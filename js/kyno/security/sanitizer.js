/**
 * KYNO sanitizer — extends BasmaSecurity (no duplicate XSS logic)
 */
(function (global) {
  'use strict';

  function base() {
    return global.BasmaSecurity || null;
  }

  function escapeHtml(v) {
    var b = base();
    return b && b.escapeHtml ? b.escapeHtml(v) : String(v == null ? '' : v);
  }

  function sanitizeString(str, options) {
    options = options || {};
    var b = base();
    var s = b && b.sanitizeText
      ? b.sanitizeText(str, options.maxLength || 500)
      : String(str || '').trim();
    if (options.toLowerCase) s = s.toLowerCase();
    return s;
  }

  global.KynoSanitizer = {
    escapeHtml: escapeHtml,
    sanitizeString: sanitizeString,
    sanitizeUsername: function (v) {
      var b = base();
      return b && b.sanitizeUsername ? b.sanitizeUsername(v) : sanitizeString(v, { maxLength: 64, toLowerCase: true });
    },
    sanitizePhone: function (v) {
      var b = base();
      return b && b.sanitizePhone ? b.sanitizePhone(v) : String(v || '').replace(/\D/g, '');
    }
  };
})(typeof window !== 'undefined' ? window : globalThis);
