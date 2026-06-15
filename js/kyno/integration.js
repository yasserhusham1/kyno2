/**
 * KYNO bootstrap — hooks only; does NOT replace launchApp / runAutoLoginRestore
 */
(function (global) {
  'use strict';

  var started = false;

  function bootstrapKyno() {
    if (started) return;
    started = true;

    if (global.KynoErrorHandler) KynoErrorHandler.install();
    if (global.KynoOffline) KynoOffline.install();
    if (global.KynoRateLimiter) KynoRateLimiter.startRateLimiterCleanup();
    if (global.kynoLogger) kynoLogger.info('KYNO modules ready');
  }

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', bootstrapKyno);
    } else {
      bootstrapKyno();
    }
  }

  global.KynoIntegration = { bootstrap: bootstrapKyno };
})(typeof window !== 'undefined' ? window : globalThis);
