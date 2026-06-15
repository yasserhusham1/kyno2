/**
 * KYNO — process arrays in batches (avoid UI freeze)
 */
(function (global) {
  'use strict';

  async function processBatch(items, handler, options) {
    options = options || {};
    var size = Math.max(1, options.batchSize || 25);
    var delayMs = options.delayMs != null ? options.delayMs : 0;
    var results = [];
    for (var i = 0; i < items.length; i += size) {
      var chunk = items.slice(i, i + size);
      for (var j = 0; j < chunk.length; j++) {
        results.push(await handler(chunk[j], i + j));
      }
      if (delayMs && i + size < items.length) {
        await new Promise(function (r) { setTimeout(r, delayMs); });
      }
    }
    return results;
  }

  global.KynoBatch = { processBatch: processBatch };
})(typeof window !== 'undefined' ? window : globalThis);
