/**
 * Slide-to-Confirm للحضور والانصراف.
 *
 * الهدف: منع التسجيل بالخطأ عند الضغط أو تحديث الصفحة.
 * لا يعيد تنفيذ منطق الحضور/الانصراف — يستدعي window.checkIn / window.checkOut
 * الموجودة مسبقاً في main.js بعد تمرير كامل + نافذة تأكيد.
 *
 * الحماية:
 *  - لا يُنفَّذ شيء إلا بعد تمرير كامل (تجاوز عتبة السحب) ثم ضغط "تأكيد".
 *  - أثناء التنفيذ يُقفل السلايدر (busy) لمنع الإرسال المزدوج.
 *  - يحترم قفل الاشتراك / عدم الاتصال / الإغلاق الرسمي عبر pointer-events على الحاوية.
 */
(function () {
  'use strict';

  var THRESHOLD = 0.9; // نسبة السحب المطلوبة لاعتبار التمرير مكتملاً

  function fmtNow() {
    try {
      if (typeof window.formatDateClock === 'function') return window.formatDateClock(new Date());
    } catch (e) { /* fallback below */ }
    var d = new Date();
    var h = d.getHours();
    var m = d.getMinutes();
    var ap = h >= 12 ? 'PM' : 'AM';
    var h12 = h % 12;
    if (h12 === 0) h12 = 12;
    return (h12 < 10 ? '0' : '') + h12 + ':' + (m < 10 ? '0' : '') + m + ' ' + ap;
  }

  function theme() {
    try { if (typeof window.swalTheme === 'function') return window.swalTheme(); } catch (e) { /* ignore */ }
    return {};
  }

  function setupSlider(el) {
    if (!el || el.__slideInit) return;
    el.__slideInit = true;

    var action = el.getAttribute('data-action');
    var handle = el.querySelector('.att-slide-handle');
    var fill = el.querySelector('.att-slide-fill');
    if (!handle || !fill) return;

    var dragging = false;
    var startX = 0;
    var tx = 0;
    var maxX = 0;
    var busy = false;
    var pointerId = null;

    function computeMax() {
      maxX = Math.max(40, el.clientWidth - handle.offsetWidth - 12);
    }
    function paint(x) {
      handle.style.transform = 'translateX(' + (-x) + 'px)';
      fill.style.width = (x + handle.offsetWidth + 6) + 'px';
    }
    function clearTransition() {
      handle.style.transition = '';
      fill.style.transition = '';
    }
    function reset(animate) {
      tx = 0;
      if (animate) {
        handle.style.transition = 'transform 0.25s ease';
        fill.style.transition = 'width 0.25s ease';
        paint(0);
        setTimeout(clearTransition, 260);
      } else {
        clearTransition();
        paint(0);
      }
      el.classList.remove('dragging');
    }
    function full() {
      handle.style.transition = 'transform 0.15s ease';
      fill.style.transition = 'width 0.15s ease';
      paint(maxX);
      setTimeout(clearTransition, 160);
    }

    function isBlocked() {
      if (busy) return true;
      try {
        if (el.getAttribute('disabled') !== null || el.disabled) return true;
        var st = window.getComputedStyle(el);
        if (st && st.pointerEvents === 'none') return true;
      } catch (e) { /* ignore */ }
      return false;
    }

    function onDown(e) {
      if (isBlocked()) return;
      dragging = true;
      computeMax();
      startX = e.clientX;
      pointerId = e.pointerId;
      el.classList.add('dragging');
      clearTransition();
      try { handle.setPointerCapture(pointerId); } catch (err) { /* ignore */ }
    }
    function onMove(e) {
      if (!dragging) return;
      var dx = startX - e.clientX; // سحب لليسار = موجب (RTL)
      tx = Math.max(0, Math.min(maxX, dx));
      paint(tx);
    }
    function onUp() {
      if (!dragging) return;
      dragging = false;
      el.classList.remove('dragging');
      try { if (pointerId != null) handle.releasePointerCapture(pointerId); } catch (err) { /* ignore */ }
      if (maxX > 0 && tx / maxX >= THRESHOLD) {
        full();
        askConfirm();
      } else {
        reset(true);
      }
    }
    function onCancel() {
      dragging = false;
      reset(true);
    }

    function askConfirm() {
      if (busy) return;
      if (typeof window.Swal === 'undefined') { run(); return; }
      var isIn = action === 'checkin';
      window.Swal.fire({
        icon: 'question',
        title: isIn ? 'هل أنت متأكد من تسجيل الحضور؟' : 'هل أنت متأكد من تسجيل الانصراف؟',
        html: '<div style="font-size:13px;opacity:0.7;margin-bottom:6px">الوقت الحالي</div>' +
              '<div style="font-size:26px;font-weight:800;direction:ltr">' + fmtNow() + '</div>',
        showCancelButton: true,
        confirmButtonText: isIn ? '✅ تأكيد الحضور' : '✅ تأكيد الانصراف',
        cancelButtonText: '❌ إلغاء',
        reverseButtons: true,
        allowOutsideClick: false,
        allowEscapeKey: true,
        ...theme()
      }).then(function (res) {
        if (res && res.isConfirmed) {
          run();
        } else {
          reset(true);
        }
      });
    }

    function run() {
      if (busy) return;
      busy = true;
      el.classList.add('att-slide-busy');
      var fn = action === 'checkin' ? window.checkIn : window.checkOut;
      var done = function () {
        busy = false;
        el.classList.remove('att-slide-busy');
        reset(true);
      };
      try {
        var ret = typeof fn === 'function' ? fn() : undefined;
        if (ret && typeof ret.then === 'function') {
          ret.then(done, function (err) {
            try { console.error('[slide-confirm] attendance error', err); } catch (e) { /* ignore */ }
            done();
          });
        } else {
          done();
        }
      } catch (err) {
        try { console.error('[slide-confirm] attendance error', err); } catch (e) { /* ignore */ }
        done();
      }
    }

    handle.addEventListener('pointerdown', onDown);
    handle.addEventListener('pointermove', onMove);
    handle.addEventListener('pointerup', onUp);
    handle.addEventListener('pointercancel', onCancel);

    el.addEventListener('keydown', function (e) {
      if (isBlocked()) return;
      if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
        e.preventDefault();
        askConfirm();
      }
    });

    window.addEventListener('resize', function () {
      if (!dragging) { computeMax(); paint(tx); }
    });

    computeMax();
    paint(0);
  }

  function init() {
    setupSlider(document.getElementById('att-slide-checkin'));
    setupSlider(document.getElementById('att-slide-checkout'));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  window.initAttendanceSliders = init;
})();
