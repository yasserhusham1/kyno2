/**
 * KYNO structured logger (console + in-memory ring buffer)
 */
(function (global) {
  'use strict';

  function KynoLogger(options) {
    options = options || {};
    this.level = options.level || 'info';
    this.levels = { error: 0, warn: 1, info: 2, debug: 3 };
    this.storage = [];
    this.max = options.maxStoredLogs || 300;
  }

  KynoLogger.prototype.log = function (level, message, data) {
    if (this.levels[level] > this.levels[this.level]) return;
    var entry = {
      timestamp: new Date().toISOString(),
      level: level,
      message: message,
      data: data || {}
    };
    this.storage.push(entry);
    if (this.storage.length > this.max) this.storage.shift();
    var prefix = '[KYNO][' + level.toUpperCase() + ']';
    if (level === 'error') console.error(prefix, message, data || '');
    else if (level === 'warn') console.warn(prefix, message, data || '');
    else console.log(prefix, message, data || '');
    return entry;
  };

  KynoLogger.prototype.error = function (m, d) { return this.log('error', m, d); };
  KynoLogger.prototype.warn = function (m, d) { return this.log('warn', m, d); };
  KynoLogger.prototype.info = function (m, d) { return this.log('info', m, d); };
  KynoLogger.prototype.debug = function (m, d) { return this.log('debug', m, d); };
  KynoLogger.prototype.getLogs = function () { return this.storage.slice(); };

  var logger = new KynoLogger({
    level: global.BasmaConfig && BasmaConfig.isProduction && BasmaConfig.isProduction() ? 'info' : 'debug'
  });

  global.KynoLogger = KynoLogger;
  global.kynoLogger = logger;
})(typeof window !== 'undefined' ? window : globalThis);
