/**
 * Session — in-memory only (no PII/tokens in localStorage)
 */
(function (global) {
  'use strict';

  var ADMIN_KEY = 'basma_admin_session';
  var EMP_KEY = 'basma_emp_session';
  var _adminSessionMemory = null;

  function saveAdminSessionMeta(user) {
    if (!user || !user.id) return;
    _adminSessionMemory = {
      id: user.id,
      ts: Date.now(),
      user: {
        id: user.id,
        username: user.username,
        display_name: user.display_name || '',
        role: user.role,
        company_id: user.company_id != null ? parseInt(user.company_id, 10) : null,
        company_name: user.company_name || null,
        permissions: user.permissions || {}
      }
    };
    try { localStorage.removeItem(ADMIN_KEY); } catch (e) { /* ignore */ }
  }

  function clearAdminSessionMeta() {
    _adminSessionMemory = null;
    try { localStorage.removeItem(ADMIN_KEY); } catch (e) { /* ignore */ }
  }

  function getAdminSessionMeta() {
    return _adminSessionMemory;
  }

  global.BasmaSession = {
    ADMIN_KEY: ADMIN_KEY,
    EMP_KEY: EMP_KEY,
    saveAdminSessionMeta: saveAdminSessionMeta,
    clearAdminSessionMeta: clearAdminSessionMeta,
    getAdminSessionMeta: getAdminSessionMeta
  };
})(typeof window !== 'undefined' ? window : globalThis);
