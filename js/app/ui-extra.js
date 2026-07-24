// ======= HAMBURGER MENU =======
function toggleSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  if (!sidebar) return;
  sidebar.classList.toggle('open');
  if (overlay) overlay.classList.toggle('show', sidebar.classList.contains('open'));
}

function closeSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  if (sidebar) sidebar.classList.remove('open');
  if (overlay) {
    overlay.classList.remove('show');
    overlay.style.pointerEvents = 'none';
  }
}

// Auto-close sidebar on mobile when page is selected
function installShowPageBridge() {
  var core = window.__showPageCore;
  if (typeof core !== 'function') core = window.showPage;
  if (typeof core !== 'function') return false;
  window.__showPageCore = core;
  window.showPage = function (id) {
    core.call(window, id);
    if (window.innerWidth <= 768 && typeof closeSidebar === 'function') closeSidebar();
  };
  return true;
}

function bindSidebarNavClicks() {
  if (document.documentElement.dataset.sidebarNavBound === '1') return;
  document.documentElement.dataset.sidebarNavBound = '1';
  safeAddEvent(document, 'click', function (e) {
    var item = e.target && e.target.closest
      ? e.target.closest('#sidebar-nav .nav-item[data-page]')
      : null;
    if (!item) return;
    var pageId = item.getAttribute('data-page');
    if (!pageId) return;
    e.preventDefault();
    if (typeof window.showPage === 'function') window.showPage(pageId);
  }, true);
}

function bindSaActionClicks() {
  if (document.documentElement.dataset.saActionBound === '1') return;
  document.documentElement.dataset.saActionBound = '1';
  safeAddEvent(document, 'click', function (e) {
    var btn = e.target && e.target.closest ? e.target.closest('[data-sa-action]') : null;
    if (!btn) return;
    var action = btn.getAttribute('data-sa-action');
    if (!action) return;
    e.preventDefault();
    e.stopPropagation();
    if (action === 'security-health-report' && typeof runSecurityHealthReport === 'function') {
      runSecurityHealthReport(btn);
    }
  }, true);
}

if (typeof window !== 'undefined') {
  window.installShowPageBridge = installShowPageBridge;
  window.bindSaActionClicks = bindSaActionClicks;
  installShowPageBridge();
  bindSaActionClicks();
}

// ======= NETLIFY / VERCEL FIX =======
// Ensure all relative paths work
safeAddEvent(window, 'error', function(e) {
  console.warn('Resource error (may be non-critical):', e.target?.src || e.target?.href || e.message);
}, true);

// ======= SWAL RESPONSIVE FIX =======
document.addEventListener('DOMContentLoaded', function() {
  safeRun(function () { bindSidebarNavClicks(); }, 'sidebar-nav');
  safeRun(function () { if (typeof bindSaActionClicks === 'function') bindSaActionClicks(); }, 'sa-actions');
  safeRun(function () { if (typeof installShowPageBridge === 'function') installShowPageBridge(); }, 'show-page-bridge');
  safeAddEvent(window, 'resize', function () {
    if (window.innerWidth > 768 && typeof closeSidebar === 'function') closeSidebar();
  });
  // Ensure SweetAlert popups are responsive
  if (typeof Swal !== 'undefined') {
    const origFire = Swal.fire.bind(Swal);
    Swal.fire = function(opts) {
      if (opts && typeof opts === 'object') {
        // Ensure scrollable on mobile
        if (!opts.scrollbarPadding) opts.scrollbarPadding = false;
        // Prevent popups from overflowing on mobile
        if (window.innerWidth <= 768 && !opts.width) {
          opts.width = Math.min(window.innerWidth * 0.95, 500);
        }
      }
      var result = origFire(opts);
      if (result && typeof result.finally === 'function') {
        result.finally(function () {
          setTimeout(function () {
            if (typeof clearStaleUiBlockers === 'function') clearStaleUiBlockers();
          }, 50);
        });
      }
      return result;
    };
  }

  // Handle keyboard enter on login form  
  safeAddEvent(document.getElementById('password'), 'keydown', function(e) {
    if (e.key === 'Enter') doLogin('admin');
  });
  safeAddEvent(document.getElementById('username'), 'keydown', function(e) {
    if (e.key === 'Enter') doLogin('admin');
  });

  safeAddEvent(document, 'keydown', function (e) {
    if (e.key === 'Escape' && typeof clearStaleUiBlockers === 'function') {
      clearStaleUiBlockers();
    }
  });
});

// ======= SAFE STORAGE HELPERS =======
function safeGetStorage(key, defaultVal) {
  window.__basmaMemoryStorage = window.__basmaMemoryStorage || {};
  return Object.prototype.hasOwnProperty.call(window.__basmaMemoryStorage, key)
    ? window.__basmaMemoryStorage[key]
    : defaultVal;
}

function safeSetStorage(key, val) {
  window.__basmaMemoryStorage = window.__basmaMemoryStorage || {};
  window.__basmaMemoryStorage[key] = val;
  return true;
}

// ======= GLOBAL ERROR HANDLER =======
safeAddEvent(window, 'unhandledrejection', function(e) {
  console.warn('Unhandled promise rejection:', e.reason);
  if (e.reason && e.reason.message) {
    console.error('Error details:', e.reason.message);
  }
  if (typeof KynoSentry !== 'undefined' && KynoSentry.capture) {
    KynoSentry.capture(e.reason || e, { type: 'unhandledrejection' });
  }
});

window.onerror = function(msg, url, line, col, err) {
  console.error('JS Error:', msg, 'at', line + ':' + col, err);
  if (typeof KynoSentry !== 'undefined' && KynoSentry.capture) {
    KynoSentry.capture(err || new Error(String(msg)), { type: 'window.onerror', line: line, col: col });
  }
  return false;
};

// ============================================================
// SaaS Helper Functions
// ============================================================

/** Safe string/number for inline onclick="fn(id, 'name')" — avoids SyntaxError from quotes */
function _saOnclickArg(val) {
  if (val == null || val === undefined) return "''";
  if (typeof val === 'number' && isFinite(val)) return String(val);
  if (typeof val === 'boolean') return val ? 'true' : 'false';
  return JSON.stringify(String(val)).replace(/"/g, '&quot;');
}

function _isCompanySubscriptionTenant() {
  return currentUser === 'admin'
    && saasCurrentUser
    && saasCurrentUser.role !== 'super_admin'
    && (saasCurrentUser.role === 'company_admin' || saasCurrentUser.role === 'company_user')
    && !!saasCurrentUser.company_id;
}

function _removeSaasBanner() {
  const b = document.getElementById('subscription-banner');
  if (b) b.style.display = 'none';
}

function clearSubscriptionClientState() {
  _subscriptionStatus = null;
  _removeSaasBanner();
  if (window._subBannerReminderTimer) {
    clearInterval(window._subBannerReminderTimer);
    window._subBannerReminderTimer = null;
  }
  try {
    var keys = [];
    for (var i = 0; i < sessionStorage.length; i++) {
      var k = sessionStorage.key(i);
      if (k && k.indexOf('basma_sub_') === 0) keys.push(k);
    }
    keys.forEach(function (key) { sessionStorage.removeItem(key); });
  } catch (e) {}
  var toastRoot = document.getElementById('basma-toast-root');
  if (toastRoot) toastRoot.innerHTML = '';
  if (typeof BasmaToast !== 'undefined' && typeof BasmaToast.dismissAll === 'function') {
    BasmaToast.dismissAll();
  }
}
if (typeof window !== 'undefined') window.clearSubscriptionClientState = clearSubscriptionClientState;

function _ensureSubscriptionBannerReminder() {
  if (window._subBannerReminderTimer) return;
  window._subBannerReminderTimer = setInterval(function () {
    if (typeof _renderSubscriptionBanner === 'function') _renderSubscriptionBanner();
  }, 60000);
}

function _waSupportButtonHtml(label) {
  label = label || 'واتساب الدعم';
  return '<button type="button" class="subscription-wa-btn" onclick="typeof contactSuperAdmin===\'function\'&&contactSuperAdmin()" title="تواصل عبر واتساب">' +
    '<i class="fa-brands fa-whatsapp"></i> ' + label + '</button>';
}

function _renderSubscriptionBanner() {
  const b = document.getElementById('subscription-banner');
  if (!b) return;
  var escMsg = typeof BasmaSecurity !== 'undefined' && BasmaSecurity.escapeHtml
    ? BasmaSecurity.escapeHtml
    : (typeof esc === 'function' ? esc : function (s) { return String(s == null ? '' : s); });
  if (!_isCompanySubscriptionTenant()) {
    b.style.display = 'none';
    return;
  }
  _ensureSubscriptionBannerReminder();
  const activePage = document.querySelector('.page.active');
  const onDashboard = !!(activePage && activePage.id === 'page-dashboard');
  if (!_subscriptionStatus || _subscriptionStatus.valid) {
    if (_subscriptionStatus && _subscriptionStatus.warning) {
      if (!onDashboard) {
        b.style.display = 'none';
        return;
      }
      b.style.display = 'block';
      b.innerHTML = '<div class="subscription-banner warning">' +
        '<i class="fa fa-exclamation-triangle"></i>' +
        '<span>' + escMsg(_subscriptionStatus.message || 'ينتهي الاشتراك قريباً') + '</span>' +
        _waSupportButtonHtml('تجديد عبر واتساب') +
        '</div>';
    } else {
      b.style.display = 'none';
    }
    return;
  }
  b.style.display = 'block';
  const statusClass = { expired: 'expired', suspended: 'suspended', pending: 'pending' }[_subscriptionStatus.status] || 'expired';
  const icon = { expired: 'fa-times-circle', suspended: 'fa-pause-circle', pending: 'fa-clock' }[_subscriptionStatus.status] || 'fa-times-circle';
  b.innerHTML = '<div class="subscription-banner ' + statusClass + '">' +
    '<i class="fa ' + icon + '"></i>' +
    '<span>حساب الشركة موقوف. تواصل مع الدعم الفني.</span>' +
    _waSupportButtonHtml('واتساب الدعم') +
    '</div>';
}

function maybeShowSubscriptionExpiryToast() {
  if (!_isCompanySubscriptionTenant()) return;
  if (!_subscriptionStatus) return;
  var toastOpts = { dismissible: true, center: true };
  if (_subscriptionStatus.valid === false) {
    var blockKey = 'basma_sub_toast_blocked_' + saasCurrentUser.company_id;
    var lastBlock = parseInt(sessionStorage.getItem(blockKey), 10) || 0;
    if (Date.now() - lastBlock < 30 * 60 * 1000) return;
    sessionStorage.setItem(blockKey, String(Date.now()));
    toastOpts.onDismiss = function () {
      sessionStorage.setItem(blockKey, String(Date.now()));
    };
    if (typeof BasmaToast !== 'undefined') {
      BasmaToast.error('حساب الشركة موقوف — تواصل مع الدعم الفني عبر واتساب', 60000, toastOpts);
    }
    return;
  }
  if (!_subscriptionStatus.warning || _subscriptionStatus.daysLeft > 10) return;
  var warnKey = 'basma_sub_toast_warn_' + saasCurrentUser.company_id + '_' + _subscriptionStatus.end_date;
  var lastWarn = parseInt(sessionStorage.getItem(warnKey), 10) || 0;
  if (Date.now() - lastWarn < 30 * 60 * 1000) return;
  sessionStorage.setItem(warnKey, String(Date.now()));
  toastOpts.onDismiss = function () {
    sessionStorage.setItem(warnKey, String(Date.now()));
  };
  if (typeof BasmaToast !== 'undefined') {
    BasmaToast.warn('⏰ ينتهي اشتراككم خلال ' + _subscriptionStatus.daysLeft + ' يوم — تواصل مع الدعم للتجديد', 60000, toastOpts);
  }
}

function injectSubscriptionAlerts() {
  if (typeof notifications === 'undefined' || currentUser !== 'admin') return;
  if (!saasCurrentUser || saasCurrentUser.role === 'super_admin') return;
  if (!_subscriptionStatus) return;
  var title = '';
  var body = '';
  var icon = 'warning';
  var ico = 'fa-clock';
  if (_subscriptionStatus.valid === false) {
    title = 'حساب الشركة موقوف';
    body = 'تواصل مع الدعم الفني عبر واتساب لتجديد الاشتراك.';
    icon = 'danger';
    ico = 'fa-ban';
  } else if (_subscriptionStatus.warning && _subscriptionStatus.daysLeft <= 10) {
    title = 'تنبيه انتهاء الاشتراك';
    body = 'ينتهي اشتراككم خلال ' + _subscriptionStatus.daysLeft + ' يوم — يرجى التجديد.';
  } else {
    return;
  }
  notifications.unshift({
    id: 'sub_alert_' + (_subscriptionStatus.end_date || Date.now()),
    store: 'subscription',
    icon: icon,
    ico: ico,
    title: title,
    body: body,
    actor: 'النظام',
    ts: new Date().toISOString(),
    datetime: typeof formatNotifDateTime === 'function' ? formatNotifDateTime(new Date().toISOString()) : '',
    time: typeof formatNotifTime === 'function' ? formatNotifTime(new Date().toISOString()) : '',
    unread: true
  });
}

function _isPlatformAnnouncementDismissed(ann) {
  if (!ann || !ann.id) return false;
  var stamp = ann.updatedAt || ann.createdAt || '';
  window.__basmaDismissedAnnouncements = window.__basmaDismissedAnnouncements || {};
  return window.__basmaDismissedAnnouncements[ann.id] === stamp;
}

function dismissPlatformAnnouncement(id) {
  var list = (window.platformSettings && window.platformSettings.announcements) || [];
  var ann = list.find(function (a) { return a && a.id === id; });
  if (!ann) return;
  var stamp = ann.updatedAt || ann.createdAt || String(Date.now());
  window.__basmaDismissedAnnouncements = window.__basmaDismissedAnnouncements || {};
  window.__basmaDismissedAnnouncements[id] = stamp;
  renderPlatformAnnouncementsRail();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
}

function renderPlatformAnnouncementsRail() {
  var rail = document.getElementById('platform-announcements-rail');
  if (!rail) return;
  if (typeof currentUser !== 'undefined' && currentUser === 'emp') {
    rail.innerHTML = '';
    rail.style.display = 'none';
    return;
  }
  if (!saasCurrentUser || saasCurrentUser.role === 'super_admin' || !saasCurrentUser.company_id) {
    rail.innerHTML = '';
    rail.style.display = 'none';
    return;
  }
  var list = (window.platformSettings && window.platformSettings.announcements) || [];
  var visible = list.filter(function (a) { return a && a.message && !_isPlatformAnnouncementDismissed(a); });
  if (!visible.length) {
    rail.innerHTML = '';
    rail.style.display = 'none';
    return;
  }
  rail.style.display = 'flex';
  var esc = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml : function (s) { return String(s || ''); };
  rail.innerHTML = visible.map(function (ann) {
    return '<div class="platform-ann-card" data-ann-id="' + esc(ann.id) + '">' +
      '<button type="button" class="platform-ann-close" onclick="dismissPlatformAnnouncement(\'' + String(ann.id).replace(/'/g, "\\'") + '\')" aria-label="إغلاق">&times;</button>' +
      '<div class="platform-ann-head"><i class="fa fa-bullhorn"></i><span>من: ' + esc(_annSenderLabel(ann)) + '</span></div>' +
      '<div class="platform-ann-text">' + esc(ann.message) + '</div>' +
      '</div>';
  }).join('');
}

function injectPlatformAnnouncements() {
  if (typeof notifications === 'undefined' || currentUser !== 'admin') return;
  if (!saasCurrentUser || saasCurrentUser.role === 'super_admin') return;
  var list = (window.platformSettings && window.platformSettings.announcements) || [];
  list.forEach(function (ann) {
    if (!ann || !ann.message) return;
    notifications.unshift({
      id: 'platform_ann_' + ann.id,
      store: 'platform',
      icon: 'info',
      ico: 'fa-bullhorn',
      title: 'إشعار من ' + _annSenderLabel(ann),
      body: ann.message,
      actor: ann.senderName || 'الإدارة',
      ts: ann.updatedAt || ann.createdAt || new Date().toISOString(),
      datetime: typeof formatNotifDateTime === 'function' ? formatNotifDateTime(ann.updatedAt || ann.createdAt) : '',
      time: typeof formatNotifTime === 'function' ? formatNotifTime(ann.updatedAt || ann.createdAt) : '',
      unread: !_isPlatformAnnouncementDismissed(ann)
    });
  });
}

if (typeof window !== 'undefined') {
  window.renderPlatformAnnouncementsRail = renderPlatformAnnouncementsRail;
  window.dismissPlatformAnnouncement = dismissPlatformAnnouncement;
  window.injectPlatformAnnouncements = injectPlatformAnnouncements;
}

function getSubscriptionStatus() {
  if (typeof window !== 'undefined' && window._subscriptionStatus) return window._subscriptionStatus;
  return typeof _subscriptionStatus !== 'undefined' ? _subscriptionStatus : null;
}

function setSubscriptionStatus(st) {
  if (typeof window !== 'undefined') window._subscriptionStatus = st;
  if (typeof _subscriptionStatus !== 'undefined') _subscriptionStatus = st;
}

function resolveSubscriptionCompanyId() {
  if (typeof currentUser !== 'undefined' && currentUser === 'emp') {
    var sess = window.__basmaEmpSession;
    if (sess && sess.companyId != null) {
      var sid = parseInt(sess.companyId, 10);
      if (sid > 0) return sid;
    }
    var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
    if (emp && emp.company_id != null) return parseInt(emp.company_id, 10) || null;
  }
  if (saasCurrentUser && saasCurrentUser.company_id != null) {
    return parseInt(saasCurrentUser.company_id, 10) || null;
  }
  if (typeof getNotificationScopeId === 'function') {
    var scope = getNotificationScopeId();
    if (scope && scope !== 'super') return parseInt(scope, 10) || null;
  }
  return null;
}

async function refreshSubscriptionStatusForCurrentContext() {
  if (saasCurrentUser && saasCurrentUser.role === 'super_admin') return null;
  var cid = resolveSubscriptionCompanyId();
  if (!cid || typeof sb_checkSubscriptionStatus !== 'function') return null;
  var st = await sb_checkSubscriptionStatus(cid);
  if (st && typeof st === 'object') st._companyId = cid;
  setSubscriptionStatus(st);
  if (typeof _renderSubscriptionBanner === 'function') _renderSubscriptionBanner();
  return st;
}

function isSubscriptionActive() {
  var u = (typeof window !== 'undefined' && (window._saasCurrentUser || window.saasCurrentUser)) ||
    (typeof saasCurrentUser !== 'undefined' ? saasCurrentUser : null);
  if (u && u.role === 'super_admin') return true;
  var st = getSubscriptionStatus();
  if (typeof currentUser !== 'undefined' && currentUser === 'emp') {
    if (!st) return true;
    if (st.unchecked === true) return true;
    var cid = typeof resolveSubscriptionCompanyId === 'function' ? resolveSubscriptionCompanyId() : null;
    if (st._companyId != null && cid && parseInt(st._companyId, 10) !== parseInt(cid, 10)) return true;
  }
  // لا تحجب التنقل إذا لم تُحمَّل حالة الاشتراك بعد (تُفحص عند الدخول)
  if (!st && u && (u.role === 'company_admin' || u.role === 'company_user')) return true;
  return !!(st && st.valid === true);
}

function isEmployeePortalLocked() {
  return currentUser === 'emp' && !isSubscriptionActive();
}

function blockIfSubscriptionInactive(pageLabel) {
  if (isSubscriptionActive()) return false;
  Swal.fire({
    icon: 'warning',
    title: 'انتهى الاشتراك',
    html: 'لا يمكن الوصول إلى «' + esc(pageLabel || 'هذه الصفحة') + '» — الاشتراك غير فعّال.<br><span style="font-size:12px;color:var(--text-muted)">تواصل مع الدعم لتجديد الاشتراك.</span>',
    ...swalTheme()
  });
  return true;
}

if (typeof window !== 'undefined') {
  window.blockIfSubscriptionInactive = blockIfSubscriptionInactive;
  window.isSubscriptionActive = isSubscriptionActive;
  window.isEmployeePortalLocked = isEmployeePortalLocked;
  window.getSubscriptionStatus = getSubscriptionStatus;
  window.setSubscriptionStatus = setSubscriptionStatus;
  window.resolveSubscriptionCompanyId = resolveSubscriptionCompanyId;
  window.refreshSubscriptionStatusForCurrentContext = refreshSubscriptionStatusForCurrentContext;
}

function requireSubscription(actionName) {
  var actionLabel = typeof esc === 'function' ? esc(actionName || 'هذه العملية') : (actionName || 'هذه العملية');
  if (currentUser === 'admin') {
    const pageByAction = {
      'إضافة موظف جديد': 'employees',
      'إضافة سجل حضور': 'attendance',
      'تسجيل الحضور': 'attendance'
    };
    const requiredPage = pageByAction[actionName];
    if (requiredPage && !hasCompanyPermission(requiredPage)) {
      Swal.fire({ icon:'warning', title:'غير مصرح', text:'لا تملك صلاحية تنفيذ هذه العملية', ...swalTheme() });
      return false;
    }
  }
  if (isSubscriptionActive()) return true;
  Swal.fire({
    icon: 'warning', title: 'حساب الشركة موقوف',
    html: 'لا يمكن تنفيذ <b>' + actionLabel + '</b>.<br>تواصل مع الدعم الفني لتجديد الاشتراك.',
    confirmButtonText: 'واتساب الدعم',
    showCancelButton: true,
    cancelButtonText: 'إغلاق',
    ...swalTheme()
  }).then(function (r) { if (r.isConfirmed) contactSuperAdmin(); });
  return false;
}

async function getCurrentCompanyEmployeeLimit() {
  if (!saasCurrentUser || saasCurrentUser.role === 'super_admin') return 0;
  let limit = parseInt(saasCurrentUser.max_employees) || 0;
  if (limit > 0) return limit;
  if (typeof sb_getCompanies === 'function' && saasCurrentUser.company_id) {
    try {
      const companies = await sb_getCompanies();
      const company = (companies || []).find(c => Number(c.id) === Number(saasCurrentUser.company_id));
      if (company) {
        limit = parseInt(company.max_employees) || 0;
        if (limit > 0) {
          saasCurrentUser.max_employees = limit;
          window._saasCurrentUser = saasCurrentUser;
        }
      }
    } catch(e) {
      console.warn('getCurrentCompanyEmployeeLimit failed:', e);
    }
  }
  return limit;
}

async function canAddEmployeeUnderCompanyLimit(showMessage) {
  if (!saasCurrentUser || saasCurrentUser.role === 'super_admin') return true;
  const limit = await getCurrentCompanyEmployeeLimit();
  const companyId = saasCurrentUser.company_id || window._saasCompanyId;
  var count = (employees || []).filter(function (e) {
    return e && (!companyId || Number(e.company_id || companyId) === Number(companyId));
  }).length;
  if (typeof sb_countCompanyEmployees === 'function' && companyId) {
    try {
      var remoteCount = await sb_countCompanyEmployees(companyId);
      if (remoteCount != null) count = Math.max(count, remoteCount);
    } catch (e) {
      console.warn('canAddEmployeeUnderCompanyLimit remote count:', e);
    }
  }
  if (!limit || count < limit) return true;
  if (showMessage !== false) {
    var companyLabel = saasCurrentUser.company_name ? ('«' + saasCurrentUser.company_name + '»') : 'هذه الشركة';
    Swal.fire({
      icon: 'warning',
      title: 'تم الوصول للحد الأقصى',
      html: companyLabel + ' مسموح لها بـ <b>' + limit + '</b> موظف فقط.<br>عدد الموظفين الحالي: <b>' + count + '</b><br><small style="color:var(--text-muted)">إذا أنشأت شركة جديدة، تأكد من تسجيل الدخول بحسابها ثم فعّل الاشتراك من لوحة السوبر أدمن.</small>',
      ...swalTheme()
    });
  }
  return false;
}

// ============================================================
// Company Admin Users & Permissions
// ============================================================

async function buildCompanyUsersPage() {
  const el = document.getElementById('company-users-content');
  if (!el) return;
  if (!saasCurrentUser || !saasCurrentUser.company_id) {
    el.innerHTML = '<div class="card" style="color:#fc8181">لا توجد شركة مرتبطة بهذا الحساب.</div>';
    return;
  }
  if (!hasActionPermission('users_permissions', 'view')) {
    el.innerHTML = '<div class="card" style="color:#fc8181">لا تملك صلاحية إدارة المستخدمين.</div>';
    return;
  }
  const canAddUser = hasActionPermission('users_permissions', 'add');
  const canEditUser = hasActionPermission('users_permissions', 'edit');
  const canDeleteUser = hasActionPermission('users_permissions', 'delete');
  el.innerHTML = '<div style="text-align:center;padding:40px;color:var(--text-muted)"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    const companyId = saasCurrentUser.company_id || (typeof AuthApi !== 'undefined' && AuthApi.getCompanyId ? AuthApi.getCompanyId() : null);
    const users = typeof sb_getCompanyUsers === 'function' ? await sb_getCompanyUsers(companyId) : [];
    _companyUsersCache = users || [];
    el.innerHTML = `
      ${_saPageBannerHtml()}
      <div class="sa-hero">
        <div>
          <h3>👤 المستخدمون والصلاحيات</h3>
          <p>إضافة مستخدمين وتحديد صلاحيات تفصيلية: عرض، إضافة، تعديل، حذف لكل وحدة.</p>
        </div>
        <div class="sa-hero-actions">
          ${canAddUser ? '<button class="sa-btn sa-btn-primary" onclick="openCompanyUserForm(\'add\')"><i class="fa fa-plus"></i> إضافة مستخدم</button>' : ''}
          <button class="sa-btn sa-btn-soft" onclick="buildCompanyUsersPage()"><i class="fa fa-rotate"></i> تحديث</button>
        </div>
      </div>
      <div class="sa-table-wrap">
        <div class="sa-table-title">
          <span>مستخدمو الشركة</span>
          <span style="color:var(--text-muted);font-size:12px">${_companyUsersCache.length} مستخدم</span>
        </div>
        <table>
          <thead><tr><th>#</th><th>الاسم</th><th>اسم المستخدم</th><th>الدور</th><th>الصلاحيات</th><th>آخر دخول</th><th>الحالة</th><th>إجراءات</th></tr></thead>
          <tbody>
            ${_companyUsersCache.map((u, i) => {
              const roleLabel = u.role === 'company_admin' ? 'مدير شركة' : 'مستخدم';
              const roleBadge = u.role === 'company_admin' ? 'badge-active' : 'badge-pending';
              const allowedCount = typeof countUserPermissions === 'function'
                ? countUserPermissions(u.permissions, u.role)
                : (u.role === 'company_admin' ? 'كامل' : 0);
              const isSelf = saasCurrentUser && Number(saasCurrentUser.id) === Number(u.id);
              return `<tr>
                <td>${i + 1}</td>
                <td><strong>${typeof esc === 'function' ? esc(u.display_name || u.username) : (u.display_name || u.username)}</strong><br><span style="font-size:11px;color:var(--text-muted)">${typeof esc === 'function' ? esc(u.email || '—') : (u.email || '—')}</span></td>
                <td><span dir="ltr" style="font-family:monospace;color:var(--accent)">${typeof esc === 'function' ? esc(u.username) : u.username}</span></td>
                <td><span class="${roleBadge}">${roleLabel}</span></td>
                <td>${allowedCount === 'كامل' ? 'صلاحيات كاملة' : allowedCount + ' صلاحية'}</td>
                <td style="font-size:11px;color:var(--text-muted)">${u.last_login ? new Date(u.last_login).toLocaleString('ar-IQ') : 'لم يدخل بعد'}</td>
                <td><span class="${u.is_active ? 'badge-active' : 'badge-suspended'}">${u.is_active ? 'نشط' : 'موقوف'}</span></td>
                <td style="white-space:nowrap">
                  ${canEditUser ? '<button class="sa-btn sa-btn-soft" onclick="openCompanyUserForm(\'edit\', ' + u.id + ')"><i class="fa fa-pen"></i> تعديل</button>' : ''}
                  ${isSelf ? '<span style="font-size:11px;color:var(--text-muted)">حسابك</span>' : (canDeleteUser ? `<button class="sa-btn sa-btn-danger" onclick="deleteCompanyUser(${u.id})"><i class="fa fa-trash"></i> حذف</button>` : '')}
                </td>
              </tr>`;
            }).join('') || '<tr><td colspan="8" style="text-align:center;color:var(--text-muted)">لا يوجد مستخدمون</td></tr>'}
          </tbody>
        </table>
      </div>`;
  } catch(e) {
    el.innerHTML = '<div class="card" style="color:#fc8181">خطأ في تحميل المستخدمين: ' + esc(e.message || e) + '</div>';
  }
}

async function openCompanyUserForm(mode, userId) {
  if (!saasCurrentUser || !saasCurrentUser.company_id) return;
  const isEdit = mode === 'edit';
  if (isEdit && !requireActionPermission('users_permissions', 'edit')) return;
  if (!isEdit && !requireActionPermission('users_permissions', 'add')) return;
  const user = isEdit ? _companyUsersCache.find(u => u.id === userId) : null;
  if (isEdit && !user) return;
  const escField = typeof esc === 'function' ? esc : function (v) { return String(v || ''); };
  const permHtmlFn = typeof permissionMatrixHtml === 'function' ? permissionMatrixHtml : function () { return '<p style="color:#fc8181">تعذّر تحميل مصفوفة الصلاحيات</p>'; };
  const defaultPerms = user && user.permissions ? normalizePermissions(user.permissions) : normalizePermissions({
    dashboard: true,
    employees: true, employees_add: false, employees_delete: false, employees_edit: false,
    attendance: true, attendance_add: false, attendance_delete: false, attendance_batch_delete: false, attendance_edit: false,
    device_mgmt: true, device_mgmt_edit: false,
    salaries: false, finance: false, org: false,
    reports: true,
    notifications: true, notifications_read_all: true, notifications_clear_all: false, notifications_export: false,
    settings: false, users_permissions: false
  });
  try {
    if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
      await AuthApi.ensureValidSession();
    }
  } catch (e) { /* ignore */ }
  const { value: vals, isConfirmed } = await Swal.fire({
    title: isEdit ? '✏️ تعديل مستخدم' : '➕ إضافة مستخدم',
    html: `
      <div style="text-align:right">
        <div class="emp-form-section">
          <div class="emp-form-section-title">بيانات المستخدم</div>
          <div class="emp-field-row">
            <div class="emp-field"><label>الاسم الظاهر</label><input id="cu-name" value="${user ? escField(user.display_name || '') : ''}" placeholder="مثال: مسؤول الموارد البشرية"></div>
            <div class="emp-field"><label>اسم المستخدم *</label><input id="cu-username" value="${user ? escField(user.username) : ''}" dir="ltr" autocomplete="username"></div>
          </div>
          <div class="emp-field-row" style="margin-top:10px">
            <div class="emp-field"><label>البريد الإلكتروني</label><input id="cu-email" value="${user ? escField(user.email || '') : ''}" dir="ltr" autocomplete="email"></div>
            <div class="emp-field"><label>الدور</label>
              <select id="cu-role">
                <option value="company_user" ${user && user.role === 'company_user' ? 'selected' : ''}>مستخدم بصلاحيات محددة</option>
                <option value="company_admin" ${user && user.role === 'company_admin' ? 'selected' : ''}>مدير شركة كامل الصلاحيات</option>
              </select>
            </div>
          </div>
          <div class="emp-field-row" style="margin-top:10px">
            <div class="emp-field"><label>${isEdit ? 'كلمة مرور جديدة' : 'كلمة المرور *'}</label><input id="cu-pass" type="password" placeholder="${isEdit ? 'اتركها فارغة إذا لا تريد تغييرها' : '6 أحرف على الأقل'}" autocomplete="new-password"></div>
            <div class="emp-field"><label>تأكيد كلمة المرور</label><input id="cu-pass2" type="password" placeholder="تأكيد كلمة المرور" autocomplete="new-password"></div>
          </div>
        </div>
        <div class="emp-form-section">
          <div class="emp-form-section-title">مصفوفة الصلاحيات التفصيلية</div>
          <div class="perm-matrix-wrap">
            ${permHtmlFn(defaultPerms)}
          </div>
          <div class="emp-field-hint">حدّد لكل وحدة: عرض، إضافة، تعديل، حذف، تصدير، قراءة/حذف الإشعارات. مدير الشركة = صلاحيات كاملة.</div>
        </div>
      </div>`,
    width: 920,
    confirmButtonText: isEdit ? 'حفظ التعديلات' : 'إضافة المستخدم',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    didOpen: bindPermissionCards,
    preConfirm: () => {
      const username = document.getElementById('cu-username').value.trim();
      const pass = document.getElementById('cu-pass').value;
      const pass2 = document.getElementById('cu-pass2').value;
      if (!username || username.length < 3) { Swal.showValidationMessage('اسم المستخدم يجب أن يكون 3 أحرف على الأقل'); return false; }
      if (!isEdit && pass.length < 6) { Swal.showValidationMessage('كلمة المرور مطلوبة ويجب أن تكون 6 أحرف على الأقل'); return false; }
      if (pass || pass2) {
        if (pass.length < 6) { Swal.showValidationMessage('كلمة المرور يجب أن تكون 6 أحرف على الأقل'); return false; }
        if (pass !== pass2) { Swal.showValidationMessage('كلمة المرور وتأكيدها غير متطابقين'); return false; }
      }
      var popup = Swal.getPopup ? Swal.getPopup() : null;
      var matrixRoot = popup ? popup.querySelector('.perm-matrix-wrap') : null;
      return {
        id: isEdit ? user.id : undefined,
        display_name: document.getElementById('cu-name').value.trim(),
        username: username.toLowerCase(),
        email: document.getElementById('cu-email').value.trim(),
        role: document.getElementById('cu-role').value,
        password: pass,
        permissions: readPermissionsFromForm(matrixRoot, isEdit ? user.permissions : null),
        is_active: true
      };
    }
  });
  if (!isConfirmed || !vals) return;
  try {
    const result = await sb_upsertCompanyUser(vals, saasCurrentUser.company_id);
    if (!result.ok) {
      Swal.fire({ icon:'error', title:'لم يتم الحفظ', text: result.error || 'حدث خطأ', ...swalTheme() });
      return;
    }
    if (result.user && saasCurrentUser && Number(vals.id) === Number(saasCurrentUser.id)) {
      saasCurrentUser.permissions = normalizePermissions(result.user.permissions || vals.permissions);
      if (result.user.role) saasCurrentUser.role = result.user.role;
      if (result.user.display_name) saasCurrentUser.display_name = result.user.display_name;
      window._saasCurrentUser = saasCurrentUser;
      if (typeof saveAdminSession === 'function') saveAdminSession(saasCurrentUser);
    }
    Swal.fire({ icon:'success', title:isEdit ? 'تم تعديل المستخدم' : 'تم إضافة المستخدم', timer:1500, showConfirmButton:false, ...swalTheme() });
    logActivity(isEdit ? 'edit' : 'add', 'users', (isEdit ? 'تعديل' : 'إضافة') + ' مستخدم: ' + vals.username, { targetName: vals.username });
    await buildCompanyUsersPage();
  } catch (e) {
    console.error('openCompanyUserForm save:', e);
    Swal.fire({ icon:'error', title:'خطأ', text: e.message || 'تعذّر حفظ المستخدم', ...swalTheme() });
  }
}

async function deleteCompanyUser(userId) {
  if (!requireActionPermission('users_permissions', 'delete')) return;
  if (!saasCurrentUser || !saasCurrentUser.company_id) return;
  if (Number(saasCurrentUser.id) === Number(userId)) {
    Swal.fire({ icon: 'warning', title: 'غير مسموح', text: 'لا يمكنك حذف حسابك الحالي', ...swalTheme() });
    return;
  }
  const user = _companyUsersCache.find(function (u) { return Number(u.id) === Number(userId); });
  if (!user) {
    Swal.fire({ icon: 'error', title: 'خطأ', text: 'المستخدم غير موجود — حدّث القائمة', ...swalTheme() });
    return;
  }
  const username = user.username || user.display_name || 'مستخدم';
  const { isConfirmed } = await Swal.fire({
    title: 'حذف مستخدم',
    html: 'هل تريد حذف المستخدم <b>' + (typeof esc === 'function' ? esc(username) : username) + '</b>؟',
    icon: 'warning',
    confirmButtonText: 'نعم، حذف',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#e53e3e'
  });
  if (!isConfirmed) return;
  try {
    if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
      await AuthApi.ensureValidSession();
    }
    const result = await sb_deleteCompanyUser(userId, saasCurrentUser.company_id);
    if (!result.ok) {
      Swal.fire({ icon:'error', title:'لم يتم الحذف', text: result.error || 'حدث خطأ', ...swalTheme() });
      return;
    }
    Swal.fire({ icon:'success', title:'تم حذف المستخدم', timer:1400, showConfirmButton:false, ...swalTheme() });
    logActivity('delete', 'users', 'حذف مستخدم: ' + username, { targetName: username });
    await buildCompanyUsersPage();
  } catch (e) {
    console.error('deleteCompanyUser:', e);
    Swal.fire({ icon:'error', title:'خطأ', text: e.message || 'تعذّر حذف المستخدم', ...swalTheme() });
  }
}

// ============================================================
// Super Admin Dashboard
// ============================================================

function _saCan(action) {
  return typeof canSuperAdmin !== 'function' || canSuperAdmin(action);
}

function _saPageBannerHtml() {
  if (typeof isSuperAdminViewOnly === 'function' && isSuperAdminViewOnly()) {
    return '<div class="sa-readonly-banner" role="status"><i class="fa fa-eye"></i><span>وضع <strong>عرض فقط</strong> — يمكنك استعراض البيانات دون تعديل أو حذف</span></div>';
  }
  return '';
}

function _annSenderLabel(ann) {
  if (!ann) return 'الإدارة';
  var name = String(ann.senderName || '').trim();
  var job = String(ann.senderJobTitle || '').trim();
  if (!name) return 'الإدارة';
  return job ? (name + ' — ' + job) : name;
}

function saMoneyInt(value) {
  if (typeof exactMoneyValue === 'function') return exactMoneyValue(value, 0);
  if (typeof sb_normalizeMoneyInt === 'function') return sb_normalizeMoneyInt(value, 0);
  return Math.max(0, Math.round(Number(value) || 0));
}

function formatSaMoney(value) {
  return saMoneyInt(value).toLocaleString('ar-IQ');
}

async function buildSuperAdminDashboard() {
  const el = document.getElementById('sa-dashboard-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px;color:var(--text-muted)"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    const [companies, subs] = await Promise.all([
      typeof sb_getCompanies === 'function' ? sb_getCompanies() : null,
      typeof sb_getAllSubscriptions === 'function' ? sb_getAllSubscriptions() : null
    ]);
    const totalCompanies = companies ? companies.length : 0;
    const activeCompanies = companies ? companies.filter(c => c.status === 'active').length : 0;
    const expiredSubs = subs ? subs.filter(s => s.status === 'expired').length : 0;
    const totalRevenue = subs ? subs.reduce((a, s) => a + saMoneyInt(s.amount), 0) : 0;
    const totalEmployees = companies ? companies.reduce((a, c) => a + (parseInt(c.employee_count) || 0), 0) : 0;

    el.innerHTML = `
      ${_saPageBannerHtml()}
      <div class="sa-hero">
        <div>
          <h3>👑 لوحة إدارة المنصة</h3>
          <p>إدارة الشركات، الاشتراكات، المستخدمين، والإيرادات من مكان واحد مع عزل كامل لبيانات كل شركة.</p>
        </div>
        <div class="sa-hero-actions">
          <button class="sa-btn sa-btn-soft" onclick="openSuperAdminAccountSettings()"><i class="fa fa-user-cog"></i> حسابي</button>
          ${_saCan('companies_create') ? '<button class="sa-btn sa-btn-primary" onclick="openAddCompanyForm()"><i class="fa fa-plus"></i> شركة جديدة</button>' : ''}
        </div>
      </div>

      <div class="sa-stat-grid">
        <div class="sa-stat-card blue"><div class="sa-stat-val">${totalCompanies}</div><div class="sa-stat-lbl">إجمالي الشركات</div></div>
        <div class="sa-stat-card green"><div class="sa-stat-val">${activeCompanies}</div><div class="sa-stat-lbl">شركات نشطة</div></div>
        <div class="sa-stat-card red"><div class="sa-stat-val">${expiredSubs}</div><div class="sa-stat-lbl">اشتراكات منتهية</div></div>
        <div class="sa-stat-card gold"><div class="sa-stat-val">${totalRevenue.toLocaleString()}</div><div class="sa-stat-lbl">إجمالي الإيرادات</div></div>
        <div class="sa-stat-card"><div class="sa-stat-val">${totalEmployees}</div><div class="sa-stat-lbl">إجمالي الموظفين</div></div>
      </div>

      <div class="sa-action-grid">
        ${_saCan('companies_create') ? `<button class="sa-action-card" onclick="openAddCompanyForm()">
          <div class="sa-action-icon"><i class="fa fa-building"></i></div>
          <div class="sa-action-title">إضافة شركة جديدة</div>
          <div class="sa-action-desc">إنشاء شركة مع أدمن واشتراك PRO من نفس النافذة.</div>
        </button>` : ''}
        ${_saCan('companies_view') ? `<button class="sa-action-card blue" onclick="showPage('sa-companies')">
          <div class="sa-action-icon"><i class="fa fa-list"></i></div>
          <div class="sa-action-title">إدارة الشركات</div>
          <div class="sa-action-desc">تفعيل، إيقاف، تعديل، ومراجعة كل الشركات المسجلة.</div>
        </button>` : ''}
        ${_saCan('subscriptions_view') || _saCan('subscriptions_renew') ? `<button class="sa-action-card gold" onclick="showPage('sa-subscriptions')">
          <div class="sa-action-icon"><i class="fa fa-credit-card"></i></div>
          <div class="sa-action-title">الاشتراكات</div>
          <div class="sa-action-desc">${_saCan('subscriptions_renew') ? 'متابعة الاشتراكات المنتهية والنشطة وتجديدها مباشرة.' : 'استعراض حالة اشتراكات الشركات (عرض فقط).'}</div>
        </button>` : ''}
        <button class="sa-action-card purple" onclick="openSuperAdminAccountSettings()">
          <div class="sa-action-icon"><i class="fa fa-key"></i></div>
          <div class="sa-action-title">بيانات الدخول</div>
          <div class="sa-action-desc">تغيير اسمك المعروض ووظيفتك وبيانات الدخول.</div>
        </button>
        ${_saCan('platform_view') || _saCan('platform_announce') || _saCan('platform_whatsapp') ? `<button class="sa-action-card" onclick="showPage('sa-platform')">
          <div class="sa-action-icon"><i class="fa fa-bullhorn"></i></div>
          <div class="sa-action-title">إعدادات المنصة</div>
          <div class="sa-action-desc">${_saCan('platform_whatsapp') || _saCan('platform_announce') ? 'رقم واتساب الدعم وإشعارات البث لجميع الشركات.' : 'استعراض إعدادات المنصة والإشعارات (عرض فقط).'}</div>
        </button>` : ''}
        ${_saCan('team_manage') ? `<button class="sa-action-card blue" onclick="showPage('sa-team')">
          <div class="sa-action-icon"><i class="fa fa-users-cog"></i></div>
          <div class="sa-action-title">فريق السوبر أدمن</div>
          <div class="sa-action-desc">إضافة حسابات وتحديد صلاحيات كل عضو في الفريق.</div>
        </button>` : ''}
        ${_saCan('users_view') || _saCan('users_manage') ? `<button class="sa-action-card purple" onclick="showPage('sa-users')">
          <div class="sa-action-icon"><i class="fa fa-user-shield"></i></div>
          <div class="sa-action-title">مستخدمي الشركات</div>
          <div class="sa-action-desc">${_saCan('users_manage') ? 'إنشاء وإدارة حسابات مديري الشركات.' : 'استعراض مستخدمي الشركات (عرض فقط).'}</div>
        </button>` : ''}
      </div>

      <div class="sa-table-wrap">
        <div class="sa-table-title">
          <span>🏢 الشركات — ملخص سريع</span>
          <button class="sa-btn sa-btn-blue" onclick="showPage('sa-companies')"><i class="fa fa-arrow-left"></i> عرض الكل</button>
        </div>
        <table>
          <thead><tr>
            <th>#</th><th>الشركة</th><th>الكود</th><th>الحالة</th><th>الاشتراك</th><th>الموظفون</th><th>الانتهاء</th><th>إجراءات</th>
          </tr></thead>
          <tbody>
            ${companies ? companies.map((c, i) => {
              const subStatus = c.subscription_status || 'pending';
              const statusBadge = { active:'badge-active', expired:'badge-expired', suspended:'badge-suspended', pending:'badge-pending' }[subStatus] || 'badge-pending';
              const compStatus = { active:'badge-active', suspended:'badge-suspended', pending:'badge-pending' }[c.status] || 'badge-pending';
              const endDate = c.end_date ? new Date(c.end_date).toLocaleDateString('ar-IQ') : '—';
              return `<tr>
                <td>${i+1}</td>
                <td><strong>${c.company_name}</strong></td>
                <td><span dir="ltr" style="font-family:monospace;color:var(--accent)">${c.company_code}</span></td>
                <td><span class="${compStatus}">${{ active:'نشط', suspended:'موقوف', pending:'معلق' }[c.status] || c.status}</span></td>
                <td><span class="${statusBadge}">${{ active:'نشط', expired:'منتهٍ', suspended:'موقوف', pending:'معلق' }[subStatus] || subStatus}</span></td>
                <td>${c.employee_count || 0} / ${c.max_employees || 50}</td>
                <td style="white-space:nowrap">${endDate}</td>
                <td>
                  ${_saCan('subscriptions_renew') ? `<button class="sa-btn sa-btn-primary" onclick="openRenewSubscription(${c.id}, ${_saOnclickArg(c.company_name)})"><i class="fa fa-plus"></i> تمديد</button>` : ''}
                  <button class="sa-btn sa-btn-soft" onclick="openCompanyDetails(${c.id})"><i class="fa fa-eye"></i> تفاصيل</button>
                </td>
              </tr>`;
            }).join('') : '<tr><td colspan="8" style="text-align:center;color:var(--text-muted)">لا توجد شركات</td></tr>'}
          </tbody>
        </table>
      </div>`;
  } catch(e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ في تحميل البيانات: ' + esc(e.message || e) + '</div>';
    console.error('buildSuperAdminDashboard:', e);
  }
  if (typeof syncSystemVersionLabels === 'function') syncSystemVersionLabels();
}

async function buildSACompaniesPage() {
  const el = document.getElementById('sa-companies-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    const companies = await sb_getCompanies();
    el.innerHTML = `
      ${_saPageBannerHtml()}
      <div class="sa-hero">
        <div>
          <h3>🏢 إدارة الشركات</h3>
          <p>تحكم كامل بحالة الشركات وحدود الموظفين وتجديد اشتراكات كل شركة.</p>
        </div>
        <div class="sa-hero-actions">
          ${_saCan('companies_create') ? '<button class="sa-btn sa-btn-primary" onclick="openAddCompanyForm()"><i class="fa fa-plus"></i> إضافة شركة</button>' : ''}
          <button class="sa-btn sa-btn-soft" onclick="buildSACompaniesPage()"><i class="fa fa-rotate"></i> تحديث</button>
        </div>
      </div>
      <div class="sa-table-wrap">
        <div class="sa-table-title">
          <span>قائمة الشركات</span>
          <span style="color:var(--text-muted);font-size:12px">${(companies || []).length} شركة</span>
        </div>
        <table>
          <thead><tr><th>#</th><th>الشركة</th><th>الكود</th><th>الحالة</th><th>الموظفون</th><th>المنشئ</th><th>إجراءات</th></tr></thead>
          <tbody>
            ${(companies || []).map((c, i) => {
              const badge = { active:'badge-active', suspended:'badge-suspended', pending:'badge-pending' }[c.status] || 'badge-pending';
              return `<tr>
                <td>${i+1}</td>
                <td><strong>${c.company_name}</strong></td>
                <td><span dir="ltr" style="font-family:monospace;color:var(--accent)">${c.company_code}</span></td>
                <td><span class="${badge}">${{active:'نشط',suspended:'موقوف',pending:'معلق'}[c.status]||c.status}</span></td>
                <td>${c.employee_count||0} / ${c.max_employees||50}</td>
                <td style="font-size:11px;color:var(--text-muted)">${c.created_at ? new Date(c.created_at).toLocaleDateString('ar-IQ') : '—'}</td>
                <td style="white-space:nowrap">
                  ${_saCan('companies_edit') ? `<button class="sa-btn sa-btn-soft" onclick="openEditCompanyFormById(${c.id})"><i class="fa fa-pen"></i> تعديل</button>` : ''}
                  ${_saCan('companies_suspend') ? `<button class="sa-btn ${c.status==='active'?'sa-btn-danger':'sa-btn-success'}" onclick="toggleCompanyStatus(${c.id},${_saOnclickArg(c.status)},${_saOnclickArg(c.company_name)})"><i class="fa ${c.status==='active'?'fa-pause':'fa-play'}"></i> ${c.status==='active'?'إيقاف':'تفعيل'}</button>` : ''}
                  ${_saCan('subscriptions_renew') ? `<button class="sa-btn sa-btn-primary" onclick="openRenewSubscription(${c.id}, ${_saOnclickArg(c.company_name)})"><i class="fa fa-credit-card"></i> اشتراك</button>` : ''}
                  ${_saCan('companies_delete') ? `<button class="sa-btn sa-btn-danger" onclick="deleteCompany(${c.id}, ${_saOnclickArg(c.company_name)}, ${c.employee_count || 0})"><i class="fa fa-trash"></i> حذف</button>` : ''}
                </td>
              </tr>`;
            }).join('') || '<tr><td colspan="7" style="text-align:center;color:var(--text-muted)">لا توجد شركات</td></tr>'}
          </tbody>
        </table>
      </div>`;
  } catch(e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ: ' + esc(e.message || e) + '</div>';
  }
}

async function buildSASubscriptionsPage() {
  const el = document.getElementById('sa-subscriptions-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    const subs = await sb_getAllSubscriptions();
    el.innerHTML = `
      ${_saPageBannerHtml()}
      <div class="sa-hero">
        <div>
          <h3>💳 إدارة الاشتراكات</h3>
          <p>متابعة حالة اشتراك كل شركة وتفعيل أو تمديد الخطة من داخل لوحة التحكم.</p>
        </div>
        <div class="sa-hero-actions">
          <button class="sa-btn sa-btn-soft" onclick="buildSASubscriptionsPage()"><i class="fa fa-rotate"></i> تحديث</button>
        </div>
      </div>
      <div class="sa-table-wrap">
        <div class="sa-table-title">
          <span>💳 الاشتراكات</span>
          <span style="color:var(--text-muted);font-size:12px">${(subs || []).length} سجل</span>
        </div>
        <table>
          <thead><tr><th>#</th><th>الشركة</th><th>الخطة</th><th>البداية</th><th>الانتهاء</th><th>الحالة</th><th>المبلغ</th><th>متبقي</th><th>إجراءات</th></tr></thead>
          <tbody>
            ${(subs || []).map((s, i) => {
              const badge = {active:'badge-active',expired:'badge-expired',suspended:'badge-suspended',pending:'badge-pending'}[s.status]||'badge-pending';
              const label = {active:'نشط',expired:'منتهٍ',suspended:'موقوف',pending:'معلق'}[s.status]||s.status;
              var daysLeft = (typeof sb_subscriptionDaysLeft === 'function')
                ? sb_subscriptionDaysLeft(s)
                : (s.end_date ? Math.max(0, Math.round((new Date(s.end_date) - new Date()) / 86400000)) : 0);
              var remainLabel = s.status === 'active' && daysLeft >= 0
                ? (daysLeft + ' يوم')
                : '—';
              return `<tr>
                <td>${i+1}</td>
                <td><strong>${s.companies?.company_name||'—'}</strong></td>
                <td><span class="badge-super">${s.plan_name}</span></td>
                <td>${s.start_date||'—'}</td>
                <td>${s.end_date||'—'}</td>
                <td><span class="${badge}">${label}</span></td>
                <td>${formatSaMoney(s.amount)}</td>
                <td>${remainLabel}</td>
                <td style="white-space:nowrap">
                  ${_saCan('subscriptions_edit') || _saCan('companies_edit') || _saCan('subscriptions_renew') ? `<button class="sa-btn sa-btn-soft" onclick="openEditSubscriptionForm(${s.id})"><i class="fa fa-pen"></i> تعديل</button>` : ''}
                  ${_saCan('subscriptions_renew') ? `<button class="sa-btn sa-btn-primary" onclick="openRenewSubscription(${s.company_id}, ${_saOnclickArg(s.companies?.company_name || '')})"><i class="fa fa-plus"></i> تمديد</button>` : ''}
                  ${_saCan('subscriptions_delete') ? `<button class="sa-btn sa-btn-danger" onclick="deleteSubscription(${s.id}, ${_saOnclickArg(s.companies?.company_name || '')})"><i class="fa fa-trash"></i> حذف</button>` : ''}
                </td>
              </tr>`;
            }).join('')||'<tr><td colspan="9" style="text-align:center;color:var(--text-muted)">لا توجد اشتراكات</td></tr>'}
          </tbody>
        </table>
      </div>`;
  } catch(e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ: ' + esc(e.message || e) + '</div>';
  }
}

async function buildSAUsersPage() {
  const el = document.getElementById('sa-users-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    const [users, companies] = await Promise.all([
      sb_getSaasUsers(null),
      sb_getCompanies()
    ]);
    const esc = function (s) {
      return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
    };
    const allUsers = users || [];
    const byCompany = {};
    allUsers.filter(function (u) { return u.role !== 'super_admin'; }).forEach(function (u) {
      var cid = u.company_id || 0;
      if (!byCompany[cid]) byCompany[cid] = [];
      byCompany[cid].push(u);
    });
    const expandedId = window._saExpandedCompanyId != null ? parseInt(window._saExpandedCompanyId, 10) : null;
    const statusMap = { active: ['badge-active', 'نشطة'], suspended: ['badge-suspended', 'موقوفة'], pending: ['badge-pending', 'معلقة'] };
    const subMap = { active: ['badge-active', 'نشط'], expired: ['badge-expired', 'منتهٍ'], suspended: ['badge-suspended', 'موقوف'], pending: ['badge-pending', 'معلق'] };
    const roleLabel = { company_admin: '🏢 مدير شركة', company_user: '👤 مستخدم' };

    function renderUserRows(list, companyId) {
      if (!list.length) {
        return '<tr><td colspan="6" style="text-align:center;color:var(--text-muted);padding:18px">لا يوجد مستخدمون لهذه الشركة — أنشئ حساب مدير</td></tr>';
      }
      return list.map(function (u, i) {
        return '<tr>' +
          '<td>' + (i + 1) + '</td>' +
          '<td><strong dir="ltr">' + esc(u.username) + '</strong></td>' +
          '<td style="font-size:12px">' + esc(u.email || '—') + '</td>' +
          '<td><span class="badge-active">' + (roleLabel[u.role] || u.role) + '</span></td>' +
          '<td style="font-size:11px;color:var(--text-muted)">' + (u.last_login ? new Date(u.last_login).toLocaleString('ar-IQ') : 'لم يدخل بعد') + '</td>' +
          '<td style="white-space:nowrap">' +
            (_saCan('users_manage') ? '<button class="sa-btn sa-btn-soft" onclick="openEditCompanyAdminForm(' + companyId + ',' + u.id + ',' + _saOnclickArg(u.username) + ')"><i class="fa fa-pen"></i> تعديل</button> ' : '') +
            (_saCan('users_manage') ? '<button class="sa-btn sa-btn-danger" onclick="deleteSaasUser(' + u.id + ',' + _saOnclickArg(u.username) + ')"><i class="fa fa-trash"></i> حذف</button>' : '') +
          '</td>' +
        '</tr>';
      }).join('');
    }

    const companyPanels = (companies || []).map(function (c) {
      var cid = c.id;
      var compUsers = byCompany[cid] || [];
      var expanded = expandedId === cid;
      var st = statusMap[c.status] || ['badge-pending', c.status || '—'];
      var sub = subMap[c.subscription_status] || ['badge-pending', c.subscription_status || '—'];
      var endDate = c.end_date ? new Date(c.end_date).toLocaleDateString('ar-IQ') : '—';
      return '<div class="sa-company-panel' + (expanded ? ' expanded' : '') + '" id="sa-company-panel-' + cid + '">' +
        '<button type="button" class="sa-company-panel-head" onclick="toggleSACompanyPanel(' + cid + ')">' +
          '<div class="sa-company-panel-title">' +
            '<i class="fa fa-building"></i>' +
            '<strong>' + esc(c.company_name) + '</strong>' +
            '<span class="badge-pending" dir="ltr">' + esc(c.company_code) + '</span>' +
          '</div>' +
          '<div class="sa-company-panel-meta">' +
            '<span><i class="fa fa-users"></i> ' + compUsers.length + ' مستخدم</span>' +
            '<span><i class="fa fa-id-badge"></i> ' + (c.employee_count || 0) + ' موظف</span>' +
            '<span class="' + st[0] + '">' + st[1] + '</span>' +
            '<i class="fa fa-chevron-down sa-company-chevron"></i>' +
          '</div>' +
        '</button>' +
        '<div class="sa-company-panel-body"' + (expanded ? '' : ' hidden') + '>' +
          '<div class="sa-company-details-grid">' +
            '<div><span>الكود</span><strong dir="ltr">' + esc(c.company_code) + '</strong></div>' +
            '<div><span>الحالة</span><strong class="' + st[0] + '">' + st[1] + '</strong></div>' +
            '<div><span>الاشتراك</span><strong class="' + sub[0] + '">' + sub[1] + '</strong></div>' +
            '<div><span>انتهاء الاشتراك</span><strong>' + endDate + '</strong></div>' +
            '<div><span>الموظفون</span><strong>' + (c.employee_count || 0) + ' / ' + (c.max_employees || 50) + '</strong></div>' +
            '<div><span>عدد المستخدمين</span><strong>' + compUsers.length + '</strong></div>' +
          '</div>' +
          '<div class="sa-company-panel-actions">' +
            (_saCan('users_manage') ? '<button class="sa-btn sa-btn-primary" onclick="openAddCompanyAdminForm(' + cid + ',' + _saOnclickArg(c.company_name) + ')"><i class="fa fa-user-plus"></i> إنشاء حساب مدير</button>' : '') +
            '<button class="sa-btn sa-btn-blue" onclick="showPage(\'sa-companies\')"><i class="fa fa-building"></i> إدارة الشركة</button>' +
            (_saCan('subscriptions_renew') ? '<button class="sa-btn sa-btn-soft" onclick="openRenewSubscription(' + cid + ',' + _saOnclickArg(c.company_name) + ')"><i class="fa fa-credit-card"></i> الاشتراك</button>' : '') +
          '</div>' +
          '<div class="sa-table-wrap" style="margin-top:12px;border-radius:12px">' +
            '<div class="sa-table-title"><span>مستخدمو ' + esc(c.company_name) + '</span></div>' +
            '<table><thead><tr><th>#</th><th>المستخدم</th><th>البريد</th><th>الدور</th><th>آخر دخول</th><th>إجراءات</th></tr></thead>' +
            '<tbody>' + renderUserRows(compUsers, cid) + '</tbody></table>' +
          '</div>' +
          '<p class="sa-company-hint">بعد إنشاء الحساب، يسجّل مدير الشركة الدخول بنفس اسم المستخدم وكلمة المرور ليرى لوحة الشركة كاملة (موظفون، حضور، رواتب…).</p>' +
        '</div>' +
      '</div>';
    }).join('');

    el.innerHTML = `
      ${_saPageBannerHtml()}
      <div class="sa-hero">
        <div>
          <h3>👤 مستخدمو الشركات</h3>
          <p>اضغط على اسم الشركة لعرض التفاصيل والمستخدمين. أنشئ حساب مدير لكل شركة للدخول إلى لوحة إدارة الشركة.</p>
        </div>
        <div class="sa-hero-actions">
          <button class="sa-btn sa-btn-soft" onclick="openSuperAdminAccountSettings()"><i class="fa fa-user-cog"></i> حساب السوبر أدمن</button>
          <button class="sa-btn sa-btn-soft" onclick="buildSAUsersPage()"><i class="fa fa-rotate"></i> تحديث</button>
        </div>
      </div>

      ${_saCan('team_manage') ? '<div style="margin-bottom:16px;padding:12px 16px;border:1px solid var(--border);border-radius:12px;font-size:13px;color:var(--text-secondary)"><i class="fa fa-users-cog"></i> لإدارة فريق السوبر أدمن والصلاحيات: <button class="sa-btn sa-btn-soft" onclick="showPage(\'sa-team\')">فريق السوبر أدمن</button></div>' : ''}

      <div class="sa-company-accordion">
        ${companyPanels || '<div style="text-align:center;padding:30px;color:var(--text-muted)">لا توجد شركات</div>'}
      </div>`;
  } catch(e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ: ' + esc(e.message || e) + '</div>';
  }
}

function toggleSACompanyPanel(companyId) {
  var cid = parseInt(companyId, 10);
  if (!cid) return;
  if (window._saExpandedCompanyId === cid) {
    window._saExpandedCompanyId = null;
  } else {
    window._saExpandedCompanyId = cid;
  }
  buildSAUsersPage();
}

async function openAddCompanyAdminForm(companyId, companyName) {
  if (!_saCan('users_manage')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية إدارة مستخدمي الشركات', ...swalTheme() });
    return;
  }
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    Swal.fire({ icon: 'warning', title: 'للسوبر أدمن فقط', ...swalTheme() });
    return;
  }
  const { value: vals } = await Swal.fire({
    title: '🏢 إنشاء حساب — ' + (companyName || ''),
    html: `
      <div style="text-align:right">
        <div style="background:rgba(0,212,170,0.08);border:1px solid rgba(0,212,170,0.2);border-radius:10px;padding:10px 12px;margin-bottom:12px;font-size:12px;color:var(--text-secondary)">
          هذا الحساب يفتح <b>لوحة إدارة الشركة</b> كاملة (موظفون، حضور، رواتب، إعدادات…).
        </div>
        <div class="form-group"><label>اسم المستخدم *</label><input id="ca-user" class="swal2-input" placeholder="admin_company" dir="ltr" autocomplete="off"></div>
        <div class="form-group"><label>الاسم المعروض</label><input id="ca-display" class="swal2-input" placeholder="مدير الشركة"></div>
        <div class="form-group"><label>البريد الإلكتروني</label><input id="ca-email" class="swal2-input" type="email" dir="ltr"></div>
        <div class="form-group"><label>كلمة المرور *</label><input id="ca-pass" class="swal2-input" type="password" placeholder="6 أحرف على الأقل"></div>
        <div class="form-group"><label>الدور</label>
          <select id="ca-role" class="swal2-input">
            <option value="company_admin">مدير شركة (صلاحيات كاملة)</option>
            <option value="company_user">مستخدم شركة (حسب الصلاحيات)</option>
          </select>
        </div>
      </div>`,
    confirmButtonText: 'إنشاء الحساب',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    width: 520,
    ...swalTheme(),
    preConfirm: function () {
      var u = document.getElementById('ca-user').value.trim().toLowerCase();
      var p = document.getElementById('ca-pass').value;
      if (!u || u.length < 3) { Swal.showValidationMessage('اسم المستخدم 3 أحرف على الأقل'); return false; }
      if (!p || p.length < 6) { Swal.showValidationMessage('كلمة المرور 6 أحرف على الأقل'); return false; }
      return {
        username: u,
        display_name: document.getElementById('ca-display').value.trim(),
        email: document.getElementById('ca-email').value.trim(),
        password: p,
        role: document.getElementById('ca-role').value
      };
    }
  });
  if (!vals) return;
  window._saExpandedCompanyId = companyId;
  var res = await sb_upsertCompanyUser(vals, companyId);
  if (res.ok) {
    Swal.fire({
      icon: 'success',
      title: 'تم إنشاء الحساب',
      html: 'يمكن لـ <b dir="ltr">' + vals.username + '</b> تسجيل الدخول الآن والوصول إلى لوحة <b>' + (companyName || 'الشركة') + '</b>.',
      timer: 2800,
      showConfirmButton: false,
      ...swalTheme()
    });
    buildSAUsersPage();
  } else {
    Swal.fire({ icon: 'error', title: 'فشل الإنشاء', text: res.error || 'حدث خطأ', ...swalTheme() });
  }
}

async function openEditCompanyAdminForm(companyId, userId, username) {
  const { value: vals } = await Swal.fire({
    title: '✏️ تعديل — ' + (username || ''),
    html: `
      <div style="text-align:right">
        <div class="form-group"><label>كلمة مرور جديدة</label><input id="eu-pass" class="swal2-input" type="password" placeholder="اتركها فارغة بدون تغيير"></div>
        <div class="form-group"><label>الدور</label>
          <select id="eu-role" class="swal2-input">
            <option value="company_admin">مدير شركة</option>
            <option value="company_user">مستخدم شركة</option>
          </select>
        </div>
      </div>`,
    confirmButtonText: 'حفظ',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: function () {
      return {
        id: userId,
        username: username,
        password: document.getElementById('eu-pass').value,
        role: document.getElementById('eu-role').value
      };
    }
  });
  if (!vals) return;
  if (vals.password && vals.password.length < 6) {
    Swal.fire({ icon: 'warning', title: 'كلمة المرور قصيرة', text: '6 أحرف على الأقل', ...swalTheme() });
    return;
  }
  var payload = { id: vals.id, username: vals.username, role: vals.role };
  if (vals.password) payload.password = vals.password;
  var res = await sb_upsertCompanyUser(payload, companyId);
  if (res.ok) {
    Swal.fire({ icon: 'success', title: 'تم التحديث', timer: 1400, showConfirmButton: false, ...swalTheme() });
    buildSAUsersPage();
  } else {
    Swal.fire({ icon: 'error', title: 'فشل التحديث', text: res.error || '', ...swalTheme() });
  }
}

async function buildSAPlatformPage() {
  var el = document.getElementById('sa-platform-content');
  if (!el) return;
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">هذه الصفحة للسوبر أدمن فقط</div>';
    return;
  }
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  if (typeof sb_loadPlatformGlobals === 'function') await sb_loadPlatformGlobals();
  var waSub = (window.platformSettings && window.platformSettings.supportWhatsApp) || '07733344940';
  var waTeam = (window.platformSettings && window.platformSettings.supportWhatsAppTeam) || waSub;
  var announcements = (window.platformSettings && window.platformSettings.announcements) || [];
  var esc = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml : function (s) { return String(s || ''); };
  var waEditable = _saCan('platform_whatsapp');
  var waFieldClass = waEditable ? 'setting-input' : 'setting-input sa-input-readonly';
  el.innerHTML =
    _saPageBannerHtml() +
    '<div class="sa-hero">' +
      '<div><h3>📢 إعدادات المنصة</h3><p>أرقام واتساب وإشعارات البث — التحديث فوري عند جميع الشركات.</p></div>' +
      '<div class="sa-hero-actions"><button class="sa-btn sa-btn-soft" onclick="buildSAPlatformPage()"><i class="fa fa-rotate"></i> تحديث</button></div>' +
    '</div>' +
    '<div class="sa-table-wrap" style="margin-bottom:16px">' +
      '<div class="sa-table-title"><span><i class="fa-brands fa-whatsapp"></i> أرقام واتساب</span></div>' +
      '<div style="padding:16px;display:flex;flex-direction:column;gap:16px">' +
        '<div>' +
          '<label class="setting-label">واتساب تفعيل / تجديد الاشتراك</label>' +
          '<input type="text" class="' + waFieldClass + '" id="sa-platform-wa-sub" dir="ltr" value="' + esc(waSub) + '" placeholder="07733344940" style="width:100%;margin-top:6px"' + (waEditable ? '' : ' disabled readonly') + '>' +
          '<div style="font-size:11px;color:var(--text-muted);margin-top:4px">يظهر في تنبيهات انتهاء الاشتراك وزر «تجديد عبر واتساب».</div>' +
        '</div>' +
        '<div>' +
          '<label class="setting-label">واتساب فريق الدعم</label>' +
          '<input type="text" class="' + waFieldClass + '" id="sa-platform-wa-team" dir="ltr" value="' + esc(waTeam) + '" placeholder="07733344940" style="width:100%;margin-top:6px"' + (waEditable ? '' : ' disabled readonly') + '>' +
          '<div style="font-size:11px;color:var(--text-muted);margin-top:4px">يظهر في «تواصل مع فريق الدعم» داخل لوحات الشركات. إن تُرك فارغاً يُستخدم رقم الاشتراك.</div>' +
        '</div>' +
        '<div style="display:flex;gap:10px;flex-wrap:wrap">' +
          (_saCan('platform_whatsapp') ? '<button class="sa-btn sa-btn-primary" onclick="savePlatformWhatsAppNumbers()"><i class="fa fa-save"></i> حفظ الأرقام</button>' : '<span style="font-size:12px;color:var(--text-muted)">لا تملك صلاحية تعديل أرقام واتساب</span>') +
          '<button type="button" class="sa-btn sa-btn-soft" onclick="contactSuperAdmin(\'اختبار — تجديد اشتراك\')"><i class="fa fa-credit-card"></i> اختبار الاشتراك</button>' +
          '<button type="button" class="sa-btn sa-btn-soft" onclick="contactSupportTeam(\'اختبار — فريق الدعم\')"><i class="fa fa-headset"></i> اختبار الدعم</button>' +
        '</div>' +
      '</div>' +
    '</div>' +
    '<div class="sa-table-wrap">' +
      '<div class="sa-table-title">' +
        '<span><i class="fa fa-bullhorn"></i> إشعارات الشركات</span>' +
        (_saCan('platform_announce') ? '<button class="sa-btn sa-btn-primary" onclick="openCreatePlatformAnnouncement()"><i class="fa fa-plus"></i> إرسال إشعار</button>' : '') +
      '</div>' +
      '<table><thead><tr><th>#</th><th>المرسل</th><th>الرسالة</th><th>التاريخ</th><th>إجراءات</th></tr></thead><tbody>' +
      (announcements.length ? announcements.map(function (ann, i) {
        var when = ann.updatedAt || ann.createdAt;
        var whenLabel = when ? new Date(when).toLocaleString('ar-IQ') : '—';
        return '<tr><td>' + (i + 1) + '</td><td style="font-size:12px;white-space:nowrap">' + esc(_annSenderLabel(ann)) + '</td><td style="max-width:420px;white-space:pre-wrap">' + esc(ann.message) + '</td><td style="font-size:12px;color:var(--text-muted);white-space:nowrap">' + whenLabel + '</td><td style="white-space:nowrap">' +
          (_saCan('platform_announce_manage') ? '<button class="sa-btn sa-btn-soft" onclick="openEditPlatformAnnouncement(\'' + String(ann.id).replace(/'/g, "\\'") + '\')"><i class="fa fa-pen"></i> تعديل</button> ' : '') +
          (_saCan('platform_announce_manage') ? '<button class="sa-btn sa-btn-danger" onclick="deletePlatformAnnouncement(\'' + String(ann.id).replace(/'/g, "\\'") + '\')"><i class="fa fa-trash"></i> حذف</button>' : '') +
        '</td></tr>';
      }).join('') : '<tr><td colspan="5" style="text-align:center;color:var(--text-muted);padding:24px">لا توجد إشعارات مرسلة</td></tr>') +
      '</tbody></table></div>';
}

async function savePlatformWhatsAppNumbers() {
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') return;
  if (!_saCan('platform_whatsapp')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية تعديل أرقام واتساب', ...swalTheme() });
    return;
  }
  var subIn = document.getElementById('sa-platform-wa-sub');
  var teamIn = document.getElementById('sa-platform-wa-team');
  var subVal = subIn ? String(subIn.value || '').trim() : '';
  var teamVal = teamIn ? String(teamIn.value || '').trim() : '';
  var subNorm = typeof normalizeWhatsAppPhone === 'function' ? normalizeWhatsAppPhone(subVal) : '';
  if (!subVal || !subNorm) {
    Swal.fire({ icon: 'warning', title: 'رقم الاشتراك غير صالح', text: 'أدخل رقم واتساب للاشتراك مثل 07733344940', ...swalTheme() });
    return;
  }
  var teamNorm = teamVal ? (typeof normalizeWhatsAppPhone === 'function' ? normalizeWhatsAppPhone(teamVal) : '') : '';
  if (teamVal && !teamNorm) {
    Swal.fire({ icon: 'warning', title: 'رقم الدعم غير صالح', ...swalTheme() });
    return;
  }
  var res = await sb_savePlatformGlobals({
    supportWhatsApp: subVal,
    supportWhatsAppTeam: teamVal || subVal
  });
  if (!res.ok) {
    Swal.fire({ icon: 'error', title: 'لم يُحفظ', text: res.error || '', ...swalTheme() });
    return;
  }
  Swal.fire({
    icon: 'success',
    title: 'تم حفظ الأرقام',
    html: 'اشتراك: <b dir="ltr">' + subNorm + '</b><br>دعم: <b dir="ltr">' + (teamNorm || subNorm) + '</b>',
    timer: 2400,
    showConfirmButton: false,
    ...swalTheme()
  });
}

function _getPlatformAnnouncementsList() {
  return ((window.platformSettings && window.platformSettings.announcements) || []).slice();
}

async function _reloadPlatformAnnouncementsForEdit() {
  if (typeof sb_fetchPlatformAnnouncementsRemote === 'function') {
    try {
      var remote = await sb_fetchPlatformAnnouncementsRemote();
      if (remote != null) {
        window.platformSettings = window.platformSettings || {};
        window.platformSettings.announcements = remote;
        if (typeof _savePlatformAnnouncementsCache === 'function') {
          _savePlatformAnnouncementsCache(remote);
        }
        return remote.slice();
      }
    } catch (e) {
      console.warn('_reloadPlatformAnnouncementsForEdit:', e);
    }
  }
  if (typeof sb_loadPlatformGlobals === 'function') await sb_loadPlatformGlobals();
  return _getPlatformAnnouncementsList();
}

async function openCreatePlatformAnnouncement() {
  if (!_saCan('platform_announce')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية إرسال الإشعارات', ...swalTheme() });
    return;
  }
  var result = await Swal.fire({
    title: '📢 إرسال إشعار لجميع الشركات',
    input: 'textarea',
    inputPlaceholder: 'اكتب رسالة الإشعار...',
    inputAttributes: { rows: 4, style: 'direction:rtl;text-align:right' },
    showCancelButton: true,
    confirmButtonText: 'إرسال',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    inputValidator: function (v) { if (!v || !String(v).trim()) return 'اكتب نص الإشعار'; }
  });
  if (!result.value) return;
  var list = await _reloadPlatformAnnouncementsForEdit();
  var senderMeta = typeof platformAnnouncementSenderMeta === 'function'
    ? platformAnnouncementSenderMeta()
    : { senderId: saasCurrentUser && saasCurrentUser.id, senderName: saasCurrentUser && saasCurrentUser.username, senderJobTitle: '' };
  list.unshift(Object.assign({
    id: 'ann_' + Date.now(),
    message: String(result.value).trim(),
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  }, senderMeta));
  var res = await sb_savePlatformGlobals({ announcements: list });
  if (!res.ok) {
    Swal.fire({ icon: 'error', title: 'فشل الإرسال', text: res.error || '', ...swalTheme() });
    return;
  }
  Swal.fire({ icon: 'success', title: 'تم إرسال الإشعار', text: 'سيظهر عند جميع الشركات فوراً', timer: 2000, showConfirmButton: false, ...swalTheme() });
  buildSAPlatformPage();
}

async function openEditPlatformAnnouncement(annId) {
  if (!_saCan('platform_announce_manage')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية تعديل الإشعارات', ...swalTheme() });
    return;
  }
  var list = await _reloadPlatformAnnouncementsForEdit();
  var ann = list.find(function (a) { return a && a.id === annId; });
  if (!ann) {
    Swal.fire({ icon: 'warning', title: 'الإشعار غير موجود', ...swalTheme() });
    buildSAPlatformPage();
    return;
  }
  var result = await Swal.fire({
    title: '✏️ تعديل الإشعار',
    input: 'textarea',
    inputValue: ann.message || '',
    inputAttributes: { rows: 4, style: 'direction:rtl;text-align:right' },
    showCancelButton: true,
    confirmButtonText: 'حفظ',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    inputValidator: function (v) { if (!v || !String(v).trim()) return 'اكتب نص الإشعار'; }
  });
  if (!result.value) return;
  ann.message = String(result.value).trim();
  ann.updatedAt = new Date().toISOString();
  var res = await sb_savePlatformGlobals({ announcements: list });
  if (!res.ok) {
    Swal.fire({ icon: 'error', title: 'فشل التعديل', text: res.error || '', ...swalTheme() });
    return;
  }
  Swal.fire({ icon: 'success', title: 'تم التعديل', timer: 1400, showConfirmButton: false, ...swalTheme() });
  buildSAPlatformPage();
}

async function deletePlatformAnnouncement(annId) {
  if (!_saCan('platform_announce_manage')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية حذف الإشعارات', ...swalTheme() });
    return;
  }
  var list = await _reloadPlatformAnnouncementsForEdit();
  var ann = list.find(function (a) { return a && a.id === annId; });
  if (!ann) {
    buildSAPlatformPage();
    return;
  }
  var confirm = await Swal.fire({
    title: 'حذف الإشعار؟',
    text: 'سيختفي فوراً من جميع الشركات ولا يبقى أثر له في الإشعارات',
    icon: 'warning',
    showCancelButton: true,
    confirmButtonText: 'نعم، احذف',
    cancelButtonText: 'إلغاء',
    confirmButtonColor: '#e53e3e',
    ...swalTheme()
  });
  if (!confirm.isConfirmed) return;
  list = list.filter(function (a) { return a && a.id !== annId; });
  var res = await sb_savePlatformGlobals({ announcements: list });
  if (!res.ok) {
    Swal.fire({ icon: 'error', title: 'فشل الحذف', text: res.error || '', ...swalTheme() });
    return;
  }
  Swal.fire({ icon: 'success', title: 'تم الحذف', timer: 1200, showConfirmButton: false, ...swalTheme() });
  buildSAPlatformPage();
}

async function buildSAStatsPage() {
  const el = document.getElementById('sa-stats-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    const [companies, subs] = await Promise.all([sb_getCompanies(), sb_getAllSubscriptions()]);
    const now = new Date();
    const thisMonth = now.getMonth();
    const thisYear = now.getFullYear();
    const newThisMonth = (companies||[]).filter(c => {
      const d = new Date(c.created_at); return d.getMonth()===thisMonth && d.getFullYear()===thisYear;
    }).length;
    const revenueThisMonth = (subs||[]).filter(s => {
      const d = new Date(s.created_at); return d.getMonth()===thisMonth && d.getFullYear()===thisYear;
    }).reduce((a,s) => a + saMoneyInt(s.amount), 0);
    const totalRevenue = (subs||[]).reduce((a,s) => a + saMoneyInt(s.amount), 0);
    const activeSubs = (subs||[]).filter(s => s.status==='active').length;
    const expiredSubs = (subs||[]).filter(s => s.status==='expired').length;
    const totalEmps = (companies||[]).reduce((a,c) => a+(parseInt(c.employee_count)||0), 0);

    el.innerHTML = `
      ${_saPageBannerHtml()}
      <div class="sa-stat-grid">
        <div class="sa-stat-card blue"><div class="sa-stat-val">${(companies||[]).length}</div><div class="sa-stat-lbl">إجمالي الشركات</div></div>
        <div class="sa-stat-card green"><div class="sa-stat-val">${newThisMonth}</div><div class="sa-stat-lbl">شركات جديدة هذا الشهر</div></div>
        <div class="sa-stat-card green"><div class="sa-stat-val">${activeSubs}</div><div class="sa-stat-lbl">اشتراكات نشطة</div></div>
        <div class="sa-stat-card red"><div class="sa-stat-val">${expiredSubs}</div><div class="sa-stat-lbl">اشتراكات منتهية</div></div>
        <div class="sa-stat-card gold"><div class="sa-stat-val">${totalRevenue.toLocaleString()}</div><div class="sa-stat-lbl">إجمالي الإيرادات</div></div>
        <div class="sa-stat-card gold"><div class="sa-stat-val">${revenueThisMonth.toLocaleString()}</div><div class="sa-stat-lbl">إيرادات هذا الشهر</div></div>
        <div class="sa-stat-card"><div class="sa-stat-val">${totalEmps}</div><div class="sa-stat-lbl">إجمالي الموظفين</div></div>
      </div>
      <div class="sa-table-wrap" style="margin-top:16px">
        <div class="sa-table-title">
          <span>توزيع الإيرادات حسب الشركة</span>
        </div>
        <table>
          <thead><tr><th>الشركة</th><th>عدد الاشتراكات</th><th>إجمالي المدفوع</th></tr></thead>
          <tbody>
            ${(companies||[]).map(c => {
              const compSubs = (subs||[]).filter(s => s.company_id===c.id);
              const rev = compSubs.reduce((a,s) => a + saMoneyInt(s.amount), 0);
              return `<tr><td>${esc(c.company_name || '')}</td><td>${compSubs.length}</td><td>${rev.toLocaleString()}</td></tr>`;
            }).join('')}
          </tbody>
        </table>
      </div>
      <div class="sa-table-wrap" style="margin-top:16px">
        <div class="sa-table-title">
          <span>🔒 تقرير الصحة الأمنية</span>
          <button type="button" class="sa-btn sa-btn-primary" data-sa-action="security-health-report"><i class="fa fa-shield-alt"></i> تشغيل التقرير</button>
        </div>
        <div id="sa-security-health-report" style="padding:12px;font-size:13px;color:var(--text-muted)">اضغط «تشغيل التقرير» لفحص شامل: RLS، صلاحيات anon، هجمات الدخول، سجل التدقيق، وتقييم اختراق.</div>
      </div>`;
    bindSaActionClicks();
  } catch(e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ: ' + esc(e.message || e) + '</div>';
  }
}

function _saSecSeverityLabel(sev) {
  var map = {
    critical: 'حرج',
    high: 'مرتفع',
    medium: 'متوسط',
    low: 'منخفض',
    info: 'معلومة'
  };
  return map[sev] || sev || '—';
}

function _saSecStatusIcon(st) {
  if (st === 'pass') return '<span class="sa-sec-icon pass">✓</span>';
  if (st === 'fail') return '<span class="sa-sec-icon fail">✕</span>';
  if (st === 'warn') return '<span class="sa-sec-icon warn">!</span>';
  return '<span class="sa-sec-icon">•</span>';
}

function _renderSecurityHealthReportHtml(report) {
  if (!report || report.ok === false) return '';
  var verdict = report.verdict || (report.enterprise_ready ? 'safe' : 'warning');
  var verdictClass = 'sa-sec-verdict-' + verdict;
  var score = typeof report.security_score === 'number' ? report.security_score : (report.enterprise_ready ? 92 : 55);
  var findings = Array.isArray(report.findings) ? report.findings : [];
  var failFindings = findings.filter(function (f) { return f && (f.status === 'fail' || f.status === 'warn'); });
  var passFindings = findings.filter(function (f) { return f && f.status === 'pass'; });
  var metrics = report.metrics || {};
  var noRls = report.tables_without_rls || [];
  var noTenant = report.rpcs_without_tenant_validation || [];

  var findingsHtml = failFindings.map(function (f) {
    var itemsHtml = '';
    if (f.items && Array.isArray(f.items) && f.items.length) {
      if (typeof f.items[0] === 'string') {
        itemsHtml = '<pre class="sa-sec-items-pre">' + esc(f.items.join(', ')) + '</pre>';
      } else {
        itemsHtml = '<pre class="sa-sec-items-pre">' + esc(JSON.stringify(f.items, null, 2)) + '</pre>';
      }
    }
    return ''
      + '<div class="sa-sec-finding sa-sec-finding-' + esc(f.status || 'warn') + '">'
      + '<div class="sa-sec-finding-head">'
      + _saSecStatusIcon(f.status)
      + '<div><strong>' + esc(f.title_ar || f.id || '') + '</strong>'
      + ' <span class="sa-sec-sev sa-sec-sev-' + esc(f.severity || 'medium') + '">' + esc(_saSecSeverityLabel(f.severity)) + '</span></div>'
      + '</div>'
      + '<p class="sa-sec-finding-detail">' + esc(f.detail_ar || '') + '</p>'
      + (f.recommendation_ar && f.recommendation_ar !== '—'
        ? '<p class="sa-sec-finding-rec"><i class="fa fa-lightbulb"></i> ' + esc(f.recommendation_ar) + '</p>' : '')
      + itemsHtml
      + '</div>';
  }).join('');

  var passHtml = passFindings.length
    ? '<details class="sa-sec-pass-details"><summary>✓ فحوصات ناجحة (' + passFindings.length + ')</summary>'
      + passFindings.map(function (f) {
        return '<div class="sa-sec-finding sa-sec-finding-pass">'
          + _saSecStatusIcon('pass') + ' <span>' + esc(f.title_ar || '') + '</span>'
          + '<small>' + esc(f.detail_ar || '') + '</small></div>';
      }).join('')
      + '</details>'
    : '';

  var attackNote = report.attack_suspected
    ? '<div class="sa-sec-alert attack"><strong>تنبيه:</strong> رُصد نشاط يشبه الهجوم. راجع محاولات الدخول الفاشلة وحسابات السوبر أدمن فوراً.</div>'
    : '';
  var compromisedNote = report.compromised_confirmed
    ? '<div class="sa-sec-alert critical"><strong>اختراق مؤكّد:</strong> تواصل مع الدعم الفني فوراً.</div>'
    : '';

  return ''
    + '<div class="sa-sec-report ' + verdictClass + '">'
    + '<div class="sa-sec-verdict-banner">'
    + '<div class="sa-sec-score-ring" data-score="' + score + '"><span>' + score + '</span><small>/100</small></div>'
    + '<div class="sa-sec-verdict-text">'
    + '<h3>' + esc(report.verdict_ar || (report.enterprise_ready ? 'النظام آمن' : 'يوجد مخاطر')) + '</h3>'
    + '<p>' + esc(report.verdict_summary_ar || '') + '</p>'
    + '<div class="sa-sec-meta">'
    + '<span><i class="fa fa-clock"></i> ' + esc(report.generated_at ? new Date(report.generated_at).toLocaleString('ar-IQ') : '—') + '</span>'
    + '<span><i class="fa fa-shield-alt"></i> Enterprise: ' + (report.enterprise_ready ? '✓ جاهز' : '✕ غير جاهز') + '</span>'
    + '</div></div></div>'
    + attackNote + compromisedNote
    + '<div class="sa-sec-metrics">'
    + '<div class="sa-sec-metric"><b>' + (metrics.failed_logins_24h != null ? metrics.failed_logins_24h : '—') + '</b><span>دخول فاشل / 24س</span></div>'
    + '<div class="sa-sec-metric"><b>' + (metrics.audit_deletes_24h != null ? metrics.audit_deletes_24h : '—') + '</b><span>حذف / 24س</span></div>'
    + '<div class="sa-sec-metric"><b>' + (metrics.super_admin_active_count != null ? metrics.super_admin_active_count : '—') + '</b><span>سوبر أدمن</span></div>'
    + '<div class="sa-sec-metric"><b>' + (Array.isArray(noRls) ? noRls.length : 0) + '</b><span>جداول بلا RLS</span></div>'
    + '<div class="sa-sec-metric"><b>' + (Array.isArray(noTenant) ? noTenant.length : 0) + '</b><span>RPCs للمراجعة</span></div>'
    + '</div>'
    + (findingsHtml ? '<div class="sa-sec-findings-title"><i class="fa fa-search"></i> نتائج الفحص التفصيلية</div>' + findingsHtml : '')
    + passHtml
    + '<details class="sa-sec-tech-details"><summary>تفاصيل تقنية (RLS / Policies / RPCs)</summary>'
    + '<div class="sa-stat-grid" style="margin:12px 0">'
    + '<div class="sa-stat-card blue"><div class="sa-stat-val">' + (report.table_count || 0) + '</div><div class="sa-stat-lbl">جداول</div></div>'
    + '<div class="sa-stat-card green"><div class="sa-stat-val">' + (report.tables_rls_enabled || 0) + '</div><div class="sa-stat-lbl">RLS مفعّل</div></div>'
    + '<div class="sa-stat-card"><div class="sa-stat-val">' + (report.policy_count || 0) + '</div><div class="sa-stat-lbl">Policies</div></div>'
    + '<div class="sa-stat-card"><div class="sa-stat-val">' + ((report.security_definer_rpcs || []).length) + '</div><div class="sa-stat-lbl">DEFINER RPCs</div></div>'
    + '</div>'
    + '<p><b>Policies USING(true):</b> ' + ((report.policies_using_true || []).length) + '</p>'
    + '<p><b>Policies WITH CHECK(true):</b> ' + ((report.policies_with_check_true || []).length) + '</p>'
    + (Array.isArray(noTenant) && noTenant.length
      ? '<p><b>RPCs للمراجعة:</b></p><pre class="sa-sec-items-pre">' + esc(noTenant.join(', ')) + '</pre>' : '')
    + '</details>'
    + '</div>';
}

async function runSecurityHealthReport(triggerBtn) {
  var box = document.getElementById('sa-security-health-report');
  if (!box) {
    if (typeof BasmaToast !== 'undefined') BasmaToast.warn('افتح صفحة الإحصائيات أولاً');
    return;
  }
  if (typeof syncSaasSessionContext === 'function') syncSaasSessionContext();
  if (triggerBtn && triggerBtn.disabled !== undefined) {
    triggerBtn.disabled = true;
    triggerBtn.style.opacity = '0.7';
  }
  box.innerHTML = '<i class="fa fa-spinner fa-spin"></i> جارٍ التحليل...';
  try {
    if (typeof sb_securityHealthReport !== 'function') {
      box.innerHTML = '<span style="color:#fc8181">ملف الاتصال غير محمّل — حدّث الصفحة</span>';
      return;
    }
    var report = await sb_securityHealthReport();
    if (!report) {
      box.innerHTML = '<span style="color:#fc8181">تعذّر التقرير — أعد تسجيل الدخول ثم حاول مجدداً</span>';
      return;
    }
    if (report.ok === false) {
      var errMsg = report.error || 'unknown';
      if (errMsg === 'auth_session_required' || errMsg === 'super_admin_only') {
        errMsg = errMsg === 'super_admin_only'
          ? 'هذا التقرير للسوبر أدمن فقط'
          : 'انتهت الجلسة — سجّل الخروج ثم الدخول مجدداً';
      }
      box.innerHTML = '<span style="color:#fc8181">تعذّر التقرير: ' + esc(errMsg) + '</span>';
      return;
    }
    box.innerHTML = _renderSecurityHealthReportHtml(report);
  } catch (e) {
    box.innerHTML = '<span style="color:#fc8181">' + esc(e.message || e) + '</span>';
  } finally {
    if (triggerBtn && triggerBtn.disabled !== undefined) {
      triggerBtn.disabled = false;
      triggerBtn.style.opacity = '';
    }
  }
}
window.runSecurityHealthReport = runSecurityHealthReport;

function _saHealthBadge(ok) {
  return ok ? '<span class="badge-active">OK</span>' : '<span class="badge-expired">DOWN</span>';
}

function _saFormatDt(val) {
  if (!val) return '—';
  try { return new Date(val).toLocaleString('ar-IQ'); } catch (e) { return String(val); }
}

async function buildSAMonitoringPage() {
  var el = document.getElementById('sa-monitoring-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    var snap = typeof sb_systemMonitoringSnapshot === 'function' ? await sb_systemMonitoringSnapshot() : null;
    if (!snap || snap.ok === false) {
      var errDetail = (snap && snap.error) || '';
      if (snap && snap.message) errDetail = snap.message;
      el.innerHTML = '<div style="color:#fc8181;padding:20px">تعذّر تحميل المراقبة: ' + esc(errDetail || 'الخدمة غير متاحة') +
        '<br><small style="opacity:0.85">إن استمرت المشكلة تواصل مع الدعم الفني</small></div>';
      return;
    }
    var sec = snap.security || {};
    var rls = snap.rls || {};
    var co = snap.companies || {};
    var us = snap.users || {};
    var audit = (snap.audit && snap.audit.logs) ? snap.audit.logs : [];
    var health = snap.system_health || {};
    var ver = snap.system_version || (window.BasmaApp && BasmaApp.version) || '1.0.0';
    var auditDeletes = audit.filter(function (a) { return a && /delete/i.test(String(a.action || '')); });
    var auditSalary = audit.filter(function (a) { return a && /salary|payroll/i.test(String(a.action || '') + String(a.category || '')); });
    var auditPerms = audit.filter(function (a) { return a && /perm|permission|super_admin|team_manage/i.test(String(a.action || '') + String(a.details || '')); });

    el.innerHTML = ''
      + _saPageBannerHtml()
      + '<div class="sa-hero"><div><h3>🛡️ System Monitoring</h3>'
      + '<p>مراقبة أمنية وتشغيلية للمنصة — KYNO <strong>v' + esc(String(ver).replace(/^v/, '')) + '</strong></p></div></div>'

      + '<div class="sa-table-wrap"><div class="sa-table-title"><span>🔒 Security</span></div>'
      + '<div class="sa-stat-grid" style="padding:12px">'
      + '<div class="sa-stat-card blue"><div class="sa-stat-val">' + (sec.table_count || 0) + '</div><div class="sa-stat-lbl">جداول</div></div>'
      + '<div class="sa-stat-card green"><div class="sa-stat-val">' + (sec.policy_count || 0) + '</div><div class="sa-stat-lbl">RLS Policies</div></div>'
      + '<div class="sa-stat-card"><div class="sa-stat-val">' + (sec.rpc_count || 0) + '</div><div class="sa-stat-lbl">RPCs</div></div>'
      + '<div class="sa-stat-card"><div class="sa-stat-val">' + (sec.trigger_count || 0) + '</div><div class="sa-stat-lbl">Triggers</div></div>'
      + '<div class="sa-stat-card ' + (sec.enterprise_ready ? 'green' : (sec.verdict === 'attack_suspected' || sec.verdict === 'critical' ? 'red' : 'yellow')) + '">'
      + '<div class="sa-stat-val">' + (sec.security_score != null ? sec.security_score : (sec.enterprise_ready ? '✓' : '!')) + '</div>'
      + '<div class="sa-stat-lbl">درجة الأمان /100</div></div>'
      + '<div class="sa-stat-card ' + (sec.verdict === 'safe' ? 'green' : sec.verdict === 'warning' ? 'yellow' : 'red') + '">'
      + '<div class="sa-stat-val" style="font-size:18px">' + (sec.verdict === 'safe' ? '✓' : sec.verdict === 'attack_suspected' ? '⚠' : '!') + '</div>'
      + '<div class="sa-stat-lbl">آخر تقرير أمني</div></div>'
      + '</div>'
      + (sec.verdict_ar ? '<p style="padding:0 12px 12px;font-size:13px;line-height:1.7">' + esc(sec.verdict_ar) + '<br><small style="color:var(--text-muted)">' + esc(sec.verdict_summary_ar || '') + '</small></p>' : '')
      + '<p style="padding:0 12px 12px;font-size:12px;color:var(--text-muted)">generated: ' + esc(sec.generated_at || snap.generated_at || '') + '</p></div>'

      + '<div class="sa-stat-grid">'
      + '<div class="sa-stat-card blue"><div class="sa-stat-val">' + (co.total || 0) + '</div><div class="sa-stat-lbl">شركات</div></div>'
      + '<div class="sa-stat-card green"><div class="sa-stat-val">' + (co.active || 0) + '</div><div class="sa-stat-lbl">نشطة</div></div>'
      + '<div class="sa-stat-card yellow"><div class="sa-stat-val">' + (co.suspended || 0) + '</div><div class="sa-stat-lbl">معلقة</div></div>'
      + '<div class="sa-stat-card red"><div class="sa-stat-val">' + (co.expired || 0) + '</div><div class="sa-stat-lbl">منتهية</div></div>'
      + '<div class="sa-stat-card"><div class="sa-stat-val">' + (us.total || 0) + '</div><div class="sa-stat-lbl">مستخدمون</div></div>'
      + '<div class="sa-stat-card"><div class="sa-stat-val">' + (us.employees || 0) + '</div><div class="sa-stat-lbl">موظفون</div></div>'
      + '</div>'

      + '<div class="sa-table-wrap" style="margin-top:16px"><div class="sa-table-title"><span>⚡ System Health</span></div>'
      + '<table><thead><tr><th>Service</th><th>Status</th><th>Label</th></tr></thead><tbody>'
      + ['database', 'auth', 'storage', 'supabase'].map(function (k) {
        var h = health[k] || {};
        var svcLabel = { database: 'قاعدة البيانات', auth: 'المصادقة', storage: 'التخزين', supabase: 'المزامنة' }[k] || k;
        var lbl = h.label || '';
        if (typeof sanitizeCloudUserText === 'function') lbl = sanitizeCloudUserText(lbl);
        else lbl = String(lbl).replace(/supabase/gi, 'المزامنة');
        return '<tr><td>' + svcLabel + '</td><td>' + _saHealthBadge(h.ok === true) + '</td><td>' + esc(lbl) + '</td></tr>';
      }).join('')
      + '</tbody></table></div>'

      + '<div class="sa-table-wrap" style="margin-top:16px"><div class="sa-table-title"><span>👤 آخر تسجيلات الدخول</span></div>'
      + '<table><thead><tr><th>المستخدم</th><th>الدور</th><th>الشركة</th><th>آخر دخول</th></tr></thead><tbody>'
      + ((us.recent_logins || []).slice(0, 20).map(function (u) {
        return '<tr><td>' + esc(u.display_name || u.username || '') + '</td><td>' + esc(u.role || '') + '</td><td>' + esc(u.company_id || '—') + '</td><td>' + _saFormatDt(u.last_login) + '</td></tr>';
      }).join('') || '<tr><td colspan="4">—</td></tr>')
      + '</tbody></table></div>'

      + '<div class="sa-table-wrap" style="margin-top:16px"><div class="sa-table-title"><span>📋 Audit — آخر ' + audit.length + ' عملية</span></div>'
      + '<p style="padding:8px 12px;font-size:12px">حذف: ' + auditDeletes.length + ' • رواتب: ' + auditSalary.length + ' • صلاحيات: ' + auditPerms.length + '</p>'
      + '<div style="max-height:360px;overflow:auto"><table><thead><tr><th>الوقت</th><th>الشركة</th><th>الفاعل</th><th>الإجراء</th><th>التفاصيل</th></tr></thead><tbody>'
      + (audit.slice(0, 100).map(function (a) {
        return '<tr><td style="white-space:nowrap">' + _saFormatDt(a.created_at) + '</td><td>' + esc(a.company_id || '') + '</td><td>' + esc(a.actor_name || a.actor_role || '') + '</td><td>' + esc(a.action || '') + '</td><td>' + esc((a.details || a.target_name || '').slice(0, 80)) + '</td></tr>';
      }).join('') || '<tr><td colspan="5">—</td></tr>')
      + '</tbody></table></div></div>';
  } catch (e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ: ' + esc(e.message || e) + '</div>';
  }
}

var _saBackupLastPayload = null;
var _saBackupCompanies = [];

function _saBackupStatusBadge(status) {
  var map = {
    active: ['badge-active', 'نشط'],
    suspended: ['badge-suspended', 'موقوف'],
    pending: ['badge-pending', 'معلق'],
    expired: ['badge-expired', 'منتهٍ']
  };
  var st = map[status] || ['badge-pending', status || '—'];
  return '<span class="' + st[0] + '">' + st[1] + '</span>';
}

function _saBackupCompanyCardHtml(c, selected) {
  var cid = c.id;
  var name = esc(c.company_name || ('شركة #' + cid));
  var code = esc(c.company_code || '—');
  var emps = parseInt(c.employee_count, 10) || 0;
  var max = parseInt(c.max_employees, 10) || 50;
  var cls = 'sa-backup-co-item' + (selected ? ' active' : '');
  return ''
    + '<button type="button" class="' + cls + '" data-id="' + cid + '"'
    + ' onclick="saSelectBackupCompany(' + cid + ')">'
    + '<span class="sa-backup-co-check" aria-hidden="true"><i class="fa fa-check"></i></span>'
    + '<span class="sa-backup-co-icon"><i class="fa fa-building"></i></span>'
    + '<span class="sa-backup-co-body">'
    + '<strong class="sa-backup-co-name">' + name + '</strong>'
    + '<span class="sa-backup-co-code" dir="ltr">' + code + '</span>'
    + '</span>'
    + '<span class="sa-backup-co-meta">'
    + '<span><i class="fa fa-users"></i> ' + emps + ' / ' + max + '</span>'
    + _saBackupStatusBadge(c.status)
    + '</span>'
    + '</button>';
}

function saSelectBackupCompany(companyId) {
  var hidden = document.getElementById('sa-backup-company');
  if (hidden) hidden.value = String(companyId);
  document.querySelectorAll('.sa-backup-co-item').forEach(function (btn) {
    btn.classList.toggle('active', parseInt(btn.getAttribute('data-id'), 10) === companyId);
  });
  saSyncBackupCompanyPreview();
}

function saFilterBackupCompanies() {
  var q = String((document.getElementById('sa-backup-search') || {}).value || '').trim().toLowerCase();
  var list = document.getElementById('sa-backup-company-list');
  if (!list) return;
  var visible = 0;
  list.querySelectorAll('.sa-backup-co-item').forEach(function (btn) {
    var cid = parseInt(btn.getAttribute('data-id'), 10);
    var c = (_saBackupCompanies || []).find(function (x) { return x.id === cid; });
    var name = String((c && c.company_name) || '').toLowerCase();
    var code = String((c && c.company_code) || '').toLowerCase();
    var show = !q || name.indexOf(q) >= 0 || code.indexOf(q) >= 0 || String(cid).indexOf(q) >= 0;
    btn.style.display = show ? '' : 'none';
    if (show) visible++;
  });
  var empty = document.getElementById('sa-backup-empty');
  if (empty) empty.style.display = visible ? 'none' : 'block';
}

function saSyncBackupCompanyPreview() {
  var hidden = document.getElementById('sa-backup-company');
  var preview = document.getElementById('sa-backup-preview');
  if (!preview || !hidden) return;
  var cid = parseInt(hidden.value, 10);
  var c = (_saBackupCompanies || []).find(function (x) { return x.id === cid; });
  if (!c) {
    preview.innerHTML = '<p class="sa-backup-preview-empty">اختر شركة من القائمة</p>';
    return;
  }
  var endDate = c.end_date ? new Date(c.end_date).toLocaleDateString('ar-IQ') : '—';
  preview.innerHTML = ''
    + '<div class="sa-backup-preview-grid">'
    + '<div><span>المعرّف</span><strong>#' + c.id + '</strong></div>'
    + '<div><span>الكود</span><strong dir="ltr">' + esc(c.company_code || '—') + '</strong></div>'
    + '<div><span>الحالة</span><strong>' + _saBackupStatusBadge(c.status) + '</strong></div>'
    + '<div><span>الموظفون</span><strong>' + (c.employee_count || 0) + ' / ' + (c.max_employees || 50) + '</strong></div>'
    + '<div><span>انتهاء الاشتراك</span><strong>' + endDate + '</strong></div>'
    + '<div><span>ملف التصدير</span><strong dir="ltr">kyno-backup-company-' + c.id + '-*.json</strong></div>'
    + '</div>';
}

async function buildSABackupPage() {
  var el = document.getElementById('sa-backup-content');
  if (!el) return;
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  try {
    var companies = typeof sb_getCompanies === 'function' ? await sb_getCompanies() : [];
    _saBackupCompanies = companies || [];
    var stats = null;
    var snap = typeof sb_systemMonitoringSnapshot === 'function' ? await sb_systemMonitoringSnapshot() : null;
    if (snap && snap.backup_stats) stats = snap.backup_stats;
    var firstId = _saBackupCompanies.length ? _saBackupCompanies[0].id : 0;
    var listHtml = _saBackupCompanies.length
      ? _saBackupCompanies.map(function (c, i) { return _saBackupCompanyCardHtml(c, i === 0); }).join('')
      : '';

    el.innerHTML = ''
      + _saPageBannerHtml()
      + '<div class="sa-hero"><div><h3>💾 Backup Center</h3><p>تصدير واستيراد وتحقق من سلامة نسخ الشركات (Super Admin)</p></div></div>'
      + '<div class="sa-stat-grid">'
      + '<div class="sa-stat-card"><div class="sa-stat-val" id="sa-backup-last-date">—</div><div class="sa-stat-lbl">آخر نسخة</div></div>'
      + '<div class="sa-stat-card blue"><div class="sa-stat-val" id="sa-backup-size">—</div><div class="sa-stat-lbl">حجم النسخة</div></div>'
      + '<div class="sa-stat-card green"><div class="sa-stat-val" id="sa-backup-records">' + (stats ? ((stats.employees || 0) + (stats.attendance || 0) + (stats.salary_records || 0)) : '—') + '</div><div class="sa-stat-lbl">سجلات (منصة)</div></div>'
      + '</div>'
      + '<div class="sa-backup-panel">'
      + '<div class="sa-backup-picker">'
      + '<div class="sa-backup-picker-head">'
      + '<div><h4><i class="fa fa-building"></i> اختر الشركة</h4><p>حدّد الشركة قبل التصدير أو الاستيراد</p></div>'
      + '<div class="sa-backup-search-wrap">'
      + '<i class="fa fa-search"></i>'
      + '<input type="search" id="sa-backup-search" class="sa-backup-search" placeholder="بحث بالاسم أو الكود..." oninput="saFilterBackupCompanies()" autocomplete="off">'
      + '</div>'
      + '</div>'
      + '<div class="sa-backup-company-list" id="sa-backup-company-list">' + listHtml + '</div>'
      + '<p id="sa-backup-empty" class="sa-backup-empty" style="display:none"><i class="fa fa-search"></i> لا توجد شركة مطابقة للبحث</p>'
      + '<input type="hidden" id="sa-backup-company" value="' + firstId + '">'
      + '<div class="sa-backup-preview" id="sa-backup-preview"></div>'
      + '</div>'
      + '<div class="sa-backup-actions">'
      + '<button class="sa-btn sa-btn-primary sa-backup-action-btn" onclick="saRunBackupExport()" ' + (firstId ? '' : 'disabled') + '><i class="fa fa-download"></i> تصدير كامل</button>'
      + '<button class="sa-btn sa-btn-soft sa-backup-action-btn" onclick="saVerifyBackupIntegrity()"><i class="fa fa-check-circle"></i> التحقق من السلامة</button>'
      + '<label class="sa-btn sa-btn-blue sa-backup-action-btn sa-backup-import-label"><i class="fa fa-upload"></i> استيراد كامل<input type="file" accept="application/json,.json" onchange="saRunBackupImport(this)"></label>'
      + '</div>'
      + '<pre id="sa-backup-log" class="sa-backup-log">جاهز — اختر شركة ثم اضغط «تصدير كامل».</pre>'
      + '</div>';
    saSyncBackupCompanyPreview();
  } catch (e) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">خطأ: ' + esc(e.message || e) + '</div>';
  }
}

function _saBackupLog(msg) {
  var box = document.getElementById('sa-backup-log');
  if (box) box.textContent = String(msg || '');
}

function _saBackupCountRecords(payload) {
  if (!payload) return 0;
  return ['employees', 'attendance', 'salary_records', 'leaves', 'departments'].reduce(function (n, k) {
    var arr = payload[k];
    return n + (Array.isArray(arr) ? arr.length : 0);
  }, 0);
}

async function saRunBackupExport() {
  var sel = document.getElementById('sa-backup-company');
  var cid = sel ? parseInt(sel.value, 10) : 0;
  if (!cid) {
    _saBackupLog('اختر شركة أولاً من القائمة.');
    return;
  }
  var co = (_saBackupCompanies || []).find(function (c) { return c.id === cid; });
  var coLabel = co ? (co.company_name || ('#' + cid)) : ('#' + cid);
  _saBackupLog('جارٍ تصدير «' + coLabel + '»...');
  var data = typeof sb_superExportCompany === 'function' ? await sb_superExportCompany(cid) : null;
  if (!data || data.ok === false) {
    _saBackupLog('فشل: ' + ((data && data.error) || 'الخدمة غير متاحة — تواصل مع الدعم الفني'));
    return;
  }
  _saBackupLastPayload = data;
  var json = JSON.stringify(data, null, 2);
  var blob = new Blob([json], { type: 'application/json' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'kyno-backup-company-' + cid + '-' + new Date().toISOString().slice(0, 10) + '.json';
  a.click();
  URL.revokeObjectURL(a.href);
  var sizeKb = Math.round(json.length / 1024);
  var rec = _saBackupCountRecords(data);
  var dateEl = document.getElementById('sa-backup-last-date');
  var sizeEl = document.getElementById('sa-backup-size');
  var recEl = document.getElementById('sa-backup-records');
  if (dateEl) dateEl.textContent = new Date().toLocaleString('ar-IQ');
  if (sizeEl) sizeEl.textContent = sizeKb + ' KB';
  if (recEl) recEl.textContent = String(rec);
  _saBackupLog('تم التصدير — ' + rec + ' سجل، ' + sizeKb + ' KB');
}

async function saVerifyBackupIntegrity() {
  var payload = _saBackupLastPayload;
  if (!payload) {
    _saBackupLog('صدّر نسخة أولاً أو استورد ملف JSON.');
    return;
  }
  var cid = parseInt(payload.company_id, 10);
  var issues = [];
  ['employees', 'attendance', 'salary_records', 'leaves'].forEach(function (k) {
    (payload[k] || []).forEach(function (row, i) {
      if (row && row.company_id != null && parseInt(row.company_id, 10) !== cid) {
        issues.push(k + '[' + i + '] company_id=' + row.company_id);
      }
    });
  });
  if (!payload.ok && payload.ok !== true) issues.push('missing ok flag');
  if (!cid) issues.push('missing company_id');
  _saBackupLog(issues.length ? ('فشل التحقق:\n' + issues.slice(0, 10).join('\n')) : ('✓ سلامة OK — company ' + cid + ', ' + _saBackupCountRecords(payload) + ' records'));
}

async function saRunBackupImport(input) {
  var file = input && input.files && input.files[0];
  if (!file) return;
  try {
    var text = await file.text();
    var payload = JSON.parse(text);
    _saBackupLastPayload = payload;
    var sel = document.getElementById('sa-backup-company');
    if ((!payload.company_id || payload.company_id <= 0) && sel && sel.value) {
      payload.company_id = parseInt(sel.value, 10);
    }
    if (!payload.company_id) {
      _saBackupLog('فشل: ملف النسخة لا يحتوي company_id — اختر الشركة من القائمة أو استخدم ملف تصدير KYNO');
      input.value = '';
      return;
    }
    if (typeof sb_importCompanyFull !== 'function') {
      _saBackupLog('sb_importCompanyFull غير متاح');
      return;
    }
    _saBackupLog('جارٍ الاستيراد للشركة #' + payload.company_id + '...');
    var res = await sb_importCompanyFull(payload);
    if (res && res.ok) {
      _saBackupLog('✓ استيراد OK — ' + JSON.stringify(res.imported || res));
      saVerifyBackupIntegrity();
    } else {
      var errMsg = (res && res.error) || 'unknown';
      if (errMsg === 'no_company_context') {
        errMsg += ' — تواصل مع الدعم الفني لتحديث النظام';
      }
      if (String(errMsg).indexOf('departments') >= 0 && String(errMsg).indexOf('updated_at') >= 0) {
        errMsg += ' — تواصل مع الدعم الفني';
      }
      if (String(errMsg).indexOf('saas_v3_write_audit') >= 0 || String(errMsg).indexOf('is not unique') >= 0) {
        errMsg += ' — تواصل مع الدعم الفني';
      }
      if (String(errMsg).indexOf('date_iso') >= 0) {
        errMsg += ' — تواصل مع الدعم الفني';
      }
      _saBackupLog('فشل: ' + errMsg);
    }
  } catch (e) {
    _saBackupLog('خطأ استيراد: ' + (e.message || e));
  }
  input.value = '';
}

window.buildSAMonitoringPage = buildSAMonitoringPage;
window.buildSABackupPage = buildSABackupPage;
window.buildSASettingsPage = buildSASettingsPage;
window.saSelectBackupCompany = saSelectBackupCompany;
window.saFilterBackupCompanies = saFilterBackupCompanies;
window.saRunBackupExport = saRunBackupExport;
window.saVerifyBackupIntegrity = saVerifyBackupIntegrity;
window.saRunBackupImport = saRunBackupImport;

async function buildSASettingsPage() {
  var el = document.getElementById('sa-settings-content');
  if (!el) return;
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">هذه الصفحة للسوبر أدمن فقط</div>';
    return;
  }
  var currentTheme = document.documentElement.getAttribute('data-theme') || localStorage.getItem('attendance_theme') || 'dark';
  var displayName = typeof getSuperAdminDisplayName === 'function'
    ? getSuperAdminDisplayName(saasCurrentUser)
    : (saasCurrentUser.display_name || saasCurrentUser.username || 'Super Admin');
  el.innerHTML =
    '<div class="sa-hero">' +
      '<div class="sa-hero-text">' +
        '<h2 class="sa-hero-title"><i class="fa fa-cog"></i> الإعدادات</h2>' +
        '<p class="sa-hero-sub">تفضيلات واجهة السوبر أدمن — تُحفظ في السحابة لكل مستخدم</p>' +
      '</div>' +
    '</div>' +
    '<div class="settings-layout" style="margin-top:20px">' +
      '<section class="settings-section">' +
        '<h2 class="settings-section-title"><i class="fa fa-user"></i> الحساب</h2>' +
        '<div class="card settings-app-card">' +
          '<div class="app-info-rows">' +
            '<div class="app-info-row"><span class="app-info-label">الاسم</span><span class="app-info-value">' + displayName + '</span></div>' +
            '<div class="app-info-row"><span class="app-info-label">المستخدم</span><span class="app-info-value">' + (saasCurrentUser.username || '—') + '</span></div>' +
          '</div>' +
        '</div>' +
      '</section>' +
      '<section class="settings-section">' +
        '<h2 class="settings-section-title"><i class="fa fa-palette"></i> مظهر الواجهة</h2>' +
        '<div class="card">' +
          '<div class="theme-switch-wrap">' +
            '<div><div style="font-weight:700;font-size:14px">وضع العرض</div>' +
            '<div class="settings-hint-inline">يُطبَّق فوراً ويُحفظ في قاعدة البيانات</div></div>' +
            '<div class="theme-switch-btns">' +
              '<button type="button" class="theme-btn' + (currentTheme === 'dark' ? ' active' : '') + '" id="sa-theme-btn-dark" onclick="setTheme(\'dark\')"><i class="fa fa-moon"></i> داكن</button>' +
              '<button type="button" class="theme-btn' + (currentTheme === 'light' ? ' active' : '') + '" id="sa-theme-btn-light" onclick="setTheme(\'light\')"><i class="fa fa-sun"></i> فاتح</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</section>' +
      '<section class="settings-section">' +
        '<h2 class="settings-section-title"><i class="fa fa-info-circle"></i> النظام</h2>' +
        '<div class="card settings-app-card">' +
          '<div class="app-info-rows">' +
            '<div class="app-info-row"><span class="app-info-label">المنتج</span><span class="app-info-value">بصمة KYNO</span></div>' +
            '<div class="app-info-row"><span class="app-info-label">الإصدار</span><span class="app-info-value app-version-badge">v1.0.0</span></div>' +
          '</div>' +
        '</div>' +
      '</section>' +
    '</div>';
}

// ======= Super Admin Team =======
async function buildSATeamPage() {
  var el = document.getElementById('sa-team-content');
  if (!el) return;
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">هذه الصفحة للسوبر أدمن فقط</div>';
    return;
  }
  if (!_saCan('team_manage')) {
    el.innerHTML = '<div style="padding:24px;text-align:center;color:var(--text-muted)"><i class="fa fa-lock fa-2x"></i><p style="margin-top:12px">لا تملك صلاحية إدارة فريق السوبر أدمن</p></div>';
    return;
  }
  el.innerHTML = '<div style="text-align:center;padding:40px"><i class="fa fa-spinner fa-spin fa-2x"></i></div>';
  var esc = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml : function (s) { return String(s || ''); };
  var res = typeof sb_listSuperAdmins === 'function' ? await sb_listSuperAdmins() : { ok: false, data: [] };
  if (!res.ok) {
    el.innerHTML = '<div style="color:#fc8181;padding:20px">تعذّر تحميل الفريق: ' + esc(res.error || 'unknown') + '<br><small>تواصل مع الدعم الفني إن استمرت المشكلة</small></div>';
    return;
  }
  var team = res.data || [];
  el.innerHTML =
    _saPageBannerHtml() +
    '<div class="sa-hero">' +
      '<div><h3>👥 فريق السوبر أدمن</h3><p>إضافة حسابات جديدة، تحديد الاسم والوظيفة، وضبط الصلاحيات التفصيلية لكل عضو.</p></div>' +
      '<div class="sa-hero-actions">' +
        '<button class="sa-btn sa-btn-primary" onclick="openSuperAdminTeamForm()"><i class="fa fa-user-plus"></i> إضافة عضو</button>' +
        '<button class="sa-btn sa-btn-soft" onclick="buildSATeamPage()"><i class="fa fa-rotate"></i> تحديث</button>' +
      '</div>' +
    '</div>' +
    '<div class="sa-table-wrap">' +
      '<div class="sa-table-title"><span>أعضاء الفريق</span><span style="color:var(--text-muted);font-size:12px">' + team.length + '</span></div>' +
      '<table><thead><tr><th>#</th><th>الاسم</th><th>المستخدم</th><th>الوظيفة</th><th>البريد</th><th>آخر دخول</th><th>إجراءات</th></tr></thead><tbody>' +
      (team.length ? team.map(function (u, i) {
        var perms = typeof normalizeSuperAdminPermissions === 'function'
          ? normalizeSuperAdminPermissions(u.permissions || {})
          : (u.permissions || {});
        var permCount = typeof SUPER_ADMIN_PERM_DEFS !== 'undefined'
          ? SUPER_ADMIN_PERM_DEFS.filter(function (d) {
            return d.key !== 'view_only' && d.key !== 'job_title' && perms[d.key] === true;
          }).length
          : '—';
        return '<tr>' +
          '<td>' + (i + 1) + '</td>' +
          '<td><strong>' + esc(u.display_name || u.username) + '</strong>' +
            (u.is_self ? ' <span class="badge-super">أنت</span>' : '') +
            (perms.view_only ? ' <span class="badge-pending">عرض فقط</span>' : '') + '</td>' +
          '<td dir="ltr"><code>' + esc(u.username) + '</code></td>' +
          '<td style="font-size:12px">' + esc((perms && perms.job_title) || '—') + '</td>' +
          '<td style="font-size:12px">' + esc(u.email || '—') + '</td>' +
          '<td style="font-size:11px;color:var(--text-muted)">' + (u.last_login ? new Date(u.last_login).toLocaleString('ar-IQ') : '—') + '</td>' +
          '<td style="white-space:nowrap">' +
            '<button class="sa-btn sa-btn-soft" onclick="openSuperAdminTeamForm(' + u.id + ')"><i class="fa fa-pen"></i> تعديل</button> ' +
            (u.is_self ? '' : '<button class="sa-btn sa-btn-danger" onclick="deleteSuperAdminTeamMember(' + u.id + ',' + _saOnclickArg(u.display_name || u.username) + ')"><i class="fa fa-trash"></i> حذف</button>') +
            '<div style="font-size:10px;color:var(--text-muted);margin-top:4px">' + permCount + ' صلاحية مفعّلة</div>' +
          '</td></tr>';
      }).join('') : '<tr><td colspan="7" style="text-align:center;color:var(--text-muted);padding:24px">لا يوجد أعضاء — أضف أول حساب سوبر أدمن</td></tr>') +
      '</tbody></table></div>';
}

async function openSuperAdminTeamForm(userId) {
  if (!_saCan('team_manage')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', ...swalTheme() });
    return;
  }
  var isEdit = !!userId;
  var existing = null;
  if (isEdit) {
    var listRes = await sb_listSuperAdmins();
    existing = (listRes.data || []).find(function (u) { return u.id === userId; });
    if (!existing) {
      Swal.fire({ icon: 'warning', title: 'العضو غير موجود', ...swalTheme() });
      buildSATeamPage();
      return;
    }
  }
  var perms = {};
  if (existing && existing.permissions) {
    perms = typeof normalizeSuperAdminPermissions === 'function'
      ? normalizeSuperAdminPermissions(existing.permissions)
      : existing.permissions;
  } else if (typeof emptySuperAdminPermissions === 'function') {
    perms = emptySuperAdminPermissions();
  }
  var matrixHtml = typeof superAdminPermissionMatrixHtml === 'function'
    ? superAdminPermissionMatrixHtml(perms, 'sa-team-perm-')
    : '';
  var result = await Swal.fire({
    title: isEdit ? '✏️ تعديل عضو الفريق' : '➕ إضافة سوبر أدمن',
    html:
      '<div style="text-align:right;max-height:65vh;overflow-y:auto;padding:4px">' +
        '<div class="emp-field"><label>اسم المستخدم *</label><input id="sa-team-user" dir="ltr" value="' + (existing ? existing.username : '') + '"></div>' +
        '<div class="emp-field" style="margin-top:8px"><label>الاسم المعروض *</label><input id="sa-team-name" value="' + (existing ? (existing.display_name || '') : '') + '" placeholder="مثال: أحمد محمد"></div>' +
        '<div class="emp-field" style="margin-top:8px"><label>الوظيفة / المسمى</label><input id="sa-team-job" value="' + (existing && perms.job_title ? perms.job_title : '') + '" placeholder="مثال: مدير المنصة"></div>' +
        '<div class="emp-field" style="margin-top:8px"><label>البريد</label><input id="sa-team-email" dir="ltr" value="' + (existing ? (existing.email || '') : '') + '"></div>' +
        '<div class="emp-field" style="margin-top:8px"><label>كلمة المرور' + (isEdit ? ' (اتركها فارغة للإبقاء)' : ' *') + '</label><input id="sa-team-pass" type="password"></div>' +
        '<hr style="border-color:var(--border);margin:14px 0">' +
        '<div style="font-weight:700;margin-bottom:8px;color:var(--accent)">الصلاحيات</div>' +
        matrixHtml +
      '</div>',
    width: 720,
    confirmButtonText: isEdit ? 'حفظ' : 'إنشاء',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    didOpen: function () {
      if (typeof bindSuperAdminPermissionMatrix === 'function') bindSuperAdminPermissionMatrix('sa-team-perm-');
      else if (typeof bindPermissionCards === 'function') bindPermissionCards();
    },
    preConfirm: function () {
      var username = document.getElementById('sa-team-user').value.trim();
      var displayName = document.getElementById('sa-team-name').value.trim();
      var jobTitle = document.getElementById('sa-team-job').value.trim();
      var email = document.getElementById('sa-team-email').value.trim();
      var password = document.getElementById('sa-team-pass').value;
      if (!username || username.length < 3) {
        Swal.showValidationMessage('اسم المستخدم 3 أحرف على الأقل');
        return false;
      }
      if (!displayName) {
        Swal.showValidationMessage('أدخل الاسم المعروض');
        return false;
      }
      if (!isEdit && (!password || password.length < 6)) {
        Swal.showValidationMessage('كلمة المرور 6 أحرف على الأقل');
        return false;
      }
      if (password && password.length > 0 && password.length < 6) {
        Swal.showValidationMessage('كلمة المرور 6 أحرف على الأقل');
        return false;
      }
      var permRead = typeof readSuperAdminPermissionMatrix === 'function'
        ? readSuperAdminPermissionMatrix('sa-team-perm-')
        : {};
      permRead.job_title = jobTitle;
      return { username: username, display_name: displayName, email: email, password: password || null, permissions: permRead, job_title: jobTitle };
    }
  });
  if (!result.value) return;
  var payload = {
    id: isEdit ? userId : null,
    username: result.value.username,
    display_name: result.value.display_name,
    email: result.value.email,
    job_title: result.value.job_title,
    permissions: result.value.permissions,
    is_active: true
  };
  if (result.value.password) payload.password = result.value.password;
  var saveRes = await sb_upsertSuperAdmin(payload);
  if (!saveRes.ok) {
    Swal.fire({ icon: 'error', title: 'لم يُحفظ', text: saveRes.error || '', ...swalTheme() });
    return;
  }
  Swal.fire({ icon: 'success', title: isEdit ? 'تم التحديث' : 'تم إنشاء الحساب', timer: 1600, showConfirmButton: false, ...swalTheme() });
  buildSATeamPage();
}

async function deleteSuperAdminTeamMember(userId, displayName) {
  if (!_saCan('team_manage')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', ...swalTheme() });
    return;
  }
  var confirm = await Swal.fire({
    title: 'حذف عضو الفريق؟',
    html: 'هل تريد حذف حساب <b>' + (displayName || '') + '</b> نهائياً؟',
    icon: 'warning',
    showCancelButton: true,
    confirmButtonText: 'نعم، احذف',
    cancelButtonText: 'إلغاء',
    confirmButtonColor: '#e53e3e',
    ...swalTheme()
  });
  if (!confirm.isConfirmed) return;
  var delRes = await sb_deleteSuperAdmin(userId);
  if (!delRes.ok) {
    Swal.fire({ icon: 'error', title: 'فشل الحذف', text: delRes.error || '', ...swalTheme() });
    return;
  }
  Swal.fire({ icon: 'success', title: 'تم الحذف', timer: 1200, showConfirmButton: false, ...swalTheme() });
  buildSATeamPage();
}

// ======= Super Admin Actions =======
async function openSuperAdminAccountSettings() {
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    Swal.fire({ icon: 'warning', title: 'هذه الخاصية للسوبر أدمن فقط', ...swalTheme() });
    return;
  }
  const currentUsername = saasCurrentUser.username || '';
  const currentEmail = saasCurrentUser.email || '';
  const currentDisplayName = saasCurrentUser.display_name || '';
  const currentJobTitle = typeof getSuperAdminJobTitle === 'function' ? getSuperAdminJobTitle(saasCurrentUser) : '';
  const { value: vals } = await Swal.fire({
    title: '👑 إعدادات حسابي',
    html: `
      <div style="text-align:right">
        <div class="emp-form-section">
          <div class="emp-form-section-title">الملف الشخصي</div>
          <div class="emp-field">
            <label>الاسم المعروض</label>
            <input id="sa-account-display" value="${currentDisplayName}" placeholder="يظهر للشركات عند إرسال الإشعارات">
            <div class="emp-field-hint">يُعرض كاسم المرسل في إشعارات المنصة.</div>
          </div>
          <div class="emp-field" style="margin-top:10px">
            <label>الوظيفة / المسمى</label>
            <input id="sa-account-job" value="${currentJobTitle}" placeholder="مثال: مدير الدعم الفني">
          </div>
          <div class="emp-form-section-title" style="margin-top:16px">بيانات الدخول</div>
          <div class="emp-field">
            <label>اسم المستخدم</label>
            <input id="sa-account-username" value="${currentUsername}" dir="ltr" autocomplete="username">
            <div class="emp-field-hint">سيتم استخدامه في تسجيل الدخول القادم.</div>
          </div>
          <div class="emp-field" style="margin-top:10px">
            <label>البريد الإلكتروني</label>
            <input id="sa-account-email" value="${currentEmail}" dir="ltr" autocomplete="email">
          </div>
          <div class="emp-field" style="margin-top:10px">
            <label>كلمة المرور الجديدة</label>
            <input id="sa-account-password" type="password" placeholder="اتركها فارغة إذا لا تريد تغييرها" autocomplete="new-password">
            <div class="emp-field-hint">6 أحرف على الأقل عند تغييرها.</div>
          </div>
          <div class="emp-field" style="margin-top:10px">
            <label>تأكيد كلمة المرور</label>
            <input id="sa-account-password2" type="password" placeholder="تأكيد كلمة المرور الجديدة" autocomplete="new-password">
          </div>
        </div>
      </div>`,
    width: 560,
    confirmButtonText: 'حفظ التغييرات',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: () => {
      const username = document.getElementById('sa-account-username').value.trim();
      const email = document.getElementById('sa-account-email').value.trim();
      const password = document.getElementById('sa-account-password').value;
      const password2 = document.getElementById('sa-account-password2').value;
      if (!username || username.length < 3) {
        Swal.showValidationMessage('اسم المستخدم يجب أن يكون 3 أحرف على الأقل');
        return false;
      }
      if (password || password2) {
        if (password.length < 6) {
          Swal.showValidationMessage('كلمة المرور يجب أن تكون 6 أحرف على الأقل');
          return false;
        }
        if (password !== password2) {
          Swal.showValidationMessage('كلمة المرور وتأكيدها غير متطابقين');
          return false;
        }
      }
      return {
        username,
        email,
        password,
        display_name: document.getElementById('sa-account-display').value.trim(),
        job_title: document.getElementById('sa-account-job').value.trim()
      };
    }
  });
  if (!vals) return;
  if (typeof sb_updateSaasAccount !== 'function') {
    Swal.fire({ icon:'error', title:'الدالة غير متاحة', text:'تأكد من تحديث ملفات النظام ثم أعد تحميل الصفحة', ...swalTheme() });
    return;
  }
  const result = await sb_updateSaasAccount(saasCurrentUser.id, vals);
  if (!result.ok) {
    Swal.fire({ icon:'error', title:'لم يتم الحفظ', text: result.error || 'حدث خطأ غير معروف', ...swalTheme() });
    return;
  }
  saasCurrentUser = {
    ...saasCurrentUser,
    username: result.data.username,
    email: result.data.email || '',
    display_name: result.data.display_name || vals.display_name || saasCurrentUser.display_name
  };
  if (vals.job_title) {
    saasCurrentUser.job_title = vals.job_title;
    saasCurrentUser.permissions = saasCurrentUser.permissions || {};
    saasCurrentUser.permissions.super_admin = saasCurrentUser.permissions.super_admin || {};
    saasCurrentUser.permissions.super_admin.job_title = vals.job_title;
  }
  window._saasCurrentUser = saasCurrentUser;
  if (typeof saveAdminSession === 'function') saveAdminSession(saasCurrentUser);
  const nameEl = document.getElementById('sidebar-name');
  if (nameEl) {
    nameEl.textContent = typeof getSuperAdminDisplayName === 'function'
      ? getSuperAdminDisplayName(saasCurrentUser)
      : (saasCurrentUser.username || 'Super Admin');
  }
  const roleEl = document.getElementById('sidebar-role');
  if (roleEl && typeof getSuperAdminJobTitle === 'function') {
    roleEl.textContent = '👑 ' + (getSuperAdminJobTitle(saasCurrentUser) || 'مسؤول النظام');
  }
  Swal.fire({
    icon: 'success',
    title: 'تم تحديث الحساب',
    text: vals.password ? 'تم تغيير اسم المستخدم/البيانات وكلمة المرور بنجاح' : 'تم تحديث بيانات الحساب بنجاح',
    timer: 1800,
    showConfirmButton: false,
    ...swalTheme()
  });
}

async function openAddCompanyForm() {
  if (!_saCan('companies_create')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية إنشاء شركة', ...swalTheme() });
    return;
  }
  function genCompanyCode() {
    return 'KYNO-' + Date.now().toString(36).toUpperCase().slice(-5) + Math.random().toString(36).slice(2, 6).toUpperCase();
  }
  const { value: formVals } = await Swal.fire({
    title: '🏢 إضافة شركة جديدة',
    html: `
      <div style="text-align:right">
        <div style="background:rgba(0,212,170,0.08);border:1px solid rgba(0,212,170,0.2);border-radius:10px;padding:10px 12px;margin-bottom:12px;font-size:12px;color:var(--text-secondary)">
          كل شركة لها <b>كود تفعيل فريد</b> وبيانات معزولة (موظفون، حضور، رواتب…) — منفصلة عن باقي الشركات.
        </div>
        <div class="form-group"><label>اسم الشركة *</label><input id="sc-name" class="swal2-input" placeholder="مثال: شركة الرافدين"></div>
        <div class="form-group"><label>كود التفعيل (يُولَّد تلقائياً)</label><input id="sc-code" class="swal2-input" dir="ltr" readonly style="opacity:0.85;letter-spacing:1px"></div>
        <div class="form-group"><label>الحد الأقصى للموظفين</label><input id="sc-max" class="swal2-input" type="number" value="50"></div>
        <hr style="border-color:var(--border);margin:16px 0">
        <div style="font-weight:700;margin-bottom:8px;color:var(--accent)">👤 بيانات مسؤول الشركة</div>
        <div class="form-group"><label>اسم المستخدم *</label><input id="sc-username" class="swal2-input" placeholder="admin_company" dir="ltr"></div>
        <div class="form-group"><label>البريد الإلكتروني</label><input id="sc-email" class="swal2-input" type="email" placeholder="admin@company.com" dir="ltr"></div>
        <div class="form-group"><label>كلمة المرور *</label><input id="sc-password" class="swal2-input" type="password" placeholder="••••••••"></div>
        <hr style="border-color:var(--border);margin:16px 0">
        <div style="font-size:12px;color:var(--text-muted);line-height:1.8">
          سيتم إنشاء الشركة بحالة <b>معلق</b> بدون اشتراك.<br>
          تفعيل/تجديد الاشتراك يتم من صفحة <b>اشتراكات السوبر أدمن</b>.
        </div>
      </div>`,
    confirmButtonText: 'إنشاء الشركة',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    didOpen: function () {
      var code = genCompanyCode();
      var codeEl = document.getElementById('sc-code');
      var userEl = document.getElementById('sc-username');
      if (codeEl) codeEl.value = code;
      if (userEl && !userEl.value) userEl.value = code.toLowerCase().replace(/[^a-z0-9]/g, '_') + '_admin';
    },
    preConfirm: () => {
      const name = document.getElementById('sc-name').value.trim();
      const code = document.getElementById('sc-code').value.trim().toUpperCase();
      const username = document.getElementById('sc-username').value.trim().toLowerCase();
      const password = document.getElementById('sc-password').value;
      if (!name || !code || !username || !password) { Swal.showValidationMessage('يرجى تعبئة الحقول المطلوبة'); return false; }
      if (username.length < 3) { Swal.showValidationMessage('اسم المستخدم 3 أحرف على الأقل'); return false; }
      if (password.length < 6) { Swal.showValidationMessage('كلمة المرور 6 أحرف على الأقل'); return false; }
      return {
        name, code,
        max_employees: parseInt(document.getElementById('sc-max').value) || 50,
        username, email: document.getElementById('sc-email').value.trim(),
        password
      };
    }
  });
  if (!formVals) return;
  try {
    var result = null;
    if (typeof sb_createCompanyWithAdmin === 'function') {
      result = await sb_createCompanyWithAdmin(formVals);
    } else {
      const company = await sb_upsertCompany({ company_name: formVals.name, company_code: formVals.code, max_employees: formVals.max_employees, status: 'pending' });
      if (!company) { Swal.fire({ icon:'error', title:'فشل إنشاء الشركة', ...swalTheme() }); return; }
      const admin = await sb_upsertSaasUser({ username: formVals.username, email: formVals.email, password: formVals.password, role: 'company_admin', company_id: company.id });
      result = admin ? { ok: true, company: company } : { ok: false, error: 'فشل إنشاء مدير الشركة — قد يكون اسم المستخدم مستخدماً' };
    }
    if (!result || !result.ok) {
      Swal.fire({ icon:'error', title:'فشل إنشاء الشركة', text: (result && result.error) || 'حدث خطأ', ...swalTheme() });
      return;
    }
    if (result.company && result.company.id && typeof markCompanyTenantFresh === 'function') {
      markCompanyTenantFresh(result.company.id);
    }
    Swal.fire({
      icon: 'success',
      title: 'تم إنشاء الشركة',
      html: '<b>' + formVals.name + '</b> تم إنشاؤها بنجاح<br>كود التفعيل: <code dir="ltr">' + formVals.code + '</code><br><small style="color:var(--text-muted)">بيانات الشركة معزولة. فعّل الاشتراك من صفحة الاشتراكات.</small>',
      ...swalTheme()
    });
    buildSuperAdminDashboard();
    buildSACompaniesPage();
  } catch(e) {
    Swal.fire({ icon:'error', title:'خطأ', text: e.message, ...swalTheme() });
  }
}

function _mapRenewSubscriptionError(code) {
  var map = {
    permission_denied: 'لا تملك صلاحية تمديد الاشتراك',
    super_admin_only: 'يجب تسجيل الدخول كسوبر أدمن',
    invalid_company: 'معرّف الشركة غير صالح',
    invalid_subscription: 'معرّف الاشتراك غير صالح',
    subscription_not_found: 'سجل الاشتراك غير موجود',
    company_not_found: 'الشركة غير موجودة',
    company_update_failed: 'تعذّr تحديث بيانات الشركة',
    edit_failed: 'تعذّr حفظ التعديلات',
    no_auth: 'انتهت جلسة الدخول — سجّل الدخول مرة أخرى',
    no_client: 'تعذّر الاتصال بالخادم',
    renew_failed: 'تعذّر تجديد الاشتراك'
  };
  return map[code] || code || 'تعذّر تجديد الاشتراك';
}

function _canEditSubscription() {
  return _saCan('subscriptions_edit') || _saCan('companies_edit') || _saCan('subscriptions_renew');
}

async function openEditSubscriptionForm(subscriptionId) {
  if (!_canEditSubscription()) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية تعديل الاشتراك', ...swalTheme() });
    return;
  }
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    Swal.fire({ icon: 'warning', title: 'التعديل متاح للسوبر أدمن فقط', ...swalTheme() });
    return;
  }
  var subs = await sb_getAllSubscriptions();
  var sub = (subs || []).find(function (s) { return s && s.id === subscriptionId; });
  if (!sub) {
    Swal.fire({ icon: 'error', title: 'غير موجود', text: 'لم يُعثر على سجل الاشتراك', ...swalTheme() });
    buildSASubscriptionsPage();
    return;
  }
  var companies = await sb_getCompanies();
  var company = (companies || []).find(function (c) { return c && c.id === sub.company_id; });
  var companyName = (company && company.company_name) || (sub.companies && sub.companies.company_name) || '';
  var maxEmp = (company && company.max_employees) || 50;
  var durDays = (typeof sb_subscriptionDaysLeft === 'function')
    ? Math.max(1, sb_subscriptionDaysLeft(sub))
    : ((typeof sb_calcSubscriptionDurationDays === 'function')
      ? sb_calcSubscriptionDurationDays(sub)
      : (sub.start_date && sub.end_date
        ? Math.max(1, Math.round((new Date(sub.end_date) - new Date(sub.start_date)) / 86400000))
        : 30));
  var amountVal = typeof saMoneyInt === 'function' ? saMoneyInt(sub.amount) : (parseInt(sub.amount, 10) || 0);

  const { value: formVals } = await Swal.fire({
    title: '✏️ تعديل اشتراك — ' + companyName,
    html: `
      <div style="text-align:right">
        <div class="form-group"><label>اسم الشركة *</label><input id="sub-edit-name" class="swal2-input" value="${esc(companyName)}"></div>
        <div class="form-group"><label>الحد الأقصى للموظفين *</label><input id="sub-edit-max" class="swal2-input" type="number" min="1" value="${maxEmp}"></div>
        <div class="form-group"><label>مدة الاشتراك (بالأيام من اليوم) *</label><input id="sub-edit-days" class="swal2-input" type="number" min="1" value="${durDays}"></div>
        <div class="form-group"><label>المبلغ</label><input id="sub-edit-amount" class="swal2-input" type="text" inputmode="numeric" value="${amountVal}"></div>
        <div style="font-size:12px;color:var(--text-muted);margin-top:6px">يُحدَّث تاريخ البداية إلى <b>اليوم</b> وينتهي الاشتراك بعد عدد الأيام الذي تدخله (مثلاً 10 = ينتهي بعد 10 أيام).</div>
      </div>`,
    confirmButtonText: 'حفظ التعديلات',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    width: 520,
    ...swalTheme(),
    preConfirm: function () {
      var name = document.getElementById('sub-edit-name').value.trim();
      var max = parseInt(document.getElementById('sub-edit-max').value, 10);
      var days = parseInt(document.getElementById('sub-edit-days').value, 10);
      if (!name) { Swal.showValidationMessage('اسم الشركة مطلوب'); return false; }
      if (!max || max < 1) { Swal.showValidationMessage('حد الموظفين يجب أن يكون 1 على الأقل'); return false; }
      if (!days || days < 1) { Swal.showValidationMessage('المدة يجب أن تكون يوماً واحداً على الأقل'); return false; }
      return {
        companyName: name,
        maxEmployees: max,
        durationDays: days,
        amount: saMoneyInt(document.getElementById('sub-edit-amount').value)
      };
    }
  });
  if (!formVals) return;

  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    await AuthApi.refreshAuthSessionForWrite();
  }

  var result = await sb_updateSubscriptionDetails({
    subscriptionId: subscriptionId,
    companyId: sub.company_id,
    companyName: formVals.companyName,
    maxEmployees: formVals.maxEmployees,
    durationDays: formVals.durationDays,
    amount: formVals.amount
  });
  if (result && result.ok) {
    Swal.fire({ icon: 'success', title: 'تم التعديل', text: 'تم تحديث بيانات الشركة والاشتراك', timer: 1600, showConfirmButton: false, ...swalTheme() });
    buildSuperAdminDashboard();
    buildSASubscriptionsPage();
    if (typeof buildSACompaniesPage === 'function') buildSACompaniesPage();
  } else {
    Swal.fire({ icon: 'error', title: 'فشل التعديل', text: _mapRenewSubscriptionError(result && result.error), ...swalTheme() });
  }
}

async function openRenewSubscription(companyId, companyName) {
  if (!_saCan('subscriptions_renew')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية تمديد الاشتراك', ...swalTheme() });
    return;
  }
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') {
    Swal.fire({ icon:'warning', title:'التجديد متاح للسوبر أدمن فقط', ...swalTheme() });
    return;
  }
  const { value: formVals } = await Swal.fire({
    title: '💳 تجديد اشتراك — ' + companyName,
    html: `
      <div style="text-align:right">
        <div class="form-group"><label>المدة (بالأيام) *</label><input id="ren-days" class="swal2-input" type="number" min="1" value="30" placeholder="مثال: 30"></div>
        <div class="form-group"><label>المبلغ المدفوع</label><input id="ren-amount" class="swal2-input" type="text" inputmode="numeric" pattern="[0-9]*" placeholder="مثال: 30000" value="0"></div>
        <div class="form-group"><label>ملاحظات</label><input id="ren-notes" class="swal2-input" placeholder="مثال: تم التحويل البنكي"></div>
      </div>`,
    confirmButtonText: '✅ تأكيد التجديد',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: () => {
      var days = parseInt(document.getElementById('ren-days').value, 10);
      if (!days || days < 1) { Swal.showValidationMessage('أدخل مدة صحيحة (يوم واحد على الأقل)'); return false; }
      return {
        days: days,
        amount: saMoneyInt(document.getElementById('ren-amount').value),
        notes: document.getElementById('ren-notes').value.trim()
      };
    }
  });
  if (!formVals) return;
  const result = await sb_renewSubscription(companyId, formVals.days, formVals.amount, formVals.notes);
  if (result && result.ok) {
    Swal.fire({ icon:'success', title:'تم تجديد الاشتراك', text:'تم تمديد اشتراك ' + companyName + ' لمدة ' + formVals.days + ' يوم', ...swalTheme() });
    buildSuperAdminDashboard();
    buildSASubscriptionsPage();
  } else {
    var renewErr = _mapRenewSubscriptionError(result && result.error);
    Swal.fire({ icon:'error', title:'فشل التجديد', text: renewErr, ...swalTheme() });
  }
}

async function deleteSubscription(subscriptionId, companyName) {
  if (!_saCan('subscriptions_delete')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية حذف سجلات الاشتراك', ...swalTheme() });
    return;
  }
  const { isConfirmed } = await Swal.fire({
    title: 'حذف اشتراك',
    html: 'هل تريد حذف اشتراك شركة <b>' + (companyName || 'غير محددة') + '</b>؟<br><small style="color:var(--text-muted)">لن يتم حذف بيانات الشركة أو الموظفين، سيتم حذف سجل الاشتراك فقط.</small>',
    icon: 'warning',
    confirmButtonText: 'نعم، حذف',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#e53e3e'
  });
  if (!isConfirmed) return;
  if (typeof sb_deleteSubscription !== 'function') {
    Swal.fire({ icon:'error', title:'دالة الحذف غير متاحة', ...swalTheme() });
    return;
  }
  const result = await sb_deleteSubscription(subscriptionId);
  if (!result.ok) {
    Swal.fire({ icon:'error', title:'لم يتم حذف الاشتراك', text: result.error || 'حدث خطأ', ...swalTheme() });
    return;
  }
  Swal.fire({ icon:'success', title:'تم حذف الاشتراك', timer:1400, showConfirmButton:false, ...swalTheme() });
  buildSASubscriptionsPage();
  buildSuperAdminDashboard();
}

async function toggleCompanyStatus(companyId, currentStatus, companyName) {
  if (!_saCan('companies_suspend')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية إيقاف/تفعيل الشركات', ...swalTheme() });
    return;
  }
  const newStatus = currentStatus === 'active' ? 'suspended' : 'active';
  const action = newStatus === 'active' ? 'تفعيل' : 'إيقاف';
  const { isConfirmed } = await Swal.fire({
    title: action + ' شركة',
    html: 'هل تريد <b>' + action + '</b> شركة <b>' + companyName + '</b>؟',
    icon: 'warning',
    confirmButtonText: 'نعم، ' + action,
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: newStatus === 'active' ? '#00d4aa' : '#e53e3e'
  });
  if (!isConfirmed) return;
  const ok = await sb_toggleCompanyStatus(companyId, newStatus);
  if (ok) {
    Swal.fire({ icon: 'success', title: 'تم ' + action + ' الشركة', ...swalTheme(), timer: 1500, showConfirmButton: false });
    buildSACompaniesPage();
  } else {
    Swal.fire({ icon: 'error', title: 'فشل العملية', ...swalTheme() });
  }
}

async function deleteCompany(companyId, companyName, employeeCount) {
  if (!_saCan('companies_delete')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية حذف الشركات', ...swalTheme() });
    return;
  }
  employeeCount = parseInt(employeeCount, 10) || 0;
  const { isConfirmed } = await Swal.fire({
    title: 'حذف شركة نهائياً',
    html: 'هل تريد حذف شركة <b>' + (companyName || 'غير محددة') + '</b>؟<br><br>' +
      '<small style="color:#fc8181">⚠️ سيتم حذف المستخدمين، الموظفين (' + employeeCount + ')، الحضور، الرواتب، الاشتراك، والإعدادات — لا يمكن التراجع.</small>',
    icon: 'warning',
    confirmButtonText: 'نعم، حذف نهائي',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#e53e3e'
  });
  if (!isConfirmed) return;
  if (employeeCount > 0) {
    const { isConfirmed: confirmAgain } = await Swal.fire({
      title: 'تأكيد إضافي',
      html: 'الشركة تحتوي على <b>' + employeeCount + '</b> موظف(ين).<br>هل أنت متأكد من الحذف الكامل؟',
      icon: 'error',
      confirmButtonText: 'نعم، احذف كل شيء',
      showCancelButton: true,
      cancelButtonText: 'إلغاء',
      ...swalTheme(),
      confirmButtonColor: '#e53e3e'
    });
    if (!confirmAgain) return;
  }
  if (typeof sb_deleteCompany !== 'function') {
    Swal.fire({ icon: 'error', title: 'دالة الحذف غير متاحة', ...swalTheme() });
    return;
  }
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    await AuthApi.ensureValidSession();
  }
  const ok = await sb_deleteCompany(companyId);
  if (ok) {
    Swal.fire({ icon: 'success', title: 'تم حذف الشركة', timer: 1400, showConfirmButton: false, ...swalTheme() });
    buildSACompaniesPage();
    buildSuperAdminDashboard();
    if (typeof buildSASubscriptionsPage === 'function') buildSASubscriptionsPage();
    if (typeof buildSAUsersPage === 'function') buildSAUsersPage();
  } else {
    Swal.fire({
      icon: 'error',
      title: 'فشل الحذف',
      text: 'تأكد من صلاحيات السوبر أدمن — إن استمرت المشكلة تواصل مع الدعم الفني',
      ...swalTheme()
    });
  }
}

async function openEditCompanyFormById(companyId) {
  const companies = await sb_getCompanies();
  const company = companies && companies.find(function (c) { return c.id === companyId; });
  if (company) openEditCompanyForm(company);
}

async function openEditCompanyForm(company) {
  if (!_saCan('companies_edit')) {
    Swal.fire({ icon: 'warning', title: 'غير مصرح', text: 'لا تملك صلاحية تعديل الشركات', ...swalTheme() });
    return;
  }
  if (!company || !company.id) return;
  const { value: vals } = await Swal.fire({
    title: '✏️ تعديل شركة',
    html: `
      <div style="text-align:right">
        <div class="form-group"><label>اسم الشركة</label><input id="ec-name" class="swal2-input" value="${company.company_name||''}"></div>
        <div class="form-group"><label>الحد الأقصى للموظفين</label><input id="ec-max" class="swal2-input" type="number" value="${company.max_employees||50}"></div>
        <div class="form-group"><label>ملاحظات</label><input id="ec-notes" class="swal2-input" value="${company.notes||''}"></div>
      </div>`,
    confirmButtonText: 'حفظ', showCancelButton: true, cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: () => ({
      name: document.getElementById('ec-name').value.trim(),
      max: parseInt(document.getElementById('ec-max').value)||50,
      notes: document.getElementById('ec-notes').value.trim()
    })
  });
  if (!vals || !vals.name) return;
  await sb_upsertCompany({ id: company.id, company_name: vals.name, company_code: company.company_code, status: company.status, max_employees: vals.max, notes: vals.notes });
  Swal.fire({ icon:'success', title:'تم التعديل', timer:1200, showConfirmButton:false, ...swalTheme() });
  buildSACompaniesPage();
}

async function openCompanyDetails(companyId) {
  window._saExpandedCompanyId = companyId;
  showPage('sa-users');
}

async function openAddSaasUserForm() {
  const companies = await sb_getCompanies();
  const compOpts = (companies||[]).map(c => `<option value="${c.id}">${c.company_name}</option>`).join('');
  const { value: vals } = await Swal.fire({
    title: '👤 إضافة مستخدم',
    html: `
      <div style="text-align:right">
        <div class="form-group"><label>اسم المستخدم *</label><input id="nu-user" class="swal2-input" dir="ltr"></div>
        <div class="form-group"><label>البريد الإلكتروني</label><input id="nu-email" class="swal2-input" type="email" dir="ltr"></div>
        <div class="form-group"><label>كلمة المرور *</label><input id="nu-pass" class="swal2-input" type="password"></div>
        <div class="form-group"><label>الدور</label>
          <select id="nu-role" class="swal2-input">
            <option value="company_admin">أدمن شركة</option>
            <option value="super_admin">سوبر أدمن</option>
          </select></div>
        <div class="form-group"><label>الشركة</label><select id="nu-company" class="swal2-input"><option value="">— بدون شركة —</option>${compOpts}</select></div>
      </div>`,
    confirmButtonText: 'إضافة', showCancelButton: true, cancelButtonText: 'إلغاء', ...swalTheme(),
    preConfirm: () => {
      const u = document.getElementById('nu-user').value.trim();
      const p = document.getElementById('nu-pass').value;
      if (!u || !p) { Swal.showValidationMessage('يرجى إدخال اسم المستخدم وكلمة المرور'); return false; }
      return { username: u, email: document.getElementById('nu-email').value.trim(),
               password: p, role: document.getElementById('nu-role').value,
               company_id: document.getElementById('nu-company').value || null };
    }
  });
  if (!vals) return;
  const res = await sb_upsertSaasUser(vals);
  if (res) {
    Swal.fire({ icon:'success', title:'تم إضافة المستخدم', ...swalTheme(), timer:1500, showConfirmButton:false });
    buildSAUsersPage();
  } else {
    Swal.fire({ icon:'error', title:'فشل الإضافة', text:'تأكد من أن اسم المستخدم غير مكرر', ...swalTheme() });
  }
}

async function deleteSaasUser(userId, username) {
  const { isConfirmed } = await Swal.fire({
    title: 'حذف مستخدم', html: 'هل تريد حذف المستخدم <b>' + (username || '') + '</b>؟',
    icon: 'warning', confirmButtonText: 'نعم، حذف', showCancelButton: true,
    cancelButtonText: 'إلغاء', ...swalTheme(), confirmButtonColor: '#e53e3e'
  });
  if (!isConfirmed) return;
  var ok = false;
  if (typeof sb_deleteCompanyUser === 'function') {
    var users = await sb_getSaasUsers(null);
    var u = (users || []).find(function (x) { return x.id === userId; });
    if (u && u.company_id) {
      var res = await sb_deleteCompanyUser(userId, u.company_id);
      ok = res && res.ok;
    }
  }
  if (!ok && typeof sb_deleteSaasUser === 'function') {
    ok = await sb_deleteSaasUser(userId);
  }
  if (ok) {
    Swal.fire({ icon:'success', title:'تم الحذف', timer:1200, showConfirmButton:false, ...swalTheme() });
    buildSAUsersPage();
  } else {
    Swal.fire({ icon:'error', title:'فشل الحذف', ...swalTheme() });
  }
}

if (typeof window !== 'undefined') {
  window.bindSidebarNavClicks = bindSidebarNavClicks;
  window.bindSaActionClicks = bindSaActionClicks;
  window.installShowPageBridge = installShowPageBridge;
  window.runSecurityHealthReport = runSecurityHealthReport;
  window.buildSuperAdminDashboard = buildSuperAdminDashboard;
  window.openAddCompanyForm = openAddCompanyForm;
  window.openSuperAdminAccountSettings = openSuperAdminAccountSettings;
  window.buildSACompaniesPage = buildSACompaniesPage;
  window.buildSASubscriptionsPage = buildSASubscriptionsPage;
  window.buildSAUsersPage = buildSAUsersPage;
  window.buildSATeamPage = buildSATeamPage;
  window.buildSAPlatformPage = buildSAPlatformPage;
  window.buildSAStatsPage = buildSAStatsPage;
  window.toggleSidebar = toggleSidebar;
  window.closeSidebar = closeSidebar;
  window.blockIfSubscriptionInactive = blockIfSubscriptionInactive;
  window.isSubscriptionActive = isSubscriptionActive;
  window.openRenewSubscription = openRenewSubscription;
  window.openEditSubscriptionForm = openEditSubscriptionForm;
  window.deleteSubscription = deleteSubscription;
  window.openCompanyDetails = openCompanyDetails;
  window.toggleCompanyStatus = toggleCompanyStatus;
  window.deleteCompany = deleteCompany;
  window.openEditCompanyFormById = openEditCompanyFormById;
  window.openEditCompanyForm = openEditCompanyForm;
  window.openAddCompanyAdminForm = openAddCompanyAdminForm;
  window.openEditCompanyAdminForm = openEditCompanyAdminForm;
  window.deleteSaasUser = deleteSaasUser;
  window.toggleSACompanyPanel = toggleSACompanyPanel;
  window.openCompanyUserForm = openCompanyUserForm;
  window.deleteCompanyUser = deleteCompanyUser;
  window.buildCompanyUsersPage = buildCompanyUsersPage;
  window.savePlatformWhatsAppNumbers = savePlatformWhatsAppNumbers;
  window.openCreatePlatformAnnouncement = openCreatePlatformAnnouncement;
  window.openEditPlatformAnnouncement = openEditPlatformAnnouncement;
  window.deletePlatformAnnouncement = deletePlatformAnnouncement;
  window.openSuperAdminTeamForm = openSuperAdminTeamForm;
  window.deleteSuperAdminTeamMember = deleteSuperAdminTeamMember;
  window.openAddSaasUserForm = openAddSaasUserForm;
  window.buildSAMonitoringPage = buildSAMonitoringPage;
  window.buildSABackupPage = buildSABackupPage;
  window.buildSASettingsPage = buildSASettingsPage;
  window.saSelectBackupCompany = saSelectBackupCompany;
  window.saFilterBackupCompanies = saFilterBackupCompanies;
  window.saRunBackupExport = saRunBackupExport;
  window.saVerifyBackupIntegrity = saVerifyBackupIntegrity;
  window.saRunBackupImport = saRunBackupImport;
  window.dismissPlatformAnnouncement = dismissPlatformAnnouncement;
  installShowPageBridge();
}
