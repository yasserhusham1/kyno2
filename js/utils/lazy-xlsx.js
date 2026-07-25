(function (global) {
  'use strict';

  var XLSX_URL = 'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js';
  var _loadPromise = null;

  function ensureXlsxLoaded() {
    if (typeof global.XLSX !== 'undefined') return Promise.resolve();
    if (_loadPromise) return _loadPromise;
    _loadPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = XLSX_URL;
      s.async = true;
      s.onload = function () {
        if (typeof global.XLSX !== 'undefined') resolve();
        else { _loadPromise = null; reject(new Error('xlsx_load_failed')); }
      };
      s.onerror = function () { _loadPromise = null; reject(new Error('xlsx_load_failed')); };
      document.head.appendChild(s);
    });
    return _loadPromise;
  }

  global.ensureXlsxLoaded = ensureXlsxLoaded;
})(typeof window !== 'undefined' ? window : globalThis);
