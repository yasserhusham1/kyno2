/**
 * KYNO — Sentry error monitoring (optional via sentryDsn in local.config.js)
 * No PII: company_id, user_id, role, page only.
 * SDK loads lazily after startup idle window — does not block first paint.
 */
(function (global) {
  'use strict';

  var SENTRY_URL = 'https://browser.sentry-cdn.com/8.45.0/bundle.tracing.min.js';
  var _loadPromise = null;
  var _initialized = false;
  var _pendingCaptures = [];

  function cfg() {
    try {
      if (global.BasmaConfig && global.BasmaConfig.get) {
        return {
          dsn: String(global.BasmaConfig.get('sentryDsn') || '').trim(),
          env: global.BasmaConfig.isProduction && global.BasmaConfig.isProduction() ? 'production' : 'development'
        };
      }
    } catch (e) {}
    return { dsn: '', env: 'development' };
  }

  function sessionContext() {
    var u = global.saasCurrentUser || global.currentUser || null;
    var page = '';
    try {
      var active = document.querySelector('.page.active');
      if (active && active.id) page = active.id.replace(/^page-/, '');
    } catch (e2) {}
    return {
      company_id: u && u.company_id != null ? u.company_id : null,
      user_id: u && u.id != null ? u.id : null,
      role: u && u.role ? u.role : null,
      page: page
    };
  }

  function loadSentryScript() {
    if (typeof global.Sentry !== 'undefined' && global.Sentry.init) return Promise.resolve();
    if (_loadPromise) return _loadPromise;
    _loadPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = SENTRY_URL;
      s.async = true;
      s.crossOrigin = 'anonymous';
      s.onload = function () {
        if (typeof global.Sentry !== 'undefined' && global.Sentry.init) resolve();
        else { _loadPromise = null; reject(new Error('sentry_load_failed')); }
      };
      s.onerror = function () { _loadPromise = null; reject(new Error('sentry_load_failed')); };
      document.head.appendChild(s);
    });
    return _loadPromise;
  }

  function flushPendingCaptures() {
    if (!_pendingCaptures.length) return;
    var queue = _pendingCaptures.slice();
    _pendingCaptures = [];
    queue.forEach(function (item) {
      captureKynoError(item.err, item.extra);
    });
  }

  function initSentry() {
    if (_initialized) return true;
    var c = cfg();
    if (!c.dsn || typeof global.Sentry === 'undefined' || !global.Sentry.init) return false;
    var release = (global.BasmaApp && global.BasmaApp.versionLabel) || 'v1.0.0';
    global.Sentry.init({
      dsn: c.dsn,
      environment: c.env,
      release: release,
      tracesSampleRate: c.env === 'production' ? 0.15 : 0.5,
      beforeSend: function (event) {
        var ctx = sessionContext();
        event.tags = event.tags || {};
        if (ctx.page) event.tags.page = ctx.page;
        if (ctx.role) event.tags.role = ctx.role;
        event.user = {
          id: ctx.user_id != null ? String(ctx.user_id) : undefined,
          company_id: ctx.company_id != null ? String(ctx.company_id) : undefined
        };
        if (event.request) delete event.request.headers;
        return event;
      }
    });
    _initialized = true;
    flushPendingCaptures();
    return true;
  }

  function ensureSentryReady() {
    var c = cfg();
    if (!c.dsn) return Promise.resolve(false);
    return loadSentryScript().then(function () {
      return initSentry();
    }).catch(function () {
      return false;
    });
  }

  function captureKynoError(err, extra) {
    var c = cfg();
    if (!c.dsn) return;
    if (!_initialized || typeof global.Sentry === 'undefined' || !global.Sentry.captureException) {
      _pendingCaptures.push({ err: err, extra: extra });
      ensureSentryReady();
      return;
    }
    var ctx = sessionContext();
    var payload = Object.assign({}, ctx, extra || {});
    global.Sentry.withScope(function (scope) {
      scope.setContext('kyno', payload);
      global.Sentry.captureException(err instanceof Error ? err : new Error(String(err)));
    });
  }

  function scheduleDeferredInit() {
    var run = function () { ensureSentryReady(); };
    if (typeof global.requestIdleCallback === 'function') {
      global.requestIdleCallback(run, { timeout: 4000 });
    } else {
      setTimeout(run, 2000);
    }
  }

  global.KynoSentry = Object.freeze({
    init: initSentry,
    capture: captureKynoError,
    context: sessionContext
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', scheduleDeferredInit);
  } else {
    scheduleDeferredInit();
  }
})(typeof window !== 'undefined' ? window : globalThis);
