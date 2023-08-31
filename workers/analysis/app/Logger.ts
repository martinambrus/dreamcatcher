import { ILogger, LOG_SEVERITIES } from './Redis/Interfaces/ILogger.js';
import { IRedisPub } from './Redis/Interfaces/IRedisPub.js';
import { IMessageQueue } from './Redis/Interfaces/IMessageQueue.js';
import { env } from 'node:process';

/**
 * A logging class that formats log messages and logs them
 * into the console and the Kafka cluster.
 * @class Logger
 */
export class Logger implements ILogger {

  /**
   * Main app client ID, so we can prepend it to every log message.
   * @private
   * @type { string }
   */
  private readonly client_id: string;

  /**
   * Main app service ID, so we can use it in Redis logs.
   * @private
   * @type { string }
   */
  private readonly service_id: string;

  /**
   * Instance of the message broker class used for message publishing.
   * @private
   * @type { IMessageQueue }
   */
  private mq_broker: IMessageQueue = null;

  /**
   * Redis Pub client instance.
   * @private
   * @type { IRedisPub }
   */
  private redis_pub: IRedisPub = null;

  /**
   * Logs channel name.
   * @private
   */
  private logs_channel_name: string;

  /**
   * Create a global logger instance and sets client ID
   * to the correct value for later logging purposes.
   *
   * @param { string }             client_id  Client ID to identify client in log messages.
   * @param { string }             service_id Service ID to add to Redis logs.
   * @param { IRedisPub }          redis_pub  Redis Pub client instance, used to fetch error codes.
   * @param { IMessageQueue|null } mq_broker  Message broker, used for publishing log messages.
   * @constructor
   */
  constructor(client_id: string, service_id: string, redis_pub: IRedisPub = null, mq_broker: IMessageQueue|null = null ) {
    this.client_id = client_id;
    this.service_id = service_id;
    this.redis_pub = redis_pub;
    this.mq_broker = mq_broker;

    this.logs_channel_name = env.REDIS_NEW_LINKS_CHANNEL;
  }

  /**
   * Sets a new message broker instance.
   * @param { IMessageQueue } broker The message broker to use from now on.
   */
  public set_mq_broker( broker: IMessageQueue ): void {
    this.mq_broker = broker;
  }

  /**
   * Sets a new Redis Pub client.
   * @param { IRedisPub } redis_pub The Redis Pub client to use from now on.
   */
  public set_redis_pub_client( redis_pub: IRedisPub ): void {
    this.redis_pub = redis_pub;
  }

  /**
   * Formats a log message by prefixing it with date/time and client ID.
   *
   * @param { string } msg Message to format for logging purposes.
   *
   * @return { string } Returns a correctly formatted log message.
   */
  public format(msg: string): string {
    let dt: Date = new Date();
    return '[' + dt.getDate() + '.' + ( dt.getMonth() + 1 ) + '.' + dt.getFullYear() + ' ' + dt.getHours() + ':' + dt.getMinutes() + ':' + dt.getSeconds() + '] ' + this.client_id + ': ' + msg;

  }

  /**
   * Logs message into the message queue log.
   *
   * @param { string }        msg        Message to log.
   * @param { number|string } code       A numeric error code. If string is passed, code will be looked up from the Redis client.
   * @param { string }        severity   Log severity - on of the LOG_SEVERITIES enum, @see { Analysis.LOG_SEVERITIES }
   * @param { Object }        extra_data Any extra data to be passed to the message.
   */
  public async log_msg( msg: string, code: number|string = 0, severity: string = LOG_SEVERITIES.LOG_SEVERITY_ERROR, extra_data: Object = {} ): Promise<void> {
    msg = this.format( msg );

    if ( this.mq_broker ) {
      let log_msg = {
        'service': this.service_id,
        'time': Math.round( Date.now() / 1000 ),
        'msg': msg,
      };

      if (severity) {
        log_msg['severity'] = severity;
      }

      if (code) {
        if ( typeof code === 'string' ) {
          log_msg['code'] = parseInt( await this.redis_pub.get( code ) );
        } else {
          log_msg['code'] = code;
        }
      }

      if ( Object.keys( extra_data ) ) {
        log_msg[ 'extra_data' ] = extra_data;
      }

      // extract trace ID, if found
      let msg_key = Date.now() + '_' + Math.random(); // random key if trace ID is not present
      if ( extra_data && extra_data[ 'trace_id' ] ) {
        msg_key = extra_data[ 'trace_id' ];
      }

      // no await - we're not returning anything here
      this.mq_broker.send( this.logs_channel_name, log_msg, msg_key );
    }
  }

}