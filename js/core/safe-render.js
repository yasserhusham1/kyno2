/**
 * Safe HTML rendering — ES module + window.BasmaSafe
 */
export function escapeHtml(value) {
  if (typeof window !== 'undefined' && window.BasmaSecurity && BasmaSecurity.escapeHtml) {
    return BasmaSecurity.escapeHtml(value);
  }
  const s = String(value == null ? '' : value);
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function setElementHtml(el, html) {
  if (!el) return;
  if (typeof window !== 'undefined' && window.BasmaDom && BasmaDom.setSafeHtml) {
    BasmaDom.setSafeHtml(el, html);
  } else {
    el.innerHTML = html;
  }
}

export function escAttr(value) {
  return escapeHtml(value).replace(/`/g, '&#96;');
}

if (typeof window !== 'undefined') {
  window.BasmaSafe = Object.assign(window.BasmaSafe || {}, {
    escapeHtml,
    setElementHtml,
    escAttr
  });
}
