(function (global) {
  'use strict';

  var CHART_URL = 'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js';
  var _loadPromise = null;

  function ensureChartLoaded() {
    if (typeof global.Chart !== 'undefined') return Promise.resolve();
    if (_loadPromise) return _loadPromise;
    _loadPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = CHART_URL;
      s.async = true;
      s.crossOrigin = 'anonymous';
      s.onload = function () {
        if (typeof global.Chart !== 'undefined') resolve();
        else { _loadPromise = null; reject(new Error('chart_load_failed')); }
      };
      s.onerror = function () { _loadPromise = null; reject(new Error('chart_load_failed')); };
      document.head.appendChild(s);
    });
    return _loadPromise;
  }

  global.ensureChartLoaded = ensureChartLoaded;
})(typeof window !== 'undefined' ? window : globalThis);
