/**
 * KYNO global error handler — complements window.onerror in main.js
 */
(function (global) {
  'use strict';

  var installed = false;

  function installErrorHandler() {
    if (installed || typeof global.addEventListener !== 'function') return;
    installed = true;

    global.addEventListener('unhandledrejection', function (ev) {
      var reason = ev.reason;
      if (global.kynoLogger) {
        kynoLogger.error('Unhandled promise rejection', {
          message: reason && reason.message ? reason.message : String(reason)
        });
      }
    });

    var prev = global.onerror;
    global.onerror = function (msg, url, line, col, err) {
      if (global.kynoLogger) {
        kynoLogger.error('JS error', { msg: msg, url: url, line: line, col: col, stack: err && err.stack });
      }
      if (typeof prev === 'function') return prev.apply(this, arguments);
      return false;
    };
  }

  global.KynoErrorHandler = { install: installErrorHandler };
})(typeof window !== 'undefined' ? window : globalThis);
