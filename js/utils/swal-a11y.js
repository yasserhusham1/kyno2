/**
 * إصلاح تحذير aria-hidden: نقل التركيز من #app قبل إخفائه عند فتح SweetAlert2
 */
(function (global) {
  'use strict';

  if (!global.Swal || global.Swal.__basmaA11yPatched) return;

  function isInsideAriaHiddenApp(el) {
    var node = el;
    while (node) {
      if (node.id === 'app' && node.getAttribute('aria-hidden') === 'true') return true;
      node = node.parentElement;
    }
    return false;
  }

  function blurFocusedAppControl() {
    try {
      var active = document.activeElement;
      if (!active || active === document.body || active === document.documentElement) return;
      var app = document.getElementById('app');
      if (!app || !app.contains(active)) return;
      if (typeof active.blur === 'function') active.blur();
    } catch (e) { /* ignore */ }
  }

  function focusSwalPopup(popup) {
    var root = popup || (global.Swal.getPopup && global.Swal.getPopup());
    if (!root) return;
    global.requestAnimationFrame(function () {
      if (isInsideAriaHiddenApp(document.activeElement)) blurFocusedAppControl();
      var target = root.querySelector(
        'button.swal2-confirm:not([disabled]), button.swal2-deny:not([disabled]), ' +
        'button.swal2-cancel:not([disabled]), input.swal2-input:not([disabled]), ' +
        'textarea.swal2-textarea:not([disabled]), select.swal2-select:not([disabled])'
      ) || root.querySelector('.swal2-popup');
      if (target && typeof target.focus === 'function') {
        try { target.focus({ preventScroll: true }); } catch (err) { target.focus(); }
      }
    });
  }

  function patchSwalOptions(opts) {
    if (!opts || typeof opts !== 'object' || Array.isArray(opts)) return opts;
    var userWillOpen = opts.willOpen;
    var userDidOpen = opts.didOpen;
    opts.willOpen = function () {
      blurFocusedAppControl();
      if (typeof userWillOpen === 'function') userWillOpen();
    };
    opts.didOpen = function (popup) {
      focusSwalPopup(popup);
      if (typeof userDidOpen === 'function') userDidOpen(popup);
    };
    return opts;
  }

  var origFire = global.Swal.fire.bind(global.Swal);
  global.Swal.fire = function (opts) {
    if (arguments.length === 0) return origFire();
    if (arguments.length === 1 && typeof opts === 'object' && !Array.isArray(opts)) {
      return origFire(patchSwalOptions(Object.assign({}, opts)));
    }
    return origFire.apply(global.Swal, arguments);
  };

  global.Swal.__basmaA11yPatched = true;
  global.basmaFocusSwalPopup = focusSwalPopup;
})(typeof window !== 'undefined' ? window : globalThis);
