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

      if (!sb) {

        console.warn('Supabase unavailable - offline mode');

        return null;

      }

      var res = await sb.rpc(name, params || {});

      if (res.error) {

        console.error('SOFT ERROR:', res.error.message || 'rpc_error', res.error.code || '');

        return { error: true, message: res.error.message, code: res.error.code };

      }

      return res.data;

    };

    if (global.KynoRetry && options.retry !== false) {

      return KynoRetry.retryWithBackoff(run, { maxRetries: options.maxRetries || 2 });

    }

    if (typeof global.safeRpc === 'function') {

      return global.safeRpc(run);

    }

    return run();

  }



  global.KynoSupabase = {

    ensureClient: ensureClient,

    getUrl: getUrl,

    rpc: rpc

  };

})(typeof window !== 'undefined' ? window : globalThis);


