/**
 * Sync system_version (BasmaApp.versionLabel) across login, SA, footer, settings.
 */
(function (global) {
  'use strict';

  var IDS = ['login-app-version', 'set-app-version'];

  function label() {
    if (global.BasmaApp && global.BasmaApp.versionLabel) return global.BasmaApp.versionLabel;
    if (global.BasmaConfig && global.BasmaConfig.appVersion) return 'v' + global.BasmaConfig.appVersion();
    return 'v1.0.0';
  }

  function syncSystemVersionLabels() {
    var text = label();
    IDS.forEach(function (id) {
      var el = global.document && global.document.getElementById(id);
      if (el) el.textContent = text;
    });
  }

  global.syncSystemVersionLabels = syncSystemVersionLabels;

  if (global.document) {
    if (global.document.readyState === 'loading') {
      global.document.addEventListener('DOMContentLoaded', syncSystemVersionLabels);
    } else {
      syncSystemVersionLabels();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
