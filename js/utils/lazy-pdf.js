(function (global) {
  'use strict';

  var HTML2CANVAS_URL = 'https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js';
  var JSPDF_URL = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js';
  var _loadPromise = null;

  function pdfLibsReady() {
    return typeof global.html2canvas === 'function'
      && global.jspdf
      && global.jspdf.jsPDF;
  }

  function loadScript(url) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = url;
      s.async = true;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('pdf_lib_load_failed')); };
      document.head.appendChild(s);
    });
  }

  function ensurePdfLibsLoaded() {
    if (pdfLibsReady()) return Promise.resolve();
    if (_loadPromise) return _loadPromise;
    _loadPromise = Promise.all([
      typeof global.html2canvas === 'function' ? Promise.resolve() : loadScript(HTML2CANVAS_URL),
      (global.jspdf && global.jspdf.jsPDF) ? Promise.resolve() : loadScript(JSPDF_URL)
    ]).then(function () {
      if (!pdfLibsReady()) {
        _loadPromise = null;
        throw new Error('pdf_libs_load_failed');
      }
    }).catch(function (e) {
      _loadPromise = null;
      throw e;
    });
    return _loadPromise;
  }

  global.ensurePdfLibsLoaded = ensurePdfLibsLoaded;
})(typeof window !== 'undefined' ? window : globalThis);
