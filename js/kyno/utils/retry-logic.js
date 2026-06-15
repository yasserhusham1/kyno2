/**
 * KYNO — retry with exponential backoff (browser)
 */
(function (global) {
  'use strict';

  function defaultShouldRetry(error) {
    if (!error) return true;
    var code = error.code || error.status;
    if (code === 401 || code === 403 || code === 400 || code === 404) return false;
    if (code === 'AUTH_ERROR' || code === 'VALIDATION_ERROR') return false;
    var msg = String(error.message || error).toLowerCase();
    if (msg.indexOf('failed to fetch') >= 0 || msg.indexOf('network') >= 0) return true;
    if (typeof code === 'number' && code >= 500) return true;
    return error.name === 'TypeError';
  }

  function sleep(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  async function executeWithTimeout(fn, timeoutMs) {
    var ms = timeoutMs || 30000;
    return Promise.race([
      Promise.resolve(typeof fn === 'function' ? fn() : fn),
      new Promise(function (_, reject) {
        setTimeout(function () { reject(new Error('timeout_' + ms)); }, ms);
      })
    ]);
  }

  async function retryWithBackoff(fn, options) {
    options = options || {};
    var maxRetries = options.maxRetries != null ? options.maxRetries : 3;
    var delay = options.initialDelayMs != null ? options.initialDelayMs : 400;
    var maxDelay = options.maxDelayMs != null ? options.maxDelayMs : 12000;
    var mult = options.backoffMultiplier != null ? options.backoffMultiplier : 2;
    var shouldRetry = options.shouldRetry || defaultShouldRetry;
    var onRetry = options.onRetry || null;
    var timeout = options.timeout != null ? options.timeout : 45000;
    var lastErr;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        return await executeWithTimeout(fn, timeout);
      } catch (err) {
        lastErr = err;
        if (attempt >= maxRetries || !shouldRetry(err)) throw err;
        var jitter = Math.random() * 0.1 * delay;
        var nextDelay = Math.min(delay * mult + jitter, maxDelay);
        if (onRetry) onRetry({ attempt: attempt + 1, maxRetries: maxRetries, nextDelay: nextDelay, error: err });
        await sleep(nextDelay);
        delay = nextDelay;
      }
    }
    throw lastErr;
  }

  global.KynoRetry = {
    retryWithBackoff: retryWithBackoff,
    executeWithTimeout: executeWithTimeout,
    defaultShouldRetry: defaultShouldRetry
  };
})(typeof window !== 'undefined' ? window : globalThis);
