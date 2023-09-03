-- create extensions
CREATE EXTENSION pg_trgm;
-- CREATE EXTENSION plpgsql; -- this one is already present
CREATE EXTENSION unaccent;

-- feeds table with URLs, subscribers and stats
CREATE TABLE feeds (
    id BIGINT NOT NULL PRIMARY KEY generated by default as identity,
    url VARCHAR( 500 ) UNIQUE NOT NULL,
	title VARCHAR( 500 ) DEFAULT '',
	article_selector VARCHAR( 500 ) DEFAULT '',
	icon VARCHAR( 500 ) NOT NULL DEFAULT '',
	fetch_interval_minutes SMALLINT NOT NULL DEFAULT 5,
	last_fetch_ts INT NOT NULL DEFAULT 0,
	last_non_empty_fetch INT NOT NULL DEFAULT 0,
	next_fetch_ts INT NOT NULL DEFAULT 0,
	last_error TEXT DEFAULT '',
	last_error_ts INT NOT NULL DEFAULT 0,
	empty_fetches INT NOT NULL DEFAULT 0,
	subsequent_stable_fetch_intervals INT NOT NULL DEFAULT 0,
	subsequent_errors_counter INT NOT NULL DEFAULT 0,
	total_fetches INT NOT NULL DEFAULT 0,
	total_errors INT NOT NULL DEFAULT 0,
	normal_subscribers INT NOT NULL DEFAULT 0,
	premium_subscribers INT NOT NULL DEFAULT 0,
	stories_per_day TEXT NOT NULL DEFAULT '{}',
    stories_per_hour TEXT NOT NULL DEFAULT '{}',
    stories_per_month TEXT NOT NULL DEFAULT '{}',
    active SMALLINT NOT NULL DEFAULT 1
);

CREATE INDEX next_fetch_ts ON feeds( next_fetch_ts ASC );
CREATE INDEX rss_fetch_conditions ON feeds (normal_subscribers ASC, premium_subscribers ASC, active ASC, next_fetch_ts ASC, subsequent_errors_counter DESC );
CREATE INDEX errors_check ON feeds ( subsequent_errors_counter DESC, last_error_ts ASC );
CREATE INDEX url ON feeds USING HASH ( url );




-- functions to update stats on the given feed
-- recursive JSON merge
CREATE OR REPLACE FUNCTION jsonb_merge_recurse(orig jsonb, delta jsonb)
RETURNS jsonb LANGUAGE SQL AS $$
    SELECT
        jsonb_object_agg(
            COALESCE(keyOrig, keyDelta),
            CASE
                WHEN valOrig isnull THEN valDelta
                WHEN valDelta isnull THEN valOrig
                WHEN (jsonb_typeof(valOrig) <> 'object' OR jsonb_typeof(valDelta) <> 'object') THEN valDelta
                ELSE jsonb_merge_recurse(valOrig, valDelta)
            END
        )
    FROM jsonb_each(orig) e1(keyOrig, valOrig)
    FULL JOIN jsonb_each(delta) e2(keyDelta, valDelta) ON keyOrig = keyDelta
$$;

-- update statistical information and fetch intervals after a successful RSS fetch result
CREATE OR REPLACE FUNCTION update_feed_after_fetch_success( feed_url TEXT, hour_num TEXT, day_of_week TEXT, day_of_year TEXT, week_of_year TEXT, month_num TEXT, year_num TEXT, inc_by INTEGER, first_item_ts INTEGER ) RETURNS bool AS $$
DECLARE
    feed_data feeds%rowtype;
    unix_timestamp INTEGER := ROUND( EXTRACT( epoch FROM now() ) );
    first_stamp_difference INTEGER;
BEGIN
    SELECT * FROM feeds INTO feed_data WHERE url = feed_url;

    -- reset fetch time interval if we've had previous subsequent errors in this feed
    IF feed_data.subsequent_errors_counter > 0 THEN
        feed_data.fetch_interval_minutes := feed_data.fetch_interval_minutes - ( feed_data.subsequent_errors_counter * 5 );
        IF feed_data.fetch_interval_minutes <= 0 THEN
            feed_data.fetch_interval_minutes := 5;
        END IF;
        feed_data.subsequent_errors_counter := 0;
    END IF;

    -- update fetch data
    -- ... last fetch TS is always updated
    feed_data.last_fetch_ts := unix_timestamp;

    IF inc_by > 0 AND inc_by IS NOT NULL THEN
	    -- we've had links inserted, increase statistical data
	    feed_data.stories_per_hour := jsonb_merge_recurse( feed_data.stories_per_hour::jsonb, ('{ "' || hour_num || '" : { "' || day_of_year || '" : { "' || year_num || '" : ' || ( COALESCE( feed_data.stories_per_hour::jsonb->hour_num->day_of_year->year_num::text,'0')::int + inc_by)::text ||' } } }')::jsonb );
        feed_data.stories_per_month := jsonb_merge_recurse( feed_data.stories_per_month::jsonb, ('{ "' || month_num || '" : { "' || year_num || '" : ' || ( COALESCE( feed_data.stories_per_month::jsonb->month_num->year_num::text,'0')::int + inc_by)::text ||' } }')::jsonb );
        feed_data.stories_per_day := jsonb_merge_recurse( feed_data.stories_per_day::jsonb, ('{ "' || day_of_week || '" : { "' || week_of_year || '" : { "' || year_num || '" : ' || ( COALESCE( feed_data.stories_per_day::jsonb->day_of_week->week_of_year->year_num::text,'0')::int + inc_by)::text ||' } } }')::jsonb );

        -- continue with the rest of data
        feed_data.subsequent_stable_fetch_intervals := feed_data.subsequent_stable_fetch_intervals + 1;
        feed_data.total_fetches := feed_data.total_fetches + 1;
        feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
        feed_data.last_non_empty_fetch := unix_timestamp;

        -- if this feed was dormant for a long time, let's reset its timers, so we can re-train
        -- our fetch timers on this feed from scratch
        IF feed_data.subsequent_stable_fetch_intervals > 10 AND ( ( feed_data.empty_fetches / feed_data.total_fetches ) * 100 ) >= 24 THEN
            feed_data.fetch_interval_minutes := 5;
            feed_data.subsequent_stable_fetch_intervals := 0;
        END IF;

        -- if the timestamp of the first added item is timed long before our actual fetch time,
        -- and it's after the actual last fetch time, shorten this feed's fetch time to match the difference
        IF first_item_ts >= feed_data.last_non_empty_fetch AND first_item_ts < feed_data.next_fetch_ts THEN
            -- check if the difference when divided by 5 (minutes) gives us any space to adjust our timer
            first_stamp_difference := FLOOR( ( ( feed_data.next_fetch_ts - first_item_ts ) / 60 ) / 5 );
            IF first_stamp_difference >= 1 AND ( feed_data.fetch_interval_minutes - ( first_stamp_difference * 5 ) ) > 0 THEN
                feed_data.fetch_interval_minutes := feed_data.fetch_interval_minutes - ( first_stamp_difference * 5 );
                feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
            END IF;
        END IF;
    ELSE
        -- we've not had any links inserted
        IF feed_data.subsequent_stable_fetch_intervals > 10 AND unix_timestamp < ( feed_data.last_non_empty_fetch + (60 * 60 * 20) ) THEN
            -- leave a grace period of 20 hours for feeds that already have a stable fetch interval,
            -- as these could potentially be daily feeds (such as local auctions or a trading RSS channel)
            -- which lay dormant during the night
            -- ... for this reason, we won't increment total fetches, neither empty fetches here
            feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
        ELSIF feed_data.subsequent_stable_fetch_intervals > 10 AND ( ( feed_data.empty_fetches / feed_data.total_fetches ) * 100 ) < 24 THEN
            -- don't modify the fetch interval if this feed was known to work
            -- for some time, as this could be a temporary flaw in their systems
            -- ... if such a feed is found to be with 10+ errors, it will automatically be
            --     excluded from fetching for 2 days and then the interval will reset
            -- ... we can still increase this interval if empty fetches ratio is too high (let's start with higher than 24%)
            feed_data.total_fetches := feed_data.total_fetches + 1;
            feed_data.empty_fetches := feed_data.empty_fetches + 1;
            feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
        ELSE
            -- this feed doesn't have a stable fetch interval yet - update timings
            -- but don't go above 10 days in the interval
            IF ( feed_data.fetch_interval_minutes + 5 ) < (60 * 24 * 10) THEN
                -- don't go above 1 hour for feeds where we didn't receive any articles yet,
                -- so we don't create a 10 days gap for a feed which may start updating every hour during
                -- the day but may lay dormant during the night
                IF
                    feed_data.empty_fetches <> feed_data.total_fetches -- extend if we have at least some articles
                    OR feed_data.empty_fetches > 32 -- or if we've not seen anything at all for the past 32 fetches
                                                    -- which would make for 36 hours of empty initial results
                    OR feed_data.fetch_interval_minutes < 60 -- or if none exist but the interval is not yet at 1 hour
                THEN
                    feed_data.fetch_interval_minutes := feed_data.fetch_interval_minutes + 5;
                    feed_data.next_fetch_ts := unix_timestamp + ( ( feed_data.fetch_interval_minutes + 5 ) * 60 );
                ELSE
                    feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
                END IF;
            ELSE
                feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
            END IF;

            feed_data.total_fetches := feed_data.total_fetches + 1;
            feed_data.empty_fetches := feed_data.empty_fetches + 1;
            feed_data.subsequent_stable_fetch_intervals := 0;
        END IF;
	END IF;

	UPDATE feeds SET
		fetch_interval_minutes = feed_data.fetch_interval_minutes,
		subsequent_errors_counter = feed_data.subsequent_errors_counter,
		last_fetch_ts = feed_data.last_fetch_ts,
		stories_per_hour = feed_data.stories_per_hour,
		stories_per_month = feed_data.stories_per_month,
		stories_per_day = feed_data.stories_per_day,
		subsequent_stable_fetch_intervals = feed_data.subsequent_stable_fetch_intervals,
		total_fetches = feed_data.total_fetches,
		next_fetch_ts = feed_data.next_fetch_ts,
		last_non_empty_fetch = feed_data.last_non_empty_fetch,
		empty_fetches = feed_data.empty_fetches
	WHERE url = feed_url;

	RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- update statistical information and fetch intervals after a failed RSS fetch result
CREATE OR REPLACE FUNCTION update_feed_after_fetch_failed( feed_url TEXT, err_msg TEXT ) RETURNS bool AS $$
DECLARE
    feed_data feeds%rowtype;
    unix_timestamp INTEGER := ROUND( EXTRACT( epoch FROM now() ) );
BEGIN
    SELECT * FROM feeds INTO feed_data WHERE url = feed_url;

    -- don't go above 10 days with fetch interval
    IF ( feed_data.fetch_interval_minutes + 5 ) < (60 * 24 * 10) THEN
        feed_data.fetch_interval_minutes := feed_data.fetch_interval_minutes + 5;
        feed_data.next_fetch_ts := unix_timestamp + ( ( feed_data.fetch_interval_minutes + 5 ) * 60 );
    ELSE
        feed_data.next_fetch_ts := unix_timestamp + ( feed_data.fetch_interval_minutes * 60 );
    END IF;

    -- update fetch data
    feed_data.last_fetch_ts := unix_timestamp;
    feed_data.last_error_ts := unix_timestamp;
    feed_data.last_error := err_msg;
    feed_data.total_errors := feed_data.total_errors + 1;
    feed_data.total_fetches := feed_data.total_fetches + 1;
    feed_data.subsequent_errors_counter := feed_data.subsequent_errors_counter + 1;
    feed_data.subsequent_stable_fetch_intervals := 0;

    -- save new values
	UPDATE feeds SET
		fetch_interval_minutes = feed_data.fetch_interval_minutes,
		subsequent_errors_counter = feed_data.subsequent_errors_counter,
		last_fetch_ts = feed_data.last_fetch_ts,
        last_error_ts = feed_data.last_error_ts,
		last_error = feed_data.last_error,
		total_errors = feed_data.total_errors,
		subsequent_stable_fetch_intervals = feed_data.subsequent_stable_fetch_intervals,
		total_fetches = feed_data.total_fetches,
		next_fetch_ts = feed_data.next_fetch_ts
	WHERE url = feed_url;

	RETURN TRUE;
END;
$$ LANGUAGE plpgsql;



-- updates feeds with 10+ subsequent failures where last fetch was more than 2 days ago
CREATE OR REPLACE FUNCTION update_old_failed_feeds() RETURNS bool AS $$
DECLARE
    unix_timestamp INTEGER := ROUND( EXTRACT( epoch FROM now() ) );
BEGIN
    UPDATE feeds SET
        subsequent_errors_counter = 0,
        last_error_ts = 0,
        fetch_interval_minutes = 5,
        subsequent_stable_fetch_intervals = 0
    WHERE
        subsequent_errors_counter > 10 AND
        last_error_ts > unix_timestamp - (60 * 60 * 24 * 2); -- now minus 2 days

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;



-- assemble all feeds with the following parameters:
-- -> at least 1 normal/premium user subscribed
-- -> next_fetch_ts >= current time
-- -> subsequent errors counter less than 10
CREATE OR REPLACE VIEW fetchable_feeds AS
    SELECT url FROM feeds WHERE
        ( normal_subscribers > 0 OR premium_subscribers > 0 ) AND
        active = 1 AND
        (
            ( next_fetch_ts = 0 OR next_fetch_ts <= ROUND( EXTRACT( epoch FROM now() ) ) )
            AND
            subsequent_errors_counter < 10
        );



-- table unprocessed_links with new links that are waiting for pre-processing and scoring by the system
CREATE TABLE unprocessed_links (
    id BIGINT NOT NULL PRIMARY KEY generated by default as identity,
    feed_id BIGINT NOT NULL,
    title VARCHAR( 750 ) DEFAULT '',
	description TEXT DEFAULT '',
	original_body TEXT DEFAULT '',
	link VARCHAR( 750 ) NOT NULL,
	img VARCHAR( 500 ) DEFAULT '',
	date_posted INT NOT NULL DEFAULT 0,
	date_fetched INT NOT NULL DEFAULT ROUND( EXTRACT( epoch FROM now() ) ),
	date_processed INT NOT NULL DEFAULT 0,
	is_processed SMALLINT NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX feed_link ON unprocessed_links (feed_id ASC, link ASC );
CREATE INDEX feed_processed ON unprocessed_links (feed_id ASC, is_processed ASC );
CREATE INDEX processed_fetched ON unprocessed_links (is_processed DESC, date_fetched DESC );



-- table err_log
CREATE TABLE err_log (
    id BIGINT NOT NULL PRIMARY KEY generated by default as identity,
    service_id VARCHAR( 50 ) NOT NULL,
	code INT NOT NULL DEFAULT 0,
	log_time INT NOT NULL DEFAULT 0,
	msg TEXT NOT NULL,
	extra TEXT DEFAULT ''
);

CREATE INDEX service_id_log_time ON err_log ( service_id, log_time );
CREATE INDEX code ON err_log ( code );