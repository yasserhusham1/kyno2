/**
 * KYNO — Sentry error monitoring (optional via sentryDsn in local.config.js)
 * No PII: company_id, user_id, role, page only.
 */
(function (global) {
  'use strict';

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

  function initSentry() {
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
    return true;
  }

  function captureKynoError(err, extra) {
    var ctx = sessionContext();
    var payload = Object.assign({}, ctx, extra || {});
    if (global.Sentry && global.Sentry.captureException) {
      global.Sentry.withScope(function (scope) {
        scope.setContext('kyno', payload);
        global.Sentry.captureException(err instanceof Error ? err : new Error(String(err)));
      });
    }
  }

  global.KynoSentry = Object.freeze({
    init: initSentry,
    capture: captureKynoError,
    context: sessionContext
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initSentry);
  } else {
    initSentry();
  }
})(typeof window !== 'undefined' ? window : globalThis);
