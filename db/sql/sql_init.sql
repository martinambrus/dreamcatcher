CREATE TABLE feeds (
    id BIGINT PRIMARY KEY generated by default as identity,
    url VARCHAR( 500 ),
	title VARCHAR( 500 ),
	icon VARCHAR( 500 ) DEFAULT '',
	fetch_interval_minutes SMALLINT NOT NULL DEFAULT 5,
	last_fetch_ts BIGINT NOT NULL DEFAULT 0,
	last_non_empty_fetch INT NOT NULL DEFAULT 0,
	next_fetch_ts INT NOT NULL DEFAULT 0,
	last_error TEXT,
	last_error_ts INT NOT NULL DEFAULT 0,
	empty_fetches INT NOT NULL DEFAULT 0,
	subsequent_stable_fetch_intervals INT NOT NULL DEFAULT 0,
	subsequent_errors_counter INT NOT NULL DEFAULT 0,
	total_fetches INT NOT NULL DEFAULT 0,
	total_errors INT NOT NULL DEFAULT 0,
	normal_subscribers INT NOT NULL DEFAULT 0,
	premium_subscribers INT NOT NULL DEFAULT 0,
	stories_per_day TEXT,
	stories_per_hour TEXT,
	stories_per_month TEXT
);

CREATE INDEX next_fetch_ts ON feeds( next_fetch_ts ASC );
CREATE INDEX rss_fetch_conditions ON feeds (normal_subscribers ASC, premium_subscribers ASC, next_fetch_ts ASC, subsequent_errors_counter DESC );
CREATE INDEX errors_check ON feeds ( subsequent_errors_counter DESC, last_error_ts ASC );
CREATE INDEX url ON feeds USING HASH ( url );