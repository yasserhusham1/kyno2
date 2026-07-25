(function (global) {
  'use strict';

  var QRCODE_URL = 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js';
  var _loadPromise = null;

  function qrcodeReady() {
    return typeof global.QRCode !== 'undefined' && global.QRCode && global.QRCode.CorrectLevel;
  }

  function ensureQrcodeLoaded() {
    if (qrcodeReady()) return Promise.resolve();
    if (_loadPromise) return _loadPromise;
    _loadPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = QRCODE_URL;
      s.async = true;
      s.crossOrigin = 'anonymous';
      s.onload = function () {
        if (qrcodeReady()) resolve();
        else { _loadPromise = null; reject(new Error('qrcode_load_failed')); }
      };
      s.onerror = function () { _loadPromise = null; reject(new Error('qrcode_load_failed')); };
      document.head.appendChild(s);
    });
    return _loadPromise;
  }

  global.ensureQrcodeLoaded = ensureQrcodeLoaded;
})(typeof window !== 'undefined' ? window : globalThis);
