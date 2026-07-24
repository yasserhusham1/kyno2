/**
 * مزامنة الحالة على window — مطلوب لـ main.js و supabase_integration.js
 */
(function (global) {
  'use strict';

  function syncWindowState() {
    if (global.saasCurrentUser != null) {
      global._saasCurrentUser = global.saasCurrentUser;
    } else if (global._saasCurrentUser != null) {
      global.saasCurrentUser = global._saasCurrentUser;
    }
    if (global.charts == null) global.charts = {};
    if (global.appSettings == null && typeof global.createDefaultAppSettings === 'function') {
      global.appSettings = global.createDefaultAppSettings('');
    }
  }

  global.syncWindowState = syncWindowState;
})(typeof window !== 'undefined' ? window : globalThis);
