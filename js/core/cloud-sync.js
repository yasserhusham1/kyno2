/**
 * KYNO Cloud Sync — سحابة أولاً، طابور offline، ومزامنة سريعة
 */
(function (global) {
  'use strict';

  var FLUSH_INTERVAL_MS = 8000;
  var PULL_INTERVAL_MS = 60000;
  var _flushTimer = null;
  var _pullTimer = null;
  var _immediateSyncTimer = null;
  var _inited = false;

  function isOnline() {
    return typeof navigator !== 'undefined' ? navigator.onLine !== false : true;
  }

  function queueStorageKey() {
    var cid = typeof global.getActiveStorageCompanyId === 'function'
      ? global.getActiveStorageCompanyId() : null;
    return 'basma_cloud_flush_c_' + (cid || '0');
  }

  function markNeedsCloudFlush() {
    try {
      localStorage.setItem(queueStorageKey(), String(Date.now()));
    } catch (e) { /* ignore */ }
  }

  function clearNeedsCloudFlush() {
    try { localStorage.removeItem(queueStorageKey()); } catch (e) { /* ignore */ }
  }

  function needsCloudFlush() {
    try { return !!localStorage.getItem(queueStorageKey()); } catch (e) { return false; }
  }

  function updateConnectivityBanner() {
    var el = document.getElementById('cloud-offline-banner');
    if (!el) return;
    if (!isOnline()) {
      el.style.display = '';
      el.innerHTML = '<i class="fa fa-wifi"></i> بدون اتصال — التعديلات تُحفظ وتُرفع تلقائياً عند عودة الشبكة';
      if (global.BasmaLeaveGuard && global.BasmaLeaveGuard.updateSyncStatusUi) {
        global.BasmaLeaveGuard.updateSyncStatusUi();
      }
      return;
    }
    el.style.display = 'none';
    if (global.BasmaLeaveGuard && global.BasmaLeaveGuard.updateSyncStatusUi) {
      global.BasmaLeaveGuard.updateSyncStatusUi();
    }
  }

  async function flushPendingToCloud(options) {
    options = options || {};
    if (typeof window !== 'undefined' && (window.__basmaLoggingOut || window.__basmaDisableAutoSync)) return false;
    if (!(await hasCloudAuth())) return false;
    if (!isOnline()) {
      updateConnectivityBanner();
      return false;
    }
    if (typeof global.AuthApi !== 'undefined' && global.AuthApi.hasAuthenticatedSession) {
      var hasJwt = await global.AuthApi.hasAuthenticatedSession();
      if (!hasJwt && global.currentUser === 'admin') {
        updateConnectivityBanner();
        return false;
      }
    }
    var ok = true;
    if (typeof global.syncToSupabase === 'function' &&
        (options.force || (typeof global.hasPendingDataSync === 'function' && global.hasPendingDataSync()) || needsCloudFlush())) {
      try {
        ok = await global.syncToSupabase({ reason: options.reason || 'cloud-flush' }) !== false;
      } catch (e) {
        console.warn('flushPendingToCloud:', e);
        ok = false;
      }
    }
    if (ok) clearNeedsCloudFlush();
    updateConnectivityBanner();
    if (typeof global.BasmaLeaveGuard !== 'undefined' && global.BasmaLeaveGuard.updateSyncStatusUi) {
      global.BasmaLeaveGuard.updateSyncStatusUi();
    }
    if (typeof global.updatePendingSyncBadge === 'function') global.updatePendingSyncBadge();
    return ok;
  }

  function scheduleImmediateCloudSync(reason) {
    if (_immediateSyncTimer) clearTimeout(_immediateSyncTimer);
    markNeedsCloudFlush();
    _immediateSyncTimer = setTimeout(function () {
      _immediateSyncTimer = null;
      flushPendingToCloud({ reason: reason || 'immediate' }).catch(function (e) {
        console.warn('scheduleImmediateCloudSync:', e);
      });
    }, 250);
  }

  async function saveAndSyncCloud(options) {
    options = options || {};
    if (typeof global.saveData === 'function') global.saveData();
    markNeedsCloudFlush();
    updateConnectivityBanner();
    if (!isOnline()) {
      if (typeof global.schedulePendingSyncRetry === 'function') global.schedulePendingSyncRetry();
      return { ok: false, offline: true };
    }
    if (options.settingsOnly && typeof global.syncToSupabase === 'function') {
      var settingsOk = await global.syncToSupabase({ settingsOnly: true, reason: options.reason || 'settings' });
      updateConnectivityBanner();
      return { ok: !!settingsOk, offline: false };
    }
    scheduleImmediateCloudSync(options.reason || 'save-and-sync');
    return { ok: true, offline: false, queued: true };
  }

  function stopPeriodicCloudSync() {
    if (_flushTimer) { clearInterval(_flushTimer); _flushTimer = null; }
    if (_pullTimer) { clearInterval(_pullTimer); _pullTimer = null; }
  }

  async function hasCloudAuth() {
    if (typeof window !== 'undefined' && window.__basmaLoggingOut) return false;
    if (global.currentUser !== 'admin' && global.currentUser !== 'emp') return false;
    if (typeof global.AuthApi !== 'undefined' && global.AuthApi.hasAuthenticatedSession) {
      try { return await global.AuthApi.hasAuthenticatedSession(); } catch (e) { return false; }
    }
    return true;
  }

  async function cloudRefreshFromServer(options) {
    options = options || {};
    if (typeof window !== 'undefined' && (window.__basmaLoggingOut || window.__basmaDisableAutoSync)) return false;
    if (!isOnline() || typeof global.syncFromSupabase !== 'function') return false;
    if (!(await hasCloudAuth())) return false;
    try {
      return await global.syncFromSupabase({
        reason: options.reason || 'cloud-refresh',
        realtime: !!options.realtime,
        forceRemote: !!options.forceRemote
      });
    } catch (e) {
      console.warn('cloudRefreshFromServer:', e);
      return false;
    }
  }

  function startPeriodicCloudSync() {
    if (_flushTimer) clearInterval(_flushTimer);
    if (_pullTimer) clearInterval(_pullTimer);
    _flushTimer = setInterval(function () {
      if (!isOnline()) return;
      flushPendingToCloud({ reason: 'periodic-flush' }).catch(function () {});
    }, FLUSH_INTERVAL_MS);
    _pullTimer = setInterval(function () {
      if (!isOnline()) return;
      if (global.currentUser !== 'admin') return;
      if (typeof global.hasPendingDataSync === 'function' && global.hasPendingDataSync()) return;
      cloudRefreshFromServer({ reason: 'periodic-pull', realtime: true }).catch(function () {});
    }, PULL_INTERVAL_MS);
  }

  function initCloudSync() {
    if (!_inited) {
      _inited = true;
      window.addEventListener('online', function () {
        updateConnectivityBanner();
        flushPendingToCloud({ reason: 'online', force: true }).then(function () {
          if (global.currentUser === 'admin') {
            return cloudRefreshFromServer({ reason: 'online-refresh', realtime: true });
          }
        }).catch(function (e) { console.warn('online handler:', e); });
      });
      window.addEventListener('offline', function () {
        updateConnectivityBanner();
        if (global.BasmaToast && global.BasmaToast.warn) {
          global.BasmaToast.warn('انقطع الاتصال — سيتم حفظ التعديلات ورفعها عند عودة الشبكة');
        }
      });
    }
    startPeriodicCloudSync();
    updateConnectivityBanner();
  }

  global.BasmaCloud = {
    isOnline: isOnline,
    markNeedsCloudFlush: markNeedsCloudFlush,
    flushPendingToCloud: flushPendingToCloud,
    scheduleImmediateCloudSync: scheduleImmediateCloudSync,
    saveAndSyncCloud: saveAndSyncCloud,
    cloudRefreshFromServer: cloudRefreshFromServer,
    updateConnectivityBanner: updateConnectivityBanner,
    initCloudSync: initCloudSync,
    stopPeriodicCloudSync: stopPeriodicCloudSync
  };
})(typeof window !== 'undefined' ? window : globalThis);
