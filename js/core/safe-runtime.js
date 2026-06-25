/**
 * KYNO Soft-Failure Runtime — Layers 2, 4, 5, 7
 * No throw in UI bootstrap path; isolate module failures.
 */
(function (global) {
  'use strict';

  global.__APP_SAFE_MODE = false;

  function applySafeMode() {
    if (!global.__APP_SAFE_MODE || typeof document === 'undefined') return;
    if (document.body) document.body.classList.add('safe-mode');
    console.warn('Running in SAFE MODE');
    document.querySelectorAll(
      'button, [type="button"], [type="submit"], .btn-login, .btn-save, .btn-add, .sa-btn, .nav-item, .sa-action-card'
    ).forEach(function (btn) {
      btn.disabled = false;
      btn.style.pointerEvents = 'auto';
    });
    if (typeof global.clearStaleUiBlockers === 'function') global.clearStaleUiBlockers();
    if (typeof global.ensureAppInteractive === 'function') global.ensureAppInteractive();
  }

  global.safeRun = function (fn, moduleName) {
    try {
      var result = fn();
      if (result && typeof result.then === 'function') {
        return result.catch(function (e) {
          console.error('[MODULE FAILED] ' + moduleName, e);
          global.__APP_SAFE_MODE = true;
          applySafeMode();
        });
      }
      return result;
    } catch (e) {
      console.error('[MODULE FAILED] ' + moduleName, e);
      global.__APP_SAFE_MODE = true;
      applySafeMode();
      return undefined;
    }
  };

  global.safeAddEvent = function (el, event, handler, options) {
    if (!el) {
      console.warn('Missing element for event:', event);
      return;
    }
    try {
      if (options !== undefined) el.addEventListener(event, handler, options);
      else el.addEventListener(event, handler);
    } catch (e) {
      console.error('Event binding failed:', e);
      global.__APP_SAFE_MODE = true;
      applySafeMode();
    }
  };

  global.safeRpc = async function (fn) {
    var args = Array.prototype.slice.call(arguments, 1);
    try {
      return await fn.apply(null, args);
    } catch (e) {
      console.error('RPC FAILED:', e);
      return { error: true, message: String(e && e.message ? e.message : e) };
    }
  };

  global.applySafeMode = applySafeMode;
})(typeof window !== 'undefined' ? window : globalThis);
