/**
 * Safe storage — لا passwords ولا tokens حساسة
 */
(function (global) {
  'use strict';

  var FORBIDDEN_KEYS = [
    'password', 'password_hash', 'service_role', 'secret',
    'private_key', 'api_secret'
  ];

  var FORBIDDEN_KEY_PATTERNS = [
    /service.role/i,
    /password_hash/i,
    /^sb-[a-z0-9-]+-auth-token$/i,
    /^basma_admin_session$/i,
    /^attendance_system_data/i,
    /^basma_registered_/i,
    /^basma_emp_session$/i,
    /^basma_employee_company_id$/i,
    /^basma_cloud_flush_/i,
    /^basma_tenant_/i
  ];

  function isForbiddenKey(key) {
    var k = String(key || '');
    var kl = k.toLowerCase();
    if (FORBIDDEN_KEYS.some(function (f) { return kl.indexOf(f) >= 0; })) return true;
    return FORBIDDEN_KEY_PATTERNS.some(function (re) { return re.test(k); });
  }

  function safeSet(key, value) {
    if (isForbiddenKey(key)) {
      console.warn('Blocked sensitive storage key:', key);
      return false;
    }
    try {
      localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value));
      return true;
    } catch (e) {
      console.warn('safeSet failed:', e);
      return false;
    }
  }

  function safeGet(key, parseJson) {
    try {
      var raw = localStorage.getItem(key);
      if (raw == null) return null;
      if (!parseJson) return raw;
      return JSON.parse(raw);
    } catch (e) {
      return null;
    }
  }

  function safeRemove(key) {
    try { localStorage.removeItem(key); } catch (e) {}
  }

  function patchNativeStorage() {
    if (typeof localStorage === 'undefined' || localStorage.__basmaPatched) return;
    var origSet = localStorage.setItem.bind(localStorage);
    localStorage.setItem = function (key, value) {
      if (isForbiddenKey(key)) {
        console.warn('Blocked localStorage.setItem:', key);
        return;
      }
      return origSet(key, value);
    };
    try {
      Object.defineProperty(localStorage, '__basmaPatched', { value: true, configurable: false });
    } catch (e) { localStorage.__basmaPatched = true; }
  }

  patchNativeStorage();

  global.BasmaStorage = {
    safeSet: safeSet,
    safeGet: safeGet,
    safeRemove: safeRemove,
    isForbiddenKey: isForbiddenKey,
    patchNativeStorage: patchNativeStorage
  };
})(typeof window !== 'undefined' ? window : globalThis);
