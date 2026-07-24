/**
 * حماية المغادرة + مؤشر مزامنة غير مزعج بجانب أيقونة السحابة
 */
(function (global) {
  'use strict';

  var _inited = false;

  function isEmployeePortal() {
    return global.currentUser === 'emp' && !!global.loggedInEmpId;
  }

  function getPendingCount() {
    var n = 0;
    var empId = isEmployeePortal() ? String(global.loggedInEmpId) : '';
    (global.employees || []).forEach(function (e) {
      if (!e || !e._pendingRemoteSync) return;
      if (!empId || String(e.id) === empId) n++;
    });
    (global.attData || []).forEach(function (a) {
      if (!a || !a._pendingRemoteSync) return;
      if (!empId || String(a.empId) === empId) n++;
    });
    (global.leavesData || []).forEach(function (l) {
      if (!l || !l._pendingSync) return;
      if (!empId || String(l.empId || l.employee_id) === empId) n++;
    });
    return n;
  }

  function isSyncing() {
    return !!global.__basmaBulkSyncRunning;
  }

  function isOffline() {
    if (global.BasmaCloud && global.BasmaCloud.isOnline) return !global.BasmaCloud.isOnline();
    return typeof navigator !== 'undefined' && navigator.onLine === false;
  }

  function needsCloudFlush() {
    if (isEmployeePortal()) return false;
    return false;
  }

  function shouldBlockLeave() {
    if (isSyncing()) return true;
    if (typeof global.hasPendingDataSync === 'function' && global.hasPendingDataSync()) return true;
    return needsCloudFlush();
  }

  function getStatusMessage() {
    var count = getPendingCount();
    if (isOffline()) {
      if (count > 0) return 'بدون اتصال — لا يمكن حفظ ' + count + ' تغيير حتى يعود الإنترنت';
      return 'بدون اتصال — لا يمكن جلب البيانات من السحابة';
    }
    if (isSyncing()) return 'جارٍ رفع التغييرات للسحابة…';
    if (count > 0) return count + ' تغيير ينتظر الرفع — لا تغلق النافذة الآن';
    return 'متزامن مع السحابة';
  }

  function updateSyncStatusUi() {
    var el = document.getElementById('cloud-sync-status');
    if (!el) return;

    var iconEl = el.querySelector('.cloud-sync-status-icon');
    var hintEl = el.querySelector('.cloud-sync-status-hint');
    var count = getPendingCount();
    var offline = isOffline();
    var syncing = isSyncing();
    var active = offline || syncing || count > 0 || needsCloudFlush();
    var isEmp = global.currentUser === 'emp';

    if (offline && isEmp && count <= 0 && !syncing && !needsCloudFlush()) {
      el.style.display = 'none';
      el.classList.remove('is-synced', 'is-pending', 'is-syncing', 'is-offline');
      return;
    }

    el.classList.remove('is-synced', 'is-pending', 'is-syncing', 'is-offline');
    el.style.display = active ? '' : 'none';

    if (offline && (count > 0 || syncing || needsCloudFlush())) {
      el.classList.add('is-offline');
      if (iconEl) iconEl.className = 'fa fa-wifi cloud-sync-status-icon';
      if (hintEl) hintEl.textContent = 'بدون نت';
    } else if (syncing) {
      el.classList.add('is-syncing');
      if (iconEl) iconEl.className = 'fa fa-sync fa-spin cloud-sync-status-icon';
      if (hintEl) hintEl.textContent = 'جارٍ الرفع';
    } else if (count > 0 || needsCloudFlush()) {
      el.classList.add('is-pending');
      if (iconEl) iconEl.className = 'fa fa-cloud-upload-alt cloud-sync-status-icon';
      if (hintEl) hintEl.textContent = count > 0 ? (count === 1 ? '1 باقٍ' : count + ' باقية') : 'رفع…';
    } else {
      el.classList.add('is-synced');
      if (iconEl) iconEl.className = 'fa fa-cloud cloud-sync-status-icon';
      if (hintEl) hintEl.textContent = '';
    }

    el.title = getStatusMessage();
    el.setAttribute('aria-label', getStatusMessage());

    var setText = document.getElementById('set-cloud-status-text');
    var setDot = document.getElementById('set-cloud-status-dot');
    if (setText) setText.textContent = getStatusMessage();
    if (setDot) {
      setDot.classList.remove('dot-synced', 'dot-pending', 'dot-syncing', 'dot-offline');
      if (offline) setDot.classList.add('dot-offline');
      else if (syncing) setDot.classList.add('dot-syncing');
      else if (count > 0 || needsCloudFlush()) setDot.classList.add('dot-pending');
      else setDot.classList.add('dot-synced');
    }

    var legacyBadge = document.getElementById('pending-sync-badge');
    if (legacyBadge) legacyBadge.style.display = 'none';
  }

  function initLeaveGuard() {
    if (!_inited) {
      _inited = true;
      window.addEventListener('beforeunload', function (e) {
        if (!shouldBlockLeave()) return;
        e.preventDefault();
        e.returnValue = '';
      });
    }
    updateSyncStatusUi();
  }

  function confirmLogout(proceedFn) {
    if (global.currentUser === 'emp') {
      proceedFn();
      return;
    }
    if (!shouldBlockLeave()) {
      proceedFn();
      return;
    }
    var count = getPendingCount();
    var syncing = isSyncing();
    var sw = typeof global.swalTheme === 'function' ? global.swalTheme() : {};
    var detail = syncing
      ? 'جارٍ رفع التغييرات — يُفضّل الانتظار ثوانٍ قبل الخروج.'
      : ('لديك ' + (count || 'بعض') + ' تغييرات لم تُرفع للسحابة بعد.');

    if (typeof global.Swal === 'undefined') {
      if (window.confirm(detail + '\n\nمتابعة الخروج؟')) proceedFn();
      return;
    }

    global.Swal.fire({
      title: '⏳ انتظر قليلاً',
      html: detail + '<br><span style="font-size:12px;opacity:0.75">يُرفع تلقائياً — لا حاجة لإعادة الإدخال</span>',
      icon: 'info',
      showCancelButton: true,
      showDenyButton: true,
      confirmButtonText: syncing ? 'حسناً، سأنتظر' : 'رفع الآن',
      denyButtonText: 'خروج على أي حال',
      cancelButtonText: 'إلغاء',
      confirmButtonColor: '#00d4aa',
      denyButtonColor: '#718096',
      ...sw
    }).then(async function (result) {
      if (result.isDismissed && !result.isDenied) return;
      if (result.isConfirmed && !syncing && global.BasmaCloud && global.BasmaCloud.flushPendingToCloud) {
        global.Swal.fire({
          title: 'جارٍ الرفع…',
          allowOutsideClick: false,
          didOpen: function () { global.Swal.showLoading(); },
          ...sw
        });
        try {
          await global.BasmaCloud.flushPendingToCloud({ reason: 'pre-logout-flush', force: true });
        } catch (e) { console.warn('pre-logout flush:', e); }
        global.Swal.close();
        updateSyncStatusUi();
        if (!shouldBlockLeave()) {
          proceedFn();
          return;
        }
        global.Swal.fire({
          icon: 'warning',
          title: 'لم يكتمل الرفع',
          text: 'يمكنك الانتظار قليلاً أو الخروج على مسؤوليتك',
          showDenyButton: true,
          showCancelButton: true,
          confirmButtonText: 'انتظر',
          denyButtonText: 'خروج على أي حال',
          ...sw
        }).then(function (r2) {
          if (r2.isDenied) proceedFn();
        });
        return;
      }
      if (result.isDenied) proceedFn();
    });
  }

  global.BasmaLeaveGuard = {
    initLeaveGuard: initLeaveGuard,
    updateSyncStatusUi: updateSyncStatusUi,
    shouldBlockLeave: shouldBlockLeave,
    confirmLogout: confirmLogout,
    getStatusMessage: getStatusMessage,
    getPendingCount: getPendingCount
  };
})(typeof window !== 'undefined' ? window : globalThis);
