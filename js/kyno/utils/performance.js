/**
 * KYNO — debounce / throttle
 */
(function (global) {
  'use strict';

  function debounce(fn, waitMs) {
    var t;
    return function () {
      var ctx = this;
      var args = arguments;
      clearTimeout(t);
      t = setTimeout(function () { fn.apply(ctx, args); }, waitMs || 200);
    };
  }

  function throttle(fn, waitMs) {
    var last = 0;
    var pending = null;
    return function () {
      var ctx = this;
      var args = arguments;
      var now = Date.now();
      var run = function () {
        last = Date.now();
        fn.apply(ctx, args);
      };
      if (now - last >= (waitMs || 200)) run();
      else {
        clearTimeout(pending);
        pending = setTimeout(run, (waitMs || 200) - (now - last));
      }
    };
  }

  global.KynoPerf = { debounce: debounce, throttle: throttle };
})(typeof window !== 'undefined' ? window : globalThis);
