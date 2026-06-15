/**
 * XSS guard — sanitize all innerHTML assignments
 */
(function (global) {
  'use strict';

  var FORBID_TAGS = /<\/?(?:script|iframe|object|embed|form|meta|link|base|svg|math)\b[^>]*>/gi;
  var FORBID_ATTR = /\s(on\w+|formaction|xmlns|xlink:href)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi;
  var FORBID_URL = /(?:href|src|action)\s*=\s*("|')\s*javascript:/gi;

  function sanitizeHtml(html) {
    if (html == null) return '';
    var s = String(html);
    s = s.replace(FORBID_TAGS, '');
    s = s.replace(FORBID_ATTR, '');
    s = s.replace(FORBID_URL, '');
    return s;
  }

  function setInner(el, html) {
    if (!el) return;
    el.innerHTML = html == null ? '' : String(html);
  }

  function patchInnerHtml() {
    if (typeof Element === 'undefined' || Element.prototype.__kynoHtmlPatched) return;
    var desc = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
    if (!desc || typeof desc.set !== 'function') return;
    var nativeSet = desc.set;
    var nativeGet = desc.get;
    Object.defineProperty(Element.prototype, 'innerHTML', {
      configurable: true,
      enumerable: desc.enumerable,
      get: function () { return nativeGet.call(this); },
      set: function (val) {
        if (this.dataset && this.dataset.basmaTrusted === '1') {
          nativeSet.call(this, val == null ? '' : String(val));
          return;
        }
        nativeSet.call(this, sanitizeHtml(val));
      }
    });
    Element.prototype.__kynoHtmlPatched = true;
  }

  patchInnerHtml();

  if (global.BasmaSecurity) {
    global.BasmaSecurity.sanitizeHtml = sanitizeHtml;
    global.BasmaSecurity.setHtml = function (el, html) {
      setInner(el, sanitizeHtml(html));
    };
    global.BasmaSecurity.setTrustedHtml = function (el, html) {
      setInner(el, sanitizeHtml(html));
    };
    global.BasmaSecurity.setSafeHtml = global.BasmaSecurity.setHtml;
  }

  global.KynoSanitize = { sanitizeHtml: sanitizeHtml, patchInnerHtml: patchInnerHtml };
})(typeof window !== 'undefined' ? window : globalThis);
