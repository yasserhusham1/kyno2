/**
 * إعدادات عامة — لا تضع service_role أو أسرار هنا.
 */
(function (global) {
  'use strict';

  var defaults = {
    supabaseUrl: '',
    supabaseAnonKey: '',
    appEnv: 'development',
    appVersion: '1.0.0',
    sentryDsn: '',
    strictRls: false,
    authUseCookies: true,
    kynoRpcMode: false,
    kynoFinalLockdown: false,
    supabaseProxy: undefined,
    realtimeTables: ['employees', 'employee_devices', 'attendance', 'app_settings', 'leaves'],
    pageSize: 100,
    maxUploadBytes: 2 * 1024 * 1024,
    allowedUploadMime: ['image/jpeg', 'image/png', 'image/webp', 'image/gif']
  };

  var local = {};
  var supabaseDefaults = {};
  try {
    if (global.__BASMA_SUPABASE_DEFAULTS__) supabaseDefaults = global.__BASMA_SUPABASE_DEFAULTS__;
  } catch (e) { /* ignore */ }
  try {
    if (global.__BASMA_LOCAL_CONFIG__) local = global.__BASMA_LOCAL_CONFIG__;
  } catch (e) { /* ignore */ }

  var config = Object.assign({}, defaults, supabaseDefaults, local);
  var directUrl = String(config.supabaseUrl || '').replace(/\/$/, '');
  var runtime = { activeUrl: directUrl, usingProxy: false, proxyTried: false };

  if (/\.supabase\.co$/i.test(directUrl)) {
    config.supabaseDirectUrl = directUrl;
  }

  // /sb proxy only when explicitly enabled OR hosted on Netlify (needs supabase-proxy function deployed once)
  var loc = global.location;
  var wantProxy = config.supabaseProxy === true;
  if (!wantProxy && config.supabaseProxy !== false && loc && loc.protocol !== 'file:') {
    var host = loc.hostname || '';
    var isLocal = host === 'localhost' || host === '127.0.0.1' || host === '[::1]';
    if (!isLocal && /\.netlify\.app$/i.test(host)) wantProxy = true;
  }

  if (wantProxy && config.supabaseDirectUrl && loc && loc.origin) {
    // Direct function URL works on Git + API deploy; /sb/* redirect is optional backup
    runtime.activeUrl = loc.origin.replace(/\/$/, '') + '/.netlify/functions/supabase-proxy';
    runtime.usingProxy = true;
    config.supabaseProxy = true;
  } else {
    runtime.activeUrl = directUrl;
    config.supabaseProxy = false;
  }

  var hostedUrl = String(config.supabaseDirectUrl || runtime.activeUrl || '').replace(/\/$/, '');
  if (/\.supabase\.co$/i.test(hostedUrl) || runtime.usingProxy) {
    config.kynoRpcMode = true;
    config.kynoFinalLockdown = true;
  } else if (config.appEnv === 'production') {
    if (!Object.prototype.hasOwnProperty.call(local, 'kynoRpcMode')) config.kynoRpcMode = true;
    if (!Object.prototype.hasOwnProperty.call(local, 'kynoFinalLockdown')) config.kynoFinalLockdown = true;
  }

  function isNetlifyHost() {
    try {
      var h = loc && loc.hostname ? loc.hostname : '';
      return /\.netlify\.app$/i.test(h);
    } catch (e) {
      return false;
    }
  }

  function fallbackToDirectSupabase() {
    if (!config.supabaseDirectUrl || runtime.proxyTried) return false;
    runtime.proxyTried = true;
    // On Netlify, direct *.supabase.co often fails (ERR_NAME_NOT_RESOLVED) — proxy function is required
    if (isNetlifyHost()) return false;
    runtime.activeUrl = config.supabaseDirectUrl;
    runtime.usingProxy = false;
    config.supabaseProxy = false;
    return true;
  }

  function markProxyUnavailable() {
    runtime.proxyTried = true;
    runtime.proxyBroken = true;
  }

  global.BasmaConfig = Object.freeze({
    get: function (key) { return config[key]; },
    supabaseUrl: function () { return String(runtime.activeUrl || '').trim(); },
    supabaseAnonKey: function () { return String(config.supabaseAnonKey || '').trim(); },
    supabaseDirectUrl: function () {
      return String(config.supabaseDirectUrl || directUrl || '').trim();
    },
    isSupabaseProxied: function () { return runtime.usingProxy === true; },
    isNetlifyHost: isNetlifyHost,
    isProxyBroken: function () { return runtime.proxyBroken === true; },
    markProxyUnavailable: markProxyUnavailable,
    fallbackToDirectSupabase: fallbackToDirectSupabase,
    isProduction: function () { return config.appEnv === 'production'; },
    authUseCookies: function () { return config.authUseCookies !== false; },
    kynoRpcMode: function () { return config.kynoRpcMode === true; },
    kynoFinalLockdown: function () { return config.kynoFinalLockdown === true; },
    pageSize: function () { return Math.max(20, parseInt(config.pageSize, 10) || 100); },
    realtimeTables: function () {
      return Array.isArray(config.realtimeTables) ? config.realtimeTables.slice() : ['employees'];
    },
    maxUploadBytes: function () { return config.maxUploadBytes; },
    allowedUploadMime: function () { return config.allowedUploadMime.slice(); },
    appVersion: function () {
      if (global.BasmaApp && global.BasmaApp.version) return global.BasmaApp.version;
      return String(config.appVersion || '1.0.0');
    }
  });
})(typeof window !== 'undefined' ? window : globalThis);
