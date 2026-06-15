/**
 * Security utilities — XSS prevention, input sanitization
 */
(function (global) {
  'use strict';

  var HTML_ESCAPE = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return HTML_ESCAPE[c] || c;
    });
  }

  /** Whitelist CSS class from a known map — prevents class injection */
  function escClass(value, allowedMap, fallback) {
    var key = String(value == null ? '' : value);
    if (allowedMap && Object.prototype.hasOwnProperty.call(allowedMap, key)) {
      return allowedMap[key];
    }
    return fallback || 'badge-secondary';
  }

  function escAttr(value) {
    return escapeHtml(value).replace(/`/g, '&#96;');
  }

  function sanitizeText(value, maxLen) {
    var s = String(value == null ? '' : value)
      .replace(/[\0\x08\x0B\x0C\x0E-\x1F]/g, '')
      .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
      .trim();
    if (maxLen && s.length > maxLen) s = s.slice(0, maxLen);
    return s;
  }

  function sanitizeUsername(value) {
    return sanitizeText(value, 64).replace(/[^\w.@+-]/g, '').toLowerCase();
  }

  function sanitizePhone(value) {
    return sanitizeText(value, 24).replace(/[^\d+\-\s()]/g, '');
  }

  function sanitizeFilename(name) {
    return sanitizeText(name, 120).replace(/[\\/:*?"<>|]/g, '_') || 'file';
  }

  /** Set text safely */
  function setText(el, value) {
    if (!el) return;
    el.textContent = value == null ? '' : String(value);
  }

  /** Only for static trusted HTML templates built with escapeHtml on all dynamic parts */
  function setTrustedHtml(el, html) {
    if (!el) return;
    el.innerHTML = html;
  }

  function safeHtml(value) {
    return escapeHtml(value);
  }

  function setHtml(el, html) {
    if (!el) return;
    el.innerHTML = html == null ? '' : String(html);
  }

  function setSafeHtml(el, html) {
    setHtml(el, html);
  }

  function validateUpload(file, opts) {
    opts = opts || {};
    if (!file || !file.type) return { ok: false, error: 'ملف غير صالح' };
    var max = opts.maxBytes || (global.BasmaConfig && BasmaConfig.maxUploadBytes()) || 2097152;
    var allowed = opts.allowedMime || (global.BasmaConfig && BasmaConfig.allowedUploadMime()) || ['image/jpeg', 'image/png', 'image/webp'];
    if (file.size > max) return { ok: false, error: 'حجم الملف كبير جداً' };
    if (allowed.indexOf(file.type) < 0) return { ok: false, error: 'نوع الملف غير مسموح' };
    var ext = (file.name || '').split('.').pop().toLowerCase();
    if (['exe', 'bat', 'cmd', 'sh', 'js', 'html', 'php'].indexOf(ext) >= 0) {
      return { ok: false, error: 'نوع الملف محظور' };
    }
    return { ok: true };
  }

  global.BasmaSecurity = {
    escapeHtml: escapeHtml,
    escClass: escClass,
    escAttr: escAttr,
    safeHtml: safeHtml,
    setHtml: setHtml,
    setSafeHtml: setSafeHtml,
    sanitizeText: sanitizeText,
    sanitizeUsername: sanitizeUsername,
    sanitizePhone: sanitizePhone,
    sanitizeFilename: sanitizeFilename,
    setText: setText,
    setTrustedHtml: setTrustedHtml,
    validateUpload: validateUpload
  };
})(typeof window !== 'undefined' ? window : globalThis);
