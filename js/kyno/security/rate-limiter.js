/**
 * KYNO client rate limiter (UI layer — server still enforces login_attempts)
 */
(function (global) {
  'use strict';

  function RateLimiter(maxAttempts, windowMs) {
    this.maxAttempts = maxAttempts || 5;
    this.windowMs = windowMs || 15 * 60 * 1000;
    this.attempts = new Map();
  }

  RateLimiter.prototype.isAllowed = function (key) {
    var k = String(key || '').toLowerCase();
    var now = Date.now();
    var list = (this.attempts.get(k) || []).filter(function (t) { return now - t < this.windowMs; }.bind(this));
    if (list.length >= this.maxAttempts) {
      var oldest = Math.min.apply(null, list);
      return { allowed: false, retryAfterSec: Math.ceil((oldest + this.windowMs - now) / 1000) };
    }
    list.push(now);
    this.attempts.set(k, list);
    return { allowed: true, remaining: this.maxAttempts - list.length };
  };

  RateLimiter.prototype.reset = function (key) {
    this.attempts.delete(String(key || '').toLowerCase());
  };

  var RateLimiters = {
    login: new RateLimiter(8, 15 * 60 * 1000)
  };

  function checkRateLimit(name, key) {
    var lim = RateLimiters[name];
    if (!lim) return { allowed: true };
    var r = lim.isAllowed(key);
    if (!r.allowed) {
      var err = new Error('rate_limited');
      err.code = 'RATE_LIMIT_EXCEEDED';
      err.retryAfter = r.retryAfterSec;
      throw err;
    }
    return r;
  }

  function startRateLimiterCleanup(intervalMs) {
    return setInterval(function () {
      Object.keys(RateLimiters).forEach(function (name) {
        var lim = RateLimiters[name];
        var now = Date.now();
        lim.attempts.forEach(function (list, key) {
          var recent = list.filter(function (t) { return now - t < lim.windowMs; });
          if (recent.length) lim.attempts.set(key, recent);
          else lim.attempts.delete(key);
        });
      });
    }, intervalMs || 5 * 60 * 1000);
  }

  global.KynoRateLimiter = {
    RateLimiter: RateLimiter,
    RateLimiters: RateLimiters,
    checkRateLimit: checkRateLimit,
    startRateLimiterCleanup: startRateLimiterCleanup
  };
})(typeof window !== 'undefined' ? window : globalThis);
