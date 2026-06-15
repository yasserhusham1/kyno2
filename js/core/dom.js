/**
 * Safe DOM builders — reduce XSS from innerHTML
 */
(function (global) {
  'use strict';

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'className') node.className = attrs[k];
        else if (k === 'text') node.textContent = attrs[k];
        else if (k === 'html') node.innerHTML = attrs[k];
        else if (k.startsWith('on')) { /* skip inline handlers */ }
        else node.setAttribute(k, attrs[k]);
      });
    }
    (children || []).forEach(function (c) {
      if (c == null) return;
      if (typeof c === 'string') node.appendChild(document.createTextNode(c));
      else node.appendChild(c);
    });
    return node;
  }

  function clear(el) {
    if (!el) return;
    while (el.firstChild) el.removeChild(el.firstChild);
  }

  function setSafeHtml(el, html) {
    if (!el) return;
    if (global.BasmaSecurity) BasmaSecurity.setTrustedHtml(el, html);
    else el.innerHTML = html;
  }

  function setText(el, text) {
    if (!el) return;
    if (global.BasmaSecurity) BasmaSecurity.setText(el, text);
    else el.textContent = text == null ? '' : String(text);
  }

  function renderRows(tbody, rowsHtml, emptyHtml) {
    if (!tbody) return;
    if (!rowsHtml) setSafeHtml(tbody, emptyHtml || '');
    else setSafeHtml(tbody, rowsHtml);
  }

  global.BasmaDom = { el: el, clear: clear, setSafeHtml: setSafeHtml, setText: setText, renderRows: renderRows };
})(typeof window !== 'undefined' ? window : globalThis);
