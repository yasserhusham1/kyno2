/**
 * In-memory Supabase Auth storage — no JWT in localStorage/sessionStorage
 */
(function (global) {
  'use strict';

  function createMemoryAuthStorage() {
    var store = Object.create(null);
    return {
      getItem: function (key) {
        return Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null;
      },
      setItem: function (key, value) {
        store[key] = String(value);
      },
      removeItem: function (key) {
        delete store[key];
      }
    };
  }

  global.KynoMemoryAuthStorage = createMemoryAuthStorage;
})(typeof window !== 'undefined' ? window : globalThis);
