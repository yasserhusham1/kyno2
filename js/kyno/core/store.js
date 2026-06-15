/**
 * KYNO lightweight store — mirrors key globals without replacing data.js
 */
(function (global) {
  'use strict';

  function KynoStore() {
    this.subscribers = new Set();
  }

  KynoStore.prototype.getSnapshot = function () {
    return {
      currentUser: global.currentUser || null,
      saasUser: global.saasCurrentUser || global._saasCurrentUser || null,
      online: global.KynoOffline ? KynoOffline.isOnline() : true
    };
  };

  KynoStore.prototype.subscribe = function (fn) {
    this.subscribers.add(fn);
    return function () { this.subscribers.delete(fn); }.bind(this);
  };

  KynoStore.prototype.notify = function (patch) {
    var snap = this.getSnapshot();
    this.subscribers.forEach(function (fn) {
      try { fn(snap, patch || {}); } catch (e) { /* ignore */ }
    });
  };

  global.KynoStore = KynoStore;
  global.kynoStore = new KynoStore();
})(typeof window !== 'undefined' ? window : globalThis);
