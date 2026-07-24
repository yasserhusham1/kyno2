/**

 * Toast notifications

 */

(function (global) {

  'use strict';



  var container = null;



  function ensureContainer() {

    if (container) return container;

    container = document.createElement('div');

    container.id = 'basma-toast-root';

    container.setAttribute('aria-live', 'polite');

    container.style.cssText = 'position:fixed;bottom:20px;left:20px;z-index:99999;display:flex;flex-direction:column;align-items:flex-start;gap:8px;pointer-events:none;max-width:min(92vw,420px);margin:0';

    document.body.appendChild(container);

    return container;

  }



  function dismissToastEl(el, onDismiss) {

    if (!el || el.dataset.dismissed === '1') return;

    el.dataset.dismissed = '1';

    el.style.opacity = '0';

    el.style.transition = 'opacity .3s';

    setTimeout(function () {

      if (el.parentNode) el.remove();

      if (typeof onDismiss === 'function') onDismiss();

    }, 320);

  }



  function show(message, type, duration, options) {

    if (!message) return;

    options = options || {};

    var root = options.center ? document.body : ensureContainer();

    var el = document.createElement('div');

    var colors = { success: '#38a169', error: '#e53e3e', warn: '#d69e2e', info: '#3182ce' };

    el.className = 'basma-toast basma-toast-' + (type || 'info') + (options.center ? ' basma-toast-center' : '');

    if (options.dismissible) el.classList.add('basma-toast-dismissible');



    var baseStyle = 'pointer-events:auto;padding:12px 16px;border-radius:12px;color:#fff;font-size:14px;box-shadow:0 8px 24px rgba(0,0,0,0.35);background:' + (colors[type] || colors.info) + ';animation:basmaToastIn .25s ease';

    if (options.center) {

      baseStyle += ';position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);z-index:100001;min-width:min(92vw,420px);max-width:92vw;text-align:center;line-height:1.7';

    }

    el.style.cssText = baseStyle;



    var textEl = document.createElement('div');

    textEl.className = 'basma-toast-text';

    if (global.BasmaSecurity) BasmaSecurity.setText(textEl, message);

    else textEl.textContent = message;

    el.appendChild(textEl);



    var onDismiss = options.onDismiss;

    var timer = null;



    function closeToast() {

      if (timer) {

        clearTimeout(timer);

        timer = null;

      }

      dismissToastEl(el, onDismiss);

    }



    if (options.dismissible) {

      var closeBtn = document.createElement('button');

      closeBtn.type = 'button';

      closeBtn.className = 'basma-toast-close';

      closeBtn.setAttribute('aria-label', 'إغلاق');

      closeBtn.innerHTML = '&times;';

      closeBtn.addEventListener('click', function (ev) {

        ev.stopPropagation();

        closeToast();

      });

      el.appendChild(closeBtn);

    }



    root.appendChild(el);



    if (duration && duration > 0) {

      timer = setTimeout(closeToast, duration);

    }

  }



  function dismissAll() {

    if (container) container.innerHTML = '';

    document.querySelectorAll('.basma-toast-center').forEach(function (el) { el.remove(); });

  }



  global.BasmaToast = {

    show: show,

    success: function (m, d, o) { show(m, 'success', d, o); },

    error: function (m, d, o) { show(m, 'error', d, o); },

    warn: function (m, d, o) { show(m, 'warn', d, o); },

    info: function (m, d, o) { show(m, 'info', d, o); },

    dismissAll: dismissAll

  };

})(typeof window !== 'undefined' ? window : globalThis);


