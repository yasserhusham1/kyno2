/**
 * KynoLoader — مؤشر تحميل احترافي مع شريط تقدم وعداد زمن فعلي
 * يدعم عمليات متوازية مع تتبع كل عملية بشكل مستقل
 */
(function (global) {
  'use strict';

  var _container = null;
  var _ops = {};
  var _nextId = 0;

  // ─── ألوان وأيقونات حسب الحالة ───────────────────────────
  var COLORS = {
    loading: '#63b3ed',
    success: '#68d391',
    error:   '#fc8181',
    warn:    '#f6ad55'
  };

  // ─── إنشاء حاوية الجذر ───────────────────────────────────
  function _ensureContainer() {
    if (_container && document.body.contains(_container)) return _container;
    _container = document.createElement('div');
    _container.id = 'kyno-loader-root';
    _container.style.cssText = [
      'position:fixed',
      'bottom:24px',
      'right:24px',
      'z-index:999990',
      'display:flex',
      'flex-direction:column-reverse',
      'gap:8px',
      'pointer-events:none',
      'max-width:340px',
      'width:calc(100vw - 48px)'
    ].join(';');
    document.body.appendChild(_container);
    return _container;
  }

  // ─── إنشاء HTML لبطاقة العملية ───────────────────────────
  function _createCard(id, label, color) {
    var el = document.createElement('div');
    el.id   = 'kyno-op-' + id;
    el.setAttribute('role', 'status');
    el.style.cssText = [
      'pointer-events:auto',
      'background:linear-gradient(135deg,rgba(26,32,44,0.97),rgba(17,24,39,0.97))',
      'backdrop-filter:blur(12px)',
      '-webkit-backdrop-filter:blur(12px)',
      'border:1px solid rgba(255,255,255,0.08)',
      'border-left:3px solid ' + color,
      'border-radius:14px',
      'padding:12px 14px 10px',
      'box-shadow:0 8px 32px rgba(0,0,0,0.45),0 2px 8px rgba(0,0,0,0.3)',
      'direction:rtl',
      'animation:kynoSlideIn 0.3s cubic-bezier(0.34,1.56,0.64,1)',
      'transition:border-left-color 0.4s,opacity 0.4s,transform 0.4s',
      'will-change:transform,opacity',
      'min-width:240px'
    ].join(';');

    el.innerHTML =
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px">' +
        '<div class="kyno-spinner" id="kyno-ico-' + id + '" style="' +
          'width:18px;height:18px;border-radius:50%;flex-shrink:0;' +
          'border:2.5px solid rgba(255,255,255,0.15);' +
          'border-top-color:' + color + ';' +
          'animation:kynoSpin 0.7s linear infinite;' +
          'transition:border-color 0.4s,border-top-color 0.4s' +
        '"></div>' +
        '<span id="kyno-lbl-' + id + '" style="' +
          'flex:1;font-size:13px;font-weight:600;color:#e2e8f0;' +
          'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;' +
          'font-family:Cairo,Tajawal,sans-serif' +
        '">' + _esc(label) + '</span>' +
        '<span id="kyno-tm-' + id + '" style="' +
          'font-size:11px;color:rgba(255,255,255,0.45);' +
          'font-variant-numeric:tabular-nums;' +
          'font-family:monospace;letter-spacing:0.5px' +
        '">0.0ث</span>' +
        '<button id="kyno-close-' + id + '" title="إغلاق" style="' +
          'background:none;border:none;cursor:pointer;padding:0 0 0 4px;' +
          'color:rgba(255,255,255,0.35);font-size:16px;line-height:1;' +
          'transition:color 0.2s;flex-shrink:0;' +
        '" onclick="(function(){' +
          'var c=document.getElementById(\'kyno-op-' + id + '\');' +
          'if(c){c.style.opacity=\'0\';c.style.transform=\'translateX(24px) scale(0.96)\';' +
          'setTimeout(function(){if(c.parentNode)c.remove();},380);}' +
        '})()" onmouseenter="this.style.color=\'rgba(255,255,255,0.75)\'" onmouseleave="this.style.color=\'rgba(255,255,255,0.35)\'">&#10005;</button>' +
      '</div>' +
      '<div style="position:relative;height:4px;background:rgba(255,255,255,0.08);border-radius:4px;overflow:hidden">' +
        '<div id="kyno-bar-' + id + '" style="' +
          'position:absolute;inset:0;right:auto;' +
          'width:0%;height:100%;border-radius:4px;' +
          'background:linear-gradient(90deg,' + color + ',' + color + 'cc);' +
          'transition:width 0.15s ease,background 0.4s;' +
          'box-shadow:0 0 8px ' + color + '88' +
        '"></div>' +
        '<div style="' +
          'position:absolute;inset:0;' +
          'background:linear-gradient(90deg,transparent 0%,rgba(255,255,255,0.12) 50%,transparent 100%);' +
          'animation:kynoShimmer 1.5s infinite;opacity:0.6' +
        '"></div>' +
      '</div>';

    return el;
  }

  // ─── بدء عملية ───────────────────────────────────────────
  function start(label, options) {
    options = options || {};
    var id        = 'lo' + (++_nextId);
    var color     = COLORS[options.type || 'loading'];
    var startTime = Date.now();
    var progress  = 0;

    _ensureContainer();
    var el = _createCard(id, label, color);
    _container.appendChild(el);
    _container.style.opacity = '1';

    // عداد الزمن الفعلي + محاكاة شريط التقدم
    var barEl = document.getElementById('kyno-bar-' + id);
    var tmEl  = document.getElementById('kyno-tm-' + id);

    var tick = setInterval(function () {
      var ms      = Date.now() - startTime;
      var secs    = (ms / 1000).toFixed(1);
      if (tmEl) tmEl.textContent = secs + 'ث';

      // خوارزمية شريط التقدم: ينمو بسرعة ثم يبطئ عند 80%
      var target = 80;
      if (ms < 500)        target = 40;
      else if (ms < 1500)  target = 65;
      else if (ms < 4000)  target = 80;
      else                 target = 88;

      progress += (target - progress) * 0.08;
      if (barEl) barEl.style.width = Math.min(progress, 89) + '%';
    }, 80);

    _ops[id] = { el: el, startTime: startTime, tick: tick, label: label };
    return id;
  }

  // ─── إنهاء عملية ─────────────────────────────────────────
  function done(id, result, resultLabel) {
    var op = _ops[id];
    if (!op) return;

    clearInterval(op.tick);

    var ms    = Date.now() - op.startTime;
    var secs  = (ms / 1000).toFixed(2);
    var isErr = result === 'error';
    var color = isErr ? COLORS.error : COLORS.success;

    var barEl = document.getElementById('kyno-bar-' + id);
    var icoEl = document.getElementById('kyno-ico-' + id);
    var tmEl  = document.getElementById('kyno-tm-' + id);
    var lblEl = document.getElementById('kyno-lbl-' + id);
    var card  = op.el;

    // أكمل الشريط إلى 100%
    if (barEl) {
      barEl.style.transition = 'width 0.35s cubic-bezier(0.4,0,0.2,1),background 0.35s';
      barEl.style.width = '100%';
      barEl.style.background = 'linear-gradient(90deg,' + color + ',' + color + 'bb)';
      barEl.style.boxShadow = '0 0 10px ' + color + '99';
    }

    // أوقف دوران الأيقونة واستبدلها
    if (icoEl) {
      icoEl.style.animation = 'none';
      icoEl.style.border = '2.5px solid ' + color;
      icoEl.innerHTML = '<svg viewBox="0 0 16 16" width="10" height="10" fill="' + color + '">' +
        (isErr
          ? '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm3.3 9.7L9.4 8.9a2 2 0 000-1.8l1.9-1.8-.7-.7-1.8 1.9a2 2 0 00-1.6 0L5.3 4.6l-.7.7 1.9 1.8a2 2 0 000 1.6L4.6 10.7l.7.7 1.8-1.9a2 2 0 001.6 0l1.9 1.9.7-.7z"/>'
          : '<path d="M6.5 11.5L2 7l1.4-1.4L6.5 8.7l6.1-6.2L14 4z"/>'
        ) + '</svg>';
      icoEl.style.display = 'flex';
      icoEl.style.alignItems = 'center';
      icoEl.style.justifyContent = 'center';
    }

    // حدّث العنوان والوقت وزر الإغلاق
    if (tmEl)  tmEl.textContent  = secs + 'ث';
    if (tmEl)  tmEl.style.color  = color;
    if (lblEl && resultLabel) lblEl.textContent = resultLabel;
    if (card)  card.style.borderLeftColor = color;
    var closeEl = document.getElementById('kyno-close-' + id);
    if (closeEl) closeEl.style.color = color + 'bb';

    // اختفاء بعد 2 ثانية
    setTimeout(function () {
      if (!card) return;
      card.style.opacity = '0';
      card.style.transform = 'translateX(24px) scale(0.96)';
      setTimeout(function () {
        if (card.parentNode) card.remove();
        delete _ops[id];
      }, 420);
    }, 2000);
  }

  // ─── تحديث عنوان العملية ─────────────────────────────────
  function update(id, newLabel) {
    var op = _ops[id];
    if (!op) return;
    var lblEl = document.getElementById('kyno-lbl-' + id);
    if (lblEl) lblEl.textContent = newLabel;
    op.label = newLabel;
  }

  // ─── تسهيل: عملية تلقائية حول promise ───────────────────
  function wrap(label, promise, options) {
    var id = start(label, options);
    return promise
      .then(function (res) {
        done(id, 'success', (options && options.successLabel) || label + ' ✓');
        return res;
      })
      .catch(function (err) {
        done(id, 'error', (options && options.errorLabel) || 'فشل: ' + label);
        throw err;
      });
  }

  // ─── مساعد إفلات ─────────────────────────────────────────
  function _esc(s) {
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  // ─── حقن CSS الأنيميشن ───────────────────────────────────
  function _injectStyles() {
    if (document.getElementById('kyno-loader-styles')) return;
    var s = document.createElement('style');
    s.id = 'kyno-loader-styles';
    s.textContent = [
      '@keyframes kynoSlideIn{from{opacity:0;transform:translateX(32px) scale(0.93)}to{opacity:1;transform:translateX(0) scale(1)}}',
      '@keyframes kynoSpin{to{transform:rotate(360deg)}}',
      '@keyframes kynoShimmer{0%{transform:translateX(-100%)}100%{transform:translateX(200%)}}'
    ].join('');
    document.head.appendChild(s);
  }

  // تشغيل الأنيميشن عند تحميل الصفحة
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', _injectStyles);
    } else {
      _injectStyles();
    }
  }

  global.KynoLoader = { start: start, done: done, update: update, wrap: wrap };

})(typeof window !== 'undefined' ? window : globalThis);
