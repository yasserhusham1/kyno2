(function (global) {
  'use strict';

  var LEAFLET_CSS = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
  var LEAFLET_JS = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
  var _loadPromise = null;

  function leafletReady() {
    return typeof global.L !== 'undefined' && global.L && typeof global.L.map === 'function';
  }

  function loadStylesheet(url) {
    return new Promise(function (resolve, reject) {
      if (document.querySelector('link[href="' + url + '"]')) {
        resolve();
        return;
      }
      var link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = url;
      link.onload = function () { resolve(); };
      link.onerror = function () { reject(new Error('leaflet_css_load_failed')); };
      document.head.appendChild(link);
    });
  }

  function loadScript(url) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = url;
      s.async = true;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('leaflet_js_load_failed')); };
      document.head.appendChild(s);
    });
  }

  function ensureLeafletLoaded() {
    if (leafletReady()) return Promise.resolve();
    if (_loadPromise) return _loadPromise;
    _loadPromise = loadStylesheet(LEAFLET_CSS)
      .then(function () {
        return leafletReady() ? Promise.resolve() : loadScript(LEAFLET_JS);
      })
      .then(function () {
        if (!leafletReady()) {
          _loadPromise = null;
          throw new Error('leaflet_load_failed');
        }
      })
      .catch(function (e) {
        _loadPromise = null;
        throw e;
      });
    return _loadPromise;
  }

  global.ensureLeafletLoaded = ensureLeafletLoaded;
})(typeof window !== 'undefined' ? window : globalThis);
