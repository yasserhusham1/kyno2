/**
 * KYNO Supabase client helper — wraps existing initSupabase / ensureSupabaseClient
 */
(function (global) {
  'use strict';

  async function ensureClient(maxAttempts) {
    if (global._sbClient) return global._sbClient;
    if (typeof global.ensureSupabaseClient === 'function') {
      var ok = await global.ensureSupabaseClient(maxAttempts || 20);
      return ok ? global._sbClient : null;
    }
    if (typeof global.initSupabase === 'function' && global.initSupabase()) {
      return global._sbClient || null;
    }
    return null;
  }

  function getUrl() {
    if (global.BasmaConfig && BasmaConfig.supabaseUrl) return BasmaConfig.supabaseUrl();
    return '';
  }

  async function rpc(name, params, options) {
    options = options || {};
    var run = async function () {
      var sb = await ensureClient(options.maxAttempts || 12);
      if (!sb) throw new Error('supabase_client_unavailable');
      var res = await sb.rpc(name, params || {});
      if (res.error) {
        var err = new Error(res.error.message || 'rpc_error');
        err.code = res.error.code;
        throw err;
      }
      return res.data;
    };
    if (global.KynoRetry && options.retry !== false) {
      return KynoRetry.retryWithBackoff(run, { maxRetries: options.maxRetries || 2 });
    }
    return run();
  }

  global.KynoSupabase = {
    ensureClient: ensureClient,
    getUrl: getUrl,
    rpc: rpc
  };
})(typeof window !== 'undefined' ? window : globalThis);
