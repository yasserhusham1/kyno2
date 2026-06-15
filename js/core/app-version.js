/**
 * إصدار التطبيق — Semantic Versioning (SemVer 2.0)
 * MAJOR.MINOR.PATCH — الإصدار الأول: 1.0.0
 */
(function (global) {
  'use strict';

  var VERSION = '1.0.0';
  var parts = VERSION.split('.').map(function (n) { return parseInt(n, 10) || 0; });

  global.BasmaApp = Object.freeze({
    name: 'KYNO Basma',
    product: 'بصمة KYNO',
    version: VERSION,
    versionLabel: 'v' + VERSION,
    semver: {
      major: parts[0],
      minor: parts[1],
      patch: parts[2]
    }
  });
})(typeof window !== 'undefined' ? window : globalThis);
