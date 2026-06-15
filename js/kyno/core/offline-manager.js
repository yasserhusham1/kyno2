/**
 * KYNO offline awareness — hooks existing cloud-sync / pauseRemoteSync
 */
(function (global) {
  'use strict';

  var state = { online: typeof navigator !== 'undefined' ? navigator.onLine : true, queue: [] };

  function setOnlineFlag(on) {
    state.online = !!on;
    if (global.kynoLogger) kynoLogger.info(on ? 'Network online' : 'Network offline');
    if (!on && typeof global.pauseRemoteSync === 'function') {
      try { global.pauseRemoteSync(60000); } catch (e) { /* ignore */ }
    }
    if (on && typeof global.resumeRemoteSync === 'function') {
      try { global.resumeRemoteSync(2000); } catch (e) { /* ignore */ }
    }
  }

  function install() {
    if (typeof global.addEventListener !== 'function') return;
    global.addEventListener('online', function () { setOnlineFlag(true); });
    global.addEventListener('offline', function () { setOnlineFlag(false); });
    setOnlineFlag(navigator.onLine);
  }

  function isOnline() {
    return state.online;
  }

  global.KynoOffline = {
    install: install,
    isOnline: isOnline,
    getState: function () { return { online: state.online, queued: state.queue.length }; }
  };
})(typeof window !== 'undefined' ? window : globalThis);
