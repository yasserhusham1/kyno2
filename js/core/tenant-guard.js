/**
 * حماية عزل الشركات + منع إعادة استخدام العمليات الحساسة (replay)
 */
(function (global) {
  'use strict';

  var _recentActions = {};
  var REPLAY_WINDOW_MS = 8000;
  var MAX_RECENT = 200;

  function activeCompanyId() {
    if (typeof global.getActiveStorageCompanyId === 'function') {
      var cid = global.getActiveStorageCompanyId();
      if (cid) return parseInt(cid, 10);
    }
    if (global.saasCurrentUser && global.saasCurrentUser.company_id) {
      return parseInt(global.saasCurrentUser.company_id, 10);
    }
    return null;
  }

  function assertTenantRecord(record, context) {
    var cid = activeCompanyId();
    if (!cid || !record) return true;
    if (record.company_id == null) {
      record.company_id = cid;
      return true;
    }
    if (parseInt(record.company_id, 10) !== cid) {
      console.warn('TENANT_MISMATCH', context || '', record);
      return false;
    }
    return true;
  }

  function stampTenantOnAllRecords(cid) {
    cid = cid != null ? parseInt(cid, 10) : activeCompanyId();
    if (!cid) return;
    (global.employees || []).forEach(function (e) {
      if (!e) return;
      if (e.company_id == null) e.company_id = cid;
    });
    (global.attData || []).forEach(function (r) {
      if (!r) return;
      if (r.company_id == null) r.company_id = cid;
    });
    (global.leavesData || []).forEach(function (l) {
      if (!l) return;
      if (l.company_id == null) l.company_id = cid;
    });
  }

  function pruneRecentActions() {
    var now = Date.now();
    Object.keys(_recentActions).forEach(function (k) {
      if (now - _recentActions[k] > REPLAY_WINDOW_MS) delete _recentActions[k];
    });
    var keys = Object.keys(_recentActions);
    if (keys.length > MAX_RECENT) {
      keys.sort(function (a, b) { return _recentActions[a] - _recentActions[b]; });
      keys.slice(0, keys.length - MAX_RECENT).forEach(function (k) { delete _recentActions[k]; });
    }
  }

  /** يمنع تنفيذ نفس العملية الحساسة مرتين خلال نافذة قصيرة */
  function guardReplay(actionKey) {
    pruneRecentActions();
    var key = String(actionKey || '');
    if (!key) return true;
    if (_recentActions[key]) return false;
    _recentActions[key] = Date.now();
    return true;
  }

  function buildActionKey(type, payload) {
    return type + '|' + JSON.stringify(payload || {});
  }

  global.BasmaTenant = {
    activeCompanyId: activeCompanyId,
    assertTenantRecord: assertTenantRecord,
    stampTenantOnAllRecords: stampTenantOnAllRecords,
    guardReplay: guardReplay,
    buildActionKey: buildActionKey
  };
})(typeof window !== 'undefined' ? window : globalThis);
