/**
 * KYNO v2 — Unified Sanitizer
 *
 * مدمج من 4 ملفات في v1:
 *   js/core/security.js          → BasmaSecurity (XSS escaping, text sanitization)
 *   js/core/html-sanitize.js     → KynoSanitize (strip dangerous tags, innerHTML patch)
 *   js/core/safe-render.js       → escapeHtml ES module export
 *   js/kyno/security/sanitizer.js → KynoSanitizer (username, phone, string sanitizers)
 *
 * المنطق: محتفظ به كما هو — لا تعديل في Business Logic.
 * الفرق الوحيد: تحويل من IIFE + globals إلى ES module exports.
 */

'use strict';

// =============================================================================
// 1. HTML Escaping (من security.js)
// =============================================================================

const HTML_ESCAPE = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

/** يُهرّب قيمة HTML — يمنع XSS في innerHTML */
export function escapeHtml(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, (c) => HTML_ESCAPE[c] || c);
}

/** يُرجع CSS class من قائمة مسموحة فقط — يمنع class injection */
export function escClass(value, allowedMap, fallback) {
  const key = String(value == null ? '' : value);
  if (allowedMap && Object.prototype.hasOwnProperty.call(allowedMap, key)) {
    return allowedMap[key];
  }
  return fallback || 'badge-secondary';
}

/** يُهرّب HTML attribute */
export function escAttr(value) {
  return escapeHtml(value).replace(/`/g, '&#96;');
}

// =============================================================================
// 2. Text Sanitization (من security.js)
// =============================================================================

/** يُنظّف نص — يزيل control chars و script tags */
export function sanitizeText(value, maxLen) {
  let s = String(value == null ? '' : value)
    .replace(/[\0\x08\x0B\x0C\x0E-\x1F]/g, '')
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
    .trim();
  if (maxLen && s.length > maxLen) s = s.slice(0, maxLen);
  return s;
}

/** يُنظّف username — يسمح بـ word chars, dot, @, +, - فقط */
export function sanitizeUsername(value) {
  return sanitizeText(value, 64).replace(/[^\w.@+-]/g, '').toLowerCase();
}

/** يُنظّف رقم هاتف */
export function sanitizePhone(value) {
  return sanitizeText(value, 24).replace(/[^\d+\-\s()]/g, '');
}

/** يُنظّف اسم ملف */
export function sanitizeFilename(name) {
  return sanitizeText(name, 120).replace(/[\\/:*?"<>|]/g, '_') || 'file';
}

/** يُنظّف string للأغراض العامة مع خيارات */
export function sanitizeString(str, options = {}) {
  let s = sanitizeText(str, options.maxLength || 500);
  if (options.toLowerCase) s = s.toLowerCase();
  return s;
}

// =============================================================================
// 3. DOM Helpers (من security.js)
// =============================================================================

/** يُعيّن النص بأمان (textContent) */
export function setText(el, value) {
  if (!el) return;
  el.textContent = value == null ? '' : String(value);
}

/** يُعيّن HTML موثوقاً (مبني بالكامل باستخدام escapeHtml) */
export function setTrustedHtml(el, html) {
  if (!el) return;
  el.innerHTML = html;
}

/** يُعيّن innerHTML — يمر بالـ sanitizer */
export function setHtml(el, html) {
  if (!el) return;
  el.innerHTML = sanitizeHtml(html == null ? '' : String(html));
}

/** alias لـ setHtml */
export const setSafeHtml = setHtml;

// =============================================================================
// 4. File Upload Validation (من security.js)
// =============================================================================

/** يتحقق من صحة ملف مرفوع — النوع، الحجم، الامتداد */
export function validateUpload(file, opts = {}) {
  if (!file || !file.type) return { ok: false, error: 'ملف غير صالح' };
  const max = opts.maxBytes || 2097152; // 2MB default
  const allowed = opts.allowedMime || ['image/jpeg', 'image/png', 'image/webp'];
  if (file.size > max) return { ok: false, error: 'حجم الملف كبير جداً' };
  if (!allowed.includes(file.type)) return { ok: false, error: 'نوع الملف غير مسموح' };
  const ext = (file.name || '').split('.').pop().toLowerCase();
  if (['exe', 'bat', 'cmd', 'sh', 'js', 'html', 'php'].includes(ext)) {
    return { ok: false, error: 'نوع الملف محظور' };
  }
  return { ok: true };
}

// =============================================================================
// 5. HTML Stripping (من html-sanitize.js)
// =============================================================================

const FORBID_TAGS = /<\/?(?:script|iframe|object|embed|form|meta|link|base|svg|math)\b[^>]*>/gi;
const FORBID_ATTR = /\s(on\w+|formaction|xmlns|xlink:href)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi;
const FORBID_URL  = /(?:href|src|action)\s*=\s*("|')\s*javascript:/gi;

/** يُزيل العلامات والـ attributes الخطيرة من HTML string */
export function sanitizeHtml(html) {
  if (html == null) return '';
  let s = String(html);
  s = s.replace(FORBID_TAGS, '');
  s = s.replace(FORBID_ATTR, '');
  s = s.replace(FORBID_URL, '');
  return s;
}

/**
 * يُصحّح innerHTML في كل العناصر — يمر كل قيمة عبر sanitizeHtml
 * عناصر ذات data-basma-trusted="1" تتجاوز الفلتر
 */
export function patchInnerHtml() {
  if (typeof Element === 'undefined' || Element.prototype.__kynoHtmlPatched) return;
  const desc = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
  if (!desc || typeof desc.set !== 'function') return;
  const nativeSet = desc.set;
  const nativeGet = desc.get;
  Object.defineProperty(Element.prototype, 'innerHTML', {
    configurable: true,
    enumerable: desc.enumerable,
    get() { return nativeGet.call(this); },
    set(val) {
      if (this.dataset && this.dataset.basmaTrusted === '1') {
        nativeSet.call(this, val == null ? '' : String(val));
        return;
      }
      nativeSet.call(this, sanitizeHtml(val));
    },
  });
  Element.prototype.__kynoHtmlPatched = true;
}
