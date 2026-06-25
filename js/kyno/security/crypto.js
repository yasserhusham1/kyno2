/**
 * KYNO crypto — no client-side btoa passwords; tokens + SHA-256 only
 */
(function (global) {
  'use strict';

  function fallbackToken(length) {
    var len = length || 32;
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    var out = '';
    for (var i = 0; i < len; i++) {
      out += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return out;
  }

  function generateSecureToken(length) {
    var len = length || 32;
    if (!global.crypto || !global.crypto.getRandomValues) {
      console.error('SOFT ERROR:', 'crypto_unavailable');
      return fallbackToken(len);
    }
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    var arr = new Uint8Array(len);
    global.crypto.getRandomValues(arr);
    return Array.from(arr, function (x) { return chars[x % chars.length]; }).join('');
  }

  async function sha256Hex(data) {
    if (!global.crypto || !global.crypto.subtle) {
      console.error('SOFT ERROR:', 'subtle_crypto_unavailable');
      return null;
    }
    var buf = new TextEncoder().encode(String(data));
    var hash = await global.crypto.subtle.digest('SHA-256', buf);
    return Array.from(new Uint8Array(hash), function (b) {
      return b.toString(16).padStart(2, '0');
    }).join('');
  }

  /** Password hashing is server-only (Edge / RPC bcrypt) */
  async function hashPasswordSecurely(password) {
    if (typeof initSupabase === 'function') initSupabase();
    var sb = global._sbClient;
    if (!sb || typeof sb.rpc !== 'function') {
      return { ok: false, error: 'use_auth_login_edge' };
    }
    try {
      var rpc = await sb.rpc('saas_hash_password_bcrypt', { p_password: String(password) });
      if (rpc.error || !rpc.data) {
        return { ok: false, error: rpc.error ? rpc.error.message : 'hash_failed' };
      }
      return { ok: true, hash: rpc.data, algorithm: 'bcrypt' };
    } catch (e) {
      return { ok: false, error: String(e.message || e) };
    }
  }

  function deprecatedBtoaPassword() {
    console.error('SOFT ERROR:', 'btoa_password_deprecated — use Edge auth-login or saas_hash_password_bcrypt RPC');
    return null;
  }

  global.KynoSecurity = {
    generateSecureToken: generateSecureToken,
    sha256Hex: sha256Hex,
    hashPasswordSecurely: hashPasswordSecurely,
    deprecatedBtoaPassword: deprecatedBtoaPassword
  };
})(typeof window !== 'undefined' ? window : globalThis);
