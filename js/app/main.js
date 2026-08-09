// Soft-failure runtime: safeRun, safeAddEvent, safeRpc, applySafeMode (js/core/safe-runtime.js)

const DEFAULT_EMPLOYEES = [];
const DEFAULT_ATT_DATA = [];
const STORAGE_KEY = 'attendance_system_data';
const ADMIN_SESSION_KEY = 'basma_admin_session';
if (typeof window !== 'undefined') {
  window.STORAGE_KEY = STORAGE_KEY;
  window.ADMIN_SESSION_KEY = ADMIN_SESSION_KEY;
}

// Global state (window) — initialized in js/app/state.js
let currentClientIp = '';
let barcodeScanContext = null;
let autoSyncTimer = null;

/** Escape dynamic text before HTML concatenation (XSS) */
function esc(v) {
  if (v == null || v === '') return '';
  if (typeof BasmaSecurity !== 'undefined' && BasmaSecurity.safeHtml) return BasmaSecurity.safeHtml(v);
  if (typeof BasmaSecurity !== 'undefined' && BasmaSecurity.escapeHtml) return BasmaSecurity.escapeHtml(v);
  return String(v).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] || c;
  });
}
function setHtml(el, html) {
  if (!el) return;
  if (typeof BasmaSecurity !== 'undefined' && BasmaSecurity.setHtml) BasmaSecurity.setHtml(el, html);
  else el.innerHTML = html == null ? '' : String(html);
}
function escAttr(v) {
  return esc(v).replace(/`/g, '&#96;');
}
function escClass(v, map, fallback) {
  if (typeof BasmaSecurity !== 'undefined' && BasmaSecurity.escClass) {
    return BasmaSecurity.escClass(v, map, fallback || 'badge-secondary');
  }
  var key = String(v == null ? '' : v);
  return (map && map[key]) ? map[key] : (fallback || 'badge-secondary');
}

function scheduleAutoSupabaseSync(reason) {
  if (window.__basmaDisableAutoSync) return;
  if (window.__basmaSuppressRealtimeUntil && Date.now() < window.__basmaSuppressRealtimeUntil) return;
  clearTimeout(autoSyncTimer);
  autoSyncTimer = setTimeout(async () => {
    try {
      if (window.__basmaDisableAutoSync) return;
      if (window.__basmaSuppressRealtimeUntil && Date.now() < window.__basmaSuppressRealtimeUntil) return;
      if (typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession) {
        var hasJwt = await AuthApi.hasAuthenticatedSession();
        if (!hasJwt) return;
        if (AuthApi.refreshJwtContext) await AuthApi.refreshJwtContext();
      }
      if (typeof syncToSupabase === 'function') {
        await syncToSupabase({ settingsOnly: true, reason: reason || 'saveData' });
        if (typeof hasPendingDataSync === 'function' && hasPendingDataSync()) {
          if (typeof BasmaCloud !== 'undefined' && BasmaCloud.scheduleImmediateCloudSync) {
            BasmaCloud.scheduleImmediateCloudSync('saveData-pending');
          } else if (typeof schedulePendingSyncRetry === 'function') {
            schedulePendingSyncRetry();
          }
        }
      } else {
        // supabase_integration.js is loaded after index.html; retry once after it loads.
        setTimeout(() => scheduleAutoSupabaseSync(reason || 'delayed'), 1200);
      }
    } catch (e) {
      console.warn('Auto Supabase sync failed:', e);
    }
  }, 400);
}

function normalizeOrgName(name) {
  return String(name || '').replace(/\s+/g, ' ').trim();
}

function dedupeOrgNames(list) {
  var out = [];
  var seen = {};
  (list || []).forEach(function (item) {
    var v = normalizeOrgName(item);
    if (!v || seen[v]) return;
    seen[v] = true;
    out.push(v);
  });
  return out;
}

function ensureOrgLists() {
  if (!Array.isArray(appSettings.departments)) appSettings.departments = [];
  if (!Array.isArray(appSettings.jobs)) appSettings.jobs = [];
  appSettings.departments = dedupeOrgNames(appSettings.departments);
  appSettings.jobs = dedupeOrgNames(appSettings.jobs);
}

function orgNameExists(list, val, excludeIdx) {
  var target = normalizeOrgName(val);
  if (!target) return false;
  return (list || []).some(function (item, i) {
    if (typeof excludeIdx === 'number' && i === excludeIdx) return false;
    return normalizeOrgName(item) === target;
  });
}

async function refreshOrgListsFromCloud() {
  ensureOrgLists();
  var cloudDepts = [];
  var cloudJobs = [];
  if (typeof sb_getSettings === 'function') {
    try {
      var remote = await sb_getSettings();
      if (remote) {
        if (remote.departments_json) {
          try { cloudDepts = JSON.parse(remote.departments_json) || []; } catch (e) { /* ignore */ }
        }
        if (remote.jobs_json) {
          try { cloudJobs = JSON.parse(remote.jobs_json) || []; } catch (e) { /* ignore */ }
        }
      }
    } catch (e) {
      console.warn('refreshOrgListsFromCloud settings:', e);
    }
  }
  if (typeof sb_getDepartmentNames === 'function') {
    try {
      var dbDepts = await sb_getDepartmentNames();
      if (Array.isArray(dbDepts)) cloudDepts = cloudDepts.concat(dbDepts);
    } catch (e) {
      console.warn('refreshOrgListsFromCloud departments:', e);
    }
  }
  appSettings.departments = dedupeOrgNames(cloudDepts);
  appSettings.jobs = dedupeOrgNames(cloudJobs);
  return true;
}

function orgActionsHtml(type, index) {
  var editBtn = hasActionPermission('org', 'edit')
    ? '<button type="button" class="btn-sm btn-primary org-btn" onclick="openOrgItemForm(\'' + type + '\',' + index + ')" title="تعديل"><i class="fa fa-edit"></i></button>'
    : '';
  var delBtn = hasActionPermission('org', 'delete')
    ? '<button type="button" class="btn-sm btn-danger org-btn" onclick="deleteOrgItem(\'' + type + '\',' + index + ')" title="حذف"><i class="fa fa-trash"></i></button>'
    : '';
  if (!editBtn && !delBtn) return '<span class="org-actions-empty">—</span>';
  return '<div class="org-actions">' + editBtn + delBtn + '</div>';
}

function orgTableRowHtml(type, name, index) {
  var count = type === 'dept'
    ? employees.filter(function (e) { return e && normalizeOrgName(e.dept) === normalizeOrgName(name); }).length
    : employees.filter(function (e) { return e && normalizeOrgName(e.role) === normalizeOrgName(name); }).length;
  var countClass = count > 0 ? 'org-count org-count-active' : 'org-count';
  return '<tr>' +
    '<td class="org-num">' + (index + 1) + '</td>' +
    '<td class="org-name">' + esc(name) + '</td>' +
    '<td class="org-count-cell"><span class="' + countClass + '">' + count + '</span></td>' +
    '<td class="org-actions-cell">' + orgActionsHtml(type, index) + '</td>' +
    '</tr>';
}

function getOrgArray(type) {
  ensureOrgLists();
  return type === 'dept' ? appSettings.departments : appSettings.jobs;
}

async function persistOrgSettingsNow() {
  if (typeof sb_saveSettings !== 'function') return { ok: false, reason: 'no_client' };
  ensureOrgLists();
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    await AuthApi.ensureValidSession();
  }
  try {
    var ok = await sb_saveSettings({
      departments_json: JSON.stringify(appSettings.departments || []),
      jobs_json: JSON.stringify(appSettings.jobs || [])
    });
    if (ok) window.__basmaLocalSettingsAt = Date.now();
    return { ok: !!ok, reason: ok ? '' : 'settings_save_failed' };
  } catch (e) {
    console.warn('persistOrgSettingsNow:', e);
    return { ok: false, reason: e.message || 'settings_save_failed' };
  }
}

function buildAppSettingsPayload() {
  return {
    company_name: appSettings.companyName || '',
    currency: appSettings.currency || '',
    timezone: appSettings.timezone || 'Asia/Baghdad (GMT+3)',
    work_start: appSettings.workStart || '08:00',
    work_end: appSettings.workEnd || '17:00',
    late_threshold: appSettings.lateThreshold || 15,
    late_deduct_rate: appSettings.lateDeductRate || 700,
    month_days: String(getStandardMonthDays()),
    clock_format: appSettings.clockFormat === '24' ? '24' : '12',
    departments_json: JSON.stringify(appSettings.departments || []),
    jobs_json: JSON.stringify(appSettings.jobs || []),
    salary_deleted_map: JSON.stringify(appSettings.salaryDeletedMap || {}),
    finance_items: JSON.stringify(appSettings.financeItems || []),
    broadcast_notices: JSON.stringify(appSettings.broadcastNotices || []),
    activity_log: JSON.stringify(appSettings.activityLog || []),
    employee_notifications: JSON.stringify(appSettings.employeeNotifications || []),
    official_closures_json: JSON.stringify(normalizeOfficialClosures(appSettings.officialClosures || [])),
    gps_name: appSettings.gpsName || '',
    gps_lat: appSettings.gpsLat || '',
    gps_lng: appSettings.gpsLng || '',
    gps_range: String(appSettings.gpsRange || 100),
    ui_theme: document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark'
  };
}

async function commitAppSettingsToCloud(options) {
  options = options || {};
  pauseRemoteSync(options.pauseMs || 30000);
  window.__basmaLocalSettingsAt = Date.now();
  if (typeof syncWindowState === 'function') syncWindowState();
  var cloud = await persistAppSettingsNow();
  saveData();
  syncSettingsUi();
  if (typeof previewGpsMap === 'function') previewGpsMap();
  resumeRemoteSync(options.resumeMs || 15000);
  return cloud;
}

async function mergeRemoteNotificationStoresBeforeSave(options) {
  options = options || {};
  if (options.skipMerge) return;
  if (window.__basmaNotifClearedAt && Date.now() - window.__basmaNotifClearedAt < 600000) return;
  var isSuper = saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (isSuper) {
    if (options.skipMerge || typeof sb_getSuperAdminPrefs !== 'function') return;
    try {
      var prefs = await sb_getSuperAdminPrefs();
      if (!prefs) return;
      ensureNotifStores();
      if (prefs.activity_log && typeof mergeActivityLogRemote === 'function') {
        try {
          var remoteLog = prefs.activity_log;
          if (typeof remoteLog === 'string') remoteLog = JSON.parse(remoteLog);
          appSettings.activityLog = mergeActivityLogRemote(
            appSettings.activityLog,
            Array.isArray(remoteLog) ? remoteLog : []
          );
        } catch (e) {}
      }
    } catch (e) {
      console.warn('mergeRemoteNotificationStoresBeforeSave (super admin):', e);
    }
    return;
  }
  try {
    var remote = null;
    if (typeof sb_fetchTenantSettingKeys === 'function') {
      remote = await sb_fetchTenantSettingKeys(['activity_log', 'employee_notifications']);
    } else if (typeof sb_getSettings === 'function') {
      remote = await sb_getSettings();
    }
    if (!remote) return;
    ensureNotifStores();
    if (remote.activity_log && typeof mergeActivityLogRemote === 'function') {
      try {
        appSettings.activityLog = mergeActivityLogRemote(
          appSettings.activityLog,
          JSON.parse(remote.activity_log) || []
        );
      } catch (e) {}
    }
    if (remote.employee_notifications && typeof mergeEmployeeNotificationsRemote === 'function') {
      try {
        appSettings.employeeNotifications = mergeEmployeeNotificationsRemote(
          appSettings.employeeNotifications,
          JSON.parse(remote.employee_notifications) || []
        );
      } catch (e) {}
    }
  } catch (e) {
    console.warn('mergeRemoteNotificationStoresBeforeSave:', e);
  }
}

async function mergeRemoteSharedSettingsBeforeSave() {
  await mergeRemoteNotificationStoresBeforeSave();
  if (typeof mergeRemoteOrgListsBeforeSave === 'function') {
    await mergeRemoteOrgListsBeforeSave();
  }
  if (typeof mergeRemoteFinanceBeforeCloudSave === 'function') {
    await mergeRemoteFinanceBeforeCloudSave();
  }
  if (typeof shouldPreferLocalAppSettings === 'function' && shouldPreferLocalAppSettings()) return;
  if (typeof sb_getSettings !== 'function') return;
  try {
    var remote = await sb_getSettings();
    if (!remote) return;
    if (remote.gps_lat != null && String(remote.gps_lat).trim() !== '') {
      appSettings.gpsLat = String(remote.gps_lat).trim();
    }
    if (remote.gps_lng != null && String(remote.gps_lng).trim() !== '') {
      appSettings.gpsLng = String(remote.gps_lng).trim();
    }
    if (remote.gps_name != null) appSettings.gpsName = remote.gps_name;
    if (remote.gps_range != null && String(remote.gps_range).trim() !== '') {
      appSettings.gpsRange = parseInt(remote.gps_range, 10) || appSettings.gpsRange;
    }
  } catch (e) {
    console.warn('mergeRemoteSharedSettingsBeforeSave:', e);
  }
}

async function persistAppSettingsNow() {
  if (typeof sb_saveSettings !== 'function') return { ok: false, reason: 'no_client' };
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    await AuthApi.ensureValidSession();
  }
  try {
    await mergeRemoteSharedSettingsBeforeSave();
    var payload = buildAppSettingsPayload();
    if (typeof guardFinanceItemsCloudWrite === 'function') {
      payload = await guardFinanceItemsCloudWrite(payload);
    }
    var ok = await sb_saveSettings(payload);
    if (ok) window.__basmaLocalSettingsAt = Date.now();
    return { ok: !!ok, reason: ok ? '' : 'settings_save_failed' };
  } catch (e) {
    console.warn('persistAppSettingsNow:', e);
    return { ok: false, reason: e.message || 'settings_save_failed' };
  }
}

function notifCloudSaveErrorMessage(reason) {
  if (reason === 'no_auth') {
    return 'انتهت جلسة الدخول — سجّل الخروج ثم ادخل مرة أخرى، ثم أعد المحاولة.';
  }
  return 'تم التحديث محلياً لكن تعذّر الحفظ في السحابة — قد تعود الإشعارات بعد المزامنة.';
}

async function ensureAuthBeforeNotifCloudSave(options) {
  options = options || {};
  if (options.skipSessionRefresh) {
    if (typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession) {
      return AuthApi.hasAuthenticatedSession();
    }
    return false;
  }
  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    return AuthApi.refreshAuthSessionForWrite();
  }
  if (typeof ensureSbAuthForWrite === 'function') return ensureSbAuthForWrite();
  return false;
}

/** حفظ سجل النشاطات/إشعارات الموظف في السحابة فوراً (منع عودة العداد بعد المزامنة) */
async function persistNotificationsNow(options) {
  options = options || {};
  ensureNotifStores();
  if (!options.noPause) pauseRemoteSync(options.pauseMs || 12000);
  window.__basmaLocalNotifAt = Date.now();
  var authOk = false;
  try {
    authOk = await ensureAuthBeforeNotifCloudSave(options);
  } catch (e) {
    console.warn('persistNotificationsNow auth:', e);
  }
  if (!authOk) {
    if (!options.noPause) resumeRemoteSync(0);
    window.__basmaPendingNotifCloudSave = Date.now();
    if (options.duringLogout) {
      return { ok: false, reason: 'no_auth' };
    }
    if (!options.serverOnly) {
      try {
        window.__basmaDisableAutoSync = true;
        if (typeof saveData === 'function') saveData();
      } catch (e) {
        console.warn('persistNotificationsNow local save:', e);
      }
    }
    return { ok: false, reason: 'no_auth' };
  }
  if (typeof filterNotificationsForCurrentTenant === 'function') filterNotificationsForCurrentTenant();
  if (!options.skipMerge) {
    await mergeRemoteNotificationStoresBeforeSave(options);
  }
  var ok = false;
  var isSuper = saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (isSuper && typeof sb_saveSuperAdminPrefs === 'function') {
    try {
      if (appSettings.activityLog && appSettings.activityLog.length > 150) {
        appSettings.activityLog.length = 150;
      }
      ok = await sb_saveSuperAdminPrefs({
        activity_log: (typeof slimSuperAdminActivityLogForCloud === 'function'
          ? slimSuperAdminActivityLogForCloud(appSettings.activityLog || [], 120)
          : (appSettings.activityLog || []).slice(0, 120))
      });
    } catch (e) {
      console.warn('persistNotificationsNow (super admin):', e);
    }
  } else if (typeof sb_saveSettings === 'function') {
    try {
      if (options.duringLogout) window.__basmaSilentSettingsSave = true;
      ok = await sb_saveSettings({
        activity_log: JSON.stringify((appSettings.activityLog || []).slice(0, 500)),
        employee_notifications: JSON.stringify((appSettings.employeeNotifications || []).slice(0, 300))
      });
    } catch (e) {
      console.warn('persistNotificationsNow:', e);
    } finally {
      if (options.duringLogout) window.__basmaSilentSettingsSave = false;
    }
  }
  if (!options.serverOnly && !isSuper) {
    try {
      window.__basmaDisableAutoSync = true;
      if (typeof saveData === 'function') saveData();
    } catch (e) {
      console.warn('persistNotificationsNow saveData:', e);
    }
  } else if (isSuper && appSettings.activityLog && appSettings.activityLog.length > 150) {
    appSettings.activityLog = appSettings.activityLog.slice(0, 150);
  }
  if (!options.noPause) resumeRemoteSync(options.resumeMs || 6000);
  if (ok) {
    window.__basmaPendingNotifCloudSave = 0;
  } else {
    window.__basmaPendingNotifCloudSave = Date.now();
  }
  return { ok: !!ok, reason: ok ? '' : 'save_failed' };
}

async function retryPendingNotifCloudSave() {
  if (!window.__basmaPendingNotifCloudSave) return;
  if (Date.now() - window.__basmaPendingNotifCloudSave > 900000) {
    window.__basmaPendingNotifCloudSave = 0;
    return;
  }
  if (typeof persistNotificationsNow !== 'function') return;
  var authReady = false;
  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    authReady = await AuthApi.refreshAuthSessionForWrite();
  } else if (typeof ensureSbAuthForWrite === 'function') {
    authReady = await ensureSbAuthForWrite();
  }
  if (!authReady) return;
  var result = await persistNotificationsNow({ skipMerge: true, pauseMs: 8000, resumeMs: 4000 });
  if (result.ok) {
    window.__basmaPendingNotifCloudSave = 0;
    if (typeof buildNotifications === 'function') buildNotifications();
  }
}

var _notifPersistTimer = null;
function schedulePersistNotifications() {
  clearTimeout(_notifPersistTimer);
  _notifPersistTimer = setTimeout(function () {
    var isSuper = saasCurrentUser && saasCurrentUser.role === 'super_admin';
    persistNotificationsNow(isSuper
      ? { skipMerge: true, skipSessionRefresh: true, noPause: true }
      : {}
    ).catch(function (e) { console.warn('schedulePersistNotifications:', e); });
  }, 700);
}

function safeActiveCompanyId(emp) {
  return getActiveCompanyId(emp);
}

function getActiveCompanyId(emp) {
  if (typeof resolveActiveCompanyId !== 'function') {
    console.error('SOFT ERROR:', 'NO_COMPANY_CONTEXT');
    return null;
  }
  var cid = resolveActiveCompanyId(emp);
  if (!cid || cid <= 0) {
    console.error('SOFT ERROR:', 'NO_COMPANY_CONTEXT');
    return null;
  }
  return cid;
}

async function syncDepartmentsToSupabase() {
  if (typeof refreshOrgListsFromCloud === 'function') {
    try {
      await refreshOrgListsFromCloud();
      if (typeof saveData === 'function') saveData();
  } catch (e) {
      console.warn('syncDepartmentsToSupabase:', e);
    }
  }
}

async function refreshNextEmpIdBeforeAdd() {
  var now = Date.now();
  var pendingMax = 1;
  try {
    (window.employees || []).forEach(function (e) {
      if (!e || !e.id) return;
      pendingMax = Math.max(pendingMax, parseInt(e.id, 10) + 1);
      if (e._pendingRemoteSync || (e._addedAt && (now - e._addedAt) < 600000)) {
        pendingMax = Math.max(pendingMax, parseInt(e.id, 10) + 1);
      }
    });
  } catch (e) {}
  var nextId = pendingMax;
  if (typeof sb_getNextEmployeeId === 'function') {
    try {
      var remoteNext = await sb_getNextEmployeeId();
      if (remoteNext && remoteNext >= 1) nextId = Math.max(nextId, remoteNext);
    } catch (e) {
      console.warn('refreshNextEmpIdBeforeAdd failed:', e);
    }
  }
  nextEmpId = nextId;
  window.nextEmpId = nextEmpId;
}

var _resumeRemoteSyncTimer = null;

function pauseRemoteSync(ms) {
  clearTimeout(autoSyncTimer);
  if (_resumeRemoteSyncTimer) clearTimeout(_resumeRemoteSyncTimer);
  window.__basmaDisableAutoSync = true;
  window.__basmaSuppressRealtimeUntil = Date.now() + (ms != null ? ms : 8000);
}

function resumeRemoteSync(ms) {
  if (_resumeRemoteSyncTimer) clearTimeout(_resumeRemoteSyncTimer);
  var delay = ms != null ? ms : 8000;
  function tryResume() {
    if (window.__basmaSuppressRealtimeUntil && Date.now() < window.__basmaSuppressRealtimeUntil) {
      _resumeRemoteSyncTimer = setTimeout(tryResume, Math.max(50, window.__basmaSuppressRealtimeUntil - Date.now() + 50));
      return;
    }
    window.__basmaDisableAutoSync = false;
    window.__basmaSuppressRealtimeUntil = 0;
    _resumeRemoteSyncTimer = null;
  }
  _resumeRemoteSyncTimer = setTimeout(tryResume, delay);
}

const DEFAULT_LATE_THRESHOLD = 15;
const DEFAULT_LATE_DEDUCT_RATE = 700;

function getEmpLateThreshold(emp) {
  var n = emp && emp.lateThreshold != null ? parseInt(emp.lateThreshold, 10) : NaN;
  return n > 0 ? n : DEFAULT_LATE_THRESHOLD;
}

function getEmpLateDeductRate(emp) {
  var n = emp && emp.lateDeductRate != null ? parseInt(emp.lateDeductRate, 10) : NaN;
  return n >= 0 && !isNaN(n) ? n : DEFAULT_LATE_DEDUCT_RATE;
}

function getEmpOfficialWorkMinutes(emp) {
  var ci = timeToMinutes((emp && emp.checkIn) || (appSettings && appSettings.workStart) || '08:00');
  var co = timeToMinutes((emp && emp.checkOut) || (appSettings && appSettings.workEnd) || '17:00');
  if (co <= ci) return Math.max(60, (24 * 60 - ci) + co);
  return Math.max(60, co - ci);
}

function getBillableLateMinutes(emp, lateMin) {
  var m = parseInt(lateMin, 10) || 0;
  if (m <= 0) return 0;
  // Late deduction is prorated by exact minutes (1..n), no legacy threshold cut.
  return m;
}

function calcAttendanceShortMinutes(emp, rec) {
  if (!emp || !rec || emp.openHours || (emp.salaryType || 'monthly') === 'commission') return 0;
  if (!rec.ci || rec.ci === '—' || !rec.co || rec.co === '—') return 0;
  var officialCi = timeToMinutes(emp.checkIn || (appSettings && appSettings.workStart) || '08:00');
  var officialCo = timeToMinutes(emp.checkOut || (appSettings && appSettings.workEnd) || '17:00');
  var actualCi = timeToMinutes(rec.ci);
  var actualCo = timeToMinutes(rec.co);
  var lateIn = Math.max(0, actualCi - officialCi);
  var earlyOut = Math.max(0, officialCo - actualCo);
  return getBillableLateMinutes(emp, lateIn + earlyOut);
}

function calcLateDeductAmount(emp, totalLateMin, dailyRate) {
  if (!emp || emp.openHours || (emp.salaryType || 'monthly') === 'commission') return 0;
  var mins = parseInt(totalLateMin, 10) || 0;
  if (mins <= 0) return 0;
  var dr = dailyRate > 0 ? dailyRate : (typeof getEmpDailyRate === 'function' ? getEmpDailyRate(emp) : 0);
  if (dr <= 0) return 0;
  var workMins = getEmpOfficialWorkMinutes(emp);
  return Math.round(mins * (dr / workMins));
}

function countWorkDaysBetween(startDate, endDate) {
  if (!startDate || !endDate || endDate < startDate) return 0;
  var n = 0;
  var d = new Date(startDate.getTime());
  d.setHours(12, 0, 0, 0);
  var end = new Date(endDate.getTime());
  end.setHours(12, 0, 0, 0);
  while (d <= end) {
    n++;
    d.setDate(d.getDate() + 1);
  }
  return n;
}

function salaryPeriodWorkDaysElapsed(type) {
  var period = salaryPeriodInfo(type || 'monthly');
  var today = new Date();
  var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1, 12, 0, 0);
  var end = yesterday < period.end ? yesterday : period.end;
  if (end < period.start) return 0;
  return Math.min(period.totalDays || 31, countWorkDaysBetween(period.start, end));
}

function salaryCompletedPeriodInfo(type) {
  var period = salaryPeriodInfo(type || 'monthly');
  var today = new Date();
  var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1, 23, 59, 59);
  var completedEnd = yesterday < period.end ? yesterday : period.end;
  return Object.assign({}, period, { end: completedEnd });
}

async function syncSalaryAfterAttendanceChange(empId) {
  if (!empId) return;
  if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(empId);
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  if (!emp) return;
  if (typeof prefetchSalaryPreviews === 'function') {
    try {
      await prefetchSalaryPreviews([emp]);
    } catch (e) {
      console.warn('syncSalaryAfterAttendanceChange:', e);
    }
  }
  if (document.getElementById('sal-table') && typeof buildSalaries === 'function') buildSalaries();
  if (currentUser === 'emp' && typeof buildEmpPortal === 'function') buildEmpPortal();
}

function upsertEmployeeIntoStore(emp) {
  if (!emp || !emp.id) return;
  normalizeEmployee(emp);
  var idx = employees.findIndex(function (e) { return e && e.id === emp.id; });
  if (idx >= 0) employees[idx] = emp;
  else employees.push(emp);
}

function isFreshLocalDevice(ld) {
  return !!(ld && !ld.fingerprint && !ld.linked_at && !ld.last_login);
}

function mergeEmployeeDevicesPreferLinked(localDevs, remoteDevs) {
  var out = (remoteDevs || []).slice();
  (localDevs || []).forEach(function (ld) {
    if (!ld || !ld.slot) return;
    var rd = out.find(function (d) { return d.slot === ld.slot; });
    if (!rd) {
      out.push(ld);
      return;
    }
    var idx = out.indexOf(rd);
    if (isFreshLocalDevice(ld)) {
      if (rd.fingerprint || rd.linked_at || rd.last_login) {
        out[idx] = Object.assign({}, rd, {
          token: ld.token || rd.token,
          barcode: ld.barcode || rd.barcode,
          pin: ld.pin || rd.pin,
          label: ld.label || rd.label
        });
      } else {
        out[idx] = Object.assign({}, ld, {
          token: ld.token || rd.token,
          barcode: ld.barcode || rd.barcode
        });
      }
      return;
    }
    out[idx] = Object.assign({}, rd, {
      ip: ld.ip || rd.ip,
      fingerprint: ld.fingerprint || rd.fingerprint,
      token: ld.token || rd.token,
      barcode: ld.barcode || rd.barcode,
      pin: ld.pin || rd.pin,
      label: ld.label || rd.label,
      linked_at: ld.linked_at || rd.linked_at,
      last_login: ld.last_login || rd.last_login
    });
  });
  return out;
}

var DELETED_EMP_TOMBSTONE_MS = 7 * 24 * 60 * 60 * 1000;

function markEmployeeDeletedLocally(id) {
  var empId = parseInt(id, 10);
  if (!empId) return;
  if (!window.__basmaDeletedEmpIds) window.__basmaDeletedEmpIds = {};
  window.__basmaDeletedEmpIds[empId] = Date.now();
}

function clearEmployeeDeletedLocally(id) {
  var empId = parseInt(id, 10);
  if (!empId || !window.__basmaDeletedEmpIds) return;
  delete window.__basmaDeletedEmpIds[empId];
}

function isEmployeeRecentlyDeleted(id) {
  var empId = parseInt(id, 10);
  if (!empId || !window.__basmaDeletedEmpIds) return false;
  var ts = window.__basmaDeletedEmpIds[empId];
  if (!ts) return false;
  return (Date.now() - ts) < DELETED_EMP_TOMBSTONE_MS;
}

function filterRecentlyDeletedEmployees(list) {
  var localById = {};
  (employees || []).forEach(function (e) { if (e && e.id) localById[e.id] = e; });
  var now = Date.now();
  return (list || []).filter(function (e) {
    if (!e || !e.id) return false;
    if (!isEmployeeRecentlyDeleted(e.id)) return true;
    var local = localById[e.id];
    if (local && (local._pendingRemoteSync || (local._addedAt && (now - local._addedAt) < LOCAL_EMP_PREFER_MS))) {
      clearEmployeeDeletedLocally(e.id);
      return true;
    }
    return false;
  });
}

function purgeEmployeeLocalState(id) {
  var empId = parseInt(id, 10);
  if (!empId) return;
  markEmployeeDeletedLocally(empId);
  if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(empId);
  employees = (employees || []).filter(function (x) { return !x || Number(x.id) !== empId; });
  attData = (attData || []).filter(function (x) { return !x || Number(x.empId) !== empId; });
  if (Array.isArray(window.leavesData)) {
    window.leavesData = window.leavesData.filter(function (x) { return !x || Number(x.empId) !== empId; });
  }
  if (window.appSettings && appSettings.salaryDeletedMap && typeof appSettings.salaryDeletedMap === 'object') {
    Object.keys(appSettings.salaryDeletedMap).forEach(function (k) {
      if (String(k).indexOf(String(empId) + ':') === 0 || String(k).indexOf('-' + empId + '-') >= 0) {
        delete appSettings.salaryDeletedMap[k];
      }
    });
  }
  if (Array.isArray(appSettings.employeeNotifications)) {
    appSettings.employeeNotifications = appSettings.employeeNotifications.filter(function (n) {
      return !n || Number(n.empId) !== empId;
    });
  }
  if (window.__basmaEmpSession && parseInt(window.__basmaEmpSession.empId || '0', 10) === empId && typeof clearRegisteredDeviceCache === 'function') {
    clearRegisteredDeviceCache();
  }
  if (window.loggedInEmpId === empId) {
    window.loggedInEmpId = null;
    currentUser = null;
    checkedIn = false;
    checkInTime = null;
    if (typeof clearRegisteredDeviceCache === 'function') clearRegisteredDeviceCache();
  }
}

function filterAttendanceForEmployees(empList, attList) {
  var ids = {};
  (empList || []).forEach(function (e) { if (e && e.id) ids[e.id] = true; });
  return (attList || []).filter(function (r) { return r && ids[r.empId]; });
}

var LOCAL_EMP_PREFER_MS = 300000;

function mergeRemoteEmployeesWithLocal(remoteEmps) {
  var now = Date.now();
  if (typeof filterRecentlyDeletedEmployees === 'function') {
    remoteEmps = filterRecentlyDeletedEmployees(remoteEmps);
  }
  var localById = {};
  (employees || []).forEach(function (e) {
    if (e && e.id) localById[e.id] = e;
  });
  var merged = (remoteEmps || []).map(function (remote) {
    var local = localById[remote.id];
    if (!local) return remote;
    var pending = local._pendingRemoteSync || (local._addedAt && (now - local._addedAt) < LOCAL_EMP_PREFER_MS);
    var editedRecently = local._localEmpEditAt && (now - local._localEmpEditAt) < LOCAL_EMP_PREFER_MS;
    if (typeof BasmaConflict !== 'undefined' && BasmaConflict.shouldPromptEmployeeConflict &&
        BasmaConflict.shouldPromptEmployeeConflict(local, remote, now) && !pending) {
      BasmaConflict.queueConflict({
        type: 'employee',
        id: local.id,
        local: Object.assign({}, local),
        remote: Object.assign({}, remote),
        diffs: BasmaConflict.detectEmployeeConflict(local, remote)
      });
      if (typeof normalizeEmployeeSalaryFields === 'function') normalizeEmployeeSalaryFields(remote);
      return remote;
    }
    var salaryLocked = local._salaryLockedUntil && now < local._salaryLockedUntil;
    var preferLocal = pending || editedRecently || salaryLocked || local._freshDevices;
    if (!preferLocal && !local._localEmpEditAt && !local._addedAt) {
      if (typeof normalizeEmployeeSalaryFields === 'function') normalizeEmployeeSalaryFields(remote);
      return remote;
    }
    var out = Object.assign({}, remote, {
      name: local.name || remote.name,
      dept: local.dept || remote.dept,
      role: local.role || remote.role,
      phone: local.phone || remote.phone,
      days: local.days != null ? local.days : remote.days,
      lateMin: local.lateMin != null ? local.lateMin : remote.lateMin,
      checkIn: local.checkIn || remote.checkIn,
      checkOut: local.checkOut || remote.checkOut,
      remoteAttend: !!local.remoteAttend,
      openHours: !!local.openHours,
      salDeletedPeriod: local.salDeletedPeriod != null ? local.salDeletedPeriod : remote.salDeletedPeriod,
      salStatus: local.salStatus || remote.salStatus,
      salBonus: local.salBonus != null ? local.salBonus : remote.salBonus,
      hireDate: (local.hireDate != null && local.hireDate !== '') ? local.hireDate : remote.hireDate,
      active: preferLocal ? (local.active !== false) : (remote.active !== false),
      devices: mergeEmployeeDevicesPreferLinked(local.devices, remote.devices),
      _pendingRemoteSync: local._pendingRemoteSync,
      _addedAt: local._addedAt,
      _localEmpEditAt: local._localEmpEditAt,
      _salaryLockedUntil: local._salaryLockedUntil,
      _freshDevices: local._freshDevices
    });
    if (preferLocal || salaryLocked) {
      out.salaryType = local.salaryType || remote.salaryType || 'monthly';
      out.salary = local.salary != null ? parseExactInt(local.salary, 0) : parseExactInt(remote.salary, 0);
      out.salaryHalf = out.salaryType === 'biweekly'
        ? parseExactInt(local.salaryHalf != null ? local.salaryHalf : remote.salaryHalf, 0)
        : 0;
      out.dailyRate = local.dailyRate != null ? parseExactInt(local.dailyRate, 0) : parseExactInt(remote.dailyRate, 0);
    }
    if (typeof normalizeEmployeeSalaryFields === 'function') normalizeEmployeeSalaryFields(out);
    return out;
  });
  if (typeof mergeLocalPendingEmployees === 'function') {
    merged = mergeLocalPendingEmployees(merged);
  }
  merged.forEach(function (e) {
    if (e && typeof normalizeEmployeeSalaryFields === 'function') normalizeEmployeeSalaryFields(e);
  });
  return merged;
}

function isOfficialClosureErrorCode(code, detail) {
  var c = String(code || '').toLowerCase();
  var d = String(detail || '').toLowerCase();
  var merged = c + ' ' + d;
  if (merged.indexOf('official_closure_active') >= 0) return true;
  if (merged.indexOf('official closure') >= 0) return true;
  if (merged.indexOf('تعطيل') >= 0 && merged.indexOf('رسمي') >= 0) return true;
  if (merged.indexOf('عطلة') >= 0 && merged.indexOf('رسمية') >= 0) return true;
  if (!c) return false;
  return c === 'official_closure_active';
}

function mapAttendanceSaveErrorMessage(errCode, errDetail, mode) {
  var code = String(errCode || '').toLowerCase();
  var detail = String(errDetail || '');
  var actionWord = mode === 'checkout' ? 'الانصراف' : 'الحضور';
  if (code === 'employee_suspended') return 'تم إيقاف حسابك، يرجى مراجعة الإدارة.';
  if (code === 'subscription_inactive') return 'حساب الشركة موقوف — لا يمكن تسجيل ' + actionWord + '.';
  if (code === 'rate_limited') return 'تم تجاوز عدد المحاولات، حاول لاحقاً.';
  if (isOfficialClosureErrorCode(code, detail)) return 'الموقع معطل حالياً بسبب عطلة رسمية للشركة خلال الفترة المحددة في الإعدادات.';
  if (code === 'device_not_authorized') return 'الجهاز غير مصرح.';
  if (code.indexOf('rpc_function_missing') >= 0 || code.indexOf('could not find the function') >= 0 || code === 'pgrst202') {
    return 'تعذّر حفظ البصمة لأن دالة الحضور غير محدثة على السحابة. يلزم تشغيل آخر migrations ثم إعادة المحاولة.';
  }
  if (code.indexOf('no_auth') >= 0 || code.indexOf('jwt') >= 0) {
    return 'انتهت الجلسة أو غير مصرح لك. أعد تسجيل الدخول ثم حاول مرة أخرى.';
  }
  if (code === 'no_company_context' || code === 'tenant_mismatch') {
    return 'تعذّر حفظ ' + actionWord + ' — دالة الحضور على السحابة تحتاج تحديث migration 106. اطلب من المسؤول تشغيله في Supabase.';
  }
  if (code === 'cloud_unavailable') {
    return 'تعذّر الاتصال بالسحابة حالياً. تحقق من الإنترنت ثم حاول مرة أخرى.';
  }
  if (code === 'attendance_not_saved') {
    return 'تم رفض حفظ سجل الحضور من الخادم (حفظ إحصائيات فقط). يلزم تحديث دالة الحضور في Supabase.';
  }
  var mergedErr = (code + ' ' + detail).toLowerCase();
  if (/updated_at/i.test(mergedErr) && /attendance/i.test(mergedErr)) {
    return 'تعذّر حفظ ' + actionWord + ' — يلزم تطبيق migration 122 على Supabase. اطلب من المسؤول ثم أعد المحاولة.';
  }
  if (/does not exist/i.test(mergedErr) && /column/i.test(mergedErr)) {
    var rawHint = String(detail || code || '').trim();
    return 'تعذّر حفظ ' + actionWord + ' في السحابة. السبب: ' + (rawHint || 'خطأ عمود في قاعدة البيانات — طبّق migration 122');
  }
  var hint = code || String(detail || '').trim();
  if (hint) return 'تعذّر حفظ ' + actionWord + ' في السحابة. السبب: ' + hint;
  return 'تعذّر حفظ ' + actionWord + ' في السحابة. تحقق من الإنترنت ثم حاول مرة أخرى.';
}

async function persistAttendanceNow(rec) {
  if (!rec) return null;
  try {
    var saved = null;
    if (currentUser === 'emp' && typeof sb_upsertAttendanceFromDevice !== 'function') {
      return { ok: false, error: 'cloud_unavailable' };
    }
    if (currentUser === 'emp' && typeof sb_upsertAttendanceFromDevice === 'function') {
      saved = await sb_upsertAttendanceFromDevice(rec);
      if (!saved) return { ok: false, error: 'cloud_unavailable' };
      if (saved && saved.ok === false) {
        rec._pendingRemoteSync = true;
        if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
        return saved;
      }
      if (saved && saved.id) rec.id = saved.id;
      if (saved && saved.admin_reason) {
        rec._adminReason = String(saved.admin_reason);
        if (rec._adminReason === 'admin_batch_absence') rec._adminBatchAbsence = true;
      }
    } else if (typeof sb_upsertAttendance === 'function') {
      saved = await sb_upsertAttendance(rec);
      if (saved && saved.id) rec.id = saved.id;
    } else {
      return null;
    }
    if (saved) {
      rec._pendingRemoteSync = false;
      rec._localAttEditAt = Date.now();
      if (saved.id) rec.id = saved.id;
      if (saved.admin_reason) {
        rec._adminReason = String(saved.admin_reason);
        if (rec._adminReason === 'admin_batch_absence') rec._adminBatchAbsence = true;
      }
      if (typeof kynoAttendanceSyncHash === 'function') rec._lastCloudSyncHash = kynoAttendanceSyncHash(rec);
      if (rec.empId && typeof syncSalaryAfterAttendanceChange === 'function') {
        syncSalaryAfterAttendanceChange(rec.empId).catch(function (e) {
          console.warn('syncSalaryAfterAttendanceChange:', e);
        });
      }
      if (typeof BasmaCloud !== 'undefined') {
        if (BasmaCloud.updateConnectivityBanner) BasmaCloud.updateConnectivityBanner();
        if (currentUser !== 'emp' && BasmaCloud.scheduleImmediateCloudSync) BasmaCloud.scheduleImmediateCloudSync('attendance-saved');
      }
    } else {
      rec._pendingRemoteSync = true;
      if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
      if (typeof showPersistWarning === 'function') showPersistWarning('تعذّر حفظ الحضور في السحابة — سيتم إعادة المحاولة');
    }
    return saved;
  } catch (e) {
    console.warn('persistAttendanceNow failed:', e);
    if (rec) {
      rec._pendingRemoteSync = true;
      if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
    }
    return { ok: false, error: 'cloud_unavailable' };
  }
}

function ensureAttendanceRecordDates(rec) {
  if (!rec) return rec;
  var iso = attendanceRecordIso(rec);
  if (iso) {
    rec.dateIso = iso;
    if (!rec.date || rec.date === '—') {
      rec.date = typeof formatAttendanceDisplayDate === 'function'
        ? formatAttendanceDisplayDate(rec)
        : iso.replace(/-/g, '/');
    }
    return rec;
  }
  if (rec._punchType && typeof todayIsoDate === 'function') {
    rec.dateIso = todayIsoDate();
    if (!rec.date && typeof todayAttDate === 'function') rec.date = todayAttDate();
  }
  return rec;
}

function attendanceNowLabel() {
  return formatAppTimeAmPm(new Date(), false);
}

function minutesToHoursStr(totalMin) {
  if (!Number.isFinite(totalMin) || totalMin <= 0) return '0س 0د';
  return Math.floor(totalMin / 60) + 'س ' + (totalMin % 60) + 'د';
}

function calcAttendanceWorkHours(rec, emp) {
  if (!rec || !emp) return '—';
  if (!rec.ci || rec.ci === '—' || !rec.co || rec.co === '—') return '—';
  if (emp.openHours) return 'يوم كامل';
  var ciMin = timeToMinutes(rec.ci);
  var coMin = timeToMinutes(rec.co);
  if (coMin >= ciMin) return minutesToHoursStr(coMin - ciMin);
  if (isOvernightShift(emp)) return minutesToHoursStr((24 * 60 - ciMin) + coMin);
  return '0س 0د';
}

function syncAttendanceRecordHours(rec, emp) {
  if (!rec) return rec;
  if (!emp && rec.empId) emp = (employees || []).find(function (e) { return e && e.id === rec.empId; });
  if (!emp) return rec;
  if (!rec.ci || rec.ci === '—' || !rec.co || rec.co === '—') {
    if (!rec.co || rec.co === '—') rec.hrs = '—';
    return rec;
  }
  rec.hrs = calcAttendanceWorkHours(rec, emp);
  return rec;
}

function formatWorkHoursDisplay(rec, emp) {
  if (!rec) return '—';
  if (!emp && rec.empId) emp = (employees || []).find(function (e) { return e && e.id === rec.empId; });
  if (emp && emp.openHours && rec.ci && rec.ci !== '—' && rec.co && rec.co !== '—') return 'يوم كامل';
  var hrs = rec.hrs;
  if (hrs && hrs !== '—' && hrs !== '0س 0د' && hrs !== '0:00') return hrs;
  return calcAttendanceWorkHours(rec, emp);
}

async function refreshEmployeeDevicesUi(empId) {
  if (empId && typeof sb_refreshEmployeeDevices === 'function') {
    await sb_refreshEmployeeDevices(empId);
  } else if (typeof sb_refreshEmployeeDevices === 'function') {
    var list = window.employees || [];
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].id) await sb_refreshEmployeeDevices(list[i].id);
    }
  }
  if (typeof saveData === 'function') saveData();
  if (typeof buildEmployees === 'function') buildEmployees();
  if (typeof buildDeviceManagement === 'function') buildDeviceManagement();
}

function applyOptimisticPunchToRecord(rec, punchType) {
  if (!rec) return rec;
  ensureAttendanceRecordDates(rec);
  var t = attendanceNowLabel();
  if (punchType === 'check_out') {
    rec.co = t;
    if (!rec.ci || rec.ci === '—') rec.ci = checkInTime || t;
  } else {
    rec.ci = t;
    if (!rec.co) rec.co = '—';
  }
  if (punchType === 'check_out') {
    var emp = (employees || []).find(function (e) { return e && e.id === rec.empId; });
    syncAttendanceRecordHours(rec, emp);
  }
  rec._localAttEditAt = Date.now();
  if (typeof currentUser === 'undefined' || currentUser !== 'emp') {
    rec._pendingRemoteSync = true;
  }
  return rec;
}

function applyServerAttendanceToRecord(rec, saved, emp) {
  if (!rec || !saved || saved.ok !== true) return rec;
  if (saved.id) rec.id = saved.id;
  if (saved.date_iso) rec.dateIso = String(saved.date_iso).slice(0, 10);
  if (saved.date_label) rec.date = saved.date_label;
  var hasServerTimes = !!(saved.check_in && saved.check_in !== '—') || !!(saved.check_out && saved.check_out !== '—');
  if (saved.server_authoritative !== true && !hasServerTimes && !saved.id) return rec;
  if (saved.check_in && saved.check_in !== '—') rec.ci = saved.check_in;
  if (saved.check_out && saved.check_out !== '—') rec.co = saved.check_out;
  if (saved.hours && saved.hours !== '—') rec.hrs = saved.hours;
  syncAttendanceRecordHours(rec, emp);
  if (saved.late != null) rec.late = saved.late;
  if (saved.overtime != null) rec.ot = saved.overtime;
  if (saved.status) rec.status = saved.status;
  if (saved.date_label) rec.date = saved.date_label;
  if (saved.date_iso) rec.dateIso = String(saved.date_iso).slice(0, 10);
  if (emp && saved.late && saved.late !== '—') {
    var lateNum = parseDurationMinutes(saved.late);
    if (Number.isFinite(lateNum) && lateNum > 0) emp.lateMin = (emp.lateMin || 0) + lateNum;
  }
  return rec;
}

async function persistEmployeeNow(emp) {
  if (!emp) return false;
  if (typeof isEmployeeRecentlyDeleted === 'function' && isEmployeeRecentlyDeleted(emp.id) &&
      !emp._pendingRemoteSync && !emp._addedAt) {
    return false;
  }
  if (typeof BasmaTenant !== 'undefined' && BasmaTenant.assertTenantRecord && !BasmaTenant.assertTenantRecord(emp, 'persistEmployeeNow')) {
    return false;
  }
  if (typeof BasmaTenant !== 'undefined' && BasmaTenant.guardReplay &&
      !BasmaTenant.guardReplay(BasmaTenant.buildActionKey('persistEmployee', { id: emp.id, ts: emp._localEmpEditAt }))) {
    return false;
  }
  try {
    if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
      await AuthApi.ensureValidSession();
    }
    if (currentUser === 'emp') {
      if (typeof sb_patchEmployeeStatsFromDevice === 'function') {
        await sb_patchEmployeeStatsFromDevice(emp);
      }
      return true;
    }
    if (typeof sb_upsertEmployee !== 'function') return false;
    var saved = await sb_upsertEmployee(emp, { requireExisting: false });
    if (saved) {
      emp._pendingRemoteSync = false;
      if (typeof clearEmployeeDeletedLocally === 'function') clearEmployeeDeletedLocally(emp.id);
      if (typeof kynoEmployeeSyncHash === 'function') emp._lastCloudSyncHash = kynoEmployeeSyncHash(emp);
      if (typeof BasmaCloud !== 'undefined' && BasmaCloud.scheduleImmediateCloudSync) {
        BasmaCloud.scheduleImmediateCloudSync('employee-saved');
      }
      return true;
    }
    emp._pendingRemoteSync = true;
    if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
    if (typeof showPersistWarning === 'function') showPersistWarning('تعذّر حفظ بيانات الموظف في السحابة — سيتم إعادة المحاولة');
    return false;
  } catch (e) {
    console.warn('persistEmployeeNow failed:', e);
    emp._pendingRemoteSync = true;
    if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
    if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
    return false;
  }
}

function showPersistWarning(message) {
  if (window.BasmaToast && typeof BasmaToast.warn === 'function') {
    BasmaToast.warn(message);
  } else {
    console.warn(message);
  }
}
window.showPersistWarning = showPersistWarning;

async function persistSalaryDeletedMapNow() {
  return persistAppSettingsNow();
}

function shortEmpName(fullName) {
  const parts = fullName.trim().split(/\s+/);
  if (parts.length >= 2) return parts[0] + ' ' + parts[parts.length - 1];
  return fullName.trim();
}

/** الاسم الكامل للموظف — يُستخدم في سجلات الحضور والتقارير */
function fullEmpName(name) {
  return String(name || '').trim();
}

/** اسم العرض في جدول الحضور — يفضّل الاسم الكامل من بطاقة الموظف */
function attRecordDisplayName(rec) {
  if (!rec) return '';
  const emp = (employees || []).find(e => e && e.id === rec.empId);
  if (emp && emp.name) return fullEmpName(emp.name);
  return fullEmpName(rec.emp);
}

/** مزامنة أسماء/أقسام سجلات الحضور مع بطاقات الموظفين الحالية */
function syncAllAttendanceEmployeeNames() {
  let changed = false;
  (attData || []).forEach(r => {
    if (!r || !r.empId) return;
    const emp = (employees || []).find(e => e && e.id === r.empId);
    if (!emp || !emp.name) return;
    const full = fullEmpName(emp.name);
    if (r.emp !== full) { r.emp = full; changed = true; }
    if (emp.dept && r.dept !== emp.dept) { r.dept = emp.dept; changed = true; }
  });
  return changed;
}

function fmtTimeDisplay(t) {
  if (!t || t === '—') return '—';
  return typeof formatDisplayTime === 'function' ? formatDisplayTime(t, false) : t;
}

function pickAvatar(name) {
  return (name.trim().charAt(0) || '؟');
}

function pickAvatarClass(id) {
  return 'a' + (((id - 1) % 5) + 1);
}

var APP_TIMEZONE = 'Asia/Baghdad';

function getAppDateParts(date) {
  var d = date || new Date();
  var parts = new Intl.DateTimeFormat('en-US', {
    timeZone: APP_TIMEZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'short',
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
    hour12: !(typeof BasmaTime !== 'undefined' && BasmaTime.use24HourClock && BasmaTime.use24HourClock())
  }).formatToParts(d);
  var out = {};
  parts.forEach(function (p) { out[p.type] = p.value; });
  return out;
}

function todayIsoDate() {
  var p = getAppDateParts();
  return p.year + '-' + p.month + '-' + p.day;
}

function todayAttDate() {
  var days = ['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
  var months = ['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
  var p = getAppDateParts();
  var dayMap = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  var dow = dayMap[p.weekday] != null ? dayMap[p.weekday] : 0;
  return days[dow] + ' ' + parseInt(p.day, 10) + ' ' + months[parseInt(p.month, 10) - 1];
}

function formatAttendanceDisplayDate(rec) {
  if (!rec) return '—';
  var iso = String(rec.dateIso || rec.date_iso || '').slice(0, 10);
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) {
    return iso.replace(/-/g, '/');
  }
  var raw = String(rec.date || '').trim();
  var m = raw.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (m) return m[1] + '/' + String(m[2]).padStart(2, '0') + '/' + String(m[3]).padStart(2, '0');
  return raw || '—';
}

function attRecordInDateRange(rec, fromIso, toIso) {
  if (!rec) return false;
  var iso = attendanceRecordIso(rec);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(iso)) return false;
  return iso >= fromIso && iso <= toIso;
}

function attendanceRecordIso(rec) {
  if (!rec) return '';
  var iso = String(rec.dateIso || rec.date_iso || '').slice(0, 10);
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso;
  var raw = String(rec.date || '').trim();
  var m = raw.match(/^(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (m) return m[1] + '-' + String(m[2]).padStart(2, '0') + '-' + String(m[3]).padStart(2, '0');
  return '';
}

function attendanceRecordKey(rec) {
  if (!rec || !rec.empId) return '';
  var iso = attendanceRecordIso(rec);
  return iso ? String(rec.empId) + '|' + iso : '';
}

function attendanceRecordRank(rec) {
  var rank = 0;
  if (rec && rec.id) rank += 100;
  if (rec && rec.ci && rec.ci !== '—') rank += 10;
  if (rec && !rec._pendingRemoteSync) rank += 5;
  if (rec && rec._localAttEditAt) rank += 1;
  return rank;
}

/** سجل غياب إداري (دفعة يدوية) — يُحتسب في الراتب ولا يظهر في بصمة الحضور */
function employeeHireIso(empOrId) {
  var emp = empOrId;
  if (typeof empOrId === 'number' || typeof empOrId === 'string') {
    emp = (employees || []).find(function (e) { return e && String(e.id) === String(empOrId); });
  }
  if (!emp) return '';
  return String(emp.hireDate || emp.hire_date || '').slice(0, 10);
}

function isHireDateBackfillAbsence(rec) {
  if (!rec || rec.status !== 'غياب') return false;
  if (rec._adminReason === 'hire_date_backfill') return true;
  var hireIso = employeeHireIso(rec.empId);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(hireIso)) return false;
  var recIso = attendanceRecordIso(rec);
  if (!recIso) return false;
  var monthStart = hireIso.slice(0, 8) + '01';
  var dayBeforeHire = addIsoDays(hireIso, -1);
  if (!dayBeforeHire || recIso < monthStart || recIso > dayBeforeHire) return false;
  var todayIso = typeof todayIsoDate === 'function' ? todayIsoDate() : '';
  if (todayIso && recIso > todayIso) return false;
  return true;
}

function isAdminOnlyAbsenceRecord(rec) {
  if (!rec) return false;
  if (isHireDateBackfillAbsence(rec)) return false;
  if (rec._adminReason === 'hire_date_backfill') return false;
  if (rec._adminBatchAbsence === true) return true;
  if (rec._adminReason === 'admin_batch_absence') return true;
  var noCi = !rec.ci || rec.ci === '—';
  var noCo = !rec.co || rec.co === '—';
  if (rec._adminReason && rec._adminReason !== 'hire_date_backfill' && rec.status === 'غياب' && noCi && noCo) return true;
  if (rec.status === 'غياب' && noCi && noCo) return true;
  return false;
}

/** سجل بصمة فعلية (حضور/انصراف) — يظهر في شاشة الحضور */
function isPunchAttendanceRecord(rec) {
  if (!rec) return false;
  if (isHireDateBackfillAbsence(rec)) return true;
  if (isAdminOnlyAbsenceRecord(rec)) return false;
  if (rec.ci && rec.ci !== '—') return true;
  if (rec.co && rec.co !== '—') return true;
  return rec.status && rec.status !== 'غياب';
}

function dedupeAttendanceRecords(list) {
  var byKey = {};
  (list || []).forEach(function (rec) {
    if (!rec) return;
    ensureAttendanceRecordDates(rec);
    var iso = attendanceRecordIso(rec);
    if (iso) rec.dateIso = iso;
    var key = attendanceRecordKey(rec);
    if (!key) return;
    var prev = byKey[key];
    if (!prev || attendanceRecordRank(rec) > attendanceRecordRank(prev)) byKey[key] = rec;
  });
  return Object.keys(byKey).map(function (k) { return byKey[k]; });
}

function countEmployeePresentDays(empId, list) {
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  var keys = {};
  (list || []).forEach(function (r) {
    if (!r || r.empId !== empId) return;
    if (!r.ci || r.ci === '—' || r.status === 'غياب') return;
    if (emp && emp.openHours && (!r.co || r.co === '—')) return;
    var k = attendanceRecordKey(r);
    if (k) keys[k] = true;
  });
  return Object.keys(keys).length;
}

function countEmployeeLateMinutes(empId, list) {
  var total = 0;
  var seen = {};
  (list || []).forEach(function (r) {
    if (!r || r.empId !== empId) return;
    var k = attendanceRecordKey(r);
    if (!k || seen[k]) return;
    seen[k] = true;
    if (r.late && r.late !== '—') {
      var n = parseDurationMinutes(r.late);
      if (Number.isFinite(n)) total += n;
    }
  });
  return total;
}

function normalizeAttendanceStore() {
  attData = dedupeAttendanceRecords(attData || []);
  window.attData = attData;
  (employees || []).forEach(function (emp) {
    if (!emp || !emp.id) return;
    emp.days = countEmployeePresentDays(emp.id, attData);
    emp.lateMin = countEmployeeLateMinutes(emp.id, attData);
  });
}

function isAttendanceRecordToday(r) {
  if (!r) return false;
  var iso = todayIsoDate();
  if (r.dateIso) return String(r.dateIso).slice(0, 10) === iso;
  if (r.date_iso) return String(r.date_iso).slice(0, 10) === iso;
  return r.date === todayAttDate();
}

function isOvernightShift(emp) {
  if (!emp) return false;
  var ci = timeToMinutes(emp.checkIn || (appSettings && appSettings.workStart) || '08:00');
  var co = timeToMinutes(emp.checkOut || (appSettings && appSettings.workEnd) || '17:00');
  return co <= ci;
}

function getAppMinutesNow() {
  var p = getAppDateParts(new Date());
  return (parseInt(p.hour, 10) || 0) * 60 + (parseInt(p.minute, 10) || 0);
}

function isOvernightCheckoutWindow(emp) {
  if (!isOvernightShift(emp)) return false;
  return getAppMinutesNow() <= timeToMinutes(emp.checkIn || '22:00');
}

function isOpenOvernightRecord(r, emp) {
  if (!r || !emp || !isOvernightShift(emp)) return false;
  if (!r.ci || r.ci === '—' || (r.co && r.co !== '—')) return false;
  var iso = typeof attendanceRecordIso === 'function'
    ? attendanceRecordIso(r)
    : String(r.dateIso || r.date_iso || '').slice(0, 10);
  if (!iso) return false;
  var yesterday = addIsoDays(todayIsoDate(), -1);
  if (iso !== yesterday) return false;
  return isOvernightCheckoutWindow(emp);
}

function isActiveOpenAttendanceRecord(r, emp) {
  if (!r || !r.ci || r.ci === '—' || (r.co && r.co !== '—')) return false;
  if (isAttendanceRecordToday(r)) return true;
  return isOpenOvernightRecord(r, emp);
}

function getEmpPortalAttendanceRecord(emp) {
  if (!emp) return null;
  var todayRec = attData.find(function (r) {
    return r && r.empId === emp.id && isAttendanceRecordToday(r);
  });
  if (todayRec) return todayRec;
  return findOpenAttendanceRecord(emp.id, false);
}

function formatAppTimeAmPm(date, withSeconds) {
  if (typeof formatDateClock === 'function') return formatDateClock(date, withSeconds);
  var p = getAppDateParts(date);
  var h = parseInt(p.hour, 10);
  var m = String(parseInt(p.minute, 10)).padStart(2, '0');
  var ap = (p.dayPeriod || '').toUpperCase();
  if (!ap) ap = h >= 12 ? 'PM' : 'AM';
  var hh = String(h).padStart(2, '0');
  if (withSeconds) {
    var s = String(parseInt(p.second || '0', 10)).padStart(2, '0');
    return hh + ':' + m + ':' + s + ' ' + ap;
  }
  return hh + ':' + m + ' ' + ap;
}

function syncAttForEmployee(emp) {
  const isComm = (emp.salaryType || 'monthly') === 'commission';
  attData.forEach(r => {
    if (r.empId === emp.id) {
      r.emp = fullEmpName(emp.name);
      r.dept = emp.dept;
      // Recalculate late/ot/status based on current openHours setting
      if (r.ci && r.ci !== '—') {
        if (isComm || emp.openHours) {
          // Commission or open hours: no late/overtime; open hours is counted after checkout.
          r.late = '—';
          r.ot = '—';
          r.status = 'طبيعي';
        } else {
          // Normal mode: recalculate late from check-in time
          const empCi = emp.checkIn || '08:00';
          const empCo = emp.checkOut || '17:00';
          
          const actualCiMin = timeToMinutes(r.ci);
          const officialCiMin = timeToMinutes(empCi);
          const lateMin = Math.max(0, actualCiMin - officialCiMin);
          r.late = lateMin > 0 ? lateMin + 'د' : '—';

          const actualCoMin = timeToMinutes(r.co);
          const officialCoMin = timeToMinutes(empCo);
          if (actualCoMin > 0 && r.co && r.co !== '—') {
            const otMin = Math.max(0, actualCoMin - officialCoMin);
            r.ot = otMin > 0 ? (Math.floor(otMin/60) + 'س ' + (otMin%60) + 'د') : '—';
          } else {
            r.ot = '—';
          }
          // Set status
          if (lateMin > getEmpLateThreshold(emp)) r.status = 'متأخر';
          else if (r.ot !== '—') r.status = 'إضافي';
          else r.status = 'طبيعي';
        }
      }
      syncAttendanceRecordHours(r, emp);
    }
  });
}

function recalcAllAttendance() {
  // Recalculate late/ot/status for all attendance records based on current employee settings
  attData.forEach(r => {
    const emp = employees.find(e => e.id === r.empId);
    if (!emp) return;
    const isComm = (emp.salaryType || 'monthly') === 'commission';
    if (r.ci && r.ci !== '—') {
      if (isComm || emp.openHours) {
        r.late = '—';
        r.ot = '—';
        r.status = 'طبيعي';
      } else {
        const empCi = emp.checkIn || '08:00';
        const empCo = emp.checkOut || '17:00';
        
        const actualCiMin = timeToMinutes(r.ci);
        const officialCiMin = timeToMinutes(empCi);
        const lateMin = Math.max(0, actualCiMin - officialCiMin);
        r.late = lateMin > 0 ? lateMin + 'د' : '—';

        const actualCoMin = timeToMinutes(r.co);
        const officialCoMin = timeToMinutes(empCo);
        if (actualCoMin > 0) {
          const otMin = Math.max(0, actualCoMin - officialCoMin);
          r.ot = otMin > 0 ? (Math.floor(otMin/60) + 'س ' + (otMin%60) + 'د') : '—';
        } else {
          r.ot = '—';
        }
        // Set status
        if (lateMin > getEmpLateThreshold(emp)) r.status = 'متأخر';
        else if (r.ot !== '—') r.status = 'إضافي';
        else r.status = 'طبيعي';
      }
      syncAttendanceRecordHours(r, emp);
    } else if (r.status !== 'غياب') {
      r.status = 'غياب';
    }
  });
  saveData();
}

function findOpenAttendanceRecord(empId, requireActiveShift) {
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  return attData.find(function (r) {
    if (!r || r.empId !== empId) return false;
    if (requireActiveShift === false) {
      return isActiveOpenAttendanceRecord(r, emp);
    }
    if (isAttendanceRecordToday(r)) return isActiveOpenAttendanceRecord(r, emp);
    return isOpenOvernightRecord(r, emp);
  }) || null;
}

function createAttRecord(empId, dept, name) {
  return {
    empId, emp: fullEmpName(name), dept,
    date: todayAttDate(), dateIso: todayIsoDate(), ci:'—', co:'—', hrs:'—', late:'—', ot:'—', status:'غياب'
  };
}

/**
 * توليد سجلات غياب فعلية للأيام السابقة لتاريخ المباشرة داخل شهر المباشرة.
 * النطاق: من أول يوم في شهر تاريخ المباشرة حتى اليوم السابق للمباشرة.
 * يتخطّى: السجلات الموجودة مسبقاً، أيام الإجازات المعتمدة، والعطل الرسمية، وأي يوم مستقبلي.
 * ملاحظة: هذه السجلات تظهر في سجل الحضور والتقارير، ولا تُحتسب في الراتب لأنها قبل تاريخ المباشرة
 *          (الخادم يبدأ الاحتساب من effective_start = hire_date، والواجهة كذلك بعد هذا التعديل).
 */
async function backfillHireDateAbsences(emp) {
  if (!emp || currentUser === 'emp') return { created: 0 };
  var hireIso = employeeHireIso(emp);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(hireIso)) return { created: 0 };
  var todayIso = typeof todayIsoDate === 'function' ? todayIsoDate() : new Date().toISOString().slice(0, 10);
  var monthStartIso = hireIso.slice(0, 8) + '01';
  var endIso = addIsoDays(hireIso, -1);
  if (!endIso || endIso < monthStartIso) return { created: 0 };
  var recs = [];
  var cur = monthStartIso;
  var guard = 0;
  while (cur && cur <= endIso && guard < 400) {
    guard++;
    var iso = cur;
    cur = addIsoDays(cur, 1);
    if (iso > todayIso) continue;
    var key = String(emp.id) + '|' + iso;
    var dup = (attData || []).find(function (a) { return a && a.empId === emp.id && attendanceRecordKey(a) === key; });
    if (dup) continue;
    if (typeof isDateOnEmployeeLeave === 'function' && isDateOnEmployeeLeave(emp.id, iso)) continue;
    if (typeof officialClosureForDate === 'function' && officialClosureForDate(iso)) continue;
    var rec = {
      empId: emp.id, emp: fullEmpName(emp.name), dept: emp.dept,
      date: iso.replace(/-/g, '/'), dateIso: iso,
      ci: '—', co: '—', hrs: '—', late: '—', ot: '—', status: 'غياب',
      _adminReason: 'hire_date_backfill'
    };
    if (emp.company_id != null) rec.company_id = emp.company_id;
    attData.push(rec);
    recs.push(rec);
  }
  for (var i = 0; i < recs.length; i++) {
    try {
      if (typeof persistAttendanceNow === 'function') await persistAttendanceNow(recs[i]);
    } catch (e) { console.warn('backfillHireDateAbsences persist:', e); }
  }
  if (recs.length) saveData();
  return { created: recs.length };
}

function focusAttendanceHireMonth(empId) {
  var periodEl = document.getElementById('att-filter-period');
  if (periodEl) periodEl.value = 'month';
  var fromEl = document.getElementById('att-filter-from');
  var toEl = document.getElementById('att-filter-to');
  if (fromEl) fromEl.value = '';
  if (toEl) toEl.value = '';
  if (empId) {
    var emp = (employees || []).find(function (e) { return e && e.id === empId; });
    var nameEl = document.getElementById('att-filter-name');
    if (nameEl && emp && emp.name) nameEl.value = emp.name;
  }
}

async function backfillAllHireDateAbsences(options) {
  options = options || {};
  if (currentUser === 'emp') return { created: 0 };
  var total = 0;
  for (var i = 0; i < (employees || []).length; i++) {
    var emp = employees[i];
    if (!emp || !employeeHireIso(emp)) continue;
    var r = await backfillHireDateAbsences(emp);
    total += (r && r.created) || 0;
  }
  if (total > 0) {
    if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
    if (!options.silent) focusAttendanceHireMonth();
    if (typeof buildAttendance === 'function') buildAttendance();
  }
  return { created: total };
}

function refreshAll() {
  if (handleDeletedLoggedEmployee()) return;
  if (typeof hydrateFinanceItemsFromCloud === 'function' && currentUser !== 'emp') {
    hydrateFinanceItemsFromCloud({ forceRemote: true, replace: true }).catch(function () {});
  }
  if (syncAllAttendanceEmployeeNames()) saveData();
  if (typeof syncLeavesFromSupabase === 'function') {
    syncLeavesFromSupabase().then(function () {
      if (typeof buildLeaves === 'function' && document.getElementById('leaves-content')) buildLeaves();
      if (typeof buildLeaveBadge === 'function') buildLeaveBadge();
      if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
      if (typeof buildDashboard === 'function') buildDashboard();
    }).catch(function (e) { console.warn('refreshAll leaves:', e); });
  }
  if (typeof buildEmployees === 'function') buildEmployees();
  if (typeof buildAttendance === 'function') buildAttendance();
  if (typeof buildDeviceManagement === 'function') buildDeviceManagement();
  buildFinancePage();
  buildOrgPage();
  if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
  buildDashboard();
  buildReports();
  buildNotifications();
  if (currentUser === 'emp') buildEmpPortal();
  if (typeof prefetchSalaryPreviews === 'function') {
    prefetchSalaryPreviews(employees).then(function () {
      if (document.getElementById('sal-table')) buildSalaries();
      if (document.getElementById('paid-sal-table')) buildPaidSalaries();
      if (currentUser === 'emp') buildEmpPortal();
      if (document.getElementById('page-reports') && document.getElementById('page-reports').classList.contains('active') && typeof buildReportCharts === 'function') buildReportCharts();
    }).catch(function (e) { console.warn('refreshAll salary prefetch:', e); });
  } else if (typeof buildSalaries === 'function') {
    buildSalaries();
    if (typeof buildPaidSalaries === 'function') buildPaidSalaries();
  }
  if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
}

function filterEmployees() {
  const el = document.getElementById('emp-search');
  empSearchQuery = el ? el.value.trim().toLowerCase() : '';
  if (typeof buildEmployees === 'function') buildEmployees();
}

function basmaBootstrapData() {
  var hasEmpSession = !!(window.loggedInEmpId || (window.__basmaEmpSession && window.__basmaEmpSession.empId));
  if (!hasEmpSession && typeof restoreEmployeeDeviceSession === 'function') {
    restoreEmployeeDeviceSession();
    hasEmpSession = !!(window.loggedInEmpId || (window.__basmaEmpSession && window.__basmaEmpSession.empId));
  }
  if (!hasEmpSession && typeof loadData === 'function') loadData();
  if (typeof cleanCorruptedData === 'function') cleanCorruptedData();
  if (typeof deduplicateAllDeviceTokens === 'function') deduplicateAllDeviceTokens();
  if (typeof recalcAllAttendance === 'function') recalcAllAttendance();
  if (typeof syncAllAttendanceEmployeeNames === 'function' && syncAllAttendanceEmployeeNames()) {
    if (typeof saveData === 'function') saveData();
  }
  if (typeof BasmaCloud !== 'undefined' && BasmaCloud.initCloudSync) BasmaCloud.initCloudSync();
  if (typeof BasmaLeaveGuard !== 'undefined' && BasmaLeaveGuard.initLeaveGuard) BasmaLeaveGuard.initLeaveGuard();
  if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
  if (currentUser === 'admin' && saasCurrentUser && saasCurrentUser.company_id &&
      typeof BasmaCloud !== 'undefined' && BasmaCloud.isOnline && BasmaCloud.isOnline()) {
    BasmaCloud.cloudRefreshFromServer({ reason: 'bootstrap-admin' }).then(function () {
      if (typeof refreshAll === 'function') refreshAll();
    }).catch(function (e) { console.warn('bootstrap cloud refresh:', e); });
  }
}
if (window.__basmaModulesReady) basmaBootstrapData();
else window.addEventListener('basma:modules-ready', basmaBootstrapData, { once: true });

// ======= THEME =======
const THEME_KEY = 'attendance_theme';

function swalTheme() {
  const light = document.documentElement.getAttribute('data-theme') === 'light';
  return { background: light ? '#ffffff' : '#0f2240', color: light ? '#1a202c' : '#e8f4fd', confirmButtonColor: '#00d4aa' };
}

function batchProgressHtml(title, subtitle) {
  return '<div class="batch-progress-wrap" style="text-align:center;padding:8px 4px 2px;font-family:Cairo,sans-serif">' +
    '<div style="font-size:18px;font-weight:800;margin-bottom:6px">' + esc(title) + '</div>' +
    '<div id="batch-progress-subtitle" style="font-size:13px;opacity:0.72;margin-bottom:18px">' + esc(subtitle || '') + '</div>' +
    '<div style="background:rgba(127,127,127,0.22);border-radius:999px;height:14px;overflow:hidden;box-shadow:inset 0 1px 3px rgba(0,0,0,0.12)">' +
    '<div id="batch-progress-bar" style="width:0%;height:100%;background:linear-gradient(90deg,#00d4aa,#2563a8);transition:width 0.15s ease;border-radius:999px"></div></div>' +
    '<div id="batch-progress-pct" style="font-size:15px;font-weight:800;margin-top:10px;color:#00d4aa">0%</div>' +
    '<div id="batch-progress-detail" style="font-size:12px;opacity:0.72;margin-top:8px;min-height:18px"></div>' +
    '</div>';
}

function setBatchProgress(current, total, detail, subtitle) {
  var pct = total > 0 ? Math.min(100, Math.round((current / total) * 100)) : (current > 0 ? 100 : 0);
  var bar = document.getElementById('batch-progress-bar');
  var pctEl = document.getElementById('batch-progress-pct');
  var detEl = document.getElementById('batch-progress-detail');
  var subEl = document.getElementById('batch-progress-subtitle');
  if (bar) bar.style.width = pct + '%';
  if (pctEl) pctEl.textContent = pct + '%';
  if (detEl) detEl.textContent = detail != null ? detail : (current + ' / ' + total);
  if (subEl && subtitle) subEl.textContent = subtitle;
}

function parseIsoDateOnly(value) {
  var s = String(value || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return '';
  var d = new Date(s + 'T12:00:00');
  return Number.isFinite(d.getTime()) ? s : '';
}

function localDateToIso(date) {
  if (!date || !Number.isFinite(date.getTime())) return '';
  var y = date.getFullYear();
  var m = String(date.getMonth() + 1).padStart(2, '0');
  var d = String(date.getDate()).padStart(2, '0');
  return y + '-' + m + '-' + d;
}

function addIsoDays(iso, days) {
  var clean = parseIsoDateOnly(iso);
  if (!clean) return '';
  var d = new Date(clean + 'T12:00:00');
  d.setDate(d.getDate() + (parseInt(days, 10) || 0));
  return d.toISOString().slice(0, 10);
}

function normalizeOfficialClosures(list) {
  if (!Array.isArray(list)) return [];
  var out = [];
  list.forEach(function (item) {
    if (!item) return;
    var start = parseIsoDateOnly(item.startDate || item.start || item.from);
    var days = Math.max(1, parseInt(item.days, 10) || 0);
    var end = parseIsoDateOnly(item.endDate || item.end || item.to) || (start ? addIsoDays(start, days - 1) : '');
    if (!start || !end) return;
    if (new Date(end + 'T12:00:00') < new Date(start + 'T12:00:00')) {
      var tmp = start; start = end; end = tmp;
    }
    var paid = String(item.payType || item.type || '').toLowerCase() !== 'unpaid';
    var diffDays = Math.round((new Date(end + 'T12:00:00') - new Date(start + 'T12:00:00')) / 86400000) + 1;
    out.push({
      id: String(item.id || ('closure_' + start.replace(/-/g, '') + '_' + Math.random().toString(36).slice(2, 8))),
      title: String(item.title || item.name || 'تعطيل رسمي').trim() || 'تعطيل رسمي',
      startDate: start,
      endDate: end,
      days: Math.max(1, diffDays),
      payType: paid ? 'paid' : 'unpaid'
    });
  });
  return out.sort(function (a, b) { return String(b.startDate).localeCompare(String(a.startDate)); });
}

function officialClosureForDate(dateIso) {
  var iso = parseIsoDateOnly(dateIso || (typeof todayIsoDate === 'function' ? todayIsoDate() : ''));
  if (!iso) return null;
  var closures = normalizeOfficialClosures(appSettings.officialClosures || []);
  for (var i = 0; i < closures.length; i++) {
    var c = closures[i];
    if (iso >= c.startDate && iso <= c.endDate) return c;
  }
  if (currentUser === 'emp' && window.__empActiveOfficialClosure) {
    var ac = window.__empActiveOfficialClosure;
    if (iso >= ac.startDate && iso <= ac.endDate) return ac;
  }
  return null;
}

async function refreshOfficialClosuresFromCloud() {
  if (currentUser === 'emp' && window.loggedInEmpId) {
    window.__empActiveOfficialClosure = null;
    try {
      if (typeof sb_getActiveOfficialClosureForEmployee === 'function') {
        var active = await sb_getActiveOfficialClosureForEmployee(window.loggedInEmpId);
        if (active && active.ok === true && active.active === true && active.closure) {
          var activeNorm = normalizeOfficialClosures([active.closure]);
          window.__empActiveOfficialClosure = activeNorm[0] || active.closure;
          var mergedActive = normalizeOfficialClosures(appSettings.officialClosures || []);
          var hitActive = mergedActive.some(function (c) { return c.id === window.__empActiveOfficialClosure.id; });
          if (!hitActive) mergedActive.push(window.__empActiveOfficialClosure);
          appSettings.officialClosures = normalizeOfficialClosures(mergedActive);
          if (typeof saveData === 'function') saveData();
        }
      }
      if (typeof sb_getOfficialClosuresJsonForEmployee === 'function') {
        var closuresPayload = await sb_getOfficialClosuresJsonForEmployee(window.loggedInEmpId);
        if (closuresPayload && closuresPayload.ok === true && closuresPayload.closures_json != null) {
          var parsed = [];
          try {
            parsed = JSON.parse(closuresPayload.closures_json || '[]') || [];
          } catch (parseErr) {
            parsed = [];
          }
          appSettings.officialClosures = normalizeOfficialClosures(parsed);
          if (typeof saveData === 'function') saveData();
        }
      }
      if (typeof renderOfficialClosureEmpBanner === 'function' && typeof bindOfficialClosureAttendanceButtons === 'function') {
        var uiClosure = officialClosureForDate();
        renderOfficialClosureEmpBanner(uiClosure);
        bindOfficialClosureAttendanceButtons(uiClosure);
      }
    } catch (e) {
      console.warn('refreshOfficialClosuresFromCloud emp:', e);
    }
    if (typeof renderOfficialClosureEmpBanner === 'function' && typeof bindOfficialClosureAttendanceButtons === 'function') {
      var uiClosureFallback = officialClosureForDate();
      renderOfficialClosureEmpBanner(uiClosureFallback);
      bindOfficialClosureAttendanceButtons(uiClosureFallback);
    }
    return !!(appSettings.officialClosures && appSettings.officialClosures.length) || !!window.__empActiveOfficialClosure;
  }
  if (typeof sb_getSettings !== 'function' || typeof applyRemoteAppSettings !== 'function') return false;
  try {
    var settings = await sb_getSettings();
    if (!settings) return false;
    applyRemoteAppSettings(settings, { forceRemote: true });
    if (typeof saveData === 'function') saveData();
    return true;
  } catch (e) {
    console.warn('refreshOfficialClosuresFromCloud:', e);
    return false;
  }
}

function countOfficialClosureDaysBetween(fromIso, toIso, payType) {
  var from = parseIsoDateOnly(fromIso);
  var to = parseIsoDateOnly(toIso);
  if (!from || !to || new Date(to + 'T12:00:00') < new Date(from + 'T12:00:00')) return 0;
  var seen = {};
  normalizeOfficialClosures(appSettings.officialClosures || []).forEach(function (c) {
    if (payType && c.payType !== payType) return;
    var start = c.startDate > from ? c.startDate : from;
    var end = c.endDate < to ? c.endDate : to;
    if (end < start) return;
    for (var d = start; d <= end; d = addIsoDays(d, 1)) {
      seen[d] = true;
      if (d === end) break;
    }
  });
  return Object.keys(seen).length;
}

function renderOfficialClosuresList() {
  var wrap = document.getElementById('official-closures-list');
  if (!wrap) return;
  var closures = normalizeOfficialClosures(appSettings.officialClosures || []);
  appSettings.officialClosures = closures;
  if (!closures.length) {
    wrap.innerHTML = '<div class="settings-hint" style="padding:10px;border:1px dashed var(--border);border-radius:10px">لا توجد عطل رسمية محفوظة حالياً.</div>';
    return;
  }
  wrap.innerHTML = closures.map(function (c) {
    var paidText = c.payType === 'paid' ? 'براتب' : 'بدون راتب';
    var paidColor = c.payType === 'paid' ? '#68d391' : '#fc8181';
    return '<div style="display:flex;gap:8px;align-items:center;justify-content:space-between;padding:10px;margin-top:8px;border:1px solid var(--border);border-radius:10px;background:rgba(255,255,255,0.03)">' +
      '<div style="line-height:1.7"><b>' + esc(c.title) + '</b><div style="font-size:12px;color:var(--text-muted)">' + esc(c.startDate) + ' إلى ' + esc(c.endDate) + ' — ' + c.days + ' يوم — <span style="color:' + paidColor + ';font-weight:700">' + paidText + '</span></div></div>' +
      '<div style="display:flex;gap:6px;flex-wrap:wrap"><button type="button" class="btn-sm btn-primary" data-perm="settings.edit" onclick="openOfficialClosureForm(\'' + esc(c.id) + '\')"><i class="fa fa-edit"></i></button>' +
      '<button type="button" class="btn-sm btn-danger" data-perm="settings.edit" onclick="deleteOfficialClosure(\'' + esc(c.id) + '\')"><i class="fa fa-trash"></i></button></div>' +
      '</div>';
  }).join('');
  if (typeof applyPermissionUi === 'function') applyPermissionUi();
}

function clearAllSalaryPreviewCache() {
  if (window._salaryPreviewCache && typeof window._salaryPreviewCache.clear === 'function') window._salaryPreviewCache.clear();
  if (typeof clearSalaryCacheForEmployee === 'function') {
    (employees || []).forEach(function (e) { if (e && e.id) clearSalaryCacheForEmployee(e.id); });
  }
}

async function saveOfficialClosuresSettings(message) {
  appSettings.officialClosures = normalizeOfficialClosures(appSettings.officialClosures || []);
  window.__basmaOfficialClosuresLocalAt = Date.now();
  clearAllSalaryPreviewCache();
  logActivity('edit', 'settings', message || 'تعديل إعدادات تعطيل الروابط', { deferSave: true });
  pauseRemoteSync(45000);
  window.__basmaLocalSettingsAt = Date.now();
  var expectedCount = appSettings.officialClosures.length;
  var ok = false;
  if (typeof sb_saveOfficialClosuresJson === 'function') {
    ok = await sb_saveOfficialClosuresJson(appSettings.officialClosures);
  }
  if (!ok) {
    var cloud = await commitAppSettingsToCloud({ pauseMs: 45000, resumeMs: 15000 });
    ok = !!(cloud && cloud.ok);
  } else {
    resumeRemoteSync(15000);
  }
  if (ok && typeof sb_verifyOfficialClosuresJson === 'function') {
    ok = await sb_verifyOfficialClosuresJson(expectedCount);
  }
  saveData();
  renderOfficialClosuresList();
  buildSalaries();
  if (typeof buildPaidSalaries === 'function') buildPaidSalaries();
  return { ok: !!ok };
}

async function openOfficialClosureForm(id) {
  if (!requireActionPermission('settings', 'edit')) return;
  appSettings.officialClosures = normalizeOfficialClosures(appSettings.officialClosures || []);
  var current = (appSettings.officialClosures || []).find(function (c) { return c.id === id; }) || null;
  var today = typeof todayIsoDate === 'function' ? todayIsoDate() : new Date().toISOString().slice(0, 10);
  var html = '<div style="text-align:right;direction:rtl">' +
    '<label class="setting-label">اسم العطلة</label><input id="closure-title" class="swal2-input" style="width:100%;margin:6px 0" value="' + esc(current ? current.title : 'تعطيل رسمي') + '">' +
    '<label class="setting-label">تاريخ بداية التعطيل</label><input id="closure-start" type="date" class="swal2-input" style="width:100%;margin:6px 0" value="' + esc(current ? current.startDate : today) + '">' +
    '<label class="setting-label">عدد أيام التعطيل</label><input id="closure-days" type="number" min="1" max="60" step="1" class="swal2-input" style="width:100%;margin:6px 0" value="' + esc(current ? current.days : 1) + '">' +
    '<label class="setting-label">احتساب أيام العطلة</label><select id="closure-pay-type" class="swal2-select" style="width:100%;margin:6px 0"><option value="paid"' + (!current || current.payType === 'paid' ? ' selected' : '') + '>براتب - لا تخصم من الموظفين</option><option value="unpaid"' + (current && current.payType === 'unpaid' ? ' selected' : '') + '>بدون راتب - تخصم من الرواتب</option></select>' +
    '</div>';
  var res = await Swal.fire({
    title: current ? 'تعديل تعطيل الرابط' : 'تعطيل الرابط',
    html: html,
    showCancelButton: true,
    confirmButtonText: 'حفظ',
    cancelButtonText: 'إلغاء',
    focusConfirm: false,
    preConfirm: function () {
      var title = (document.getElementById('closure-title')?.value || '').trim() || 'تعطيل رسمي';
      var start = parseIsoDateOnly(document.getElementById('closure-start')?.value || '');
      var days = parseInt(document.getElementById('closure-days')?.value, 10);
      var payType = document.getElementById('closure-pay-type')?.value === 'unpaid' ? 'unpaid' : 'paid';
      if (!start) return Swal.showValidationMessage('اختر تاريخ بداية صحيح');
      if (!Number.isFinite(days) || days < 1 || days > 60) return Swal.showValidationMessage('عدد الأيام يجب أن يكون بين 1 و 60');
      return { id: current ? current.id : ('closure_' + Date.now()), title: title, startDate: start, endDate: addIsoDays(start, days - 1), days: days, payType: payType };
    },
    ...swalTheme()
  });
  if (!res.isConfirmed || !res.value) return;
  var next = appSettings.officialClosures.filter(function (c) { return c.id !== res.value.id; });
  next.push(res.value);
  appSettings.officialClosures = normalizeOfficialClosures(next);
  var cloud = await saveOfficialClosuresSettings((current ? 'تعديل' : 'إضافة') + ' تعطيل روابط: ' + res.value.title);
  Swal.fire({
    icon: cloud.ok ? 'success' : 'error',
    title: cloud.ok ? 'تم الحفظ في السحابة' : 'تعذّر الحفظ في السحابة',
    text: cloud.ok
      ? 'تم حفظ تعطيل الرابط — سيتم تطبيقه على جميع الموظفين.'
      : 'لم يُحفظ التعطيل في Supabase. أعد تسجيل الدخول كمسؤول ثم احفظ مرة أخرى.',
    timer: cloud.ok ? 2400 : undefined,
    showConfirmButton: !cloud.ok,
    ...swalTheme()
  });
}

async function deleteOfficialClosure(id) {
  if (!requireActionPermission('settings', 'edit')) return;
  var current = normalizeOfficialClosures(appSettings.officialClosures || []).find(function (c) { return c.id === id; });
  if (!current) return;
  var res = await Swal.fire({ icon: 'warning', title: 'حذف التعطيل؟', text: current.title, showCancelButton: true, confirmButtonText: 'حذف', cancelButtonText: 'إلغاء', ...swalTheme() });
  if (!res.isConfirmed) return;
  appSettings.officialClosures = normalizeOfficialClosures(appSettings.officialClosures || []).filter(function (c) { return c.id !== id; });
  var cloud = await saveOfficialClosuresSettings('حذف تعطيل روابط: ' + current.title);
  Swal.fire({
    icon: cloud.ok ? 'success' : 'error',
    title: cloud.ok ? 'تم الحذف من السحابة' : 'تعذّر الحذف من السحابة',
    timer: cloud.ok ? 1800 : undefined,
    showConfirmButton: !cloud.ok,
    ...swalTheme()
  });
}

function renderOfficialClosureEmpBanner(closure) {
  var box = document.getElementById('emp-closure-banner');
  if (!box) return;
  if (!closure) {
    box.style.display = 'none';
    box.innerHTML = '';
    return;
  }
  box.style.display = 'block';
  box.innerHTML = '<div style="padding:12px 14px;border-radius:12px;border:1px solid rgba(128,90,213,0.35);background:rgba(128,90,213,0.12);color:#e9d8fd;line-height:1.8">' +
    '<b>⛔ الموقع معطل حالياً — عطلة رسمية</b><br>' +
    'العطلة: <b>' + esc(closure.title) + '</b><br>' +
    'المدة: من ' + esc(closure.startDate) + ' إلى ' + esc(closure.endDate) + ' (' + esc(closure.days) + ' يوم)<br>' +
    '<span style="font-size:12px;opacity:0.9">لا يمكن تسجيل الحضور أو الانصراف خلال فترة التعطيل.</span>' +
    '</div>';
}

function bindOfficialClosureAttendanceButtons(closure) {
  document.querySelectorAll('.attendance-btns .att-btn').forEach(function (btn) {
    btn.disabled = false;
    btn.style.pointerEvents = '';
    btn.style.opacity = closure ? '0.85' : '';
    btn.title = closure ? 'الموقع معطل بسبب عطلة رسمية — مرّر لعرض التفاصيل' : '';
    // ملاحظة: تسجيل الحضور/الانصراف يتم عبر Slide-to-Confirm (slide-confirm.js)
    // الذي يستدعي checkIn()/checkOut() بعد التمرير الكامل + التأكيد؛ لذا لا نربط onclick مباشر
    // لمنع التسجيل بالخطأ عبر الضغط. checkIn/checkOut نفسها تتحقق من العطلة الرسمية داخلياً.
  });
}

function showOfficialClosureBlock(closure, actionText) {
  if (!closure) return false;
  Swal.fire({
    icon: 'info',
    title: 'الموقع معطل حالياً',
    html: 'السبب: <b>عطلة رسمية</b><br>العطلة: <b>' + esc(closure.title) + '</b><br>المدة: من ' + esc(closure.startDate) + ' إلى ' + esc(closure.endDate) + ' (' + esc(closure.days) + ' يوم)<br>لا يمكن ' + esc(actionText || 'استخدام موقع الموظف') + ' خلال فترة التعطيل.',
    ...swalTheme()
  });
  return true;
}


function repaintBatchProgressFrame() {
  return new Promise(function (resolve) { requestAnimationFrame(resolve); });
}

async function runWithBatchProgress(opts) {
  var total = Math.max(1, opts.total || 1);
  window.__basmaPreserveSwal = true;
  Swal.fire({
    html: batchProgressHtml(opts.title || 'جاري المعالجة...', opts.subtitle || ''),
    width: 440,
    padding: '1.75rem',
    ...swalTheme(),
    allowOutsideClick: false,
    allowEscapeKey: false,
    showConfirmButton: false,
    showCancelButton: false
  });
  await repaintBatchProgressFrame();
  var update = function (current, detail, sub) {
    setBatchProgress(current, total, detail, sub);
  };
  update(0, '0 / ' + total);
  try {
    return await opts.run(update);
  } finally {
    window.__basmaPreserveSwal = false;
    if (Swal.isVisible()) Swal.close();
    await repaintBatchProgressFrame();
  }
}

function setTheme(theme, opts) {
  opts = opts || {};
  const t = theme === 'light' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', t);
  document.getElementById('theme-btn-dark')?.classList.toggle('active', t === 'dark');
  document.getElementById('theme-btn-light')?.classList.toggle('active', t === 'light');
  document.getElementById('sa-theme-btn-dark')?.classList.toggle('active', t === 'dark');
  document.getElementById('sa-theme-btn-light')?.classList.toggle('active', t === 'light');
  Object.values(window.charts).forEach(c => { try { c.destroy(); } catch (e) {} });
  window.charts = {};
  const active = document.querySelector('.page.active');
  if (active?.id === 'page-reports') setTimeout(buildReportCharts, 80);
  if (active?.id === 'page-dashboard') setTimeout(buildDashboard, 80);
  if (!opts.skipCloud && typeof persistUiThemeToCloud === 'function') {
    persistUiThemeToCloud(t).catch(function (e) { console.warn('persistUiThemeToCloud:', e); });
  }
}
function initTheme() { setTheme('dark', { skipCloud: true }); }

async function persistUiThemeToCloud(theme) {
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    await AuthApi.ensureValidSession();
  }
  var isSuper = saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (isSuper && typeof sb_saveSuperAdminPrefs === 'function') {
    return sb_saveSuperAdminPrefs({ ui_theme: theme });
  }
  if (currentUser === 'admin' && typeof sb_saveSettings === 'function') {
    return sb_saveSettings({ ui_theme: theme });
  }
  return false;
}

async function loadUserUiPreferences() {
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    await AuthApi.ensureValidSession();
  }
  var theme = null;
  var isSuper = saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (isSuper && typeof sb_getSuperAdminPrefs === 'function') {
    var prefs = await sb_getSuperAdminPrefs();
    if (prefs) {
      if (prefs.ui_theme === 'light' || prefs.ui_theme === 'dark') theme = prefs.ui_theme;
      if (prefs.activity_log && typeof mergeActivityLogRemote === 'function') {
        ensureNotifStores();
        try {
          var remoteLog = prefs.activity_log;
          if (typeof remoteLog === 'string') remoteLog = JSON.parse(remoteLog);
          appSettings.activityLog = mergeActivityLogRemote(
            appSettings.activityLog,
            Array.isArray(remoteLog) ? remoteLog : []
          );
          if (typeof saveData === 'function') saveData();
        } catch (e) {}
      }
    }
  } else if (currentUser === 'admin' && typeof sb_getSettings === 'function') {
    var remote = await sb_getSettings();
    if (remote && (remote.ui_theme === 'light' || remote.ui_theme === 'dark')) {
      theme = remote.ui_theme;
    }
  }
  if (theme) setTheme(theme, { skipCloud: true });
}

function updatePendingSyncBadge() {
  if (typeof BasmaLeaveGuard !== 'undefined' && BasmaLeaveGuard.updateSyncStatusUi) {
    BasmaLeaveGuard.updateSyncStatusUi();
    return;
  }
  var badge = document.getElementById('pending-sync-badge');
  var countEl = document.getElementById('pending-sync-count');
  if (!badge || !countEl) return;
  var n = 0;
  (employees || []).forEach(function (e) { if (e && e._pendingRemoteSync) n++; });
  (attData || []).forEach(function (a) { if (a && a._pendingRemoteSync) n++; });
  (window.leavesData || []).forEach(function (l) { if (l && l._pendingSync) n++; });
  badge.style.display = n > 0 ? '' : 'none';
  countEl.textContent = String(n);
}
window.updatePendingSyncBadge = updatePendingSyncBadge;

function syncSettingsUi() {
  // Company settings
  const cn = document.getElementById('set-company-name');
  const cu = document.getElementById('set-currency');
  const tz = document.getElementById('set-timezone');
  if (cn) cn.value = appSettings.companyName || '';
  if (cu) cu.value = appSettings.currency || '';
  if (tz) tz.value = appSettings.timezone || '';
  var md = document.getElementById('set-month-days');
  if (md) md.value = getStandardMonthDays();
  var cf = document.getElementById('set-clock-format');
  if (cf) cf.value = (appSettings.clockFormat === '24') ? '24' : '12';
  var syncRow = document.getElementById('set-last-sync-row');
  var syncAt = document.getElementById('set-last-sync-at');
  if (syncAt) {
    if (appSettings.lastSyncedAt) {
      syncAt.textContent = formatNotifDateTime(appSettings.lastSyncedAt).full;
    } else {
      syncAt.textContent = '—';
    }
  }
  var verEl = document.getElementById('set-app-version');
  var prodEl = document.getElementById('set-app-product');
  if (verEl && typeof BasmaApp !== 'undefined') verEl.textContent = BasmaApp.versionLabel;
  if (prodEl && typeof BasmaApp !== 'undefined') prodEl.textContent = BasmaApp.product;
  if (typeof BasmaLeaveGuard !== 'undefined' && BasmaLeaveGuard.updateSyncStatusUi) {
    BasmaLeaveGuard.updateSyncStatusUi();
  }
  renderOfficialClosuresList();
  if (typeof renderBroadcastNoticesList === 'function') renderBroadcastNoticesList();

  // GPS settings
  const gl = document.getElementById('set-gps-lat');
  const gg = document.getElementById('set-gps-lng');
  const gr = document.getElementById('set-gps-range');
  const gn = document.getElementById('set-gps-name');
  if (gn) gn.value = appSettings.gpsName || '';
  if (gl) gl.value = appSettings.gpsLat || '';
  if (gg) gg.value = appSettings.gpsLng || '';
  if (gr) gr.value = appSettings.gpsRange || 100;
  previewGpsMap();

  // Security toggles
  const td = document.getElementById('toggle-track-devices');
  const ip = document.getElementById('toggle-ip-restrict');
  const sa = document.getElementById('toggle-security-alerts');
  const ab = document.getElementById('toggle-auto-backup');
  if (td) td.checked = appSettings.trackDevices !== false;
  if (ip) ip.checked = appSettings.ipRestrict !== false;
  if (sa) sa.checked = appSettings.securityAlerts !== false;
  if (ab) ab.checked = appSettings.autoBackup !== false;

  var maintCard = document.getElementById('data-maintenance-card');
  if (maintCard) {
    var isSuperMaint = saasCurrentUser && saasCurrentUser.role === 'super_admin';
    var isCompanyMaint = saasCurrentUser && saasCurrentUser.company_id && !isSuperMaint;
    maintCard.style.display = isCompanyMaint ? '' : 'none';
  }

  var sbCard = document.getElementById('supabase-card');
  if (sbCard) {
    var isSuper = saasCurrentUser && saasCurrentUser.role === 'super_admin';
    var isCompanyTenant = saasCurrentUser && saasCurrentUser.company_id && !isSuper;
    sbCard.style.display = isCompanyTenant ? '' : 'none';
    var sbHint = sbCard.querySelector('[data-sb-tenant-hint]');
    if (sbHint && isCompanyTenant) {
      sbHint.textContent = 'المزامنة معزّولة لشركة: ' + (saasCurrentUser.company_name || ('#' + saasCurrentUser.company_id));
    }
  }
}

function saveCompanySettings() {
  if (!requireActionPermission('settings', 'edit')) return;
  const cn = document.getElementById('set-company-name').value.trim();
  const cu = document.getElementById('set-currency').value.trim();
  const tz = document.getElementById('set-timezone').value.trim();
  const mdRaw = parseInt(document.getElementById('set-month-days')?.value, 10);
  const md = clampMonthDays(mdRaw);
  if (!cn) { Swal.fire({ icon: 'warning', title: 'مطلوب', text: 'اسم الشركة مطلوب', ...swalTheme() }); return; }
  if (!Number.isFinite(mdRaw) || mdRaw < 20 || mdRaw > 31) {
    Swal.fire({ icon: 'warning', title: 'قيمة غير صالحة', text: 'أيام الشهر المعتمدة يجب أن تكون بين 20 و 31', ...swalTheme() });
    return;
  }
  var prevMonthDays = getStandardMonthDays();
  var prevClock = appSettings.clockFormat === '24' ? '24' : '12';
  var newClock = (document.getElementById('set-clock-format')?.value === '24') ? '24' : '12';
  appSettings.companyName = cn;
  appSettings.currency = cu;
  appSettings.timezone = tz;
  appSettings.monthDays = md;
  if (newClock !== prevClock) {
    appSettings.clockFormat = newClock;
    if (typeof BasmaTime !== 'undefined' && BasmaTime.migrateAllTimesToClockFormat) {
      BasmaTime.migrateAllTimesToClockFormat(newClock);
    }
    refreshAll();
  } else {
    appSettings.clockFormat = newClock;
  }
  if (prevMonthDays !== md && typeof recalcEmployeeDailyRatesFromSettings === 'function') {
    recalcEmployeeDailyRatesFromSettings();
    if (typeof clearSalaryCacheForEmployee === 'function') {
      (employees || []).forEach(function (e) { if (e && e.id) clearSalaryCacheForEmployee(e.id); });
    }
  }
  logActivity('edit', 'settings', 'تعديل إعدادات الشركة: ' + cn + (prevMonthDays !== md ? (' — أيام الشهر: ' + md) : ''), { deferSave: true });
  commitAppSettingsToCloud().then(function (cloud) {
    if (cloud.ok) {
      Swal.fire({ icon: 'success', title: 'تم الحفظ', text: 'تم حفظ إعدادات الشركة في السحابة', ...swalTheme(), timer: 2000, showConfirmButton: false });
    } else {
      Swal.fire({ icon: 'error', title: 'لم يتم الحفظ', html: 'تعذّر حفظ الإعدادات في السحابة.<br><b>تحقق من الإنترنت أو أعد تسجيل الدخول</b> ثم حاول مرة أخرى.', ...swalTheme() });
    }
  });
}

function isValidCoord(lat, lng) {
  const la = Number(lat);
  const ln = Number(lng);
  return Number.isFinite(la) && Number.isFinite(ln) && la >= -90 && la <= 90 && ln >= -180 && ln <= 180;
}

var _gpsMap = null;
var _gpsMarker = null;
var _gpsCircle = null;
var _gpsPreviewTimer = null;
var _gpsLastPreviewKey = '';
var _gpsUpdatingInputsFromMap = false;

function readGpsFormValues() {
  return {
    lat: (document.getElementById('set-gps-lat')?.value || appSettings.gpsLat || '33.3152').trim(),
    lng: (document.getElementById('set-gps-lng')?.value || appSettings.gpsLng || '44.3661').trim(),
    range: parseInt(document.getElementById('set-gps-range')?.value, 10) || appSettings.gpsRange || 100,
    name: (document.getElementById('set-gps-name')?.value || appSettings.gpsName || 'موقع الشركة').trim() || 'موقع الشركة'
  };
}

function setGpsInputs(lat, lng, range) {
  var latEl = document.getElementById('set-gps-lat');
  var lngEl = document.getElementById('set-gps-lng');
  var rangeEl = document.getElementById('set-gps-range');
  _gpsUpdatingInputsFromMap = true;
  if (latEl && Number.isFinite(Number(lat))) latEl.value = Number(lat).toFixed(6);
  if (lngEl && Number.isFinite(Number(lng))) lngEl.value = Number(lng).toFixed(6);
  if (rangeEl && range != null) rangeEl.value = String(Math.max(10, Math.min(5000, parseInt(range, 10) || 100)));
  _gpsUpdatingInputsFromMap = false;
}

function updateGpsMapLabel(lat, lng, range, name) {
  var label = document.getElementById('gps-map-label');
  var coords = document.getElementById('gps-map-coords');
  if (label) label.textContent = (name || 'موقع الشركة') + ' - نطاق ' + range + 'م';
  if (coords) coords.textContent = Number(lat).toFixed(6) + ', ' + Number(lng).toFixed(6);
}

function fallbackGpsIframe(lat, lng, range, name) {
  var frame = document.getElementById('gps-map-frame');
  if (!frame) return;
  var la = Number(lat);
  var ln = Number(lng);
  var delta = Math.max(0.001, Math.min(0.03, range / 111000 * 3));
  var nextSrc = 'https://www.openstreetmap.org/export/embed.html?bbox=' +
    encodeURIComponent((ln - delta) + ',' + (la - delta) + ',' + (ln + delta) + ',' + (la + delta)) +
    '&layer=mapnik&marker=' + encodeURIComponent(la + ',' + ln);
  if (frame.src !== nextSrc) frame.src = nextSrc;
  frame.style.display = 'block';
  updateGpsMapLabel(la, ln, range, name);
}

function ensureGpsLeafletMap(lat, lng, range, name) {
  var mapEl = document.getElementById('gps-leaflet-map');
  if (!mapEl || typeof L === 'undefined' || !L.map) return false;
  var la = Number(lat);
  var ln = Number(lng);
  if (!_gpsMap) {
    _gpsMap = L.map(mapEl, {
      center: [la, ln],
      zoom: 17,
      scrollWheelZoom: true
    });
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; OpenStreetMap'
    }).addTo(_gpsMap);
    _gpsMarker = L.marker([la, ln], { draggable: true }).addTo(_gpsMap);
    _gpsCircle = L.circle([la, ln], {
      radius: range,
      color: '#00d4aa',
      weight: 2,
      fillColor: '#00d4aa',
      fillOpacity: 0.12
    }).addTo(_gpsMap);
    _gpsMarker.on('dragend', function () {
      var p = _gpsMarker.getLatLng();
      var values = readGpsFormValues();
      setGpsInputs(p.lat, p.lng, values.range);
      previewGpsMap({ source: 'marker', force: true });
    });
    _gpsMap.on('click', function (evt) {
      if (!evt || !evt.latlng) return;
      var values = readGpsFormValues();
      setGpsInputs(evt.latlng.lat, evt.latlng.lng, values.range);
      previewGpsMap({ source: 'map', force: true });
    });
    setTimeout(function () { try { _gpsMap.invalidateSize(); } catch (e) {} }, 80);
  }
  _gpsMarker.setLatLng([la, ln]);
  _gpsCircle.setLatLng([la, ln]);
  _gpsCircle.setRadius(range);
  _gpsMap.setView([la, ln], Math.max(_gpsMap.getZoom() || 17, 16), { animate: false });
  updateGpsMapLabel(la, ln, range, name);
  return true;
}

function scheduleGpsMapPreview(source) {
  if (_gpsUpdatingInputsFromMap) return;
  clearTimeout(_gpsPreviewTimer);
  _gpsPreviewTimer = setTimeout(function () {
    previewGpsMap({ source: source || 'manual' });
  }, source === 'manual' ? 550 : 80);
}

function previewGpsMap(options) {
  options = options || {};
  const values = readGpsFormValues();
  const lat = values.lat;
  const lng = values.lng;
  const range = Math.max(10, Math.min(5000, values.range));
  const name = values.name;
  if (!isValidCoord(lat, lng)) {
    updateGpsMapLabel(appSettings.gpsLat || 33.3152, appSettings.gpsLng || 44.3661, range, 'إحداثيات غير صحيحة');
    return false;
  }
  const la = Number(lat);
  const ln = Number(lng);
  const key = la.toFixed(6) + '|' + ln.toFixed(6) + '|' + range + '|' + name;
  if (!options.force && key === _gpsLastPreviewKey) return true;
  _gpsLastPreviewKey = key;
  var showMap = function () {
    if (!ensureGpsLeafletMap(la, ln, range, name)) {
      fallbackGpsIframe(la, ln, range, name);
    }
  };
  if (typeof ensureLeafletLoaded === 'function') {
    ensureLeafletLoaded().then(showMap).catch(function () {
      fallbackGpsIframe(la, ln, range, name);
    });
  } else {
    showMap();
  }
  return true;
}

function useMyLocationForCompany() {
  if (!navigator.geolocation) {
    Swal.fire({ icon:'error', title:'الموقع غير مدعوم', text:'المتصفح لا يدعم تحديد الموقع الجغرافي', ...swalTheme() });
    return;
  }
  Swal.fire({ title:'جارٍ تحديد موقعك...', text:'اسمح للمتصفح باستخدام الموقع لتثبيت موقع الشركة', allowOutsideClick:false, didOpen:()=>Swal.showLoading(), ...swalTheme() });
  navigator.geolocation.getCurrentPosition(pos => {
    const lat = pos.coords.latitude.toFixed(6);
    const lng = pos.coords.longitude.toFixed(6);
    const acc = Math.round(pos.coords.accuracy || 0);
    const latEl = document.getElementById('set-gps-lat');
    const lngEl = document.getElementById('set-gps-lng');
    const rangeEl = document.getElementById('set-gps-range');
    if (latEl) latEl.value = lat;
    if (lngEl) lngEl.value = lng;
    if (rangeEl && acc > 0) rangeEl.value = Math.max(parseInt(rangeEl.value, 10) || 100, Math.min(1000, acc + 100));
    previewGpsMap({ source: 'location', force: true });
    Swal.fire({ icon:'success', title:'تم تحديد الموقع', html:'الإحداثيات:<br><b dir="ltr">' + lat + ', ' + lng + '</b><br>دقة الجهاز تقريباً: ' + acc + ' متر', ...swalTheme() });
  }, err => {
    Swal.fire({ icon:'error', title:'تعذر تحديد الموقع', text: err.message || 'تحقق من صلاحيات الموقع في المتصفح', ...swalTheme() });
  }, { enableHighAccuracy:true, timeout:15000, maximumAge:0 });
}

function openCompanyLocationMap() {
  const lat = document.getElementById('set-gps-lat')?.value || appSettings.gpsLat;
  const lng = document.getElementById('set-gps-lng')?.value || appSettings.gpsLng;
  if (!isValidCoord(lat, lng)) { Swal.fire({ icon:'warning', title:'إحداثيات غير صحيحة', ...swalTheme() }); return; }
  window.open('https://www.openstreetmap.org/?mlat=' + encodeURIComponent(lat) + '&mlon=' + encodeURIComponent(lng) + '#map=18/' + encodeURIComponent(lat) + '/' + encodeURIComponent(lng), '_blank');
}

function copyCompanyCoords() {
  const lat = document.getElementById('set-gps-lat')?.value || appSettings.gpsLat;
  const lng = document.getElementById('set-gps-lng')?.value || appSettings.gpsLng;
  const text = lat + ', ' + lng;
  navigator.clipboard?.writeText(text).then(() => {
    Swal.fire({ icon:'success', title:'تم النسخ', text:text, ...swalTheme(), timer:1300, showConfirmButton:false });
  }).catch(() => Swal.fire({ icon:'info', title:'الإحداثيات', text:text, ...swalTheme() }));
}

function enableSecuritySuite() {
  appSettings.trackDevices = true;
  appSettings.ipRestrict = true;
  appSettings.securityAlerts = true;
  appSettings.autoBackup = true;
  syncSettingsUi();
  logActivity('edit', 'settings', 'تفعيل الحماية الكاملة: تتبع الأجهزة، تقييد IP، إشعارات أمنية، نسخ احتياطي', { deferSave: true });
  commitAppSettingsToCloud({ pauseMs: 15000, resumeMs: 8000 }).then(function () {
  Swal.fire({ icon:'success', title:'تم تفعيل الحماية الكاملة', text:'تم تفعيل تتبع الأجهزة، تقييد الدخول، الإشعارات الأمنية، والنسخ الاحتياطي التلقائي', ...swalTheme(), timer:2200, showConfirmButton:false });
  });
}

function saveGpsSettings() {
  if (!requireActionPermission('settings', 'edit')) return;
  const name = document.getElementById('set-gps-name')?.value.trim() || 'موقع الشركة الرئيسي';
  const lat = document.getElementById('set-gps-lat').value.trim();
  const lng = document.getElementById('set-gps-lng').value.trim();
  const range = parseInt(document.getElementById('set-gps-range').value, 10) || 100;
  if (!lat || !lng) { Swal.fire({ icon: 'warning', title: 'مطلوب', text: 'إحداثيات الموقع مطلوبة', ...swalTheme() }); return; }
  if (!isValidCoord(lat, lng)) { Swal.fire({ icon: 'error', title: 'إحداثيات غير صحيحة', text: 'تأكد من خط العرض والطول', ...swalTheme() }); return; }
  var latFixed = Number(lat).toFixed(6);
  var lngFixed = Number(lng).toFixed(6);
  var safeRange = Math.max(10, Math.min(5000, range));
  setGpsInputs(latFixed, lngFixed, safeRange);
  previewGpsMap({ source: 'save', force: true });
  appSettings.gpsName = name;
  appSettings.gpsLat = latFixed;
  appSettings.gpsLng = lngFixed;
  appSettings.gpsRange = safeRange;
  logActivity('edit', 'settings', 'تعديل إعدادات GPS: ' + name, { deferSave: true });
  commitAppSettingsToCloud().then(function (cloud) {
    if (cloud.ok) {
      Swal.fire({ icon: 'success', title: 'تم الحفظ', text: 'تم حفظ موقع الشركة في السحابة — نطاق: ' + appSettings.gpsRange + ' م', ...swalTheme(), timer: 2200, showConfirmButton: false });
    } else {
      Swal.fire({ icon: 'error', title: 'لم يتم الحفظ', html: 'تعذّر حفظ موقع الشركة في السحابة.<br>تحقق من الإنترنت أو أعد تسجيل الدخول ثم حاول مرة أخرى.', ...swalTheme() });
    }
  });
}

function exportBackup() {
  var cid = typeof resolveActiveCompanyId === 'function' ? resolveActiveCompanyId() : null;
  if (typeof sb_exportCompanyData === 'function') {
    Swal.fire({ title: '⏳ جارٍ التصدير...', allowOutsideClick: false, didOpen: function () { Swal.showLoading(); }, ...swalTheme() });
    sb_exportCompanyData().then(function (cloud) {
      if (cloud && cloud.ok) {
        var blob = new Blob([JSON.stringify(cloud, null, 2)], { type: 'application/json' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = 'kyno_company_' + (cid || 'export') + '_' + new Date().toISOString().slice(0, 10) + '.json';
        a.click();
        URL.revokeObjectURL(url);
        logActivity('backup', 'backup', 'تصدير نسخة سحابية للشركة');
        Swal.fire({ icon: 'success', title: 'تم التصدير', text: 'تم تصدير بيانات الشركة من السيرفر', ...swalTheme(), timer: 2500, showConfirmButton: false });
        return;
      }
      exportBackupLocal();
    }).catch(function () { exportBackupLocal(); });
    return;
  }
  exportBackupLocal();
}

function exportBackupLocal() {
  var cid = typeof resolveActiveCompanyId === 'function' ? resolveActiveCompanyId() : null;
  const data = {
    company_id: cid,
    employees, attData, leavesData: window.leavesData || [], nextEmpId, appSettings,
    exportDate: new Date().toISOString(),
    version: (typeof BasmaApp !== 'undefined' && BasmaApp.version) ? BasmaApp.version : '1.0.0',
    exportType: 'local'
  };
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'backup_' + (appSettings.companyName || 'company').replace(/\s+/g, '_') + '_' + new Date().toISOString().slice(0,10) + '.json';
  a.click();
  URL.revokeObjectURL(url);
  logActivity('backup', 'backup', 'تصدير نسخة احتياطية محلية');
  Swal.fire({ icon: 'success', title: 'تم التصدير', text: 'تم تحميل النسخة الاحتياطية المحلية', ...swalTheme(), timer: 2000, showConfirmButton: false });
}

function importBackup() {
  document.getElementById('backup-file-input').click();
}

function handleBackupFile(event) {
  const file = event.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = function(e) {
    try {
      const data = JSON.parse(e.target.result);
      var cid = typeof resolveActiveCompanyId === 'function' ? resolveActiveCompanyId() : null;
      if (data.company_id && cid && parseInt(data.company_id, 10) !== parseInt(cid, 10)) {
        Swal.fire({ icon: 'error', title: 'شركة مختلفة', text: 'ملف النسخة الاحتياطية يخص شركة أخرى — لا يمكن الاستيراد.', ...swalTheme() });
        return;
      }
      if (data.ok && data.settings && typeof sb_importCompanySettings === 'function') {
        var isFullExport = data.version === '057' || (Array.isArray(data.employees) && Array.isArray(data.attendance));
        Swal.fire({
          title: isFullExport ? 'استيراد نسخة الشركة الكاملة' : 'استيراد إعدادات الشركة',
          html: (isFullExport
            ? 'سيتم استيراد الموظفين والحضور والرواتب والإجازات والإعدادات.<br>'
            : 'سيتم استيراد إعدادات الشركة من ملف السحابة (بدون استبدال الموظفين).<br>') +
            '<b>تاريخ:</b> ' + esc(data.exported_at || data.exportDate || '—'),
          icon: 'warning', showCancelButton: true,
          confirmButtonText: 'نعم، استيراد', cancelButtonText: 'إلغاء',
          ...swalTheme(), confirmButtonColor: '#dd6b20'
        }).then(function (r) {
          if (!r.isConfirmed) return;
          var importFn = (isFullExport && typeof sb_importCompanyFull === 'function')
            ? sb_importCompanyFull : sb_importCompanySettings;
          importFn(data).then(function (res) {
            if (res && res.ok) {
              if (typeof syncFromSupabase === 'function') syncFromSupabase({ forceRemote: true });
              logActivity('import', 'backup', isFullExport ? 'استيراد نسخة شركة كاملة' : 'استيراد إعدادات شركة من سحابة');
              var msg = isFullExport && res.imported
                ? 'تم — موظفين: ' + (res.imported.employees || 0) + '، حضور: ' + (res.imported.attendance || 0)
                : 'تم استيراد ' + (res.imported_keys || (res.imported && res.imported.settings) || 0) + ' إعداد';
              Swal.fire({ icon: 'success', title: 'تم الاستيراد', text: msg, ...swalTheme(), timer: 2200, showConfirmButton: false });
            } else {
              Swal.fire({ icon: 'error', title: 'فشل الاستيراد', text: (res && res.error) || 'تعذّر الاستيراد', ...swalTheme() });
            }
          });
        });
        return;
      }
      if (!data.employees || !data.attData) {
        Swal.fire({ icon: 'error', title: 'ملف غير صالح', text: 'الملف لا يحتوي على بيانات صحيحة', ...swalTheme() });
        return;
      }
      Swal.fire({
        title: 'استعادة النسخة الاحتياطية',
        html: 'سيتم استبدال جميع البيانات الحالية بالنسخة الاحتياطية<br><b>تاريخ النسخة:</b> ' + (data.exportDate || 'غير معروف'),
        icon: 'warning', showCancelButton: true,
        confirmButtonText: 'نعم، استعادة', cancelButtonText: 'إلغاء',
        ...swalTheme(), confirmButtonColor: '#dd6b20'
      }).then(r => {
        if (!r.isConfirmed) return;
        employees = data.employees;
        attData = data.attData;
        nextEmpId = data.nextEmpId || Math.max(0, ...employees.map(e => e.id)) + 1;
        if (data.appSettings) Object.assign(appSettings, data.appSettings);
        if (!appSettings.salaryDeletedMap || typeof appSettings.salaryDeletedMap !== 'object') appSettings.salaryDeletedMap = {};
        if (!Array.isArray(appSettings.financeItems)) appSettings.financeItems = [];
        if (!Array.isArray(appSettings.activityLog)) appSettings.activityLog = [];
        if (!Array.isArray(appSettings.employeeNotifications)) appSettings.employeeNotifications = [];
        ensureOrgLists();
        saveData();
        refreshAll();
        syncSettingsUi();
        logActivity('import', 'backup', 'استعادة نسخة احتياطية — ' + (data.exportDate || 'بدون تاريخ'));
        Swal.fire({ icon: 'success', title: 'تمت الاستعادة', text: 'تم استعادة النسخة الاحتياطية بنجاح', ...swalTheme(), timer: 2000, showConfirmButton: false });
      });
    } catch (err) {
      Swal.fire({ icon: 'error', title: 'خطأ في الملف', text: 'تعذر قراءة الملف — تأكد من أنه ملف JSON صالح', ...swalTheme() });
    }
  };
  reader.readAsText(file);
  event.target.value = '';
}

function resetAllData() {
  Swal.fire({
    title: '⚠️ مسح البيانات',
    html: `<div style="text-align:right;font-size:14px;line-height:2">
      <div style="margin-bottom:12px;color:#fc8181;font-weight:700">اختر نوع البيانات التي تريد مسحها:</div>
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:8px">
        <input type="checkbox" id="reset-att" style="width:16px;height:16px;accent-color:#fc8181" checked>
        <span>🗓️ سجلات الحضور والانصراف</span>
      </label>
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:8px">
        <input type="checkbox" id="reset-emp" style="width:16px;height:16px;accent-color:#fc8181">
        <span>👥 بيانات الموظفين</span>
      </label>
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:8px">
        <input type="checkbox" id="reset-sal" style="width:16px;height:16px;accent-color:#fc8181">
        <span>💰 حالات الرواتب والمكافآت</span>
      </label>
      <div style="font-size:12px;color:rgba(232,244,253,0.5);margin-top:8px;border-top:1px solid rgba(255,255,255,0.08);padding-top:8px">
        ⚙️ الإعدادات (اسم الشركة، الأوقات، GPS) لن تُمسح
      </div>
      <div style="color:#fc8181;font-size:12px;margin-top:6px">هذا الإجراء <b>لا يمكن التراجع عنه</b></div>
    </div>`,
    icon: 'warning', showCancelButton: true,
    confirmButtonText: 'مسح المحدد', cancelButtonText: 'إلغاء',
    ...swalTheme(), confirmButtonColor: '#e53e3e',
    preConfirm: () => {
      return {
        att: document.getElementById('reset-att')?.checked || false,
        emp: document.getElementById('reset-emp')?.checked || false,
        sal: document.getElementById('reset-sal')?.checked || false
      };
    }
  }).then(r => {
    if (!r.isConfirmed || !r.value) return;
    const { att, emp, sal } = r.value;
    if (!att && !emp && !sal) {
      Swal.fire({ icon: 'info', title: 'لم يتم اختيار أي بيانات', ...swalTheme(), timer: 1500, showConfirmButton: false });
      return;
    }
    let messages = [];
    if (att) {
      attData = [];
      messages.push('سجلات الحضور');
    }
    if (emp) {
      employees = [];
      nextEmpId = 1;
      attData = []; // Clear attendance too when employees are cleared
      messages.push('بيانات الموظفين');
    }
    if (sal) {
      employees.forEach(e => { e.salStatus = 'معلق'; e.salBonus = 0; });
      messages.push('حالات الرواتب');
    }
    saveData();
    refreshAll();
    syncSettingsUi();
    logActivity('reset', 'system', 'مسح بيانات: ' + messages.join('، '));
    Swal.fire({
      icon: 'success',
      title: 'تم المسح',
      text: 'تم مسح: ' + messages.join('، '),
      ...swalTheme(), timer: 2500, showConfirmButton: false
    });
  });
}

/* ===== Device Fingerprint System ===== */
const DEVICE_FP_KEY = 'basma_device_fp';

function randomDeviceFingerprint() {
  var bytes = new Uint8Array(18);
  if (window.crypto && window.crypto.getRandomValues) {
    window.crypto.getRandomValues(bytes);
  } else {
    for (var i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  var chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var out = 'DEVU-';
  bytes.forEach(function (b) { out += chars[b % chars.length]; });
  return out;
}

function legacyDeviceFingerprint() {
  var raw = [
    navigator.userAgent || '',
    navigator.platform || '',
    navigator.language || '',
    (Intl.DateTimeFormat().resolvedOptions().timeZone || ''),
    (screen && screen.width && screen.height ? (screen.width + 'x' + screen.height + 'x' + (screen.colorDepth || '')) : '')
  ].join('|');
  var hash = 0;
  for (var i = 0; i < raw.length; i++) {
    hash = ((hash << 5) - hash) + raw.charCodeAt(i);
    hash |= 0;
  }
  return 'DEV-' + Math.abs(hash).toString(36).toUpperCase();
}

function getDeviceFingerprint() {
  if (window.__basmaDeviceFp) return window.__basmaDeviceFp;
  try {
    var stored = localStorage.getItem(DEVICE_FP_KEY);
    if (stored && /^DEVU-[0-9A-Z]{12,}$/i.test(stored)) {
      window.__basmaDeviceFp = stored.toUpperCase();
      return window.__basmaDeviceFp;
    }
    if (stored && /^DEV-[0-9A-Z]{4,}$/i.test(stored)) {
      window.__basmaDeviceFp = stored.toUpperCase();
      return window.__basmaDeviceFp;
    }
  } catch (e) { /* ignore */ }

  // جلسات الموظفين القديمة تبقى على البصمة القديمة حتى لا ينقطع دخولهم بعد التحديث.
  if (typeof hasActiveEmployeeSession === 'function' && hasActiveEmployeeSession()) {
    window.__basmaDeviceFp = legacyDeviceFingerprint();
    try { localStorage.setItem(DEVICE_FP_KEY, window.__basmaDeviceFp); } catch (e3) { /* ignore */ }
    return window.__basmaDeviceFp;
  }

  window.__basmaDeviceFp = randomDeviceFingerprint();
  try { localStorage.setItem(DEVICE_FP_KEY, window.__basmaDeviceFp); } catch (e2) { /* ignore */ }
  return window.__basmaDeviceFp;
}

function withClientTimeout(promise, ms, label) {
  var timeoutMs = Math.max(1000, parseInt(ms, 10) || 12000);
  return Promise.race([
    promise,
    new Promise(function (_, reject) {
      setTimeout(function () {
        reject(new Error((label || 'operation') + '_timeout'));
      }, timeoutMs);
    })
  ]);
}

function generatePin() {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

function genBarcode(empId, slot) { return 'ATT-' + empId + '-D' + slot; }

function generateDeviceToken() {
  const bytes = new Uint8Array(16);
  if (window.crypto && window.crypto.getRandomValues) {
    window.crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let out = 'REG_';
  bytes.forEach(b => { out += chars[b % chars.length]; });
  return out;
}

function isTokenUsed(token, currentEmpId, currentSlot) {
  var list = window.employees || [];
  return list.some(emp => (emp.devices || []).some(dev =>
    dev.token === token && (emp.id !== currentEmpId || dev.slot !== currentSlot)
  ));
}

function ensureDeviceToken(emp, dev) {
  if (!emp || !dev) return '';
  if (!dev.token || !/^REG_[A-Za-z0-9]{10,}$/.test(dev.token)) {
    dev.token = generateDeviceToken();
    dev.tokenCreatedAt = new Date().toISOString();
    dev.tokenUsedAt = '';
  }
  if (!dev.tokenCreatedAt) dev.tokenCreatedAt = new Date().toISOString();
  return dev.token;
}

function deduplicateAllDeviceTokens() {
  var seen = {};
  var changed = false;
  (employees || []).forEach(function (emp) {
    if (!emp || !emp.id) return;
    (emp.devices || []).forEach(function (dev) {
      if (!dev) return;
      if (!dev.token || !/^REG_[A-Za-z0-9]{10,}$/.test(dev.token)) {
        dev.token = generateDeviceToken();
        dev.tokenCreatedAt = new Date().toISOString();
        dev.tokenUsedAt = '';
        changed = true;
      }
      var key = dev.token;
      if (seen[key]) {
        dev.token = generateDeviceToken();
        dev.tokenCreatedAt = new Date().toISOString();
        dev.tokenUsedAt = '';
        seen[dev.token] = emp.id + ':' + dev.slot;
        changed = true;
      } else {
        seen[key] = emp.id + ':' + dev.slot;
      }
    });
  });
  if (changed && typeof saveData === 'function') saveData();
  return changed;
}

function getDeviceInfo() {
  return {
    userAgent: navigator.userAgent || '',
    platform: navigator.platform || '',
    language: navigator.language || '',
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || '',
    screen: (screen && screen.width && screen.height) ? (screen.width + 'x' + screen.height) : ''
  };
}

function getRegistrationUrl(token, legacyCode) {
  var base = window.location.href.split('#')[0].split('?')[0];
  var url = base + '?token=' + encodeURIComponent(token);
  // استخدم code وليس reg — &reg في HTML يتحول إلى ® ويفسد الرابط عند النسخ
  if (legacyCode) url += '&code=' + encodeURIComponent(legacyCode);
  return url;
}

/** إصلاح روابط التسجيل التالفة (&reg → ® عند العرض في HTML) */
function normalizeRegistrationLinkInput(raw) {
  var s = String(raw || '').trim();
  if (!s) return s;
  s = s.replace(/\u00AE=/gi, '&code=').replace(/®=/gi, '&code=').replace(/&reg=/gi, '&code=');
  s = s.replace(/([?&]token=)(REG_[A-Za-z0-9]{10,})(?:\u00AE|®)[^&#]*/gi, '$1$2');
  var tokM = s.match(/REG_[A-Za-z0-9]{10,}/i);
  var attM = s.match(/ATT-\d+-D[12]/i);
  if (tokM) {
    var tokClean = tokM[0];
    var code = attM ? attM[0] : '';
    try {
      var probe = s.indexOf('http') === 0 ? s : (s.indexOf('?') === 0 ? 'https://x/' + s : s);
      if (s.indexOf('token=') >= 0 || s.indexOf('code=') >= 0 || s.indexOf('?') === 0 || s.indexOf('http') === 0) {
        var u = new URL(probe, window.location.href);
        var qTok = u.searchParams.get('token') || '';
        var qCode = u.searchParams.get('code') || u.searchParams.get('reg') || '';
        var qTokClean = (String(qTok).match(/^(REG_[A-Za-z0-9]{10,})/i) || [])[1] || tokClean;
        if (!qCode) {
          var inTok = String(qTok).match(/ATT-\d+-D[12]/i);
          if (inTok) qCode = inTok[0];
        }
        if (!qCode && attM) qCode = attM[0];
        var base = s.indexOf('http') === 0 ? s.split('?')[0] : '';
        var q = '?token=' + encodeURIComponent(qTokClean) + (qCode ? '&code=' + encodeURIComponent(qCode) : '');
        return base ? base + q : q;
      }
    } catch (e) { /* fall through */ }
    if (s.indexOf('?') === 0) {
      return '?token=' + encodeURIComponent(tokClean) + (code ? '&code=' + encodeURIComponent(code) : '');
    }
  }
  return s;
}

function copyRegistrationLink(url) {
  url = normalizeRegistrationLinkInput(url || '');
  if (!url) return;
  var done = function () {
    if (typeof Swal !== 'undefined') {
      Swal.fire({ icon: 'success', title: 'تم نسخ الرابط', text: 'أرسله للموظف لفتحه على هاتفه', ...swalTheme(), timer: 1600, showConfirmButton: false });
    }
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(url).then(done).catch(function () {
      fallbackCopyRegistrationLink(url);
      done();
    });
  } else {
    fallbackCopyRegistrationLink(url);
    done();
  }
}

function fallbackCopyRegistrationLink(url) {
  var ta = document.createElement('textarea');
  ta.value = url;
  ta.style.cssText = 'position:fixed;left:-9999px;top:0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
}

function getQrPayload(code) {
  const parsed = parseBarcode(code);
  if (!parsed) return code;
  const empList = window.employees || [];
  const emp = empList.find(e => e.id === parsed.empId);
  if (!emp) return code;
  const dev = getDevice(emp, parsed.slot);
  const prevToken = dev && dev.token;
  const token = ensureDeviceToken(emp, dev);
  if (dev && dev.token !== prevToken) {
    try { saveData(); } catch (e) { console.warn('getQrPayload saveData:', e); }
  }
  return getRegistrationUrl(token, code);
}

async function prepareQrPayloadForEmployee(code, emp) {
  const parsed = parseBarcode(code);
  if (!parsed || !emp) return getQrPayload(code);
  const dev = getDevice(emp, parsed.slot || 1);
  const prevToken = dev && dev.token;
  const token = ensureDeviceToken(emp, dev);
  const tokenChanged = dev && dev.token !== prevToken;
  var prevDisable = window.__basmaDisableAutoSync;
  window.__basmaDisableAutoSync = true;
  try {
    if (typeof sb_pushDeviceTokensForEmployee === 'function') {
      var push = await sb_pushDeviceTokensForEmployee(emp);
      if (!push.ok) console.warn('prepareQrPayloadForEmployee:', push.reason);
    }
  } catch (e) {
    console.warn('prepareQrPayloadForEmployee:', e);
  } finally {
    window.__basmaDisableAutoSync = prevDisable;
  }
  if (tokenChanged) {
    try { saveData(); } catch (e) { console.warn('prepareQrPayload saveData:', e); }
  }
  return getRegistrationUrl(token, code);
}

/* ===== Self-Registration Page for Phone ===== */
function showPhoneRegistrationPage() {
  // Remove existing overlay if any
  const existing = document.getElementById('phone-reg-overlay');
  if (existing) existing.remove();

  const fp = getDeviceFingerprint();
  const overlay = document.createElement('div');
  overlay.id = 'phone-reg-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;z-index:9999;background:#0a1628;display:flex;align-items:center;justify-content:center;padding:16px;font-family:Cairo,Tajawal,sans-serif;direction:rtl';
  overlay.innerHTML = `
  <div style="background:#0f2240;border:1px solid rgba(0,212,170,0.25);border-radius:20px;padding:28px 24px;max-width:420px;width:100%;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,0.7);max-height:90vh;overflow-y:auto">
    <div style="font-size:38px;margin-bottom:10px">📱</div>
    <h2 style="color:#e8f4fd;font-size:20px;margin:0 0 8px;font-weight:800">تسجيل الجهاز</h2>
    <p style="color:rgba(232,244,253,0.65);font-size:13px;line-height:1.8;margin:0 0 20px">
      سيتم تسجيل IP الهاتف وبصمة الجهاز تلقائياً عند فتح رابط QR<br>
      <span style="font-size:11px;color:rgba(0,212,170,0.8)">يعمل تلقائياً بدون PIN أو إدخال يدوي</span>
    </p>
    <div style="margin-bottom:14px;text-align:right">
      <label style="color:rgba(232,244,253,0.65);font-size:12px;display:block;margin-bottom:6px">رمز التسجيل</label>
      <input type="text" id="phone-reg-code" placeholder="REG_x8aK29LmPq" dir="ltr" autocomplete="off" autocorrect="off" spellcheck="false"
        style="width:100%;padding:13px;border-radius:12px;border:2px solid #00d4aa;background:rgba(0,0,0,0.3);color:#00d4aa;font-size:14px;text-align:center;font-weight:700;font-family:monospace;outline:none;letter-spacing:1px">
    </div>
    <div style="margin-bottom:16px;padding:10px 14px;border-radius:10px;background:rgba(0,0,0,0.25);border:1px solid rgba(255,255,255,0.08);text-align:right">
      <div style="color:rgba(232,244,253,0.4);font-size:11px;margin-bottom:3px">بصمة هذا الجهاز</div>
      <div style="color:#68d391;font-size:12px;direction:ltr;font-weight:700;font-family:monospace;word-break:break-all">${esc(fp)}</div>
    </div>
    <button onclick="doPhoneRegistration()" style="width:100%;padding:14px;border-radius:12px;border:none;background:linear-gradient(135deg,#00d4aa,#00a880);color:#0a1628;font-size:16px;font-weight:800;cursor:pointer">
      🔗 تسجيل هذا الجهاز
    </button>
    <div id="phone-reg-result" style="margin-top:14px;display:none;padding:14px;border-radius:12px;font-size:14px;font-weight:700;line-height:1.8"></div>
    <button onclick="closePhoneRegistration()" style="margin-top:12px;padding:10px 24px;border-radius:10px;border:1px solid rgba(255,255,255,0.15);background:transparent;color:rgba(232,244,253,0.65);cursor:pointer;font-size:14px">
      ← رجوع
    </button>
  </div>`;
  document.body.appendChild(overlay);
  setTimeout(() => {
    const inp = document.getElementById('phone-reg-code');
    if (inp) { inp.focus(); safeAddEvent(inp, 'keydown', function (e) { if (e.key === 'Enter') doPhoneRegistration(); }); }
  }, 200);
}

function closePhoneRegistration() {
  const overlay = document.getElementById('phone-reg-overlay');
  if (overlay) overlay.remove();
}

function ensureEmployeesArray() {
  if (!Array.isArray(window.employees)) window.employees = [];
  if (typeof employees === 'undefined' || !Array.isArray(employees)) {
    window.employees = window.employees || [];
  }
  return window.employees;
}

function mergeRegistrationLookupIntoEmployees(lookup) {
  if (!lookup || !lookup.employee_id) return null;
  var empList = ensureEmployeesArray();
  var empId = parseInt(lookup.employee_id, 10);
  if (!empId || !Number.isFinite(empId)) return null;
  var slot = parseInt(lookup.slot, 10) || 1;
  var emp = empList.find(function (e) { return e.id === empId; });
  if (!emp) {
    emp = {
      id: empId,
      name: lookup.emp_name || 'موظف',
      dept: lookup.dept || '—',
      role: '—',
      phone: '—',
      salary: 0,
      devices: [],
      company_id: lookup.company_id || null
    };
    empList.push(emp);
  }
  normalizeEmployee(emp);
  var dev = getDevice(emp, slot);
  if (!dev) {
    dev = {
      slot: slot,
      label: slot === 1 ? 'الهاتف الأول' : 'الهاتف الثاني',
      ip: '', fingerprint: '', pin: '', barcode: genBarcode(empId, slot),
      token: '', deviceInfo: null, linked_at: '', last_login: ''
    };
    emp.devices = emp.devices || [];
    emp.devices.push(dev);
  }
  if (lookup.token) dev.token = lookup.token;
  if (lookup.pin) dev.pin = lookup.pin;
  if (lookup.label) dev.label = lookup.label;
  if (lookup.fingerprint) dev.fingerprint = lookup.fingerprint;
  if (lookup.ip) dev.ip = lookup.ip;
  dev.barcode = lookup.barcode || genBarcode(empId, slot);
  if (typeof applyEmployeeClientProfile === 'function') {
    applyEmployeeClientProfile(emp, lookup);
  }
  return { emp: emp, dev: dev };
}

async function refreshEmployeeClientProfileById(empId, options) {
  empId = parseInt(empId, 10);
  if (!empId) return null;
  if (typeof initSupabase === 'function') initSupabase();
  if (typeof ensureSupabaseClient === 'function') {
    await ensureSupabaseClient(8);
  }
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  if (typeof sb_fetchEmployeeClientProfile !== 'function') return emp || null;
  var prof = await sb_fetchEmployeeClientProfile(empId, options || {});
  if (!prof || prof.ok !== true) return emp || null;
  if (!emp) {
    emp = {
      id: empId,
      name: prof.emp_name || 'موظف',
      dept: prof.dept || '—',
      role: '—',
      phone: '—',
      salary: 0,
      devices: [],
      company_id: prof.company_id || null
    };
    employees.push(emp);
  }
  if (typeof applyEmployeeClientProfile === 'function') applyEmployeeClientProfile(emp, prof);
  if (typeof ensureEmployeeTenantContext === 'function') ensureEmployeeTenantContext(emp);
  if (typeof saveData === 'function') saveData();
  return emp;
}

async function refreshLoggedInEmployeeFromServer() {
  if (!window.loggedInEmpId) return null;
  return refreshEmployeeClientProfileById(window.loggedInEmpId);
}

function resetEmployeeCheckInStateFromAttendance(empId) {
  var openRec = findOpenAttendanceRecord(empId, false);
  if (!openRec || !openRec.ci || openRec.ci === '—' || (openRec.co && openRec.co !== '—')) {
    checkedIn = false;
    checkInTime = null;
    return;
  }
  checkedIn = true;
  var baseDate = openRec.dateIso ? new Date(openRec.dateIso + 'T12:00:00') : new Date();
  var parts = String(openRec.ci).match(/(\d+):(\d+)\s*(AM|PM)/i);
  if (parts) {
    var ch = parseInt(parts[1], 10);
    var cm = parseInt(parts[2], 10);
    var cap = parts[3].toUpperCase();
    if (cap === 'PM' && ch !== 12) ch += 12;
    if (cap === 'AM' && ch === 12) ch = 0;
    checkInTime = new Date(baseDate.getFullYear(), baseDate.getMonth(), baseDate.getDate(), ch, cm);
  } else {
    checkInTime = new Date(baseDate.getFullYear(), baseDate.getMonth(), baseDate.getDate(), 8, 0);
  }
}

function employeeNotificationKey(n) {
  if (!n) return '';
  if (n.id != null && n.id !== '') return 'id:' + String(n.id);
  if (n.notif_ref != null && n.notif_ref !== '') return 'id:' + String(n.notif_ref);
  if (n._remoteId != null && n._remoteId !== '') return 'remote:' + String(n._remoteId);
  if (n._remote_id != null && n._remote_id !== '') return 'remote:' + String(n._remote_id);
  if (n.financeItemId != null && n.financeItemId !== '') return 'finance:' + String(n.financeItemId);
  if (n.finance_item_id != null && n.finance_item_id !== '') return 'finance:' + String(n.finance_item_id);
  return [
    n.empId || n.emp_id || n.employee_id || '',
    n.financeType || n.finance_type || n.type || n.notif_type || '',
    n.action || '',
    n.title || '',
    n.body || '',
    n.ts || n.created_at || ''
  ].join('|');
}

function employeeNotificationSignature(n) {
  if (!n) return '';
  var rawTs = n.ts || n.created_at || n.createdAt || '';
  var tsBucket = '';
  if (rawTs) {
    var t = typeof rawTs === 'number' ? rawTs : new Date(rawTs).getTime();
    if (Number.isFinite(t)) tsBucket = String(Math.floor(t / 60000));
  }
  return [
    n.empId || n.emp_id || n.employee_id || '',
    n.financeItemId || n.finance_item_id || '',
    n.financeType || n.finance_type || n.type || n.notif_type || '',
    n.action || '',
    n.title || '',
    n.body || '',
    tsBucket
  ].join('|');
}

function dedupeEmployeeNotifications(arr) {
  var seen = {};
  var seenSig = {};
  var out = [];
  (arr || []).forEach(function (n) {
    if (!n) return;
    var key = employeeNotificationKey(n);
    var sig = employeeNotificationSignature(n);
    if (!key) key = 'idx:' + out.length;
    if (seen[key] || (sig && seenSig[sig])) {
      var existing = seen[key] || seenSig[sig];
      var isRead = existing.read === true || n.read === true || existing.unread === false || n.unread === false;
      existing.read = isRead;
      existing.unread = !isRead;
      existing._remoteId = existing._remoteId || n._remoteId || n._remote_id;
      existing.title = existing.title || n.title;
      existing.body = existing.body || n.body;
      existing.financeType = existing.financeType || n.financeType || n.finance_type;
      return;
    }
    seen[key] = n;
    if (sig) seenSig[sig] = n;
    out.push(n);
  });
  return out;
}

function getEmpPortalAttendanceRows(emp, options) {
  options = options || {};
  if (!emp || !emp.id) return [];
  var list = (attData || []).filter(function (r) {
    return r && r.empId === emp.id && isPunchAttendanceRecord(r);
  });
  list.forEach(function (r) { ensureAttendanceRecordDates(r); });
  list = list.filter(function (r) { return !!attendanceRecordIso(r); });
  list.sort(function (a, b) {
    return attendanceRecordIso(b).localeCompare(attendanceRecordIso(a));
  });
  var maxDays = options.days;
  if (maxDays != null && maxDays > 0 && list.length > maxDays) list = list.slice(0, maxDays);
  return list;
}

async function fetchAllEmployeeAttendanceFromCloud(empId, options) {
  options = options || {};
  if (!empId || typeof sb_fetchEmployeeAttendance !== 'function') return [];
  var pageSize = options.pageSize || 500;
  var offset = 0;
  var all = [];
  var guard = 0;
  while (guard < 200) {
    guard++;
    var page = await sb_fetchEmployeeAttendance(empId, {
      limit: pageSize,
      offset: offset,
      fingerprint: options.fingerprint,
      token: options.token,
      slot: options.slot
    });
    if (!page || !page.length) break;
    all = all.concat(page);
    if (page.length < pageSize) break;
    offset += page.length;
  }
  return all;
}

async function refreshLoggedInEmployeeAttendance(options) {
  options = options || {};
  var empId = parseInt(window.loggedInEmpId || '0', 10);
  if (!empId) return false;
  if (typeof sb_fetchEmployeeAttendance !== 'function') return false;
  var localPending = (attData || []).filter(function (r) {
    if (!r || r.empId !== empId) return false;
    return r._pendingRemoteSync || (r._localAttEditAt && (Date.now() - r._localAttEditAt) < 300000);
  });
  var existingForEmp = (attData || []).filter(function (r) {
    return r && r.empId === empId;
  });
  var rows = typeof fetchAllEmployeeAttendanceFromCloud === 'function'
    ? await fetchAllEmployeeAttendanceFromCloud(empId, options)
    : await sb_fetchEmployeeAttendance(empId, { limit: 5000, offset: 0 });
  if (rows == null) return false;
  if (!Array.isArray(rows)) rows = [];
  if (rows.length === 0 && existingForEmp.length > 0) {
    var hasMeaningfulLocal = existingForEmp.some(function (r) {
      if (!r) return false;
      if (r._pendingRemoteSync || r._localAttEditAt) return true;
      if (r.ci && r.ci !== '—') return true;
      if (r.co && r.co !== '—') return true;
      return false;
    });
    if (hasMeaningfulLocal) {
      if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
      resetEmployeeCheckInStateFromAttendance(empId);
      if (typeof saveData === 'function') saveData();
      return true;
    }
  }
  var byKey = {};
  existingForEmp.forEach(function (r) {
    ensureAttendanceRecordDates(r);
    var k = attendanceRecordKey(r);
    if (k) byKey[k] = r;
  });
  rows.forEach(function (r) {
    ensureAttendanceRecordDates(r);
    var k = attendanceRecordKey(r);
    if (!k) return;
    var prev = byKey[k];
    if (!prev || attendanceRecordRank(r) > attendanceRecordRank(prev)) byKey[k] = r;
  });
  localPending.forEach(function (local) {
    ensureAttendanceRecordDates(local);
    var k = attendanceRecordKey(local);
    if (!k) return;
    var prev = byKey[k];
    if (!prev || attendanceRecordRank(local) > attendanceRecordRank(prev)) byKey[k] = local;
  });
  attData = (attData || []).filter(function (r) { return !r || r.empId !== empId; });
  Object.keys(byKey).forEach(function (k) { attData.push(byKey[k]); });
  if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
  resetEmployeeCheckInStateFromAttendance(empId);
  if (typeof saveData === 'function') saveData();
  return true;
}

function mergeEmployeeNotificationsForEmp(empId, remoteArr) {
  ensureNotifStores();
  empId = parseInt(empId, 10);
  if (!empId) return false;
  var remote = dedupeEmployeeNotifications((remoteArr || []).filter(function (n) {
    if (!n || String(n.empId) !== String(empId)) return false;
    var empCid = typeof getLoggedInEmployeeCompanyId === 'function' ? getLoggedInEmployeeCompanyId() : null;
    if (empCid && n.companyId != null && parseInt(n.companyId, 10) !== empCid) return false;
    return true;
  }));
  if (!remote.length) return false;
  var other = (appSettings.employeeNotifications || []).filter(function (n) { return n && String(n.empId) !== String(empId); });
  var local = (appSettings.employeeNotifications || []).filter(function (n) { return n && String(n.empId) === String(empId); });
  var localMap = {};
  var localSigMap = {};
  local.forEach(function (l) {
    var key = employeeNotificationKey(l);
    var sig = employeeNotificationSignature(l);
    if (key) localMap[key] = l;
    if (sig) localSigMap[sig] = l;
  });
  var merged = remote.map(function (r) {
    var l = localMap[employeeNotificationKey(r)] || localSigMap[employeeNotificationSignature(r)];
    if (!l) return r;
    var dismissed = typeof isEmployeeFinanceRailDismissed === 'function' && isEmployeeFinanceRailDismissed(l);
    var isRead = dismissed || l.read === true || r.read === true || l.unread === false || r.unread === false;
    return Object.assign({}, r, {
      read: isRead,
      unread: !isRead,
      type: l.type || r.type,
      title: l.title || r.title,
      body: l.body || r.body,
      ico: l.ico || r.ico,
      icon: l.icon || r.icon,
      _remoteId: l._remoteId || r._remoteId
    });
  });
  local.forEach(function (l) {
    var lk = employeeNotificationKey(l);
    if (l && lk && !merged.some(function (x) { return employeeNotificationKey(x) === lk; })) merged.unshift(l);
  });
  appSettings.employeeNotifications = other.concat(dedupeEmployeeNotifications(merged));
  return true;
}

async function refreshLoggedInEmployeeSalaryHistory(options) {
  options = options || {};
  var empId = parseInt(window.loggedInEmpId || '0', 10);
  if (!empId) return false;
  if (typeof sb_fetchEmployeeSalaryRecords !== 'function') return false;
  var rows = await sb_fetchEmployeeSalaryRecords(empId, { limit: options.limit || 120 });
  if (!rows) return false;
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  if (!emp) return false;
  emp.salaryHistoryData = rows;
  emp.salaryHistoryInit = true;
  if (typeof saveData === 'function') saveData();
  return true;
}

async function refreshLoggedInEmployeeNotifications(options) {
  options = options || {};
  var empId = parseInt(window.loggedInEmpId || '0', 10);
  if (!empId) return false;
  if (typeof sb_fetchEmployeeNotifications !== 'function') return false;
  var rows = await sb_fetchEmployeeNotifications(empId, { limit: options.limit || 80 });
  if (!rows) return false;
  if (!rows.length) {
    if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
    return true;
  }
  var parsed = rows.map(function (n) {
    var notifType = n.type || n.notif_type || n.notifType || '';
    var isLeave = notifType === 'leave' || notifType === 'absence';
    return {
      id: n.notif_ref || n.id || n._remote_id,
      ts: n.ts != null ? n.ts : (n.created_at ? new Date(n.created_at).getTime() : Date.now()),
      empId: n.empId != null ? parseInt(n.empId, 10) : (n.emp_id != null ? parseInt(n.emp_id, 10) : empId),
      empName: n.empName || n.emp_name || '',
      type: isLeave ? 'leave' : (notifType || undefined),
      financeType: n.financeType || n.finance_type || notifType || undefined,
      action: n.action,
      amount: n.amount,
      title: n.title || '',
      body: n.body || '',
      note: n.note || n.body || '',
      ico: n.ico || (isLeave ? 'fa-calendar-alt' : undefined),
      icon: n.icon || (isLeave ? 'blue' : undefined),
      actorName: n.actorName || n.actor_name || '',
      financeItemId: n.financeItemId != null ? n.financeItemId : n.finance_item_id,
      read: n.read === true || n.is_read === true,
      unread: !(n.read === true || n.is_read === true || n.unread === false),
      _remoteId: n._remoteId != null ? n._remoteId : n._remote_id,
      companyId: n.companyId != null ? n.companyId : n.company_id
    };
  });
  mergeEmployeeNotificationsForEmp(empId, parsed);
  if (typeof saveData === 'function') saveData();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
  if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
  return true;
}

var _autoLoginRestoreRunning = false;
var _employeePortalPollTimer = null;

function startEmployeePortalPolling() {
  if (_employeePortalPollTimer) clearInterval(_employeePortalPollTimer);
  if (window._broadcastReShowTimer) clearInterval(window._broadcastReShowTimer);
  window._broadcastReShowTimer = null;
  if (currentUser !== 'emp' || !window.loggedInEmpId) return;
  if (typeof renderEmployeeBroadcastRail === 'function') { try { renderEmployeeBroadcastRail(); } catch (e) { /* ignore */ } }
  window._broadcastReShowTimer = setInterval(function () {
    if (currentUser !== 'emp' || !window.loggedInEmpId || document.hidden) return;
    if (typeof renderEmployeeBroadcastRail === 'function') { try { renderEmployeeBroadcastRail(); } catch (e) { /* ignore */ } }
  }, 20000);
  _employeePortalPollTimer = setInterval(function () {
    if (currentUser !== 'emp' || !window.loggedInEmpId || document.hidden) return;
    var tasks = [];
    if (typeof refreshLoggedInEmployeeFromServer === 'function') {
      tasks.push(refreshLoggedInEmployeeFromServer().catch(function (e) { console.warn('employee poll profile:', e); }));
    }
    if (typeof refreshLoggedInEmployeeAttendance === 'function') {
      tasks.push(refreshLoggedInEmployeeAttendance().catch(function (e) { console.warn('employee poll attendance:', e); }));
    }
    if (typeof refreshLoggedInEmployeeNotifications === 'function') {
      tasks.push(refreshLoggedInEmployeeNotifications({ limit: 100 }).catch(function (e) { console.warn('employee poll notifications:', e); }));
    }
    if (typeof syncLeavesFromSupabase === 'function') {
      tasks.push(syncLeavesFromSupabase({ empId: window.loggedInEmpId }).catch(function (e) { console.warn('employee poll leaves:', e); }));
    }
    if (typeof refreshLoggedInEmployeeSalaryHistory === 'function') {
      tasks.push(refreshLoggedInEmployeeSalaryHistory({ limit: 120 }).catch(function (e) { console.warn('employee poll salary:', e); }));
    }
    Promise.all(tasks).then(function () {
      if (typeof buildEmpPortal === 'function') buildEmpPortal({ skipSubscriptionRefresh: true });
      if (typeof buildEmployeeLeaveNotifs === 'function') buildEmployeeLeaveNotifs(window.loggedInEmpId);
      if (typeof updateNotifBadges === 'function') updateNotifBadges();
      if (typeof renderEmployeeBroadcastRail === 'function') renderEmployeeBroadcastRail();
    });
  }, 15000);
}

function stopEmployeePortalPolling() {
  if (_employeePortalPollTimer) clearInterval(_employeePortalPollTimer);
  _employeePortalPollTimer = null;
  if (window._broadcastReShowTimer) clearInterval(window._broadcastReShowTimer);
  window._broadcastReShowTimer = null;
}

function clearAdminSessionForEmployeeClient() {
  if (typeof clearAdminSession === 'function') clearAdminSession();
  saasCurrentUser = null;
  window._saasCurrentUser = null;
  if (typeof setSubscriptionStatus === 'function') setSubscriptionStatus(null);
  else window._subscriptionStatus = null;
  if (typeof AuthApi !== 'undefined' && AuthApi.clearSupabaseSession) {
    AuthApi.clearSupabaseSession().catch(function () {});
  }
}

async function doPhoneRegistration() {
  const result = document.getElementById('phone-reg-result');
  try {
    var activeClosure = officialClosureForDate();
    if (activeClosure) {
      if (result) {
        result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(128,90,213,0.14);border:1px solid rgba(128,90,213,0.35);color:#d6bcfa;font-size:13px;font-weight:700';
        result.textContent = 'الرابط معطل حالياً بسبب: ' + activeClosure.title + ' (' + activeClosure.startDate + ' إلى ' + activeClosure.endDate + ')';
      }
      return;
    }
    beginQrRegistrationContext();
    const codeInp = document.getElementById('phone-reg-code');
    if (!codeInp || !result) return;
    const code = normalizeRegistrationLinkInput(codeInp.value.trim());
    if (!code) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      result.textContent = 'تعذر قراءة رابط التسجيل';
      return;
    }
    let parsed = parseBarcode(code);
    if (!parsed) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      result.textContent = 'رابط QR غير صالح';
      return;
    }

    result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(0,212,170,0.08);border:1px solid rgba(0,212,170,0.2);color:var(--accent,#00d4aa);font-size:13px;font-weight:700';
    result.textContent = 'جارٍ التحقق من QR في السحابة...';

    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') await withClientTimeout(ensureSupabaseClient(12), 14000, 'supabase_connect');

    var empList = window.employees || [];
    let emp = null;
    let dev = null;
    var resolveErr = '';

    if (typeof sb_resolveQrRegistration === 'function') {
      const resolved = await withClientTimeout(sb_resolveQrRegistration({
        token: parsed.token || null,
        empId: parsed.empId || null,
        slot: parsed.slot || null
      }), 14000, 'qr_resolve');
      if (resolved.ok && resolved.data) {
        const merged = mergeRegistrationLookupIntoEmployees(resolved.data);
        if (merged) {
          emp = merged.emp;
          dev = merged.dev;
          if (!parsed.empId) parsed.empId = emp.id;
          if (!parsed.slot) parsed.slot = dev.slot;
          if (resolved.data.token && !parsed.token) parsed.token = resolved.data.token;
        } else {
          resolveErr = 'merge_failed';
        }
      } else {
        resolveErr = resolved.error || 'not_found';
        if (!parsed.token && resolveErr === 'token_not_found' && parsed.empId && parsed.slot) {
          const resolvedSlot = await withClientTimeout(sb_resolveQrRegistration({
            empId: parsed.empId,
            slot: parsed.slot,
            token: parsed.token || null
          }), 14000, 'qr_resolve_slot');
          if (resolvedSlot.ok && resolvedSlot.data) {
            const mergedSlot = mergeRegistrationLookupIntoEmployees(resolvedSlot.data);
            if (mergedSlot) {
              emp = mergedSlot.emp;
              dev = mergedSlot.dev;
              resolveErr = '';
            }
          }
        }
      }
    }

    if (parsed.token && resolveErr && (!emp || !dev)) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      if (resolveErr === 'token_not_found' || resolveErr === 'not_found') {
        result.innerHTML = 'رمز QR غير موجود في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">افتح «عرض QR» من لوحة الإدارة وانتظر «QR جاهز»، ثم امسح QR جديداً. لن يتم استخدام بيانات محفوظة سابقاً على هذا الهاتف.</span>';
      } else {
        result.innerHTML = 'تعذّر التحقق من QR في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">' + esc(describeSupabaseSaveError(resolveErr)) + '</span>';
      }
      return;
    }

    if (!emp || !dev) {
      // لا نستخدم أي تطابق محلي قبل الرجوع للسحابة، حتى لا يظهر موظف قديم محفوظ على الهاتف.
      emp = null;
      dev = null;
    }

    if ((!emp || !dev) && typeof sb_lookupDeviceRegistration === 'function') {
      const lookup = await withClientTimeout(sb_lookupDeviceRegistration({
        token: parsed.token || null,
        empId: parsed.empId || null,
        slot: parsed.slot || null
      }), 14000, 'qr_lookup');
      if (lookup && lookup.employee_id) {
        const merged = mergeRegistrationLookupIntoEmployees(lookup);
        if (merged) {
          emp = merged.emp;
          dev = merged.dev;
          if (!parsed.empId) parsed.empId = emp.id;
          if (!parsed.slot) parsed.slot = dev.slot;
        }
      }
    }

    if ((!emp || !dev) && typeof syncFromSupabase === 'function') {
      result.textContent = 'جارٍ مزامنة بيانات الموظف...';
      try {
        await withClientTimeout(syncFromSupabase({ keepDisableAutoSync: true }), 16000, 'employee_sync');
        empList = window.employees || [];
        var target2 = parsed.token ? findDeviceByToken(parsed.token) : null;
        emp = target2?.emp || (parsed.empId ? empList.find(e => e.id === parsed.empId) : null);
        dev = target2?.dev || (emp && parsed.slot ? getDevice(emp, parsed.slot) : null);
      } catch (e) {
        console.warn('sync before phone registration failed:', e);
      } finally {
        if (typeof resumeRemoteSync === 'function') resumeRemoteSync(4000);
      }
    }

    if (dev && parsed.token && !dev.token) {
      dev.token = parsed.token;
      dev.tokenCreatedAt = new Date().toISOString();
    }

    if (!emp || !dev) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      if (resolveErr === 'employee_not_found') {
        result.innerHTML = 'الموظف غير موجود في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">أضف الموظف من لوحة الإدارة حتى تظهر «QR جاهز» ثم امسح QR جديداً.</span>';
      } else if (resolveErr === 'token_not_found') {
        result.innerHTML = 'رمز QR غير منشور في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">1) من الإدارة: افتح «عرض QR» وانتظر «✓ QR جاهز»<br>2) انسخ الرابط بزر «نسخ الرابط» (لا تنسخ من النص مباشرة)<br>3) تأكد أن الرابط يحتوي <b>&amp;code=ATT-</b> وليس الرمز ®</span>';
      } else if (resolveErr === 'merge_failed') {
        result.innerHTML = 'تعذّر دمج بيانات QR محلياً<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">QR موجود في السحابة — حدّث الصفحة على الهاتف ثم أعد المسح.</span>';
      } else {
        result.innerHTML = 'لم يتم العثور على بيانات هذا QR<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">1) من لوحة الإدارة: أضف الموظف حتى تظهر «QR جاهز»<br>2) افتح «عرض QR» ثم امسح<br>3) على الهاتف: امسح QR جديداً (ليس من تجربة قديمة)<br>4) إن استمرت المشكلة تواصل مع الدعم الفني</span>';
      }
      return;
    }

    if (parsed.pin && dev.pin && dev.pin !== parsed.pin) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      result.textContent = 'رمز QR القديم غير مطابق لهذا الجهاز';
      return;
    }

    const fp = getDeviceFingerprint();
    const ip = await withClientTimeout(fetchClientIp(), 7000, 'ip_lookup').catch(function () { return ''; });

    if (!parsed.token && dev.token) parsed.token = dev.token;
    const linkToken = parsed.token || dev.token || null;

    if (typeof sb_linkDeviceByToken === 'function' && (linkToken || (parsed.empId && parsed.slot))) {
      result.textContent = 'جارٍ ربط الجهاز في السحابة...';
      const remoteLink = await withClientTimeout(sb_linkDeviceByToken(
        linkToken,
        fp,
        ip,
        getDeviceInfo(),
        parsed.empId || emp.id,
        parsed.slot || dev.slot
      ), 14000, 'device_link');
      if (remoteLink && remoteLink.ok === true) {
        dev.fingerprint = remoteLink.fingerprint || fp;
        dev.ip = remoteLink.ip || ip || dev.ip || '';
        if (remoteLink.employee_id && !emp) {
          var mergedRemote = mergeRegistrationLookupIntoEmployees({
            employee_id: remoteLink.employee_id,
            emp_name: remoteLink.emp_name,
            slot: remoteLink.slot,
            token: linkToken,
            fingerprint: dev.fingerprint,
            ip: dev.ip
          });
          if (mergedRemote) {
            emp = mergedRemote.emp;
            dev = mergedRemote.dev;
          }
        }
      } else if (remoteLink && remoteLink.ok === false) {
        if (remoteLink.error === 'official_closure_active') {
          result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(128,90,213,0.14);border:1px solid rgba(128,90,213,0.35);color:#d6bcfa;font-size:13px;font-weight:700';
          result.textContent = 'الرابط معطل حالياً بسبب عطلة رسمية للشركة';
          return;
        }
        if (remoteLink.error === 'device_already_linked') {
          if (typeof sb_adoptBrowserFingerprint === 'function') {
            var adoptRetry = await sb_adoptBrowserFingerprint(fp, ip, {
              token: linkToken,
              employeeId: parsed.empId || (emp && emp.id) || null,
              slot: parsed.slot || (dev && dev.slot) || null
            });
            if (adoptRetry && adoptRetry.ok === true) {
              remoteLink = {
                ok: true,
                employee_id: adoptRetry.employee_id,
                slot: adoptRetry.slot,
                emp_name: adoptRetry.emp_name,
                fingerprint: fp,
                ip: ip,
                multi_browser: adoptRetry.multi_browser === true
              };
            }
          }
          if (!remoteLink || remoteLink.ok !== true) {
            result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
            result.textContent = 'تعذّر ربط هذا المتصفح — أعد مسح QR من لوحة الإدارة';
            return;
          }
        }
        if (remoteLink.error === 'not_found' || remoteLink.error === 'invalid_token') {
          result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
          result.innerHTML = 'تعذّر تسجيل الجهاز في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">من لوحة الإدارة: أعد فتح QR للموظف ثم امسح QR جديداً. إن استمرت المشكلة تواصل مع الدعم الفني.</span>';
          return;
        }
        if (remoteLink.error === 'invalid_fingerprint') {
          result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
          result.textContent = 'تعذّر إنشاء بصمة الجهاز — حدّث الصفحة وحاول مرة أخرى';
          return;
        }
        result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700;line-height:1.8';
        result.innerHTML = 'تعذّر ربط الجهاز في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">' + esc(describeDeviceLinkError(remoteLink)) + '</span>';
        return;
      } else {
        result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
        result.innerHTML = 'تعذّر ربط الجهاز في السحابة<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">خدمة الربط لم تُرجع نتيجة واضحة — حدّث الصفحة ثم أعد مسح QR.</span>';
        return;
      }
    }

    const linked = linkDeviceToEmployee(emp, dev, ip, fp);
    if (!linked.ok) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      result.textContent = linked.message || 'تعذّر ربط الجهاز';
      return;
    }
    ensureEmployeeTenantContext(emp);
    if (!employees.some(function (e) { return e && e.id === emp.id; })) {
      employees.push(emp);
      window.employees = employees;
    }
    emp._freshDevices = true;
    if (typeof saveData === 'function') saveData();

    currentUser = 'emp';
    window.loggedInEmpId = emp.id;
    if (typeof clearAdminSessionForEmployeeClient === 'function') clearAdminSessionForEmployeeClient();
    if (typeof refreshEmployeeSubscriptionForEmp === 'function') {
      try { await refreshEmployeeSubscriptionForEmp(emp); } catch (e) {
        console.warn('doPhoneRegistration subscription refresh:', e);
      }
    }
    result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(56,161,105,0.12);border:1px solid rgba(56,161,105,0.35);color:#68d391;font-size:14px;font-weight:700;line-height:1.8';
    result.innerHTML = 'تم ربط الهاتف بنجاح<br>' +
      '<span style="font-size:13px;color:#e8f4fd">' + esc(emp.name) + ' - ' + esc(dev.label) + '</span><br>' +
      '<span style="font-size:11px;color:rgba(232,244,253,0.5);direction:ltr;display:block;margin-top:4px">IP: ' + esc(ip || 'غير متاح') + '</span>' +
      '<span style="font-size:11px;color:rgba(232,244,253,0.5);direction:ltr;display:block;margin-top:4px">Fingerprint: ' + esc(fp) + '</span>';
    try {
      history.replaceState({}, '', window.location.pathname + window.location.hash);
    } catch (e) { /* ignore */ }
    setTimeout(function () {
      try {
        window.__basmaQrRegistrationInProgress = false;
        closePhoneRegistration();
        launchApp();
      } catch (e) { console.warn('launchApp after phone reg:', e); }
    }, 900);
  } catch (e) {
    console.error('doPhoneRegistration error:', e);
    if (result) {
      result.style.cssText = 'display:block;padding:14px;border-radius:12px;background:rgba(229,62,62,0.12);border:1px solid rgba(229,62,62,0.35);color:#fc8181;font-size:13px;font-weight:700';
      var detail = (e && e.message) ? String(e.message) : '';
      if (/localStorage|QuotaExceeded|SecurityError/i.test(detail)) {
        result.innerHTML = 'تعذّر حفظ بيانات الجهاز محلياً<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">أغلق وضع التصفح الخاص أو اسمح بالتخزين للموقع ثم أعد مسح QR</span>';
      } else if (/_timeout$/i.test(detail)) {
        result.innerHTML = 'انتهت مهلة التحقق من الجهاز<br><span style="font-size:11px;color:rgba(232,244,253,0.65)">تحقق من الإنترنت ثم حدّث الصفحة أو أعد مسح QR. إذا استمرت المشكلة افتح قيد المحاولات من إدارة بصمة الأجهزة.</span>';
      } else {
        result.textContent = 'حدث خطأ أثناء ربط الجهاز: ' + (detail || 'حاول مرة أخرى');
      }
    }
  }
}

function sanitizeNumber(v, fallback) {
  const normalized = String(v ?? '')
    .replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d))
    .replace(/[۰-۹]/g, d => '۰۱۲۳۴۵۶۷۸۹'.indexOf(d))
    .replace(/[,٬\s]/g, '');
  const n = Number(normalized);
  return Number.isFinite(n) ? n : fallback;
}

function exactMoneyValue(value, fallback) {
  const normalized = String(value ?? '')
    .replace(/[٠-٩]/g, d => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)))
    .replace(/[۰-۹]/g, d => String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)))
    .replace(/[^\d,٬.-]/g, '')
    .replace(/[٬,]/g, '');
  if (!normalized || normalized === '-' || normalized === '.') {
    const fb = Number(fallback || 0);
    return Number.isFinite(fb) ? Math.max(0, Math.round(fb)) : 0;
  }
  const n = Number(normalized);
  if (!Number.isFinite(n)) {
    const fb = Number(fallback || 0);
    return Number.isFinite(fb) ? Math.max(0, Math.round(fb)) : 0;
  }
  return Math.max(0, Math.round(n));
}

function parseExactInt(value, fallback) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.round(value));
  }
  const normalized = String(value ?? '')
    .replace(/[٠-٩]/g, d => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)))
    .replace(/[۰-۹]/g, d => String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)))
    .replace(/[^\d]/g, '');
  if (!normalized) return Math.max(0, parseInt(fallback || 0, 10) || 0);
  return Math.max(0, parseInt(normalized, 10) || 0);
}

function readMoneyValue(id, fallback) {
  const el = document.getElementById(id);
  return parseExactInt(el ? el.value : '', fallback || 0);
}

function sanitizeTime(v, fallback) {
  const s = String(v || '').trim();
  return /^([01]\d|2[0-3]):([0-5]\d)$/.test(s) ? s : fallback;
}

function sanitizeAvatarUrl(v) {
  var s = String(v || '').trim();
  if (!s) return '';
  if (
    s.indexOf('avatarSafe') !== -1 ||
    s.indexOf('avatarUrl') !== -1 ||
    s.indexOf('emp.') !== -1 ||
    s.indexOf('window.') !== -1 ||
    s.indexOf('{') !== -1 || s.indexOf('}') !== -1 ||
    s.indexOf('(') !== -1 || s.indexOf(')') !== -1
  ) return '';
  if (/^data:image\//i.test(s)) {
    if (/^data:image\/svg\+xml/i.test(s)) return '';
    if (/^data:image\/(png|jpe?g|webp);base64,[A-Za-z0-9+/=\s]+$/i.test(s)) {
      return s.replace(/\s+/g, '');
    }
    return '';
  }
  if ((s.startsWith('http://') || s.startsWith('https://')) &&
      s.indexOf("'") === -1 && s.indexOf('"') === -1 && s.indexOf('+') === -1 &&
      s.indexOf('%20') === -1 && s.indexOf(' ') === -1) {
    return s;
  }
  return '';
}
if (typeof window !== 'undefined') window.sanitizeAvatarUrl = sanitizeAvatarUrl;

function normalizeEmployeeSalaryFields(e) {
  if (!e) return e;
  e.salaryType = e.salaryType || 'monthly';
  e.salary = parseExactInt(e.salary, 0);
  e.salaryHalf = parseExactInt(e.salaryHalf, 0);
  e.dailyRate = parseExactInt(e.dailyRate, 0);
  if (e.salaryType === 'commission') {
    e.salary = 0;
    e.salaryHalf = 0;
    e.dailyRate = 0;
    return e;
  }
  if (e.salaryType === 'biweekly') {
    if (!e.salaryHalf && e.salary > 0) {
      e.salaryHalf = Math.floor(e.salary / 2);
    }
    if (!e.salary && e.salaryHalf > 0) {
      e.salary = e.salaryHalf * 2;
    }
    if (!e.dailyRate && e.salaryHalf > 0) {
      e.dailyRate = Math.floor(e.salaryHalf / getBiweeklyPeriodDays());
    }
    return e;
  }
  e.salaryType = 'monthly';
  e.salaryHalf = 0;
  e.salary = parseExactInt(e.salary, 0);
  if (e.salary > 0 && !e.dailyRate) {
    e.dailyRate = Math.floor(e.salary / getStandardMonthDays());
  }
  return e;
}

/** تثبيت الراتب من النموذج بعد المزامنة — يمنع 500000 → 499999 من إعادة الحساب */
function applyEmployeeSalaryFromForm(emp, formValues) {
  if (!emp || !formValues) return emp;
  var salaryType = formValues.salaryType || 'monthly';
  var salary = parseExactInt(formValues.salary, emp.salary);
  emp.salaryType = salaryType;
  emp.salary = salary;
  if (salaryType === 'biweekly') {
    emp.salaryHalf = parseExactInt(formValues.salaryHalf, 0) || (salary > 0 ? Math.floor(salary / 2) : 0);
    emp.dailyRate = parseExactInt(formValues.dailyRate, 0) || (emp.salaryHalf > 0 ? Math.floor(emp.salaryHalf / getBiweeklyPeriodDays()) : 0);
  } else if (salaryType === 'commission') {
    emp.salary = 0;
    emp.salaryHalf = 0;
    emp.dailyRate = 0;
  } else {
    emp.salaryHalf = 0;
    emp.dailyRate = parseExactInt(formValues.dailyRate, 0) || (salary > 0 ? Math.floor(salary / getStandardMonthDays()) : 0);
  }
  normalizeEmployeeSalaryFields(emp);
  return emp;
}

function normalizeEmployee(e) {
  if (!e) return e;
  normalizeEmployeeSalaryFields(e);
  e.checkIn = sanitizeTime(e.checkIn, '08:00');
  e.checkOut = sanitizeTime(e.checkOut, '17:00');
  e.days = parseExactInt(e.days, 0);
  e.lateMin = parseExactInt(e.lateMin, 0);
  e.salBonus = parseExactInt(e.salBonus, 0);
  e.avatarUrl = sanitizeAvatarUrl(e.avatarUrl);
  if (e.remoteAttend === undefined) e.remoteAttend = false;
  e.openHours = e.openHours === true;
  e.remoteAttend = e.remoteAttend === true;
  if (e.salDeletedPeriod === undefined) e.salDeletedPeriod = '';
  e.hireDate = e.hireDate ? String(e.hireDate).slice(0, 10) : '';
  e.active = e.active !== false;
  if (!e.devices) {
    e.devices = [
      { slot: 1, label: 'الهاتف الأول', ip: '', fingerprint: '', pin: '', barcode: genBarcode(e.id, 1), token: '', deviceInfo: null, linked_at: '', last_login: '' },
      { slot: 2, label: 'الهاتف الثاني', ip: '', fingerprint: '', pin: '', barcode: genBarcode(e.id, 2), token: '', deviceInfo: null, linked_at: '', last_login: '' }
    ];
  }
  e.devices.forEach((d, i) => {
    if (!d.slot) d.slot = i + 1;
    if (!d.label) d.label = d.slot === 1 ? 'الهاتف الأول' : 'الهاتف الثاني';
    if (!d.barcode) d.barcode = genBarcode(e.id, d.slot);
    ensureDeviceToken(e, d);
    if (!d.fingerprint) d.fingerprint = '';
    if (!d.pin) d.pin = '';
    if (!d.ip) d.ip = '';
    if (!d.linked_at) d.linked_at = '';
    if (!d.last_login) d.last_login = '';
    if (d.deviceInfo === undefined) d.deviceInfo = null;
  });
  return e;
}
function normalizeAllEmployees() { employees = employees.map(normalizeEmployee); }

function cleanCorruptedData() {
  var changed = false;
  employees.forEach(function(e) {
    var beforeUrl = e.avatarUrl || '';
    normalizeEmployee(e);
    if ((e.avatarUrl || '') !== beforeUrl) changed = true;
  });
  if (changed) saveData();
}

async function fetchClientIp() {
  try {
    const r = await fetch('https://api.ipify.org?format=json', { cache: 'no-store' });
    const j = await r.json();
    return (j.ip || '').trim();
  } catch (e) { return ''; }
}

function findEmployeeByFingerprint(fp) {
  if (!fp) return null;
  return employees.find(e => (e.devices || []).some(d => d.fingerprint && d.fingerprint === fp));
}

function findEmployeeByIp(ip) {
  if (!ip) return null;
  return employees.find(e => (e.devices || []).some(d => d.ip && d.ip.trim() === ip.trim()));
}

function findEmployeeByPin(pin) {
  if (!pin) return null;
  return employees.find(e => (e.devices || []).some(d => d.pin && d.pin === pin));
}

function findDeviceByToken(token) {
  if (!token) return null;
  for (const emp of (window.employees || [])) {
    const dev = (emp.devices || []).find(d => d.token === token);
    if (dev) return { emp, dev };
  }
  return null;
}

function findEmployeeByDevice(ip, fp) {
  // Priority: fingerprint > IP
  if (fp) {
    const byFp = findEmployeeByFingerprint(fp);
    if (byFp) return byFp;
  }
  if (ip) {
    const byIp = findEmployeeByIp(ip);
    if (byIp) return byIp;
  }
  return null;
}

function parseBarcode(code) {
  let token = normalizeRegistrationLinkInput(code);
  if (!token) return null;
  function dec(v) {
    if (!v) return v;
    try { return decodeURIComponent(v); } catch (e) { return v; }
  }
  function cleanRegToken(v) {
    var t = dec(v || '');
    var m = String(t).match(/^(REG_[A-Za-z0-9]{10,})/i);
    return m ? m[1] : t;
  }
  try {
    if (/^https?:\/\//i.test(token) || token.includes('code=') || token.includes('reg=') || token.includes('token=')) {
      const u = new URL(token, window.location.href);
      const regToken = cleanRegToken(u.searchParams.get('token'));
      const legacy = dec(u.searchParams.get('code') || u.searchParams.get('reg') || '');
      if (regToken) {
        const legacyParsed = legacy ? parseBarcode(legacy) : null;
        return Object.assign({ token: regToken }, legacyParsed || {});
      }
      token = legacy || token;
    } else if (token.startsWith('?')) {
      const params = new URLSearchParams(token);
      const regToken = cleanRegToken(params.get('token'));
      const legacy = dec(params.get('code') || params.get('reg') || '');
      if (regToken) {
        const legacyParsed = legacy ? parseBarcode(legacy) : null;
        return Object.assign({ token: regToken }, legacyParsed || {});
      }
      token = legacy || token;
    }
  } catch (e) {}
  if (/^REG_[A-Za-z0-9]{10,}$/i.test(token)) return { token };
  // Support new format: ATT-X-DY-PZZZZZZ
  const mNew = token.match(/^ATT-(\d+)-D([12])-P(\d{6})$/i);
  if (mNew) return { empId: parseInt(mNew[1], 10), slot: parseInt(mNew[2], 10), pin: mNew[3] };
  // Support old format: ATT-X-DY
  const m = token.match(/^ATT-(\d+)-D([12])$/i);
  if (!m) return null;
  return { empId: parseInt(m[1], 10), slot: parseInt(m[2], 10), pin: null };
}

function getDevice(emp, slot) { normalizeEmployee(emp); return emp.devices.find(d => d.slot === slot); }

function applyBarcodeIp(empId, slot, ip, fingerprint, pin) {
  const emp = employees.find(e => e.id === empId);
  if (!emp) return false;
  const dev = getDevice(emp, slot);
  if (ip) dev.ip = ip.trim();
  if (fingerprint) dev.fingerprint = fingerprint;
  if (pin) dev.pin = pin;
  dev.deviceInfo = getDeviceInfo();
  dev.last_login = new Date().toISOString();
  if (!dev.linked_at) dev.linked_at = dev.last_login;
  if (!dev.tokenUsedAt) dev.tokenUsedAt = dev.last_login;
  saveData();
  persistEmployeeNow(emp);
  return true;
}

function linkDeviceToEmployee(emp, dev, ip, fingerprint) {
  if (!emp || !dev || !fingerprint) return { ok: false, message: 'تعذر قراءة بصمة الجهاز' };
  if (dev.fingerprint && dev.fingerprint !== fingerprint) {
    return { ok: false, message: 'هذا الـ QR مستخدم لجهاز آخر. امسح بيانات هذا الجهاز من بطاقة الموظف إذا أردت الاستبدال.' };
  }
  dev.fingerprint = fingerprint;
  dev.ip = ip || dev.ip || '';
  try {
  dev.deviceInfo = getDeviceInfo();
  } catch (e) {
    dev.deviceInfo = { userAgent: navigator.userAgent || '' };
  }
  dev.last_login = new Date().toISOString();
  if (!dev.linked_at) dev.linked_at = dev.last_login;
  if (!dev.tokenUsedAt) dev.tokenUsedAt = dev.last_login;
  ensureEmployeeTenantContext(emp);
  emp._freshDevices = true;
  markEmployeeSessionActive(emp.id, dev.slot);
  try {
    if (typeof saveData === 'function') saveData();
  } catch (e) {
    console.warn('saveData during device link:', e);
  }
  if (typeof persistEmployeeNow === 'function') {
    persistEmployeeNow(emp).catch(function (err) { console.warn('persistEmployeeNow:', err); });
  }
  return { ok: true, emp: emp, dev: dev };
}
function ensureQrBox(elementId) {
  let el = document.getElementById(elementId);
  if (!el) return null;
  if (el.tagName === 'CANVAS') {
    const wrap = el.parentElement;
    if (!wrap) return null;
    const box = document.createElement('di' + 'v');
    box.id = elementId;
    box.className = 'qr-mini';
    wrap.replaceChild(box, el);
    el = box;
  }
  if (!el.classList.contains('qr-mini')) el.classList.add('qr-mini');
  return el;
}

function qrImgFallback(box, text) {
  const img = document.createElement('img');
  img.className = 'qr-img';
  img.width = 128;
  img.height = 128;
  img.alt = 'QR Code';
  img.onload = () => { box.dataset.qrReady = '1'; };
  img.onerror = () => {
    box.innerHTML = '<span style="font-size:12px;color:#fc8181">تعذّر تحميل QR — تحقق من الإنترنت</span>';
  };
  img.src = 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&margin=10&data=' + encodeURIComponent(text);
  box.appendChild(img);
}

function renderQrCodeWithPayload(elementId, payload) {
  if (!payload) return;
  const box = ensureQrBox(elementId);
  if (!box) return;
  if (box.dataset.qrPayload === payload && box.dataset.qrReady === '1') return;
  box.dataset.qrPayload = payload;
  box.innerHTML = '<span style="font-size:11px;color:var(--text-muted)">…</span>';
  box.dataset.qrReady = '0';

  const finishWithImg = () => {
    if (box.dataset.qrReady === '1') return;
    box.innerHTML = '';
    qrImgFallback(box, payload);
  };

  const tryQrcodeJs = () => {
    if (typeof QRCode === 'undefined' || !QRCode.CorrectLevel) return false;
    try {
      box.innerHTML = '';
      const holder = document.createElement('di' + 'v');
      holder.style.cssText = 'line-height:0;display:flex;justify-content:center';
      box.appendChild(holder);
      new QRCode(holder, {
        text: payload,
        width: 128,
        height: 128,
        colorDark: '#0a1628',
        colorLight: '#ffffff',
        correctLevel: QRCode.CorrectLevel.M
      });
      // QRCode.js creates canvas (sync) + img (shown via addEventListener, not onload).
      // Remove the img element entirely so only the canvas remains visible.
      const canvas = holder.querySelector('canvas');
      const img = holder.querySelector('img');
      if (canvas) {
        canvas.style.cssText = 'display:block;margin:0 auto';
        if (img) img.remove(); // حذف كامل بدلاً من الإخفاء فقط
        box.dataset.qrReady = '1';
        return true;
      }
      if (img && img.src) {
        img.style.cssText = 'display:block;margin:0 auto';
        box.dataset.qrReady = '1';
        return true;
      }
    } catch (e) { console.warn('QRCode.js:', e); }
    return false;
  };

  const render = function () {
    if (tryQrcodeJs()) return;
    finishWithImg();
  };

  if (typeof ensureQrcodeLoaded === 'function') {
    ensureQrcodeLoaded().then(render).catch(function () { finishWithImg(); });
    return;
  }
  render();
}

function renderQrCode(elementId, code) {
  if (!code) return;
  const parsed = parseBarcode(code);
  const empList = window.employees || [];
  const emp = parsed && parsed.empId ? empList.find(e => e.id === parsed.empId) : null;
  if (emp && currentUser === 'admin' && typeof prepareQrPayloadForEmployee === 'function') {
    prepareQrPayloadForEmployee(code, emp).then(function (payload) {
      renderQrCodeWithPayload(elementId, payload);
    }).catch(function () {
      renderQrCodeWithPayload(elementId, getQrPayload(code));
    });
    return;
  }
  renderQrCodeWithPayload(elementId, getQrPayload(code));
}
function openBarcodeModal(desc, onScan) {
  barcodeScanContext = { onScan };
  document.getElementById('barcode-modal-desc').textContent = desc || '';
  const res = document.getElementById('scan-result-ip');
  res.classList.remove('show'); res.textContent = '';
  const inp = document.getElementById('barcode-scan-input');
  inp.value = '';
  const pinInp = document.getElementById('barcode-pin-input');
  if (pinInp) pinInp.value = '';
  const fpDisplay = document.getElementById('barcode-fp-display');
  if (fpDisplay) fpDisplay.textContent = getDeviceFingerprint();
  document.getElementById('barcode-modal').classList.add('open');
  setTimeout(() => inp.focus(), 200);
}
function closeBarcodeModal() {
  document.getElementById('barcode-modal').classList.remove('open');
  barcodeScanContext = null;
}
async function handleBarcodeScanned(code) {
  const parsed = parseBarcode(code);
  if (!parsed) { Swal.fire({ icon: 'error', title: 'رمز QR غير صالح', text: code, ...swalTheme() }); return; }
  const target = parsed.token ? findDeviceByToken(parsed.token) : null;
  const emp = target?.emp || (parsed.empId ? employees.find(e => e.id === parsed.empId) : null);
  const dev = target?.dev || (emp && parsed.slot ? getDevice(emp, parsed.slot) : null);
  if (!emp || !dev) { Swal.fire({ icon: 'error', title: 'QR غير معروف', text: 'لم يتم العثور على الموظف أو الجهاز', ...swalTheme() }); return; }
  const ip = await fetchClientIp();
  const fp = getDeviceFingerprint();
  const linked = linkDeviceToEmployee(emp, dev, ip || '', fp);
  if (!linked.ok) { Swal.fire({ icon: 'error', title: 'تعذر الربط', text: linked.message, ...swalTheme() }); return; }
  const statusParts = [];
  if (ip) statusParts.push('IP: ' + esc(ip));
  statusParts.push('بصمة: ' + esc(fp));
  document.getElementById('scan-result-ip').innerHTML = '✅ تم ربط الجهاز<br><span style="font-size:11px;direction:ltr">' + statusParts.join(' | ') + '</span>';
  document.getElementById('scan-result-ip').classList.add('show');
  if (typeof sb_upsertEmployee === 'function') {
    try { await sb_upsertEmployee(emp, { requireExisting: true }); } catch (e) { console.warn('Supabase device update failed:', e); }
  }
  if (typeof sb_refreshEmployeeDevices === 'function') {
    try { await sb_refreshEmployeeDevices(emp.id); } catch (e) { console.warn('sb_refreshEmployeeDevices:', e); }
  }
  if (typeof saveData === 'function') saveData();
  if (barcodeScanContext?.onScan) barcodeScanContext.onScan(emp.id, dev.slot, ip, fp);
  Swal.fire({ icon: 'success', title: 'تم ربط الجهاز', html: esc(emp?.name || '') + '<br>' + esc(dev?.label || '') + '<br><b style="direction:ltr;color:#68d391;font-size:13px">بصمة: ' + esc(fp) + '</b>' + (ip ? '<br><span style="direction:ltr;color:#63b3ed;font-size:12px">IP: ' + esc(ip) + '</span>' : ''), ...swalTheme(), timer: 3000, showConfirmButton: false });
  refreshAll();
  setTimeout(closeBarcodeModal, 600);
}

async function handlePinEntry(pin) {
  if (!pin || pin.length !== 6) { Swal.fire({ icon: 'error', title: 'PIN غير صالح', text: 'أدخل 6 أرقام', ...swalTheme() }); return; }
  const emp = findEmployeeByPin(pin);
  if (!emp) { Swal.fire({ icon: 'error', title: 'PIN غير مسجّل', text: 'لم يتم العثور على جهاز مرتبط بهذا الرمز', ...swalTheme() }); return; }
  const dev = emp.devices.find(d => d.pin === pin);
  if (!dev) return;
  const fp = getDeviceFingerprint();
  const ip = currentClientIp || await fetchClientIp();
  currentClientIp = ip;
  // Update fingerprint and IP for this device
  applyBarcodeIp(emp.id, dev.slot, ip || '', fp, pin);
  document.getElementById('scan-result-ip').innerHTML = '✅ تم ربط الجهاز<br><span style="font-size:11px">' + esc(emp.name) + ' — ' + esc(dev.label) + '</span>';
  document.getElementById('scan-result-ip').classList.add('show');
  if (barcodeScanContext?.onScan) barcodeScanContext.onScan(emp.id, dev.slot, ip, fp);
  Swal.fire({ icon: 'success', title: 'تم ربط الجهاز', html: esc(emp.name) + '<br>' + esc(dev.label) + '<br><b style="direction:ltr;color:#68d391;font-size:13px">بصمة: ' + esc(fp) + '</b>' + (ip ? '<br><span style="direction:ltr;color:#63b3ed;font-size:12px">IP: ' + esc(ip) + '</span>' : ''), ...swalTheme(), timer: 3000, showConfirmButton: false });
  refreshAll();
  setTimeout(closeBarcodeModal, 600);
}

function startBarcodeScanForForm(slot) {
  const empId = parseInt(document.getElementById('emp-form-id')?.value || '0', 10);
  if (!empId) { Swal.fire({ icon: 'info', title: 'احفظ الموظف أولاً', text: 'أضف الموظف ثم عد للتعديل لتسجيل QR', ...swalTheme() }); return; }
  openBarcodeModal('أو امسح QR من كاميرا الهاتف ' + (slot === 1 ? 'الأول' : 'الثاني'), (id, s, ip, fp) => {
    const inp = document.getElementById('emp-ip-' + s);
    if (inp) inp.value = ip || '';
    const fpInp = document.getElementById('emp-fp-' + s);
    if (fpInp) fpInp.value = fp || '';
    const emp = employees.find(e => e.id === id);
    const dev = emp ? getDevice(emp, s) : null;
    renderQrCode('qr-form-' + s, dev?.barcode || genBarcode(id, s));
    const c = document.getElementById('bc-code-' + s);
    if (c) c.textContent = dev?.token || genBarcode(id, s);
  });
}

function showEmployeeBarcodes(id) {
  const e = employees.find(x => x.id === id);
  if (!e) return;
  normalizeEmployee(e);
  const H = 'di' + 'v';
  let html = '<div id="qr-cloud-status" style="font-size:12px;color:var(--text-muted);margin-bottom:10px;text-align:center">…</div>';
  e.devices.forEach(d => {
    const linkCode = d.token ? getRegistrationUrl(d.token, d.barcode) : '';
    html += '<' + H + ' style="margin-bottom:18px;padding:12px;border:1px solid var(--border);border-radius:12px;text-align:center">';
    html += '<' + H + ' style="font-weight:700;color:var(--accent)">' + esc(d.label) + '</' + H + '>';
    html += '<' + H + ' id="qr-view-' + d.slot + '" class="qr-mini"></' + H + '>';
    html += '<' + H + ' class="qr-code-label">' + esc(d.token || d.barcode) + '</' + H + '>';
    if (linkCode) {
      html += '<' + H + ' style="margin:8px 0;padding:10px;background:rgba(244,161,0,0.1);border:1px solid rgba(244,161,0,0.3);border-radius:10px">';
      html += '<' + H + ' style="font-size:10px;color:var(--text-muted);margin-bottom:4px">رابط احتياطي — يفتح على هاتف الموظف ويسجّل الجهاز</' + H + '>';
      html += '<input type="text" readonly id="reg-link-' + d.slot + '" value="' + escAttr(linkCode) + '" style="width:100%;box-sizing:border-box;font-size:11px;direction:ltr;text-align:left;margin-top:6px;padding:8px;border-radius:8px;border:1px solid rgba(244,161,0,0.35);background:rgba(0,0,0,0.2);color:#f6e05e" onclick="this.select()">';
      html += '<button type="button" class="btn-sm btn-primary" style="margin-top:8px;font-size:11px;width:100%" onclick="copyRegistrationLink(document.getElementById(\'reg-link-' + d.slot + '\').value)"><i class="fa fa-copy"></i> نسخ الرابط للموظف</button>';
      html += '</' + H + '>';
    }
    html += '<' + H + ' class="qr-scan-hint">امسح QR من هاتف الموظف لتسجيل IP تلقائياً</' + H + '>';
    const statusLines = [];
    if (d.fingerprint) statusLines.push('بصمة: <b style="color:#68d391">' + esc(d.fingerprint) + '</b>');
    if (d.ip) statusLines.push('IP: <b style="color:#63b3ed">' + esc(d.ip) + '</b>');
    html += '<' + H + ' style="font-size:12px;direction:ltr;margin-top:6px;line-height:2">' + (statusLines.length ? statusLines.join('<br>') : '<span style="color:#fc8181">لم يُسجَّل بعد</span>') + '</' + H + '>';
    html += '</' + H + '>';
  });
  Swal.fire({ title: 'رمز QR — ' + esc(e.name), html: html, width: 400, ...swalTheme(), confirmButtonText: 'إغلاق',
    didOpen: function () {
      setTimeout(async function () {
        pauseRemoteSync(8000);
        window.__basmaDisableAutoSync = true;
        var statusEl = document.getElementById('qr-cloud-status');
        if (statusEl) statusEl.textContent = 'جارٍ تفعيل QR في السحابة...';
        try {
          var qrReady = await ensureEmployeeCloudQrReady(e, { retries: 6, slot: 1 });
          if (!qrReady.ok) {
            if (statusEl) {
              statusEl.innerHTML = '<span style="color:#fc8181">تعذّر تفعيل QR — ' + esc(describeSupabaseSaveError(qrReady.reason)) + '</span>';
            }
            Swal.showValidationMessage('لم يُرفع QR للسحابة — أعد تسجيل الدخول ثم حاول مرة أخرى');
            return;
          }
          if (statusEl) {
            statusEl.innerHTML = '<span style="color:#68d391">✓ QR جاهز للمسح من الهاتف</span>';
          }
          for (var i = 0; i < e.devices.length; i++) {
            var d = e.devices[i];
            ensureDeviceToken(e, d);
            var payload = await prepareQrPayloadForEmployee(d.barcode, e);
            renderQrCodeWithPayload('qr-view-' + d.slot, payload);
            var linkInp = document.getElementById('reg-link-' + d.slot);
            if (linkInp) linkInp.value = payload;
          }
        } catch (err) {
          console.warn('showEmployeeBarcodes:', err);
          if (statusEl) statusEl.innerHTML = '<span style="color:#fc8181">خطأ في تجهيز QR</span>';
        } finally {
          window.__basmaDisableAutoSync = false;
          resumeRemoteSync(4000);
        }
      }, 200);
    } });
}

function hasQrRegistrationParams() {
  try {
    var rawSearch = String(window.location.search || '');
    rawSearch = rawSearch.replace(/\u00AE=/gi, '&code=').replace(/®=/gi, '&code=').replace(/&reg=/gi, '&code=');
    var params = new URLSearchParams(rawSearch);
    return !!(params.get('token') || params.get('code') || params.get('reg') || params.get('pin'));
  } catch (e) {
    return false;
  }
}

function beginQrRegistrationContext() {
  window.__basmaQrRegistrationInProgress = true;
  currentUser = null;
  window.loggedInEmpId = null;
  checkedIn = false;
  checkInTime = null;
  if (typeof clearRegisteredDeviceCache === 'function') clearRegisteredDeviceCache();
  window.__basmaDeviceFp = null;
}

async function checkQrRegisterFromUrl() {
  try {
    var rawSearch = window.location.search || '';
    rawSearch = rawSearch.replace(/\u00AE=/gi, '&code=').replace(/®=/gi, '&code=').replace(/&reg=/gi, '&code=');
    const params = new URLSearchParams(rawSearch);
    let token = params.get('token');
    const reg = params.get('code') || params.get('reg');
    const pin = params.get('pin');
    if (!token && !reg && !pin) return false;
    beginQrRegistrationContext();
    if (token) {
      var tokClean = String(token).match(/^(REG_[A-Za-z0-9]{10,})/i);
      if (tokClean) token = tokClean[1];
    }
    // لا نحمّل بيانات الموظفين المحلية هنا حتى لا يلتقط الهاتف موظفاً قديماً محفوظاً في المتصفح.
    window.employees = [];
    ensureEmployeesArray();
    // Clean URL before showing overlay (prevents re-trigger on reload)
    history.replaceState({}, '', window.location.pathname + window.location.hash);
    const code = reg || '';
    const pinVal = pin || '';
    let fullCode = pinVal ? (code + '-P' + pinVal) : code;
    if (token) {
      fullCode = '?token=' + encodeURIComponent(token) + (code ? '&code=' + encodeURIComponent(code) : '');
    }
    if (!fullCode) return false;
    showPhoneRegistrationPage();
    setTimeout(function () {
      const inp = document.getElementById('phone-reg-code');
      if (inp) inp.value = fullCode;
      doPhoneRegistration();
    }, 800);
    return true;
  } catch (e) {
    console.warn('checkQrRegisterFromUrl error:', e);
    return false;
  }
}

var EMP_DEVICE_SESSION_KEY = 'basma_emp_device_session';

function restoreEmployeeDeviceSession() {
  if (window.__basmaEmpSession && window.__basmaEmpSession.active && window.__basmaEmpSession.empId) {
    return window.__basmaEmpSession;
  }
  try {
    var raw = localStorage.getItem(EMP_DEVICE_SESSION_KEY) || sessionStorage.getItem(EMP_DEVICE_SESSION_KEY);
    if (!raw) return null;
    var parsed = JSON.parse(raw);
    if (!parsed || !parsed.empId) return null;
    window.__basmaEmpSession = {
      empId: parseInt(parsed.empId, 10) || null,
      slot: parseInt(parsed.slot, 10) || 1,
      companyId: parsed.companyId != null ? parseInt(parsed.companyId, 10) : null,
      fingerprint: parsed.fingerprint || null,
      active: true
    };
    if (parsed.fingerprint && /^DEVU?-/i.test(parsed.fingerprint)) {
      window.__basmaDeviceFp = String(parsed.fingerprint).toUpperCase();
      try { localStorage.setItem(DEVICE_FP_KEY, window.__basmaDeviceFp); } catch (e2) { /* ignore */ }
    }
    return window.__basmaEmpSession;
  } catch (e) {
    return null;
  }
}

function getCachedEmployeeSessionIds() {
  restoreEmployeeDeviceSession();
  var s = window.__basmaEmpSession;
  return {
    empId: s ? (parseInt(s.empId || '0', 10) || 0) : 0,
    slot: s ? (parseInt(s.slot || '0', 10) || 1) : 1,
    companyId: s && s.companyId != null ? (parseInt(s.companyId, 10) || 0) : 0,
    fingerprint: s && s.fingerprint ? s.fingerprint : ''
  };
}

function clearRegisteredDeviceCache() {
  window.__basmaEmpSession = null;
  _empFinanceRailRenderSig = '';
  window.__basmaEmpPortalBannerMsg = '';
  try {
    localStorage.removeItem(EMP_DEVICE_SESSION_KEY);
    sessionStorage.removeItem(EMP_DEVICE_SESSION_KEY);
    localStorage.removeItem('basma_registered_emp');
    localStorage.removeItem('basma_registered_slot');
    localStorage.removeItem('basma_emp_session');
    localStorage.removeItem('basma_employee_company_id');
  } catch (e) { /* ignore */ }
}

function ensureEmployeeTenantContext(emp) {
  if (!emp || emp.company_id == null) return false;
  var cid = parseInt(emp.company_id, 10);
  if (!cid || cid <= 0) return false;
  if (window.__basmaActiveCompanyId === cid) return true;
  window.__basmaActiveCompanyId = cid;
  if (window.__basmaCloudOnlyStorage) return true;
  if (typeof switchTenantDataStore === 'function') {
    switchTenantDataStore(cid, { savePrevious: true, resetSettings: false, skipLegacyMigrate: true });
  } else if (typeof loadData === 'function') {
    loadData();
    if (typeof filterLocalDataByCompany === 'function') filterLocalDataByCompany(cid);
  }
  return true;
}

async function ensureEmployeeFromServerAccess(empId, slot, fp, prof) {
  empId = parseInt(empId, 10);
  slot = parseInt(slot, 10) || 1;
  if (!empId || !prof || prof.ok !== true) return null;
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  if (!emp) {
    emp = {
      id: empId,
      name: prof.emp_name || 'موظف',
      dept: prof.dept || '—',
      role: '—',
      phone: '—',
      salary: 0,
      devices: [],
      company_id: prof.company_id || null
    };
    employees.push(emp);
  }
  if (typeof applyEmployeeClientProfile === 'function') applyEmployeeClientProfile(emp, prof);
  ensureEmployeeTenantContext(emp);
  normalizeEmployee(emp);
  var dev = getDevice(emp, slot);
  if (dev && fp) dev.fingerprint = fp;
  emp._freshDevices = true;
  if (typeof saveData === 'function') saveData();
  return emp;
}

function markEmployeeSessionActive(empId, slot, companyId) {
  empId = parseInt(empId, 10) || null;
  slot = parseInt(slot, 10) || 1;
  if (!companyId) {
    var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (localEmp && localEmp.company_id != null) companyId = parseInt(localEmp.company_id, 10);
  } else {
    companyId = parseInt(companyId, 10) || null;
  }
  var fp = window.__basmaDeviceFp || '';
  try {
    if (!fp && typeof getDeviceFingerprint === 'function') fp = getDeviceFingerprint();
  } catch (e0) { fp = fp || ''; }
  if (fp) {
    fp = String(fp).toUpperCase();
    window.__basmaDeviceFp = fp;
  }
  window.__basmaEmpSession = { empId: empId, slot: slot, companyId: companyId || null, fingerprint: fp || null, active: true };
  try {
    var payload = JSON.stringify({
      empId: empId,
      slot: slot,
      companyId: companyId || null,
      fingerprint: fp || null,
      ts: Date.now()
    });
    localStorage.setItem(EMP_DEVICE_SESSION_KEY, payload);
    sessionStorage.setItem(EMP_DEVICE_SESSION_KEY, payload);
    if (fp) localStorage.setItem(DEVICE_FP_KEY, fp);
    localStorage.setItem('basma_registered_emp', String(empId || ''));
    localStorage.setItem('basma_registered_slot', String(slot || 1));
  } catch (e) { /* ignore */ }
}

function hasActiveEmployeeSession() {
  return !!(window.__basmaEmpSession && window.__basmaEmpSession.active && window.__basmaEmpSession.empId);
}

function mergeLocalPendingEmployees(remoteEmps) {
  var cid = typeof safeActiveCompanyId === 'function' ? safeActiveCompanyId() : null;
  var remoteIds = {};
  (remoteEmps || []).forEach(function(e) { if (e && e.id) remoteIds[e.id] = true; });
  var merged = (remoteEmps || []).slice();
  var now = Date.now();
  (employees || []).forEach(function(local) {
    if (!local || !local.id || remoteIds[local.id]) return;
    if (typeof isEmployeeRecentlyDeleted === 'function' && isEmployeeRecentlyDeleted(local.id)) return;
    if (cid && local.company_id && parseInt(local.company_id, 10) !== parseInt(cid, 10)) return;
    if (cid && !local.company_id) return;
    if (local._pendingRemoteSync || (local._addedAt && (now - local._addedAt) < (typeof LOCAL_EMP_PREFER_MS !== 'undefined' ? LOCAL_EMP_PREFER_MS : 86400000))) {
      if (typeof clearEmployeeDeletedLocally === 'function') clearEmployeeDeletedLocally(local.id);
      merged.push(local);
    }
  });
  return merged;
}

function mergeLocalPendingAttendance(remoteAtts, mergedEmployees) {
  var cid = typeof safeActiveCompanyId === 'function' ? safeActiveCompanyId() : null;
  var remoteKeys = {};
  (remoteAtts || []).forEach(function (r) {
    if (r) remoteKeys[attendanceRecordKey(r)] = true;
  });
  var empIds = {};
  (mergedEmployees || []).forEach(function (e) { if (e && e.id) empIds[e.id] = true; });
  var merged = (remoteAtts || []).slice();
  (attData || []).forEach(function (local) {
    if (!local || !local.empId) return;
    if (cid && local.company_id && parseInt(local.company_id, 10) !== parseInt(cid, 10)) return;
    if (cid && !local.company_id) return;
    var key = attendanceRecordKey(local);
    if (!key || remoteKeys[key]) return;
    if (empIds[local.empId] && (local._pendingRemoteSync || local._addedAt || (local._localAttEditAt && (Date.now() - local._localAttEditAt) < 300000))) {
      merged.push(local);
    }
  });
  return dedupeAttendanceRecords(merged);
}

async function refreshEmployeeSubscriptionForEmp(emp) {
  if (!emp) return null;
  var cid = emp.company_id != null ? parseInt(emp.company_id, 10) : 0;
  if (!cid || typeof sb_checkSubscriptionStatus !== 'function') return null;
  try {
    var st = await sb_checkSubscriptionStatus(cid);
    if (st && typeof st === 'object') st._companyId = cid;
    if (typeof setSubscriptionStatus === 'function') setSubscriptionStatus(st);
    else { window._subscriptionStatus = st; }
    return st;
  } catch (e) {
    console.warn('refreshEmployeeSubscriptionForEmp:', e);
    return null;
  }
}

async function tryAutoAdoptBrowserFingerprint(fp, ip, options) {
  options = options || {};
  if (!fp || typeof sb_adoptBrowserFingerprint !== 'function') return null;
  var cached = typeof getCachedEmployeeSessionIds === 'function'
    ? getCachedEmployeeSessionIds()
    : { empId: 0, slot: 1, companyId: 0 };
  var token = options.token || null;
  if (!token && cached.empId) {
    var empLocal = (typeof employees !== 'undefined' ? employees : []).find(function (e) {
      return e && e.id === cached.empId;
    });
    if (empLocal && typeof getDevice === 'function') {
      var devTok = getDevice(empLocal, options.slot || cached.slot);
      if (devTok && devTok.token) token = devTok.token;
    }
  }
  var attempts = [];
  if (token) {
    attempts.push({ token: token, employeeId: options.employeeId || cached.empId || null, slot: options.slot || cached.slot || null });
  }
  if (cached.empId && cached.slot) {
    attempts.push({ employeeId: cached.empId, slot: cached.slot });
  }
  if (ip) attempts.push({});
  for (var i = 0; i < attempts.length; i++) {
    try {
      var adoptOpts = attempts[i];
      var adoptPromise = sb_adoptBrowserFingerprint(fp, ip, adoptOpts);
      var adopt = typeof withClientTimeout === 'function'
        ? await withClientTimeout(adoptPromise, 12000, 'browser_adopt')
        : await adoptPromise;
      if (adopt && adopt.ok === true) {
        markEmployeeSessionActive(adopt.employee_id, adopt.slot || 1, adopt.company_id);
        return adopt;
      }
    } catch (e) {
      console.warn('tryAutoAdoptBrowserFingerprint:', e);
    }
  }
  return null;
}

async function resolveRegisteredEmployeeFromServer(fp, ipRestrictOn) {
  fp = fp || (typeof getDeviceFingerprint === 'function' ? getDeviceFingerprint() : '');
  var cached = typeof getCachedEmployeeSessionIds === 'function'
    ? getCachedEmployeeSessionIds()
    : { empId: 0, slot: 1, companyId: 0 };
  if (cached.empId && typeof sb_verifyEmployeeDeviceAccess === 'function') {
    try {
      var cachedAccess = await sb_verifyEmployeeDeviceAccess(cached.empId, { fingerprint: fp, slot: cached.slot });
      if (cachedAccess && cachedAccess.ok === true && typeof ensureEmployeeFromServerAccess === 'function') {
        return ensureEmployeeFromServerAccess(cached.empId, cached.slot, fp, cachedAccess);
      }
    } catch (e) {
      console.warn('resolveRegisteredEmployeeFromServer cached:', e);
    }
  }
  if (!ipRestrictOn || !fp || typeof sb_resolveEmployeeByFingerprint !== 'function') return null;
  try {
    var resolved = await sb_resolveEmployeeByFingerprint(fp);
    if (!resolved || resolved.ok !== true || !resolved.employee_id) {
      if (typeof tryAutoAdoptBrowserFingerprint === 'function') {
        var adopted = await tryAutoAdoptBrowserFingerprint(fp, typeof currentClientIp !== 'undefined' ? currentClientIp : '');
        if (adopted) resolved = await sb_resolveEmployeeByFingerprint(fp);
      }
      if (!resolved || resolved.ok !== true || !resolved.employee_id) return null;
    }
    var slot = parseInt(resolved.slot, 10) || 1;
    markEmployeeSessionActive(resolved.employee_id, slot, resolved.company_id);
    if (typeof sb_verifyEmployeeDeviceAccess === 'function') {
      var access = await sb_verifyEmployeeDeviceAccess(resolved.employee_id, { fingerprint: fp, slot: slot });
      if (access && access.ok === true && typeof ensureEmployeeFromServerAccess === 'function') {
        return ensureEmployeeFromServerAccess(resolved.employee_id, slot, fp, access);
      }
    }
    var stub = {
      id: resolved.employee_id,
      name: resolved.emp_name || 'موظف',
      dept: resolved.dept || '—',
      role: '—',
      phone: '—',
      salary: 0,
      devices: [{ slot: slot, label: resolved.label || ('الهاتف ' + slot), fingerprint: fp }],
      company_id: resolved.company_id || null,
      remoteAttend: resolved.remote_attend === true
    };
    upsertEmployeeIntoStore(stub);
    if (typeof ensureEmployeeTenantContext === 'function') ensureEmployeeTenantContext(stub);
    return stub;
  } catch (e) {
    console.warn('resolveRegisteredEmployeeFromServer:', e);
    return null;
  }
}

async function refreshEmployeesFromSupabaseForEmployeeClient(reason) {
  var cached = typeof getCachedEmployeeSessionIds === 'function'
    ? getCachedEmployeeSessionIds()
    : { empId: 0, slot: 1, companyId: 0 };
  var cachedEmp = cached.empId;
  var cachedSlot = cached.slot;
  if (cachedEmp && typeof refreshEmployeeClientProfileById === 'function') {
    try {
      var refreshed = await refreshEmployeeClientProfileById(cachedEmp, { slot: cachedSlot });
      if (refreshed) {
        ensureEmployeeTenantContext(refreshed);
        return true;
      }
    } catch (e) {
      console.warn('employee profile verification failed:', e);
    }
  }
  if (typeof syncFromSupabase !== 'function' || typeof hasTenantSyncContext !== 'function') {
    return hasActiveEmployeeSession();
  }
  if (!hasTenantSyncContext()) return hasActiveEmployeeSession();
  var hasAdminJwt = typeof AuthApi !== 'undefined' && AuthApi.getCompanyId && AuthApi.getCompanyId();
  if (!hasAdminJwt) return hasActiveEmployeeSession();
  try {
    if (typeof initSupabase === 'function') initSupabase();
    const ok = await syncFromSupabase({ reason: reason || 'employee-device-verify' });
    if (ok !== true) return hasActiveEmployeeSession();
    return true;
  } catch (e) {
    console.warn('employee Supabase verification failed:', e);
    return hasActiveEmployeeSession();
  }
}

async function tryAutoEmployeeLogin() {
  try {
    if (currentUser) return true;
    if (typeof restoreEmployeeDeviceSession === 'function') restoreEmployeeDeviceSession();
    const cached = typeof getCachedEmployeeSessionIds === 'function'
      ? getCachedEmployeeSessionIds()
      : { empId: 0, slot: 1, companyId: 0 };
    const cachedEmp = cached.empId;
    const cachedSlot = cached.slot;
    const sessionActive = hasActiveEmployeeSession();
    const fp = getDeviceFingerprint();
    let ip = currentClientIp || '';
    let emp = cachedEmp ? employees.find(e => e.id === cachedEmp) : null;
    let dev = emp ? getDevice(emp, cachedSlot) : null;
    var ipRestrictOn = appSettings.ipRestrict !== false;

    if (!sessionActive && !cachedEmp && !emp) return false;

    if (sessionActive && cachedEmp && (!emp || !dev)) {
      try { await refreshEmployeesFromSupabaseForEmployeeClient('pre-auto-login'); } catch (e) {}
      emp = employees.find(e => e.id === cachedEmp) || emp;
      dev = emp ? getDevice(emp, cachedSlot) : null;
    } else if (!sessionActive) {
      const remoteVerified = await refreshEmployeesFromSupabaseForEmployeeClient('pre-auto-login');
      if (remoteVerified) {
        emp = employees.find(e => e.id === cachedEmp) || emp;
        dev = emp && cachedSlot ? getDevice(emp, cachedSlot) : null;
      }
    }

    if (!emp || !dev) {
      emp = findEmployeeByFingerprint(fp) || emp;
      dev = emp ? (emp.devices || []).find(d => d.fingerprint === fp) : dev;
      if (!dev && emp) dev = getDevice(emp, cachedSlot);
    }

    if (!emp && !ipRestrictOn && cachedEmp) {
      emp = employees.find(function (e) { return e && e.id === cachedEmp; }) || emp;
      if (emp) dev = getDevice(emp, cachedSlot) || { slot: cachedSlot || 1 };
    }
    if (!emp && !ipRestrictOn && employees.length === 1) {
      emp = employees[0];
      dev = getDevice(emp, cachedSlot || 1) || { slot: cachedSlot || 1 };
    }

    if (!emp || !dev) {
      var remoteEmp = (employees || []).find(function (e) { return e && e.remoteAttend && e.id === cachedEmp; });
      if (remoteEmp) {
        emp = remoteEmp;
        dev = getDevice(emp, cachedSlot) || { slot: cachedSlot || 1 };
      }
    }

    if (emp && typeof refreshEmployeeClientProfileById === 'function') {
      try {
        emp = await refreshEmployeeClientProfileById(emp.id) || emp;
        dev = getDevice(emp, dev ? dev.slot : cachedSlot) || dev;
      } catch (e) {
        console.warn('tryAutoEmployeeLogin profile refresh:', e);
      }
    }

    clearAdminSessionForEmployeeClient();

    if (emp && (emp.remoteAttend || !ipRestrictOn)) {
      dev = dev || getDevice(emp, cachedSlot) || { slot: cachedSlot || 1 };
    } else if (sessionActive && emp && dev) {
      if (fp && (!dev.fingerprint || dev.fingerprint !== fp)) dev.fingerprint = fp;
    } else if (dev && dev.fingerprint && dev.fingerprint !== fp && ipRestrictOn) {
      if (cachedEmp && typeof sb_verifyEmployeeDeviceAccess === 'function') {
        try {
          var access = await sb_verifyEmployeeDeviceAccess(cachedEmp, { fingerprint: fp, slot: cachedSlot });
          if (access && access.ok === true) {
            dev.fingerprint = fp;
          } else {
            emp = null;
            dev = null;
          }
        } catch (e) {
          emp = null;
          dev = null;
        }
      } else {
        emp = null;
        dev = null;
      }
    }

    if ((!emp || !dev) && cachedEmp && ipRestrictOn && typeof sb_verifyEmployeeDeviceAccess === 'function') {
      try {
        var serverAccess = await sb_verifyEmployeeDeviceAccess(cachedEmp, { fingerprint: fp, slot: cachedSlot });
        if (serverAccess && serverAccess.ok === true) {
          emp = await ensureEmployeeFromServerAccess(cachedEmp, cachedSlot, fp, serverAccess);
          dev = emp ? (getDevice(emp, cachedSlot) || { slot: cachedSlot || 1 }) : null;
        }
      } catch (e) {
        console.warn('tryAutoEmployeeLogin server verify:', e);
      }
    }

    if ((!emp || !dev) && ipRestrictOn && typeof resolveRegisteredEmployeeFromServer === 'function') {
      try {
        var resolvedEmp = await resolveRegisteredEmployeeFromServer(fp, ipRestrictOn);
        if (resolvedEmp) {
          emp = resolvedEmp;
          dev = getDevice(emp, cachedSlot) || (emp.devices || [])[0] || { slot: cachedSlot || 1 };
        }
      } catch (e) {
        console.warn('tryAutoEmployeeLogin fingerprint resolve:', e);
      }
    }

    if (!emp || !dev) {
      if (!sessionActive) clearRegisteredDeviceCache();
      return false;
    }

    if (emp && typeof sb_employeeLoginGate === 'function') {
      try {
        var autoGate = await sb_employeeLoginGate(emp.id);
        if (autoGate && autoGate.active === false) {
          emp.active = false;
          window.__basmaEmpLoginNotice = { title: 'تم إيقاف الحساب', text: (autoGate.message || SUSPENDED_MSG) };
          clearRegisteredDeviceCache();
          return false;
        }
        if (autoGate && autoGate.active === true) emp.active = true;
      } catch (e) {
        console.warn('tryAutoEmployeeLogin gate:', e);
      }
    }

    ip = ip || await fetchClientIp().catch(() => '');
    dev.last_login = new Date().toISOString();
    if (ip && dev.ip !== ip) dev.ip = ip;
    dev.deviceInfo = getDeviceInfo();
    markEmployeeSessionActive(emp.id, dev.slot, emp.company_id);
    currentClientIp = ip || currentClientIp;
    currentUser = 'emp';
    window.loggedInEmpId = emp.id;
    if (typeof clearAdminSessionForEmployeeClient === 'function') clearAdminSessionForEmployeeClient();
    if (typeof refreshEmployeeSubscriptionForEmp === 'function') {
      try { await refreshEmployeeSubscriptionForEmp(emp); } catch (e) {
        console.warn('tryAutoEmployeeLogin subscription refresh:', e);
      }
    }
    if (typeof refreshLoggedInEmployeeFromServer === 'function') {
      try { await refreshLoggedInEmployeeFromServer(); } catch (e) {
        console.warn('tryAutoEmployeeLogin profile refresh:', e);
      }
    }
    if (typeof refreshLoggedInEmployeeAttendance === 'function') {
      try { await refreshLoggedInEmployeeAttendance(); } catch (e) {
        console.warn('tryAutoEmployeeLogin attendance refresh:', e);
      }
    }
    if (typeof refreshLoggedInEmployeeNotifications === 'function') {
      try { await refreshLoggedInEmployeeNotifications(); } catch (e) {
        console.warn('tryAutoEmployeeLogin notifications refresh:', e);
      }
    }
    if (typeof refreshLoggedInEmployeeSalaryHistory === 'function') {
      try { await refreshLoggedInEmployeeSalaryHistory(); } catch (e) {
        console.warn('tryAutoEmployeeLogin salary history refresh:', e);
      }
    }
    upsertEmployeeIntoStore(emp);
    ensureEmployeeTenantContext(emp);
    saveData();
    launchApp();
    return true;
  } catch (e) {
    console.warn('tryAutoEmployeeLogin error:', e);
    if (hasActiveEmployeeSession()) return false;
    return false;
  }
}

async function runAutoLoginRestore() {
  if (window.__basmaQrRegistrationInProgress || (typeof hasQrRegistrationParams === 'function' && hasQrRegistrationParams())) return false;
  if (window.__basmaAutoLoginRestoreDone) return !!currentUser;
  if (_autoLoginRestoreRunning) return !!currentUser;
  if (currentUser) return true;
  var app = document.getElementById('app');
  if (app && app.style.display === 'block') return true;
  _autoLoginRestoreRunning = true;
  try {
    if (typeof hasActiveEmployeeSession === 'function' && hasActiveEmployeeSession()) {
      if (typeof clearAdminSessionForEmployeeClient === 'function') clearAdminSessionForEmployeeClient();
      var empRestored = await withClientTimeout(tryAutoEmployeeLogin(), 18000, 'auto_employee_login');
      if (empRestored) return true;
      return false;
    }
    var adminRestored = await tryAutoAdminLogin();
    if (adminRestored) return true;
    return await withClientTimeout(tryAutoEmployeeLogin(), 18000, 'auto_employee_login');
  } catch (e) {
    console.warn('runAutoLoginRestore:', e);
    return false;
  } finally {
    _autoLoginRestoreRunning = false;
    window.__basmaAutoLoginRestoreDone = true;
  }
}

function initAuth() {
  if (typeof initSupabase === 'function') initSupabase();
}

function initSession() {
  /* session.js registers BasmaSession at parse time */
}

function initPermissions() {
  if (typeof applyPermissionUi === 'function') applyPermissionUi(document);
}

function initRPC() {
  if (typeof BasmaRpcMode !== 'undefined') { /* flags loaded at parse time */ }
}

function initCloudSync() {
  if (typeof BasmaCloud !== 'undefined' && BasmaCloud.initCloudSync && currentUser) {
    BasmaCloud.initCloudSync();
  }
}

function initUIBindings() {
  if (typeof KYNO_UI_BINDINGS !== 'undefined' && KYNO_UI_BINDINGS.bindTopbarClicks) {
    KYNO_UI_BINDINGS.bindTopbarClicks();
  }
  if (typeof bindSidebarNavClicks === 'function') bindSidebarNavClicks();
  if (typeof bindSaActionClicks === 'function') bindSaActionClicks();
  if (typeof installShowPageBridge === 'function') installShowPageBridge();
}

function bindBarcodeInputs() {
  var scanInp = document.getElementById('barcode-scan-input');
  safeAddEvent(scanInp, 'keydown', function (e) {
    if (e.key === 'Enter') {
      e.preventDefault();
      var val = scanInp.value.trim();
      if (!val) return;
      if (/^\d{6}$/.test(val)) handlePinEntry(val);
      else handleBarcodeScanned(val);
    }
  });
  var pinInp = document.getElementById('barcode-pin-input');
  safeAddEvent(pinInp, 'keydown', function (e) {
    if (e.key === 'Enter') {
      e.preventDefault();
      var val = pinInp.value.trim();
      if (val) handlePinEntry(val);
    }
  });
}

function bindVisibilitySync() {
  safeAddEvent(document, 'visibilitychange', function () {
    if (document.visibilityState !== 'visible') return;
    if (currentUser === 'emp' && window.loggedInEmpId) {
      var tasks = [];
      if (typeof refreshLoggedInEmployeeFromServer === 'function') {
        tasks.push(refreshLoggedInEmployeeFromServer().catch(function (e) {
          console.warn('visibility profile refresh:', e);
        }));
      }
      if (typeof refreshLoggedInEmployeeAttendance === 'function') {
        tasks.push(refreshLoggedInEmployeeAttendance().catch(function (e) {
          console.warn('visibility attendance refresh:', e);
        }));
      }
      if (typeof refreshLoggedInEmployeeNotifications === 'function') {
        tasks.push(refreshLoggedInEmployeeNotifications().catch(function (e) {
          console.warn('visibility notifications refresh:', e);
        }));
      }
      if (typeof refreshLoggedInEmployeeSalaryHistory === 'function') {
        tasks.push(refreshLoggedInEmployeeSalaryHistory().catch(function (e) {
          console.warn('visibility salary history refresh:', e);
        }));
      }
      if (typeof syncLeavesFromSupabase === 'function') {
        tasks.push(syncLeavesFromSupabase({ empId: window.loggedInEmpId }).catch(function (e) {
          console.warn('visibility leaves refresh:', e);
        }));
      }
      Promise.all(tasks).then(function () {
        if (typeof buildEmpPortal === 'function') buildEmpPortal();
        if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
      });
      return;
    }
    if (typeof saasCurrentUser !== 'undefined' && saasCurrentUser &&
        typeof syncFromSupabase === 'function' && typeof hasTenantSyncContext === 'function' &&
        hasTenantSyncContext()) {
      if (typeof retryPendingNotifCloudSave === 'function') {
        retryPendingNotifCloudSave().catch(function (e) { console.warn('retry pending notif save:', e); });
      }
      syncFromSupabase({ realtime: true, reason: 'visibility' }).catch(function (e) {
        console.warn('visibility admin sync:', e);
      });
    }
  });
}

function bootstrapAppShell() {
  safeRun(function () { if (typeof restoreEmployeeDeviceSession === 'function') restoreEmployeeDeviceSession(); }, 'emp-session');
  safeRun(function () { initTheme(); }, 'theme');
  safeRun(function () { initAuth(); }, 'auth');
  safeRun(function () { initSession(); }, 'session');
  safeRun(function () { initPermissions(); }, 'permissions');
  safeRun(function () { initRPC(); }, 'rpc');
  safeRun(function () { initCloudSync(); }, 'cloud');
  safeRun(function () { initUIBindings(); }, 'ui');
  safeRun(function () { bindBarcodeInputs(); }, 'buttons');
  safeRun(function () { bindVisibilitySync(); }, 'visibility');
  safeRun(function () {
    var registrationHandledPromise = checkQrRegisterFromUrl();
    if (registrationHandledPromise && typeof registrationHandledPromise.then === 'function') {
      registrationHandledPromise.then(function (registrationHandled) {
        if (!registrationHandled) return runAutoLoginRestore();
      }).catch(function (e) {
        console.error('[MODULE FAILED] auto-login', e);
        window.__APP_SAFE_MODE = true;
        if (typeof applySafeMode === 'function') applySafeMode();
      }).finally(function () {
        if (typeof applySafeMode === 'function') applySafeMode();
      });
    }
  }, 'auto-login');
  if (typeof applySafeMode === 'function') applySafeMode();
}

document.addEventListener('DOMContentLoaded', function () {
  bootstrapAppShell();
});

// Auto-login restore runs once from bootstrapAppShell (checkQrRegisterFromUrl → runAutoLoginRestore).
// Removed duplicate window.load listener (Phase 1 / Task 2.2a).

// Notifications are now generated dynamically in buildNotifications()
let notifications = [];

const adminNav = [
  { id:'dashboard', icon:'fa-tachometer-alt', label:'لوحة التحكم' },
  { id:'employees', icon:'fa-users', label:'الموظفون' },
  { id:'attendance', icon:'fa-calendar-check', label:'الحضور والانصراف' },
  { id:'device-mgmt', icon:'fa-mobile-alt', label:'بصمة الأجهزة والتتبع' },
  { id:'leaves', icon:'fa-calendar-alt', label:'الإجازات والغياب' },
  { id:'salaries', icon:'fa-money-check-alt', label:'الرواتب' },
  { id:'finance', icon:'fa-wallet', label:'الخصومات والسلف' },
  { id:'org', icon:'fa-sitemap', label:'الأقسام والوظائف' },
  { id:'reports', icon:'fa-chart-bar', label:'التقارير' },
  { id:'notifications', icon:'fa-bell', label:'الإشعارات' },
  { id:'users-permissions', icon:'fa-user-shield', label:'المستخدمون والصلاحيات' },
  { id:'settings', icon:'fa-cog', label:'الإعدادات' },
];

const superAdminNav = [
  { id:'superadmin', icon:'fa-crown', label:'لوحة السوبر أدمن', section:'السوبر أدمن' },
  { id:'sa-companies', icon:'fa-building', label:'الشركات' },
  { id:'sa-subscriptions', icon:'fa-credit-card', label:'الاشتراكات' },
  { id:'sa-users', icon:'fa-user-shield', label:'المستخدمين' },
  { id:'sa-team', icon:'fa-users-cog', label:'فريق السوبر أدمن' },
  { id:'sa-platform', icon:'fa-bullhorn', label:'إعدادات المنصة' },
  { id:'sa-stats', icon:'fa-chart-line', label:'الإحصائيات' },
  { id:'sa-monitoring', icon:'fa-heartbeat', label:'System Monitoring' },
  { id:'sa-backup', icon:'fa-database', label:'Backup Center' },
  { id:'sa-settings', icon:'fa-cog', label:'الإعدادات' },
];

const empNav = [
  { id:'emp-home', icon:'fa-home', label:'الرئيسية' },
  { id:'emp-salary', icon:'fa-money-bill-wave', label:'الراتب' },
  { id:'emp-profile', icon:'fa-user-circle', label:'الملف الشخصي' },
  { id:'notifications', icon:'fa-bell', label:'الإشعارات' },
];

// currentUser, saasCurrentUser — on window via state.js
checkedIn = false; checkInTime = null;
window.charts = window.charts || {};
let _subscriptionStatus = null;
let _companyUsersCache = [];

// الصلاحيات التفصيلية — js/core/permission-matrix.js (hasActionPermission, permissionMatrixHtml, …)

function syncSaasSessionContext() {
  if (typeof window === 'undefined') return null;
  var u = window._saasCurrentUser || window.saasCurrentUser ||
    (typeof saasCurrentUser !== 'undefined' ? saasCurrentUser : null);
  if (u) {
    window._saasCurrentUser = u;
    window.saasCurrentUser = u;
    saasCurrentUser = u;
  }
  if (typeof currentUser !== 'undefined' && currentUser) window.currentUser = currentUser;
  return u;
}

function getSaasSessionUser() {
  syncSaasSessionContext();
  return window._saasCurrentUser || window.saasCurrentUser ||
    (typeof saasCurrentUser !== 'undefined' ? saasCurrentUser : null);
}

function clearStaleUiBlockers() {
  if (typeof document === 'undefined') return;
  if (typeof Swal !== 'undefined' && !window.__basmaPreserveSwal) {
    try {
      if (Swal.isVisible && Swal.isVisible()) Swal.close();
    } catch (e) { /* ignore */ }
  }
  document.querySelectorAll('.swal2-container').forEach(function (node) {
    if (!node.querySelector('.swal2-popup')) node.remove();
  });
  if (document.body) {
    document.body.classList.remove('swal2-shown', 'swal2-height-auto', 'swal2-no-backdrop');
    document.body.style.removeProperty('overflow');
    document.body.style.removeProperty('padding-right');
  }
  var phoneOv = document.getElementById('phone-reg-overlay');
  if (phoneOv) phoneOv.remove();
  if (window.__basmaLoggingOut) {
    var barcode = document.getElementById('barcode-modal');
    if (barcode) barcode.classList.remove('open');
  }
  if (typeof closeSidebar === 'function') closeSidebar();
  else {
    var ov = document.getElementById('sidebar-overlay');
    if (ov) {
      ov.classList.remove('show');
      ov.style.pointerEvents = 'none';
    }
    var sidebar = document.getElementById('sidebar');
    if (sidebar) sidebar.classList.remove('open');
  }
}

function ensureAppInteractive() {
  clearStaleUiBlockers();
  if (typeof document !== 'undefined' && document.body) {
    document.body.classList.add('app-active');
  }
  var lp = document.getElementById('login-page');
  if (lp) {
    lp.style.display = 'none';
    lp.style.pointerEvents = 'none';
    lp.style.visibility = 'hidden';
    lp.style.opacity = '0';
    lp.setAttribute('aria-hidden', 'true');
    if ('inert' in lp) lp.inert = true;
  }
  var app = document.getElementById('app');
  if (app) {
    app.style.display = 'block';
    app.style.pointerEvents = 'auto';
    app.removeAttribute('aria-hidden');
    if ('inert' in app) app.inert = false;
  }
  var ov = document.getElementById('sidebar-overlay');
  if (ov) {
    ov.classList.remove('show');
    ov.style.pointerEvents = 'none';
  }
  var sidebar = document.getElementById('sidebar');
  if (sidebar && window.innerWidth > 768) sidebar.classList.remove('open');
}

function showLoginPageAfterLogout() {
  clearStaleUiBlockers();
  var app = document.getElementById('app');
  if (app) {
    app.style.display = 'none';
    app.style.pointerEvents = 'none';
    app.setAttribute('aria-hidden', 'true');
    if ('inert' in app) app.inert = true;
  }
  var loginEl = document.getElementById('login-page');
  if (loginEl) {
    loginEl.style.display = 'flex';
    loginEl.style.pointerEvents = 'auto';
    loginEl.style.visibility = 'visible';
    loginEl.style.opacity = '1';
    loginEl.removeAttribute('aria-hidden');
    if ('inert' in loginEl) loginEl.inert = false;
  }
  if (typeof document !== 'undefined' && document.body) {
    document.body.classList.remove('app-active');
  }
  var username = document.getElementById('username');
  if (username && typeof username.focus === 'function') {
    setTimeout(function () { try { username.focus(); } catch (e) {} }, 50);
  }
}

function firstAllowedAdminPage() {
  syncSaasSessionContext();
  const first = adminNav.find(n => hasCompanyPermission(n.id));
  if (first) return first.id;
  var u = getSaasSessionUser();
  if (u && u.role === 'company_admin') return 'dashboard';
  return null;
}

function bindPermissionCards() {
  document.querySelectorAll('.perm-check').forEach(function (input) {
    var card = input.closest('.perm-card');
    if (!card) return;
    var sync = function () { card.classList.toggle('active', input.checked); };
    sync();
    safeAddEvent(input, 'change', sync);
  });
}

function launchApp() {
  safeRun(function () {
    if (window.__basmaModulesReady) {
      _runLaunchApp();
      return;
    }
    window.addEventListener('basma:modules-ready', _runLaunchApp, { once: true });
  }, 'launch-app');
  if (typeof applySafeMode === 'function') applySafeMode();
}

function _runLaunchApp() {
  window.__basmaLoggingOut = false;
  window.__basmaSilentSettingsSave = false;
  syncSaasSessionContext();
  ensureAppInteractive();
  var loginPage = document.getElementById('login-page');
  var appEl = document.getElementById('app');
  if (loginPage) loginPage.style.display = 'none';
  if (appEl) appEl.style.display = 'block';
  if (typeof BasmaCloud !== 'undefined' && BasmaCloud.initCloudSync) BasmaCloud.initCloudSync();
  if (typeof BasmaNetworkStatus !== 'undefined' && BasmaNetworkStatus.init) BasmaNetworkStatus.init();
  if (typeof BasmaNetworkStatus !== 'undefined' && BasmaNetworkStatus.probe) {
    setTimeout(function () { BasmaNetworkStatus.probe(true); }, 600);
  }
  if (typeof BasmaLeaveGuard !== 'undefined' && BasmaLeaveGuard.initLeaveGuard) BasmaLeaveGuard.initLeaveGuard();
  if (typeof setupSupabaseRealtime === 'function' && currentUser) {
    setupSupabaseRealtime().catch(function (e) { console.warn('setupSupabaseRealtime:', e); });
  }
  startClock();
  if (typeof initEmployeeNameFilters === 'function') initEmployeeNameFilters();

  if (typeof hydrateFinanceItemsFromCloud === 'function' && currentUser !== 'emp') {
    hydrateFinanceItemsFromCloud({ forceRemote: true, replace: true }).then(function () {
      if (document.getElementById('page-finance') && document.getElementById('page-finance').classList.contains('active') && typeof buildFinancePageNow === 'function') {
        buildFinancePageNow();
      }
    }).catch(function () {});
  }

  if (currentUser === 'emp') {
    document.querySelectorAll('.page').forEach(function (p) { p.classList.remove('active'); });
    setupNav();
    showPage('emp-home');
    (async function finishEmployeeLaunch() {
      if (typeof refreshEmployeeClientProfileById === 'function' && window.loggedInEmpId) {
        try { await refreshEmployeeClientProfileById(window.loggedInEmpId); } catch (e) {
          console.warn('refreshEmployeeClientProfileById:', e);
        }
      }
      if (typeof refreshLoggedInEmployeeAttendance === 'function' && window.loggedInEmpId) {
        try { await refreshLoggedInEmployeeAttendance(); } catch (e) {
          console.warn('refreshLoggedInEmployeeAttendance:', e);
        }
      }
      if (typeof refreshLoggedInEmployeeNotifications === 'function' && window.loggedInEmpId) {
        try { await refreshLoggedInEmployeeNotifications(); } catch (e) {
          console.warn('refreshLoggedInEmployeeNotifications:', e);
        }
      }
      if (typeof refreshLoggedInEmployeeSalaryHistory === 'function' && window.loggedInEmpId) {
        try { await refreshLoggedInEmployeeSalaryHistory(); } catch (e) {
          console.warn('refreshLoggedInEmployeeSalaryHistory:', e);
        }
      }
      var empUser = employees.find(function (e) { return e.id === window.loggedInEmpId; }) || employees[0];
      document.getElementById('sidebar-name').textContent = empUser ? empUser.name.split(' ').slice(0, 2).join(' ') : 'موظف';
      document.getElementById('sidebar-role').textContent = 'موظف';
      var sidebarAvatar = document.getElementById('sidebar-avatar');
      if (sidebarAvatar) {
        var avatarSafe = empUser ? sanitizeAvatarUrl(empUser.avatarUrl) : '';
        if (empUser && avatarSafe) {
          sidebarAvatar.innerHTML = '<img src="' + avatarSafe + '" style="width:100%;height:100%;object-fit:cover;border-radius:inherit">';
        } else {
          sidebarAvatar.textContent = empUser ? pickAvatar(empUser.name) : '؟';
        }
      }
      buildEmpPortal();
      buildNotifications();
      showPage('emp-home');
      if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
      if (typeof renderEmployeeBroadcastRail === 'function') renderEmployeeBroadcastRail();
      if (typeof startEmployeePortalPolling === 'function') startEmployeePortalPolling();
      if (typeof applyPermissionUi === 'function') applyPermissionUi();
    })();
    return;
  }

  if (currentUser === 'admin' && !window.__basmaTenantNeedsCloudReset) syncDepartmentsToSupabase();
  setupNav();
  buildDashboard();
  if (typeof buildEmployees === 'function') buildEmployees();
  if (typeof buildAttendance === 'function') buildAttendance();
  buildSalaries();
  buildNotifications();
  buildReports();
  syncSettingsUi();
  if (typeof applyPermissionUi === 'function') applyPermissionUi();
  setTimeout(clearStaleUiBlockers, 0);
  setTimeout(clearStaleUiBlockers, 350);
  (async function finishLaunch() {
    if (typeof sb_loadPlatformGlobals === 'function') {
      try { await sb_loadPlatformGlobals(); } catch (e) { console.warn('sb_loadPlatformGlobals:', e); }
    }
    if (typeof loadUserUiPreferences === 'function') {
      try { await loadUserUiPreferences(); } catch (e) { console.warn('loadUserUiPreferences:', e); }
    }
    if (typeof syncCompanySupportUi === 'function') syncCompanySupportUi();
  if (currentUser === 'admin') {
    const isSuperAdmin = saasCurrentUser && saasCurrentUser.role === 'super_admin';
      var companyName = (saasCurrentUser && saasCurrentUser.company_name) || appSettings.companyName || 'الشركة';
      document.getElementById('sidebar-name').textContent = isSuperAdmin
        ? (typeof getSuperAdminDisplayName === 'function' ? getSuperAdminDisplayName(saasCurrentUser) : (saasCurrentUser.username || 'Super Admin'))
        : (saasCurrentUser ? (saasCurrentUser.display_name || saasCurrentUser.username) : 'المسؤول');
      document.getElementById('sidebar-role').textContent = isSuperAdmin
        ? ('👑 ' + (typeof getSuperAdminJobTitle === 'function' && getSuperAdminJobTitle(saasCurrentUser) ? getSuperAdminJobTitle(saasCurrentUser) : 'مسؤول النظام'))
        : ((saasCurrentUser && saasCurrentUser.role === 'company_user') ? '👤 مستخدم شركة' : ('🏢 ' + companyName));
    document.getElementById('sidebar-avatar').textContent = isSuperAdmin ? '👑' : 'م';
      if (_isCompanySubscriptionTenant()) {
    _renderSubscriptionBanner();
        if (typeof maybeShowSubscriptionExpiryToast === 'function') maybeShowSubscriptionExpiryToast();
      } else {
        if (typeof clearSubscriptionClientState === 'function') clearSubscriptionClientState();
        else _removeSaasBanner();
      }
    if (isSuperAdmin) {
      if (typeof window.compactSuperAdminLocalStorage === 'function') {
        try { window.compactSuperAdminLocalStorage(); } catch (e) { console.warn('compactSuperAdminLocalStorage:', e); }
      }
      showPage('superadmin');
      buildSuperAdminDashboard();
    } else {
        if (typeof renderPlatformAnnouncementsRail === 'function') renderPlatformAnnouncementsRail();
        if (typeof startPlatformGlobalsPolling === 'function') startPlatformGlobalsPolling();
      var startPage = firstAllowedAdminPage();
      if (startPage) {
        showPage(startPage);
      } else {
        Swal.fire({
          icon: 'warning',
          title: 'لا صلاحيات',
          text: 'لم يُمنح حسابك صلاحية أي صفحة. تواصل مع مدير الشركة.',
          confirmButtonText: 'حسناً',
          ...swalTheme()
        });
      }
    }
  }
  })();
}

function doLogout() {
  var runLogoutConfirm = function () {
    Swal.fire({
      title:'تسجيل الخروج', text:'هل تريد تسجيل الخروج؟',
      icon:'question', showCancelButton:true,
      confirmButtonText:'نعم، خروج', cancelButtonText:'إلغاء',
      ...swalTheme(),
      confirmButtonColor:'#e53e3e', cancelButtonColor:'#00d4aa'
    }).then(function (r) {
      if (r.isConfirmed) {
        performLogout().catch(function (e) { console.warn('performLogout:', e); });
      }
    });
  };
  if (typeof BasmaLeaveGuard !== 'undefined' && BasmaLeaveGuard.confirmLogout) {
    BasmaLeaveGuard.confirmLogout(runLogoutConfirm);
  } else {
    runLogoutConfirm();
  }
}

async function performLogoutCloudSync(ctx, options) {
  options = options || {};
  var timeoutMs = options.timeoutMs != null ? options.timeoutMs : 1200;
  try {
    await Promise.race([
      performLogoutCloudSyncWork(ctx, options),
      new Promise(function (_, reject) {
        setTimeout(function () { reject(new Error('logout_sync_timeout')); }, timeoutMs);
      })
    ]);
    return true;
  } catch (e) {
    if (!e || e.message !== 'logout_sync_timeout') {
      console.warn('performLogoutCloudSync:', e.message || e);
    }
    return false;
  }
}

async function performLogoutCloudSyncWork(ctx) {
  if (typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession) {
    try {
      if (!(await AuthApi.hasAuthenticatedSession())) return;
    } catch (e) {
      return;
    }
  }
  var tasks = [];
  if (ctx.isSuper && typeof persistNotificationsNow === 'function') {
    tasks.push(persistNotificationsNow({ serverOnly: true, skipMerge: true, skipSessionRefresh: true, noPause: true, duringLogout: true }));
  } else if (ctx.isCompanyAdmin) {
    if (typeof sb_recordClientAudit === 'function') {
      tasks.push(sb_recordClientAudit({
        action: 'logout',
        category: 'system',
        details: ctx.logoutDetail,
        target_name: ctx.actorName || ''
      }));
    }
    if (typeof persistNotificationsNow === 'function') {
      tasks.push(persistNotificationsNow({ serverOnly: true, skipMerge: true, skipSessionRefresh: true, noPause: true, duringLogout: true }));
    }
  }
  if (!tasks.length) return;
  await Promise.all(tasks);
}

async function finishLogoutTransition(wasEmployee) {
  window.__basmaLoggingOut = true;
  window.__basmaDisableAutoSync = true;
  try {
    if (typeof BasmaCloud !== 'undefined' && BasmaCloud.stopPeriodicCloudSync) {
      BasmaCloud.stopPeriodicCloudSync();
    }
  } catch (e) { console.warn('stopPeriodicCloudSync:', e); }
  if (typeof stopEmployeePortalPolling === 'function') stopEmployeePortalPolling();
  showLoginPageAfterLogout();
  if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
  if (typeof renderEmployeeBroadcastRail === 'function') renderEmployeeBroadcastRail();
  try {
    if (typeof AuthApi !== 'undefined' && AuthApi.logoutLocal) {
      await AuthApi.logoutLocal();
    } else {
      currentUser = null;
      saasCurrentUser = null;
      window._saasCurrentUser = null;
      if (typeof AuthApi !== 'undefined' && AuthApi.clearJwtContext) AuthApi.clearJwtContext();
    }
  } catch (e) { console.warn('logoutLocal:', e); }
  window.loggedInEmpId = null;
  checkedIn = false;
  checkInTime = null;
  if (wasEmployee) clearRegisteredDeviceCache();
  else clearAdminSession();
  if (typeof clearTenantDataStore === 'function') clearTenantDataStore();
  if (typeof clearSubscriptionClientState === 'function') clearSubscriptionClientState();
  else {
    _subscriptionStatus = null;
    _removeSaasBanner();
  }
  if (typeof renderPlatformAnnouncementsRail === 'function') renderPlatformAnnouncementsRail();
  if (window._platformGlobalsPollTimer) {
    clearInterval(window._platformGlobalsPollTimer);
    window._platformGlobalsPollTimer = null;
  }
  Object.values(window.charts || {}).forEach(function (c) { try { c.destroy(); } catch (e) {} });
  window.charts = {};
  if (typeof syncWindowState === 'function') syncWindowState();
  window.__basmaLoggingOut = false;
  window.__basmaDisableAutoSync = false;
  showLoginPageAfterLogout();
}

var _handlingForeignSessionConflict = false;

/**
 * حماية من تسرّب بيانات بين الشركات: يُستدعى عندما يكتشف هذا التبويب أن جلسته
 * تبنّت خطأً هوية شركة/مستخدم مختلف (كوكي جلسة مشتركة تغيّرت بسبب تسجيل دخول
 * إلى شركة أخرى في تبويب آخر من نفس المتصفح). نقوم بتصفير محلي لهذا التبويب
 * فقط دون استدعاء تسجيل الخروج البعيد (الذي سيُبطل جلسة التبويب الآخر الصحيحة).
 */
async function handleForeignSessionConflict() {
  if (_handlingForeignSessionConflict) return;
  _handlingForeignSessionConflict = true;
  try {
    window.__basmaLoggingOut = true;
    window.__basmaDisableAutoSync = true;
    try {
      if (typeof BasmaCloud !== 'undefined' && BasmaCloud.stopPeriodicCloudSync) BasmaCloud.stopPeriodicCloudSync();
    } catch (e) { /* ignore */ }
    if (typeof stopEmployeePortalPolling === 'function') stopEmployeePortalPolling();
    try {
      if (typeof AuthApi !== 'undefined' && AuthApi.clearSupabaseSession) await AuthApi.clearSupabaseSession();
    } catch (e) { console.warn('handleForeignSessionConflict clearSupabaseSession:', e); }
    currentUser = null;
    saasCurrentUser = null;
    window._saasCurrentUser = null;
    window.loggedInEmpId = null;
    employees = [];
    attData = [];
    if (Array.isArray(window.leavesData)) window.leavesData = [];
    if (typeof clearAdminSession === 'function') clearAdminSession();
    if (typeof clearTenantDataStore === 'function') clearTenantDataStore();
    if (typeof syncWindowState === 'function') syncWindowState();
    showLoginPageAfterLogout();
  } finally {
    window.__basmaLoggingOut = false;
    window.__basmaDisableAutoSync = false;
  }
  setTimeout(function () {
    if (typeof Swal !== 'undefined') {
      Swal.fire({
        icon: 'warning',
        title: 'يجب تسجيل الدخول من جديد',
        text: 'تم تسجيل الدخول إلى شركة أخرى من هذا المتصفح، لذلك أُنهيت جلسة هذا التبويب حمايةً لبيانات الشركات. سجّل الدخول مرة أخرى هنا للمتابعة.',
        confirmButtonText: 'حسناً',
        ...(typeof swalTheme === 'function' ? swalTheme() : {})
      });
    }
  }, 150);
}
window.handleForeignSessionConflict = handleForeignSessionConflict;

async function performLogout() {
  delete window.__basmaPortalVisitLogged;
  if (typeof BasmaCloud !== 'undefined' && BasmaCloud.stopPeriodicCloudSync) {
    BasmaCloud.stopPeriodicCloudSync();
  }
  const wasEmployee = currentUser === 'emp' || window.loggedInEmpId;
  var isSuper = !!(saasCurrentUser && saasCurrentUser.role === 'super_admin');
  var isCompanyAdmin = currentUser === 'admin' && !isSuper && !wasEmployee;
  var actor = typeof getActorInfo === 'function' ? getActorInfo() : { name: 'مستخدم' };
  var logoutDetail = wasEmployee
    ? ('تسجيل خروج موظف: ' + actor.name)
    : ('تسجيل خروج: ' + actor.name);

  if (typeof logActivity === 'function') {
    logActivity('logout', 'system', logoutDetail, { deferSave: true, skipCloudAudit: true, skipPersistSchedule: true });
  }

  if (isCompanyAdmin || isSuper) {
    await performLogoutCloudSync({
      isSuper: isSuper,
      isCompanyAdmin: isCompanyAdmin,
      logoutDetail: logoutDetail,
      actorName: actor.name || ''
    }, { timeoutMs: isSuper ? 900 : 1500 });
  }

  window.__basmaLoggingOut = true;
  window.__basmaDisableAutoSync = true;
  try {
    await finishLogoutTransition(wasEmployee);
  } catch (e) {
    console.warn('finishLogoutTransition:', e);
    window.__basmaLoggingOut = false;
    window.__basmaDisableAutoSync = false;
    showLoginPageAfterLogout();
  }
}

// ======= NAV =======
function setupNav() {
  syncSaasSessionContext();
  var sessionUser = getSaasSessionUser();
  const isSuperAdmin = sessionUser && sessionUser.role === 'super_admin';
  let nav, el = document.getElementById('sidebar-nav');
  if (!el) {
    console.warn('setupNav: #sidebar-nav not found');
    return;
  }
  if (typeof syncCompanySupportUi === 'function') syncCompanySupportUi();
  if (currentUser !== 'admin') {
    nav = empNav;
    el.innerHTML = '<div class="nav-section-title">القائمة الرئيسية</div>' +
      nav.map(n => `<div class="nav-item" data-page="${n.id}" id="nav-${n.id}"><i class="fa ${n.icon}"></i> ${n.label}${n.badge ? `<span class="nav-badge">${n.badge}</span>` : ''}</div>`).join('');
    if (typeof bindSidebarNavClicks === 'function') bindSidebarNavClicks();
    return;
  }
  if (isSuperAdmin) {
    var saNavItems = superAdminNav.filter(function (n) {
      return typeof canSuperAdminPage !== 'function' || canSuperAdminPage(n.id);
    });
    if (!saNavItems.length) saNavItems = superAdminNav.slice(0, 1);
    el.innerHTML = '<div class="nav-section-title">لوحة السوبر أدمن</div>' +
      saNavItems.map(n => `<div class="nav-item" data-page="${n.id}" id="nav-${n.id}"><i class="fa ${n.icon}"></i> ${n.label}</div>`).join('');
  } else {
    nav = adminNav.filter(n => hasCompanyPermission(n.id));
    el.innerHTML = '<div class="nav-section-title">القائمة الرئيسية</div>' +
      nav.map(n => `<div class="nav-item" data-page="${n.id}" id="nav-${n.id}"><i class="fa ${n.icon}"></i> ${n.label}${n.badge ? `<span class="nav-badge">${n.badge}</span>` : ''}</div>`).join('');
  }
  if (typeof bindSidebarNavClicks === 'function') bindSidebarNavClicks();
}

function safeBuildPage(fnName) {
  var fn = typeof window !== 'undefined' ? window[fnName] : null;
  if (typeof fn !== 'function') fn = (typeof globalThis !== 'undefined' && globalThis[fnName]) || null;
  if (typeof fn !== 'function') {
    try { fn = eval('typeof ' + fnName + " === 'function' ? " + fnName + ' : null'); } catch (e) { fn = null; }
  }
  if (typeof fn !== 'function') {
    console.warn('safeBuildPage: missing', fnName);
    if (typeof Swal !== 'undefined') {
      Swal.fire({
        icon: 'error',
        title: 'خطأ في تحميل الصفحة',
        text: 'الدالة ' + fnName + ' غير متاحة — حدّث الصفحة (Ctrl+Shift+R)',
        ...swalTheme()
      });
    }
    return;
  }
  try {
    var r = fn();
    if (r && typeof r.catch === 'function') {
      r.catch(function (e) {
        console.warn(fnName + ':', e);
        if (typeof Swal !== 'undefined') {
          Swal.fire({ icon: 'error', title: 'فشل بناء الصفحة', text: String(e.message || e), ...swalTheme() });
        }
      });
    }
  } catch (e) {
    console.warn(fnName + ':', e);
    if (typeof Swal !== 'undefined') {
      Swal.fire({ icon: 'error', title: 'فشل بناء الصفحة', text: String(e.message || e), ...swalTheme() });
    }
  }
}

function showPage(id) {
  if (typeof window !== 'undefined') {
    if (window.__basmaLoggingOut) return;
  }
  syncSaasSessionContext();
  var sessionUser = getSaasSessionUser();
  if (typeof BasmaPermissions !== 'undefined' && !BasmaPermissions.requireAuth(id)) return;
  var subscriptionPages = ['dashboard', 'employees', 'attendance', 'device-mgmt', 'leaves', 'salaries', 'finance', 'org', 'reports', 'notifications', 'users-permissions', 'settings', 'emp-salary'];
  if (typeof blockIfSubscriptionInactive === 'function' && subscriptionPages.indexOf(id) >= 0) {
    var pageTitles = { dashboard: 'لوحة التحكم', employees: 'الموظفون', attendance: 'الحضور', salaries: 'الرواتب', finance: 'المالية', reports: 'التقارير', 'emp-salary': 'الراتب', notifications: 'الإشعارات' };
    if (blockIfSubscriptionInactive(pageTitles[id] || id)) return;
  }
  var superAdminOnlyPages = ['superadmin', 'sa-companies', 'sa-subscriptions', 'sa-users', 'sa-team', 'sa-platform', 'sa-stats', 'sa-monitoring', 'sa-backup', 'sa-settings', 'notifications'];
  if (currentUser === 'admin' && sessionUser && sessionUser.role === 'super_admin') {
    if (typeof canSuperAdminPage === 'function' && !canSuperAdminPage(id)) {
      Swal.fire({ icon:'warning', title:'غير مصرح', text:'لا تملك صلاحية الوصول إلى هذه الصفحة', ...swalTheme() });
      id = 'superadmin';
    }
    if (superAdminOnlyPages.indexOf(id) < 0) {
      id = 'superadmin';
    }
  }
  if (currentUser === 'admin' && (!sessionUser || sessionUser.role !== 'super_admin') && !hasCompanyPermission(id)) {
    Swal.fire({ icon:'warning', title:'غير مصرح', text:'لا تملك صلاحية الوصول إلى هذه الصفحة', ...swalTheme() });
    var fallback = firstAllowedAdminPage();
    if (fallback && fallback !== id) {
      if (window.innerWidth <= 768) closeSidebar();
      showPage(fallback);
      return;
    }
    if (window.innerWidth <= 768) closeSidebar();
    return;
  }
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  const page = document.getElementById('page-' + id);
  if (!page) {
    console.warn('showPage: missing #page-' + id);
    return;
  }
  page.classList.add('active');
  const navItem = document.getElementById('nav-' + id);
  if (navItem) navItem.classList.add('active');
  const titles = {
    'dashboard':'لوحة التحكم','employees':'الموظفون','attendance':'الحضور والانصراف',
    'device-mgmt':'بصمة الأجهزة والتتبع',
    'leaves':'الإجازات والغياب',
    'salaries':'الرواتب','finance':'الخصومات والمكافآت والسلف','org':'الأقسام والوظائف','reports':'التقارير','notifications':'الإشعارات',
    'users-permissions':'المستخدمون والصلاحيات','settings':'الإعدادات','emp-home':'الرئيسية','emp-salary':'الراتب','emp-profile':'الملف الشخصي',
    'superadmin':'👑 لوحة السوبر أدمن','sa-companies':'🏢 الشركات','sa-subscriptions':'💳 الاشتراكات',
    'sa-users':'👤 المستخدمين','sa-team':'👥 فريق السوبر أدمن','sa-platform':'📢 إعدادات المنصة','sa-stats':'📊 الإحصائيات',
    'sa-monitoring':'🛡️ System Monitoring','sa-backup':'💾 Backup Center','sa-settings':'⚙️ الإعدادات'
  };
  var titleEl = document.getElementById('topbar-title');
  if (titleEl) {
    if (typeof BasmaSecurity !== 'undefined') BasmaSecurity.setText(titleEl, titles[id] || id);
    else titleEl.textContent = titles[id] || id;
  }
  if (id === 'reports') { setTimeout(buildReports, 100); }
  if (id === 'dashboard') {
    if (typeof buildDashboard === 'function') buildDashboard();
  }
  if (id === 'attendance') {
    if (typeof buildAttendance === 'function') buildAttendance();
  }
  if (id === 'device-mgmt') {
    if (typeof buildDeviceManagement === 'function') buildDeviceManagement();
    if (typeof refreshDeviceTrackingLog === 'function') refreshDeviceTrackingLog();
    refreshEmployeeDevicesUi().catch(function (e) { console.warn('refreshEmployeeDevicesUi:', e); });
  }
  if (id === 'employees') {
    if (typeof buildEmployees === 'function') buildEmployees();
    refreshEmployeeDevicesUi().catch(function (e) { console.warn('refreshEmployeeDevicesUi:', e); });
  }
  if (id === 'salaries') {
    var renderSalaries = function () {
      buildSalaries();
      buildPaidSalaries();
      refreshPaidSalaryRecordsFromCloud().then(buildPaidSalaries);
    };
    if (typeof ensureFinanceLoaded === 'function') {
      ensureFinanceLoaded({ forceRemote: true, replace: false }).finally(renderSalaries);
    } else {
      renderSalaries();
    }
  }
  if (id === 'finance') {
    if (typeof ensureFinanceLoaded === 'function') {
      ensureFinanceLoaded({ forceRemote: true, replace: true }).finally(function () {
        buildFinancePageNow();
      });
    } else if (typeof hydrateFinanceItemsFromCloud === 'function') {
      hydrateFinanceItemsFromCloud({ forceRemote: true, replace: true }).finally(function () {
        buildFinancePageNow();
      });
    } else {
      buildFinancePage();
    }
  }
  if (id === 'org') {
    buildOrgPage();
    refreshOrgListsFromCloud().then(function () {
      buildOrgPage();
      if (typeof saveData === 'function') saveData();
    });
  }
  if (id === 'notifications') {
    if (currentUser === 'emp' && typeof syncEmployeeNotificationsBeforeOpen === 'function') {
      syncEmployeeNotificationsBeforeOpen().finally(function () {
        buildNotifications();
        markCurrentEmployeeNotificationsRead();
        buildNotifications();
      });
    } else if (currentUser === 'admin' && saasCurrentUser && saasCurrentUser.role === 'super_admin') {
      syncSuperAdminNotificationsBeforeOpen().finally(function () {
        buildNotifications();
      });
    } else if (currentUser === 'admin' && typeof sb_getSettings === 'function') {
      (async function () {
        try {
          var remote = await sb_getSettings();
          if (remote && remote.activity_log && typeof mergeActivityLogRemote === 'function') {
            ensureNotifStores();
            appSettings.activityLog = mergeActivityLogRemote(
              appSettings.activityLog,
              JSON.parse(remote.activity_log) || []
            );
            if (typeof saveData === 'function') saveData();
          }
        } catch (e) {
          console.warn('open notifications merge:', e);
        }
        buildNotifications();
      })();
    } else {
      buildNotifications();
    }
  }
  if (id === 'leaves') {
    // تعبئة فلتر الأقسام
    var leaveDeptSel = document.getElementById('leaves-filter-dept');
    if (leaveDeptSel) {
      var depts = [...new Set((window.employees || []).map(function(e){ return e && e.dept; }).filter(Boolean))];
      var existOpts = leaveDeptSel.querySelectorAll('option:not([value=""])');
      existOpts.forEach(function(o){ o.remove(); });
      depts.forEach(function(d) {
        var o = document.createElement('option');
        o.value = d; o.textContent = d;
        leaveDeptSel.appendChild(o);
      });
    }
    if (typeof buildLeaves === 'function') buildLeaves();
    if (typeof loadLeavesFromSupabase === 'function') loadLeavesFromSupabase().catch(function(){});
  }
  if (id === 'users-permissions') { buildCompanyUsersPage(); }
  if (typeof applyPermissionUi === 'function') applyPermissionUi();
  if (id === 'settings') { syncSettingsUi(); setTimeout(sbCheckConnection, 500); }
  if (id === 'emp-home' || id === 'emp-salary' || id === 'emp-profile') {
    if (currentUser === 'emp') {
      var refreshes = [];
      if (typeof refreshLoggedInEmployeeSalaryHistory === 'function') refreshes.push(refreshLoggedInEmployeeSalaryHistory().catch(function (e) { console.warn('emp salary refresh:', e); }));
      if (typeof refreshLoggedInEmployeeNotifications === 'function') refreshes.push(refreshLoggedInEmployeeNotifications().catch(function (e) { console.warn('emp notifications refresh:', e); }));
      if (typeof syncLeavesFromSupabase === 'function' && window.loggedInEmpId) refreshes.push(syncLeavesFromSupabase({ empId: window.loggedInEmpId }).catch(function (e) { console.warn('emp leaves refresh:', e); }));
      Promise.all(refreshes).finally(function () {
        buildEmpPortal();
        if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
      });
    } else {
      buildEmpPortal();
    }
  }
  if (id === 'superadmin') { safeBuildPage('buildSuperAdminDashboard'); }
  if (id === 'sa-companies') { safeBuildPage('buildSACompaniesPage'); }
  if (id === 'sa-subscriptions') { safeBuildPage('buildSASubscriptionsPage'); }
  if (id === 'sa-users') { safeBuildPage('buildSAUsersPage'); }
  if (id === 'sa-team') { safeBuildPage('buildSATeamPage'); }
  if (id === 'sa-platform') { safeBuildPage('buildSAPlatformPage'); }
  if (id === 'sa-stats') { safeBuildPage('buildSAStatsPage'); }
  if (id === 'sa-monitoring') { safeBuildPage('buildSAMonitoringPage'); }
  if (id === 'sa-backup') { safeBuildPage('buildSABackupPage'); }
  if (id === 'sa-settings') { safeBuildPage('buildSASettingsPage'); }
  if (typeof ensureAppInteractive === 'function') ensureAppInteractive();
  if (_isCompanySubscriptionTenant()) {
  _renderSubscriptionBanner();
    if (typeof maybeShowSubscriptionExpiryToast === 'function') maybeShowSubscriptionExpiryToast();
    if (typeof renderPlatformAnnouncementsRail === 'function') renderPlatformAnnouncementsRail();
  } else if (typeof _removeSaasBanner === 'function') {
    _removeSaasBanner();
  }
  if (window.innerWidth <= 768) closeSidebar();
}

// ======= CLOCK =======
var _clockTimer = null;
function startClock() {
  if (_clockTimer) return;
  function tick() {
    const el = document.getElementById('clock');
    if (el) el.textContent = formatAppTimeAmPm(new Date(), true);
  }
  tick();
  _clockTimer = setInterval(tick, 1000);
}

function iraqiTime() {
  return formatAppTimeAmPm(new Date(), false);
}

// دالة موحدة لتحويل الوقت (24 ساعة أو AM/PM) إلى دقائق
function timeToMinutes(timeStr) {
  if (!timeStr || timeStr === '—') return 0;
  let h = 0, m = 0;
  const ampmMatch = String(timeStr).match(/(\d{1,2}):(\d{2})\s*(AM|PM)/i);
  if (ampmMatch) {
    h = parseInt(ampmMatch[1]);
    m = parseInt(ampmMatch[2]);
    const ap = ampmMatch[3].toUpperCase();
    if (ap === 'PM' && h !== 12) h += 12;
    if (ap === 'AM' && h === 12) h = 0;
  } else {
    const parts = String(timeStr).split(':').map(Number);
    h = parts[0] || 0;
    m = parts[1] || 0;
  }
  return (h * 60) + m;
}

function toTimeInputValue(timeStr) {
  if (!timeStr || timeStr === '—') return '';
  var s = String(timeStr).trim();
  var ampmMatch = s.match(/(\d{1,2}):(\d{2})\s*(AM|PM)/i);
  if (ampmMatch) {
    var h = parseInt(ampmMatch[1], 10);
    var m = parseInt(ampmMatch[2], 10);
    var ap = ampmMatch[3].toUpperCase();
    if (ap === 'PM' && h !== 12) h += 12;
    if (ap === 'AM' && h === 12) h = 0;
    return String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0');
  }
  var hm = s.match(/^(\d{1,2}):(\d{2})$/);
  if (hm) return String(parseInt(hm[1], 10)).padStart(2, '0') + ':' + hm[2];
  return '';
}

function fromTimeInputToAmPm(value) {
  var v = String(value || '').trim();
  if (!v) return '—';
  var hm = v.match(/^(\d{1,2}):(\d{2})$/);
  if (!hm) return v;
  var h24 = parseInt(hm[1], 10);
  var m = parseInt(hm[2], 10);
  var ap = h24 >= 12 ? 'PM' : 'AM';
  var h12 = (h24 % 12) || 12;
  return String(h12).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ' ' + ap;
}

// ======= DASHBOARD =======
function currentMonthIsoPrefix() {
  var p = getAppDateParts();
  return p.year + '-' + p.month;
}

function computeDashboardTodayStats() {
  var todayIso = todayIsoDate();
  var totalEmp = (employees || []).length;
  var recordedByEmp = {};
  (attData || []).filter(isAttendanceRecordToday).forEach(function (r) {
    if (!r || !r.empId) return;
    recordedByEmp[r.empId] = r;
  });

  var presentCount = 0;
  var absentCount = 0;
  var leaveCount = 0;
  var lateCount = 0;
  var lateMinutesTotal = 0;
  var lateMinutesCount = 0;

  (employees || []).forEach(function (emp) {
    if (!emp || emp.id == null) return;
    var rec = recordedByEmp[emp.id];
    var onLeave = typeof isDateOnEmployeeLeave === 'function' && isDateOnEmployeeLeave(emp.id, todayIso);

    if (rec) {
      if (isAdminOnlyAbsenceRecord(rec)) return;
      if (rec.ci && rec.ci !== '—') {
        presentCount++;
        var lateMin = parseDurationMinutes(rec.late) || 0;
        if (!lateMin && typeof timeToMinutes === 'function') {
          lateMin = Math.max(0, timeToMinutes(rec.ci) - timeToMinutes(emp.checkIn || (appSettings && appSettings.workStart) || '08:00'));
        }
        if (lateMin > 0) {
          lateMinutesTotal += lateMin;
          lateMinutesCount++;
        }
        var threshold = typeof getEmpLateThreshold === 'function' ? getEmpLateThreshold(emp) : 0;
        if (rec.status === 'متأخر' || lateMin > threshold) lateCount++;
        return;
      }
    }

    if (onLeave) {
      leaveCount++;
      return;
    }

    absentCount++;
  });

  return {
    totalEmp: totalEmp,
    presentCount: presentCount,
    absentCount: absentCount,
    leaveCount: leaveCount,
    lateCount: lateCount,
    avgLate: lateMinutesCount > 0 ? Math.round(lateMinutesTotal / lateMinutesCount) : 0
  };
}

function computeDashboardMonthOvertimeHours() {
  var monthPrefix = currentMonthIsoPrefix();
  var totalMin = 0;
  (attData || []).forEach(function (r) {
    if (!r) return;
    var iso = String(r.dateIso || r.date_iso || '').slice(0, 10);
    if (!iso || iso.slice(0, 7) !== monthPrefix) return;
    if (!r.ot || r.ot === '—') return;
    totalMin += parseDurationMinutes(r.ot) || 0;
  });
  return totalMin > 0 ? Math.round((totalMin / 60) * 10) / 10 : 0;
}

function buildDashboard() {
  var dashStats = computeDashboardTodayStats();
  var presentCount = dashStats.presentCount;
  var absentCount = dashStats.absentCount;
  var leaveCount = dashStats.leaveCount;
  var lateCount = dashStats.lateCount;
  var avgLate = dashStats.avgLate;
  var totalEmp = dashStats.totalEmp;
  var totalSalaries = (employees || []).reduce(function (s, e) {
    return s + (parseExactInt(e && e.salary, 0) || 0);
  }, 0);
  var totalOvertimeHours = computeDashboardMonthOvertimeHours();

  var statCards = document.querySelectorAll('#page-dashboard .stats-grid .stat-card');
  if (statCards.length >= 5) {
    var pVal = statCards[0].querySelector('.stat-value');
    var pSub = statCards[0].querySelector('.stat-sub');
    var pBar = statCards[0].querySelector('.progress-fill');
    if (pVal) pVal.textContent = presentCount;
    if (pSub) pSub.textContent = 'من أصل ' + totalEmp + ' موظف';
    if (pBar) pBar.style.width = (totalEmp > 0 ? Math.round(presentCount / totalEmp * 100) : 0) + '%';

    var aVal = statCards[1].querySelector('.stat-value');
    var aSub = statCards[1].querySelector('.stat-sub');
    var aBar = statCards[1].querySelector('.progress-fill');
    if (aVal) aVal.textContent = absentCount;
    if (aSub) {
      aSub.textContent = leaveCount > 0
        ? (leaveCount + ' إجازة • ' + absentCount + ' بدون عذر')
        : (absentCount + ' غياب');
    }
    if (aBar) aBar.style.width = (totalEmp > 0 ? Math.round(absentCount / totalEmp * 100) : 0) + '%';

    var lVal = statCards[2].querySelector('.stat-value');
    var lSub = statCards[2].querySelector('.stat-sub');
    var lBar = statCards[2].querySelector('.progress-fill');
    if (lVal) lVal.textContent = lateCount;
    if (lSub) lSub.textContent = lateCount > 0 ? ('متوسط التأخير ' + avgLate + ' دقيقة') : 'لا يوجد تأخير اليوم';
    if (lBar) lBar.style.width = (totalEmp > 0 ? Math.round(lateCount / totalEmp * 100) : 0) + '%';

    var sVal = statCards[3].querySelector('.stat-value');
    if (sVal) sVal.textContent = totalSalaries.toLocaleString();

    var oVal = statCards[4].querySelector('.stat-value');
    var oSub = statCards[4].querySelector('.stat-sub');
    if (oVal) oVal.textContent = String(totalOvertimeHours);
    if (oSub) oSub.textContent = totalOvertimeHours > 0 ? 'ساعة هذا الشهر' : 'لا توجد ساعات إضافية';
  }

  var tbody = document.getElementById('dashboard-table');
  if (tbody) {
    var statusMap = { 'طبيعي':'badge-success', 'متأخر':'badge-warning', 'غياب':'badge-danger', 'إضافي':'badge-info' };
    var statusIcon = { 'طبيعي':'🟢', 'متأخر':'🟡', 'غياب':'🔴', 'إضافي':'🔵' };
    var dashTodayRecords = attData.filter(function (r) {
      return isAttendanceRecordToday(r) && isPunchAttendanceRecord(r);
    });
    tbody.innerHTML = dashTodayRecords.length ? dashTodayRecords.map(function (r) {
      var st = esc(r.status);
      var timeCell = r.ci === '—' ? '<span class="badge badge-danger">غائب</span>' :
        '<div class="time-slot"><span>' + esc(fmtTimeDisplay(r.ci)) + '</span><span class="time-arrow">←</span><span>' + esc(fmtTimeDisplay(r.co)) + '</span></div>';
      return '<tr>' +
        '<td><strong>' + esc(attRecordDisplayName(r)) + '</strong></td>' +
        '<td style="color:var(--text-muted)">' + esc(r.dept) + '</td>' +
        '<td>' + timeCell + '</td>' +
        '<td><span class="badge ' + escClass(r.status, statusMap, 'badge-success') + '">' + esc(statusIcon[r.status] || '') + ' ' + st + '</span></td>' +
        '<td>' + (r.late !== '—' ? '<span style="color:#f6e05e">⏱ ' + esc(r.late) + '</span>' : r.ot !== '—' ? '<span style="color:#63b3ed">+ ' + esc(r.ot) + '</span>' : '—') + '</td>' +
      '</tr>';
    }).join('') : '<tr><td colspan="5" style="text-align:center;padding:24px;color:var(--text-muted)">لا توجد سجلات حضور لليوم</td></tr>';
  }

  setTimeout(function () {
    if (typeof BasmaCharts === 'undefined') return;
    BasmaCharts.buildWeekChart(attData);
    BasmaCharts.buildTodayChart(attData, employees, window.leavesData || []);
  }, 80);
}

function findAttIndex(empId, date) {
  return attData.findIndex(r => r.empId === empId && r.date === date);
}

function editAttRecord(empId, date) {
  if (!requireActionPermission('attendance', 'edit')) return;
  const idx = findAttIndex(empId, date);
  if (idx === -1) return;
  const rec = attData[idx];
  const emp = employees.find(e => e.id === empId);

  const empOpts = employees.map(e =>
    '<option value="' + e.id + '"' + (e.id === empId ? ' selected' : '') + '>' + esc(e.name) + '</option>'
  ).join('');

  const statusOpts = ['طبيعي','متأخر','غياب','إضافي'].map(s =>
    '<option value="' + s + '"' + (s === rec.status ? ' selected' : '') + '>' + s + '</option>'
  ).join('');
  const recIso = attendanceRecordIso(rec) || todayIsoDate();

  Swal.fire({
    title: '✏️ تعديل سجل الحضور',
    html: '<div class="emp-form-wrap">' +
      '<div class="emp-field"><label>الموظف</label><select id="att-emp-id">' + empOpts + '</select></div>' +
      '<div class="emp-field"><label>التاريخ</label><input type="date" id="att-date" value="' + escAttr(recIso) + '"></div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>وقت الحضور</label><input type="time" id="att-ci" dir="ltr" value="' + escAttr(toTimeInputValue(rec.ci)) + '" step="60"><label class="att-clear-card att-clear-ci"><input type="checkbox" id="att-clear-ci" onchange="(function(){var b=document.getElementById(\'att-clear-ci\');var t=document.getElementById(\'att-ci\'); if(t){ t.disabled=!!(b&&b.checked); t.style.opacity=(b&&b.checked)?\'0.55\':\'1\'; }})()"><span class="att-clear-card-check"></span><span class="att-clear-card-body"><span class="att-clear-card-title">مسح الحضور فقط</span><span class="att-clear-card-desc">سيتم حذف وقت الحضور فقط، وسيبقى الانصراف كما هو.</span></span></label></div>' +
      '<div class="emp-field"><label>وقت الانصراف</label><input type="time" id="att-co" dir="ltr" value="' + escAttr(toTimeInputValue(rec.co)) + '" step="60"><label class="att-clear-card att-clear-co"><input type="checkbox" id="att-clear-co" onchange="(function(){var b=document.getElementById(\'att-clear-co\');var t=document.getElementById(\'att-co\'); if(t){ t.disabled=!!(b&&b.checked); t.style.opacity=(b&&b.checked)?\'0.55\':\'1\'; }})()"><span class="att-clear-card-check"></span><span class="att-clear-card-body"><span class="att-clear-card-title">مسح الانصراف فقط</span><span class="att-clear-card-desc">سيتم حذف وقت الانصراف فقط، وسيبقى الحضور كما هو.</span></span></label></div>' +
      '</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>ساعات العمل</label><input type="text" id="att-hrs" value="' + (rec.hrs !== '—' ? rec.hrs : '') + '" placeholder="8س 00د"></div>' +
      '<div class="emp-field"><label>التأخير</label><input type="text" id="att-late" value="' + (rec.late !== '—' ? rec.late : '') + '" placeholder="0د"></div>' +
      '</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>الإضافي</label><input type="text" id="att-ot" value="' + (rec.ot !== '—' ? rec.ot : '') + '" placeholder="0د"></div>' +
      '<div class="emp-field"><label>الحالة</label><select id="att-status">' + statusOpts + '</select></div>' +
      '</div>' +
    '</div>',
    ...swalTheme(),
    showCancelButton: true,
    confirmButtonText: 'حفظ التعديلات',
    cancelButtonText: 'إلغاء',
    preConfirm: () => {
      const newEmpId = parseInt(document.getElementById('att-emp-id').value, 10);
      const newDate = document.getElementById('att-date').value.trim();
      const clearCi = !!document.getElementById('att-clear-ci')?.checked;
      const clearCo = !!document.getElementById('att-clear-co')?.checked;
      const ciInput = document.getElementById('att-ci').value.trim();
      const coInput = document.getElementById('att-co').value.trim();
      const ci = clearCi ? '—' : fromTimeInputToAmPm(ciInput);
      const co = clearCo ? '—' : fromTimeInputToAmPm(coInput);
      const hrs = document.getElementById('att-hrs').value.trim() || '—';
      const late = document.getElementById('att-late').value.trim() || '—';
      const ot = document.getElementById('att-ot').value.trim() || '—';
      const status = document.getElementById('att-status').value;
      if (!newDate) { Swal.showValidationMessage('التاريخ مطلوب'); return false; }
      if (!/^\d{4}-\d{2}-\d{2}$/.test(newDate)) { Swal.showValidationMessage('صيغة التاريخ غير صحيحة'); return false; }
      if (clearCi && clearCo) { Swal.showValidationMessage('اختر مسح الحضور أو الانصراف فقط (واحد فقط)'); return false; }
      return { newEmpId, newDate, ci, co, clearCi, clearCo, hrs, late, ot, status };
    }
  }).then(async r => {
    if (!r.isConfirmed || !r.value) return;
    window.__basmaSuppressRealtimeUntil = Date.now() + 5000;
    const v = r.value;
    const newEmp = employees.find(e => e.id === v.newEmpId);
    attData[idx].empId = v.newEmpId;
    attData[idx].emp = newEmp ? fullEmpName(newEmp.name) : attData[idx].emp;
    attData[idx].dept = newEmp ? newEmp.dept : attData[idx].dept;
    attData[idx].dateIso = v.newDate;
    attData[idx].date = v.newDate.replace(/-/g, '/');
    attData[idx].ci = v.ci;
    attData[idx].co = v.co;
    attData[idx].hrs = v.hrs;
    attData[idx].late = v.late;
    attData[idx].ot = v.ot;
    attData[idx].status = v.status;
    if (v.status === 'غياب' && v.ci === '—' && v.co === '—') {
      attData[idx]._adminBatchAbsence = true;
      attData[idx]._adminReason = 'admin_batch_absence';
    } else {
      delete attData[idx]._adminBatchAbsence;
      if (attData[idx]._adminReason === 'admin_batch_absence') delete attData[idx]._adminReason;
    }
    syncAttendanceRecordHours(attData[idx], newEmp || emp);
    attData[idx]._pendingRemoteSync = true;
    attData[idx]._localAttEditAt = Date.now();
    attData[idx]._clearCheckIn = !!v.clearCi;
    attData[idx]._clearCheckOut = !!v.clearCo;
    const saved = await persistAttendanceNow(attData[idx]);
    if (!saved || saved.ok === false) {
      delete attData[idx]._clearCheckIn;
      delete attData[idx]._clearCheckOut;
      Swal.fire({ icon:'error', title:'تعذر حفظ التعديل في السحابة', text:'لم يتم اعتماد تعديل الحضور حتى لا يعود السجل للقيمة السابقة.', ...swalTheme() });
      window.__basmaSuppressRealtimeUntil = 0;
      return;
    }
    if (saved.ok === true) {
      applyServerAttendanceToRecord(attData[idx], saved, newEmp || emp);
    } else {
      if (saved.id) attData[idx].id = saved.id;
      if (saved.check_in !== undefined) attData[idx].ci = saved.check_in || '—';
      if (saved.check_out !== undefined) attData[idx].co = saved.check_out || '—';
      if (saved.hours !== undefined) attData[idx].hrs = saved.hours || '—';
      if (saved.late !== undefined) attData[idx].late = saved.late || '—';
      if (saved.overtime !== undefined) attData[idx].ot = saved.overtime || '—';
      if (saved.status) attData[idx].status = saved.status;
      if (saved.date_label) attData[idx].date = saved.date_label;
      if (saved.date_iso) attData[idx].dateIso = String(saved.date_iso).slice(0, 10);
      syncAttendanceRecordHours(attData[idx], newEmp || emp);
    }
    delete attData[idx]._clearCheckIn;
    delete attData[idx]._clearCheckOut;
    // Recalculate emp.days and emp.lateMin from attendance data
    if (emp) {
      emp.days = countEmployeePresentDays(emp.id, attData);
      emp.lateMin = countEmployeeLateMinutes(emp.id, attData);
    }
    if (emp) await persistEmployeeNow(emp);
    saveData();
    refreshAll();
    logActivity('edit', 'attendance', 'تعديل سجل حضور: ' + rec.emp + ' — ' + rec.date, { targetName: rec.emp, empId: rec.empId, targetEmpId: rec.empId });
    Swal.fire({ icon: 'success', title: 'تم تعديل السجل', ...swalTheme(), timer: 1500, showConfirmButton: false });
    setTimeout(() => { window.__basmaSuppressRealtimeUntil = 0; }, 4500);
  });
}

function deleteAttRecord(empId, date) {
  if (!requireActionPermission('attendance', 'delete')) return;
  const idx = findAttIndex(empId, date);
  if (idx === -1) return;
  const rec = attData[idx];
  const emp = employees.find(e => e.id === empId);
  const today = todayAttDate();
  const isToday = (date === today);

  let warningMsg = 'هل تريد حذف سجل حضور <b>' + esc(rec.emp) + '</b> بتاريخ <b>' + esc(formatAttendanceDisplayDate(rec)) + '</b>؟';
  if (isToday) {
    warningMsg += '<br><br><div style="padding:8px 12px;background:rgba(252,129,129,0.1);border:1px solid rgba(252,129,129,0.2);border-radius:8px;font-size:12px;color:#fc8181">⚠️ تنبيه: هذا سجل اليوم — إذا سجلت حضورك مرة أخرى سيتم إنشاء سجل جديد تلقائياً</div>';
  }

  Swal.fire({
    title: 'حذف سجل الحضور',
    html: warningMsg,
    icon: 'warning', showCancelButton: true,
    confirmButtonText: 'نعم، احذف', cancelButtonText: 'إلغاء',
    ...swalTheme(), confirmButtonColor: '#e53e3e'
  }).then(async r => {
    if (!r.isConfirmed) return;
    pauseRemoteSync(10000);
    if (typeof sb_deleteAttendance === 'function') {
      const deleted = await sb_deleteAttendance(rec);
      if (!deleted) {
        resumeRemoteSync(0);
        Swal.fire({ icon:'error', title:'تعذر حذف السجل من السحابة', text:'لم يتم حذف سجل الحضور من قاعدة البيانات لذلك لم أحذفه محلياً.', ...swalTheme() });
        return;
      }
    }
    attData.splice(idx, 1);

    // Reset check-in state if deleting today's record for logged-in employee
    if (isToday && emp && currentUser === 'emp') {
      const loggedEmp = getLoggedInEmp();
      if (loggedEmp && loggedEmp.id === empId) {
        checkedIn = false;
        checkInTime = null;
        const checkinTimeEl = document.getElementById('checkin-time');
        const checkoutTimeEl = document.getElementById('checkout-time');
        if (checkinTimeEl) checkinTimeEl.textContent = 'اضغط للتسجيل';
        if (checkoutTimeEl) checkoutTimeEl.textContent = 'اضغط للتسجيل';
      }
    }

    // Recalculate emp.days and emp.lateMin from attendance data
    if (emp) {
      emp.days = countEmployeePresentDays(emp.id, attData);
      emp.lateMin = countEmployeeLateMinutes(emp.id, attData);
    }

    saveData();
    if (emp) await persistEmployeeNow(emp);
    refreshAll();
    logActivity('delete', 'attendance', 'حذف سجل حضور: ' + rec.emp + ' — ' + formatAttendanceDisplayDate(rec), { targetName: rec.emp, empId: rec.empId, targetEmpId: rec.empId });
    Swal.fire({ icon: 'success', title: 'تم حذف السجل', ...swalTheme(), timer: 1500, showConfirmButton: false });
    resumeRemoteSync(9000);
  });
}

function deleteAttRecordsBatch() {
  if (!requireActionPermission('attendance', 'batch_delete')) return;
  if (!employees.length) {
    Swal.fire({ icon: 'warning', title: 'لا يوجد موظفون', text: 'أضف موظفين أولاً', ...swalTheme() });
    return;
  }
  (async function runBatchDeleteFlow() {
    window.__basmaPreserveSwal = true;
    try {
      var empOpts = employees.map(function (e) {
        return '<option value="' + e.id + '">' + esc(e.name) + '</option>';
      }).join('');
      var r = await Swal.fire({
        title: '🗑️ حذف سجلات حضور دفعة واحدة',
        html: '<div class="emp-form-wrap" style="text-align:right">' +
          '<div class="emp-field"><label>الموظف</label><select id="att-batch-emp" class="setting-input" style="width:100%">' + empOpts + '</select></div>' +
          '<div class="emp-field-row">' +
          '<div class="emp-field"><label>من تاريخ</label><input type="date" id="att-batch-from" class="setting-input" style="width:100%"></div>' +
          '<div class="emp-field"><label>إلى تاريخ</label><input type="date" id="att-batch-to" class="setting-input" style="width:100%"></div>' +
          '</div>' +
          '<div style="font-size:12px;color:var(--text-muted);margin-top:8px">سيتم حذف جميع سجلات الحضور والانصراف للموظف المحدد ضمن الفترة المختارة من السحابة.</div>' +
          '</div>',
        ...swalTheme(),
        showCancelButton: true,
        confirmButtonText: 'متابعة',
        cancelButtonText: 'إلغاء',
        preConfirm: function () {
          var empId = parseInt(document.getElementById('att-batch-emp')?.value || '0', 10);
          var fromIso = document.getElementById('att-batch-from')?.value || '';
          var toIso = document.getElementById('att-batch-to')?.value || '';
          if (!empId) { Swal.showValidationMessage('اختر الموظف'); return false; }
          if (!fromIso || !toIso) { Swal.showValidationMessage('حدد تاريخ البداية والنهاية'); return false; }
          if (fromIso > toIso) { Swal.showValidationMessage('تاريخ البداية يجب أن يكون قبل تاريخ النهاية'); return false; }
          return { empId: empId, fromIso: fromIso, toIso: toIso };
        }
      });
      if (!r.isConfirmed || !r.value) return;

      var empId = r.value.empId;
      var fromIso = r.value.fromIso;
      var toIso = r.value.toIso;
      var emp = employees.find(function (e) { return e && e.id === empId; });

      Swal.fire({
        title: '⏳ جارٍ جلب السجلات من السحابة...',
        allowOutsideClick: false,
        didOpen: function () { Swal.showLoading(); },
        ...swalTheme()
      });
      if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
        await AuthApi.refreshAuthSessionForWrite();
      }
      await loadAttendanceForBatchDelete(empId, fromIso, toIso);
      if (Swal.isVisible()) Swal.close();

      var rawMatches = (attData || []).filter(function (rec) {
        return rec && rec.empId === empId && attRecordInDateRange(rec, fromIso, toIso);
      });
      var matchGroups = {};
      rawMatches.forEach(function (rec) {
        var key = attendanceRecordKey(rec);
        if (!key) return;
        if (!matchGroups[key]) matchGroups[key] = [];
        matchGroups[key].push(rec);
      });
      var uniqueKeys = Object.keys(matchGroups);
      if (!uniqueKeys.length) {
        Swal.fire({
          icon: 'info',
          title: 'لا توجد سجلات',
          text: 'لم يُعثر على سجلات حضور للموظف في الفترة المحددة (محلياً أو في السحابة).',
          ...swalTheme()
        });
        return;
      }
      var fromDisplay = fromIso.replace(/-/g, '/');
      var toDisplay = toIso.replace(/-/g, '/');
      var r2 = await Swal.fire({
        title: 'تأكيد الحذف',
        html: 'هل تريد حذف <b style="color:#fc8181">' + uniqueKeys.length + '</b> سجل حضور للموظف <b>' + esc(emp ? emp.name : '') + '</b><br>من <b>' + fromDisplay + '</b> إلى <b>' + toDisplay + '</b>؟' +
          (rawMatches.length > uniqueKeys.length ? '<br><span style="font-size:12px;color:var(--text-muted)">سيتم إزالة ' + rawMatches.length + ' صف محلي (' + (rawMatches.length - uniqueKeys.length) + ' مكرر)</span>' : '') +
          '<br><br><span style="font-size:12px;color:var(--text-muted)">لا يمكن التراجع عن هذا الإجراء.</span>',
        icon: 'warning',
        showCancelButton: true,
        confirmButtonText: 'نعم، احذف الكل',
        cancelButtonText: 'إلغاء',
        ...swalTheme(),
        confirmButtonColor: '#e53e3e'
      });
      if (!r2.isConfirmed) return;

      pauseRemoteSync(20000);
      var keysToDelete = {};
      var failed = 0;
      var failDetails = [];
      await runWithBatchProgress({
        title: 'جاري الحذف...',
        subtitle: 'يتم حذف السجلات من السحابة',
        total: uniqueKeys.length,
        run: async function (update) {
          for (var gi = 0; gi < uniqueKeys.length; gi++) {
            var groupKey = uniqueKeys[gi];
            var group = matchGroups[groupKey].slice().sort(function (a, b) {
              return attendanceRecordRank(b) - attendanceRecordRank(a);
            });
            var dayLabel = group[0].date || attendanceRecordIso(group[0]).replace(/-/g, '/');
            var cloudOk = true;
            if (typeof sb_deleteAttendance === 'function') {
              cloudOk = false;
              for (var gj = 0; gj < group.length; gj++) {
                if (await sb_deleteAttendance(group[gj])) {
                  cloudOk = true;
                  break;
                }
              }
              if (!cloudOk) {
                var fallbackRec = Object.assign({}, group[0], {
                  empId: group[0].empId,
                  dateIso: attendanceRecordIso(group[0]),
                  id: group[0].id || null
                });
                cloudOk = !!(await sb_deleteAttendance(fallbackRec));
              }
            }
            if (!cloudOk && typeof sb_deleteAttendance === 'function') {
              failed++;
              failDetails.push(dayLabel);
            } else {
              keysToDelete[groupKey] = true;
            }
            update(gi + 1, (gi + 1) + ' / ' + uniqueKeys.length + ' — ' + dayLabel);
            await repaintBatchProgressFrame();
          }
        }
      });
      if (!Object.keys(keysToDelete).length) {
        resumeRemoteSync(0);
        Swal.fire({
          icon: 'error',
          title: 'تعذر الحذف',
          html: 'لم يتم حذف أي سجل من السحابة.' + (failDetails.length ? '<br><span style="font-size:12px;color:var(--text-muted)">أيام فشلت: ' + esc(failDetails.slice(0, 8).join('، ')) + '</span>' : ''),
          ...swalTheme()
        });
        return;
      }
      attData = (attData || []).filter(function (row) {
        if (!row) return false;
        return !keysToDelete[attendanceRecordKey(row)];
      });
      window.attData = attData;
      if (emp) {
        emp.days = countEmployeePresentDays(empId, attData);
        emp.lateMin = countEmployeeLateMinutes(empId, attData);
        await persistEmployeeNow(emp);
      }
      saveData();
      refreshAll();
      logActivity('delete', 'attendance', 'حذف دفعة سجلات حضور: ' + (emp ? emp.name : empId) + ' — ' + fromDisplay + ' → ' + toDisplay + ' (' + Object.keys(keysToDelete).length + ')', { targetName: emp ? emp.name : '', empId: empId, targetEmpId: empId });
      var deletedCount = Object.keys(keysToDelete).length;
      var msg = 'تم حذف ' + deletedCount + ' يوم حضور من السحابة';
      if (failed > 0) msg += ' — فشل حذف ' + failed + ' يوم';
      Swal.fire({ icon: failed > 0 ? 'warning' : 'success', title: 'تم الحذف', text: msg, ...swalTheme(), timer: failed > 0 ? 0 : 2200, showConfirmButton: failed > 0 });
      resumeRemoteSync(9000);
    } catch (e) {
      console.error('deleteAttRecordsBatch:', e);
      Swal.fire({ icon: 'error', title: 'تعذّر الحذف', text: (e && e.message) || 'حدث خطأ أثناء حذف الدفعة', ...swalTheme() });
    } finally {
      window.__basmaPreserveSwal = false;
    }
  })();
}

async function mergeAttendanceRangeFromCloud(empId, fromIso, toIso) {
  empId = parseInt(empId, 10);
  if (!empId || !fromIso || !toIso) return false;
  if (typeof sb_getAttendance !== 'function') return false;
  var rows = await sb_getAttendance({ employeeId: empId, dateFrom: fromIso, dateTo: toIso, limit: 500 });
  if (!rows || !rows.length) return false;
  var keep = (attData || []).filter(function (r) {
    if (!r || r.empId !== empId) return true;
    return !attRecordInDateRange(r, fromIso, toIso);
  });
  rows.forEach(function (r) { keep.push(r); });
  attData = typeof dedupeAttendanceRecords === 'function' ? dedupeAttendanceRecords(keep) : keep;
  window.attData = attData;
  if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
  if (typeof saveData === 'function') saveData();
  return true;
}

async function loadAttendanceForBatchDelete(empId, fromIso, toIso) {
  empId = parseInt(empId, 10);
  if (!empId || !fromIso || !toIso) return;
  if (typeof sb_getAttendance !== 'function') return;
  var rows = await sb_getAttendance({ employeeId: empId, dateFrom: fromIso, dateTo: toIso, limit: 500 });
  if (!rows || !rows.length) return;
  var keep = (attData || []).filter(function (r) {
    if (!r || r.empId !== empId) return true;
    return !attRecordInDateRange(r, fromIso, toIso);
  });
  rows.forEach(function (r) { keep.push(r); });
  attData = typeof dedupeAttendanceRecords === 'function' ? dedupeAttendanceRecords(keep) : keep;
  window.attData = attData;
  if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
}

function addAttRecord() {
  if (!requireActionPermission('attendance', 'add')) return;
  if (!requireSubscription('إضافة سجل حضور')) return;
  const empOpts = employees.map(e => {
    const st = e.salaryType || 'monthly';
    const badge = st === 'commission' ? ' 💰' : (st === 'biweekly' ? ' 📅' : '');
    return '<option value="' + e.id + '">' + esc(e.name) + badge + '</option>';
  }).join('');
  const statusOpts = ['طبيعي','متأخر','غياب','إضافي'].map(s =>
    '<option value="' + s + '">' + s + '</option>'
  ).join('');

  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const defFrom = y + '-' + m + '-01';
  const defTo = y + '-' + m + '-' + String(new Date(y, now.getMonth() + 1, 0).getDate()).padStart(2, '0');

  Swal.fire({
    title: '➕ إضافة سجل حضور وانصراف',
    html: '<div class="emp-form-wrap">' +
      '<div class="emp-field"><label>الموظف <span class="req">*</span></label><select id="att-emp-id" onchange="onAttEmpChange()"><option value="">— اختر —</option>' + empOpts + '</select></div>' +
      '<div id="att-emp-salary-info" style="display:none;padding:8px 12px;background:rgba(99,179,237,0.1);border:1px solid rgba(99,179,237,0.2);border-radius:8px;font-size:13px;color:#63b3ed;margin-bottom:10px"></div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>من تاريخ <span class="req">*</span></label><input type="date" id="att-from-date" value="' + defFrom + '"></div>' +
      '<div class="emp-field"><label>إلى تاريخ <span class="req">*</span></label><input type="date" id="att-to-date" value="' + defTo + '"></div>' +
      '</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>وقت الحضور</label><input type="time" id="att-ci" value="08:00"></div>' +
      '<div class="emp-field"><label>وقت الانصراف</label><input type="time" id="att-co" value="17:00"></div>' +
      '</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>الحالة</label><select id="att-status">' + statusOpts + '</select></div>' +
      '</div>' +
      '<div id="att-preview" style="display:none;margin-top:12px;padding:12px;background:rgba(104,211,145,0.08);border:1px solid rgba(104,211,145,0.2);border-radius:10px;font-size:13px"></div>' +
    '</div>',
    ...swalTheme(),
    showCancelButton: true,
    confirmButtonText: 'إضافة السجلات',
    cancelButtonText: 'إلغاء',
    width: 600,
    didOpen: () => {
      const calcPreview = () => {
        const empId = parseInt(document.getElementById('att-emp-id')?.value, 10);
        const fromDate = document.getElementById('att-from-date')?.value;
        const toDate = document.getElementById('att-to-date')?.value;
        const previewEl = document.getElementById('att-preview');
        if (!empId || !fromDate || !toDate || !previewEl) { if (previewEl) previewEl.style.display = 'none'; return; }

        const emp = employees.find(e => e.id === empId);
        if (!emp) { previewEl.style.display = 'none'; return; }

        const from = new Date(fromDate + 'T00:00:00');
        const to = new Date(toDate + 'T23:59:59');
        if (to < from) { previewEl.innerHTML = '<span style="color:#fc8181">⚠️ تاريخ النهاية قبل تاريخ البداية</span>'; previewEl.style.display = ''; return; }

        const totalDays = Math.round((to - from) / (1000 * 60 * 60 * 24)) + 1;
        // Count existing records in range
        const existing = attData.filter(r => r.empId === empId && attRecordInDateRange(r, fromDate, toDate));
        const workDays = totalDays;
        const newDays = Math.max(0, workDays - existing.length);

        const salaryType = emp.salaryType || 'monthly';
        const isComm = salaryType === 'commission';
        const isBiw = salaryType === 'biweekly';

        let salaryInfo = '';
        if (isComm) {
          salaryInfo = '<div style="margin-top:8px;padding:6px 10px;background:rgba(246,224,94,0.1);border:1px solid rgba(246,224,94,0.2);border-radius:6px;color:#f6e05e">💰 عمولة — لا يُحتسب راتب ثابت</div>';
        } else if (isBiw) {
          const halfSalary = emp.salaryHalf || Math.round(emp.salary / 2);
          const dayOfMonth = now.getDate();
          const splitDay = getBiweeklySplitDay();
          const isSecondHalf = dayOfMonth > splitDay;
          salaryInfo = '<div style="margin-top:8px;padding:6px 10px;background:rgba(99,179,237,0.1);border:1px solid rgba(99,179,237,0.2);border-radius:6px;color:#63b3ed">📅 راتب كل ' + splitDay + ' يوم — ' + halfSalary.toLocaleString() + ' IQD' + (isSecondHalf ? ' (النصف الثاني)' : ' (النصف الأول)') + '</div>';
        } else {
          salaryInfo = '<div style="margin-top:8px;padding:6px 10px;background:rgba(104,211,145,0.1);border:1px solid rgba(104,211,145,0.2);border-radius:6px;color:#68d391">📋 راتب شهري — ' + emp.salary.toLocaleString() + ' IQD / شهر</div>';
        }

        previewEl.innerHTML = '<div style="font-weight:700;margin-bottom:6px">📊 معاينة السجلات</div>' +
          '<div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px">' +
          '<span>📅 المدة: <b>' + totalDays + '</b> يوم</span>' +
          '<span>🗓 أيام الفترة: <b>' + workDays + '</b></span>' +
          '<span>✅ مسجل سابقاً: <b>' + existing.length + '</b></span>' +
          '<span>➕ سيُضاف: <b style="color:#68d391">' + newDays + '</b></span>' +
          '</div>' + salaryInfo;
        previewEl.style.display = '';
      };

      window.onAttEmpChange = function() {
        const empId = parseInt(document.getElementById('att-emp-id')?.value, 10);
        const infoEl = document.getElementById('att-emp-salary-info');
        if (!empId || !infoEl) { if (infoEl) infoEl.style.display = 'none'; calcPreview(); return; }
        const emp = employees.find(e => e.id === empId);
        if (!emp) { infoEl.style.display = 'none'; calcPreview(); return; }
        const st = emp.salaryType || 'monthly';
        const label = st === 'commission' ? '💰 عمولة' : (st === 'biweekly' ? '📅 كل ' + getBiweeklyPeriodDays() + ' يوم' : '📋 شهري');
        infoEl.innerHTML = 'نوع الراتب: <b>' + esc(label) + '</b>' + (st !== 'commission' ? ' — الراتب: ' + esc(emp.salary.toLocaleString()) + ' IQD' : '');
        infoEl.style.display = '';
        // Set default times from employee
        const ciInput = document.getElementById('att-ci');
        const coInput = document.getElementById('att-co');
        if (ciInput && emp.checkIn) ciInput.value = emp.checkIn;
        if (coInput && emp.checkOut) coInput.value = emp.checkOut;
        calcPreview();
      };

      safeAddEvent(document.getElementById('att-from-date'), 'change', calcPreview);
      safeAddEvent(document.getElementById('att-to-date'), 'change', calcPreview);
      safeAddEvent(document.getElementById('att-emp-id'), 'change', calcPreview);
    },
    preConfirm: () => {
      const empId = parseInt(document.getElementById('att-emp-id').value, 10);
      const fromDate = document.getElementById('att-from-date').value;
      const toDate = document.getElementById('att-to-date').value;
      const ci = document.getElementById('att-ci').value || '';
      const co = document.getElementById('att-co').value || '';
      const status = document.getElementById('att-status').value;
      if (!empId) { Swal.showValidationMessage('اختر الموظف'); return false; }
      if (!fromDate || !toDate) { Swal.showValidationMessage('حدد التاريخ من وإلى'); return false; }
      if (new Date(toDate + 'T00:00:00') < new Date(fromDate + 'T00:00:00')) { Swal.showValidationMessage('تاريخ النهاية يجب أن يكون بعد تاريخ البداية'); return false; }
      return { empId, fromDate, toDate, ci, co, status };
    }
  }).then(async r => {
    if (!r.isConfirmed || !r.value) return;
    window.__basmaSuppressRealtimeUntil = Date.now() + 5000;
    const v = r.value;
    const emp = employees.find(e => e.id === v.empId);
    if (!emp) return;

    const from = new Date(v.fromDate + 'T00:00:00');
    const to = new Date(v.toDate + 'T23:59:59');
    const salaryType = emp.salaryType || 'monthly';
    const isComm = salaryType === 'commission';
    const isBiw = salaryType === 'biweekly';

    // Convert 24h time to Iraqi AM/PM format
    const toAmPm = t => {
      if (!t) return '—';
      const [h, m] = t.split(':').map(Number);
      const ampm = h >= 12 ? 'PM' : 'AM';
      const hh = ((h % 12) || 12).toString().padStart(2, '0');
      return hh + ':' + String(m).padStart(2, '0') + ' ' + ampm;
    };

    // Calculate hours between check-in and check-out
    const calcHrs = (ciVal, coVal) => {
      if (!ciVal || !coVal) return '—';
      const [h1, m1] = ciVal.split(':').map(Number);
      const [h2, m2] = coVal.split(':').map(Number);
      const diff = (h2 * 60 + m2) - (h1 * 60 + m1);
      if (diff <= 0) return '—';
      return Math.floor(diff / 60) + 'س ' + (diff % 60) + 'د';
    };

    // Calculate late minutes
    const calcLate = (ciVal) => {
      if (!ciVal || isComm) return '—';
      const empCi = emp.checkIn || '08:00';
      const [eH, eM] = empCi.split(':').map(Number);
      const [aH, aM] = ciVal.split(':').map(Number);
      const late = Math.max(0, (aH * 60 + aM) - (eH * 60 + eM));
      return late > 0 ? late + 'د' : '—';
    };

    let added = 0;
    let skipped = 0;
    const totalDays = Math.round((to - from) / (1000 * 60 * 60 * 24)) + 1;
    await runWithBatchProgress({
      title: 'جاري الإضافة...',
      subtitle: 'يتم حفظ سجلات الحضور في السحابة',
      total: totalDays,
      run: async function (update) {
        let processed = 0;
        for (let d = new Date(from); d <= to; d.setDate(d.getDate() + 1)) {
          const iso = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
          const dateDisplay = iso.replace(/-/g, '/');
          processed++;
          const dup = attData.find(function (a) {
            return a.empId === v.empId && attendanceRecordKey(a) === (String(v.empId) + '|' + iso);
          });
          if (dup) {
            skipped++;
            update(processed, processed + ' / ' + totalDays + ' — تخطي ' + dateDisplay);
            await repaintBatchProgressFrame();
            continue;
          }

      // Determine status for this day - always calculate from actual times
      let dayCi = toAmPm(v.ci);
      let dayCo = toAmPm(v.co);
      let dayHrs = calcHrs(v.ci, v.co);
      let dayLate = '—';
      let dayOt = '—';
      let dayStatus = 'طبيعي';

      if (isComm) {
        // Commission: just attendance, no late/ot calculation
        dayLate = '—';
        dayOt = '—';
        dayStatus = 'طبيعي';
      } else if (emp.openHours) {
        // Open hours: always normal, no late
        dayLate = '—';
        dayOt = '—';
        dayStatus = 'طبيعي';
      } else {
        // Normal mode: calculate late from check-in time
        if (v.ci) {
          const empCi = emp.checkIn || '08:00';
          const [eH, eM] = empCi.split(':').map(Number);
          const [aH, aM] = v.ci.split(':').map(Number);
          const lateMin = Math.max(0, (aH * 60 + aM) - (eH * 60 + eM));
          dayLate = lateMin > 0 ? lateMin + 'د' : '—';
          if (lateMin > getEmpLateThreshold(emp)) dayStatus = 'متأخر';
        }
        // Calculate overtime from check-out time
        if (v.co) {
          const empCo = emp.checkOut || '17:00';
          const [oH, oM] = empCo.split(':').map(Number);
          const [aH, aM] = v.co.split(':').map(Number);
          const otMin = Math.max(0, (aH * 60 + aM) - (oH * 60 + oM));
          if (otMin > 0) {
            dayOt = Math.floor(otMin / 60) + 'س ' + (otMin % 60) + 'د';
            if (dayStatus === 'طبيعي') dayStatus = 'إضافي';
          }
        }
      }
      const dateStr = d.getFullYear() + '/' + String(d.getMonth() + 1).padStart(2, '0') + '/' + String(d.getDate()).padStart(2, '0');

      if (v.status === 'غياب') {
        dayCi = '—'; dayCo = '—'; dayHrs = '—'; dayLate = '—'; dayOt = '—'; dayStatus = 'غياب';
      } else if (v.status === 'طبيعي') {
        dayLate = '—'; dayOt = '—'; dayStatus = 'طبيعي';
      } else if (v.status === 'متأخر') {
        dayOt = '—'; dayStatus = 'متأخر';
      } else if (v.status === 'إضافي') {
        dayLate = '—'; dayStatus = 'إضافي';
      }

      const newRec = {
        empId: v.empId, emp: fullEmpName(emp.name), dept: emp.dept,
        date: dateStr, dateIso: iso, ci: dayCi, co: dayCo, hrs: dayHrs, late: dayLate, ot: dayOt, status: dayStatus
      };
      if (dayStatus === 'غياب') {
        newRec._adminBatchAbsence = true;
        newRec._adminReason = 'admin_batch_absence';
      }
      attData.push(newRec);
      await persistAttendanceNow(newRec);
      added++;
      update(processed, processed + ' / ' + totalDays + ' — ' + dateDisplay);
      await repaintBatchProgressFrame();
        }
      }
    });

    // Update employee days count
    emp.days = countEmployeePresentDays(emp.id, attData);
    emp.lateMin = countEmployeeLateMinutes(emp.id, attData);
    if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
    await persistEmployeeNow(emp);

    if (typeof mergeAttendanceRangeFromCloud === 'function') {
      await mergeAttendanceRangeFromCloud(v.empId, v.fromDate, v.toDate);
    }

    saveData();
    if (typeof syncSalaryAfterAttendanceChange === 'function') {
      await syncSalaryAfterAttendanceChange(v.empId);
    } else {
      refreshAll();
    }
    logActivity('add', 'attendance', 'إضافة ' + added + ' سجل حضور للموظف: ' + emp.name, { targetName: emp.name, empId: emp.id, targetEmpId: emp.id });

    // Show result with salary info
    let resultHtml = 'تم إضافة <b style="color:#68d391">' + added + '</b> سجل حضور';
    if (skipped > 0) resultHtml += '<br>تم تخطي <b>' + skipped + '</b> يوم مكرر';

    if (!isComm) {
      const sal = calcEmpSalary(emp);
      const baseSalary = sal.baseSalary;
      const deduct = sal.totalDeduct;
      const ot = sal.overtimeInNet ? (sal.ot || 0) : 0;
      const finalSal = sal.final;
      resultHtml += '<br><br><div style="padding:8px 12px;background:rgba(104,211,145,0.1);border:1px solid rgba(104,211,145,0.2);border-radius:8px;text-align:right;font-size:13px">' +
        '<div>📋 أيام الحضور: <b>' + emp.days + '</b></div>' +
        '<div>💰 الراتب: <b>' + baseSalary.toLocaleString() + '</b> IQD</div>' +
        (deduct > 0 ? '<div style="color:#fc8181">➖ خصم: <b>' + deduct.toLocaleString() + '</b> IQD</div>' : '') +
        (ot > 0 ? '<div style="color:#63b3ed">➕ إضافي: <b>' + ot.toLocaleString() + '</b> IQD</div>' : '') +
        '<div style="font-weight:700;color:var(--accent);margin-top:4px">💵 الصافي: <b>' + finalSal.toLocaleString() + '</b> IQD</div>' +
        '</div>';
    } else {
      resultHtml += '<br><br><div style="padding:8px 12px;background:rgba(246,224,94,0.1);border:1px solid rgba(246,224,94,0.2);border-radius:8px;font-size:13px;color:#f6e05e">💰 عمولة — لا يُحتسب راتب ثابت</div>';
    }

    Swal.fire({ icon: 'success', title: 'تم إضافة السجلات', html: resultHtml, ...swalTheme() });
    setTimeout(() => { window.__basmaSuppressRealtimeUntil = 0; }, 4500);
  });
}

function countFridays(from, to) {
  let count = 0;
  for (let d = new Date(from); d <= to; d.setDate(d.getDate() + 1)) {
    if (d.getDay() === 5) count++;
  }
  return count;
}

function applyAttendanceFilters(list) {
  var fDept = document.getElementById('att-filter-dept')?.value || '';
  var fPeriod = document.getElementById('att-filter-period')?.value || 'today';
  var fStatus = document.getElementById('att-filter-status')?.value || '';
  var fFrom = parseIsoDateOnly(document.getElementById('att-filter-from')?.value || '');
  var fTo = parseIsoDateOnly(document.getElementById('att-filter-to')?.value || '');
  var fName = typeof getEmployeeNameQuery === 'function'
    ? getEmployeeNameQuery('att-filter-name')
    : (document.getElementById('att-filter-name')?.value || '').trim().toLowerCase();
  var filtered = Array.isArray(list) ? list.slice() : [];
  filtered = filtered.filter(function (r) { return isPunchAttendanceRecord(r); });
  if (fDept) filtered = filtered.filter(function (r) { return r.dept === fDept; });
  if (fStatus) filtered = filtered.filter(function (r) { return r.status === fStatus; });
  if (fName) {
    filtered = filtered.filter(function (r) {
      return typeof attendanceRecordMatchesNameQuery === 'function'
        ? attendanceRecordMatchesNameQuery(r, fName, employees)
        : String(r.emp || '').toLowerCase().indexOf(fName) >= 0;
    });
  }
  if (fFrom || fTo) {
    filtered = filtered.filter(function (r) {
      var iso = parseIsoDateOnly(r.dateIso || r.date_iso || '');
      if (!iso) return false;
      if (fFrom && iso < fFrom) return false;
      if (fTo && iso > fTo) return false;
      return true;
    });
  } else if (fPeriod === 'today') {
    filtered = filtered.filter(function (r) { return isAttendanceRecordToday(r); });
  } else if (fPeriod === 'week') {
    var weekCutoff = new Date(); weekCutoff.setDate(weekCutoff.getDate() - 6); weekCutoff.setHours(0,0,0,0);
    filtered = filtered.filter(function (r) { var iso = r.dateIso || r.date_iso || ''; return iso ? new Date(iso + 'T12:00:00') >= weekCutoff : false; });
  } else if (fPeriod === 'month') {
    var now = new Date();
    var monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
    var monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0);
    filtered = filtered.filter(function (r) {
      var iso = r.dateIso || r.date_iso || '';
      if (!iso) return false;
      var d = new Date(iso + 'T12:00:00');
      return d >= monthStart && d <= monthEnd;
    });
  }
  return filtered.sort(function (a, b) {
    var isoA = attendanceRecordIso(a);
    var isoB = attendanceRecordIso(b);
    if (isoA && isoB) return isoB.localeCompare(isoA);
    return String(b.date || '').localeCompare(String(a.date || ''));
  });
}

async function exportAttExcel() {
  if (!requireActionPermission('attendance', 'export')) return;
  try {
    if (typeof ensureXlsxLoaded === 'function') await ensureXlsxLoaded();
  } catch (e) {
    Swal.fire({ icon: 'error', title: 'خطأ', text: 'مكتبة XLSX غير محملة، الرجاء تحديث الصفحة', ...swalTheme() });
    return;
  }
  if (typeof XLSX === 'undefined') {
    Swal.fire({ icon: 'error', title: 'خطأ', text: 'مكتبة XLSX غير محملة، الرجاء تحديث الصفحة', ...swalTheme() });
    return;
  }
  logActivity('export', 'attendance', 'تصدير تقرير الحضور Excel');
  try {
    var filtered = applyAttendanceFilters(attData);
    var rows = filtered.map(function(r, i) {
      return {
        '#': i + 1,
        'الموظف': attRecordDisplayName(r) || '-',
        'القسم': r.dept || '-',
        'التاريخ': r.date || '-',
        'الحضور': r.ci !== '—' ? r.ci : '',
        'الانصراف': r.co !== '—' ? r.co : '',
        'ساعات العمل': r.hrs !== '—' ? r.hrs : '',
        'التأخير': r.late !== '—' ? r.late : '',
        'الإضافي': r.ot !== '—' ? r.ot : '',
        'الحالة': r.status || '-'
      };
    });
    var wb = XLSX.utils.book_new();
    var ws = XLSX.utils.json_to_sheet(rows, { origin: 'A3' });
    ws['!cols'] = [
      { wch: 5 }, { wch: 22 }, { wch: 18 }, { wch: 20 },
      { wch: 12 }, { wch: 12 }, { wch: 14 }, { wch: 12 }, { wch: 12 }, { wch: 12 }
    ];
    // RTL direction for Arabic Excel
    ws['!dir'] = 'RTL';
    var companyName = appSettings.companyName || 'تقرير الحضور';
    var dateStr = new Date().toLocaleDateString('ar-IQ');
    ws['A1'] = { v: companyName, t: 's' };
    ws['A2'] = { v: 'تقرير الحضور والانصراف - ' + dateStr, t: 's' };
    ws['!merges'] = [
      { s: { r: 0, c: 0 }, e: { r: 0, c: 9 } },
      { s: { r: 1, c: 0 }, e: { r: 1, c: 9 } }
    ];
    XLSX.utils.book_append_sheet(wb, ws, 'تقرير الحضور');
    var fileName = 'تقرير_الحضور_' + new Date().toISOString().slice(0, 10) + '.xlsx';
    XLSX.writeFile(wb, fileName);
    Swal.fire({ icon: 'success', title: 'تم تصدير الملف', text: 'تم تحميل ملف Excel بنجاح', ...swalTheme(), timer: 2000, showConfirmButton: false });
  } catch (e) {
    console.error('exportAttExcel error:', e);
    Swal.fire({ icon: 'error', title: 'خطأ', text: 'حدث خطأ أثناء تصدير Excel: ' + e.message, ...swalTheme() });
  }
}

function buildPrintPage(title, subtitle, headers, rows, extraCss) {
  var dateStr = new Date().toLocaleDateString('ar-IQ', { year: 'numeric', month: 'long', day: 'numeric' });
  var company = esc(String(appSettings.companyName || '\u0646\u0638\u0627\u0645 \u0627\u0644\u062D\u0636\u0648\u0631'));
  var safeTitle = esc(title);
  var safeSubtitle = esc(subtitle);
  var lt = String.fromCharCode(60);
  var end = lt + '/';
  var headerRow = headers.map(function(h) { return lt + 'th>' + h + end + 'th>'; }).join('');
  var bodyRows = rows.map(function(r) {
    return lt + 'tr>' + r.map(function(c) { return lt + 'td>' + (c || '-') + end + 'td>'; }).join('') + end + 'tr>';
  }).join('');
  var css = [
    '*{margin:0;padding:0;box-sizing:border-box}',
    'body{font-family:Cairo,Arial,sans-serif;direction:rtl;background:#fff;color:#1a202c;padding:20px}',
    '.rpt-hd{text-align:center;margin-bottom:20px;padding:16px;border-bottom:2px solid #00d4aa}',
    '.rpt-co{font-size:24px;font-weight:900;color:#1a3a5c}',
    '.rpt-tt{font-size:15px;font-weight:700;color:#2563a8;margin-top:4px}',
    '.rpt-dt{font-size:12px;color:#718096;margin-top:4px}',
    'table{width:100%;border-collapse:collapse;font-size:13px;margin-top:14px}',
    'thead th{background:#1a3a5c;color:#fff;padding:10px;text-align:right;font-size:12px}',
    'tbody td{padding:8px 10px;border-bottom:1px solid #e2e8f0;text-align:right}',
    'tbody tr:nth-child(even){background:#f7fafc}',
    '.rpt-ft{margin-top:20px;text-align:center;font-size:11px;color:#a0aec0}',
    (extraCss || '')
  ].join('');
  var footerTxt = '\u062A\u0645 \u0627\u0644\u0625\u0646\u0634\u0627\u0621 \u0628\u0648\u0627\u0633\u0637\u0629 \u0646\u0638\u0627\u0645 \u0625\u062F\u0627\u0631\u0629 \u0627\u0644\u062D\u0636\u0648\u0631 - ';
  var doc = '<!DOCTYPE html>' + lt + 'html lang="ar" dir="rtl">' + lt + 'head>' + lt + 'meta charset="UTF-8">';
  doc += lt + 'meta name="viewport" content="width=device-width,initial-scale=1">';
  doc += lt + 'title>' + safeTitle + end + 'title>';
  doc += lt + 'link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700;900&display=swap" rel="stylesheet">';
  doc += lt + 'style>' + css + end + 'style>' + end + 'head>' + lt + 'body>';
  doc += lt + 'div class="rpt-hd">' + lt + 'div class="rpt-co">' + company + end + 'div>' + lt + 'div class="rpt-tt">' + safeTitle + end + 'div>' + lt + 'div class="rpt-dt">' + safeSubtitle + ' | ' + dateStr + end + 'div>' + end + 'div>';
  doc += lt + 'table>' + lt + 'thead>' + lt + 'tr>' + headerRow + end + 'tr>' + end + 'thead>' + lt + 'tbody>' + bodyRows + end + 'tbody>' + end + 'table>';
  doc += lt + 'div class="rpt-ft">' + footerTxt + dateStr + end + 'div>';
  doc += end + 'body>' + end + 'html>';
  return doc;
}

function extractReportCss(html) {
  var m = String(html || '').match(/<style>([\s\S]*?)<\/style>/i);
  return m ? m[1] : '';
}

function extractReportBody(html) {
  var m = String(html || '').match(/<body>([\s\S]*?)<\/body>/i);
  return m ? m[1] : String(html || '');
}

function waitForReportFrameReady(frameWin) {
  return new Promise(function(resolve) {
    function done() {
      setTimeout(resolve, 500);
    }
    try {
      if (frameWin.document.readyState === 'complete') done();
      else frameWin.onload = done;
    } catch (e) {
      setTimeout(resolve, 800);
    }
  });
}

function canvasHasContent(canvas) {
  if (!canvas || !canvas.width || !canvas.height) return false;
  var ctx = canvas.getContext('2d');
  if (!ctx) return false;
  var sample = ctx.getImageData(0, 0, Math.min(canvas.width, 400), Math.min(canvas.height, 400)).data;
  var dark = 0;
  for (var i = 0; i < sample.length; i += 16) {
    if (sample[i] < 245 || sample[i + 1] < 245 || sample[i + 2] < 245) dark++;
  }
  return dark > 20;
}

function saveCanvasAsPdf(canvas, filename, orientation) {
  if (typeof BasmaPdf !== 'undefined' && BasmaPdf.saveCanvasAsPdf) {
    return BasmaPdf.saveCanvasAsPdf(canvas, filename, orientation);
  }
  if (typeof jspdf === 'undefined' || !jspdf.jsPDF) {
    console.error('SOFT ERROR:', 'مكتبة jsPDF غير جاهزة');
    return false;
  }
  var safeName = filename || ('report_' + Date.now() + '.pdf');
  var pdf = new jspdf.jsPDF({
    orientation: orientation || 'landscape',
    unit: 'mm',
    format: 'a4',
    compress: true
  });
  var margin = 8;
  var pageW = pdf.internal.pageSize.getWidth();
  var pageH = pdf.internal.pageSize.getHeight();
  var usableW = pageW - margin * 2;
  var usableH = pageH - margin * 2;
  var imgData = canvas.toDataURL('image/jpeg', 0.95);
  var imgW = usableW;
  var imgH = (canvas.height * imgW) / canvas.width;
  var y = margin;
  var remaining = imgH;

  pdf.addImage(imgData, 'JPEG', margin, y, imgW, imgH);
  remaining -= usableH;

  while (remaining > 0) {
    y = margin - (imgH - remaining);
    pdf.addPage();
    pdf.addImage(imgData, 'JPEG', margin, y, imgW, imgH);
    remaining -= usableH;
  }

  pdf.save(safeName);
  return true;
}

async function captureReportCanvas(reportHtml) {
  if (typeof html2canvas === 'undefined') {
    console.error('SOFT ERROR:', 'مكتبة html2canvas غير جاهزة');
    return null;
  }

  var iframe = document.createElement('iframe');
  iframe.setAttribute('aria-hidden', 'true');
  iframe.style.cssText = 'position:fixed;left:0;top:0;width:1200px;height:900px;border:0;background:#fff;opacity:1;pointer-events:none;z-index:1050;';
  document.body.appendChild(iframe);

  var frameWin = iframe.contentWindow;
  var frameDoc = iframe.contentDocument || frameWin.document;
  frameDoc.open();
  frameDoc.write(reportHtml);
  frameDoc.close();

  try {
    await waitForReportFrameReady(frameWin);
    if (frameWin.document.fonts && frameWin.document.fonts.ready) {
      try { await frameWin.document.fonts.ready; } catch (e) {}
    }
    await new Promise(function(resolve) {
      requestAnimationFrame(function() { requestAnimationFrame(resolve); });
    });

    var body = frameDoc.body;
    var width = Math.max(body.scrollWidth, body.offsetWidth, 1100);
    var height = Math.max(body.scrollHeight, body.offsetHeight, 600);

    var canvas = await html2canvas(body, {
      window: frameWin,
      scale: 2,
      useCORS: true,
      allowTaint: true,
      backgroundColor: '#ffffff',
      logging: false,
      width: width,
      height: height,
      scrollX: 0,
      scrollY: 0
    });

    if (!canvasHasContent(canvas)) {
      console.error('SOFT ERROR:', 'تعذر التقاط محتوى التقرير. جرّب المعاينة ثم احفظ من المتصفح.');
      return null;
    }

    return canvas;
  } finally {
    if (iframe.parentNode) iframe.parentNode.removeChild(iframe);
  }
}

async function downloadReportPdfFromHtml(reportHtml, filename) {
  try {
    if (typeof ensurePdfLibsLoaded === 'function') await ensurePdfLibsLoaded();
    var canvas = await captureReportCanvas(reportHtml);
    saveCanvasAsPdf(canvas, filename, 'landscape');
    return true;
  } catch (e) {
    console.error('downloadReportPdfFromHtml error:', e);
    Swal.fire({ icon:'error', title:'فشل إنشاء PDF', text: e.message || 'حدث خطأ أثناء إنشاء الملف', ...swalTheme() });
    return false;
  }
}

async function presentPdfActions(reportHtml, filename) {
  var choice = await Swal.fire({
    title: 'خيارات ملف PDF',
    text: 'اختر الإجراء المطلوب',
    icon: 'question',
    showCancelButton: true,
    showDenyButton: true,
    confirmButtonText: 'معاينة',
    denyButtonText: 'تحميل',
    cancelButtonText: 'إلغاء',
    ...swalTheme()
  });
  if (choice.isConfirmed) {
    logActivity('export', 'reports', 'معاينة تقرير PDF: ' + (filename || 'تقرير'), { targetName: filename });
    var win = window.open('', '_blank', 'width=1100,height=760');
    if (!win) {
      Swal.fire({ icon:'warning', title:'تنبيه', text:'يرجى السماح بالنوافذ المنبثقة لهذا الموقع', ...swalTheme() });
      return;
    }
    win.document.open();
    win.document.write(reportHtml);
    win.document.close();
    return;
  }
  if (choice.isDenied) {
    Swal.fire({
      title: 'جاري إنشاء PDF...',
      allowOutsideClick: false,
      didOpen: function() { Swal.showLoading(); },
      ...swalTheme()
    });
    var ok = await downloadReportPdfFromHtml(reportHtml, filename);
    Swal.close();
    if (ok) {
      logActivity('download', 'reports', 'تحميل ملف PDF: ' + (filename || 'تقرير'), { targetName: filename });
      Swal.fire({ icon:'success', title:'تم التحميل', text:'تم حفظ ملف PDF على جهازك', timer: 2200, showConfirmButton: false, ...swalTheme() });
    }
  }
}

function exportAttPdf() {
  if (!requireActionPermission('attendance', 'export')) return;
  try {
    logActivity('export', 'attendance', 'تصدير تقرير الحضور PDF');
    var fDept = document.getElementById('att-filter-dept')?.value || '';
    var fPeriod = document.getElementById('att-filter-period')?.value || 'today';
    var fFrom = parseIsoDateOnly(document.getElementById('att-filter-from')?.value || '');
    var fTo = parseIsoDateOnly(document.getElementById('att-filter-to')?.value || '');
    var filtered = applyAttendanceFilters(attData);
    var statusClass = { 'طبيعي':'status-present','متأخر':'status-late','غياب':'status-absent','إضافي':'status-ot' };
    var headers = ['#','الموظف','القسم','التاريخ','الحضور','الانصراف','ساعات العمل','التأخير','إضافي','الحالة'];
    var rows = filtered.map((r, i) => [
      i + 1, esc(attRecordDisplayName(r) || '—'), esc(r.dept || '—'), esc(r.date || '—'),
      esc(r.ci !== '—' ? r.ci : '—'), esc(r.co !== '—' ? r.co : '—'),
      esc(r.hrs !== '—' ? r.hrs : '—'), esc(r.late !== '—' ? r.late : '—'),
      esc(r.ot !== '—' ? r.ot : '—'),
      '<span class="' + (statusClass[r.status] || '') + '">' + esc(r.status || '—') + '</span>'
    ]);
    var periodLabel = (fFrom || fTo)
      ? ('من ' + (fFrom || 'البداية') + ' إلى ' + (fTo || 'النهاية'))
      : (fPeriod === 'today' ? 'اليوم' : fPeriod === 'week' ? 'هذا الأسبوع' : fPeriod === 'month' ? 'هذا الشهر' : 'جميع السجلات');
    var html = buildPrintPage('تقرير الحضور والانصراف', periodLabel + (fDept ? ' — ' + esc(fDept) : ''), headers, rows, '');
    presentPdfActions(html, 'تقرير_الحضور_' + new Date().toISOString().slice(0, 10) + '.pdf');
  } catch(e) {
    console.error('exportAttPdf error:', e);
    Swal.fire({ icon:'error', title:'خطأ في التصدير', text: e.message, ...swalTheme() });
  }
}

// ======= SALARIES =======

function salaryPeriodInfo(type) {
  const now = new Date();
  const y = now.getFullYear();
  const m = now.getMonth();
  const stdDays = getStandardMonthDays();
  const splitDay = getBiweeklySplitDay();
  if (type === 'biweekly') {
    const firstHalf = now.getDate() <= splitDay;
    const calEndDay = new Date(y, m + 1, 0).getDate();
    const start = new Date(y, m, firstHalf ? 1 : splitDay + 1);
    const endDay = firstHalf ? Math.min(splitDay, calEndDay) : calEndDay;
    const end = new Date(y, m, endDay, 23, 59, 59);
    const h1Days = splitDay;
    const h2Days = Math.max(1, stdDays - splitDay);
    const totalDays = firstHalf ? h1Days : h2Days;
    let elapsedDays;
    if (firstHalf) {
      elapsedDays = Math.min(Math.max(1, now.getDate()), h1Days);
    } else {
      elapsedDays = Math.min(Math.max(1, now.getDate() - splitDay), h2Days);
    }
    return { start, end, elapsedDays, totalDays };
  }
  const start = new Date(y, m, 1);
  const end = new Date(y, m + 1, 0, 23, 59, 59);
  return { start, end, elapsedDays: Math.min(now.getDate(), stdDays), totalDays: stdDays };
}

function salaryPeriodKey(type) {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  if (type === 'biweekly') {
    return y + '-' + m + (now.getDate() <= getBiweeklySplitDay() ? '-H1' : '-H2');
  }
  return y + '-' + m;
}

function isSalaryPaidForCurrentPeriod(emp) {
  if (!emp) return false;
  const periodKey = salaryPeriodKey(emp.salaryType || 'monthly');
  const marker = (appSettings.salaryDeletedMap || {})[String(emp.id)];
  const markerPeriod = typeof marker === 'object' && marker ? marker.period : marker;
  if (typeof marker === 'object' && marker && marker.reason === 'paid' && markerPeriod === periodKey) return true;
  if (String(emp.salStatus || emp.sal_status || '') === 'مدفوع' && emp.salDeletedPeriod === periodKey) return true;
  if (String(emp.salStatus || emp.sal_status || '') === 'مدفوع' && !emp.salDeletedPeriod && !markerPeriod) return true;
  if (Array.isArray(emp.salaryHistoryData)) {
    return emp.salaryHistoryData.some(function (rec) {
      return rec && String(rec.monthIso || rec.month_iso || '') === periodKey && String(rec.status || '') === 'مدفوع';
    });
  }
  return false;
}

function isSalaryHiddenForCurrentPeriod(emp) {
  if (!emp) return false;
  const periodKey = salaryPeriodKey(emp.salaryType || 'monthly');
  const deletedMap = appSettings.salaryDeletedMap || {};
  const marker = deletedMap[String(emp.id)];
  const markerPeriod = typeof marker === 'object' && marker ? marker.period : marker;
  if (isSalaryPaidForCurrentPeriod(emp)) return true;
  const hasAttendanceInPeriod = attData.some(r => r.empId === emp.id && recordInPeriod(r, salaryPeriodInfo(emp.salaryType || 'monthly')));
  if (hasAttendanceInPeriod) return false;
  return emp.salDeletedPeriod === periodKey || markerPeriod === periodKey;
}

function recordInPeriod(record, period) {
  if (!record || !period) return false;
  var iso = typeof attendanceRecordIso === 'function'
    ? attendanceRecordIso(record)
    : String(record.dateIso || record.date_iso || '').slice(0, 10);
  if (!iso || !/^\d{4}-\d{2}-\d{2}$/.test(iso)) return false;
  var d = new Date(iso + 'T12:00:00');
  if (isNaN(d.getTime())) return false;
  var start = period.start instanceof Date ? period.start : new Date(period.start);
  var end = period.end instanceof Date ? period.end : new Date(period.end);
  if (isNaN(start.getTime()) || isNaN(end.getTime())) return false;
  var dayStart = new Date(start.getFullYear(), start.getMonth(), start.getDate(), 0, 0, 0);
  var dayEnd = new Date(end.getFullYear(), end.getMonth(), end.getDate(), 23, 59, 59);
  return d >= dayStart && d <= dayEnd;
}

function parseDurationMinutes(value) {
  const s = String(value || '').trim();
  if (!s || s === '—') return 0;
  const colonMatch = s.match(/^(\d{1,2}):(\d{2})$/);
  if (colonMatch) {
    const h = parseInt(colonMatch[1], 10) || 0;
    const m = parseInt(colonMatch[2], 10) || 0;
    return (h * 60) + m;
  }
  let minutes = 0;
  const hourMatch = s.match(/(\d+)\s*(?:س|h|hour)/i);
  const minMatch = s.match(/(\d+)\s*(?:د|m|min)/i);
  if (hourMatch) minutes += parseInt(hourMatch[1], 10) * 60;
  if (minMatch) minutes += parseInt(minMatch[1], 10);
  if (!hourMatch && !minMatch) {
    const n = parseInt(s.replace(/[^\d]/g, ''), 10);
    if (Number.isFinite(n)) minutes += n;
  }
  return minutes;
}

// Centralized salary calculation — legacy client path (fallback when RPC mode off or cache miss)
var _salaryPreviewCache = {};

function clearSalaryCacheForEmployee(id) {
  var empId = parseInt(id, 10);
  if (!empId) return;
  Object.keys(_salaryPreviewCache).forEach(function (k) {
    if (k.indexOf(String(empId) + '|') === 0) delete _salaryPreviewCache[k];
  });
}

function mapServerSalaryPreview(d) {
  if (!d) return null;
  var baseSalary = d.base_salary || 0;
  var bonus = d.bonus || 0;
  var totalDeduct = d.total_deduct || 0;
  var otAmount = d.overtime_amount || 0;
  var otInNet = d.overtime_in_net === true || d.include_overtime_in_salary === true;
  return {
    baseSalary: baseSalary,
    lateDeduct: d.late_deduct || 0,
    absentDeduct: d.absent_deduct || 0,
    leaveDeduct: d.leave_deduct || 0,
    leaveItems: Array.isArray(d.leave_items) ? d.leave_items : (d.leave_items ? JSON.parse(JSON.stringify(d.leave_items)) : []),
    totalDeduct: totalDeduct,
    ot: otAmount,
    overtimeInNet: otInNet,
    includeOvertimeInSalary: otInNet,
    bonus: bonus,
    manualDeduct: d.manual_deduct || 0,
    loanDeduct: d.loan_deduct || 0,
    loanItems: Array.isArray(d.loan_items) ? d.loan_items : [],
    financeItems: [],
    final: computeSalaryNetAmount(baseSalary, bonus, totalDeduct, otAmount, otInNet, false),
    attendDays: d.attend_days || 0,
    absentDays: d.absent_days || 0,
    leaveDays: d.leave_days || 0,
    paidLeaveDays: d.paid_leave_days || 0,
    leaveCoveredDays: d.leave_covered_days || 0,
    officialPaidClosureDays: d.official_paid_closure_days || 0,
    officialUnpaidClosureDays: d.official_unpaid_closure_days || 0,
    totalLateMin: d.late_minutes || 0,
    totalOvertimeMin: d.overtime_minutes || 0,
    isComm: false,
    isBiw: false,
    dailyRate: d.daily_rate || 0,
    periodDays: d.period_days || 0,
    elapsedDays: d.elapsed_days || 0,
    monthIso: d.month_iso || '',
    monthLabel: d.month_label || ''
  };
}

function emptySalaryPreview(emp) {
  return {
    baseSalary: 0,
    lateDeduct: 0,
    absentDeduct: 0,
    leaveDeduct: 0,
    leaveItems: [],
    totalDeduct: 0,
    ot: 0,
    bonus: 0,
    manualDeduct: 0,
    loanDeduct: 0,
    financeItems: [],
    final: 0,
    attendDays: 0,
    absentDays: 0,
    leaveDays: 0,
    paidLeaveDays: 0,
    leaveCoveredDays: 0,
    officialPaidClosureDays: 0,
    officialUnpaidClosureDays: 0,
    totalLateMin: 0,
    totalOvertimeMin: 0,
    isComm: (emp && emp.salaryType) === 'commission',
    isBiw: (emp && emp.salaryType) === 'biweekly',
    dailyRate: 0,
    periodDays: 0,
    elapsedDays: 0,
    _pendingServerCalc: true
  };
}

function applyLocalLeaveDeductionsToSalary(emp, salaryPreview) {
  return salaryPreview;
}

function parseMoneyFromText(text) {
  var s = String(text || '').replace(/[,\s]/g, '');
  var m = s.match(/(\d{3,})(?=IQD|دينار|$)/i) || s.match(/(\d+)/);
  return m ? (parseInt(m[1], 10) || 0) : 0;
}

function localAbsenceDaysCount(leave) {
  if (!leave) return 1;
  var n = parseInt(leave.absenceDays != null ? leave.absenceDays : (leave.absence_days != null ? leave.absence_days : leave.multiplier), 10);
  return Math.max(1, Number.isFinite(n) ? n : 1);
}

function normalizeLeaveType(leave) {
  var t = String((leave && (leave.leaveType || leave.leave_type || leave.type)) || 'paid_single').trim();
  if (t === 'annual' || t === 'sick' || t === 'paid') return 'paid_single';
  if (t === 'unpaid') return 'unpaid_single';
  return t;
}

function leaveEffectiveDaysInPeriod(leave, period) {
  if (!leave || !period) return 0;
  var fromIso = String(leave.fromDate || leave.from_date || leave.date || '').trim();
  if (!fromIso) return 0;
  var leaveType = normalizeLeaveType(leave);
  if (leaveType === 'paid_open' || leaveType === 'unpaid_open') {
    var toIso = String(leave.toDate || leave.to_date || fromIso).trim();
    return leaveDaysInSalaryPeriod(fromIso, toIso, period);
  }
  var d = new Date(fromIso + 'T12:00:00');
  if (isNaN(d.getTime())) return 0;
  return (d >= period.start && d <= period.end) ? 1 : 0;
}

function isDateOnEmployeeLeave(empId, dateIso) {
  if (!empId || !dateIso) return false;
  var iso = String(dateIso).slice(0, 10);
  return (window.leavesData || []).some(function (l) {
    if (!l || String(l.empId || l.employee_id) !== String(empId)) return false;
    var fromIso = String(l.fromDate || l.from_date || l.date || '').slice(0, 10);
    if (!fromIso) return false;
    var leaveType = normalizeLeaveType(l);
    if (leaveType === 'paid_open' || leaveType === 'unpaid_open') {
      var toIso = String(l.toDate || l.to_date || fromIso).slice(0, 10);
      return iso >= fromIso && iso <= toIso;
    }
    return iso === fromIso;
  });
}

function localLeaveDaysCount(fromDate, toDate) {
  if (!fromDate) return 1;
  if (!toDate) return 1;
  var a = new Date(fromDate + 'T00:00:00');
  var b = new Date(toDate + 'T00:00:00');
  if (isNaN(a.getTime()) || isNaN(b.getTime())) return 1;
  return Math.max(1, Math.round((b - a) / 86400000) + 1);
}

function leaveDaysInSalaryPeriod(fromDate, toDate, period) {
  if (!fromDate || !period) return 1;
  var effFrom = new Date(fromDate + 'T12:00:00');
  var effTo = new Date((toDate || fromDate) + 'T12:00:00');
  if (isNaN(effFrom.getTime()) || isNaN(effTo.getTime())) return 1;
  if (effTo < period.start || effFrom > period.end) return 0;
  var start = effFrom < period.start ? period.start : effFrom;
  var end = effTo > period.end ? period.end : effTo;
  return Math.max(1, Math.round((end - start) / 86400000) + 1);
}

function buildSalaryDeductionBreakdown(emp) {
  var salaryType = emp.salaryType || 'monthly';
  var isComm = salaryType === 'commission';
  var fullPeriod = salaryPeriodInfo(salaryType);
  var completedPeriod = salaryCompletedPeriodInfo(salaryType);
  var dailyRate = typeof getEmpDailyRate === 'function' ? getEmpDailyRate(emp) : 0;
  var base = isComm ? 0 : (parseExactInt(emp.salary, 0) || 0);
  if (salaryType === 'biweekly') base = parseExactInt(emp.salaryHalf, 0) || Math.round(base / 2);
  if (!dailyRate && base > 0) dailyRate = Math.round(base / (typeof getStandardMonthDays === 'function' ? getStandardMonthDays() : 30));

  var empHireIso = /^\d{4}-\d{2}-\d{2}/.test(String(emp.hireDate || '')) ? String(emp.hireDate).slice(0, 10) : '';

  var attendDays = 0;
  var recordedAbsentTotal = 0;
  var recordedAbsentCompleted = 0;
  var totalLateMin = 0;
  var leaveCoveredDays = 0;
  var paidLeaveDays = 0;
  var leaveDeduct = 0;
  var leaveDays = 0;
  var officialPaidClosureDays = 0;
  var officialUnpaidClosureDays = 0;
  var attendSeen = {};
  var absentSeen = {};

  (attData || []).forEach(function (r) {
    if (!r || r.empId !== emp.id) return;
    var dayKey = typeof attendanceRecordIso === 'function'
      ? attendanceRecordIso(r)
      : String(r.dateIso || r.date_iso || '').slice(0, 10);
    if (!dayKey) return;
    if (!recordInPeriod(r, fullPeriod)) return;
    var inCompleted = recordInPeriod(r, completedPeriod);
    var hasCi = !!(r.ci && r.ci !== '—');
    var hasCo = !!(r.co && r.co !== '—');
    var closureHit = typeof officialClosureForDate === 'function' ? officialClosureForDate(dayKey) : null;

    if (inCompleted && hasCi && hasCo) {
      if (!attendSeen[dayKey]) {
        attendSeen[dayKey] = true;
        attendDays++;
      }
      if (!isComm && !emp.openHours) {
        totalLateMin += calcAttendanceShortMinutes(emp, r);
      }
    }

    // تاريخ المباشرة: لا يُحتسب أي غياب قبله (مطابقة لمنطق الخادم effective_start)
    var beforeHire = empHireIso && dayKey < empHireIso;

    if (r.status === 'غياب'
        && !beforeHire
        && !isDateOnEmployeeLeave(emp.id, dayKey)
        && !closureHit
        && !absentSeen[dayKey]) {
      absentSeen[dayKey] = true;
      recordedAbsentTotal++;
      if (inCompleted) recordedAbsentCompleted++;
    }
  });

  (window.leavesData || []).forEach(function (l) {
    if (!l || String(l.empId) !== String(emp.id)) return;
    var fromIso = String(l.fromDate || l.from_date || l.date || '').trim();
    if (!fromIso) return;
    var days = leaveEffectiveDaysInPeriod(l, completedPeriod);
    if (!days) return;
    var leaveType = normalizeLeaveType(l);
    leaveCoveredDays += days;
    if (leaveType === 'paid_single' || leaveType === 'paid_open') {
      paidLeaveDays += days;
      return;
    }
    if (leaveType === 'unpaid_open') {
      leaveDays += days;
      leaveDeduct += Math.round(days * dailyRate);
    } else if (leaveType === 'unpaid_single') {
      leaveDays += 1;
      leaveDeduct += dailyRate;
    } else if (leaveType === 'absence_mult') {
      var mult = localAbsenceDaysCount(l);
      leaveDays += 1;
      leaveDeduct += Math.round(mult * dailyRate);
    }
  });

  var completedFromIso = completedPeriod && completedPeriod.start ? localDateToIso(completedPeriod.start) : '';
  var completedToIso = completedPeriod && completedPeriod.end ? localDateToIso(completedPeriod.end) : '';
  officialPaidClosureDays = countOfficialClosureDaysBetween(completedFromIso, completedToIso, 'paid');
  officialUnpaidClosureDays = countOfficialClosureDaysBetween(completedFromIso, completedToIso, 'unpaid');
  if (!isComm) {
    leaveCoveredDays += officialPaidClosureDays + officialUnpaidClosureDays;
    paidLeaveDays += officialPaidClosureDays;
    leaveDays += officialUnpaidClosureDays;
    leaveDeduct += Math.round(officialUnpaidClosureDays * dailyRate);
  }

  var elapsedWorkDays = salaryPeriodWorkDaysElapsed(salaryType);
  // تاريخ المباشرة: تبدأ نافذة احتساب الأيام المنقضية من max(بداية الفترة، تاريخ المباشرة)
  if (empHireIso && !isComm) {
    var hireClean = parseIsoDateOnly(empHireIso);
    if (hireClean) {
      var hireStart = new Date(hireClean + 'T12:00:00');
      if (hireStart > fullPeriod.start) {
        var effEnd = completedPeriod && completedPeriod.end ? completedPeriod.end : fullPeriod.end;
        elapsedWorkDays = (effEnd >= hireStart)
          ? Math.min(fullPeriod.totalDays || 31, countWorkDaysBetween(hireStart, effEnd))
          : 0;
      }
    }
  }
  var expectedAbsent = isComm ? 0 : Math.max(0, elapsedWorkDays - attendDays - recordedAbsentCompleted - leaveCoveredDays);
  var absentDays = recordedAbsentTotal + expectedAbsent;
  var lateDeduct = calcLateDeductAmount(emp, totalLateMin, dailyRate);
  var absentDeduct = isComm ? 0 : Math.round(absentDays * dailyRate);
  var finance = employeeFinanceSummaryFromVisibleData(emp);
  var totalDeduct = lateDeduct + absentDeduct + leaveDeduct + finance.deductions + finance.loans;

  return {
    attendDays: attendDays,
    absentDays: absentDays,
    recordedAbsent: recordedAbsentTotal,
    recordedAbsentCompleted: recordedAbsentCompleted,
    expectedAbsent: expectedAbsent,
    leaveCoveredDays: leaveCoveredDays,
    paidLeaveDays: paidLeaveDays,
    lateDeduct: lateDeduct,
    absentDeduct: absentDeduct,
    leaveDeduct: leaveDeduct,
    leaveDays: leaveDays,
    officialPaidClosureDays: officialPaidClosureDays,
    officialUnpaidClosureDays: officialUnpaidClosureDays,
    totalLateMin: totalLateMin,
    manualDeduct: finance.deductions,
    loanDeduct: finance.loans,
    bonus: finance.bonuses,
    totalDeduct: totalDeduct,
    dailyRate: dailyRate,
    baseSalary: base,
    elapsedDays: fullPeriod.elapsedDays
  };
}

function formatSalaryDeductionBreakdown(sal) {
  if (!sal) return '';
  var parts = [];
  if ((sal.lateDeduct || 0) > 0) {
    var lateLabel = 'نقص دوام';
    if (sal.totalLateMin > 0) lateLabel += ' (' + sal.totalLateMin + ' د)';
    parts.push(lateLabel + ': ' + sal.lateDeduct.toLocaleString());
  }
  if ((sal.absentDeduct || 0) > 0) parts.push('غياب: ' + sal.absentDeduct.toLocaleString());
  if ((sal.leaveDeduct || 0) > 0) parts.push('إجازات: ' + sal.leaveDeduct.toLocaleString());
  if ((sal.manualDeduct || 0) > 0) parts.push('خصومات مالية: ' + sal.manualDeduct.toLocaleString());
  if ((sal.loanDeduct || 0) > 0) parts.push('سلف: ' + sal.loanDeduct.toLocaleString());
  if ((sal.officialUnpaidClosureDays || 0) > 0) parts.push('تعطيل بدون راتب: ' + sal.officialUnpaidClosureDays + ' يوم');
  if ((sal.officialPaidClosureDays || 0) > 0) parts.push('تعطيل براتب: ' + sal.officialPaidClosureDays + ' يوم');
  if ((sal.paidLeaveDays || 0) > 0) parts.push('إجازات مدفوعة: ' + sal.paidLeaveDays + ' يوم');
  return parts.join(' | ');
}

function computeSalaryNetAmount(baseSalary, bonus, totalDeduct, ot, otInNet, isComm) {
  if (isComm) return parseInt(bonus, 10) || 0;
  return (parseInt(baseSalary, 10) || 0)
    + (parseInt(bonus, 10) || 0)
    - (parseInt(totalDeduct, 10) || 0)
    + (otInNet ? (parseInt(ot, 10) || 0) : 0);
}

function isSalaryNetNegative(net) {
  return (parseInt(net, 10) || 0) < 0;
}

function formatSalaryNetAmount(net, withCurrency) {
  var n = parseInt(net, 10) || 0;
  var text = n.toLocaleString();
  return withCurrency ? text + ' IQD' : text;
}

function salaryNetNegativeTitle(net) {
  if (!isSalaryNetNegative(net)) return '';
  return 'راتب سالب — الخصومات أعلى من الراتب الأساسي والمكافآت. الصافي: ' + formatSalaryNetAmount(net, true);
}

function salaryNetTableCellHtml(final, isComm) {
  if (isComm) {
    return { html: 'يُحسب يدوياً', tdClass: '', tdStyle: 'color:var(--accent);font-weight:700', title: '' };
  }
  var formatted = formatSalaryNetAmount(final, false);
  if (isSalaryNetNegative(final)) {
    return {
      html: formatted,
      tdClass: 'sal-net-negative',
      tdStyle: '',
      title: salaryNetNegativeTitle(final)
    };
  }
  return {
    html: formatted,
    tdClass: '',
    tdStyle: 'color:var(--accent);font-weight:700',
    title: ''
  };
}

function salaryNetPdfHtml(net, isComm) {
  if (isComm) return esc('يُحسب يدوياً');
  var formatted = formatSalaryNetAmount(net, true);
  if (!isSalaryNetNegative(net)) {
    return '<strong style="color:#276749">' + esc(formatted) + '</strong>';
  }
  return '<strong class="sal-net-negative-inline" title="' + escAttr(salaryNetNegativeTitle(net)) + '">' + esc(formatted) + ' (سالب)</strong>';
}

function salaryNetInlineHtml(net, isComm) {
  if (isComm) return esc('يُحسب يدوياً');
  var formatted = esc(formatSalaryNetAmount(net, true));
  if (!isSalaryNetNegative(net)) {
    return '<b style="color:#68d391">' + formatted + '</b>';
  }
  return '<b class="sal-net-negative-inline" title="' + escAttr(salaryNetNegativeTitle(net)) + '">' + formatted + ' (سالب)</b>';
}

function applySalaryNetElementStyle(el, net, isComm) {
  if (!el) return;
  if (isComm || !isSalaryNetNegative(net)) {
    el.classList.remove('sal-net-negative');
    el.removeAttribute('title');
    return;
  }
  el.classList.add('sal-net-negative');
  el.title = salaryNetNegativeTitle(net);
}

function employeeFinanceSummaryFromVisibleData(emp) {
  if (!emp) return { deductions: 0, bonuses: 0, loans: 0, items: [] };
  if (typeof financeTotalsForSalary === 'function') {
    try { return financeTotalsForSalary(emp); } catch (e) {}
  }
  return { deductions: 0, bonuses: 0, loans: 0, items: [] };
}

function calcEmployeeVisibleSalaryFallback(emp) {
  var empty = emptySalaryPreview(emp);
  if (!emp) return empty;
  var salaryType = emp.salaryType || 'monthly';
  var isComm = salaryType === 'commission';
  var breakdown = buildSalaryDeductionBreakdown(emp);
  return Object.assign(empty, {
    baseSalary: breakdown.baseSalary,
    totalDeduct: breakdown.totalDeduct,
    lateDeduct: breakdown.lateDeduct,
    absentDeduct: breakdown.absentDeduct,
    leaveDeduct: breakdown.leaveDeduct,
    leaveDays: breakdown.leaveDays,
    officialPaidClosureDays: breakdown.officialPaidClosureDays,
    officialUnpaidClosureDays: breakdown.officialUnpaidClosureDays,
    paidLeaveDays: breakdown.paidLeaveDays,
    leaveCoveredDays: breakdown.leaveCoveredDays,
    attendDays: breakdown.attendDays,
    absentDays: breakdown.absentDays,
    totalLateMin: breakdown.totalLateMin,
    manualDeduct: breakdown.manualDeduct,
    loanDeduct: breakdown.loanDeduct,
    bonus: breakdown.bonus,
    final: isComm ? breakdown.bonus : computeSalaryNetAmount(breakdown.baseSalary, breakdown.bonus, breakdown.totalDeduct, 0, false, false),
    dailyRate: breakdown.dailyRate,
    elapsedDays: breakdown.elapsedDays,
    isComm: isComm,
    isBiw: salaryType === 'biweekly',
    _localVisibleCalc: true,
    _pendingServerCalc: false
  });
}

async function prefetchSalaryPreviews(empList) {
  if (typeof kynoRequiresServerSalary === 'function' ? !kynoRequiresServerSalary() : (typeof isKynoRpcMode !== 'function' || !isKynoRpcMode())) return;
  if (typeof sb_previewSalary !== 'function') return;
  _salaryPreviewCache = {};
  if (typeof currentUser !== 'undefined' && currentUser === 'emp') return;
  if (typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession) {
    try {
      if (!(await AuthApi.hasAuthenticatedSession())) return;
    } catch (e) { return; }
  }
  var list = empList || employees || [];
  await Promise.all(list.map(function (e) {
    if (!e || !e.id) return Promise.resolve();
    var m = salaryPeriodKey(e.salaryType || 'monthly');
    return sb_previewSalary(e.id, m).then(function (res) {
      if (res && res.ok) _salaryPreviewCache[e.id + '|' + m] = res;
    }).catch(function (err) { console.warn('prefetchSalaryPreviews:', err); });
  }));
}

async function refreshSalaryUiAfterPayrollChange(empIds) {
  var list = employees || [];
  if (empIds && empIds.length) {
    var wanted = {};
    empIds.forEach(function (id) {
      var n = parseInt(id, 10);
      if (n) wanted[n] = true;
    });
    list = list.filter(function (e) { return e && wanted[e.id]; });
  }
  list.forEach(function (e) {
    if (e && e.id) clearSalaryCacheForEmployee(e.id);
  });
  if (typeof prefetchSalaryPreviews === 'function' && list.length) {
    try {
      await prefetchSalaryPreviews(list);
    } catch (e) {
      console.warn('refreshSalaryUiAfterPayrollChange:', e);
    }
  }
  if (document.getElementById('sal-table') && typeof buildSalaries === 'function') buildSalaries();
  var dashPage = document.getElementById('page-dashboard');
  if (dashPage && dashPage.classList.contains('active') && typeof buildDashboard === 'function') buildDashboard();
  if (currentUser === 'emp' && typeof buildEmpPortal === 'function') buildEmpPortal();
}

function calcEmpSalary(emp) {
  if (!emp || !emp.id) return emptySalaryPreview(emp);
  if (isSalaryPaidForCurrentPeriod(emp)) return emptySalaryPreview(emp);
  var m = salaryPeriodKey(emp.salaryType || 'monthly');
  var cached = _salaryPreviewCache[emp.id + '|' + m];
  if (cached && cached.ok !== false) {
    var mapped = mapServerSalaryPreview(cached);
    if (mapped) {
      // Safety net: ignore server late fields when they are stale. Recompute
      // late minutes and deduction from visible attendance records.
      var localBreakdown = buildSalaryDeductionBreakdown(emp);
      var correctedLate = localBreakdown.lateDeduct || 0;
      mapped.totalLateMin = localBreakdown.totalLateMin || 0;
      mapped.lateDeduct = correctedLate;
      mapped.absentDeduct = localBreakdown.absentDeduct || 0;
      mapped.leaveDeduct = localBreakdown.leaveDeduct || 0;
      mapped.attendDays = localBreakdown.attendDays || 0;
      mapped.absentDays = localBreakdown.absentDays || 0;
      mapped.leaveDays = localBreakdown.leaveDays || 0;
      mapped.paidLeaveDays = localBreakdown.paidLeaveDays || 0;
      mapped.leaveCoveredDays = localBreakdown.leaveCoveredDays || 0;
      mapped.officialPaidClosureDays = localBreakdown.officialPaidClosureDays || 0;
      mapped.officialUnpaidClosureDays = localBreakdown.officialUnpaidClosureDays || 0;
      mapped.manualDeduct = localBreakdown.manualDeduct || 0;
      mapped.loanDeduct = localBreakdown.loanDeduct || 0;
      mapped.bonus = localBreakdown.bonus || 0;
      mapped.totalDeduct = Math.max(
        0,
        (mapped.lateDeduct || 0) +
        (mapped.absentDeduct || 0) +
        (mapped.leaveDeduct || 0) +
        (mapped.manualDeduct || 0) +
        (mapped.loanDeduct || 0)
      );
      if ((emp.salaryType || 'monthly') !== 'commission') {
        mapped.final = computeSalaryNetAmount(
          mapped.baseSalary,
          mapped.bonus,
          mapped.totalDeduct,
          mapped.ot,
          mapped.overtimeInNet,
          false
        );
      }
      mapped.isComm = (emp.salaryType || 'monthly') === 'commission';
      mapped.isBiw = (emp.salaryType || 'monthly') === 'biweekly';
      emp.days = mapped.attendDays;
      emp.lateMin = mapped.totalLateMin;
      return mapped;
    }
  }
  return calcEmployeeVisibleSalaryFallback(emp);
}

function buildCurrentSalaryHistoryRecord(emp, status) {
  if (!emp) return null;
  var sal = calcEmpSalary(emp);
  var monthIso = salaryPeriodKey(emp.salaryType || 'monthly');
  var now = new Date();
  var paidAt = status === 'مدفوع' ? now.toISOString() : '';
  var monthLabel = salaryPeriodDateFromKey(monthIso);
  var deduct = sal.totalDeduct != null ? sal.totalDeduct : ((sal.lateDeduct || 0) + (sal.manualDeduct || 0) + (sal.loanDeduct || 0) + (sal.leaveDeduct || 0) + (sal.absentDeduct || 0));
  return {
    id: 'sal_' + monthIso + '_' + emp.id,
    monthIso: monthIso,
    month_iso: monthIso,
    month: monthLabel,
    month_label: monthLabel,
    base: sal.baseSalary || emp.salary || 0,
    base_salary: sal.baseSalary || emp.salary || 0,
    days: sal.attendDays || emp.days || 0,
    attend_days: sal.attendDays || emp.days || 0,
    lateMin: sal.totalLateMin || emp.lateMin || 0,
    late_minutes: sal.totalLateMin || emp.lateMin || 0,
    lateDeduct: sal.lateDeduct || 0,
    late_deduct: sal.lateDeduct || 0,
    absent_days: sal.absentDays || 0,
    ot: sal.ot || 0,
    overtime_amount: sal.ot || 0,
    bonus: sal.bonus || 0,
    deduct: deduct || 0,
    total_deduct: deduct || 0,
    final: sal.final || 0,
    net_salary: sal.final || 0,
    status: status || emp.salStatus || 'مُصدر',
    paidAt: paidAt,
    paid_at: paidAt,
    issuedAt: new Date().toISOString()
  };
}

async function upsertCurrentSalaryHistoryForEmployee(emp, status) {
  if (!emp) return null;
  var rec = buildCurrentSalaryHistoryRecord(emp, status);
  if (!rec) return null;
  if (!Array.isArray(emp.salaryHistoryData)) emp.salaryHistoryData = [];
  var saved = null;
  if (typeof sb_upsertSalaryRecord === 'function') {
    saved = await sb_upsertSalaryRecord(emp.id, rec);
    if (saved) rec = Object.assign({}, rec, saved);
  }
  var key = String(rec.monthIso || rec.month_iso || '');
  var idx = emp.salaryHistoryData.findIndex(function (x) {
    return x && String(x.monthIso || x.month_iso || '') === key;
  });
  if (idx >= 0) emp.salaryHistoryData[idx] = Object.assign({}, emp.salaryHistoryData[idx], rec, { status: status || rec.status });
  else emp.salaryHistoryData.unshift(rec);
  emp.salaryHistoryInit = true;
  return rec;
}

/** @deprecated — payroll is server-only via saas_v3_compute_salary */
function calcEmpSalaryLegacy(emp) {
  return calcEmpSalary(emp);
}

var _activeSalaryTab = 'current';
var _paidSalaryRecords = [];
var _paidSalaryRecordsLoading = false;

function formatSalaryDateSlash(value) {
  if (!value) return '';
  var d = value instanceof Date ? value : new Date(String(value));
  if (isNaN(d.getTime())) {
    var s = String(value || '').trim();
    var m = s.match(/^(\d{4})[-/](\d{1,2})(?:[-/](\d{1,2}))?/);
    if (!m) return s;
    return m[1] + '/' + String(m[2]).padStart(2, '0') + '/' + String(m[3] || '01').padStart(2, '0');
  }
  return d.getFullYear() + '/' + String(d.getMonth() + 1).padStart(2, '0') + '/' + String(d.getDate()).padStart(2, '0');
}

function salaryPeriodDateFromKey(key) {
  var s = String(key || '').trim();
  var m = s.match(/^(\d{4})-(\d{2})(?:-(H1|H2))?$/);
  if (!m) return formatSalaryDateSlash(s);
  var day = m[3] === 'H2' ? '16' : '01';
  return m[1] + '/' + m[2] + '/' + day;
}

function normalizeSalaryDateQuery(value) {
  return String(value || '').trim().replace(/-/g, '/');
}

function salaryDateMatches(displayDate, query) {
  query = normalizeSalaryDateQuery(query);
  if (!query) return true;
  return String(displayDate || '').indexOf(query) >= 0;
}

function formatEmployeeSalaryHistoryDate(rec) {
  if (!rec) return '—';
  var monthIso = rec.monthIso || rec.month_iso || '';
  if (monthIso) return salaryPeriodDateFromKey(monthIso);
  var paidAt = rec.paidAt || rec.paid_at;
  if (paidAt) return formatSalaryDateSlash(paidAt);
  var month = String(rec.month || rec.month_label || '').trim();
  if (/^\d{4}-\d{2}(?:-(?:H1|H2))?$/.test(month)) return salaryPeriodDateFromKey(month);
  if (/^\d{4}[/-]\d{1,2}[/-]\d{1,2}/.test(month)) return formatSalaryDateSlash(month);
  return month || '—';
}

function getSalaryRecordMonthIso(rec) {
  return rec && (rec.monthIso || rec.month_iso || rec.month || '');
}

function getSalaryRecordPaidAt(rec) {
  return rec && (rec.paidAt || rec.paid_at || rec.issuedAt || rec.issued_at || rec.created_at || '');
}

function normalizePaidSalaryRecord(row, empHint) {
  if (!row) return null;
  var empId = parseInt(row.empId != null ? row.empId : (row.employee_id != null ? row.employee_id : (empHint && empHint.id)), 10);
  var emp = empHint || (employees || []).find(function (e) { return e && e.id === empId; });
  if (!emp) return null;
  var status = row.status || row.salStatus || '';
  if (status !== 'مدفوع') return null;
  var monthIso = getSalaryRecordMonthIso(row);
  var paidAt = getSalaryRecordPaidAt(row);
  var base = parseExactInt(row.base != null ? row.base : row.base_salary, 0);
  var ot = parseExactInt(row.ot != null ? row.ot : (row.overtime_amount != null ? row.overtime_amount : row.overtime), 0);
  var deduct = parseExactInt(row.deduct != null ? row.deduct : (row.total_deduct != null ? row.total_deduct : row.deductions), 0);
  var bonus = parseExactInt(row.bonus, 0);
  var net = parseExactInt(row.net != null ? row.net : (row.final != null ? row.final : row.net_salary), 0);
  if (!net && net !== 0) net = base + bonus + ot - deduct;
  return {
    id: row.id || ('sal_' + monthIso + '_' + emp.id),
    employeeId: emp.id,
    empName: emp.name || '',
    dept: emp.dept || '',
    role: emp.role || '',
    month: row.month || row.month_label || monthIso || '—',
    monthIso: monthIso,
    periodDate: salaryPeriodDateFromKey(monthIso),
    paidAt: paidAt,
    paidDate: formatSalaryDateSlash(paidAt),
    base: base,
    ot: ot,
    deduct: deduct,
    bonus: bonus,
    net: net,
    status: 'مدفوع',
    source: row
  };
}

function paidSalaryRecordFromHiddenMarker(emp) {
  if (!emp || !emp.id) return null;
  var marker = appSettings.salaryDeletedMap && appSettings.salaryDeletedMap[String(emp.id)];
  if (!marker || typeof marker !== 'object' || marker.reason !== 'paid' || !marker.period) return null;
  var period = String(marker.period || '');
  var base = parseExactInt(emp.salary, 0);
  var bonus = parseExactInt(emp.salBonus, 0);
  return {
    id: 'recovered_paid_' + period + '_' + emp.id,
    employeeId: emp.id,
    empName: emp.name || '',
    dept: emp.dept || '',
    role: emp.role || '',
    month: period,
    monthIso: period,
    periodDate: salaryPeriodDateFromKey(period),
    paidAt: marker.at || '',
    paidDate: formatSalaryDateSlash(marker.at || ''),
    base: base,
    ot: 0,
    deduct: 0,
    bonus: bonus,
    net: base + bonus,
    status: 'مدفوع',
    isRecovered: true,
    source: { status: 'مدفوع', monthIso: period, paidAt: marker.at || '' }
  };
}

function collectPaidSalaryRecords() {
  var byKey = {};
  function add(rec) {
    if (!rec) return;
    var key = String(rec.employeeId) + '|' + String(rec.monthIso || rec.id || rec.paidAt || '');
    if (byKey[key] && byKey[key].isRecovered && !rec.isRecovered) {
      byKey[key] = Object.assign({}, byKey[key], rec, { isRecovered: false });
      return;
    }
    if (byKey[key] && !byKey[key].isRecovered && rec.isRecovered) return;
    byKey[key] = Object.assign({}, byKey[key] || {}, rec);
  }
  (employees || []).forEach(function (emp) {
    (emp.salaryHistoryData || []).forEach(function (row) {
      add(normalizePaidSalaryRecord(row, emp));
    });
    add(paidSalaryRecordFromHiddenMarker(emp));
  });
  (_paidSalaryRecords || []).forEach(function (row) {
    add(normalizePaidSalaryRecord(row));
  });
  return Object.keys(byKey).map(function (k) { return byKey[k]; }).sort(function (a, b) {
    return new Date(b.paidAt || 0).getTime() - new Date(a.paidAt || 0).getTime();
  });
}

async function refreshPaidSalaryRecordsFromCloud() {
  if (_paidSalaryRecordsLoading || typeof sb_getSalaryRecords !== 'function') return;
  _paidSalaryRecordsLoading = true;
  try {
    var rows = await sb_getSalaryRecords();
    if (Array.isArray(rows)) _paidSalaryRecords = rows.filter(function (r) { return r && r.status === 'مدفوع'; });
  } catch (e) {
    console.warn('refreshPaidSalaryRecordsFromCloud:', e);
  } finally {
    _paidSalaryRecordsLoading = false;
  }
}

function switchSalaryTab(tab) {
  _activeSalaryTab = tab === 'paid' ? 'paid' : 'current';
  var currentPanel = document.getElementById('salary-current-panel');
  var paidPanel = document.getElementById('salary-paid-panel');
  var currentBtn = document.getElementById('sal-tab-current');
  var paidBtn = document.getElementById('sal-tab-paid');
  if (currentPanel) currentPanel.style.display = _activeSalaryTab === 'current' ? '' : 'none';
  if (paidPanel) paidPanel.style.display = _activeSalaryTab === 'paid' ? '' : 'none';
  if (currentBtn) currentBtn.className = _activeSalaryTab === 'current' ? 'btn-sm btn-primary' : 'btn-sm';
  if (paidBtn) paidBtn.className = _activeSalaryTab === 'paid' ? 'btn-sm btn-primary' : 'btn-sm';
  if (_activeSalaryTab === 'paid') {
    if (!hasActionPermission('salaries', 'paid_view')) {
      requireActionPermission('salaries', 'paid_view');
      switchSalaryTab('current');
      return;
    }
    buildPaidSalaries();
    refreshPaidSalaryRecordsFromCloud().then(buildPaidSalaries);
  } else {
    buildSalaries();
  }
}

function buildSalaries() {
  const tbody = document.getElementById('sal-table');
  if (!tbody) return;

  // Populate dept filter
  const deptFilter = document.getElementById('sal-filter-dept');
  if (deptFilter) {
    const currentVal = deptFilter.value;
    const depts = [...new Set(employees.map(e => e.dept))];
    deptFilter.innerHTML = '<option value="">\u0643\u0644 \u0627\u0644\u0623\u0642\u0633\u0627\u0645</option>' + depts.map(d => '<option value="' + escAttr(d) + '">' + esc(d) + '</option>').join('');
    deptFilter.value = currentVal;
  }

  var fDept = document.getElementById('sal-filter-dept')?.value || '';
  var fStatus = document.getElementById('sal-filter-status')?.value || '';
  var fPeriodDate = document.getElementById('sal-filter-period-date')?.value || '';
  var fName = typeof getEmployeeNameQuery === 'function'
    ? getEmployeeNameQuery('sal-filter-name')
    : (document.getElementById('sal-filter-name')?.value || '').trim().toLowerCase();

  var filtered = employees.filter(e => {
    if (isSalaryHiddenForCurrentPeriod(e)) return false;
    if (fDept && e.dept !== fDept) return false;
    var salStatus = e.salStatus || '\u0645\u0639\u0644\u0642';
    if (fStatus && salStatus !== fStatus) return false;
    if (!salaryDateMatches(salaryPeriodDateFromKey(salaryPeriodKey(e.salaryType || 'monthly')), fPeriodDate)) return false;
    if (fName && typeof employeeMatchesNameQuery === 'function' && !employeeMatchesNameQuery(e, fName)) return false;
    if (fName && typeof employeeMatchesNameQuery !== 'function' && !String(e.name || '').toLowerCase().includes(fName)) return false;
    return true;
  });

  if (filtered.length === 0) {
    tbody.innerHTML = '<tr><td colspan="11" style="text-align:center;padding:32px;color:var(--text-muted)"><i class="fa fa-money-check-alt" style="font-size:36px;opacity:0.3;display:block;margin-bottom:8px"></i>\u0644\u0627 \u062A\u0648\u062C\u062F \u0643\u0634\u0648\u0641\u0627\u062A \u0631\u0648\u0627\u0628</td></tr>';
    return;
  }

  const statusMap = { '\u0645\u0639\u0644\u0642':'badge-warning', '\u0645\u064F\u0635\u062F\u0631':'badge-info', '\u0645\u062F\u0641\u0648\u0639':'badge-success' };
  const statusIcon = { '\u0645\u0639\u0644\u0642':'\u23F3', '\u0645\u064F\u0635\u062F\u0631':'\uD83D\uDCC4', '\u0645\u062F\u0641\u0648\u0639':'\u2705' };

  tbody.innerHTML = filtered.map((e, i) => {
    const eType = e.salaryType || 'monthly';
    const isComm = eType === 'commission';
    const isBiw = eType === 'biweekly';
    const typeLabel = isComm ? '<span style="font-size:10px;padding:2px 6px;border-radius:4px;background:rgba(246,224,94,0.15);color:#f6e05e;margin-right:4px">\u0639\u0645\u0648\u0644\u0629</span>' : (isBiw ? '<span style="font-size:10px;padding:2px 6px;border-radius:4px;background:rgba(99,179,237,0.15);color:#63b3ed;margin-right:4px">15 \u064A\u0648\u0645</span>' : '');
    const sal = calcEmpSalary(e);
    const deduct = sal.totalDeduct;
    const ot = sal.overtimeInNet ? (sal.ot || 0) : 0;
    const bonus = sal.bonus;
    const baseSalary = sal.baseSalary;
    const final = sal.final;
    const finalCell = salaryNetTableCellHtml(final, isComm);
    const deductBreakdown = formatSalaryDeductionBreakdown(sal);
    const deductTitle = 'إجمالي الخصومات = ' + (deduct || 0).toLocaleString() + ' IQD' + (deductBreakdown ? '\n' + deductBreakdown : '');
    const salStatus = e.salStatus || '\u0645\u0639\u0644\u0642';
    return '<tr>' +
      '<td>' + (i + 1) + '</td>' +
      '<td><strong>' + typeLabel + esc(e.name) + '</strong></td>' +
      '<td>' + esc(e.dept) + '</td>' +
      '<td>' + salaryPeriodDateFromKey(salaryPeriodKey(e.salaryType || 'monthly')) + '</td>' +
      '<td>' + (isComm ? '\u0639\u0645\u0648\u0644\u0629' : baseSalary.toLocaleString()) + '</td>' +
      '<td title="' + escAttr(deductTitle) + '" style="color:' + (isComm ? 'var(--text-muted)' : (deduct>0?'#fc8181':'var(--text-muted)')) + '">' + (isComm ? '\u2014' : (deduct > 0 ? deduct.toLocaleString() : '\u2014')) + '</td>' +
      '<td style="color:' + (isComm ? 'var(--text-muted)' : (ot>0?'#63b3ed':'var(--text-muted)')) + '">' + (isComm ? '\u2014' : (ot > 0 ? ot.toLocaleString() : '\u2014')) + '</td>' +
      '<td style="color:' + (bonus>0?'#f6e05e':'var(--text-muted)') + '">' + (bonus > 0 ? bonus.toLocaleString() : '\u2014') + '</td>' +
      '<td class="' + escAttr(finalCell.tdClass) + '" style="' + escAttr(finalCell.tdStyle) + '" title="' + escAttr(finalCell.title) + '">' + finalCell.html + '</td>' +
      '<td><span class="badge ' + escClass(salStatus, statusMap, 'badge-warning') + '">' + esc(statusIcon[salStatus] || '') + ' ' + esc(salStatus) + '</span></td>' +
      '<td>' +
        (hasActionPermission('salaries', 'edit') ? '<button class="btn-sm btn-primary" style="padding:5px 10px;margin:2px" onclick="editSalary(' + e.id + ')" title="\u062A\u0639\u062F\u064A\u0644"><i class="fa fa-edit"></i></button>' : '') +
        '<button class="btn-sm btn-primary" style="padding:5px 10px;margin:2px" onclick="viewSalary(' + e.id + ')" title="\u0639\u0631\u0636"><i class="fa fa-eye"></i></button>' +
        (hasActionPermission('salaries', 'delete') ? '<button class="btn-sm btn-danger" style="padding:5px 10px;margin:2px" onclick="deleteSalary(' + e.id + ')" title="\u062D\u0630\u0641"><i class="fa fa-trash"></i></button>' : '') +
      '</td>' +
    '</tr>';
  }).join('');
}

function buildPaidSalaries() {
  var tbody = document.getElementById('paid-sal-table');
  if (!tbody) return;
  var deptFilter = document.getElementById('paid-sal-filter-dept');
  var roleFilter = document.getElementById('paid-sal-filter-role');
  if (deptFilter) {
    var keepDept = deptFilter.value;
    var depts = [...new Set((employees || []).map(function (e) { return e && e.dept; }).filter(Boolean))];
    deptFilter.innerHTML = '<option value="">كل الأقسام</option>' + depts.map(function (d) { return '<option value="' + escAttr(d) + '">' + esc(d) + '</option>'; }).join('');
    deptFilter.value = keepDept;
  }
  if (roleFilter) {
    var keepRole = roleFilter.value;
    var roles = [...new Set((employees || []).map(function (e) { return e && e.role; }).filter(Boolean))];
    roleFilter.innerHTML = '<option value="">كل الوظائف</option>' + roles.map(function (r) { return '<option value="' + escAttr(r) + '">' + esc(r) + '</option>'; }).join('');
    roleFilter.value = keepRole;
  }
  var fName = String(document.getElementById('paid-sal-filter-name')?.value || '').trim().toLowerCase();
  var fDept = deptFilter ? deptFilter.value : '';
  var fRole = roleFilter ? roleFilter.value : '';
  var fPeriod = document.getElementById('paid-sal-filter-period-date')?.value || '';
  var fPaid = document.getElementById('paid-sal-filter-paid-date')?.value || '';
  var rows = collectPaidSalaryRecords().filter(function (rec) {
    if (fName && String(rec.empName || '').toLowerCase().indexOf(fName) < 0) return false;
    if (fDept && rec.dept !== fDept) return false;
    if (fRole && rec.role !== fRole) return false;
    if (!salaryDateMatches(rec.periodDate, fPeriod)) return false;
    if (!salaryDateMatches(rec.paidDate, fPaid)) return false;
    return true;
  });
  if (!rows.length) {
    tbody.innerHTML = '<tr><td colspan="12" style="text-align:center;padding:32px;color:var(--text-muted)"><i class="fa fa-archive" style="font-size:36px;opacity:0.3;display:block;margin-bottom:8px"></i>لا توجد رواتب مدفوعة</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map(function (rec, i) {
    var netCell = salaryNetTableCellHtml(rec.net, false);
    return '<tr>' +
      '<td>' + (i + 1) + '</td>' +
      '<td><strong>' + esc(rec.empName) + '</strong></td>' +
      '<td>' + esc(rec.dept || '—') + '</td>' +
      '<td>' + esc(rec.role || '—') + '</td>' +
      '<td>' + esc(rec.periodDate || '—') + '</td>' +
      '<td>' + esc(rec.paidDate || '—') + '</td>' +
      '<td>' + rec.base.toLocaleString() + '</td>' +
      '<td style="color:' + (rec.deduct > 0 ? '#fc8181' : 'var(--text-muted)') + '">' + (rec.deduct > 0 ? rec.deduct.toLocaleString() : '—') + '</td>' +
      '<td style="color:' + (rec.ot > 0 ? '#63b3ed' : 'var(--text-muted)') + '">' + (rec.ot > 0 ? rec.ot.toLocaleString() : '—') + '</td>' +
      '<td style="color:' + (rec.bonus > 0 ? '#f6e05e' : 'var(--text-muted)') + '">' + (rec.bonus > 0 ? rec.bonus.toLocaleString() : '—') + '</td>' +
      '<td class="' + escAttr(netCell.tdClass) + '" style="' + escAttr(netCell.tdStyle) + '" title="' + escAttr(netCell.title) + '">' + netCell.html + '</td>' +
      '<td>' +
        (hasActionPermission('salaries', 'paid_view') ? '<button class="btn-sm btn-primary" style="padding:5px 10px;margin:2px" onclick="viewPaidSalaryRecord(' + escAttr(JSON.stringify(rec.employeeId)) + ',' + escAttr(JSON.stringify(rec.monthIso)) + ')" title="معاينة"><i class="fa fa-eye"></i></button>' : '') +
        (hasActionPermission('salaries', 'paid_edit') ? '<button class="btn-sm btn-primary" style="padding:5px 10px;margin:2px" onclick="editPaidSalaryRecord(' + escAttr(JSON.stringify(rec.employeeId)) + ',' + escAttr(JSON.stringify(rec.monthIso)) + ')" title="تعديل"><i class="fa fa-edit"></i></button>' : '') +
        (hasActionPermission('salaries', 'paid_delete') ? '<button class="btn-sm btn-danger" style="padding:5px 10px;margin:2px" onclick="deletePaidSalaryRecord(' + escAttr(JSON.stringify(rec.employeeId)) + ',' + escAttr(JSON.stringify(rec.monthIso)) + ')" title="حذف"><i class="fa fa-trash"></i></button>' : '') +
      '</td>' +
    '</tr>';
  }).join('');
}

function editSalary(empId) {
  if (!requireActionPermission('salaries', 'edit')) return;
  const e = employees.find(x => x.id === empId);
  if (!e) return;
  const sal = calcEmpSalary(e);
  const deduct = sal.totalDeduct;
  const ot = sal.overtimeInNet ? (sal.ot || 0) : 0;
  const bonus = sal.bonus;
  const final = sal.final;
  const salStatus = e.salStatus || '\u0645\u0639\u0644\u0642';
  const statusOpts = ['\u0645\u0639\u0644\u0642','\u0645\u064F\u0635\u062F\u0631','\u0645\u062F\u0641\u0648\u0639'].map(s =>
    '<option value="' + s + '"' + (s === salStatus ? ' selected' : '') + '>' + s + '</option>'
  ).join('');

  Swal.fire({
    title: '\u270F\uFE0F \u062A\u0639\u062F\u064A\u0644 \u0643\u0634\u0641 \u0631\u0627\u062A\u0628: ' + esc(e.name),
    html: '<div class="emp-form-wrap">' +
      '<div class="emp-form-section"><div class="emp-form-section-title"><i class="fa fa-user"></i> \u0628\u064A\u0627\u0646\u0627\u062A \u0627\u0644\u0645\u0648\u0638\u0641</div>' +
      '<div class="emp-field"><label>\u0627\u0644\u0627\u0633\u0645</label><input value="' + esc(e.name) + '" readonly style="opacity:0.6"></div>' +
      '<div class="emp-field"><label>\u0627\u0644\u0642\u0633\u0645</label><input value="' + esc(e.dept) + '" readonly style="opacity:0.6"></div>' +
      '</div>' +
      '<div class="emp-form-section"><div class="emp-form-section-title"><i class="fa fa-money-bill"></i> \u062A\u0641\u0627\u0635\u064A\u0644 \u0627\u0644\u0631\u0627\u062A\u0628</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>\u0627\u0644\u0631\u0627\u062A\u0628 \u0627\u0644\u0623\u0633\u0627\u0633\u064A (IQD)</label><input type="number" id="sal-base" value="' + sal.baseSalary + '" min="0"></div>' +
      '<div class="emp-field"><label>\u0627\u0644\u0645\u0643\u0627\u0641\u0622\u062A (IQD)</label><input type="number" id="sal-bonus" value="' + bonus + '" min="0"></div>' +
      '</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>خصم نقص دوام (IQD)</label><input type="number" id="sal-deduct" value="' + sal.lateDeduct + '" min="0" readonly style="opacity:0.6"></div>' +
      '<div class="emp-field"><label>\u0625\u0636\u0627\u0641\u064A (IQD)</label><input type="number" id="sal-ot" value="' + ot + '" min="0" readonly style="opacity:0.6"></div>' +
      '<div class="emp-field"><label>خصم غياب (' + sal.absentDays + ' يوم) (IQD)</label><input type="number" id="sal-absent-deduct" value="' + sal.absentDeduct + '" min="0" readonly style="opacity:0.6"></div>' +
      '<div class="emp-field"><label>خصم إجازات غير مدفوعة (IQD)</label><input type="number" id="sal-leave-deduct" value="' + (sal.leaveDeduct || 0) + '" min="0" readonly style="opacity:0.6;color:' + ((sal.leaveDeduct || 0) > 0 ? '#f6ad55' : '') + '"></div>' +
      '</div>' +
      '<div class="emp-field-row">' +
      '<div class="emp-field"><label>إجمالي الخصومات (IQD)</label><input type="number" id="sal-total-deduct" value="' + deduct + '" min="0" readonly style="opacity:0.6;color:#fc8181;font-weight:700"></div>' +
      '<div class="emp-field"><label>\u0627\u0644\u0635\u0627\u0641\u064A (IQD)</label><input id="sal-final" value="' + formatSalaryNetAmount(final, false) + '" readonly style="opacity:0.6;' + (isSalaryNetNegative(final) ? 'color:#fff;background:rgba(197,48,48,0.92);font-weight:700' : 'color:var(--accent);font-weight:700') + '" title="' + escAttr(salaryNetNegativeTitle(final)) + '"></div>' +
      '<div class="emp-field"><label>\u0627\u0644\u062D\u0627\u0644\u0629</label><select id="sal-status">' + statusOpts + '</select></div>' +
      '</div></div></div>',
    ...swalTheme(), showCancelButton: true,
    confirmButtonText: '\u062D\u0641\u0638 \u0627\u0644\u062A\u0639\u062F\u064A\u0644\u0627\u062A',
    cancelButtonText: '\u0625\u0644\u063A\u0627\u0621',
    preConfirm: () => {
      const newSalary = parseExactInt(document.getElementById('sal-base').value, 0);
      const newBonus = parseExactInt(document.getElementById('sal-bonus').value, 0);
      const newStatus = document.getElementById('sal-status').value;
      if (!newSalary || newSalary < 0) { Swal.showValidationMessage('\u0623\u062F\u062E\u0644 \u0631\u0627\u062A\u0628\u0627\u064B \u0635\u062D\u064A\u062D\u0627\u064B'); return false; }
      return { newSalary, newBonus, newStatus };
    }
  }).then(async r => {
    if (!r.isConfirmed || !r.value) return;
    pauseRemoteSync(8000);
    var periodKey = salaryPeriodKey(e.salaryType || 'monthly');
    if (!appSettings.salaryDeletedMap || typeof appSettings.salaryDeletedMap !== 'object') appSettings.salaryDeletedMap = {};
    e.salDeletedPeriod = '';
    delete appSettings.salaryDeletedMap[String(e.id)];
    e.salary = r.value.newSalary;
    e.salBonus = r.value.newBonus;
    e.salStatus = r.value.newStatus;
    await persistEmployeeNow(e);
    logActivity('edit', 'salaries', 'تعديل كشف راتب: ' + e.name + ' — الحالة: ' + r.value.newStatus, { targetName: e.name });
    if (r.value.newStatus === '\u0645\u062F\u0641\u0648\u0639') {
      await upsertCurrentSalaryHistoryForEmployee(e, r.value.newStatus);
      var paidFinal = calcEmpSalary(e).final || 0;
      appSettings.salaryDeletedMap[String(e.id)] = { period: periodKey, at: new Date().toISOString(), reason: 'paid' };
      e.salDeletedPeriod = periodKey;
      await persistEmployeeNow(e);
      notifyEmployeeFinance(e.id, 'salary', 'pay', paidFinal, 'تم تغيير حالة الراتب إلى مدفوع', 'salary_' + salaryPeriodKey(e.salaryType || 'monthly'));
      logActivity('pay', 'salaries', 'تسجيل دفع راتب: ' + e.name, { targetName: e.name });
    } else if (typeof sb_updateSalaryRecordStatus === 'function') {
      await sb_updateSalaryRecordStatus(e.id, periodKey, r.value.newStatus).catch(function (err) {
        console.warn('sb_updateSalaryRecordStatus:', err);
      });
    }
    await persistSalaryDeletedMapNow();
    saveData();
    refreshAll();
    if (typeof buildPaidSalaries === 'function') buildPaidSalaries();
    Swal.fire({ icon: 'success', title: '\u062A\u0645 \u0627\u0644\u062D\u0641\u0638', ...swalTheme(), timer: 1500, showConfirmButton: false });
    resumeRemoteSync(7000);
  });
}

function deleteSalary(empId) {
  if (!requireActionPermission('salaries', 'delete')) return;
  const e = employees.find(x => x.id === empId);
  if (!e) return;
  Swal.fire({
    title: '\u062D\u0630\u0641 \u0643\u0634\u0641 \u0627\u0644\u0631\u0627\u062A\u0628',
    html: 'هل تريد حذف كشف راتب <b>' + esc(e.name) + '</b> لهذه الفترة؟<br>سيختفي من جدول إصدار الرواتب حتى يتم إصدار الرواتب من جديد.',
    icon: 'warning', showCancelButton: true,
    confirmButtonText: '\u0646\u0639\u0645', cancelButtonText: '\u0625\u0644\u063A\u0627\u0621',
    ...swalTheme(), confirmButtonColor: '#e53e3e'
  }).then(async r => {
    if (!r.isConfirmed) return;
    pauseRemoteSync(10000);
    e.salDeletedPeriod = salaryPeriodKey(e.salaryType || 'monthly');
    if (!appSettings.salaryDeletedMap) appSettings.salaryDeletedMap = {};
    appSettings.salaryDeletedMap[String(e.id)] = { period: e.salDeletedPeriod, at: new Date().toISOString() };
    e.salStatus = '\u0645\u0639\u0644\u0642';
    e.salBonus = 0;
    if (typeof sb_deleteSalaryRecord === 'function') {
      const deleted = await sb_deleteSalaryRecord(e.id, { monthIso: e.salDeletedPeriod, periodPrefix: e.salDeletedPeriod.slice(0, 7) });
      if (!deleted) {
        resumeRemoteSync(0);
        Swal.fire({ icon:'error', title:'تعذر حذف كشف الراتب من السحابة', text:'لم يتم حذف الكشف حتى لا يرجع مرة أخرى.', ...swalTheme() });
        return;
      }
    }
    await persistEmployeeNow(e);
    await persistSalaryDeletedMapNow();
    saveData();
    refreshAll();
    logActivity('delete', 'salaries', 'حذف كشف راتب: ' + e.name, { targetName: e.name });
    Swal.fire({ icon: 'success', title: 'تم حذف كشف الراتب', ...swalTheme(), timer: 1500, showConfirmButton: false });
    resumeRemoteSync(9000);
  });
}

function viewSalary(empIdOrName) {
  const e = typeof empIdOrName === 'number'
    ? employees.find(x => x.id === empIdOrName)
    : employees.find(x => x.id === empIdOrName || x.name === empIdOrName || (typeof shortEmpName === 'function' && shortEmpName(x.name) === empIdOrName));
  if (!e) return;
  const sal = calcEmpSalary(e);
  const deduct = sal.totalDeduct;
  const ot = sal.overtimeInNet ? (sal.ot || 0) : 0;
  const bonus = sal.bonus;
  const final = sal.final;
  const lateDeduct = sal.lateDeduct || 0;
  const absentDeduct = sal.absentDeduct || 0;
  const leaveDeduct = sal.leaveDeduct || 0;
  const manualDeduct = sal.manualDeduct || 0;
  const loanDeduct = sal.loanDeduct || 0;
  const salStatus = e.salStatus || '\u0645\u0639\u0644\u0642';
  Swal.fire({ icon: 'info', title: '\u0643\u0634\u0641 \u0631\u0627\u062A\u0628: ' + esc(e.name),
    html: '<div style="text-align:right;font-family:Cairo,sans-serif;line-height:2.2;font-size:14px">' +
      '<div>\uD83D\uDCCB <strong>\u0627\u0644\u0642\u0633\u0645:</strong> ' + esc(e.dept) + '</div>' +
      '<div>\uD83D\uDCB0 <strong>\u0627\u0644\u0631\u0627\u062A\u0628 \u0627\u0644\u0623\u0633\u0627\u0633\u064A:</strong> <b>' + e.salary.toLocaleString() + '</b> IQD</div>' +
      '<div>\u2795 <strong>\u0627\u0644\u0625\u0636\u0627\u0641\u064A:</strong> <b style="color:#63b3ed">' + (ot > 0 ? ot.toLocaleString() : '—') + '</b> IQD' + (sal.overtimeInNet ? '' : ' <span style="font-size:12px;color:var(--text-muted)">(غير مُفعل من بطاقة الموظف)</span>') + '</div>' +
      '<div>\uD83C\uDFC6 <strong>\u0627\u0644\u0645\u0643\u0627\u0641\u0622\u062A:</strong> <b style="color:#f6e05e">' + (bonus > 0 ? bonus.toLocaleString() : '0') + '</b> IQD</div>' +
      '<hr style="border-color:rgba(255,255,255,0.12);margin:8px 0">' +
      '<div style="font-weight:700;color:#fc8181">تفصيل الخصومات</div>' +
      '<div><strong>خصم نقص دوام:</strong> ' + (lateDeduct > 0 ? lateDeduct.toLocaleString() : '0') + ' IQD</div>' +
      '<div><strong>خصم غياب:</strong> ' + (absentDeduct > 0 ? absentDeduct.toLocaleString() : '0') + ' IQD</div>' +
      '<div><strong>خصم إجازات:</strong> ' + (leaveDeduct > 0 ? leaveDeduct.toLocaleString() : '0') + ' IQD</div>' +
      '<div><strong>إجازات مدفوعة (بدون خصم):</strong> ' + ((sal.paidLeaveDays || 0) > 0 ? sal.paidLeaveDays + ' يوم' : '0') + '</div>' +
      '<div><strong>أيام مغطاة بإجازة:</strong> ' + ((sal.leaveCoveredDays || 0) > 0 ? sal.leaveCoveredDays + ' يوم' : '0') + '</div>' +
      '<div><strong>خصومات مالية:</strong> ' + (manualDeduct > 0 ? manualDeduct.toLocaleString() : '0') + ' IQD</div>' +
      '<div><strong>استقطاع سلف:</strong> ' + (loanDeduct > 0 ? loanDeduct.toLocaleString() : '0') + ' IQD</div>' +
      '<div>\u2796 <strong>\u062E\u0635\u0648\u0645\u0627\u062A:</strong> <b style="color:#fc8181">' + (deduct > 0 ? deduct.toLocaleString() : '0') + '</b> IQD</div>' +
      '<div>\uD83D\uDCB5 <strong>\u0627\u0644\u0635\u0627\u0641\u064A:</strong> ' + salaryNetInlineHtml(final, false) + '</div>' +
      '<div>\uD83D\uDCCC <strong>\u0627\u0644\u062D\u0627\u0644\u0629:</strong> ' + esc(salStatus) + '</div>' +
      '</div>',
    ...swalTheme() });
}

function findPaidSalaryRecord(employeeId, monthIso) {
  employeeId = parseInt(employeeId, 10);
  var key = String(monthIso || '');
  return collectPaidSalaryRecords().find(function (rec) {
    return rec && rec.employeeId === employeeId && String(rec.monthIso || '') === key;
  }) || null;
}

function viewPaidSalaryRecord(employeeId, monthIso) {
  if (!requireActionPermission('salaries', 'paid_view')) return;
  var rec = findPaidSalaryRecord(employeeId, monthIso);
  if (!rec) return;
  Swal.fire({
    icon: 'info',
    title: 'راتب مدفوع: ' + esc(rec.empName),
    html: '<div style="text-align:right;font-family:Cairo,sans-serif;line-height:2.2;font-size:14px">' +
      '<div><strong>الموظف:</strong> ' + esc(rec.empName) + '</div>' +
      '<div><strong>القسم:</strong> ' + esc(rec.dept || '—') + '</div>' +
      '<div><strong>الوظيفة:</strong> ' + esc(rec.role || '—') + '</div>' +
      '<div><strong>فترة الراتب:</strong> ' + esc(rec.periodDate || '—') + '</div>' +
      '<div><strong>تاريخ الدفع:</strong> ' + esc(rec.paidDate || '—') + '</div>' +
      '<hr style="border-color:rgba(255,255,255,0.12)">' +
      '<div><strong>الراتب الأساسي:</strong> ' + rec.base.toLocaleString() + ' IQD</div>' +
      '<div><strong>الإضافي:</strong> ' + rec.ot.toLocaleString() + ' IQD</div>' +
      '<div><strong>المكافآت:</strong> ' + rec.bonus.toLocaleString() + ' IQD</div>' +
      '<div><strong>الخصومات:</strong> ' + rec.deduct.toLocaleString() + ' IQD</div>' +
      '<div><strong>الصافي:</strong> ' + salaryNetInlineHtml(rec.net, false) + '</div>' +
      '</div>',
    ...swalTheme()
  });
}

function updateLocalPaidSalaryRecord(employeeId, monthIso, patch) {
  var emp = (employees || []).find(function (e) { return e && e.id === parseInt(employeeId, 10); });
  if (emp && Array.isArray(emp.salaryHistoryData)) {
    emp.salaryHistoryData = emp.salaryHistoryData.map(function (row) {
      if (row && String(row.monthIso || row.month_iso || '') === String(monthIso)) return Object.assign({}, row, patch);
      return row;
    });
  }
  _paidSalaryRecords = (_paidSalaryRecords || []).map(function (row) {
    if (row && parseInt(row.employee_id || row.empId || row.employeeId, 10) === parseInt(employeeId, 10) && String(row.month_iso || row.monthIso || '') === String(monthIso)) {
      return Object.assign({}, row, patch);
    }
    return row;
  });
}

function removeLocalPaidSalaryRecord(employeeId, monthIso) {
  employeeId = parseInt(employeeId, 10);
  var key = String(monthIso || '');
  var emp = (employees || []).find(function (e) { return e && e.id === employeeId; });
  if (emp && Array.isArray(emp.salaryHistoryData)) {
    emp.salaryHistoryData = emp.salaryHistoryData.map(function (row) {
      if (row && String(row.monthIso || row.month_iso || '') === key) {
        return Object.assign({}, row, { status: 'معلق', paidAt: null, paid_at: null });
      }
      return row;
    });
  }
  _paidSalaryRecords = (_paidSalaryRecords || []).filter(function (row) {
    return !(parseInt(row.employee_id || row.empId || row.employeeId, 10) === employeeId && String(row.month_iso || row.monthIso || '') === key);
  });
}

async function restorePaidSalaryToCurrentPayroll(employeeId, monthIso, newStatus, patch) {
  employeeId = parseInt(employeeId, 10);
  var emp = (employees || []).find(function (e) { return e && e.id === employeeId; });
  if (!emp) return false;
  var periodKey = salaryPeriodKey(emp.salaryType || 'monthly');
  var isCurrentPeriod = String(monthIso || '') === periodKey;
  if (!appSettings.salaryDeletedMap || typeof appSettings.salaryDeletedMap !== 'object') appSettings.salaryDeletedMap = {};
  if (appSettings.salaryDeletedMap[String(employeeId)]) delete appSettings.salaryDeletedMap[String(employeeId)];
  if (isCurrentPeriod) {
    emp.salDeletedPeriod = '';
    emp.salStatus = newStatus || 'معلق';
    if (patch && patch.base != null) emp.salary = patch.base;
    if (patch && patch.bonus != null) emp.salBonus = patch.bonus;
  }
  var recordPatch = Object.assign({}, patch || {}, {
    monthIso: monthIso,
    month: monthIso,
    status: newStatus || 'معلق',
    paidAt: null,
    paid_at: null
  });
  var saved = null;
  if (typeof sb_upsertSalaryRecord === 'function') {
    saved = await sb_upsertSalaryRecord(employeeId, recordPatch);
  }
  if (!saved && typeof sb_updateSalaryRecordStatus === 'function') {
    saved = await sb_updateSalaryRecordStatus(employeeId, monthIso, newStatus || 'معلق', null).catch(function (err) {
      console.warn('restorePaidSalary sb_updateSalaryRecordStatus:', err);
      return null;
    });
  }
  if ((typeof sb_upsertSalaryRecord === 'function' || typeof sb_updateSalaryRecordStatus === 'function') && !saved) return false;
  removeLocalPaidSalaryRecord(employeeId, monthIso);
  if (emp && Array.isArray(emp.salaryHistoryData)) {
    var idx = emp.salaryHistoryData.findIndex(function (row) {
      return row && String(row.monthIso || row.month_iso || '') === String(monthIso);
    });
    var merged = Object.assign({}, saved || recordPatch, { status: newStatus || 'معلق', paidAt: null, paid_at: null });
    if (idx >= 0) emp.salaryHistoryData[idx] = Object.assign({}, emp.salaryHistoryData[idx], merged);
    else emp.salaryHistoryData.unshift(merged);
  }
  clearSalaryCacheForEmployee(employeeId);
  await persistEmployeeNow(emp);
  await persistSalaryDeletedMapNow();
  return true;
}

function editPaidSalaryRecord(employeeId, monthIso) {
  if (!requireActionPermission('salaries', 'paid_edit')) return;
  var rec = findPaidSalaryRecord(employeeId, monthIso);
  if (!rec) return;
  var statusOpts = ['معلق', 'مُصدر', 'مدفوع'].map(function (s) {
    return '<option value="' + s + '"' + (s === 'مدفوع' ? ' selected' : '') + '>' + s + '</option>';
  }).join('');
  Swal.fire({
    title: 'تعديل راتب مدفوع',
    html: '<div style="text-align:right">' +
      '<div class="emp-field"><label>فترة الراتب</label><input id="paid-edit-period" class="setting-input" value="' + escAttr(rec.periodDate || '') + '" readonly style="opacity:0.6"></div>' +
      '<div class="emp-field"><label>الحالة</label><select id="paid-edit-status" class="setting-input">' + statusOpts + '</select></div>' +
      '<div class="emp-field"><label>تاريخ الدفع</label><input id="paid-edit-date" class="setting-input" placeholder="2026/05/06" value="' + escAttr(rec.paidDate || '') + '"></div>' +
      '<div class="emp-field-row"><div class="emp-field"><label>الراتب الأساسي</label><input type="number" id="paid-edit-base" class="setting-input" min="0" value="' + rec.base + '"></div><div class="emp-field"><label>الإضافي</label><input type="number" id="paid-edit-ot" class="setting-input" min="0" value="' + rec.ot + '"></div></div>' +
      '<div class="emp-field-row"><div class="emp-field"><label>المكافآت</label><input type="number" id="paid-edit-bonus" class="setting-input" min="0" value="' + rec.bonus + '"></div><div class="emp-field"><label>الخصومات</label><input type="number" id="paid-edit-deduct" class="setting-input" min="0" value="' + rec.deduct + '"></div></div>' +
      '</div>',
    ...swalTheme(),
    showCancelButton: true,
    confirmButtonText: 'حفظ',
    cancelButtonText: 'إلغاء',
    didOpen: function () {
      var statusEl = document.getElementById('paid-edit-status');
      var dateEl = document.getElementById('paid-edit-date');
      function syncPaidDateField() {
        if (!statusEl || !dateEl) return;
        var isPaid = statusEl.value === 'مدفوع';
        dateEl.disabled = !isPaid;
        dateEl.style.opacity = isPaid ? '1' : '0.6';
      }
      if (statusEl) safeAddEvent(statusEl, 'change', syncPaidDateField);
      syncPaidDateField();
    },
    preConfirm: function () {
      var newStatus = document.getElementById('paid-edit-status')?.value || 'مدفوع';
      var paidDate = normalizeSalaryDateQuery(document.getElementById('paid-edit-date')?.value || '');
      if (newStatus === 'مدفوع' && paidDate && !/^\d{4}\/\d{2}\/\d{2}$/.test(paidDate)) {
        Swal.showValidationMessage('صيغة تاريخ الدفع يجب أن تكون 2026/05/06');
        return false;
      }
      var base = readMoneyValue('paid-edit-base', 0);
      var ot = readMoneyValue('paid-edit-ot', 0);
      var bonus = readMoneyValue('paid-edit-bonus', 0);
      var deduct = readMoneyValue('paid-edit-deduct', 0);
      return { newStatus: newStatus, paidDate: paidDate, base: base, ot: ot, bonus: bonus, deduct: deduct, net: base + ot + bonus - deduct };
    }
  }).then(async function (r) {
    if (!r.isConfirmed || !r.value) return;
    pauseRemoteSync(12000);
    var newStatus = r.value.newStatus || 'مدفوع';
    var patch = {
      base: r.value.base,
      base_salary: r.value.base,
      ot: r.value.ot,
      overtime_amount: r.value.ot,
      bonus: r.value.bonus,
      deduct: r.value.deduct,
      total_deduct: r.value.deduct,
      net: r.value.net,
      final: r.value.net,
      net_salary: r.value.net
    };
    if (newStatus !== 'مدفوع') {
      var restored = await restorePaidSalaryToCurrentPayroll(employeeId, monthIso, newStatus, patch);
      if (!restored) {
        resumeRemoteSync(0);
        Swal.fire({ icon: 'error', title: 'تعذر إرجاع الراتب', text: 'لم يتم تحديث السجل في السحابة.', ...swalTheme() });
        return;
      }
      logActivity('edit', 'salaries', 'إرجاع راتب مدفوع إلى ' + newStatus + ': ' + rec.empName + ' — ' + (rec.periodDate || monthIso), { targetName: rec.empName, empId: employeeId, targetEmpId: employeeId });
      notifyEmployeeFinance(employeeId, 'salary', 'edit', r.value.net, 'تم إرجاع الراتب إلى حالة ' + newStatus, 'salary_' + monthIso);
      saveData();
      refreshAll();
      buildSalaries();
      buildPaidSalaries();
      var empAfter = (employees || []).find(function (e) { return e && e.id === parseInt(employeeId, 10); });
      if (newStatus === 'معلق' && empAfter && String(monthIso || '') === salaryPeriodKey(empAfter.salaryType || 'monthly') && typeof switchSalaryTab === 'function') {
        switchSalaryTab('current');
      }
      Swal.fire({
        icon: 'success',
        title: 'تم إرجاع الراتب إلى كشوفات الرواتب',
        text: newStatus === 'معلق' ? 'اختفى من الرواتب المدفوعة وظهر في كشوفات الرواتب الحالية.' : 'تم تحديث الحالة.',
        ...swalTheme(),
        timer: 2200,
        showConfirmButton: false
      });
      resumeRemoteSync(7000);
      return;
    }
    var paidIso = r.value.paidDate ? r.value.paidDate.replace(/\//g, '-') + 'T12:00:00.000Z' : rec.paidAt;
    patch = Object.assign(patch, {
      paidAt: paidIso,
      paid_at: paidIso,
      status: 'مدفوع'
    });
    var saved = null;
    if (typeof sb_upsertSalaryRecord === 'function') {
      saved = await sb_upsertSalaryRecord(employeeId, Object.assign({}, rec.source || {}, patch, { monthIso: monthIso, month: rec.month, status: 'مدفوع' }));
    }
    if (saved) patch = Object.assign({}, patch, saved);
    updateLocalPaidSalaryRecord(employeeId, monthIso, patch);
    logActivity('edit', 'salaries', 'تعديل راتب مدفوع: ' + rec.empName + ' — ' + (rec.periodDate || monthIso), { targetName: rec.empName, empId: employeeId, targetEmpId: employeeId });
    notifyEmployeeFinance(employeeId, 'salary', 'edit', r.value.net, 'تم تعديل سجل راتب مدفوع', 'salary_' + monthIso);
    await persistSalaryDeletedMapNow();
    saveData();
    refreshAll();
    buildPaidSalaries();
    Swal.fire({ icon:'success', title:'تم تعديل الراتب المدفوع', ...swalTheme(), timer:1500, showConfirmButton:false });
    resumeRemoteSync(7000);
  });
}

function deletePaidSalaryRecord(employeeId, monthIso) {
  if (!requireActionPermission('salaries', 'paid_delete')) return;
  var rec = findPaidSalaryRecord(employeeId, monthIso);
  if (!rec) return;
  Swal.fire({
    icon: 'warning',
    title: 'حذف راتب مدفوع',
    html: 'هل تريد حذف راتب <b>' + esc(rec.empName) + '</b> من الأرشيف؟',
    showCancelButton: true,
    confirmButtonText: 'حذف',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#e53e3e'
  }).then(async function (r) {
    if (!r.isConfirmed) return;
    pauseRemoteSync(12000);
    var deleted = true;
    if (typeof sb_deleteSalaryRecord === 'function') {
      deleted = await sb_deleteSalaryRecord(employeeId, { monthIso: monthIso });
    }
    if (!deleted) {
      resumeRemoteSync(0);
      Swal.fire({ icon:'error', title:'تعذر حذف الراتب من السحابة', text:'لم يتم الحذف حتى لا يعود السجل بعد المزامنة.', ...swalTheme() });
      return;
    }
    var emp = (employees || []).find(function (e) { return e && e.id === parseInt(employeeId, 10); });
    if (emp && Array.isArray(emp.salaryHistoryData)) {
      emp.salaryHistoryData = emp.salaryHistoryData.filter(function (row) { return String(row.monthIso || row.month_iso || '') !== String(monthIso); });
    }
    _paidSalaryRecords = (_paidSalaryRecords || []).filter(function (row) {
      return !(parseInt(row.employee_id || row.empId || row.employeeId, 10) === parseInt(employeeId, 10) && String(row.month_iso || row.monthIso || '') === String(monthIso));
    });
    if (appSettings.salaryDeletedMap && appSettings.salaryDeletedMap[String(employeeId)]) delete appSettings.salaryDeletedMap[String(employeeId)];
    if (emp) {
      emp.salDeletedPeriod = '';
      emp.salStatus = 'معلق';
      await persistEmployeeNow(emp);
    }
    logActivity('delete', 'salaries', 'حذف راتب مدفوع: ' + rec.empName + ' — ' + (rec.periodDate || monthIso), { targetName: rec.empName, empId: employeeId, targetEmpId: employeeId });
    notifyEmployeeFinance(employeeId, 'salary', 'delete', rec.net, 'تم حذف سجل راتب مدفوع', 'salary_' + monthIso);
    await persistSalaryDeletedMapNow();
    saveData();
    refreshAll();
    buildPaidSalaries();
    Swal.fire({ icon:'success', title:'تم حذف الراتب المدفوع', ...swalTheme(), timer:1500, showConfirmButton:false });
    resumeRemoteSync(7000);
  });
}

function issueAllSalaries() {
  if (!requireActionPermission('salaries', 'add')) return;
  if (employees.length === 0) {
    Swal.fire({ icon: 'warning', title: '\u0644\u0627 \u064A\u0648\u062C\u062F \u0645\u0648\u0638\u0641\u0648\u0646', text: '\u0623\u0636\u0641 \u0645\u0648\u0638\u0641\u064A\u0646 \u0623\u0648\u0644\u0627\u064B', ...swalTheme() });
    return;
  }
  Swal.fire({
    title: '\u0625\u0635\u062F\u0627\u0631 \u0627\u0644\u0631\u0648\u0627\u062A\u0628',
    html: '\u0633\u064A\u062A\u0645 \u062A\u063A\u064A\u064A\u0631 \u062D\u0627\u0644\u0629 \u062C\u0645\u064A\u0639 \u0627\u0644\u0643\u0634\u0648\u0641\u0627\u062A \u0625\u0644\u0649 <b>\u0645\u064F\u0635\u062F\u0631</b> \u0644\u0640 ' + employees.length + ' \u0645\u0648\u0638\u0641',
    icon: 'question', showCancelButton: true,
    confirmButtonText: '\u0646\u0639\u0645\u060C \u0623\u0635\u062F\u0631', cancelButtonText: '\u0625\u0644\u063A\u0627\u0621',
    ...swalTheme()
  }).then(async r => {
    if (!r.isConfirmed) return;
    pauseRemoteSync(10000);
    var previousSalaryDeletedMap = appSettings.salaryDeletedMap || {};
    appSettings.salaryDeletedMap = {};
    var employeesToIssue = [];
    applyLoanInstallmentsOnIssue();
    employees.forEach(function(e) {
      var periodKey = salaryPeriodKey(e.salaryType || 'monthly');
      var prevMarker = previousSalaryDeletedMap[String(e.id)];
      var prevPeriod = typeof prevMarker === 'object' && prevMarker ? prevMarker.period : prevMarker;
      var paidCurrent = (typeof prevMarker === 'object' && prevMarker && prevMarker.reason === 'paid' && prevPeriod === periodKey) ||
        (String(e.salStatus || '') === 'مدفوع' && (e.salDeletedPeriod === periodKey || prevPeriod === periodKey));
      if (paidCurrent) {
        appSettings.salaryDeletedMap[String(e.id)] = typeof prevMarker === 'object' && prevMarker
          ? Object.assign({}, prevMarker, { period: periodKey, reason: 'paid' })
          : { period: periodKey, at: new Date().toISOString(), reason: 'paid' };
        e.salDeletedPeriod = periodKey;
        return;
      }
      employeesToIssue.push(e);
      e.salStatus = '\u0645\u064F\u0635\u062F\u0631';
      e.salDeletedPeriod = '';
      var fin = financeTotalsForSalary(e);
      fin.items.forEach(function(item) {
        var amt = item.type === 'loan' && item.loanMode === 'installments'
          ? currentLoanInstallmentAmount(item)
          : exactMoneyValue(item.amount, 0);
        notifyEmployeeFinance(e.id, item.type, 'applied', amt, 'تم تطبيقه عند إصدار الرواتب', item.id);
      });
    });
    logActivity('issue', 'salaries', 'إصدار رواتب ' + employeesToIssue.length + ' موظف');
    if (typeof isKynoFinalLockdown === 'function' && isKynoFinalLockdown() && typeof sb_rpcIssueSalary === 'function') {
      for (var si = 0; si < employeesToIssue.length; si++) {
        var se = employeesToIssue[si];
        if (!se || !se.id) continue;
        var sm = salaryPeriodKey(se.salaryType || 'monthly');
        await sb_rpcIssueSalary(se.id, sm);
      }
    } else if (typeof isKynoRpcMode === 'function' && isKynoRpcMode() && typeof sb_rpcIssueSalary === 'function') {
      for (var si = 0; si < employeesToIssue.length; si++) {
        var se = employeesToIssue[si];
        if (!se || !se.id) continue;
        var sm = salaryPeriodKey(se.salaryType || 'monthly');
        await sb_rpcIssueSalary(se.id, sm);
      }
    } else if (typeof syncToSupabase === 'function') {
      await syncToSupabase({ allowDeletes: false, reason: 'issue-salaries' });
    }
    await persistSalaryDeletedMapNow();
    saveData();
    refreshAll();
    Swal.fire({ icon: 'success', title: '\u062A\u0645 \u0625\u0635\u062F\u0627\u0631 \u0627\u0644\u0631\u0648\u0627\u062A\u0628', text: '\u062A\u0645 \u0625\u0635\u062F\u0627\u0631 ' + employeesToIssue.length + ' \u0643\u0634\u0641 \u0631\u0627\u062A\u0628', ...swalTheme(), timer: 2000, showConfirmButton: false });
    resumeRemoteSync(9000);
  });
}

function exportSalPdf() {
  if (!requireActionPermission('salaries', 'export')) return;
  try {
    logActivity('export', 'salaries', 'تصدير كشف الرواتب PDF');
    var fDept = document.getElementById('sal-filter-dept')?.value || '';
    var fStatus = document.getElementById('sal-filter-status')?.value || '';
    var fName = typeof getEmployeeNameQuery === 'function'
      ? getEmployeeNameQuery('sal-filter-name')
      : (document.getElementById('sal-filter-name')?.value || '').trim().toLowerCase();
    var filtered = employees.filter(e => {
      if (isSalaryHiddenForCurrentPeriod(e)) return false;
      if (fDept && e.dept !== fDept) return false;
      if (fStatus && (e.salStatus || 'معلق') !== fStatus) return false;
      if (fName && typeof employeeMatchesNameQuery === 'function' && !employeeMatchesNameQuery(e, fName)) return false;
      if (fName && typeof employeeMatchesNameQuery !== 'function' && !String(e.name || '').toLowerCase().includes(fName)) return false;
      return true;
    });
    var headers = ['#','الموظف','القسم','الراتب الأساسي','الخصومات','الإضافي','المكافآت','الراتب الصافي','الحالة'];
    var statusColor = { 'معلق':'color:#c05621', 'مُصدر':'color:#2b6cb0', 'مدفوع':'color:#276749' };
    var rows = filtered.map((e, i) => {
      var sal = calcEmpSalary(e);
      var salStatus = e.salStatus || 'معلق';
      return [
        i + 1, esc(e.name), esc(e.dept),
        e.salary.toLocaleString() + ' IQD',
        sal.totalDeduct > 0 ? '<span style="color:#c53030">' + sal.totalDeduct.toLocaleString() + '</span>' : '—',
        sal.ot > 0 ? '<span style="color:#2b6cb0">' + sal.ot.toLocaleString() + '</span>' : '—',
        sal.bonus > 0 ? '<span style="color:#b7791f">' + sal.bonus.toLocaleString() + '</span>' : '—',
        salaryNetPdfHtml(sal.final, (e.salaryType || 'monthly') === 'commission'),
        '<span style="' + (statusColor[salStatus] || '') + ';font-weight:700">' + esc(salStatus) + '</span>'
      ];
    });
    var html = buildPrintPage('كشف الرواتب', esc(fDept || 'جميع الأقسام') + (fStatus ? ' — ' + esc(fStatus) : ''), headers, rows,
      'table{min-width:600px} .report-header{background:linear-gradient(135deg,#1a3a5c,#0f2240);color:#fff;border-radius:12px;padding:24px} .company-name,.report-title,.report-date{color:#fff} .sal-net-negative-inline{background:#c53030;color:#fff;padding:4px 10px;border-radius:6px}');
    presentPdfActions(html, 'كشف_الرواتب_' + new Date().toISOString().slice(0, 10) + '.pdf');
  } catch(e) {
    console.error('exportSalPdf error:', e);
    Swal.fire({ icon:'error', title:'خطأ في التصدير', text: e.message, ...swalTheme() });
  }
}

async function exportSalExcel() {
  if (!requireActionPermission('salaries', 'export')) return;
  try {
    if (typeof ensureXlsxLoaded === 'function') await ensureXlsxLoaded();
  } catch (e) {
    Swal.fire({ icon: 'error', title: 'خطأ', text: 'مكتبة XLSX غير محملة', ...swalTheme() });
    return;
  }
  if (typeof XLSX === 'undefined') {
    Swal.fire({ icon: 'error', title: 'خطأ', text: 'مكتبة XLSX غير محملة', ...swalTheme() });
    return;
  }
  logActivity('export', 'salaries', 'تصدير كشف الرواتب Excel');
  try {
    var fDept = document.getElementById('sal-filter-dept')?.value || '';
    var fStatus = document.getElementById('sal-filter-status')?.value || '';
    var fName = typeof getEmployeeNameQuery === 'function'
      ? getEmployeeNameQuery('sal-filter-name')
      : (document.getElementById('sal-filter-name')?.value || '').trim().toLowerCase();
    var filtered = employees.filter(function(e) {
      if (isSalaryHiddenForCurrentPeriod(e)) return false;
      if (fDept && e.dept !== fDept) return false;
      if (fStatus && (e.salStatus || 'معلق') !== fStatus) return false;
      if (fName && typeof employeeMatchesNameQuery === 'function' && !employeeMatchesNameQuery(e, fName)) return false;
      if (fName && typeof employeeMatchesNameQuery !== 'function' && String(e.name || '').toLowerCase().indexOf(fName) < 0) return false;
      return true;
    });
    var rows = filtered.map(function(e) {
      var sal = calcEmpSalary(e);
      return {
        'الموظف': e.name, 'القسم': e.dept,
        'الراتب الأساسي': e.salary, 'أيام الحضور': sal.attendDays,
        'الخصومات': sal.totalDeduct, 'الإضافي': sal.ot,
        'المكافآت': sal.bonus, 'الراتب الصافي': sal.final,
        'الحالة': e.salStatus || 'معلق'
      };
    });
    var wb = XLSX.utils.book_new();
    var ws = XLSX.utils.json_to_sheet(rows, { origin: 'A3' });
    ws['!dir'] = 'RTL';
    ws['!cols'] = [
      { wch: 22 }, { wch: 18 }, { wch: 16 }, { wch: 14 },
      { wch: 14 }, { wch: 14 }, { wch: 14 }, { wch: 16 }, { wch: 12 }
    ];
    var dateStr = new Date().toLocaleDateString('ar-IQ');
    ws['A1'] = { v: appSettings.companyName || 'كشوف الرواتب', t: 's' };
    ws['A2'] = { v: 'كشف الرواتب - ' + dateStr, t: 's' };
    ws['!merges'] = [
      { s: { r: 0, c: 0 }, e: { r: 0, c: 8 } },
      { s: { r: 1, c: 0 }, e: { r: 1, c: 8 } }
    ];
    XLSX.utils.book_append_sheet(wb, ws, 'الرواتب');
    XLSX.writeFile(wb, 'كشف_الرواتب_' + new Date().toISOString().slice(0, 10) + '.xlsx');
    Swal.fire({ icon: 'success', title: 'تم تصدير الملف', text: 'تم تحميل ملف Excel بنجاح', ...swalTheme(), timer: 2000, showConfirmButton: false });
  } catch (e) {
    Swal.fire({ icon: 'error', title: 'خطأ', text: e.message, ...swalTheme() });
  }
}

// ======= FINANCE ADJUSTMENTS =======
function getAppSettingsStore() {
  return (typeof window !== 'undefined' && window.appSettings) ? window.appSettings : appSettings;
}

function financeItems() {
  var store = getAppSettingsStore();
  if (!Array.isArray(store.financeItems)) store.financeItems = [];
  store.financeItems.forEach(normalizeFinanceItem);
  return store.financeItems;
}

function normalizeFinanceItem(item) {
  if (!item) return item;
  if (item.id == null || item.id === '') {
    item.id = 'fin_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7);
  }
  item.empId = parseInt(item.empId != null ? item.empId : (item.emp_id != null ? item.emp_id : item.employee_id), 10) || item.empId;
  var typeRaw = String(item.type || '').trim();
  var typeKey = typeRaw.toLowerCase();
  var typeMap = {
    deduction: 'deduction', bonus: 'bonus', loan: 'loan', deduct: 'deduction', reward: 'bonus', advance: 'loan',
    '\u062e\u0635\u0645': 'deduction', '\u0645\u0643\u0627\u0641\u0623\u0629': 'bonus', '\u0645\u0643\u0627\u0641\u0622\u062a': 'bonus',
    '\u0633\u0644\u0641\u0629': 'loan', '\u0633\u0644\u0641': 'loan'
  };
  if (typeMap[typeRaw]) item.type = typeMap[typeRaw];
  else if (typeMap[typeKey]) item.type = typeMap[typeKey];
  item.date = item.date ? String(item.date).slice(0, 10) : (item.createdAt ? String(item.createdAt).slice(0, 10) : '');
  item.amount = exactMoneyValue(item.amount, 0);
  item.installmentCount = Math.max(1, exactMoneyValue(item.installmentCount, 1));
  item.paidInstallments = Math.max(0, exactMoneyValue(item.paidInstallments, 0));
  if (item.type === 'loan' && item.loanMode === 'installments') {
    item.installmentAmount = exactMoneyValue(item.installmentAmount, 0) || Math.floor(item.amount / item.installmentCount);
  } else {
    item.installmentAmount = 0;
  }
  // حركات قديمة/مستعادة بلا period: اربطها بشهر تاريخها الفعلي بدل تركها بلا فترة
  // (بلا هذا الربط تُعامَل كـ"صالحة لكل شهر إلى الأبد" وتظل تظهر في كل كشوف الرواتب اللاحقة)
  if (!item.period && item.date && /^\d{4}-\d{2}-\d{2}$/.test(String(item.date).slice(0, 10))) {
    var finEmp = (employees || []).find(function (e) { return e && String(e.id) === String(item.empId); });
    item.period = financePeriodFromDateLike(String(item.date).slice(0, 10), finEmp);
  }
  return item;
}

/** فترة الراتب من تاريخ حركة مالية — لإصلاح/إسناد الحركات القديمة بلا period */
function financePeriodFromDateLike(dateStr, emp) {
  var iso = String(dateStr || '').slice(0, 10);
  var ym = iso.slice(0, 7);
  if (!/^\d{4}-\d{2}$/.test(ym)) return financePeriodForEmp(emp);
  var type = (emp && emp.salaryType) || 'monthly';
  if (type === 'biweekly') {
    var day = parseInt(iso.slice(8, 10), 10) || 1;
    var split = typeof getBiweeklySplitDay === 'function' ? getBiweeklySplitDay() : 15;
    return ym + '-' + (day <= split ? 'H1' : 'H2');
  }
  return ym;
}

function currentLoanInstallmentAmount(item) {
  normalizeFinanceItem(item);
  if (!item || item.type !== 'loan') return 0;
  if (item.loanMode !== 'installments') return item.amount;
  const count = Math.max(1, item.installmentCount || 1);
  const paid = Math.max(0, item.paidInstallments || 0);
  if (paid >= count) return 0;
  const normal = item.installmentAmount || Math.floor(item.amount / count);
  const paidAmount = normal * paid;
  const remaining = Math.max(0, item.amount - paidAmount);
  return paid === count - 1 ? remaining : Math.min(normal, remaining);
}

function financePeriodForEmp(emp) {
  return salaryPeriodKey((emp && emp.salaryType) || 'monthly');
}

function financeItemAppliesToPeriod(item, period) {
  if (!item || !period) return false;
  var iperiod = String(item.period || '').trim();
  if (iperiod) {
    return iperiod === period || iperiod.slice(0, 7) === String(period).slice(0, 7);
  }
  // بلا period (لا يُفترض بعد الآن — normalizeFinanceItem تُسنِده من التاريخ):
  // احتياط أخير بشهر التاريخ/الإنشاء، وإلا لا تُطبَّق تلقائياً على كل الشهور
  var dateYm = item.date ? String(item.date).slice(0, 7) : '';
  var createdYm = item.createdAt ? String(item.createdAt).slice(0, 7) : '';
  var ym = dateYm || createdYm;
  if (ym) return ym === String(period).slice(0, 7);
  return false;
}

function financeItemAppliesToSalary(item, emp) {
  if (!item || String(item.empId) !== String(emp.id) || item.status === 'ملغي' || item.status === 'مسدد') return false;
  const period = financePeriodForEmp(emp);
  if (item.type === 'loan') {
    if (item.loanMode === 'installments') return item.status !== 'مسدد';
    return financeItemAppliesToPeriod(item, period);
  }
  return financeItemAppliesToPeriod(item, period);
}

function financeTotalsForSalary(emp) {
  const totals = { deductions: 0, bonuses: 0, loans: 0, items: [] };
  financeItems().forEach(item => {
    if (!financeItemAppliesToSalary(item, emp)) return;
    const amount = exactMoneyValue(item.amount, 0);
    if (item.type === 'bonus') {
      totals.bonuses += amount;
    } else if (item.type === 'deduction') {
      totals.deductions += amount;
    } else if (item.type === 'loan') {
      if (item.loanMode === 'installments') {
        totals.loans += currentLoanInstallmentAmount(item);
      } else {
        totals.loans += amount;
      }
    }
    totals.items.push(item);
  });
  return totals;
}

function applyLoanInstallmentsOnIssue() {
  const period = salaryPeriodKey('monthly').slice(0, 7);
  financeItems().forEach(item => {
    if (item.status === 'مسدد' || item.status === 'ملغي') return;
    if (item.type === 'loan') {
      if (item.loanMode === 'installments') {
        const count = Math.max(1, parseInt(item.installmentCount || 1, 10));
        const paid = Math.min(count, parseInt(item.paidInstallments || 0, 10) + 1);
        item.lastInstallmentAmount = currentLoanInstallmentAmount(item);
        item.paidInstallments = paid;
        item.status = paid >= count ? 'مسدد' : 'نشط';
      } else {
        item.status = 'مسدد';
      }
      item.lastSalaryPeriod = period;
    } else if (item.period && item.period.slice(0, 7) === period) {
      item.status = 'مطبق';
    }
  });
}

function buildFinancePage() {
  var renderFinancePage = function () {
    buildFinancePageNow();
  };
  if (typeof hydrateFinanceItemsFromCloud === 'function') {
    hydrateFinanceItemsFromCloud({ forceRemote: true, replace: true }).then(renderFinancePage).catch(renderFinancePage);
    return;
  }
  renderFinancePage();
}

function buildFinancePageNow() {
  const tbody = document.getElementById('finance-table');
  const empFilter = document.getElementById('fin-filter-emp');
  if (!tbody) return;
  if (empFilter) {
    const keep = empFilter.value;
    empFilter.innerHTML = '<option value="">كل الموظفين</option>' + employees.map(e => '<option value="' + e.id + '">' + esc(e.name) + '</option>').join('');
    empFilter.value = keep;
  }
  const typeFilter = document.getElementById('fin-filter-type')?.value || '';
  const empIdFilter = parseInt(document.getElementById('fin-filter-emp')?.value || '0', 10);
  const list = financeItems().filter(item => (!typeFilter || item.type === typeFilter) && (!empIdFilter || String(item.empId) === String(empIdFilter)));
  const totalDeduct = financeItems().filter(i => i.type === 'deduction' && i.status !== 'ملغي').reduce((s,i) => s + exactMoneyValue(i.amount,0), 0);
  const totalBonus = financeItems().filter(i => i.type === 'bonus' && i.status !== 'ملغي').reduce((s,i) => s + exactMoneyValue(i.amount,0), 0);
  const totalLoans = financeItems().filter(i => i.type === 'loan' && i.status !== 'مسدد' && i.status !== 'ملغي').reduce((s,i) => s + exactMoneyValue(i.amount,0), 0);
  const dEl = document.getElementById('fin-total-deduct');
  const bEl = document.getElementById('fin-total-bonus');
  const lEl = document.getElementById('fin-total-loans');
  if (dEl) dEl.textContent = totalDeduct.toLocaleString();
  if (bEl) bEl.textContent = totalBonus.toLocaleString();
  if (lEl) lEl.textContent = totalLoans.toLocaleString();
  if (!list.length) {
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:28px;color:var(--text-muted)">لا توجد حركات مالية</td></tr>';
    return;
  }
  const typeLabel = { deduction:'خصم', bonus:'مكافأة', loan:'سلفة' };
  tbody.innerHTML = list.map((item, i) => {
    const emp = employees.find(e => e.id === item.empId);
    const installment = item.type === 'loan' && item.loanMode === 'installments'
      ? ((item.paidInstallments || 0) + '/' + (item.installmentCount || 1) + ' × ' + currentLoanInstallmentAmount(item).toLocaleString())
      : '—';
    const dayName = arabicDayNameFromDate(item.date);
    const dateCell = item.date
      ? esc(String(item.date).slice(0, 10)) + (dayName ? '<br><span style="font-size:11px;color:var(--text-muted)">' + esc(dayName) + '</span>' : '')
      : '—';
    return '<tr><td>' + (i + 1) + '</td><td>' + esc(emp ? emp.name : 'موظف محذوف') + '</td><td>' + dateCell + '</td><td>' + esc(typeLabel[item.type] || item.type) + '</td><td>' + exactMoneyValue(item.amount,0).toLocaleString() + '</td><td>' + esc(installment) + '</td><td>' + esc(item.status || 'نشط') + '</td><td>' + esc(item.note || '—') + '</td><td>' +
      (hasActionPermission('finance', 'edit') ? '<button class="btn-sm btn-primary" onclick="openFinanceItemForm(' + escAttr(JSON.stringify(item.id)) + ')"><i class="fa fa-edit"></i></button>' : '') +
      (hasActionPermission('finance', 'delete') ? '<button class="btn-sm btn-danger" onclick="deleteFinanceItem(' + escAttr(JSON.stringify(item.id)) + ')"><i class="fa fa-trash"></i></button>' : '') +
      '</td></tr>';
  }).join('');
}

function openFinanceItemForm(id) {
  if (!requireActionPermission('finance', id ? 'edit' : 'add')) return;
  const existing = id !== undefined && id !== null ? financeItems().find(i => String(i.id) === String(id)) : null;
  const empOpts = employees.map(e => '<option value="' + e.id + '"' + (existing && existing.empId === e.id ? ' selected' : '') + '>' + esc(e.name) + '</option>').join('');
  Swal.fire({
    title: existing ? 'تعديل حركة مالية' : 'إضافة حركة مالية',
    html: '<div style="text-align:right">' +
      '<div class="emp-field"><label>الموظف</label><select id="fin-emp" class="setting-input">' + empOpts + '</select></div>' +
      '<div class="emp-field"><label>النوع</label><select id="fin-type" class="setting-input" onchange="document.getElementById(\'fin-loan-box\').style.display=this.value===\'loan\'?\'\':\'none\'"><option value="deduction"' + (existing?.type === 'deduction' ? ' selected' : '') + '>خصم</option><option value="bonus"' + (existing?.type === 'bonus' ? ' selected' : '') + '>مكافأة</option><option value="loan"' + (existing?.type === 'loan' ? ' selected' : '') + '>سلفة</option></select></div>' +
      '<div class="emp-field"><label>المبلغ</label><input type="number" id="fin-amount" class="setting-input" min="0" value="' + (existing ? existing.amount : '') + '"></div>' +
      '<div class="emp-field"><label>التاريخ</label><input type="date" id="fin-date" class="setting-input" value="' + (existing && existing.date ? esc(String(existing.date).slice(0, 10)) : (typeof todayIsoDate === 'function' ? todayIsoDate() : '')) + '"><span class="emp-field-hint">يُشتق اسم اليوم تلقائياً من التاريخ.</span></div>' +
      '<div id="fin-loan-box" style="display:' + (existing?.type === 'loan' ? '' : 'none') + '">' +
      '<div class="emp-field"><label>طريقة السلفة</label><select id="fin-loan-mode" class="setting-input"><option value="direct"' + (existing?.loanMode !== 'installments' ? ' selected' : '') + '>استقطاع مباشر من الراتب</option><option value="installments"' + (existing?.loanMode === 'installments' ? ' selected' : '') + '>على شكل دفعات</option></select></div>' +
      '<div class="emp-field-row"><div class="emp-field"><label>مبلغ الدفعة</label><input type="number" id="fin-installment-amount" class="setting-input" min="0" value="' + (existing?.installmentAmount || '') + '"></div><div class="emp-field"><label>عدد الدفعات</label><input type="number" id="fin-installment-count" class="setting-input" min="1" value="' + (existing?.installmentCount || 1) + '"></div></div>' +
      '</div>' +
      '<div class="emp-field"><label>ملاحظة</label><input id="fin-note" class="setting-input" value="' + ((existing?.note || '').replace(/"/g,'&quot;')) + '"></div>' +
      '</div>',
    ...swalTheme(), showCancelButton:true, confirmButtonText:'حفظ', cancelButtonText:'إلغاء',
    preConfirm: () => {
      const empId = parseInt(document.getElementById('fin-emp')?.value, 10);
      const type = document.getElementById('fin-type')?.value || 'deduction';
      const amount = readMoneyValue('fin-amount', 0);
      const loanMode = document.getElementById('fin-loan-mode')?.value || 'direct';
      const installmentCount = Math.max(1, readMoneyValue('fin-installment-count', 1));
      const installmentAmount = readMoneyValue('fin-installment-amount', 0) || Math.floor(amount / installmentCount);
      const note = document.getElementById('fin-note')?.value.trim() || '';
      const date = (document.getElementById('fin-date')?.value || '').slice(0, 10);
      if (!empId) { Swal.showValidationMessage('اختر الموظف'); return false; }
      if (!amount) { Swal.showValidationMessage('أدخل المبلغ'); return false; }
      const emp = employees.find(e => e.id === empId);
      return { empId, type, amount, originalAmount: amount, loanMode, installmentCount, installmentAmount, note, date, period: financePeriodForEmp(emp), status: 'نشط' };
    }
  }).then(async r => {
    if (!r.isConfirmed || !r.value) return;
    pauseRemoteSync(18000);
    window.__basmaLocalSettingsAt = Date.now();
    var prevItem = existing ? Object.assign({}, existing) : null;
    var item = existing ? normalizeFinanceItem(Object.assign(existing, r.value, { updatedAt: new Date().toISOString() })) : normalizeFinanceItem({ id: Date.now(), createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), paidInstallments: 0, ...r.value });
    if (!existing) financeItems().unshift(item);
    if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(item.empId);
    var emp = employees.find(function(e) { return e.id === item.empId; });
    var typeLabel = NOTIF_FINANCE_LABELS[item.type] || item.type;
    logActivity(existing ? 'edit' : 'add', 'finance', (existing ? 'تعديل' : 'إضافة') + ' ' + typeLabel + ' للموظف: ' + (emp ? emp.name : '') + ' — ' + exactMoneyValue(item.amount, 0).toLocaleString() + ' IQD', { targetName: emp ? emp.name : '', empId: item.empId, targetEmpId: item.empId });
    notifyEmployeeFinance(item.empId, item.type, existing ? 'edit' : 'add', item.amount, item.note, item.id);
    var cloud = await persistSalaryDeletedMapNow();
    if (!cloud || cloud.ok !== true) {
      if (existing && prevItem) {
        Object.assign(existing, prevItem);
      } else {
        var rollbackIdx = financeItems().findIndex(function(i) { return String(i.id) === String(item.id); });
        if (rollbackIdx >= 0) financeItems().splice(rollbackIdx, 1);
      }
      if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(item.empId);
      saveData();
      refreshAll();
      resumeRemoteSync(0);
      Swal.fire({ icon:'warning', title:'تعذّر الحفظ في السحابة', text:'لم تُحفظ الحركة نهائياً حتى لا تختفي بعد المزامنة. أعد تسجيل الدخول ثم حاول مرة أخرى.', ...swalTheme() });
      return;
    }
    if (typeof persistNotificationsNow === 'function') await persistNotificationsNow();
    saveData();
    refreshAll();
    resumeRemoteSync(9000);
    Swal.fire({ icon:'success', title:'تم حفظ الحركة المالية', ...swalTheme(), timer:1400, showConfirmButton:false });
  });
}

function deleteFinanceItem(id) {
  if (!requireActionPermission('finance', 'delete')) return;
  const idx = financeItems().findIndex(i => String(i.id) === String(id));
  if (idx < 0) return;
  const removed = financeItems()[idx];
  Swal.fire({ icon:'warning', title:'حذف الحركة المالية', text:'هل تريد حذف هذه الحركة؟', showCancelButton:true, confirmButtonText:'حذف', cancelButtonText:'إلغاء', ...swalTheme(), confirmButtonColor:'#e53e3e' }).then(async r => {
    if (!r.isConfirmed) return;
    pauseRemoteSync(18000);
    window.__basmaLocalSettingsAt = Date.now();
    const freshIdx = financeItems().findIndex(i => String(i.id) === String(id));
    if (freshIdx < 0) { resumeRemoteSync(0); return; }
    const removedNow = financeItems()[freshIdx];
    financeItems().splice(freshIdx, 1);
    const removed = removedNow;
    var emp = employees.find(function(e) { return e.id === removed.empId; });
    var typeLabel = NOTIF_FINANCE_LABELS[removed.type] || removed.type;
    if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(removed.empId);
    saveData();
    const cloud = await persistSalaryDeletedMapNow();
    if (!cloud || cloud.ok !== true) {
      financeItems().splice(Math.min(freshIdx, financeItems().length), 0, removed);
      if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(removed.empId);
      saveData();
      refreshAll();
      resumeRemoteSync(0);
      Swal.fire({ icon:'warning', title:'لم يتم الحذف من السحابة', text:'لم أحذف الحركة نهائياً حتى لا تعود بعد المزامنة. أعد تسجيل الدخول ثم حاول مرة أخرى.', ...swalTheme() });
      return;
    }
    logActivity('delete', 'finance', 'حذف ' + typeLabel + ' للموظف: ' + (emp ? emp.name : '') + ' — ' + exactMoneyValue(removed.amount, 0).toLocaleString() + ' IQD', { targetName: emp ? emp.name : '', empId: removed.empId, targetEmpId: removed.empId });
    notifyEmployeeFinance(removed.empId, removed.type, 'delete', removed.amount, removed.note || 'تم حذف الحركة', removed.id);
    if (typeof persistNotificationsNow === 'function') await persistNotificationsNow();
    saveData();
    refreshAll();
    resumeRemoteSync(9000);
  });
}

async function exportFinanceReport() {
  if (!requireActionPermission('finance', 'export')) return;
  logActivity('export', 'finance', 'تصدير تقرير الحركات المالية Excel');
  const finTypeLabel = { deduction:'خصم', bonus:'مكافأة', loan:'سلفة' };
  const rows = financeItems().map(item => {
    const emp = employees.find(e => e.id === item.empId);
    return { 'الموظف': emp ? emp.name : '', 'التاريخ': item.date ? String(item.date).slice(0, 10) : '', 'اليوم': arabicDayNameFromDate(item.date), 'النوع': finTypeLabel[item.type] || item.type, 'المبلغ': exactMoneyValue(item.amount,0), 'الحالة': item.status, 'الأقساط': (item.paidInstallments || 0) + '/' + (item.installmentCount || 1), 'ملاحظة': item.note || '' };
  });
  try {
    if (typeof ensureXlsxLoaded === 'function') await ensureXlsxLoaded();
  } catch (e) { /* fall through to info dialog */ }
  if (typeof XLSX === 'undefined') { Swal.fire({ icon:'info', title:'تقرير الحركات المالية', text:'عدد الحركات: ' + rows.length, ...swalTheme() }); return; }
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows), 'Finance');
  XLSX.writeFile(wb, 'finance_report.xlsx');
}

// المرحلة 4 — طباعة تقرير الحركات المالية (يشمل التاريخ واسم اليوم) وفق الفلاتر الحالية
function printFinanceReport() {
  if (!requireActionPermission('finance', 'export')) return;
  const typeFilter = document.getElementById('fin-filter-type')?.value || '';
  const empIdFilter = parseInt(document.getElementById('fin-filter-emp')?.value || '0', 10);
  const list = financeItems().filter(item => (!typeFilter || item.type === typeFilter) && (!empIdFilter || String(item.empId) === String(empIdFilter)));
  if (!list.length) { Swal.fire({ icon:'info', title:'لا توجد حركات', text:'لا توجد حركات مالية للطباعة.', ...swalTheme() }); return; }
  const finTypeLabel = { deduction:'خصم', bonus:'مكافأة', loan:'سلفة' };
  const headers = ['#','الموظف','التاريخ','اليوم','النوع','المبلغ','الأقساط','الحالة','الملاحظات'];
  const rows = list.map((item, i) => {
    const emp = employees.find(e => e.id === item.empId);
    const installment = item.type === 'loan' && item.loanMode === 'installments'
      ? ((item.paidInstallments || 0) + '/' + (item.installmentCount || 1) + ' × ' + currentLoanInstallmentAmount(item).toLocaleString())
      : '—';
    return [
      String(i + 1),
      esc(emp ? emp.name : 'موظف محذوف'),
      item.date ? esc(String(item.date).slice(0, 10)) : '—',
      esc(arabicDayNameFromDate(item.date) || '—'),
      esc(finTypeLabel[item.type] || item.type),
      exactMoneyValue(item.amount, 0).toLocaleString() + ' IQD',
      esc(installment),
      esc(item.status || 'نشط'),
      esc(item.note || '—')
    ];
  });
  logActivity('export', 'finance', 'طباعة تقرير الحركات المالية');
  const html = buildPrintPage('تقرير الحركات المالية', 'الخصومات والمكافآت والسلف', headers, rows, 'table{min-width:720px}');
  presentPdfActions(html, 'finance_report_' + new Date().toISOString().slice(0, 10) + '.pdf');
}

function buildOrgPage() {
  ensureOrgLists();
  var deptBody = document.getElementById('dept-table');
  var jobBody = document.getElementById('job-table');
  var emptyRow = '<tr class="org-empty-row"><td colspan="4">لا توجد عناصر — أضف من الزر أعلاه</td></tr>';
  if (deptBody) {
    deptBody.innerHTML = appSettings.departments.length
      ? appSettings.departments.map(function (d, i) { return orgTableRowHtml('dept', d, i); }).join('')
      : emptyRow;
  }
  if (jobBody) {
    jobBody.innerHTML = appSettings.jobs.length
      ? appSettings.jobs.map(function (j, i) { return orgTableRowHtml('job', j, i); }).join('')
      : emptyRow;
  }
}

function openOrgItemForm(type, idx) {
  if (!requireActionPermission('org', idx !== undefined && idx !== null ? 'edit' : 'add')) return;
  pauseRemoteSync(20000);
  var resolvedIdx = typeof idx === 'number' ? idx : -1;
  var arr = getOrgArray(type);
  var oldVal = resolvedIdx >= 0 ? arr[resolvedIdx] : '';
  Swal.fire({
    title: (resolvedIdx >= 0 ? 'تعديل ' : 'إضافة ') + (type === 'dept' ? 'قسم' : 'وظيفة'),
    input: 'text',
    inputValue: oldVal,
    inputPlaceholder: type === 'dept' ? 'اسم القسم' : 'اسم الوظيفة',
    showCancelButton: true,
    confirmButtonText: 'حفظ',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: function (v) {
      var n = normalizeOrgName(v);
      if (!n) { Swal.showValidationMessage('أدخل الاسم'); return false; }
      return n;
    }
  }).then(async function (r) {
    if (!r.isConfirmed || !r.value) { resumeRemoteSync(); return; }
    pauseRemoteSync(25000);
    var list = getOrgArray(type);
    var val = normalizeOrgName(r.value);
    var changed = false;
    if (resolvedIdx >= 0) {
      var prev = list[resolvedIdx];
      if (normalizeOrgName(prev) === val) { resumeRemoteSync(); return; }
      if (orgNameExists(list, val, resolvedIdx)) {
        resumeRemoteSync();
        Swal.fire({ icon: 'info', title: 'موجود مسبقاً', text: '«' + val + '» موجود في القائمة', ...swalTheme(), timer: 2000, showConfirmButton: false });
        return;
      }
      if (type === 'dept' && typeof sb_renameDepartment === 'function') {
        var renameRes = await sb_renameDepartment(prev, val);
        if (!renameRes || !renameRes.ok) {
          resumeRemoteSync();
          var renameMsg = (renameRes && renameRes.error === 'duplicate') ? 'يوجد قسم بنفس الاسم' : 'تعذّر تعديل القسم في قاعدة البيانات';
          Swal.fire({ icon: 'error', title: 'فشل التعديل', text: renameMsg, ...swalTheme() });
          return;
        }
      } else if (type === 'dept' && typeof sb_ensureDepartment === 'function') {
        var ensureRen = await sb_ensureDepartment(val);
        if (!ensureRen) {
          resumeRemoteSync();
          Swal.fire({ icon: 'error', title: 'فشل التعديل', text: 'تعذّر حفظ القسم في قاعدة البيانات', ...swalTheme() });
          return;
        }
        if (typeof sb_deleteDepartment === 'function') await sb_deleteDepartment(prev);
      }
      list[resolvedIdx] = val;
      changed = true;
      employees.forEach(function (e) {
        if (!e) return;
        if (type === 'dept' && normalizeOrgName(e.dept) === normalizeOrgName(prev)) e.dept = val;
        if (type === 'job' && normalizeOrgName(e.role) === normalizeOrgName(prev)) e.role = val;
      });
      logActivity('edit', 'org', 'تعديل ' + (type === 'dept' ? 'قسم' : 'وظيفة') + ': ' + prev + ' → ' + val, { deferSave: true });
    } else if (!orgNameExists(list, val)) {
      if (type === 'dept' && typeof sb_ensureDepartment === 'function') {
        var ensured = await sb_ensureDepartment(val);
        if (!ensured) {
          resumeRemoteSync();
          Swal.fire({ icon: 'error', title: 'فشل الإضافة', text: 'تعذّر حفظ القسم في قاعدة البيانات', ...swalTheme() });
          return;
        }
      }
      list.push(val);
      changed = true;
      logActivity('add', 'org', 'إضافة ' + (type === 'dept' ? 'قسم' : 'وظيفة') + ': ' + val, { deferSave: true });
    } else {
      resumeRemoteSync();
      Swal.fire({ icon: 'info', title: 'موجود مسبقاً', text: '«' + val + '» موجود في القائمة', ...swalTheme(), timer: 2000, showConfirmButton: false });
      return;
    }
    if (!changed) { resumeRemoteSync(); return; }
    ensureOrgLists();
    var orgSave = await persistOrgSettingsNow();
    await persistSalaryDeletedMapNow();
    if (typeof syncWindowState === 'function') syncWindowState();
    saveData();
    buildOrgPage();
    refreshAll();
    resumeRemoteSync(12000);
    if (orgSave.ok) {
      Swal.fire({
        icon: 'success',
        title: resolvedIdx >= 0 ? 'تم التعديل' : 'تمت الإضافة',
        text: (type === 'dept' ? 'القسم' : 'الوظيفة') + ' «' + val + '» حُفظ في النظام',
        ...swalTheme(),
        timer: 2200,
        showConfirmButton: false
      });
    } else {
      Swal.fire({
        icon: 'error',
        title: 'لم يتم الحفظ',
        html: 'تعذّر حفظ «' + esc(val) + '» في السحابة.<br><span style="font-size:12px;color:var(--text-muted)">تحقق من الإنترنت أو أعد تسجيل الدخول ثم حاول مرة أخرى.</span>',
        ...swalTheme(),
        timer: 3500,
        showConfirmButton: false
      });
    }
  });
}

function deleteOrgItem(type, idx) {
  if (!requireActionPermission('org', 'delete')) return;
  var arr = getOrgArray(type);
  var val = arr[idx];
  if (!val) return;
  var used = employees.some(function (e) {
    if (!e) return false;
    return type === 'dept'
      ? normalizeOrgName(e.dept) === normalizeOrgName(val)
      : normalizeOrgName(e.role) === normalizeOrgName(val);
  });
  if (used) {
    Swal.fire({ icon: 'warning', title: 'لا يمكن الحذف', text: 'هذا العنصر مرتبط بموظفين. عدّله أو غيّر بيانات الموظفين أولاً.', ...swalTheme() });
    return;
  }
  Swal.fire({
    icon: 'warning',
    title: 'تأكيد الحذف',
    text: 'حذف «' + val + '» من ' + (type === 'dept' ? 'الأقسام' : 'الوظائف') + '؟',
    showCancelButton: true,
    confirmButtonText: 'نعم، احذف',
    cancelButtonText: 'إلغاء',
    confirmButtonColor: '#e53e3e',
    ...swalTheme()
  }).then(async function (r) {
    if (!r.isConfirmed) return;
    pauseRemoteSync(20000);
    if (type === 'dept' && typeof sb_deleteDepartment === 'function') {
      var delRes = await sb_deleteDepartment(val);
      if (!delRes || !delRes.ok) {
    resumeRemoteSync();
        Swal.fire({ icon: 'error', title: 'فشل الحذف', text: 'تعذّر حذف القسم من قاعدة البيانات', ...swalTheme() });
    return;
      }
  }
  arr.splice(idx, 1);
    ensureOrgLists();
  logActivity('delete', 'org', 'حذف ' + (type === 'dept' ? 'قسم' : 'وظيفة') + ': ' + val, { deferSave: true });
    var orgSave = await persistOrgSettingsNow();
    await persistSalaryDeletedMapNow();
    if (typeof syncWindowState === 'function') syncWindowState();
    saveData();
    buildOrgPage();
    refreshAll();
    resumeRemoteSync(10000);
    if (orgSave.ok) {
      Swal.fire({ icon: 'success', title: 'تم الحذف', timer: 1800, showConfirmButton: false, ...swalTheme() });
    }
  });
}

// ======= NOTIFICATIONS =======
const NOTIF_ACTION_LABELS = {
  add: 'إضافة', edit: 'تعديل', delete: 'حذف', download: 'تحميل', export: 'تصدير',
  pay: 'دفع', issue: 'إصدار', checkin: 'تسجيل حضور', checkout: 'تسجيل انصراف',
  login: 'تسجيل دخول', logout: 'تسجيل خروج', backup: 'نسخ احتياطي', reset: 'مسح بيانات', applied: 'تطبيق',
  import: 'استيراد'
};
const NOTIF_CATEGORY_LABELS = {
  employees: 'الموظفون', attendance: 'الحضور', salaries: 'الرواتب', finance: 'المالية',
  leaves: 'الإجازات والغياب',
  org: 'الأقسام', settings: 'الإعدادات', users: 'المستخدمون', reports: 'التقارير',
  system: 'النظام', backup: 'النسخ الاحتياطي', subscriptions: 'الاشتراكات', companies: 'الشركات'
};
const NOTIF_FINANCE_LABELS = { deduction: 'خصم', bonus: 'مكافأة', loan: 'سلفة', leave: 'إجازة', absence: 'غياب', salary: 'راتب' };

/** اسم الشركة من جلسة الدخول — لا نعتمد على appSettings المحلي (قد يكون لشركة أخرى) */
function getCompanyDisplayName() {
  var name = '';
  if (window._loginBlockedCompany && window._loginBlockedCompany.name) {
    name = String(window._loginBlockedCompany.name).trim();
  }
  if (!name && saasCurrentUser && saasCurrentUser.company_name) {
    name = String(saasCurrentUser.company_name).trim();
  }
  if (!name && typeof appSettings !== 'undefined' && appSettings.companyName) {
    name = String(appSettings.companyName).trim();
  }
  return name || 'الشركة';
}

function getCompanyDisplayCode() {
  if (saasCurrentUser && saasCurrentUser.company_code) {
    return String(saasCurrentUser.company_code).trim();
  }
  if (window._loginBlockedCompany && window._loginBlockedCompany.code) {
    return String(window._loginBlockedCompany.code).trim();
  }
  return '';
}

/** تحويل رقم واتساب عراقي/دولي إلى صيغة wa.me (964...) */
function normalizeWhatsAppPhone(raw) {
  if (!raw) return '';
  var s = String(raw).trim();
  if (/wa\.me|whatsapp\.com/i.test(s)) {
    var fromQuery = s.match(/[?&]phone=(\+?\d+)/i);
    var fromPath = s.match(/wa\.me\/(\d+)/i);
    if (fromQuery && fromQuery[1]) s = fromQuery[1];
    else if (fromPath && fromPath[1]) s = fromPath[1];
  }
  var digits = s.replace(/\D/g, '');
  if (!digits) return '';
  if (digits.indexOf('00') === 0) digits = digits.slice(2);
  if (digits.charAt(0) === '0' && digits.length >= 10) {
    digits = '964' + digits.slice(1);
  } else if (digits.length === 10 && digits.charAt(0) === '7') {
    digits = '964' + digits;
  }
  if (digits.length < 11 || digits.length > 15) return '';
  return digits;
}

function getPlatformWhatsAppRaw(kind) {
  kind = kind || 'subscription';
  var ps = window.platformSettings || {};
  if (kind === 'team') {
    var team = ps.supportWhatsAppTeam ? String(ps.supportWhatsAppTeam).trim() : '';
    if (team) return team;
  }
  var sub = ps.supportWhatsApp ? String(ps.supportWhatsApp).trim() : '';
  if (sub) return sub;
  if (appSettings && appSettings.supportWhatsAppUrl) return String(appSettings.supportWhatsAppUrl).trim();
  return '07733344940';
}

function getSupportWhatsAppPhone(kind) {
  kind = kind || 'subscription';
  return normalizeWhatsAppPhone(getPlatformWhatsAppRaw(kind)) || '9647733344940';
}

function getTeamWhatsAppPhone() {
  return getSupportWhatsAppPhone('team');
}

/** رابط واتساب مع رسالة جاهزة — api.whatsapp.com أوضح من wa.me على الويب */
function buildWhatsAppChatUrl(phone, messageText) {
  var normalized = normalizeWhatsAppPhone(phone);
  if (!normalized) return '';
  var url = 'https://api.whatsapp.com/send?phone=' + normalized;
  if (messageText != null && String(messageText).trim()) {
    url += '&text=' + encodeURIComponent(String(messageText).trim());
  }
  return url;
}

function openWhatsAppChat(phone, messageText) {
  var url = buildWhatsAppChatUrl(phone, messageText);
  if (!url) return;
  var opened = window.open(url, '_blank', 'noopener,noreferrer');
  if (!opened) window.location.href = url;
}

/** واتساب الدعم — متاح من main.js قبل login.js */
function getSupportWhatsAppUrl() {
  return buildWhatsAppChatUrl(getSupportWhatsAppPhone('subscription'), '');
}

function _buildCompanyWhatsAppMessage(suffix) {
  var companyLabel = getCompanyDisplayName();
  var code = getCompanyDisplayCode();
  var codeLabel = code ? (' — كود: ' + code) : '';
  return 'مرحباً، ' + companyLabel + codeLabel + ' — ' + suffix;
}

/** تجديد / تفعيل الاشتراك */
function contactSuperAdmin(customMsg) {
  var text = customMsg || _buildCompanyWhatsAppMessage('أريد تجديد الاشتراك.');
  openWhatsAppChat(getSupportWhatsAppPhone('subscription'), text);
}

/** تواصل مع فريق الدعم الفني */
function contactSupportTeam(customMsg) {
  var text = customMsg || _buildCompanyWhatsAppMessage('أحتاج مساعدة من فريق الدعم.');
  openWhatsAppChat(getTeamWhatsAppPhone(), text);
}

function contactSuperAdminFromLogin() {
  contactSuperAdmin();
}

function contactSupportTeamFromLogin() {
  contactSupportTeam();
}

function syncCompanySupportUi() {
  var topBtn = document.getElementById('topbar-support-btn');
  var settingsCard = document.getElementById('company-support-card');
  var isCompany = !!(saasCurrentUser && saasCurrentUser.company_id && saasCurrentUser.role !== 'super_admin' && currentUser === 'admin');
  if (topBtn) topBtn.style.display = isCompany ? 'inline-flex' : 'none';
  var sidebarOld = document.getElementById('sidebar-support-team');
  if (sidebarOld) sidebarOld.remove();
  if (settingsCard) settingsCard.style.display = isCompany ? '' : 'none';
}

function _waSupportButtonHtml(label) {
  label = label || 'واتساب الدعم';
  return '<button type="button" class="subscription-wa-btn" onclick="contactSuperAdmin()" title="تواصل عبر واتساب">' +
    '<i class="fa-brands fa-whatsapp"></i> ' + label + '</button>';
}

function getNotificationScopeId() {
  if (saasCurrentUser) {
    if (saasCurrentUser.role === 'super_admin') return 'super';
    if (saasCurrentUser.company_id != null) return parseInt(saasCurrentUser.company_id, 10);
  }
  if (typeof currentUser !== 'undefined' && currentUser === 'emp') {
    var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
    if (emp && emp.company_id != null) return parseInt(emp.company_id, 10);
  }
  if (typeof getActiveStorageCompanyId === 'function') {
    var activeCid = getActiveStorageCompanyId();
    if (activeCid) return activeCid;
  }
  return null;
}

function notificationBelongsToScope(entry, scope) {
  if (!entry || scope == null) return false;
  if (scope === 'super') {
    return entry.companyId === 'super' || entry.scope === 'super';
  }
  var cid = entry.companyId != null ? parseInt(entry.companyId, 10) : NaN;
  if (!cid || isNaN(cid)) return false;
  return cid === parseInt(scope, 10);
}

function filterNotificationsForCurrentTenant() {
  ensureNotifStores();
  var scope = getNotificationScopeId();
  if (scope == null) return;
  appSettings.activityLog = (appSettings.activityLog || []).filter(function (x) {
    return notificationBelongsToScope(x, scope);
  });
  if (scope === 'super') {
    appSettings.employeeNotifications = [];
  } else {
    appSettings.employeeNotifications = (appSettings.employeeNotifications || []).filter(function (x) {
      var cid = x.companyId != null ? parseInt(x.companyId, 10) : NaN;
      if (!cid || isNaN(cid)) return false;
      return cid === parseInt(scope, 10);
    });
  }
}

function ensureNotifStores() {
  if (!Array.isArray(appSettings.activityLog)) appSettings.activityLog = [];
  if (!Array.isArray(appSettings.employeeNotifications)) appSettings.employeeNotifications = [];
}

function getActorInfo() {
  if (currentUser === 'emp') {
    var emp = getLoggedInEmp();
    return { name: emp ? emp.name : 'موظف', role: 'employee', type: 'employee', id: emp ? emp.id : null };
  }
  if (saasCurrentUser) {
    return {
      name: saasCurrentUser.display_name || saasCurrentUser.username || 'مستخدم',
      role: saasCurrentUser.role || 'company_admin',
      type: 'admin',
      id: saasCurrentUser.id || null
    };
  }
  return { name: 'المسؤول', role: 'company_admin', type: 'admin', id: null };
}

function activityRelatesToEmployee(log, emp) {
  if (!log || !emp) return false;
  var name = String(emp.name || '').trim();
  var empIdStr = String(emp.id);
  if (log.meta && log.meta.empId != null && String(log.meta.empId) === empIdStr) return true;
  if (log.meta && log.meta.targetEmpId != null && String(log.meta.targetEmpId) === empIdStr) return true;
  if (log.targetName && name && String(log.targetName).trim() === name) return true;
  if (log.actorName && name && String(log.actorName).trim() === name) return true;
  if (log.details && name && String(log.details).indexOf(name) >= 0) return true;
  return false;
}

function auditRowToActivityLog(row) {
  if (!row) return null;
  return {
    id: 'audit_' + (row.id != null ? row.id : Date.now()),
    ts: row.created_at || new Date().toISOString(),
    action: row.action || 'unknown',
    category: row.category || '',
    actorName: row.actor_name || row.actorName || '',
    actorRole: row.actor_role || row.actorRole || '',
    details: row.details || '',
    targetName: row.target_name || row.targetName || '',
    meta: row.meta || {},
    read: false,
    companyId: 'super',
    scope: 'super'
  };
}

async function syncSuperAdminNotificationsBeforeOpen() {
  if (!saasCurrentUser || saasCurrentUser.role !== 'super_admin') return;
  if (typeof sb_superListAuditLogs !== 'function') return;
  try {
    var res = await sb_superListAuditLogs(200);
    if (!res || res.ok === false || !Array.isArray(res.logs)) return;
    ensureNotifStores();
    var remoteEntries = res.logs.map(auditRowToActivityLog).filter(Boolean);
    var byId = {};
    (appSettings.activityLog || []).forEach(function (x) {
      if (x && x.id) byId[x.id] = x;
    });
    remoteEntries.forEach(function (entry) {
      if (!entry || !entry.id) return;
      if (byId[entry.id]) {
        byId[entry.id] = Object.assign({}, byId[entry.id], entry, {
          read: byId[entry.id].read === true || entry.read === true
        });
      } else {
        byId[entry.id] = entry;
      }
    });
    appSettings.activityLog = Object.keys(byId).map(function (id) { return byId[id]; })
      .sort(function (a, b) {
        return new Date(b.ts || 0).getTime() - new Date(a.ts || 0).getTime();
      }).slice(0, 500);
    if (typeof sb_getSuperAdminPrefs === 'function') {
      var prefs = await sb_getSuperAdminPrefs();
      if (prefs && prefs.activity_log) {
        try {
          var cloudLog = JSON.parse(prefs.activity_log) || [];
          var readMap = {};
          cloudLog.forEach(function (x) { if (x && x.id) readMap[x.id] = x.read === true; });
          (appSettings.activityLog || []).forEach(function (x) {
            if (x && x.id && readMap[x.id]) x.read = true;
          });
        } catch (e) {}
      }
    }
    filterNotificationsForCurrentTenant();
  } catch (e) {
    console.warn('syncSuperAdminNotificationsBeforeOpen:', e);
  }
}

function activityLogToNotification(log) {
  var visual = notifActionIcon(log.action);
  var actionLabel = NOTIF_ACTION_LABELS[log.action] || log.action;
  var categoryLabel = NOTIF_CATEGORY_LABELS[log.category] || log.category;
  return {
    id: log.id,
    store: 'activity',
    icon: visual.icon,
    ico: visual.ico,
    title: actionLabel + ' — ' + categoryLabel,
    body: log.details,
    actor: log.actorName,
    action: log.action,
    ts: log.ts,
    datetime: formatNotifDateTime(log.ts),
    time: formatNotifTime(log.ts),
    unread: !log.read
  };
}

function logActivity(action, category, details, extra) {
  ensureNotifStores();
  var actor = getActorInfo();
  var scope = getNotificationScopeId();
  extra = extra || {};
  var entry = {
    id: 'act_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7),
    ts: new Date().toISOString(),
    action: action,
    category: category,
    actorName: actor.name,
    actorRole: actor.role,
    actorId: actor.id,
    details: details,
    targetName: extra.targetName || '',
    meta: Object.assign({ actorId: actor.id, actorRole: actor.role }, extra),
    read: false,
    companyId: scope === 'super' ? 'super' : scope,
    scope: scope === 'super' ? 'super' : 'company'
  };
  appSettings.activityLog.unshift(entry);
  if (saasCurrentUser && saasCurrentUser.role === 'super_admin') {
    if (appSettings.activityLog.length > 150) appSettings.activityLog.length = 150;
  } else if (appSettings.activityLog.length > 500) {
    appSettings.activityLog.length = 500;
  }
  if (!extra.deferSave && typeof saveData === 'function') saveData();
  if (!extra.skipPersistSchedule && typeof schedulePersistNotifications === 'function') schedulePersistNotifications();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
  if (document.getElementById('page-notifications') &&
      document.getElementById('page-notifications').classList.contains('active') &&
      typeof buildNotifications === 'function') {
    buildNotifications();
  }
  var cloudAuditCategories = ['employees', 'salaries', 'finance', 'users_permissions', 'settings', 'auth', 'system', 'payroll', 'backup'];
  if (typeof sb_recordClientAudit === 'function' && cloudAuditCategories.indexOf(category) >= 0 && !extra.skipCloudAudit) {
    sb_recordClientAudit({
      action: action,
      category: category,
      details: details,
      target_name: extra.targetName || '',
      entity_type: category,
      entity_id: extra.empId != null ? String(extra.empId) : (extra.targetEmpId != null ? String(extra.targetEmpId) : '')
    });
  }
  return entry;
}

function notifyEmployeeFinance(empId, financeType, action, amount, note, financeItemId) {
  ensureNotifStores();
  var actor = getActorInfo();
  var emp = employees.find(function(e) { return e.id === empId; });
  var entry = {
    id: 'empn_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7),
    ts: new Date().toISOString(),
    empId: empId,
    empName: emp ? emp.name : '',
    financeType: financeType,
    action: action,
    amount: exactMoneyValue(amount, 0),
    note: note || '',
    actorName: actor.name,
    financeItemId: financeItemId || null,
    read: false,
    companyId: getNotificationScopeId() === 'super' ? null : getNotificationScopeId()
  };
  appSettings.employeeNotifications.unshift(entry);
  if (appSettings.employeeNotifications.length > 300) appSettings.employeeNotifications.length = 300;
  saveData();
  if (typeof sb_addEmployeeNotification === 'function') {
    var formatted = formatEmployeeFinanceNotificationBody({ financeType: financeType, action: action, amount: amount, note: note });
    sb_addEmployeeNotification(empId, formatted.title, formatted.body, financeType || 'finance', entry.id)
      .catch(function (e) { console.warn('sb_addEmployeeNotification finance:', e); });
  }
  if (typeof schedulePersistNotifications === 'function') schedulePersistNotifications();
  if (currentUser === 'emp' && String(window.loggedInEmpId || '') === String(empId) && typeof renderEmployeeFinanceNotificationsRail === 'function') {
    renderEmployeeFinanceNotificationsRail();
  }
  return entry;
}

function formatNotifTime(ts) {
  if (!ts) return '—';
  var d = new Date(ts);
  if (isNaN(d.getTime())) return String(ts);
  var now = new Date();
  var diffMs = now - d;
  if (diffMs < 60000) return 'الآن';
  if (diffMs < 3600000) return Math.floor(diffMs / 60000) + ' د';
  if (diffMs < 86400000) return Math.floor(diffMs / 3600000) + ' س';
  if (diffMs < 172800000) return 'أمس';
  return d.toLocaleDateString('ar-IQ', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function formatNotifDateTime(ts) {
  if (!ts) return { date: '—', time: '—', full: '—', dayKey: '', relative: '—' };
  var d = new Date(ts);
  if (isNaN(d.getTime())) return { date: String(ts), time: '', full: String(ts), dayKey: '', relative: String(ts) };
  var pad = function (n) { return String(n).padStart(2, '0'); };
  var dayKey = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  var date = d.toLocaleDateString('ar-IQ', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  var time = d.toLocaleTimeString('ar-IQ', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  return { date: date, time: time, full: date + ' — ' + time, dayKey: dayKey, relative: formatNotifTime(ts) };
}

// المرحلة 4 — اسم اليوم العربي من تاريخ YYYY-MM-DD (اشتقاق تلقائي، عرض فقط)
function arabicDayNameFromDate(dateStr) {
  if (!dateStr) return '';
  var d = new Date(String(dateStr).slice(0, 10) + 'T12:00:00');
  if (isNaN(d.getTime())) return '';
  return d.toLocaleDateString('ar-IQ', { weekday: 'long' });
}

function formatNotifDayLabel(dayKey) {
  if (!dayKey) return 'بدون تاريخ';
  var d = new Date(dayKey + 'T12:00:00');
  if (isNaN(d.getTime())) return dayKey;
  var today = new Date();
  var todayKey = today.getFullYear() + '-' + String(today.getMonth() + 1).padStart(2, '0') + '-' + String(today.getDate()).padStart(2, '0');
  var y = new Date(today); y.setDate(y.getDate() - 1);
  var yKey = y.getFullYear() + '-' + String(y.getMonth() + 1).padStart(2, '0') + '-' + String(y.getDate()).padStart(2, '0');
  if (dayKey === todayKey) return 'اليوم';
  if (dayKey === yKey) return 'أمس';
  return d.toLocaleDateString('ar-IQ', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
}

function notifActionIcon(action) {
  var map = {
    add: { icon: 'success', ico: 'fa-plus-circle' },
    edit: { icon: 'info', ico: 'fa-edit' },
    delete: { icon: 'danger', ico: 'fa-trash' },
    download: { icon: 'info', ico: 'fa-download' },
    export: { icon: 'info', ico: 'fa-file-export' },
    pay: { icon: 'success', ico: 'fa-money-bill-wave' },
    issue: { icon: 'success', ico: 'fa-file-invoice-dollar' },
    checkin: { icon: 'success', ico: 'fa-sign-in-alt' },
    checkout: { icon: 'warning', ico: 'fa-sign-out-alt' },
    login: { icon: 'info', ico: 'fa-user-check' },
    logout: { icon: 'warning', ico: 'fa-sign-out-alt' },
    backup: { icon: 'info', ico: 'fa-database' },
    import: { icon: 'info', ico: 'fa-file-import' },
    reset: { icon: 'danger', ico: 'fa-exclamation-triangle' },
    applied: { icon: 'warning', ico: 'fa-check-double' }
  };
  return map[action] || { icon: 'info', ico: 'fa-bell' };
}

function financeNotifIcon(type) {
  if (type === 'bonus') return { icon: 'success', ico: 'fa-gift' };
  if (type === 'loan') return { icon: 'warning', ico: 'fa-hand-holding-usd' };
  if (type === 'salary') return { icon: 'success', ico: 'fa-money-check-alt' };
  return { icon: 'danger', ico: 'fa-minus-circle' };
}

function updateNotifBadges() {
  generateNotifications();
  var unreadCount = notifications.filter(function(n) { return n.unread; }).length;
  var navBadge = document.querySelector('#nav-notifications .nav-badge');
  if (navBadge) {
    if (unreadCount > 0) navBadge.textContent = unreadCount;
    else navBadge.remove();
  } else if (unreadCount > 0) {
    var navItem = document.getElementById('nav-notifications');
    if (navItem) {
      var b = document.createElement('span');
      b.className = 'nav-badge';
      b.textContent = unreadCount;
      navItem.appendChild(b);
    }
  }
  var topDot = document.querySelector('.topbar-notif .notif-dot');
  if (topDot) {
    if (unreadCount > 0) {
      topDot.textContent = unreadCount > 99 ? '99+' : String(unreadCount);
      topDot.style.display = 'flex';
    } else {
      topDot.textContent = '';
      topDot.style.display = 'none';
    }
  }

  // شارة الإجازات في التنقل (للإجازات المعلّقة في السحابة)
  if (typeof buildLeaveBadge === 'function') buildLeaveBadge();

  // شارة الإشعارات غير المقروءة للموظف في بوابة الموظف
  if (currentUser === 'emp') {
    var loggedEmp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
    if (loggedEmp && typeof countEmpLeaveUnread === 'function') {
      var empUnread = countEmpLeaveUnread(loggedEmp.id);
      var empNotifBadge = document.getElementById('emp-leave-notif-badge');
      if (empNotifBadge) {
        if (empUnread > 0) {
          empNotifBadge.textContent = String(empUnread);
          empNotifBadge.style.display = '';
        } else {
          empNotifBadge.textContent = '';
          empNotifBadge.style.display = 'none';
        }
      }
    }
  }
}

async function syncEmployeeNotificationsBeforeOpen() {
  var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
  if (!emp) return;
  if (typeof loadEmpNotifsFromSupabase === 'function') {
    await loadEmpNotifsFromSupabase(emp.id);
  }
}

function markCurrentEmployeeNotificationsRead(options) {
  options = options || {};
  if (currentUser !== 'emp') return;
  ensureNotifStores();
  var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
  if (!emp) return;
  var sid = String(emp.id);
  var changed = false;
  appSettings.activityLog.forEach(function (x) {
    if (!activityRelatesToEmployee(x, emp)) return;
    if (x.read !== true) {
      x.read = true;
      changed = true;
    }
  });
  appSettings.employeeNotifications.forEach(function (x) {
    if (!x || String(x.empId) !== sid) return;
    if (x.read !== true || x.unread !== false) {
      x.read = true;
      x.unread = false;
      changed = true;
      if (x.type === 'leave' && x.id && typeof sb_markEmpNotifRead === 'function') {
        sb_markEmpNotifRead(x.id).catch(function(e){ console.warn('markEmpNotifRead:', e); });
      }
    }
  });
  if (!changed) return;
  window.__basmaLocalNotifAt = Date.now();
  if (typeof saveData === 'function') saveData();
  if (!options.silent && typeof schedulePersistNotifications === 'function') schedulePersistNotifications();
  updateNotifBadges();
  if (typeof buildEmployeeLeaveNotifs === 'function') buildEmployeeLeaveNotifs(emp.id);
  if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
}

function formatEmployeeFinanceNotificationBody(n) {
  if (!n) return { title: 'إشعار', body: '' };
  if (n.title && n.body) return { title: n.title, body: n.body };
  var typeLabel = NOTIF_FINANCE_LABELS[n.financeType] || n.financeType || 'إشعار';
  var action = n.action || '';
  var amount = exactMoneyValue(n.amount, 0);
  var note = String(n.note || '').trim();
  var actionLabel = NOTIF_ACTION_LABELS[action] || action || '';

  if (action === 'delete') {
    if (note) return { title: typeLabel, body: note };
    if (amount > 0) return { title: typeLabel, body: 'تم حذف ' + typeLabel + ' بقيمة ' + amount.toLocaleString() + ' IQD' };
    return { title: typeLabel, body: 'تم حذف ' + typeLabel };
  }
  if (action === 'add') {
    var addBody = amount > 0 ? ('تمت إضافة ' + typeLabel + ' بقيمة ' + amount.toLocaleString() + ' IQD') : ('تمت إضافة ' + typeLabel);
    if (note) addBody += ' — ' + note;
    return { title: typeLabel, body: addBody };
  }
  if (action === 'edit') {
    var editBody = amount > 0 ? ('تم تعديل ' + typeLabel + ' إلى ' + amount.toLocaleString() + ' IQD') : ('تم تعديل ' + typeLabel);
    if (note) editBody += ' — ' + note;
    return { title: typeLabel, body: editBody };
  }
  if (action === 'checkin' || action === 'checkout') {
    return { title: actionLabel || typeLabel, body: note || actionLabel || typeLabel };
  }
  var body = actionLabel ? (actionLabel + ' ' + typeLabel) : typeLabel;
  if (amount > 0) body += ' بقيمة ' + amount.toLocaleString() + ' IQD';
  if (note) body += ' — ' + note;
  return { title: typeLabel, body: body };
}

function employeeNotificationText(n) {
  if (!n) return { title: 'إشعار', body: '' };
  if (n.title && n.body) return { title: n.title, body: n.body || n.note || '' };
  if (n.financeType || n.action) return formatEmployeeFinanceNotificationBody(n);
  var typeLabel = NOTIF_FINANCE_LABELS[n.financeType] || n.financeType || 'إشعار';
  var actionLabel = NOTIF_ACTION_LABELS[n.action] || n.action || '';
  var body = actionLabel ? (actionLabel + ' ' + typeLabel) : typeLabel;
  var amount = exactMoneyValue(n.amount, 0);
  if (amount > 0) body += ' بقيمة ' + amount.toLocaleString() + ' IQD';
  if (n.note) body += ' — ' + n.note;
  return { title: typeLabel, body: body };
}

function dismissEmployeeNotification(notifId) {
  ensureNotifStores();
  var target = (appSettings.employeeNotifications || []).find(function (x) {
    return x && (String(x.id) === String(notifId) || String(x._remoteId || '') === String(notifId) || employeeNotificationKey(x) === String(notifId));
  });
  if (target && typeof markEmployeeFinanceRailDismissed === 'function') markEmployeeFinanceRailDismissed(target);
  if (!target && notifId) {
    var store = employeeRailDismissStore();
    store[String(notifId)] = '*';
    persistEmployeeRailDismissStore();
  }
  var targetKey = employeeNotificationKey(target) || '';
  var targetSig = employeeNotificationSignature(target) || '';
  var changed = false;
  (appSettings.employeeNotifications || []).forEach(function (n) {
    if (!n) return;
    var same = (targetKey && employeeNotificationKey(n) === targetKey) ||
      (targetSig && employeeNotificationSignature(n) === targetSig) ||
      String(n.id) === String(notifId) ||
      String(n._remoteId || '') === String(notifId) ||
      employeeNotificationKey(n) === String(notifId);
    if (!same) return;
    if (n.read !== true || n.unread !== false) {
      n.read = true;
      n.unread = false;
      changed = true;
    }
  });
  if (changed) {
    window.__basmaLocalNotifAt = Date.now();
    if (typeof saveData === 'function') saveData();
    if (target && typeof sb_markEmpNotifRead === 'function') {
      sb_markEmpNotifRead(target._remoteId || target.id).catch(function (e) { console.warn('dismissEmployeeNotification:', e); });
    }
    if (typeof schedulePersistNotifications === 'function') schedulePersistNotifications();
  }
  renderEmployeeFinanceNotificationsRail();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
  if (typeof buildNotifications === 'function' && document.getElementById('page-notifications')?.classList.contains('active')) buildNotifications();
}

function employeeNotifRailStamp(notif) {
  if (!notif) return '';
  return String(notif.ts != null ? notif.ts : (notif.created_at || notif.id || ''));
}

function employeeRailDismissStore() {
  window.__basmaDismissedFinanceRail = window.__basmaDismissedFinanceRail || {};
  try {
    var raw = sessionStorage.getItem('basma_dismissed_emp_finance_rail');
    if (raw) {
      var parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        Object.assign(window.__basmaDismissedFinanceRail, parsed);
      }
    }
  } catch (e) { /* ignore */ }
  return window.__basmaDismissedFinanceRail;
}

function persistEmployeeRailDismissStore() {
  try {
    sessionStorage.setItem('basma_dismissed_emp_finance_rail', JSON.stringify(window.__basmaDismissedFinanceRail || {}));
  } catch (e) { /* ignore */ }
}

function markEmployeeFinanceRailDismissed(notif) {
  if (!notif || notif.id == null) return;
  var store = employeeRailDismissStore();
  var stamp = employeeNotifRailStamp(notif) || String(Date.now());
  store[String(notif.id)] = stamp;
  if (notif._remoteId != null) store[String(notif._remoteId)] = stamp;
  var key = typeof employeeNotificationKey === 'function' ? employeeNotificationKey(notif) : '';
  if (key) store[key] = stamp;
  persistEmployeeRailDismissStore();
}

function isEmployeeFinanceRailDismissed(notif) {
  if (!notif || notif.id == null) return false;
  var store = employeeRailDismissStore();
  var stamp = employeeNotifRailStamp(notif);
  if (!stamp) return false;
  var key = typeof employeeNotificationKey === 'function' ? employeeNotificationKey(notif) : '';
  return store[String(notif.id)] === '*' || store[String(notif.id)] === stamp ||
    (notif._remoteId != null && (store[String(notif._remoteId)] === '*' || store[String(notif._remoteId)] === stamp)) ||
    (key && (store[key] === '*' || store[key] === stamp));
}

function getLoggedInEmployeeCompanyId() {
  var sess = window.__basmaEmpSession;
  if (sess && sess.companyId != null) {
    var sid = parseInt(sess.companyId, 10);
    if (sid > 0) return sid;
  }
  var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
  if (emp && emp.company_id != null) {
    var cid = parseInt(emp.company_id, 10);
    if (cid > 0) return cid;
  }
  return null;
}

var _empFinanceRailRenderSig = '';

function renderEmployeeFinanceNotificationsRail() {
  var rail = document.getElementById('employee-finance-notifications-rail');
  if (!rail) return;
  if (currentUser !== 'emp') {
    rail.innerHTML = '';
    rail.style.display = 'none';
    _empFinanceRailRenderSig = '';
    return;
  }
  ensureNotifStores();
  var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
  if (!emp) {
    rail.innerHTML = '';
    rail.style.display = 'none';
    _empFinanceRailRenderSig = '';
    return;
  }
  var sid = String(emp.id);
  var empCid = getLoggedInEmployeeCompanyId();
  var items = dedupeEmployeeNotifications((appSettings.employeeNotifications || []).filter(function (n) {
    if (!n || String(n.empId) !== sid) return false;
    if (empCid && n.companyId != null && parseInt(n.companyId, 10) !== empCid) return false;
    if (isEmployeeFinanceRailDismissed(n)) return false;
    var unread = n.unread !== undefined ? !!n.unread : !n.read;
    if (!unread) return false;
    return !!(n.financeType || n.type === 'leave' || n.title || n.body);
  })).slice(0, 3);
  var sig = items.map(function (n) {
    return String(n.id || n._remoteId || '') + ':' + employeeNotifRailStamp(n);
  }).join('|');
  if (!items.length) {
    if (_empFinanceRailRenderSig !== '' || rail.innerHTML) {
      rail.innerHTML = '';
      rail.style.display = 'none';
      _empFinanceRailRenderSig = '';
    }
    return;
  }
  if (sig === _empFinanceRailRenderSig && rail.innerHTML) return;
  _empFinanceRailRenderSig = sig;
  rail.style.display = '';
  rail.innerHTML = items.map(function (n) {
    var visual = n.type === 'leave' || n.financeType === 'leave' || n.financeType === 'absence'
      ? { icon: n.financeType === 'absence' ? 'danger' : 'warning', ico: n.ico || 'fa-calendar-alt' }
      : financeNotifIcon(n.financeType);
    var text = employeeNotificationText(n);
    return '<div class="platform-announcement employee-finance-alert ' + esc(visual.icon) + '">' +
      '<div class="platform-announcement-icon"><i class="fa ' + esc(visual.ico) + '"></i></div>' +
      '<div class="platform-announcement-body">' +
        '<div class="platform-announcement-title">' + esc(text.title) + '</div>' +
        '<div class="platform-announcement-message">' + esc(text.body) + '</div>' +
      '</div>' +
      '<button type="button" class="platform-announcement-close" data-emp-notif-id="' + escAttr(String(n.id || n._remoteId || employeeNotificationKey(n) || '')) + '" title="إغلاق"><i class="fa fa-times"></i></button>' +
    '</div>';
  }).join('');
  rail.querySelectorAll('[data-emp-notif-id]').forEach(function (btn) {
    safeAddEvent(btn, 'click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      dismissEmployeeNotification(btn.getAttribute('data-emp-notif-id') || '');
    });
  });
}
window.renderEmployeeFinanceNotificationsRail = renderEmployeeFinanceNotificationsRail;
window.dismissEmployeeNotification = dismissEmployeeNotification;
window.dismissEmployeeFinanceRailNotification = dismissEmployeeNotification;

/* =========================================================================
 * إشعارات البثّ للموظفين (Broadcast Notices)
 * رسالة يحددها المسؤول تظهر لجميع الموظفين مع زر إغلاق، وتتكرر تلقائياً
 * حسب مدة زمنية (دقيقة/ساعة/يوم). تُخزّن ضمن appSettings.broadcastNotices
 * وتُزامن كباقي الإعدادات (نفس نمط الحركات المالية).
 * ========================================================================= */

function broadcastNoticesArr() {
  if (!Array.isArray(appSettings.broadcastNotices)) appSettings.broadcastNotices = [];
  return appSettings.broadcastNotices;
}

function normalizeBroadcastNotice(n) {
  n = n || {};
  // وحدة التكرار (كل كم يظهر الإشعار من جديد بعد إغلاقه)
  var repeatUnitRaw = n.repeatUnit != null ? n.repeatUnit : n.intervalUnit;
  var repeatUnit = (repeatUnitRaw === 'minute' || repeatUnitRaw === 'hour' || repeatUnitRaw === 'day') ? repeatUnitRaw : 'hour';
  var repeatValue = parseInt(n.repeatValue != null ? n.repeatValue : n.intervalValue, 10);
  if (!Number.isFinite(repeatValue) || repeatValue < 0) repeatValue = 0;
  // عدد الأيام التي يبقى الإشعار فعّالاً/متكرراً خلالها (0 = بدون حد زمني)
  var durationDays = parseInt(n.durationDays, 10);
  if (!Number.isFinite(durationDays) || durationDays < 0) durationDays = 0;
  var nowIso = new Date().toISOString();
  return {
    id: n.id || ('bc_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7)),
    message: String(n.message || '').slice(0, 1000),
    durationDays: durationDays,
    repeatValue: repeatValue,
    repeatUnit: repeatUnit,
    active: n.active !== false,
    createdAt: n.createdAt || nowIso,
    updatedAt: n.updatedAt || nowIso
  };
}

// صياغة عربية دقيقة لمعدّل التكرار: كل ساعة / كل ساعتين / كل 3 ساعات / كل 15 ساعة ...
function broadcastRepeatPhrase(value, unit) {
  var n = parseInt(value, 10);
  if (!Number.isFinite(n) || n <= 0) return 'مرة واحدة فقط (بدون تكرار)';
  var forms = {
    minute: { one: 'كل دقيقة', two: 'كل دقيقتين', few: 'دقائق', many: 'دقيقة' },
    hour: { one: 'كل ساعة', two: 'كل ساعتين', few: 'ساعات', many: 'ساعة' },
    day: { one: 'كل يوم', two: 'كل يومين', few: 'أيام', many: 'يوماً' }
  };
  var f = forms[unit] || forms.hour;
  if (n === 1) return f.one;
  if (n === 2) return f.two;
  if (n >= 3 && n <= 10) return 'كل ' + n + ' ' + f.few;
  return 'كل ' + n + ' ' + f.many;
}

// صياغة عربية لعدد الأيام: يوم واحد / يومين / 3 أيام / 15 يوماً
function arabicDaysCount(value) {
  var n = parseInt(value, 10);
  if (!Number.isFinite(n) || n <= 0) return '';
  if (n === 1) return 'يوم واحد';
  if (n === 2) return 'يومين';
  if (n >= 3 && n <= 10) return n + ' أيام';
  return n + ' يوماً';
}

// ملخّص كامل للإشعار: "يظهر كل ساعة لمدة 5 أيام" أو "... بدون حد زمني"
function broadcastSummaryPhrase(n) {
  var repeat = (parseInt(n && n.repeatValue, 10) > 0)
    ? ('يظهر ' + broadcastRepeatPhrase(n.repeatValue, n.repeatUnit))
    : 'يظهر مرة واحدة فقط';
  var days = parseInt(n && n.durationDays, 10);
  var span = (Number.isFinite(days) && days > 0) ? ('لمدة ' + arabicDaysCount(days)) : 'بدون حد زمني (دائم)';
  return repeat + ' — ' + span;
}

// مدة التكرار بالميلي ثانية (كل كم يعاد الإظهار بعد الإغلاق)
function broadcastRepeatMs(n) {
  var v = parseInt(n && n.repeatValue, 10);
  if (!Number.isFinite(v) || v <= 0) return 0;
  var per = n.repeatUnit === 'minute' ? 60000 : n.repeatUnit === 'day' ? 86400000 : 3600000;
  return v * per;
}

// نهاية نافذة صلاحية الإشعار بالإبوك (Infinity إذا كان دائماً)
function broadcastWindowEndMs(n) {
  var days = parseInt(n && n.durationDays, 10);
  if (!Number.isFinite(days) || days <= 0) return Infinity;
  var base = new Date(n.updatedAt || n.createdAt || Date.now()).getTime();
  if (!Number.isFinite(base)) base = Date.now();
  return base + days * 86400000;
}

async function saveBroadcastNoticesSettings(message) {
  appSettings.broadcastNotices = broadcastNoticesArr().map(normalizeBroadcastNotice);
  if (typeof logActivity === 'function') logActivity('edit', 'settings', message || 'تعديل إشعارات البث للموظفين', { deferSave: true });
  var cloud = await commitAppSettingsToCloud({ pauseMs: 30000, resumeMs: 15000 });
  return cloud || { ok: false };
}

async function openBroadcastNoticeForm(id) {
  if (!requireActionPermission('settings', 'edit')) return;
  var current = broadcastNoticesArr().find(function (n) { return n.id === id; }) || null;
  var curDays = current ? parseInt(current.durationDays, 10) : 1;
  if (!Number.isFinite(curDays) || curDays < 0) curDays = 1;
  var curRepeat = current ? parseInt(current.repeatValue, 10) : 1;
  if (!Number.isFinite(curRepeat) || curRepeat < 0) curRepeat = 1;
  var curUnit = current ? current.repeatUnit : 'hour';
  var fieldWrap = 'style="text-align:right;padding:12px 14px;margin:0 0 12px;border:1px solid var(--border);border-radius:12px;background:rgba(255,255,255,0.03)"';
  var numStyle = 'style="width:96px;margin:0;text-align:center;font-size:16px;font-weight:700"';
  var html = '<div style="text-align:right;direction:rtl">' +
    // نص الرسالة
    '<div ' + fieldWrap + '>' +
      '<label class="setting-label" style="display:block;margin-bottom:4px;font-weight:700"><i class="fa fa-comment-dots" style="margin-left:6px;color:#dd6b20"></i> نص الرسالة</label>' +
      '<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;line-height:1.6">الرسالة التي ستظهر لجميع الموظفين داخل تطبيقهم.</div>' +
      '<textarea id="bc-message" class="swal2-textarea" style="width:100%;margin:0;min-height:88px;box-sizing:border-box" placeholder="اكتب نص الإشعار هنا...">' + esc(current ? current.message : '') + '</textarea>' +
    '</div>' +
    // عدد الأيام (نافذة الصلاحية)
    '<div ' + fieldWrap + '>' +
      '<label class="setting-label" style="display:block;margin-bottom:4px;font-weight:700"><i class="fa fa-calendar-days" style="margin-left:6px;color:#dd6b20"></i> عدد الأيام</label>' +
      '<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;line-height:1.6">عدد الأيام التي يبقى الإشعار يتكرر خلالها. مثال: 5 = يظل يظهر لمدة 5 أيام ثم يتوقف. اكتب 0 لجعله دائماً بلا حد زمني.</div>' +
      '<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">' +
        '<input id="bc-duration-days" type="number" min="0" max="365" step="1" class="swal2-input" ' + numStyle + ' value="' + esc(curDays) + '">' +
        '<span style="font-size:14px;color:var(--text-muted)">يوم</span>' +
      '</div>' +
    '</div>' +
    // وقت التكرار
    '<div ' + fieldWrap + '>' +
      '<label class="setting-label" style="display:block;margin-bottom:4px;font-weight:700"><i class="fa fa-repeat" style="margin-left:6px;color:#dd6b20"></i> وقت التكرار</label>' +
      '<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;line-height:1.6">كل كم من الوقت يظهر الإشعار من جديد بعد أن يغلقه الموظف. مثال: كل ساعة. اكتب 0 لعرضه مرة واحدة فقط دون تكرار.</div>' +
      '<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">' +
        '<span style="font-size:14px;color:var(--text-muted)">يتكرّر كل</span>' +
        '<input id="bc-repeat-value" type="number" min="0" max="999" step="1" class="swal2-input" ' + numStyle + ' value="' + esc(curRepeat) + '">' +
        '<select id="bc-repeat-unit" class="swal2-select" style="width:120px;margin:0">' +
          '<option value="minute"' + (curUnit === 'minute' ? ' selected' : '') + '>دقيقة</option>' +
          '<option value="hour"' + (curUnit === 'hour' ? ' selected' : '') + '>ساعة</option>' +
          '<option value="day"' + (curUnit === 'day' ? ' selected' : '') + '>يوم</option>' +
        '</select>' +
      '</div>' +
      '<div id="bc-interval-preview" style="margin-top:10px;padding:8px 12px;border-radius:8px;background:rgba(221,107,32,0.14);color:#f6ad55;font-weight:700;font-size:13px;text-align:center"></div>' +
    '</div>' +
    // الحالة
    '<label style="display:flex;align-items:center;gap:8px;cursor:pointer;padding:10px 14px;border:1px solid var(--border);border-radius:12px;background:rgba(255,255,255,0.03)"><input id="bc-active" type="checkbox"' + (!current || current.active !== false ? ' checked' : '') + '> <span style="font-weight:700">مُفعّل — يظهر للموظفين الآن</span></label>' +
    '</div>';
  var res = await Swal.fire({
    title: current ? 'تعديل الإشعار' : 'إشعار جديد للموظفين',
    html: html,
    width: 480,
    showCancelButton: true,
    confirmButtonText: 'حفظ',
    cancelButtonText: 'إلغاء',
    focusConfirm: false,
    didOpen: function () {
      var daysEl = document.getElementById('bc-duration-days');
      var repEl = document.getElementById('bc-repeat-value');
      var unitEl = document.getElementById('bc-repeat-unit');
      var preview = document.getElementById('bc-interval-preview');
      function updatePreview() {
        if (!preview) return;
        preview.textContent = '\u2192 ' + broadcastSummaryPhrase({
          repeatValue: parseInt(repEl && repEl.value, 10),
          repeatUnit: (unitEl && unitEl.value) || 'hour',
          durationDays: parseInt(daysEl && daysEl.value, 10)
        });
      }
      if (daysEl) daysEl.addEventListener('input', updatePreview);
      if (repEl) repEl.addEventListener('input', updatePreview);
      if (unitEl) unitEl.addEventListener('change', updatePreview);
      updatePreview();
    },
    preConfirm: function () {
      var message = (document.getElementById('bc-message')?.value || '').trim();
      var days = parseInt(document.getElementById('bc-duration-days')?.value, 10);
      var rep = parseInt(document.getElementById('bc-repeat-value')?.value, 10);
      var unit = document.getElementById('bc-repeat-unit')?.value || 'hour';
      var active = !!(document.getElementById('bc-active') && document.getElementById('bc-active').checked);
      if (!message) return Swal.showValidationMessage('اكتب نص الرسالة');
      if (!Number.isFinite(days) || days < 0) days = 0;
      if (days > 365) return Swal.showValidationMessage('أقصى عدد للأيام هو 365');
      if (!Number.isFinite(rep) || rep < 0) rep = 0;
      if (rep > 999) return Swal.showValidationMessage('أقصى قيمة لوقت التكرار هي 999');
      return { message: message, durationDays: days, repeatValue: rep, repeatUnit: unit, active: active };
    },
    ...swalTheme()
  });
  if (!res.isConfirmed || !res.value) return;
  var nowIso = new Date().toISOString();
  var notice = normalizeBroadcastNotice({
    id: current ? current.id : null,
    message: res.value.message,
    durationDays: res.value.durationDays,
    repeatValue: res.value.repeatValue,
    repeatUnit: res.value.repeatUnit,
    active: res.value.active,
    createdAt: current ? current.createdAt : nowIso,
    updatedAt: nowIso
  });
  var next = broadcastNoticesArr().filter(function (n) { return n.id !== notice.id; });
  next.unshift(notice);
  appSettings.broadcastNotices = next;
  var cloud = await saveBroadcastNoticesSettings((current ? 'تعديل' : 'إضافة') + ' إشعار بث للموظفين');
  renderBroadcastNoticesList();
  Swal.fire({
    icon: cloud.ok ? 'success' : 'error',
    title: cloud.ok ? 'تم الحفظ' : 'تعذّر الحفظ في السحابة',
    text: cloud.ok ? 'سيظهر الإشعار لجميع الموظفين.' : 'لم يُحفظ الإشعار في Supabase. أعد تسجيل الدخول كمسؤول ثم احفظ مرة أخرى.',
    timer: cloud.ok ? 2200 : undefined,
    showConfirmButton: !cloud.ok,
    ...swalTheme()
  });
}

async function toggleBroadcastNoticeActive(id) {
  if (!requireActionPermission('settings', 'edit')) return;
  var current = broadcastNoticesArr().find(function (n) { return n.id === id; });
  if (!current) return;
  current.active = current.active === false;
  current.updatedAt = new Date().toISOString();
  renderBroadcastNoticesList();
  await saveBroadcastNoticesSettings((current.active ? 'تفعيل' : 'إيقاف') + ' إشعار بث للموظفين');
}

async function deleteBroadcastNotice(id) {
  if (!requireActionPermission('settings', 'edit')) return;
  var current = broadcastNoticesArr().find(function (n) { return n.id === id; });
  if (!current) return;
  var res = await Swal.fire({ icon: 'warning', title: 'حذف الإشعار؟', text: current.message, showCancelButton: true, confirmButtonText: 'حذف', cancelButtonText: 'إلغاء', ...swalTheme() });
  if (!res.isConfirmed) return;
  appSettings.broadcastNotices = broadcastNoticesArr().filter(function (n) { return n.id !== id; });
  renderBroadcastNoticesList();
  var cloud = await saveBroadcastNoticesSettings('حذف إشعار بث للموظفين');
  Swal.fire({ icon: cloud.ok ? 'success' : 'error', title: cloud.ok ? 'تم الحذف' : 'تعذّر الحذف من السحابة', timer: cloud.ok ? 1600 : undefined, showConfirmButton: !cloud.ok, ...swalTheme() });
}

function renderBroadcastNoticesList() {
  var wrap = document.getElementById('broadcast-notices-list');
  if (!wrap) return;
  var list = broadcastNoticesArr().map(normalizeBroadcastNotice);
  appSettings.broadcastNotices = list;
  if (!list.length) {
    wrap.innerHTML = '<div class="settings-hint" style="padding:10px;border:1px dashed var(--border);border-radius:10px">لا توجد إشعارات محفوظة حالياً.</div>';
    return;
  }
  wrap.innerHTML = list.map(function (n) {
    var repeatText = broadcastSummaryPhrase(n);
    var statusColor = n.active !== false ? '#68d391' : '#fc8181';
    var statusText = n.active !== false ? 'مُفعّل' : 'موقوف';
    return '<div style="display:flex;gap:8px;align-items:center;justify-content:space-between;padding:10px;margin-top:8px;border:1px solid var(--border);border-radius:10px;background:rgba(255,255,255,0.03)">' +
      '<div style="line-height:1.7;flex:1;min-width:0"><b style="display:block;word-break:break-word">' + esc(n.message) + '</b>' +
      '<div style="font-size:12px;color:var(--text-muted)">' + esc(repeatText) + ' — <span style="color:' + statusColor + ';font-weight:700">' + statusText + '</span></div></div>' +
      '<div style="display:flex;gap:6px;flex-wrap:wrap">' +
      '<button type="button" class="btn-sm" data-perm="settings.edit" onclick="toggleBroadcastNoticeActive(\'' + esc(n.id) + '\')" title="' + (n.active !== false ? 'إيقاف' : 'تفعيل') + '"><i class="fa ' + (n.active !== false ? 'fa-toggle-on' : 'fa-toggle-off') + '"></i></button>' +
      '<button type="button" class="btn-sm btn-primary" data-perm="settings.edit" onclick="openBroadcastNoticeForm(\'' + esc(n.id) + '\')" title="تعديل"><i class="fa fa-edit"></i></button>' +
      '<button type="button" class="btn-sm btn-danger" data-perm="settings.edit" onclick="deleteBroadcastNotice(\'' + esc(n.id) + '\')" title="حذف"><i class="fa fa-trash"></i></button></div>' +
      '</div>';
  }).join('');
  if (typeof applyPermissionUi === 'function') applyPermissionUi();
}

function broadcastDismissStoreKey() {
  var cid = typeof getLoggedInEmployeeCompanyId === 'function' ? getLoggedInEmployeeCompanyId() : null;
  return 'basma_emp_broadcast_dismiss_' + (cid || 'x');
}

function broadcastDismissStore() {
  try {
    if (window.BasmaStorage && typeof BasmaStorage.safeGet === 'function') {
      var v = BasmaStorage.safeGet(broadcastDismissStoreKey(), true);
      if (v && typeof v === 'object') return v;
      return {};
    }
    var raw = localStorage.getItem(broadcastDismissStoreKey());
    var parsed = raw ? JSON.parse(raw) : {};
    return (parsed && typeof parsed === 'object') ? parsed : {};
  } catch (e) { return {}; }
}

function persistBroadcastDismissStore(store) {
  try {
    if (window.BasmaStorage && typeof BasmaStorage.safeSet === 'function') {
      BasmaStorage.safeSet(broadcastDismissStoreKey(), store || {});
    } else {
      localStorage.setItem(broadcastDismissStoreKey(), JSON.stringify(store || {}));
    }
  } catch (e) { /* ignore */ }
}

function isBroadcastDismissed(notice) {
  if (!notice || notice.id == null) return false;
  var rec = broadcastDismissStore()[String(notice.id)];
  if (!rec) return false;
  // إذا عدّل المسؤول الإشعار (تغيّر updatedAt) نعيد إظهاره
  if (rec.stamp && notice.updatedAt && rec.stamp !== notice.updatedAt) return false;
  var until = parseInt(rec.until, 10);
  if (!Number.isFinite(until)) return false;
  return Date.now() < until;
}

function dismissBroadcastNotice(id) {
  var notice = broadcastNoticesArr().find(function (n) { return String(n.id) === String(id); });
  var store = broadcastDismissStore();
  var ms = notice ? broadcastRepeatMs(notice) : 0;
  var until = ms > 0 ? (Date.now() + ms) : Number.MAX_SAFE_INTEGER;
  store[String(id)] = { until: until, stamp: notice ? notice.updatedAt : '' };
  persistBroadcastDismissStore(store);
  renderEmployeeBroadcastRail();
}

var _empBroadcastRailSig = '';

function renderEmployeeBroadcastRail() {
  var rail = document.getElementById('employee-broadcast-rail');
  if (!rail) return;
  if (currentUser !== 'emp') {
    rail.innerHTML = '';
    rail.style.display = 'none';
    _empBroadcastRailSig = '';
    return;
  }
  var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
  if (!emp) {
    rail.innerHTML = '';
    rail.style.display = 'none';
    _empBroadcastRailSig = '';
    return;
  }
  var nowMs = Date.now();
  var items = broadcastNoticesArr().filter(function (n) {
    if (!n || n.active === false || !String(n.message || '').trim()) return false;
    if (nowMs >= broadcastWindowEndMs(n)) return false;
    return !isBroadcastDismissed(n);
  });
  var sig = items.map(function (n) { return String(n.id) + ':' + (n.updatedAt || ''); }).join('|');
  if (!items.length) {
    if (_empBroadcastRailSig !== '' || rail.innerHTML) {
      rail.innerHTML = '';
      rail.style.display = 'none';
      _empBroadcastRailSig = '';
    }
    return;
  }
  if (sig === _empBroadcastRailSig && rail.innerHTML) return;
  _empBroadcastRailSig = sig;
  rail.style.display = 'flex';
  rail.innerHTML = items.map(function (n) {
    return '<div class="platform-ann-card">' +
      '<button type="button" class="platform-ann-close" data-broadcast-id="' + escAttr(String(n.id)) + '" aria-label="إغلاق">&times;</button>' +
      '<div class="platform-ann-head"><i class="fa fa-bullhorn"></i><span>إشعار من الإدارة</span></div>' +
      '<div class="platform-ann-text">' + esc(n.message) + '</div>' +
    '</div>';
  }).join('');
  rail.querySelectorAll('.platform-ann-close').forEach(function (btn) {
    safeAddEvent(btn, 'click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      dismissBroadcastNotice(btn.getAttribute('data-broadcast-id') || '');
    });
  });
}

window.openBroadcastNoticeForm = openBroadcastNoticeForm;
window.toggleBroadcastNoticeActive = toggleBroadcastNoticeActive;
window.deleteBroadcastNotice = deleteBroadcastNotice;
window.renderBroadcastNoticesList = renderBroadcastNoticesList;
window.renderEmployeeBroadcastRail = renderEmployeeBroadcastRail;
window.dismissBroadcastNotice = dismissBroadcastNotice;

function seedEmployeeFinanceNotificationsIfNeeded(emp) {
  if (!emp) return;
  ensureNotifStores();
  if (appSettings.employeeNotifications.some(function(n) { return n.empId === emp.id; })) return;
  var seeded = false;
  financeItems().forEach(function(item) {
    if (item.empId !== emp.id || !NOTIF_FINANCE_LABELS[item.type] || item.status === 'ملغي') return;
    appSettings.employeeNotifications.push({
      id: 'empn_seed_' + item.id,
      ts: item.createdAt || new Date().toISOString(),
      empId: emp.id,
      empName: emp.name,
      financeType: item.type,
      action: 'add',
      amount: exactMoneyValue(item.amount, 0),
      note: item.note || '',
      actorName: 'الإدارة',
      financeItemId: item.id,
      read: true
    });
    seeded = true;
  });
  if (seeded) saveData();
}

function generateNotifications() {
  ensureNotifStores();
  notifications = [];
  var seenIds = {};

  if (currentUser === 'admin') {
    var adminScope = getNotificationScopeId();
    appSettings.activityLog.forEach(function(log) {
      if (!notificationBelongsToScope(log, adminScope)) return;
      if (seenIds[log.id]) return;
      seenIds[log.id] = true;
      notifications.push(activityLogToNotification(log));
    });
  } else {
    var emp = getLoggedInEmp();
    if (emp) {
      seedEmployeeFinanceNotificationsIfNeeded(emp);
      var _empIdStr = String(emp.id);
      var empScope = getNotificationScopeId();
      appSettings.activityLog.forEach(function(log) {
        if (empScope != null && !notificationBelongsToScope(log, empScope)) return;
        if (!activityRelatesToEmployee(log, emp)) return;
        if (seenIds[log.id]) return;
        seenIds[log.id] = true;
        notifications.push(activityLogToNotification(log));
      });
      appSettings.employeeNotifications
        .filter(function(n) { return n && String(n.empId) === _empIdStr; })
        .forEach(function(n) {
          if (seenIds[n.id]) return;
          seenIds[n.id] = true;
          var _isUnread = n.unread !== undefined ? !!n.unread : !n.read;
          // إشعارات الإجازات — تنسيق مختلف عن الإشعارات المالية
          if (n.type === 'leave' || n.financeType === 'leave' || n.financeType === 'absence') {
            notifications.push({
              id: n.id,
              store: 'employee',
              icon: n.icon || (n.financeType === 'absence' ? 'danger' : 'warning'),
              ico:  n.ico  || 'fa-calendar-alt',
              title: n.title || (NOTIF_FINANCE_LABELS[n.financeType] || 'إجازة'),
              body:  n.body  || n.note || '',
              ts: n.ts,
              datetime: formatNotifDateTime(n.ts),
              time: formatNotifTime(n.ts),
              unread: _isUnread
            });
            return;
          }
          // إشعارات مالية (الشكل القديم)
          var visual = financeNotifIcon(n.financeType);
          var finText = formatEmployeeFinanceNotificationBody(n);
          notifications.push({
            id: n.id,
            store: 'employee',
            icon: visual.icon,
            ico: visual.ico,
            title: finText.title,
            body: finText.body + (n.actorName ? ' (بواسطة: ' + n.actorName + ')' : ''),
            ts: n.ts,
            datetime: formatNotifDateTime(n.ts),
            time: formatNotifTime(n.ts),
            unread: _isUnread
          });
        });
    }
  }
  notifications.sort(function(a, b) {
    return new Date(b.ts || 0).getTime() - new Date(a.ts || 0).getTime();
  });
  if (typeof injectSubscriptionAlerts === 'function') injectSubscriptionAlerts();
  if (typeof injectPlatformAnnouncements === 'function') injectPlatformAnnouncements();
}

function buildNotifications() {
  generateNotifications();
  var list = document.getElementById('notif-list');
  var header = document.getElementById('notif-page-header');
  var titleEl = document.getElementById('notif-page-title');
  var subtitleEl = document.getElementById('notif-page-subtitle');
  var clearBtn = document.getElementById('btn-clear-activity');
  var readAllBtn = document.getElementById('btn-notif-read-all');
  var exportBtn = document.getElementById('btn-notif-export');
  if (!list) return;

  if (header) {
    header.style.display = '';
    if (currentUser === 'admin') {
      var total = notifications.length;
      var unread = notifications.filter(function (n) { return n.unread; }).length;
      if (titleEl) titleEl.textContent = 'أرشيف النشاطات والإشعارات';
      if (subtitleEl) subtitleEl.textContent = total + ' عملية مؤرشفة' + (unread ? (' • ' + unread + ' غير مقروء') : '');
      if (clearBtn) clearBtn.style.display = hasActionPermission('notifications', 'clear_all') ? '' : 'none';
      if (readAllBtn) readAllBtn.style.display = hasActionPermission('notifications', 'view') ? '' : 'none';
      if (exportBtn) exportBtn.style.display = hasActionPermission('notifications', 'export') ? '' : 'none';
    } else {
      if (titleEl) titleEl.textContent = 'إشعاراتي';
      if (subtitleEl) subtitleEl.textContent = 'حركاتك، حضورك، والإشعارات المالية والإجازات';
      if (clearBtn) clearBtn.style.display = 'none';
      if (readAllBtn) readAllBtn.style.display = '';
      if (exportBtn) exportBtn.style.display = 'none';
    }
  }
  if (typeof applyPermissionUi === 'function') applyPermissionUi(header || document);

  if (notifications.length === 0) {
    list.innerHTML = '<div style="text-align:center;padding:48px;color:var(--text-muted)"><i class="fa fa-bell-slash" style="font-size:48px;opacity:0.3;display:block;margin-bottom:12px"></i>' +
      (currentUser === 'admin' ? 'لا توجد حركات مسجلة بعد' : 'لا توجد إشعارات لك حالياً') + '</div>';
    updateNotifBadges();
    return;
  }

  var groups = {};
  var groupOrder = [];
  notifications.forEach(function (n, i) {
    n._idx = i;
    var dk = (n.datetime && n.datetime.dayKey) || 'unknown';
    if (!groups[dk]) { groups[dk] = []; groupOrder.push(dk); }
    groups[dk].push(n);
  });

  list.innerHTML = groupOrder.map(function (dayKey) {
    var items = groups[dayKey];
    var dayLabel = formatNotifDayLabel(dayKey);
    var dayHtml = items.map(function (n) {
      var actionKey = esc(n.action || '');
      var actionBadge = n.action ? '<span class="notif-action-badge ' + actionKey + '">' + esc(NOTIF_ACTION_LABELS[n.action] || n.action) + '</span>' : '';
      var actorLine = n.actor ? '<span class="notif-actor"><i class="fa fa-user"></i> ' + esc(n.actor) + '</span>' : '';
      var dt = n.datetime || formatNotifDateTime(n.ts);
      return '<div class="notif-item ' + (n.unread ? 'unread' : 'read') + '" data-notif-id="' + esc(n.id) + '" data-notif-store="' + esc(n.store || '') + '" onclick="markRead(this,' + n._idx + ')">' +
        '<div class="notif-icon ' + esc(n.icon) + '"><i class="fa ' + esc(n.ico) + '"></i></div>' +
      '<div class="notif-body">' +
          '<h4>' + esc(n.title) + '</h4>' +
          '<p>' + esc(n.body) + '</p>' +
          '<div class="notif-datetime"><i class="fa fa-calendar-alt"></i> ' + esc(dt.date) + ' <span class="notif-time-sep">|</span> <i class="fa fa-clock"></i> ' + esc(dt.time) + '</div>' +
        (actorLine || actionBadge ? '<div class="notif-meta">' + actionBadge + actorLine + '</div>' : '') +
      '</div>' +
        '<div class="notif-side">' +
          '<span class="notif-relative">' + esc(n.time || dt.relative) + '</span>' +
          (n.unread ? '<span class="notif-unread-dot" title="غير مقروء"></span>' : '<span class="notif-read-tag"><i class="fa fa-check"></i></span>') +
        '</div>' +
      '</div>';
    }).join('');
    return '<div class="notif-day-group">' +
      '<div class="notif-day-header"><i class="fa fa-folder-open"></i> ' + esc(dayLabel) + ' <span class="notif-day-count">' + items.length + '</span></div>' +
      dayHtml +
    '</div>';
  }).join('');
  updateNotifBadges();
}

async function exportNotificationsArchive() {
  if (!requireActionPermission('notifications', 'export')) return;
  ensureNotifStores();
  var rows = [];
  if (currentUser === 'admin') {
    rows = (appSettings.activityLog || []).filter(function (log) {
      return notificationBelongsToScope(log, getNotificationScopeId());
    }).map(function (log) {
      var dt = formatNotifDateTime(log.ts);
      return {
        التاريخ: dt.date,
        الوقت: dt.time,
        العملية: NOTIF_ACTION_LABELS[log.action] || log.action,
        القسم: NOTIF_CATEGORY_LABELS[log.category] || log.category,
        التفاصيل: log.details,
        المنفّذ: log.actorName,
        مقروء: log.read ? 'نعم' : 'لا'
      };
    });
  } else {
    var emp = getLoggedInEmp();
    rows = (appSettings.employeeNotifications || []).filter(function (n) { return emp && n.empId === emp.id; }).map(function (n) {
      var dt = formatNotifDateTime(n.ts);
      return {
        التاريخ: dt.date,
        الوقت: dt.time,
        النوع: NOTIF_FINANCE_LABELS[n.financeType] || n.financeType,
        العملية: NOTIF_ACTION_LABELS[n.action] || n.action,
        المبلغ: exactMoneyValue(n.amount, 0),
        ملاحظة: n.note || '',
        مقروء: n.read ? 'نعم' : 'لا'
      };
    });
  }
  if (!rows.length) {
    Swal.fire({ icon: 'info', title: 'لا توجد بيانات', text: 'لا توجد إشعارات للتصدير', ...swalTheme() });
    return;
  }
  try {
    if (typeof ensureXlsxLoaded === 'function') await ensureXlsxLoaded();
  } catch (e) { /* fall through to JSON export */ }
  if (typeof XLSX !== 'undefined') {
    var ws = XLSX.utils.json_to_sheet(rows);
    var wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'الأرشيف');
    XLSX.writeFile(wb, 'basma-notifications-archive-' + new Date().toISOString().slice(0, 10) + '.xlsx');
    logActivity('export', 'notifications', 'تصدير أرشيف الإشعارات (' + rows.length + ' سجل)', { deferSave: true });
    await persistNotificationsNow();
    return;
  }
  var blob = new Blob([JSON.stringify(rows, null, 2)], { type: 'application/json;charset=utf-8' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'basma-notifications-' + Date.now() + '.json';
  a.click();
}

function markRead(el, idx) {
  if (el) el.classList.remove('unread');
  var id = el && el.getAttribute('data-notif-id');
  var store = el && el.getAttribute('data-notif-store');
  ensureNotifStores();
  if (id && store === 'activity') {
    var log = appSettings.activityLog.find(function(x) { return x.id === id; });
    if (log) log.read = true;
  } else if (id && store === 'employee') {
    var en = appSettings.employeeNotifications.find(function(x) { return x.id === id; });
    if (en) {
      en.read = true;
      en.unread = false;
      if (en.type === 'leave' && typeof sb_markEmpNotifRead === 'function') {
        sb_markEmpNotifRead(en.id).catch(function(e){ console.warn('markEmpNotifRead:', e); });
      }
    }
  } else if (id && store === 'platform') {
    var annId = String(id).replace(/^platform_ann_/, '');
    if (typeof dismissPlatformAnnouncement === 'function') dismissPlatformAnnouncement(annId);
  } else if (idx !== undefined && notifications[idx]) {
    notifications[idx].unread = false;
  }
  window.__basmaLocalNotifAt = Date.now();
  schedulePersistNotifications();
  updateNotifBadges();
  if (currentUser === 'emp' && typeof renderEmployeeFinanceNotificationsRail === 'function') {
    renderEmployeeFinanceNotificationsRail();
  }
}

async function markAllNotificationsRead() {
  if (currentUser === 'admin' && !hasActionPermission('notifications', 'view')) return;
  ensureNotifStores();
  if (currentUser === 'admin') {
    var scope = getNotificationScopeId();
    appSettings.activityLog.forEach(function(x) {
      if (notificationBelongsToScope(x, scope)) x.read = true;
    });
  } else {
    var emp = getLoggedInEmp();
    if (emp) {
      var sid = String(emp.id);
      appSettings.activityLog.forEach(function(x) {
        if (activityRelatesToEmployee(x, emp)) x.read = true;
      });
      appSettings.employeeNotifications.forEach(function(x) {
        if (x && String(x.empId) === sid) {
          x.read = true;
          x.unread = false;
        }
      });
    }
  }
  var result = await persistNotificationsNow({ skipMerge: true });
  if (!result.ok) {
    Swal.fire({ icon: 'warning', title: 'تنبيه', text: notifCloudSaveErrorMessage(result.reason), ...swalTheme() });
  }
  buildNotifications();
  if (currentUser === 'emp' && typeof renderEmployeeFinanceNotificationsRail === 'function') {
    renderEmployeeFinanceNotificationsRail();
  }
}

async function clearAdminActivityLog() {
  if (!requireActionPermission('notifications', 'clear_all')) return;
  const { isConfirmed } = await Swal.fire({
    title: 'مسح سجل النشاطات',
    text: 'هل تريد حذف جميع الإشعارات/الحركات المسجلة؟',
    icon: 'warning',
    showCancelButton: true,
    confirmButtonText: 'نعم، حذف الكل',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#e53e3e'
  });
  if (!isConfirmed) return;
  var scope = getNotificationScopeId();
  appSettings.activityLog = (appSettings.activityLog || []).filter(function (x) {
    return !notificationBelongsToScope(x, scope);
  });
  window.__basmaNotifClearedAt = Date.now();
  var result = await persistNotificationsNow({ skipMerge: true, pauseMs: 20000, resumeMs: 10000 });
  buildNotifications();
  if (!result.ok) {
    Swal.fire({ icon: 'warning', title: 'تنبيه', text: notifCloudSaveErrorMessage(result.reason), ...swalTheme() });
    return;
  }
  Swal.fire({ icon: 'success', title: 'تم حذف جميع الإشعارات', timer: 1500, showConfirmButton: false, ...swalTheme() });
}

// ======= REPORTS =======
function buildReports() {
  const el = document.getElementById('top-emp-list');
  if (!el) return;
  var theme = (typeof BasmaCharts !== 'undefined' && BasmaCharts.getChartThemeColors)
    ? BasmaCharts.getChartThemeColors()
    : { listDivider: 'rgba(255,255,255,0.05)' };
  var topRows = (typeof BasmaCharts !== 'undefined' && BasmaCharts.computeTopCommittedEmployees)
    ? BasmaCharts.computeTopCommittedEmployees(employees, attData, 5)
    : [...employees].sort((a, b) => b.days - a.days).slice(0, 5).map(function (e) {
      return { emp: e, presentDays: e.days || 0, lateCount: 0, progress: Math.round((e.days || 0) / 25 * 100) };
    });
  if (!topRows.length) {
    el.innerHTML = '<div style="text-align:center;padding:32px;color:var(--text-muted)">لا توجد بيانات موظفين بعد</div>';
    buildReportCharts();
    return;
  }
  el.innerHTML = topRows.map(function (row, i) {
    var e = row.emp;
    const avatarSafe = sanitizeAvatarUrl(e.avatarUrl);
    var lateNote = row.lateCount > 0
      ? '<div style="font-size:11px;color:#f6e05e;margin-top:2px">تأخير: ' + row.lateCount + ' مرة</div>'
      : '';
    return `
    <div style="display:flex;align-items:center;gap:16px;padding:12px 0;border-bottom:1px solid ${theme.listDivider}">
      <div style="width:32px;height:32px;border-radius:50%;background:linear-gradient(135deg,var(--accent),var(--primary-light));display:flex;align-items:center;justify-content:center;font-weight:700;font-size:13px;flex-shrink:0;color:#071525">${i + 1}</div>
      <div class="emp-avatar ${esc(e.avatarClass)}" style="width:40px;height:40px;border-radius:12px;font-size:16px;position:relative;overflow:hidden">${avatarSafe ? '<img src="'+avatarSafe+'" style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;border-radius:12px">' : esc(e.avatar)}</div>
      <div style="flex:1">
        <div style="font-weight:700;font-size:14px">${esc(e.name)}</div>
        <div style="font-size:12px;color:var(--text-muted)">${esc(e.dept)}</div>
        ${lateNote}
        <div class="progress-bar" style="margin-top:6px"><div class="progress-fill" style="width:${row.progress}%;background:var(--accent)"></div></div>
      </div>
      <div style="text-align:left">
        <div style="font-size:20px;font-weight:800;color:var(--accent)">${row.presentDays}</div>
        <div style="font-size:11px;color:var(--text-muted)">يوم هذا الشهر</div>
      </div>
    </div>
  `;
  }).join('');
  buildReportCharts();
}

function buildReportCharts() {
  if (typeof BasmaCharts === 'undefined') return;
  BasmaCharts.buildMonthChart(attData, employees);
  BasmaCharts.buildDeptChart(attData, employees);
}

// ======= EMPLOYEE PORTAL DYNAMIC =======
function getLoggedInEmp() {
  if (!window.loggedInEmpId) return null;
  var empId = parseInt(window.loggedInEmpId, 10);
  var emp = (employees || []).find(function (e) { return e && e.id === empId; });
  if (emp) return emp;
  return null;
}

function showEmpPortalStatusBanner(message, tone) {
  var homePage = document.getElementById('page-emp-home');
  if (!homePage || currentUser !== 'emp') return;
  var bannerId = 'emp-portal-status-banner';
  var existing = document.getElementById(bannerId);
  if (!message) {
    if (existing) existing.remove();
    window.__basmaEmpPortalBannerMsg = '';
    return;
  }
  if (existing && existing.textContent === message && window.__basmaEmpPortalBannerMsg === message) return;
  window.__basmaEmpPortalBannerMsg = message;
  var palette = {
    info: { bg: 'rgba(99,179,237,0.12)', border: 'rgba(99,179,237,0.35)', color: '#63b3ed' },
    warn: { bg: 'rgba(252,211,77,0.12)', border: 'rgba(252,211,77,0.35)', color: '#f6e05e' },
    error: { bg: 'rgba(252,129,129,0.12)', border: 'rgba(252,129,129,0.35)', color: '#fc8181' },
    success: { bg: 'rgba(104,211,145,0.12)', border: 'rgba(104,211,145,0.35)', color: '#68d391' }
  };
  var p = palette[tone] || palette.info;
  if (!existing) {
    existing = document.createElement('div');
    existing.id = bannerId;
    homePage.insertBefore(existing, homePage.firstChild);
  }
  existing.style.cssText = 'margin:12px 16px;padding:14px 16px;border-radius:12px;background:' + p.bg + ';border:1px solid ' + p.border + ';color:' + p.color + ';font-weight:700;text-align:center;line-height:1.7';
  existing.textContent = message;
}

async function ensureLoggedInEmployeeLoaded() {
  var empId = parseInt(window.loggedInEmpId, 10);
  if (!empId) return null;
  var emp = getLoggedInEmp();
  if (emp) return emp;
  var cached = typeof getCachedEmployeeSessionIds === 'function'
    ? getCachedEmployeeSessionIds()
    : { empId: empId, slot: 1, companyId: 0 };
  var fp = typeof getDeviceFingerprint === 'function' ? getDeviceFingerprint() : '';
  if (typeof sb_verifyEmployeeDeviceAccess === 'function') {
    try {
      var access = await withClientTimeout(
        sb_verifyEmployeeDeviceAccess(empId, { fingerprint: fp, slot: cached.slot }),
        12000,
        'employee_verify'
      );
      if (access && access.ok === true && typeof ensureEmployeeFromServerAccess === 'function') {
        emp = await ensureEmployeeFromServerAccess(empId, cached.slot, fp, access);
        if (emp) {
          upsertEmployeeIntoStore(emp);
          return emp;
        }
      }
      if (access && access.error === 'device_not_authorized') return null;
      if (access && access.error === 'employee_not_found') return null;
    } catch (e) {
      console.warn('ensureLoggedInEmployeeLoaded verify:', e);
    }
  }
  if (typeof resolveRegisteredEmployeeFromServer === 'function') {
    try {
      emp = await withClientTimeout(
        resolveRegisteredEmployeeFromServer(fp, appSettings.ipRestrict !== false),
        14000,
        'employee_resolve'
      );
      if (emp) {
        upsertEmployeeIntoStore(emp);
        window.loggedInEmpId = emp.id;
        return emp;
      }
    } catch (e) {
      console.warn('ensureLoggedInEmployeeLoaded resolve:', e);
    }
  }
  if (typeof refreshEmployeeClientProfileById === 'function') {
    try {
      emp = await withClientTimeout(
        refreshEmployeeClientProfileById(empId, { fingerprint: fp, slot: cached.slot }),
        12000,
        'employee_profile'
      );
      if (emp) {
        upsertEmployeeIntoStore(emp);
        return emp;
      }
    } catch (e) {
      console.warn('ensureLoggedInEmployeeLoaded profile:', e);
    }
  }
  return null;
}

function displayEmpLoginNotice() {
  var notice = window.__basmaEmpLoginNotice;
  if (!notice) return;
  var st = document.getElementById('emp-login-status');
  if (!st) return;
  st.innerHTML = '<span style="color:#fc8181;font-weight:700">' + esc(notice.title || 'تنبيه') + '</span><br>' +
    '<span style="font-size:12px;color:var(--text-muted)">' + esc(notice.text || '') + '</span>';
  window.__basmaEmpLoginNotice = null;
}

var _deletedEmpVerifyInFlight = false;
var _deletedEmpVerifyCooldownUntil = 0;
var _empPortalLoadInFlight = false;
var _empNotifsLoadedAt = 0;

async function verifyLoggedInEmployeeAccountStatus() {
  if (currentUser !== 'emp' || !window.loggedInEmpId) return 'active';
  var empId = parseInt(window.loggedInEmpId, 10);
  if (!empId) return 'active';
  if ((employees || []).some(function (e) { return e && e.id === empId; })) return 'active';
  if (typeof sb_fetchEmployeeClientProfile !== 'function') return 'pending';
  var cachedSlot = window.__basmaEmpSession ? (parseInt(window.__basmaEmpSession.slot || '1', 10) || 1) : 1;
  var fp = typeof getDeviceFingerprintForRpc === 'function' ? getDeviceFingerprintForRpc()
    : (typeof getDeviceFingerprint === 'function' ? getDeviceFingerprint() : '');
  var token = null;
  var localEmp = (employees || []).find(function (e) { return e && e.id === empId; });
  if (localEmp && typeof getDevice === 'function') {
    var localDev = getDevice(localEmp, cachedSlot);
    if (localDev && localDev.token) token = localDev.token;
  }
  try {
    var prof = await sb_fetchEmployeeClientProfile(empId, { fingerprint: fp, token: token, slot: cachedSlot });
    if (prof && prof.ok === true) {
      if (typeof refreshEmployeeClientProfileById === 'function') {
        await refreshEmployeeClientProfileById(empId, { fingerprint: fp, token: token, slot: cachedSlot });
      }
      if (typeof clearEmployeeDeletedLocally === 'function') clearEmployeeDeletedLocally(empId);
      return 'active';
    }
    if (prof && prof.error === 'device_not_authorized' && (token || fp)) return 'relink';
    if (prof && prof.error === 'employee_not_found') return 'deleted';
    if (!prof) return 'pending';
  } catch (e) {
    console.warn('verifyLoggedInEmployeeAccountStatus:', e);
    return 'pending';
  }
  return 'pending';
}

function forceEmployeePortalLogout(messageTitle, messageText) {
  window.__basmaLoggingOut = true;
  window.__basmaEmpLoginNotice = { title: messageTitle, text: messageText };
  clearRegisteredDeviceCache();
  window.loggedInEmpId = null;
  currentUser = null;
  checkedIn = false;
  checkInTime = null;
  if (typeof stopEmployeePortalPolling === 'function') stopEmployeePortalPolling();
  showEmpPortalStatusBanner(null);
  showLoginPageAfterLogout();
  window.__basmaPreserveSwal = true;
  setTimeout(function () {
    window.__basmaPreserveSwal = false;
    if (typeof displayEmpLoginNotice === 'function') displayEmpLoginNotice();
    if (typeof switchLoginTab === 'function') {
      var empTab = document.querySelector('.login-tab[data-type="emp"]') ||
        Array.prototype.find.call(document.querySelectorAll('.login-tab') || [], function (t) {
          return t && t.textContent && t.textContent.indexOf('موظف') >= 0;
        });
      switchLoginTab('emp', empTab || null);
    } else if (typeof refreshEmpLoginIp === 'function') {
      refreshEmpLoginIp();
    }
    Swal.fire({
      icon: 'info',
      title: messageTitle,
      html: '<div style="font-size:14px;line-height:1.8">' + esc(messageText || '') + '</div>',
      confirmButtonText: 'حسناً',
      ...swalTheme()
    });
  }, 420);
}

// المرحلة 3 — حالة حساب الموظف (نشط/موقوف)
var SUSPENDED_MSG = 'تم إيقاف حسابك، يرجى مراجعة الإدارة.';

function isLoggedInEmployeeSuspended() {
  if (currentUser !== 'emp') return false;
  var emp = getLoggedInEmp();
  return !!(emp && emp.active === false);
}

// حارس موثوق من الخادم قبل أي إجراء حضور — يُخرج الموظف الموقوف فوراً.
// عند تعذّر الاتصال يرجع للحالة المحلية (لا يمنع الموظف النشط بلا داعٍ).
async function guardEmployeeAccountActive() {
  if (currentUser !== 'emp' || !window.loggedInEmpId) return true;
  if (typeof sb_employeeLoginGate === 'function') {
    try {
      var gate = await sb_employeeLoginGate(window.loggedInEmpId);
      if (gate && gate.active === false) {
        var emp = getLoggedInEmp();
        if (emp) emp.active = false;
        forceEmployeePortalLogout('تم إيقاف الحساب', (gate.message || SUSPENDED_MSG));
        return false;
      }
      if (gate && gate.active === true) {
        var e2 = getLoggedInEmp();
        if (e2) e2.active = true;
        return true;
      }
    } catch (e) {
      console.warn('guardEmployeeAccountActive:', e);
    }
  }
  if (isLoggedInEmployeeSuspended()) {
    forceEmployeePortalLogout('تم إيقاف الحساب', SUSPENDED_MSG);
    return false;
  }
  return true;
}

function handleDeletedLoggedEmployee() {
  if (currentUser !== 'emp' || !window.loggedInEmpId) return false;
  var empId = parseInt(window.loggedInEmpId, 10);
  if ((employees || []).some(function (e) { return e && e.id === empId; })) return false;
  if (_deletedEmpVerifyInFlight) return false;
  if (Date.now() < _deletedEmpVerifyCooldownUntil) return false;
  _deletedEmpVerifyCooldownUntil = Date.now() + 15000;
  _deletedEmpVerifyInFlight = true;
  showEmpPortalStatusBanner('جارٍ التحقق من حساب الموظف...', 'info');
  verifyLoggedInEmployeeAccountStatus().then(function (status) {
    _deletedEmpVerifyInFlight = false;
    if (status === 'active') {
      showEmpPortalStatusBanner(null);
      if (typeof buildEmpPortal === 'function') buildEmpPortal();
      return;
    }
    if (status === 'pending') {
      return ensureLoggedInEmployeeLoaded().then(function (emp) {
        if (emp) {
          showEmpPortalStatusBanner(null);
          if (typeof buildEmpPortal === 'function') buildEmpPortal();
          return;
        }
        showEmpPortalStatusBanner('تعذّر تحميل بيانات الموظف — تحقق من الإنترنت ثم حدّث الصفحة أو أعد مسح QR.', 'error');
      });
    }
    if (status === 'relink') {
      forceEmployeePortalLogout(
        'يجب إعادة ربط الجهاز',
        'تم تغيير بيانات الجهاز من لوحة الإدارة. امسح رمز QR الجديد من قائمة الموظفين ثم سجّل الدخول من هذا الهاتف.'
      );
      return;
    }
    forceEmployeePortalLogout(
      'تم حذف حساب الموظف',
      'تم حذف هذا الموظف من لوحة الإدارة، لذلك لا يمكن تسجيل الحضور من هذا الجهاز.'
    );
  }).catch(function (e) {
    _deletedEmpVerifyInFlight = false;
    console.warn('handleDeletedLoggedEmployee:', e);
    showEmpPortalStatusBanner('تعذّر الاتصال بالسحابة — تحقق من الإنترنت ثم حدّث الصفحة.', 'warn');
  });
  return false;
}

function isEmpPortalOffline() {
  if (typeof BasmaNetworkStatus !== 'undefined' && BasmaNetworkStatus.getState) {
    var st = BasmaNetworkStatus.getState();
    if (st && !st.checking && (st.quality === 'offline' || st.online === false)) return true;
  }
  return typeof BasmaCloud !== 'undefined' && BasmaCloud.isOnline && !BasmaCloud.isOnline();
}

function applyEmpPortalSubscriptionLock() {
  if (currentUser !== 'emp') return;
  var locked = typeof isEmployeePortalLocked === 'function' ? isEmployeePortalLocked() : (typeof isSubscriptionActive === 'function' && !isSubscriptionActive());
  var offline = isEmpPortalOffline();
  var homePage = document.getElementById('page-emp-home');
  var bannerId = 'emp-subscription-lock-banner';
  var existing = document.getElementById(bannerId);
  if (locked && homePage) {
    if (!existing) {
      existing = document.createElement('div');
      existing.id = bannerId;
      existing.style.cssText = 'margin:12px 16px;padding:14px 16px;border-radius:12px;background:rgba(252,129,129,0.12);border:1px solid rgba(252,129,129,0.35);color:#fc8181;font-weight:700;text-align:center;line-height:1.7';
      homePage.insertBefore(existing, homePage.firstChild);
    }
    existing.textContent = '⛔ انتهى اشتراك الشركة — لا يمكن تسجيل الحضور/الانصراف. تواصل مع الإدارة للتجديد.';
  } else if (offline) {
    if (existing) existing.remove();
    var netBanner = document.getElementById('emp-portal-status-banner');
    if (netBanner && /اتصال|إنترنت|سحابة/i.test(netBanner.textContent || '')) {
      showEmpPortalStatusBanner(null);
    }
  } else {
    if (existing) existing.remove();
    if (!document.getElementById('emp-portal-status-banner')) showEmpPortalStatusBanner(null);
  }
  var blockAttendance = locked || offline;
  document.querySelectorAll('#page-emp-home .att-btn').forEach(function (btn) {
    btn.disabled = !!blockAttendance;
    btn.style.opacity = blockAttendance ? '0.45' : '';
    btn.style.pointerEvents = blockAttendance ? 'none' : '';
    btn.title = locked
      ? 'انتهى اشتراك الشركة — تواصل مع الإدارة'
      : (offline ? 'لا يوجد اتصال بالإنترنت' : '');
  });
  if (locked) {
    var salNet = document.getElementById('emp-salary-net');
    if (salNet) salNet.textContent = '—';
    var notifBox = document.getElementById('emp-leave-notifs');
    if (notifBox) notifBox.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:8px">الإشعارات غير متاحة — الاشتراك منتهٍ</div>';
  }
}

function buildEmpPortal(options) {
  options = options || {};
  var emp = getLoggedInEmp();
  if (!emp && window.loggedInEmpId && currentUser === 'emp') {
    if (_empPortalLoadInFlight) return;
    _empPortalLoadInFlight = true;
    showEmpPortalStatusBanner('جارٍ تحميل بيانات الموظف من السحابة...', 'info');
    ensureLoggedInEmployeeLoaded().then(function (loaded) {
      if (loaded) {
        showEmpPortalStatusBanner(null);
        buildEmpPortal(options);
      } else {
        showEmpPortalStatusBanner('تعذّر تحميل حسابك — تحقق من الإنترنت أو أعد مسح QR من لوحة الإدارة.', 'error');
        handleDeletedLoggedEmployee();
      }
    }).catch(function (e) {
      console.warn('buildEmpPortal load:', e);
      showEmpPortalStatusBanner('تعذّر الاتصال بالسحابة — حاول تحديث الصفحة.', 'warn');
    }).finally(function () {
      _empPortalLoadInFlight = false;
    });
    return;
  }
  if (!emp) return;
  normalizeEmployee(emp);

  if (currentUser === 'emp' && emp.active === false) {
    forceEmployeePortalLogout('تم إيقاف الحساب', SUSPENDED_MSG);
    return;
  }

  if (!options.skipSubscriptionRefresh && currentUser === 'emp' && typeof refreshSubscriptionStatusForCurrentContext === 'function') {
    refreshSubscriptionStatusForCurrentContext()
      .catch(function (e) { console.warn('buildEmpPortal subscription refresh:', e); })
      .finally(function () {
        buildEmpPortalBody(emp);
        if (currentUser === 'emp' && !window.__basmaPortalVisitLogged) {
          window.__basmaPortalVisitLogged = true;
          logEmployeePortalEvent('portal_visit', { empId: emp.id, success: true, meta: { page: 'emp-home' } });
        }
      });
    return;
  }
  buildEmpPortalBody(emp);
  if (currentUser === 'emp' && !window.__basmaPortalVisitLogged) {
    window.__basmaPortalVisitLogged = true;
    logEmployeePortalEvent('portal_visit', { empId: emp.id, success: true, meta: { page: 'emp-home' } });
  }
}

function buildEmpPortalBody(emp) {

  if (currentUser === 'emp' && typeof refreshOfficialClosuresFromCloud === 'function') {
    refreshOfficialClosuresFromCloud().finally(function () {
      buildEmpPortalBodyInner(emp);
    });
    return;
  }
  buildEmpPortalBodyInner(emp);
}

function buildEmpPortalBodyInner(emp) {
  if (typeof syncLeavesFromSupabase === 'function') {
    syncLeavesFromSupabase({ empId: emp.id }).then(function () {
      if (typeof buildEmployeeLeaves === 'function') buildEmployeeLeaves(emp.id);
    }).catch(function (e) { console.warn('buildEmpPortal leaves:', e); });
  }
  // === EMP HOME HEADER ===
  const avatarEl = document.getElementById('emp-portal-avatar');
  const nameEl = document.getElementById('emp-portal-name');
  const roleEl = document.getElementById('emp-portal-role');
  const deptEl = document.getElementById('emp-portal-dept');
  if (avatarEl) {
    const avatarSafe = sanitizeAvatarUrl(emp.avatarUrl);
    if (avatarSafe) {
      avatarEl.innerHTML = '<img src="' + avatarSafe + '" style="width:100%;height:100%;object-fit:cover;border-radius:inherit">';
    } else {
      avatarEl.textContent = emp.avatar || pickAvatar(emp.name);
    }
  }
  if (nameEl) nameEl.textContent = emp.name;
  if (roleEl) roleEl.textContent = emp.role;
  if (deptEl) {
    deptEl.textContent = '';
    var deptIcon = document.createElement('i');
    deptIcon.className = 'fa fa-microchip';
    deptEl.appendChild(deptIcon);
    deptEl.appendChild(document.createTextNode(' ' + (emp.dept || '')));
  }
  var infoRole = document.getElementById('emp-info-role');
  var infoDept = document.getElementById('emp-info-dept');
  var infoPhone = document.getElementById('emp-info-phone');
  var infoBaseSalary = document.getElementById('emp-info-base-salary');
  if (infoRole) infoRole.textContent = emp.role || emp.job || '—';
  if (infoDept) infoDept.textContent = emp.dept || '—';
  if (infoPhone) infoPhone.textContent = emp.phone && emp.phone !== '—' ? emp.phone : '—';
  if (infoBaseSalary) infoBaseSalary.textContent = emp.salaryType === 'commission' ? 'عمولة' : (parseInt(emp.salary || 0, 10) || 0).toLocaleString();
  var modeTags = document.getElementById('emp-work-mode-tags');
  if (modeTags) {
    var tags = [];
    if (emp.remoteAttend) tags.push('<span style="font-size:12px;padding:4px 10px;border-radius:999px;background:rgba(104,211,145,0.15);color:#68d391">📍 حضور من أي مكان</span>');
    if (emp.openHours) tags.push('<span style="font-size:12px;padding:4px 10px;border-radius:999px;background:rgba(99,179,237,0.15);color:#63b3ed">🕐 دوام وقت مفتوح</span>');
    if (isOvernightShift(emp)) tags.push('<span style="font-size:12px;padding:4px 10px;border-radius:999px;background:rgba(237,137,54,0.15);color:#ed8936">🌙 دوام ليلي (' + esc(emp.checkIn || '22:00') + ' → ' + esc(emp.checkOut || '05:00') + ')</span>');
    var activeClosure = officialClosureForDate();
    if (activeClosure) {
      tags.push('<span style="font-size:12px;padding:4px 10px;border-radius:999px;background:rgba(128,90,213,0.16);color:#d6bcfa">تعطيل رسمي: ' + esc(activeClosure.title) + '</span>');
    }
    modeTags.innerHTML = tags.length ? tags.join('') : '<span style="font-size:12px;color:var(--text-muted)">الحضور يتطلب موقع الشركة — فعّل «أي مكان» من الإدارة إن لزم</span>';
  }
  var closureForButtons = officialClosureForDate();
  renderOfficialClosureEmpBanner(closureForButtons);
  bindOfficialClosureAttendanceButtons(closureForButtons);

  // === DAILY STATUS ===
  const portalRec = getEmpPortalAttendanceRecord(emp);
  const sCheckin = document.getElementById('s-checkin');
  const sCheckout = document.getElementById('s-checkout');
  const sHours = document.getElementById('s-hours');
  const sLate = document.getElementById('s-late');
  const checkinTimeEl = document.getElementById('checkin-time');
  const checkoutTimeEl = document.getElementById('checkout-time');

  if (portalRec) {
    if (sCheckin) sCheckin.textContent = portalRec.ci !== '—' ? portalRec.ci : '--:-- --';
    if (sCheckout) sCheckout.textContent = portalRec.co !== '—' ? portalRec.co : '--:-- --';
    if (sHours) sHours.textContent = formatWorkHoursDisplay(portalRec, emp);
    if (sLate) sLate.textContent = portalRec.late !== '—' ? portalRec.late + ' د' : '0 د';
    if (checkinTimeEl) checkinTimeEl.textContent = portalRec.ci !== '—' ? portalRec.ci : 'اسحب للتسجيل';
    if (checkoutTimeEl) checkoutTimeEl.textContent = portalRec.co !== '—' ? portalRec.co : 'اسحب للتسجيل';
    checkedIn = portalRec.ci !== '—' && (!portalRec.co || portalRec.co === '—');
    if (portalRec.ci !== '—') {
      const now = new Date();
      const recIso = attendanceRecordIso(portalRec) || todayIsoDate();
      const parts = portalRec.ci.match(/(\d+):(\d+)\s*(AM|PM)/i);
      if (parts) {
        let ch = parseInt(parts[1]);
        const cm = parseInt(parts[2]);
        const cap = parts[3].toUpperCase();
        if (cap === 'PM' && ch !== 12) ch += 12;
        if (cap === 'AM' && ch === 12) ch = 0;
        var recDateParts = recIso.split('-');
        checkInTime = new Date(parseInt(recDateParts[0], 10), parseInt(recDateParts[1], 10) - 1, parseInt(recDateParts[2], 10), ch, cm);
      } else {
        checkInTime = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 8, 0);
      }
    }
  } else {
    if (sCheckin) sCheckin.textContent = '--:-- --';
    if (sCheckout) sCheckout.textContent = '--:-- --';
    if (sHours) sHours.textContent = '0:00';
    if (sLate) sLate.textContent = '0 د';
    if (checkinTimeEl) checkinTimeEl.textContent = 'اضغط للتسجيل';
    if (checkoutTimeEl) checkoutTimeEl.textContent = 'اضغط للتسجيل';
    checkedIn = false;
    checkInTime = null;
  }

  // === WEEK TABLE ===
  const weekTable = document.getElementById('emp-week-table');
  if (weekTable) {
    const empAtts = typeof getEmpPortalAttendanceRows === 'function'
      ? getEmpPortalAttendanceRows(emp, { days: 60 })
      : attData.filter(function (r) { return r.empId === emp.id && isPunchAttendanceRecord(r); });
    const statusMap = { 'طبيعي': 'badge-success', 'متأخر': 'badge-warning', 'غياب': 'badge-danger', 'إضافي': 'badge-info' };
    const statusIcon = { 'طبيعي': '🟢', 'متأخر': '🟡', 'غياب': '🔴', 'إضافي': '🔵' };
    if (empAtts.length === 0) {
      weekTable.innerHTML = '<tr><td colspan="4" style="text-align:center;color:var(--text-muted)">لا توجد سجلات حضور بعد</td></tr>';
    } else {
      weekTable.innerHTML = empAtts.map(r => {
        const timeCell = r.ci === '—' ? '<span class="badge badge-danger">🔴 غياب</span>' :
          '<div class="time-slot"><span>' + esc(fmtTimeDisplay(r.ci)) + '</span><span class="time-arrow">←</span><span>' + esc(fmtTimeDisplay(r.co)) + '</span></div>';
        const statusBadge = '<span class="badge ' + escAttr(statusMap[r.status] || 'badge-success') + '">' + esc(statusIcon[r.status] || '') + ' ' + esc(r.status) + (r.late !== '—' ? ' ' + esc(r.late) : '') + '</span>';
        return '<tr><td>' + esc(r.date) + '</td><td>' + timeCell + '</td><td>' + esc(formatWorkHoursDisplay(r, emp)) + '</td><td>' + statusBadge + '</td></tr>';
      }).join('');
    }
  }

  // === SALARY PAGE ===
  const months = ['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
  const now = new Date();
  const currentMonth = months[now.getMonth()] + ' ' + now.getFullYear();
  const salaryType = emp.salaryType || 'monthly';
  const isCommission = salaryType === 'commission';
  const isBiweekly = salaryType === 'biweekly';

  // Calculate days in current half
  const dayOfMonth = now.getDate();
  const splitDay = getBiweeklySplitDay();
  const isSecondHalf = dayOfMonth > splitDay;
  const daysInHalf = isSecondHalf ? (dayOfMonth - splitDay) : dayOfMonth;
  const halfPeriodDays = isSecondHalf ? Math.max(1, getStandardMonthDays() - splitDay) : splitDay;

  const sal = calcEmpSalary(emp);
  const deduct = sal.totalDeduct;
  const financialDeduct = (sal.manualDeduct || 0) + (sal.loanDeduct || 0);
  const ot = sal.overtimeInNet ? (sal.ot || 0) : 0;
  let finalSalary = sal.final;
  let salaryDisplayLabel = 'صافي الراتب — ' + currentMonth;
  let baseDisplay = '0';
  let netDisplay = '0';
  var portalLocked = typeof isEmployeePortalLocked === 'function' && isEmployeePortalLocked();

  if (isCommission) {
    salaryDisplayLabel = 'حساب العمولة — ' + currentMonth;
    baseDisplay = 'عمولة';
    netDisplay = 'يُحسب يدوياً';
  } else if (isBiweekly) {
    salaryDisplayLabel = 'صافي الراتب — ' + currentMonth + (isSecondHalf ? ' (النصف الثاني)' : ' (النصف الأول)');
    baseDisplay = sal.baseSalary.toLocaleString();
    netDisplay = finalSalary.toLocaleString();
  } else {
    baseDisplay = sal.baseSalary.toLocaleString();
    netDisplay = finalSalary.toLocaleString();
  }

  const salaryLabel = document.getElementById('emp-salary-label');
  const salaryNet = document.getElementById('emp-salary-net');
  const salaryBase = document.getElementById('emp-salary-base');
  const salaryOt = document.getElementById('emp-salary-ot');
  const salaryOtSub = document.getElementById('emp-salary-ot-sub');
  const salaryDeduct = document.getElementById('emp-salary-deduct');
  const salaryDeductSub = document.getElementById('emp-salary-deduct-sub');
  const salaryBonuses = document.getElementById('emp-salary-bonuses');
  const salaryLoans = document.getElementById('emp-salary-loans');
  const salaryManualDeduct = document.getElementById('emp-salary-manual-deduct');
  const salaryLeaves = document.getElementById('emp-salary-leaves');
  const salaryBreakdown = document.getElementById('emp-salary-breakdown');

  if (salaryLabel) salaryLabel.textContent = portalLocked ? 'الراتب غير متاح — اشتراك منتهٍ' : salaryDisplayLabel;
  if (salaryNet) {
    salaryNet.textContent = portalLocked ? '—' : (isCommission ? 'عمولة' : netDisplay);
    applySalaryNetElementStyle(salaryNet, finalSalary, isCommission);
  }
  if (salaryBase) salaryBase.textContent = portalLocked ? '—' : baseDisplay;
  if (salaryOt) salaryOt.textContent = portalLocked ? '—' : (isCommission ? '—' : (ot > 0 ? ot.toLocaleString() : '0'));
  if (salaryOtSub) salaryOtSub.textContent = portalLocked ? 'غير متاح' : (isCommission ? 'لا يوجد' : (emp.openHours ? 'دوام مفتوح: لا إضافي تلقائي' : (ot > 0 ? ('إضافي ' + Math.floor((sal.totalOvertimeMin || 0) / 60) + 'س ' + ((sal.totalOvertimeMin || 0) % 60) + 'د — ' + (sal.overtimeInNet ? 'مضاف للصافي' : 'للتقارير فقط')) : 'لا يوجد إضافي')));
  if (salaryDeduct) salaryDeduct.textContent = portalLocked ? '—' : (isCommission ? '—' : (financialDeduct > 0 ? financialDeduct.toLocaleString() : '0'));
  if (salaryDeductSub) {
    var _deductParts = [];
    if (!isCommission) {
      if (sal.manualDeduct > 0) _deductParts.push('خصومات ' + sal.manualDeduct.toLocaleString());
      if (sal.loanDeduct > 0)   _deductParts.push('سلف ' + sal.loanDeduct.toLocaleString());
    }
    salaryDeductSub.textContent = isCommission ? 'لا يوجد'
      : (_deductParts.length > 0 ? _deductParts.join(' + ') : 'لا توجد خصومات مالية');
  }
  if (salaryBonuses) salaryBonuses.textContent = portalLocked || isCommission ? '—' : (sal.bonus > 0 ? sal.bonus.toLocaleString() : '0');
  if (salaryLoans) salaryLoans.textContent = portalLocked || isCommission ? '—' : (sal.loanDeduct > 0 ? sal.loanDeduct.toLocaleString() : '0');
  if (salaryManualDeduct) salaryManualDeduct.textContent = portalLocked || isCommission ? '—' : (sal.manualDeduct > 0 ? sal.manualDeduct.toLocaleString() : '0');
  if (salaryLeaves) {
    var leaveDaysText = sal.leaveDays || 0;
    var absentText = sal.absentDays || 0;
    salaryLeaves.textContent = portalLocked || isCommission ? '—' : (leaveDaysText + ' إجازة / ' + absentText + ' غياب');
  }
  if (salaryBreakdown) {
    if (portalLocked) {
      salaryBreakdown.innerHTML = 'تفاصيل الراتب غير متاحة — الاشتراك منتهٍ';
    } else if (isCommission) {
      salaryBreakdown.innerHTML = 'هذا الموظف بنظام العمولة، لذلك لا يتم عرض تفصيل راتب شهري تلقائي.';
    } else {
      var lines = [];
      lines.push('الراتب الأساسي: <b>' + sal.baseSalary.toLocaleString() + ' IQD</b>');
      lines.push('الصافي الحالي: ' + salaryNetInlineHtml(sal.final, false));
      if (sal.manualDeduct > 0) lines.push('خصومات مالية: <b style="color:#fc8181">' + sal.manualDeduct.toLocaleString() + ' IQD</b>');
      if (sal.loanDeduct > 0) lines.push('سلف/دفعات: <b style="color:#f6ad55">' + sal.loanDeduct.toLocaleString() + ' IQD</b>');
      if (sal.leaveDeduct > 0) lines.push('خصم إجازات: <b style="color:#f6ad55">' + sal.leaveDeduct.toLocaleString() + ' IQD</b> (' + (sal.leaveDays || 0) + ' يوم)');
      if (sal.absentDeduct > 0) lines.push('خصم غياب: <b style="color:#e53e3e">' + sal.absentDeduct.toLocaleString() + ' IQD</b> (' + (sal.absentDays || 0) + ' يوم)');
      if (sal.bonus > 0) lines.push('مكافآت: <b style="color:#68d391">' + sal.bonus.toLocaleString() + ' IQD</b>');
      salaryBreakdown.innerHTML = lines.join('<br>');
    }
  }

  // Biweekly progress indicator
  const biweeklyBar = document.getElementById('emp-biweekly-bar');
  if (biweeklyBar) {
    if (isBiweekly) {
      biweeklyBar.style.display = '';
      const progress = Math.min(100, Math.round((daysInHalf / halfPeriodDays) * 100));
      biweeklyBar.innerHTML = '<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px"><span style="font-size:12px;color:var(--text-secondary)">' + (isSecondHalf ? 'النصف الثاني' : 'النصف الأول') + ' من الشهر</span><span style="font-size:12px;font-weight:700;color:' + (progress >= 100 ? '#68d391' : '#63b3ed') + '">' + daysInHalf + '/' + halfPeriodDays + ' يوم</span></div><div style="height:8px;background:rgba(255,255,255,0.1);border-radius:4px;overflow:hidden"><div style="height:100%;width:' + progress + '%;background:' + (progress >= 100 ? 'linear-gradient(90deg,#68d391,#38a169)' : 'linear-gradient(90deg,#63b3ed,#3182ce)') + ';border-radius:4px;transition:width 0.5s"></div></div>' + (progress >= 100 ? '<div style="text-align:center;margin-top:6px;font-size:12px;color:#68d391;font-weight:700">✅ اكتمل ' + (isSecondHalf ? 'النصف الثاني' : 'النصف الأول') + ' — يستحق صرف الراتب</div>' : '');
    } else {
      biweeklyBar.style.display = 'none';
    }
  }

  // Salary History
  const salaryHistory = document.getElementById('emp-salary-history');
  const isAdmin = currentUser === 'admin';
  const addBtn = document.getElementById('emp-salary-add-btn');
  const actionsTh = document.getElementById('emp-salary-actions-th');
  if (addBtn) addBtn.style.display = isAdmin ? '' : 'none';
  if (actionsTh) actionsTh.style.display = isAdmin ? '' : 'none';

  // Initialize salaryHistoryData if not exists
  if (!emp.salaryHistoryData) emp.salaryHistoryData = [];

  // لا نولّد سجلات رواتب وهمية. سجلات الراتب يجب أن تأتي من الحضور أو من إدخال المسؤول.
  if (!emp.salaryHistoryInit && emp.salaryHistoryData.length === 0) {
    emp.salaryHistoryInit = true;
    saveData();
  }

  if (salaryHistory) {
    let histHtml = '';
    emp.salaryHistoryData.forEach((rec, idx) => {
      let statusBadge = '';
      if (rec.status === 'مدفوع') {
        statusBadge = '<span style="padding:4px 12px;border-radius:20px;font-size:12px;font-weight:700;background:rgba(104,211,145,0.15);color:#68d391;border:1px solid rgba(104,211,145,0.3)">✓ مدفوع</span>';
      } else if (rec.status === 'معلق') {
        statusBadge = '<span style="padding:4px 12px;border-radius:20px;font-size:12px;font-weight:700;background:rgba(246,224,94,0.15);color:#f6e05e;border:1px solid rgba(246,224,94,0.3)">⏳ معلق</span>';
      } else if (rec.status === 'مرفوض') {
        statusBadge = '<span style="padding:4px 12px;border-radius:20px;font-size:12px;font-weight:700;background:rgba(252,129,129,0.15);color:#fc8181;border:1px solid rgba(252,129,129,0.3)">✗ مرفوض</span>';
      } else if (rec.status === 'مُصدر') {
        statusBadge = '<span style="padding:4px 12px;border-radius:20px;font-size:12px;font-weight:700;background:rgba(104,211,145,0.15);color:#68d391;border:1px solid rgba(104,211,145,0.3)">✓ مُصدر</span>';
      } else {
        statusBadge = '<span style="padding:4px 12px;border-radius:20px;font-size:12px;font-weight:700;background:rgba(160,174,192,0.15);color:#a0aec0;border:1px solid rgba(160,174,192,0.3)">' + esc(rec.status) + '</span>';
      }
      histHtml += '<tr><td>' + esc(formatEmployeeSalaryHistoryDate(rec)) + '</td><td>' + rec.base.toLocaleString() + '</td><td>' + (rec.ot > 0 ? rec.ot.toLocaleString() : '0') + '</td><td>' + (rec.deduct > 0 ? rec.deduct.toLocaleString() : '0') + '</td><td>' + rec.net.toLocaleString() + '</td><td>' + statusBadge + '</td>';
      if (isAdmin) {
        histHtml += '<td style="white-space:nowrap">' +
          (hasActionPermission('salaries', 'edit') ? '<button class="btn-sm btn-primary" style="padding:4px 10px;font-size:12px;margin:2px" onclick="editSalaryRecord(' + idx + ')"><i class="fa fa-edit"></i></button>' : '') +
          (hasActionPermission('salaries', 'delete') ? '<button class="btn-sm btn-danger" style="padding:4px 10px;font-size:12px;margin:2px" onclick="deleteSalaryRecord(' + idx + ')"><i class="fa fa-trash"></i></button>' : '') +
          '</td>';
      }
      histHtml += '</tr>';
    });
    salaryHistory.innerHTML = histHtml || '<tr><td colspan="' + (isAdmin ? '7' : '6') + '" style="text-align:center;color:var(--text-muted)">لا يوجد سجل</td></tr>';
  }

  // === PROFILE PAGE ===
  const profileAvatar = document.getElementById('emp-profile-avatar');
  const profileAvatarImg = document.getElementById('emp-profile-avatar-img');
  const profileName = document.getElementById('emp-profile-name');
  const profilePhone = document.getElementById('emp-profile-phone');
  const profileDept = document.getElementById('emp-profile-dept');
  const profileRole = document.getElementById('emp-profile-role');
  const profileCheckin = document.getElementById('emp-profile-checkin');
  const profileCheckout = document.getElementById('emp-profile-checkout');
  if (profileAvatar) profileAvatar.textContent = emp.avatar || pickAvatar(emp.name);
  // Show uploaded avatar image if exists
  if (profileAvatarImg) {
    const avatarSafe = sanitizeAvatarUrl(emp.avatarUrl);
    if (avatarSafe) {
      profileAvatarImg.src = avatarSafe;
      profileAvatarImg.style.display = 'block';
      if (profileAvatar) profileAvatar.style.display = 'none';
    } else {
      profileAvatarImg.style.display = 'none';
      if (profileAvatar) profileAvatar.style.display = '';
    }
  }
  if (profileName) profileName.value = emp.name;
  if (profilePhone) profilePhone.value = emp.phone !== '—' ? emp.phone : '';
  if (profileDept) profileDept.value = emp.dept;
  if (profileRole) profileRole.value = emp.role;
  if (profileCheckin) profileCheckin.value = emp.checkIn || '08:00';
  if (profileCheckout) profileCheckout.value = emp.checkOut || '17:00';

  // === EMPLOYEE LEAVES & NOTIFICATIONS ===
  if (typeof buildEmployeeLeaves === 'function') buildEmployeeLeaves(emp.id);
  if (!portalLocked && typeof buildEmployeeLeaveNotifs === 'function') buildEmployeeLeaveNotifs(emp.id);
  if (!portalLocked) {
    var notifRefreshNow = Date.now();
    if (notifRefreshNow - _empNotifsLoadedAt >= 25000) {
      _empNotifsLoadedAt = notifRefreshNow;
      if (typeof loadEmpNotifsFromSupabase === 'function') {
        loadEmpNotifsFromSupabase(emp.id).catch(function () {});
      }
    }
  }
  applyEmpPortalSubscriptionLock();
  if (typeof BasmaNetworkStatus !== 'undefined') {
    if (BasmaNetworkStatus.applyUi) BasmaNetworkStatus.applyUi();
    if (BasmaNetworkStatus.probe) BasmaNetworkStatus.probe(true);
  }
  if (!portalLocked && typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
  if (!portalLocked && typeof renderEmployeeBroadcastRail === 'function') renderEmployeeBroadcastRail();
}

function changeEmpAvatar() {
  document.getElementById('emp-avatar-input')?.click();
}

function handleEmpAvatarUpload(event) {
  const emp = getLoggedInEmp();
  if (!emp) return;
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;
  if (!file.type.startsWith('image/')) {
    Swal.fire({ icon: 'error', title: 'ملف غير صالح', text: 'اختر صورة فقط', ...swalTheme() });
    return;
  }
  if (file.size > 8 * 1024 * 1024) {
    Swal.fire({ icon: 'warning', title: 'صورة كبيرة', text: 'حجم الصورة يجب أن يكون أقل من 8 ميجابايت', ...swalTheme() });
    return;
  }
  openEmpAvatarCropper(file, emp);
}

function openEmpAvatarCropper(file, emp) {
  const reader = new FileReader();
  reader.onload = function (ev) {
    const imgSrc = ev.target.result;
    Swal.fire({
      title: 'اقتصاص الصورة للملف الشخصي',
      html:
        '<div class="avatar-crop-shell">' +
          '<div id="avatar-crop-wrap" class="avatar-crop-wrap">' +
            '<img id="avatar-crop-img" class="avatar-crop-img" alt="اقتصاص">' +
            '<div class="avatar-crop-frame" aria-hidden="true"></div>' +
          '</div>' +
          '<div class="avatar-crop-hint">اسحب الصورة داخل الإطار — كبّر/صغّر بالشريط أدناه</div>' +
          '<input type="range" id="avatar-crop-zoom" class="avatar-crop-zoom" min="100" max="280" value="100">' +
        '</div>',
      confirmButtonText: 'حفظ الصورة',
      showCancelButton: true,
      cancelButtonText: 'إلغاء',
      width: 360,
      ...swalTheme(),
      didOpen: function () {
        const wrap = document.getElementById('avatar-crop-wrap');
        const img = document.getElementById('avatar-crop-img');
        const zoom = document.getElementById('avatar-crop-zoom');
        if (!wrap || !img || !zoom) return;
        const state = { x: 0, y: 0, baseScale: 1, dragging: false, startX: 0, startY: 0, originX: 0, originY: 0 };
        img.src = imgSrc;
        img.onload = function () {
          const cw = wrap.clientWidth;
          const ch = wrap.clientHeight;
          const base = Math.max(cw / img.naturalWidth, ch / img.naturalHeight);
          state.baseScale = base;
          const zoomFactor = parseInt(zoom.value, 10) / 100;
          const w = img.naturalWidth * base * zoomFactor;
          const h = img.naturalHeight * base * zoomFactor;
          state.x = (cw - w) / 2;
          state.y = (ch - h) / 2;
          applyAvatarCropTransform(img, state, zoom);
        };
        safeAddEvent(zoom, 'input', function () {
          const cw = wrap.clientWidth;
          const ch = wrap.clientHeight;
          const oldW = parseFloat(img.style.width) || img.offsetWidth;
          const oldH = parseFloat(img.style.height) || img.offsetHeight;
          const cx = cw / 2;
          const cy = ch / 2;
          const ratioX = oldW ? (cx - state.x) / oldW : 0.5;
          const ratioY = oldH ? (cy - state.y) / oldH : 0.5;
          applyAvatarCropTransform(img, state, zoom);
          const newW = parseFloat(img.style.width) || img.offsetWidth;
          const newH = parseFloat(img.style.height) || img.offsetHeight;
          state.x = cx - ratioX * newW;
          state.y = cy - ratioY * newH;
          clampAvatarCropPosition(wrap, img, state);
          img.style.left = state.x + 'px';
          img.style.top = state.y + 'px';
        });
        const onDown = function (e) {
          state.dragging = true;
          const pt = e.touches ? e.touches[0] : e;
          state.startX = pt.clientX;
          state.startY = pt.clientY;
          state.originX = state.x;
          state.originY = state.y;
          img.style.cursor = 'grabbing';
        };
        const onMove = function (e) {
          if (!state.dragging) return;
          e.preventDefault();
          const pt = e.touches ? e.touches[0] : e;
          state.x = state.originX + (pt.clientX - state.startX);
          state.y = state.originY + (pt.clientY - state.startY);
          clampAvatarCropPosition(wrap, img, state);
          img.style.left = state.x + 'px';
          img.style.top = state.y + 'px';
        };
        const onUp = function () {
          state.dragging = false;
          img.style.cursor = 'grab';
        };
        safeAddEvent(img, 'mousedown', onDown);
        safeAddEvent(img, 'touchstart', onDown, { passive: true });
        safeAddEvent(window, 'mousemove', onMove);
        safeAddEvent(window, 'touchmove', onMove, { passive: false });
        safeAddEvent(window, 'mouseup', onUp);
        safeAddEvent(window, 'touchend', onUp);
        var popup = Swal.getPopup();
        if (popup) safeAddEvent(popup, 'close', function () {
          window.removeEventListener('mousemove', onMove);
          window.removeEventListener('touchmove', onMove);
          window.removeEventListener('mouseup', onUp);
          window.removeEventListener('touchend', onUp);
        }, { once: true });
      },
      preConfirm: function () {
        const wrap = document.getElementById('avatar-crop-wrap');
        const img = document.getElementById('avatar-crop-img');
        if (!wrap || !img || !img.naturalWidth) {
          Swal.showValidationMessage('تعذّر معالجة الصورة');
          return false;
        }
        const dataUrl = cropAvatarImageToDataUrl(wrap, img);
        if (!dataUrl) {
          Swal.showValidationMessage('تعذّر اقتصاص الصورة');
          return false;
        }
        return dataUrl;
      }
    }).then(async function (result) {
      if (!result.isConfirmed || !result.value) return;
      emp.avatarUrl = result.value;
      saveData();
      var synced = false;
      if (currentUser === 'emp' && typeof sb_updateEmployeeAvatar === 'function') {
        try {
          var url = await sb_updateEmployeeAvatar(emp.id, result.value);
          synced = !!url;
          if (url) emp.avatarUrl = url;
        } catch (err) {
          console.warn('Avatar RPC sync failed:', err);
        }
      } else if (typeof sb_upsertEmployee === 'function') {
        try {
          synced = !!(await sb_upsertEmployee(emp, { requireExisting: currentUser === 'emp' }));
        } catch (err) {
          console.warn('Avatar Supabase sync failed:', err);
        }
      }
      saveData();
      buildEmpPortal();
      if (typeof buildEmployees === 'function') buildEmployees();
      Swal.fire({
        icon: synced ? 'success' : 'warning',
        title: synced ? 'تم حفظ الصورة' : 'لم يتم حفظ الصورة',
        text: synced ? 'تمت مزامنة الصورة مع لوحة المسؤول' : 'تعذّر رفع الصورة للسحابة — تحقق من الإنترنت ثم حاول مرة أخرى',
        ...swalTheme(),
        timer: synced ? 1800 : undefined,
        showConfirmButton: !synced
      });
    });
  };
  reader.readAsDataURL(file);
}

function applyAvatarCropTransform(img, state, zoom) {
  const zoomFactor = parseInt(zoom.value, 10) / 100;
  const w = img.naturalWidth * state.baseScale * zoomFactor;
  const h = img.naturalHeight * state.baseScale * zoomFactor;
  img.style.width = w + 'px';
  img.style.height = h + 'px';
  img.style.left = state.x + 'px';
  img.style.top = state.y + 'px';
}

function clampAvatarCropPosition(wrap, img, state) {
  const cw = wrap.clientWidth;
  const ch = wrap.clientHeight;
  const w = parseFloat(img.style.width) || img.offsetWidth;
  const h = parseFloat(img.style.height) || img.offsetHeight;
  if (w <= cw) state.x = (cw - w) / 2;
  else {
    if (state.x > 0) state.x = 0;
    if (state.x + w < cw) state.x = cw - w;
  }
  if (h <= ch) state.y = (ch - h) / 2;
  else {
    if (state.y > 0) state.y = 0;
    if (state.y + h < ch) state.y = ch - h;
  }
}

function cropAvatarImageToDataUrl(wrap, img) {
  const cw = wrap.clientWidth;
  const ch = wrap.clientHeight;
  const displayedW = parseFloat(img.style.width) || img.offsetWidth;
  const displayedH = parseFloat(img.style.height) || img.offsetHeight;
  const offsetX = parseFloat(img.style.left) || 0;
  const offsetY = parseFloat(img.style.top) || 0;
  if (!displayedW || !displayedH) return null;
  const srcX = Math.max(0, (-offsetX / displayedW) * img.naturalWidth);
  const srcY = Math.max(0, (-offsetY / displayedH) * img.naturalHeight);
  const srcW = Math.min(img.naturalWidth - srcX, (cw / displayedW) * img.naturalWidth);
  const srcH = Math.min(img.naturalHeight - srcY, (ch / displayedH) * img.naturalHeight);
  const out = 320;
  const canvas = document.createElement('canvas');
  canvas.width = out;
  canvas.height = out;
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;
  ctx.drawImage(img, srcX, srcY, srcW, srcH, 0, 0, out, out);
  return canvas.toDataURL('image/jpeg', 0.86);
}

let profileAdminUnlocked = false;

async function verifyAdminUnlockCredentials(username, password) {
  var u = String(username || '').trim().toLowerCase();
  var p = String(password || '');
  if (!u || !p) {
    return { ok: false, message: 'أدخل اسم المستخدم وكلمة المرور' };
  }
  if (typeof AuthApi === 'undefined' || !AuthApi.verifyCredentialsViaRpc) {
    return { ok: false, message: 'خدمة التحقق غير متاحة — حدّث الصفحة' };
  }
  if (typeof initSupabase === 'function') initSupabase();
  if (typeof ensureSupabaseClient === 'function') {
    await ensureSupabaseClient(12);
  }
  var verified = await AuthApi.verifyCredentialsViaRpc(u, p);
  if (!verified || !verified.id) {
    var err = typeof AuthApi.getLastLoginError === 'function' ? AuthApi.getLastLoginError() : '';
    if (err === 'rate_limited') {
      return { ok: false, message: 'تم تجاوز عدد المحاولات — حاول لاحقاً' };
    }
    if (err === 'password_reset_required') {
      return { ok: false, message: 'يجب تغيير كلمة المرور من شاشة تسجيل الدخول أولاً' };
    }
    return { ok: false, message: 'اسم المستخدم أو كلمة المرور غير صحيحة' };
  }
  var role = verified.role || '';
  if (role !== 'company_admin' && role !== 'company_user' && role !== 'super_admin') {
    return { ok: false, message: 'هذا الحساب ليس حساب إدارة' };
  }
  var emp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
  if (emp && emp.company_id && verified.company_id && role !== 'super_admin') {
    if (parseInt(emp.company_id, 10) !== parseInt(verified.company_id, 10)) {
      return { ok: false, message: 'هذا الحساب لا ينتمي لشركة هذا الموظف' };
    }
  }
  return { ok: true, user: verified };
}

function unlockProfileAdmin() {
  Swal.fire({
    title: '🔑 دخول المسؤول',
    html: '<div style="text-align:right">' +
      '<div style="margin-bottom:12px"><label style="font-size:13px;display:block;margin-bottom:4px">اسم المستخدم</label>' +
      '<input type="text" id="admin-unlock-user" class="setting-input" style="width:100%" placeholder="اسم المستخدم" autocomplete="username" autocapitalize="off" spellcheck="false"></div>' +
      '<div><label style="font-size:13px;display:block;margin-bottom:4px">كلمة المرور</label>' +
      '<input type="password" id="admin-unlock-pass" class="setting-input" style="width:100%" placeholder="••••••" autocomplete="current-password"></div>' +
      '<p style="font-size:11px;color:var(--text-muted);margin:10px 0 0;line-height:1.6">استخدم نفس بيانات دخول لوحة الإدارة المسجّلة في النظام</p></div>',
    confirmButtonText: 'فتح القفل',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    showLoaderOnConfirm: true,
    allowOutsideClick: function () { return !Swal.isLoading(); },
    preConfirm: async function () {
      const user = document.getElementById('admin-unlock-user')?.value.trim();
      const pass = document.getElementById('admin-unlock-pass')?.value;
      const check = await verifyAdminUnlockCredentials(user, pass);
      if (!check.ok) {
        Swal.showValidationMessage('❌ ' + check.message);
        return false;
      }
      return true;
    }
  }).then(result => {
    if (result.isConfirmed) {
      profileAdminUnlocked = true;
      applyProfileLockState();
      Swal.fire({ icon: 'success', title: 'تم فتح القفل', text: 'يمكنك الآن تعديل جميع الحقول', ...swalTheme(), timer: 1500, showConfirmButton: false });
    }
  });
}

function lockProfileAdmin() {
  profileAdminUnlocked = false;
  applyProfileLockState();
}

function applyProfileLockState() {
  const fields = ['emp-profile-name', 'emp-profile-phone', 'emp-profile-dept', 'emp-profile-role', 'emp-profile-checkin', 'emp-profile-checkout'];
  fields.forEach(id => {
    const el = document.getElementById(id);
    if (el) {
      el.readOnly = !profileAdminUnlocked;
      el.style.opacity = profileAdminUnlocked ? '1' : '0.85';
      el.style.background = profileAdminUnlocked ? 'rgba(0,212,170,0.05)' : '';
      el.style.borderColor = profileAdminUnlocked ? 'var(--accent)' : '';
    }
  });
  const lockBtn = document.getElementById('emp-profile-admin-lock');
  const adminBar = document.getElementById('emp-profile-admin-bar');
  if (lockBtn) lockBtn.style.display = profileAdminUnlocked ? 'none' : '';
  if (adminBar) adminBar.style.display = profileAdminUnlocked ? 'block' : 'none';
}

function saveEmpProfile() {
  const emp = getLoggedInEmp();
  if (!emp) return;
  if (profileAdminUnlocked) {
    // Admin mode: save all fields
    const name = document.getElementById('emp-profile-name');
    const phone = document.getElementById('emp-profile-phone');
    const dept = document.getElementById('emp-profile-dept');
    const role = document.getElementById('emp-profile-role');
    const checkin = document.getElementById('emp-profile-checkin');
    const checkout = document.getElementById('emp-profile-checkout');
    if (name) emp.name = name.value.trim() || emp.name;
    if (phone) emp.phone = phone.value.trim() || '—';
    if (dept) emp.dept = dept.value.trim() || emp.dept;
    if (role) emp.role = role.value.trim() || emp.role;
    if (checkin) emp.checkIn = checkin.value.trim() || '08:00';
    if (checkout) emp.checkOut = checkout.value.trim() || '17:00';
    emp.avatar = pickAvatar(emp.name);
  } else {
    // Employee mode: only save phone (avatar saved separately)
    const phone = document.getElementById('emp-profile-phone');
    if (phone) emp.phone = phone.value.trim() || '—';
  }
  saveData();
  buildEmpPortal();
  if (typeof buildEmployees === 'function') buildEmployees();
  // Re-apply lock state after rebuild
  setTimeout(() => applyProfileLockState(), 100);
  Swal.fire({ icon: 'success', title: 'تم حفظ التعديلات', ...swalTheme(), timer: 1500, showConfirmButton: false });
}

// ======= CHECK IN/OUT =======
// Helper: calculate and save attendance record
async function doCheckIn(emp, locationLabel, geo) {
  checkedIn = true;

  let rec = findOpenAttendanceRecord(emp.id);
  var recExisted = !!rec;
  var recBefore = rec ? JSON.parse(JSON.stringify(rec)) : null;
  if (!rec) {
    rec = { empId: emp.id, emp: fullEmpName(emp.name), dept: emp.dept, date: '', dateIso: '', ci: '—', co: '—', hrs: '—', late: '—', ot: '—', status: 'طبيعي' };
    attData.push(rec);
  }
  ensureAttendanceRecordDates(rec);
  rec._punchType = 'check_in';
  applyOptimisticPunchToRecord(rec, 'check_in');
  checkInTime = rec.ci;
  if (currentUser !== 'emp') {
    saveData();
    buildEmpPortal({ skipSubscriptionRefresh: true });
    if (typeof buildAttendance === 'function') buildAttendance();
    buildDashboard();
  }

  var saved = await persistAttendanceNow(rec);
  if (!saved || saved.ok === false) {
    checkedIn = false;
    if (currentUser === 'emp') {
      var idx = attData.indexOf(rec);
      if (recExisted && idx >= 0 && recBefore) {
        Object.keys(rec).forEach(function (k) { delete rec[k]; });
        Object.assign(rec, recBefore);
      } else if (idx >= 0) {
        attData.splice(idx, 1);
      }
      checkInTime = null;
      delete rec._pendingRemoteSync;
      saveData();
      buildEmpPortal({ skipSubscriptionRefresh: true });
      if (typeof buildAttendance === 'function') buildAttendance();
      buildDashboard();
    }
    var errCode = saved && saved.error ? saved.error : 'cloud_unavailable';
    var errDetail = saved && saved.detail ? saved.detail : '';
    if (isOfficialClosureErrorCode(errCode, errDetail)) {
      var closureHit = officialClosureForDate(rec.dateIso) || officialClosureForDate();
      if (closureHit) {
        showOfficialClosureBlock(closureHit, 'تسجيل الحضور');
        return;
      }
    }
    if (errCode === 'employee_suspended') {
      forceEmployeePortalLogout('تم إيقاف الحساب', (saved && saved.message) || SUSPENDED_MSG);
      return;
    }
    var blockMsg = mapAttendanceSaveErrorMessage(errCode, errDetail, 'checkin');
    Swal.fire({ icon: 'error', title: 'فشل تسجيل الحضور', text: blockMsg, ...swalTheme() });
    return;
  }

  applyServerAttendanceToRecord(rec, saved, emp);
  var t = (rec.ci && rec.ci !== '—') ? rec.ci : (saved && saved.check_in && saved.check_in !== '—' ? saved.check_in : '—');
  var lateMin = 0;
  if (rec.late && rec.late !== '—') {
    lateMin = parseDurationMinutes(rec.late) || 0;
  }
  var isLate = rec.status === 'متأخر';

  // Update UI
  document.getElementById('checkin-time').textContent = t;
  document.getElementById('s-checkin').textContent = t;
  document.getElementById('s-late').textContent = emp.openHours ? '0 د' : (lateMin > 0 ? lateMin + ' د' : '0 د');

  saveData();
  await persistEmployeeNow(emp);
  logActivity('checkin', 'attendance', 'تسجيل حضور: ' + emp.name + ' — ' + t, { targetName: emp.name, empId: emp.id, targetEmpId: emp.id });
  await logEmployeePortalEvent('check_in', {
    empId: emp.id,
    success: true,
    geo: geo || null,
    meta: {
      time: t,
      location: locationLabel || '',
      remote_attend: !!(emp && emp.remoteAttend),
      address: geo && geo._trackAddress ? geo._trackAddress : undefined
    }
  });
  buildEmpPortal({ skipSubscriptionRefresh: true });
  if (typeof buildAttendance === 'function') buildAttendance();
  buildDashboard();
  if (typeof refreshSalaryUiAfterPayrollChange === 'function') {
    await refreshSalaryUiAfterPayrollChange([emp.id]);
  } else {
    buildSalaries();
  }

  const lateInfo = emp.openHours
    ? '<br>🕐 دوام وقت مفتوح — لا يُحتسب اليوم في الراتب حتى تسجيل الانصراف'
    : (lateMin > 0 ? '<br>⏱ تأخير: ' + lateMin + ' دقيقة' + (isLate ? ' (متأخر)' : '') : '');
  Swal.fire({ icon:'success', title:'✅ تم تسجيل الحضور', html:'الوقت: <b>' + t + '</b><br>' + locationLabel + lateInfo, ...swalTheme() });
}

function distanceMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat/2) * Math.sin(dLat/2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
    Math.sin(dLng/2) * Math.sin(dLng/2);
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function checkCompanyLocationFromGeo(geo) {
  var cLat = Number(appSettings.gpsLat);
  var cLng = Number(appSettings.gpsLng);
  var range = Number(appSettings.gpsRange || 100);
  if (!geo || !isValidCoord(cLat, cLng)) {
    return { ok: false, distance: 0, range: range, effectiveRange: range, accuracy: 0, lat: geo ? geo.lat : null, lng: geo ? geo.lng : null };
  }
  var dist = Math.round(distanceMeters(geo.lat, geo.lng, cLat, cLng));
  var accuracy = Math.round(geo.accuracy || 0);
  var effectiveRange = range + Math.min(Math.max(accuracy, 0), 400);
  return {
    ok: dist <= effectiveRange,
    distance: dist,
    range: range,
    effectiveRange: effectiveRange,
    accuracy: accuracy,
    lat: geo.lat,
    lng: geo.lng
  };
}

async function getGeolocationPermissionState() {
  if (!navigator.permissions || typeof navigator.permissions.query !== 'function') return 'unknown';
  try {
    var res = await navigator.permissions.query({ name: 'geolocation' });
    return res && res.state ? res.state : 'unknown';
  } catch (e) {
    return 'unknown';
  }
}

function geolocationErrorHint(code) {
  if (code === 1) {
    return 'المتصفح لم يسمح بالموقع. افتح إعدادات المتصفح ← أذونات الموقع ← اسمح لـ kyno-hr.netlify.app';
  }
  if (code === 2) {
    return 'تعذّر قراءة الإحداثيات. تأكد أن GPS مفعّل وجرّب قرب النافذة أو في الهواء الطلق.';
  }
  if (code === 3) {
    return 'انتهت مهلة تحديد الموقع. حاول مرة أخرى مع GPS مفعّل.';
  }
  return 'تعذّر قراءة الموقع. فعّل GPS واسمح للمتصفح بالوصول للموقع.';
}

function readGeoPositionOnce(geoOptions) {
  return new Promise(function (resolve) {
    if (!navigator.geolocation) {
      resolve({ geo: null, errorCode: 0, errorMessage: 'unsupported' });
      return;
    }
    navigator.geolocation.getCurrentPosition(
      function (pos) {
        resolve({
          geo: {
            lat: pos.coords.latitude,
            lng: pos.coords.longitude,
            accuracy: pos.coords.accuracy
          },
          errorCode: 0
        });
      },
      function (err) {
        resolve({
          geo: null,
          errorCode: err && err.code ? err.code : 0,
          errorMessage: err && err.message ? err.message : 'failed'
        });
      },
      geoOptions || { enableHighAccuracy: false, timeout: 12000, maximumAge: 180000 }
    );
  });
}

async function collectPunchGeoReliable(options) {
  options = options || {};
  if (!navigator.geolocation) {
    return { geo: null, source: 'unsupported' };
  }
  var strategies = [
    { enableHighAccuracy: false, timeout: 8000, maximumAge: 300000 },
    { enableHighAccuracy: false, timeout: 12000, maximumAge: 60000 },
    { enableHighAccuracy: true, timeout: 15000, maximumAge: 15000 },
    { enableHighAccuracy: true, timeout: 20000, maximumAge: 0 }
  ];
  var lastErr = null;
  for (var i = 0; i < strategies.length; i++) {
    var hit = await readGeoPositionOnce(strategies[i]);
    if (hit && hit.geo) {
      return { geo: hit.geo, source: 'read_' + i };
    }
    lastErr = hit;
  }
  return {
    geo: null,
    source: 'failed',
    errorCode: lastErr && lastErr.errorCode,
    errorMessage: lastErr && lastErr.errorMessage
  };
}

async function requireMandatoryPunchGeo(options) {
  options = options || {};
  var purpose = options.purpose || 'check_in';
  var actionLabel = purpose === 'check_out' ? 'الانصراف' : 'الحضور';

  if (!navigator.geolocation) {
    await Swal.fire({
      icon: 'error',
      title: 'الموقع غير مدعوم',
      text: 'متصفحك لا يدعم تحديد الموقع. استخدم Chrome أو Safari على HTTPS.',
      ...swalTheme()
    });
    return null;
  }

  async function finalizePack(pack) {
    if (!pack || !pack.geo) return null;
    pack.address = await reverseGeocodeClient(pack.geo.lat, pack.geo.lng);
    return pack;
  }

  var firstTry = await finalizePack(await collectPunchGeoReliable({ timeoutMs: 15000, samples: 1 }));
  if (firstTry && firstTry.geo) return firstTry;

  var permState = await getGeolocationPermissionState();
  if (permState === 'denied') {
    await Swal.fire({
      icon: 'error',
      title: 'الموقع محظور من المتصفح',
      html: 'GPS مفعّل على الهاتف، لكن <b>المتصفح</b> لم يسمح للموقع.<br><br>'
        + '1. افتح إعدادات Chrome/Safari<br>'
        + '2. أذونات الموقع ← <b>kyno-hr.netlify.app</b><br>'
        + '3. اختر «السماح» ثم أعد المحاولة',
      confirmButtonText: 'حاول مجدداً',
      ...swalTheme()
    });
    var afterDenied = await finalizePack(await collectPunchGeoReliable({ timeoutMs: 15000, samples: 1 }));
    if (afterDenied && afterDenied.geo) return afterDenied;
    return null;
  }

  while (true) {
    var ask = await Swal.fire({
      icon: 'warning',
      title: 'تفعيل الموقع مطلوب',
      text: 'لا يمكن تسجيل ' + actionLabel + ' بدون السماح للمتصفح بالوصول للموقع (ليس فقط GPS الهاتف).',
      showCancelButton: true,
      confirmButtonText: 'تفعيل الموقع',
      cancelButtonText: 'إلغاء',
      confirmButtonColor: '#00d4aa',
      ...swalTheme(),
      preConfirm: function () {
        return collectPunchGeoReliable({ timeoutMs: 18000, samples: 1 }).then(function (pack) {
          if (pack && pack.geo) return pack;
          var hint = geolocationErrorHint(pack && pack.errorCode);
          Swal.showValidationMessage(hint);
          return false;
        });
      }
    });
    if (!ask.isConfirmed) return null;
    if (ask.value && ask.value.geo) {
      return finalizePack(ask.value);
    }
  }
}

function verifyCompanyLocation(options) {
  options = options || {};
  const maxSamples = options.samples || 4;
  const timeoutMs = options.timeoutMs || 16000;
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) {
      reject(new Error('المتصفح لا يدعم تحديد الموقع'));
      return;
    }
    const cLat = Number(appSettings.gpsLat);
    const cLng = Number(appSettings.gpsLng);
    const range = Number(appSettings.gpsRange || 100);
    if (!isValidCoord(cLat, cLng)) {
      reject(new Error('موقع الشركة غير مضبوط — اطلب من المسؤول ضبط موقع الشركة في الإعدادات'));
      return;
    }
    const samples = [];
    let watchId = null;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      if (watchId != null) navigator.geolocation.clearWatch(watchId);
      if (!samples.length) {
        reject(new Error('تعذر قراءة موقعك'));
        return;
      }
      // نفضّل أي عينة ناجحة داخل النطاق لتقليل الرفض الخاطئ بسبب تذبذب GPS.
      var okSamples = samples.filter(function (s) { return s && s.ok === true; });
      if (okSamples.length) {
        okSamples.sort(function (a, b) { return a.distance - b.distance; });
        resolve(okSamples[0]);
        return;
      }
      samples.sort(function (a, b) { return a.distance - b.distance; });
      resolve(samples[0]);
    };
    const timer = setTimeout(finish, timeoutMs);
    watchId = navigator.geolocation.watchPosition(function (pos) {
      const lat = pos.coords.latitude;
      const lng = pos.coords.longitude;
      const dist = Math.round(distanceMeters(lat, lng, cLat, cLng));
      const accuracy = Math.round(pos.coords.accuracy || 0);
      const effectiveRange = range + Math.min(Math.max(accuracy, 0), 400);
      samples.push({
        ok: dist <= effectiveRange,
        distance: dist,
        range: range,
        effectiveRange: effectiveRange,
        accuracy: accuracy,
        lat: lat,
        lng: lng
      });
      if (samples.length >= maxSamples) {
        clearTimeout(timer);
        finish();
      }
    }, function (err) {
      clearTimeout(timer);
      if (done) return;
      done = true;
      if (watchId != null) navigator.geolocation.clearWatch(watchId);
      reject(new Error(err.message || 'تعذر قراءة موقعك'));
    }, { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 0 });
  });
}

var _checkInInFlight = false;
var _checkOutInFlight = false;

function isDeviceTrackingEnabled() {
  return appSettings && appSettings.trackDevices !== false;
}

function collectPortalGeoMeta() {
  return new Promise(function (resolve) {
    if (!navigator.geolocation) {
      resolve(null);
      return;
    }
    var done = false;
    var timer = setTimeout(function () {
      if (done) return;
      done = true;
      resolve(null);
    }, 3500);
    navigator.geolocation.getCurrentPosition(function (pos) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({
        lat: pos.coords.latitude,
        lng: pos.coords.longitude,
        accuracy: pos.coords.accuracy
      });
    }, function () {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(null);
    }, { enableHighAccuracy: false, timeout: 3000, maximumAge: 60000 });
  });
}

function collectRemotePunchGeo(options) {
  return collectPunchGeoReliable(options);
}

async function reverseGeocodeClient(lat, lng) {
  if (lat == null || lng == null) return null;
  try {
    var url = 'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude='
      + encodeURIComponent(lat) + '&longitude=' + encodeURIComponent(lng) + '&localityLanguage=ar';
    var res = await fetch(url, { cache: 'no-store' });
    if (!res.ok) return null;
    var data = await res.json();
    if (!data) return null;
    var parts = [];
    if (data.locality) parts.push(data.locality);
    else if (data.city) parts.push(data.city);
    if (data.principalSubdivision) parts.push(data.principalSubdivision);
    if (data.countryName && parts.indexOf(data.countryName) < 0) parts.push(data.countryName);
    return parts.length ? parts.join('، ') : (data.localityInfo && data.localityInfo.informative ? data.localityInfo.informative[0].name : null);
  } catch (e) {
    console.warn('reverseGeocodeClient:', e);
    return null;
  }
}

async function resolveRemotePunchGeo() {
  var pack = await collectPunchGeoReliable({ timeoutMs: 22000, samples: 6 });
  if (pack && pack.geo) {
    pack.address = await reverseGeocodeClient(pack.geo.lat, pack.geo.lng);
  }
  return pack || { geo: null, source: 'empty' };
}

async function ensureEmployeeRemoteAttendFresh(emp) {
  if (!emp || !emp.id) return emp;
  if (typeof sb_fetchEmployeeClientProfile !== 'function') return emp;
  try {
    var profile = await sb_fetchEmployeeClientProfile(emp.id);
    if (profile && profile.ok === true) {
      if (profile.remote_attend != null) emp.remoteAttend = profile.remote_attend === true;
      if (profile.open_hours != null) emp.openHours = profile.open_hours === true;
    }
  } catch (e) {
    console.warn('ensureEmployeeRemoteAttendFresh:', e);
  }
  return emp;
}

function buildRemotePunchLocationLabel(emp, punchKind, geoPack) {
  var isCheckout = punchKind === 'check_out';
  var action = isCheckout ? 'انصراف' : 'حضور';
  var openHoursNote = emp && emp.openHours ? ' — دوام وقت مفتوح' : '';
  if (geoPack && geoPack.geo) {
    var g = geoPack.geo;
    var acc = g.accuracy != null ? Math.round(g.accuracy) : null;
    var coord = Number(g.lat).toFixed(5) + ', ' + Number(g.lng).toFixed(5) + (acc != null ? ' (±' + acc + 'م)' : '');
    if (geoPack.address) {
      return '📍 ' + action + ' عن بُعد' + openHoursNote + ' — ' + geoPack.address + ' — ' + coord;
    }
    return '📍 ' + action + ' عن بُعد' + openHoursNote + ' — الموقع: ' + coord;
  }
  return '📍 ' + action + ' عن بُعد' + openHoursNote + ' — الموقع غير متاح (اسمح بالموقع في المتصفح)';
}

async function logEmployeePortalEvent(eventType, options) {
  if (!isDeviceTrackingEnabled()) return;
  if (typeof sb_logEmployeePortalEvent !== 'function') return;
  options = options || {};
  var empId = parseInt(options.empId || window.loggedInEmpId || '0', 10);
  if (!empId) return;
  var geo = options.geo || null;
  if (!geo && (eventType === 'check_in' || eventType === 'check_out')) {
    var pack = await collectPunchGeoReliable({ timeoutMs: 12000, samples: 4 });
    geo = pack && pack.geo ? pack.geo : null;
    if (geo && options.meta && !options.meta.address) {
      var addr = await reverseGeocodeClient(geo.lat, geo.lng);
      if (addr) {
        options.meta = Object.assign({}, options.meta, { address: addr });
        if (!options.meta.location || options.meta.location.indexOf('غير متاح') >= 0) {
          options.meta.location = addr + ' — ' + Number(geo.lat).toFixed(5) + ', ' + Number(geo.lng).toFixed(5);
        }
      }
    }
  }
  try {
    await sb_logEmployeePortalEvent(empId, eventType, {
      success: options.success !== false,
      ip: options.ip || currentClientIp || null,
      userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : null,
      geo: geo,
      meta: options.meta || {}
    });
  } catch (e) {
    console.warn('logEmployeePortalEvent:', e);
  }
}

function setCheckOutButtonBusy(busy) {
  try {
    var btn = document.querySelector('#page-emp-home .att-btn.checkout');
    if (!btn) return;
    btn.disabled = !!busy;
    btn.style.pointerEvents = busy ? 'none' : '';
    btn.style.opacity = busy ? '0.65' : '';
  } catch (e) { /* ignore */ }
}

function setCheckInButtonBusy(busy) {
  try {
    var btn = document.querySelector('#page-emp-home .att-btn.checkin');
    if (!btn) return;
    btn.disabled = !!busy;
    btn.style.pointerEvents = busy ? 'none' : '';
    btn.style.opacity = busy ? '0.65' : '';
  } catch (e) { /* ignore */ }
}

async function settleAttendanceLoading(loadingShownAt, cb) {
  var minMs = 700;
  var elapsed = loadingShownAt ? (Date.now() - loadingShownAt) : minMs;
  var remain = Math.max(0, minMs - elapsed);
  if (remain > 0) await new Promise(function (r) { setTimeout(r, remain); });
  return cb();
}

async function doCheckOut(emp, rec, recBefore, locationLabel, geo) {
  if (!rec.dateIso && attendanceRecordIso(rec)) rec.dateIso = attendanceRecordIso(rec);
  rec._punchType = 'check_out';
  applyOptimisticPunchToRecord(rec, 'check_out');
  if (currentUser !== 'emp') {
    saveData();
    buildEmpPortal({ skipSubscriptionRefresh: true });
    if (typeof buildAttendance === 'function') buildAttendance();
    buildDashboard();
  }
  var saved = await persistAttendanceNow(rec);
  if (!saved || saved.ok === false) {
    if (currentUser === 'emp') {
      if (recBefore) {
        Object.keys(rec).forEach(function (k) { delete rec[k]; });
        Object.assign(rec, recBefore);
      } else {
        rec.co = '—';
        rec.hrs = '—';
        rec.ot = '—';
        delete rec._punchType;
      }
      rec._pendingRemoteSync = true;
      if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
      saveData();
      buildEmpPortal({ skipSubscriptionRefresh: true });
      if (typeof buildAttendance === 'function') buildAttendance();
      buildDashboard();
    }
    var errCodeOut = saved && saved.error ? saved.error : 'cloud_unavailable';
    var errDetailOut = saved && saved.detail ? saved.detail : '';
    if (isOfficialClosureErrorCode(errCodeOut, errDetailOut)) {
      var closureHitOut = officialClosureForDate(rec.dateIso) || officialClosureForDate();
      if (closureHitOut) {
        showOfficialClosureBlock(closureHitOut, 'تسجيل الانصراف');
        return;
      }
    }
    if (errCodeOut === 'employee_suspended') {
      forceEmployeePortalLogout('تم إيقاف الحساب', (saved && saved.message) || SUSPENDED_MSG);
      return;
    }
    var blockMsg = mapAttendanceSaveErrorMessage(errCodeOut, errDetailOut, 'checkout');
    Swal.fire({ icon: 'error', title: 'فشل تسجيل الانصراف', text: blockMsg, ...swalTheme() });
    await logEmployeePortalEvent('check_out', {
      empId: emp.id,
      success: false,
      geo: geo || null,
      meta: { error: errCodeOut, location: locationLabel || '', remote_attend: !!(emp && emp.remoteAttend) }
    });
    return;
  }
  applyServerAttendanceToRecord(rec, saved, emp);
  checkedIn = false;
  var t = (rec.co && rec.co !== '—') ? rec.co : (saved && saved.check_out && saved.check_out !== '—' ? saved.check_out : '—');
  var hrsStr = formatWorkHoursDisplay(rec, emp);
  if (hrsStr === '—') hrsStr = '0س 0د';

  document.getElementById('checkout-time').textContent = t;
  document.getElementById('s-checkout').textContent = t;
  document.getElementById('s-hours').textContent = emp.openHours ? 'يوم كامل' : hrsStr;

  saveData();
  await persistEmployeeNow(emp);
  logActivity('checkout', 'attendance', 'تسجيل انصراف: ' + emp.name + ' — ' + t, { targetName: emp.name, empId: emp.id, targetEmpId: emp.id });
  await logEmployeePortalEvent('check_out', {
    empId: emp.id,
    success: true,
    geo: geo || null,
    meta: {
      time: t,
      location: locationLabel || '',
      remote_attend: !!(emp && emp.remoteAttend),
      address: geo && geo._trackAddress ? geo._trackAddress : undefined
    }
  });
  buildEmpPortal({ skipSubscriptionRefresh: true });
  if (typeof buildAttendance === 'function') buildAttendance();
  buildDashboard();
  if (typeof refreshSalaryUiAfterPayrollChange === 'function') {
    await refreshSalaryUiAfterPayrollChange([emp.id]);
  } else {
    buildSalaries();
  }

  var locationInfo = locationLabel ? ('<br>' + locationLabel) : '';
  if (emp.openHours) {
    Swal.fire({
      icon: 'success',
      title: '✅ تم تسجيل الانصراف',
      html: 'الوقت: <b>' + t + '</b><br>مجموع ساعات العمل: <b>' + hrsStr + '</b><br>🕐 دوام وقت مفتوح — يوم كامل' + locationInfo,
      ...swalTheme()
    });
    return;
  }

  var isOvertimeShow = rec.ot && rec.ot !== '—';
  Swal.fire({
    icon: 'success',
    title: '✅ تم تسجيل الانصراف',
    html: 'الوقت: <b>' + t + '</b><br>مجموع ساعات العمل: <b>' + hrsStr + '</b>'
      + (isOvertimeShow ? '<br>🔵 إضافي: ' + rec.ot : '')
      + locationInfo,
    ...swalTheme()
  });
}

async function checkIn() {
  if (_checkInInFlight) return;
  _checkInInFlight = true;
  setCheckInButtonBusy(true);
  var loadingShownAt = 0;
  try {
  let emp = getLoggedInEmp();
  if (!emp && window.loggedInEmpId) {
    emp = await ensureLoggedInEmployeeLoaded();
  }
  if (!emp) {
    Swal.fire({
      icon: 'warning',
      title: 'الحساب غير جاهز',
      text: 'تعذّر تحميل بيانات الموظف. تحقق من الإنترنت ثم حدّث الصفحة أو أعد مسح QR.',
      ...swalTheme()
    });
    return;
  }
  if (!(await guardEmployeeAccountActive())) return;
  await refreshOfficialClosuresFromCloud();
  var activeClosure = officialClosureForDate();
  renderOfficialClosureEmpBanner(activeClosure);
  bindOfficialClosureAttendanceButtons(activeClosure);
  if (activeClosure) {
    showOfficialClosureBlock(activeClosure, 'تسجيل الحضور');
    return;
  }
  var openRec = findOpenAttendanceRecord(emp.id, false);
  if (checkedIn || openRec) {
    Swal.fire({ icon:'warning', title:'تم التسجيل مسبقاً', text:'لديك حضور مفتوح — سجّل الانصراف أولاً قبل حضور جديد.', ...swalTheme() });
    return;
  }
  if (!requireSubscription('تسجيل الحضور')) return;
  if (typeof refreshLoggedInEmployeeFromServer === 'function') {
    emp = await refreshLoggedInEmployeeFromServer() || emp;
  }
  emp = await ensureEmployeeRemoteAttendFresh(emp);

  var geoPackIn = await requireMandatoryPunchGeo({ purpose: 'check_in' });
  if (!geoPackIn || !geoPackIn.geo) return;

  if (emp.remoteAttend) {
    if (geoPackIn.address) geoPackIn.geo._trackAddress = geoPackIn.address;
    var remoteInLabel = buildRemotePunchLocationLabel(emp, 'check_in', geoPackIn);
    await doCheckIn(emp, remoteInLabel, geoPackIn.geo);
    return;
  }

  if (!isValidCoord(Number(appSettings.gpsLat), Number(appSettings.gpsLng))) {
    Swal.fire({
      icon: 'error',
      title: 'موقع الشركة غير مضبوط',
      text: 'اطلب من المسؤول ضبط موقع الشركة في الإعدادات',
      ...swalTheme()
    });
    return;
  }

  Swal.fire({
    title:'📍 جارٍ التحقق من الموقع...',
    text:'يتم التحقق من موقعك الجغرافي قرب موقع الشركة', allowOutsideClick:false, showConfirmButton:false,
    ...swalTheme(), didOpen:()=>Swal.showLoading()
  });
  loadingShownAt = Date.now();
  try {
    var loc = checkCompanyLocationFromGeo(geoPackIn.geo);
    if (!loc.ok) {
      await settleAttendanceLoading(loadingShownAt, function () { return Swal.fire({
        icon:'error',
        title:'خارج نطاق الشركة',
        html:'المسافة الحالية: <b>' + loc.distance + ' متر</b><br>نطاق السماح: <b>' + loc.range + ' متر</b>' + (loc.effectiveRange > loc.range ? ' (فعلي: ' + loc.effectiveRange + ' م)' : '') + '<br>دقة الهاتف: <b>' + loc.accuracy + ' متر</b><br><span style="font-size:12px;color:var(--text-muted)">تأكد أن المسؤول ضبط موقع الشركة في الإعدادات. إذا كنت داخل الشركة وما زال الخطأ يظهر، حرّك الهاتف قرب النافذة أو ارفع نطاق السماح قليلاً.</span>',
        ...swalTheme()
      }); });
      return;
    }
    var checkInGeo = { lat: loc.lat, lng: loc.lng, accuracy: loc.accuracy };
    await settleAttendanceLoading(loadingShownAt, function () {
      return doCheckIn(emp, '📍 داخل موقع الشركة (' + loc.distance + 'م، دقة ' + loc.accuracy + 'م)', checkInGeo);
    });
  } catch (err) {
    await settleAttendanceLoading(loadingShownAt, function () {
      return Swal.fire({ icon:'error', title:'تعذر التحقق من الموقع', text: err.message || String(err), ...swalTheme() });
    });
  }
  } finally {
    // نترك قفل الزر بسيطاً لفترة قصيرة لحماية من النقرات المتكررة.
    setTimeout(function () {
      _checkInInFlight = false;
      setCheckInButtonBusy(false);
    }, 900);
  }
}

async function checkOut() {
  if (_checkOutInFlight) return;
  _checkOutInFlight = true;
  setCheckOutButtonBusy(true);
  var loadingShownAt = 0;
  try {
  let emp = getLoggedInEmp();
  if (!emp && window.loggedInEmpId) {
    emp = await ensureLoggedInEmployeeLoaded();
  }
  if (!emp) {
    Swal.fire({
      icon: 'warning',
      title: 'الحساب غير جاهز',
      text: 'تعذّر تحميل بيانات الموظف. تحقق من الإنترنت ثم حدّث الصفحة أو أعد مسح QR.',
      ...swalTheme()
    });
    return;
  }
  if (!(await guardEmployeeAccountActive())) return;
  await refreshOfficialClosuresFromCloud();
  var activeClosure = officialClosureForDate();
  renderOfficialClosureEmpBanner(activeClosure);
  bindOfficialClosureAttendanceButtons(activeClosure);
  if (activeClosure) {
    showOfficialClosureBlock(activeClosure, 'تسجيل الانصراف');
    return;
  }
  var openRec = findOpenAttendanceRecord(emp.id, false);
  if (openRec && openRec.co && openRec.co !== '—') {
    Swal.fire({ icon:'warning', title:'تم التسجيل مسبقاً', text:'لقد سجلت انصرافك بالفعل!', ...swalTheme() });
    return;
  }
  if (!checkedIn && !openRec) {
    Swal.fire({ icon:'warning', title:'لم تسجل حضورك بعد', text:'يجب تسجيل الحضور أولاً', ...swalTheme() });
    return;
  }
  if (!requireSubscription('تسجيل الانصراف')) return;
  if (typeof refreshLoggedInEmployeeFromServer === 'function') {
    emp = await refreshLoggedInEmployeeFromServer() || emp;
  }
  emp = await ensureEmployeeRemoteAttendFresh(emp);

  let rec = openRec || findOpenAttendanceRecord(emp.id, false);
  var recBefore = rec ? JSON.parse(JSON.stringify(rec)) : null;
  if (!rec) {
    Swal.fire({ icon:'warning', title:'لم تسجل حضورك بعد', text:'يجب تسجيل الحضور أولاً', ...swalTheme() });
    return;
  }

  if (emp.remoteAttend) {
    var geoPackOut = await requireMandatoryPunchGeo({ purpose: 'check_out' });
    if (!geoPackOut || !geoPackOut.geo) return;
    if (geoPackOut.address) geoPackOut.geo._trackAddress = geoPackOut.address;
    var remoteOutLabel = buildRemotePunchLocationLabel(emp, 'check_out', geoPackOut);
    await doCheckOut(emp, rec, recBefore, remoteOutLabel, geoPackOut.geo);
    return;
  }

  var geoPackOutCo = await requireMandatoryPunchGeo({ purpose: 'check_out' });
  if (!geoPackOutCo || !geoPackOutCo.geo) return;

  if (!isValidCoord(Number(appSettings.gpsLat), Number(appSettings.gpsLng))) {
    Swal.fire({
      icon: 'error',
      title: 'موقع الشركة غير مضبوط',
      text: 'اطلب من المسؤول ضبط موقع الشركة في الإعدادات',
      ...swalTheme()
    });
    return;
  }

  Swal.fire({
    title:'📍 جارٍ التحقق من الموقع...',
    text:'يتم التحقق من موقعك الجغرافي قرب موقع الشركة',
    allowOutsideClick:false,
    showConfirmButton:false,
    ...swalTheme(),
    didOpen: function () { Swal.showLoading(); }
  });
  loadingShownAt = Date.now();
  try {
    var locOut = checkCompanyLocationFromGeo(geoPackOutCo.geo);
    if (!locOut.ok) {
      await settleAttendanceLoading(loadingShownAt, function () { return Swal.fire({
        icon:'error',
        title:'خارج نطاق الشركة',
        html:'المسافة الحالية: <b>' + locOut.distance + ' متر</b><br>نطاق السماح: <b>' + locOut.range + ' متر</b>' + (locOut.effectiveRange > locOut.range ? ' (فعلي: ' + locOut.effectiveRange + ' م)' : '') + '<br>دقة الهاتف: <b>' + locOut.accuracy + ' متر</b><br><span style="font-size:12px;color:var(--text-muted)">لا يمكن تسجيل الانصراف خارج موقع الشركة.</span>',
        ...swalTheme()
      }); });
      return;
    }
    var checkoutGeo = { lat: locOut.lat, lng: locOut.lng, accuracy: locOut.accuracy };
    var checkoutLabel = '📍 داخل موقع الشركة (' + locOut.distance + 'م، دقة ' + locOut.accuracy + 'م)';
    await settleAttendanceLoading(loadingShownAt, function () {
      return doCheckOut(emp, rec, recBefore, checkoutLabel, checkoutGeo);
    });
  } catch (err) {
    await settleAttendanceLoading(loadingShownAt, function () {
      return Swal.fire({ icon:'error', title:'تعذر التحقق من الموقع', text: err.message || String(err), ...swalTheme() });
    });
  }
  } finally {
    setTimeout(function () {
      _checkOutInFlight = false;
      setCheckOutButtonBusy(false);
    }, 900);
  }
}

// ======= ACTIONS =======
function empFormHtml(emp) {
  ensureOrgLists();
  const deptOpts = appSettings.departments.map(d =>
    '<option value="' + escAttr(d) + '"' + (emp && emp.dept === d ? ' selected' : '') + '>' + esc(d) + '</option>'
  ).join('');
  const jobList = appSettings.jobs;
  const currentRole = emp ? String(emp.role || '').trim() : '';
  const roleInList = currentRole && jobList.indexOf(currentRole) >= 0;
  const jobOpts = jobList.map(j =>
    '<option value="' + escAttr(j) + '"' + (currentRole === j ? ' selected' : '') + '>' + esc(j) + '</option>'
  ).join('');
  const eid = emp ? emp.id : 0;
  if (emp) normalizeEmployee(emp);
  const d1 = emp ? getDevice(emp, 1) : { ip: '', fingerprint: '', pin: '', barcode: 'ATT-NEW-D1' };
  const d2 = emp ? getDevice(emp, 2) : { ip: '', fingerprint: '', pin: '', barcode: 'ATT-NEW-D2' };
  return [
    '<input type="hidden" id="emp-form-id" value="' + eid + '">',
    '<motionless class="emp-form-wrap">',
    '<section class="emp-form-section"><motionless class="emp-form-section-title"><i class="fa fa-user"></i> البيانات الأساسية</motionless>',
    '<motionless class="emp-field"><label>الاسم الكامل <span class="req">*</span></label><input id="emp-name" value="' + (emp ? esc(emp.name) : '') + '" placeholder="أحمد محمد الجبوري"></motionless>',
    '<motionless class="emp-field-row">',
    '<motionless class="emp-field"><label>القسم <span class="req">*</span></label><select id="emp-dept"><option value="">— اختر —</option>' + deptOpts + '</select></motionless>',
    '<motionless class="emp-field"><label>الوظيفة <span class="req">*</span></label><select id="emp-role" onchange="onEmpRoleChange()"><option value="">— اختر —</option>' + jobOpts + '<option value="__custom__"' + (currentRole && !roleInList ? ' selected' : '') + '>✏️ وظيفة أخرى...</option></select><input id="emp-role-custom" placeholder="اكتب اسم الوظيفة" value="' + (currentRole && !roleInList ? esc(currentRole) : '') + '" style="margin-top:8px;display:' + (currentRole && !roleInList ? 'block' : 'none') + '"></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row">',
    '<motionless class="emp-field"><label>رقم الهاتف <span class="req">*</span></label><input id="emp-phone" dir="ltr" placeholder="07701234567" value="' + (emp && emp.phone !== '—' ? esc(emp.phone) : '') + '"></motionless>',
    '<motionless class="emp-field"><label>نوع الراتب <span class="req">*</span></label><select id="emp-salary-type" onchange="onSalaryTypeChange()"><option value="monthly"' + (emp && emp.salaryType === 'monthly' ? ' selected' : '') + (!emp || !emp.salaryType ? ' selected' : '') + '>📋 راتب شهري</option><option value="biweekly"' + (emp && emp.salaryType === 'biweekly' ? ' selected' : '') + '>📅 راتب كل ' + getBiweeklyPeriodDays() + ' يوم</option><option value="commission"' + (emp && emp.salaryType === 'commission' ? ' selected' : '') + '>💰 راتب عمولة</option></select></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row">',
    '<motionless class="emp-field"><label>تاريخ المباشرة</label><input type="date" id="emp-hire-date" value="' + (emp ? esc(emp.hireDate || '') : (typeof todayIsoDate === 'function' ? todayIsoDate() : '')) + '"><span class="emp-field-hint">لا يُحتسب أي غياب قبل هذا التاريخ. اتركه فارغاً لعدم التقييد.</span></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row" id="emp-salary-amount-row">',
    '<motionless class="emp-field"><label>الراتب الشهري (IQD) <span class="req">*</span></label><input type="number" id="emp-salary" min="0" value="' + (emp ? emp.salary : '') + '" oninput="autoCalcDailyRate()"></motionless>',
    '<motionless class="emp-field"><label>المعدل اليومي (IQD)</label><input type="number" id="emp-daily-rate" min="0" value="' + (emp && emp.dailyRate ? emp.dailyRate : '') + '" placeholder="يُحسب تلقائياً من الراتب ÷ ' + getStandardMonthDays() + '"></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row">',
    '<motionless class="emp-field" id="emp-biweekly-half-field" style="display:none"><label>راتب كل ' + getBiweeklyPeriodDays() + ' يوم (IQD) <span class="req">*</span></label><input type="number" id="emp-salary-half" min="0" value="' + (emp && emp.salaryHalf ? emp.salaryHalf : '') + '" placeholder="نصف الراتب" oninput="autoCalcDailyRate()"></motionless>',
    '</motionless>',
    '<motionless class="emp-field" id="emp-commission-note" style="display:none;padding:10px;background:rgba(246,224,94,0.08);border:1px solid rgba(246,224,94,0.2);border-radius:10px;margin-bottom:8px"><p style="font-size:13px;color:#f6e05e;margin:0">💰 <b>راتب عمولة:</b> لا يُحتسب راتب ثابت — فقط تسجيل حضور وانصراف. يتم احتساب الراتب يدوياً حسب العمولة المتفق عليها.</p></motionless>',
    '</section>',
    '<section class="emp-form-section"><motionless class="emp-form-section-title"><i class="fa fa-clock"></i> أوقات الدوام</motionless>',
    '<motionless class="emp-field-row">',
    '<motionless class="emp-field"><label>وقت الحضور</label><input type="time" id="emp-checkin" value="' + (emp ? emp.checkIn : '08:00') + '"></motionless>',
    '<motionless class="emp-field"><label>وقت الانصراف</label><input type="time" id="emp-checkout" value="' + (emp ? emp.checkOut : '17:00') + '"></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row" style="gap:12px;margin-top:8px">',
    '<motionless class="emp-field" style="flex:1"><button type="button" id="emp-remote-attend-card" class="emp-option-card" data-option="emp-remote-attend" onclick="toggleEmpOptionFromCard(this)"><input type="checkbox" id="emp-remote-attend"' + (emp && emp.remoteAttend ? ' checked' : '') + '><span class="option-check"></span><span><span class="emp-option-title" style="color:#68d391">📍 تسجيل حضور من أي مكان</span><span class="emp-option-desc">يتجاوز فحص GPS — يمكن للموظف الدخول والحضور من أي جهاز دون QR.</span></span></button></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row" style="gap:12px;margin-top:4px">',
    '<motionless class="emp-field" style="flex:1"><button type="button" id="emp-open-hours-card" class="emp-option-card blue" data-option="emp-open-hours" onclick="toggleEmpOptionFromCard(this)"><input type="checkbox" id="emp-open-hours"' + (emp && emp.openHours ? ' checked' : '') + '><span class="option-check"></span><span><span class="emp-option-title" style="color:#63b3ed">🕐 دوام وقت مفتوح</span><span class="emp-option-desc">لا يُحتسب تأخير أو انصراف مبكر، وأي وقت حضور يُحسب يومًا كاملًا.</span></span></button></motionless>',
    '</motionless>',
    '<motionless class="emp-field-row" style="gap:12px;margin-top:4px">',
    '<motionless class="emp-field" style="flex:1"><button type="button" id="emp-include-ot-card" class="emp-option-card" data-option="emp-include-ot" onclick="toggleEmpOptionFromCard(this)"><input type="checkbox" id="emp-include-ot"' + (emp && emp.includeOvertimeInSalary ? ' checked' : '') + '><span class="option-check"></span><span><span class="emp-option-title" style="color:#9f7aea">⏱️ احتساب الوقت الإضافي ضمن الراتب</span><span class="emp-option-desc">إذا لم يُفعّل: يُحسب الإضافي للتقارير فقط ولا يُضاف للصافي.</span></span></button></motionless>',
    '</motionless><p class="emp-field-hint">مرجع حساب التأخير والانصراف</p></section>',
    '<section class="emp-form-section"><motionless class="emp-form-section-title"><i class="fa fa-chart-line"></i> إحصائيات</motionless>',
    '<motionless class="emp-field-row">',
    '<motionless class="emp-field"><label>أيام الحضور</label><input type="number" id="emp-days" min="0" max="31" value="' + (emp ? emp.days : 0) + '"></motionless>',
    '<motionless class="emp-field"><label>دقائق التأخير</label><input type="number" id="emp-late" min="0" value="' + (emp ? emp.lateMin : 0) + '"></motionless>',
    '</motionless></section>',
    '<section class="emp-form-section"><motionless class="emp-form-section-title"><i class="fa fa-qrcode"></i> الهواتف ورمز QR</motionless>',
    '<p class="emp-field-hint">امسح QR بكاميرا هاتف الموظف — يفتح رابط التسجيل ويحفظ IP الهاتف وبصمة الجهاز تلقائياً</p>',
    deviceBlockHtml(1, d1, eid),
    deviceBlockHtml(2, d2, eid),
    '</section></motionless>'
  ].join('').split('motionless').join('div');
}

function deviceBlockHtml(slot, dev, empId) {
  const esc = s => (s || '').replace(/"/g, '&quot;');
  const canScan = empId > 0;
  const D = 'di' + 'v';
  const fpVal = dev.fingerprint || '';
  const token = dev.token || '';
  const linkCode = token ? getRegistrationUrl(token, dev.barcode) : '';
  return '<' + D + ' class="device-block"><' + D + ' class="device-block-head">📱 ' + (slot === 1 ? 'الهاتف الأول' : 'الهاتف الثاني') + '</' + D + '>' +
    '<' + D + ' class="emp-field"><label>بصمة الجهاز</label>' +
    '<input type="text" id="emp-fp-' + slot + '" dir="ltr" value="' + esc(fpVal) + '" placeholder="يُملأ تلقائياً عند مسح QR" style="font-size:11px;color:#68d391" readonly>' +
    '</' + D + '>' +
    '<' + D + ' class="emp-field"><label>عنوان IP المسجّل</label><' + D + ' class="device-ip-row">' +
    '<input type="text" id="emp-ip-' + slot + '" dir="ltr" value="' + esc(dev.ip) + '" placeholder="يُملأ تلقائياً عند مسح QR">' +
    (canScan ? '<button type="button" class="btn-scan-ip" onclick="startBarcodeScanForForm(' + slot + ')"><i class="fa fa-qrcode"></i> تسجيل يدوي</button>' : '<span style="font-size:11px;color:var(--text-muted)">احفظ الموظف أولاً</span>') +
    '</' + D + '></' + D + '>' +
    (linkCode ? '<' + D + ' class="emp-field"><label>رابط الربط التلقائي (احتياطي)</label><' + D + ' style="font-size:11px;font-weight:700;color:#f6e05e;direction:ltr;padding:8px;background:rgba(0,0,0,0.2);border-radius:8px;word-break:break-all;user-select:all">' + esc(linkCode) + '</' + D + '></' + D + '>' : '') +
    '<' + D + ' id="qr-form-' + slot + '" class="qr-mini"></' + D + '>' +
    '<' + D + ' class="qr-code-label" id="bc-code-' + slot + '">' + (token || dev.barcode || '') + '</' + D + '>' +
    '<' + D + ' class="qr-scan-hint">امسح QR من هاتف الموظف لتسجيل IP تلقائياً</' + D + '></' + D + '>';
}

function autoCalcDailyRate() {
  const salaryInput = document.getElementById('emp-salary');
  const halfInput = document.getElementById('emp-salary-half');
  const dailyRateInput = document.getElementById('emp-daily-rate');
  const type = document.getElementById('emp-salary-type')?.value || 'monthly';
  if (!dailyRateInput || dailyRateInput.dataset.manual) return;
  if (type === 'biweekly' && halfInput) {
    const half = parseExactInt(halfInput.value, 0);
    dailyRateInput.value = half > 0 ? calcDailyRateFromSalary(half, 'biweekly') : '';
    return;
  }
  if (salaryInput) {
    const salary = parseExactInt(salaryInput.value, 0);
    dailyRateInput.value = salary > 0 ? calcDailyRateFromSalary(salary, type) : '';
  }
}

function onSalaryTypeChange() {
  const type = document.getElementById('emp-salary-type')?.value || 'monthly';
  const salaryRow = document.getElementById('emp-salary-amount-row');
  const halfField = document.getElementById('emp-biweekly-half-field');
  const commissionNote = document.getElementById('emp-commission-note');
  const salaryInput = document.getElementById('emp-salary');
  if (type === 'commission') {
    if (salaryRow) salaryRow.style.display = 'none';
    if (halfField) halfField.style.display = 'none';
    if (commissionNote) commissionNote.style.display = '';
  } else if (type === 'biweekly') {
    if (salaryRow) salaryRow.style.display = '';
    if (halfField) halfField.style.display = '';
    if (commissionNote) commissionNote.style.display = 'none';
  } else {
    if (salaryRow) salaryRow.style.display = '';
    if (halfField) halfField.style.display = 'none';
    if (commissionNote) commissionNote.style.display = 'none';
  }
  autoCalcDailyRate();
}

function syncEmpOptionCards() {
  ['emp-remote-attend', 'emp-open-hours', 'emp-include-ot'].forEach(id => {
    const input = document.getElementById(id);
    const card = document.getElementById(id + '-card');
    if (input && card) card.classList.toggle('active', input.checked);
  });
}

function onEmpRoleChange() {
  var sel = document.getElementById('emp-role');
  var custom = document.getElementById('emp-role-custom');
  if (!sel || !custom) return;
  var showCustom = sel.value === '__custom__';
  custom.style.display = showCustom ? 'block' : 'none';
  if (!showCustom) custom.value = '';
}

function toggleEmpOptionFromCard(card) {
  const id = card?.dataset?.option;
  const input = id ? document.getElementById(id) : null;
  if (!input) return;
  input.checked = !input.checked;
  syncEmpOptionCards();
}

function isEmpMoneyFieldEmpty(id) {
  var el = document.getElementById(id);
  return !el || String(el.value || '').trim() === '';
}

function getEmpFormRoleFieldId(roleSelectValue) {
  return roleSelectValue === '__custom__' ? 'emp-role-custom' : 'emp-role';
}

function showEmpFormFieldError(fieldId, message) {
  Swal.showValidationMessage(message);
  setTimeout(function () {
    var el = fieldId ? document.getElementById(fieldId) : null;
    if (el) {
      el.focus();
      if (el.scrollIntoView) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, 80);
  return false;
}

function readEmpForm() {
  const name = document.getElementById('emp-name').value.trim();
  const dept = document.getElementById('emp-dept').value;
  const roleSelect = document.getElementById('emp-role');
  const roleSelectValue = roleSelect ? roleSelect.value : '';
  let role = roleSelectValue;
  if (role === '__custom__') {
    role = (document.getElementById('emp-role-custom')?.value || '').trim();
  } else {
    role = (role || '').trim();
  }
  const phone = document.getElementById('emp-phone').value.trim();
  const salaryType = document.getElementById('emp-salary-type')?.value || 'monthly';
  const salaryEmpty = isEmpMoneyFieldEmpty('emp-salary');
  const salaryHalfEmpty = salaryType === 'biweekly' && isEmpMoneyFieldEmpty('emp-salary-half');
  const salary = readMoneyValue('emp-salary', 0);
  const salaryHalf = salaryType === 'biweekly' ? (readMoneyValue('emp-salary-half', 0) || Math.floor(salary / 2)) : 0;
  const dailyRate = salaryType === 'commission' ? 0 : (readMoneyValue('emp-daily-rate', 0) || calcDailyRateFromSalary(salaryType === 'biweekly' ? readMoneyValue('emp-salary-half', 0) : salary, salaryType));
  const days = readMoneyValue('emp-days', 0);
  const lateMin = readMoneyValue('emp-late', 0);
  const checkIn = document.getElementById('emp-checkin').value || '08:00';
  const checkOut = document.getElementById('emp-checkout').value || '17:00';
  const hireDate = (document.getElementById('emp-hire-date')?.value || '').slice(0, 10);
  const ip1 = document.getElementById('emp-ip-1')?.value.trim() || '';
  const ip2 = document.getElementById('emp-ip-2')?.value.trim() || '';
  const fp1 = document.getElementById('emp-fp-1')?.value.trim() || '';
  const fp2 = document.getElementById('emp-fp-2')?.value.trim() || '';

  var fieldIdMap = {
    name: 'emp-name',
    dept: 'emp-dept',
    role: getEmpFormRoleFieldId(roleSelectValue),
    phone: 'emp-phone',
    salary: 'emp-salary',
    salaryHalf: 'emp-salary-half'
  };
  var draft = {
    name: name,
    dept: dept,
    role: role,
    phone: phone,
    salary: salary,
    salaryType: salaryType,
    salaryHalf: salaryHalf,
    _salaryEmpty: salaryEmpty,
    _salaryHalfEmpty: salaryHalfEmpty
  };
  if (typeof KynoValidation !== 'undefined' && KynoValidation.validateEmployee) {
    var check = KynoValidation.validateEmployee(draft);
    if (!check.valid) {
      var firstKey = check.firstField || (check.fieldErrors && Object.keys(check.fieldErrors)[0]);
      var msg = (check.fieldErrors && firstKey && check.fieldErrors[firstKey]) || (check.errors && check.errors[0]) || 'يرجى تعبئة الحقول المطلوبة';
      return showEmpFormFieldError(fieldIdMap[firstKey] || null, msg);
    }
  } else {
    if (!name) return showEmpFormFieldError('emp-name', 'يجب أن تملأ حقل الاسم الكامل');
    if (!dept) return showEmpFormFieldError('emp-dept', 'يجب أن تملأ حقل القسم');
    if (!role) return showEmpFormFieldError(fieldIdMap.role, 'يجب أن تملأ حقل الوظيفة');
    if (!phone) return showEmpFormFieldError('emp-phone', 'يجب أن تملأ حقل الهاتف');
  }

  const remoteAttend = document.getElementById('emp-remote-attend')?.checked || false;
  const openHours = document.getElementById('emp-open-hours')?.checked || false;
  const includeOvertimeInSalary = document.getElementById('emp-include-ot')?.checked || false;
  return { name, dept, role, phone, salary, salaryType, salaryHalf, dailyRate, days, lateMin, checkIn, checkOut, hireDate, ip1, ip2, fp1, fp2, remoteAttend, openHours, includeOvertimeInSalary };
}

function buildEmpDevices(empId, ip1, ip2, prev, fp1, fp2, forceFresh) {
  const p1 = forceFresh ? null : prev?.find(d => d.slot === 1);
  const p2 = forceFresh ? null : prev?.find(d => d.slot === 2);
  const nowIso = new Date().toISOString();
  return [
    {
      slot: 1, label: 'الهاتف الأول', ip: forceFresh ? ip1 : (ip1 || p1?.ip || ''),
      fingerprint: forceFresh ? (fp1 || '') : (fp1 || p1?.fingerprint || ''),
      pin: forceFresh ? '' : (p1?.pin || ''),
      barcode: genBarcode(empId, 1),
      token: forceFresh ? generateDeviceToken() : (p1?.token || generateDeviceToken()),
      tokenCreatedAt: nowIso, tokenUsedAt: '',
      deviceInfo: null, linked_at: '', last_login: ''
    },
    {
      slot: 2, label: 'الهاتف الثاني', ip: forceFresh ? ip2 : (ip2 || p2?.ip || ''),
      fingerprint: forceFresh ? (fp2 || '') : (fp2 || p2?.fingerprint || ''),
      pin: forceFresh ? '' : (p2?.pin || ''),
      barcode: genBarcode(empId, 2),
      token: forceFresh ? generateDeviceToken() : (p2?.token || generateDeviceToken()),
      tokenCreatedAt: nowIso, tokenUsedAt: '',
      deviceInfo: null, linked_at: '', last_login: ''
    }
  ];
}

/** تجهيز QR في السحابة قبل مسح الهاتف (إعادة محاولة) */
async function ensureEmployeeCloudQrReady(emp, options) {
  options = options || {};
  if (!emp) return { ok: false, reason: 'no_employee' };
  normalizeEmployee(emp);
  var slot = options.slot || 1;
  var dev = getDevice(emp, slot);
  if (!dev) return { ok: false, reason: 'no_device' };
  ensureDeviceToken(emp, dev);

  var attempts = Math.max(1, options.retries || 5);
  for (var i = 0; i < attempts; i++) {
    if (typeof sb_pushDeviceTokensForEmployee === 'function') {
      var push = await sb_pushDeviceTokensForEmployee(emp);
      if (push.ok && push.verified) {
        return { ok: true, token: dev.token, slot: dev.slot };
      }
      if (i === attempts - 1) {
        return { ok: false, reason: push.reason || 'verify_failed' };
      }
    }
    await new Promise(function (r) { setTimeout(r, 700 + i * 500); });
  }
  return { ok: false, reason: 'push_unavailable' };
}

async function autoSyncEmployeeToSupabase(emp, retries) {
  if (!emp || typeof sb_upsertEmployee !== 'function') {
    return { ok: false, reason: 'خدمة السحابة غير محمّلة — حدّث الصفحة (Ctrl+F5)' };
  }
  var _lid = typeof KynoLoader !== 'undefined'
    ? KynoLoader.start('حفظ بيانات ' + (emp.name || 'الموظف') + '...')
    : null;
  var attempts = Math.max(1, retries || 5);
  try {
    if (typeof AuthApi !== 'undefined') {
      if (AuthApi.ensureValidSession) await AuthApi.ensureValidSession();
      else if (AuthApi.refreshJwtContext) await AuthApi.refreshJwtContext();
    }
    if (typeof initSupabase === 'function') initSupabase();
    var ready = await ensureSupabaseClient(24);
    if (!ready) {
      return { ok: false, reason: 'تعذّر الاتصال بالسحابة — تحقق من الإنترنت أو انتظر ثوانٍ ثم أعد المحاولة' };
    }
    emp.company_id = getActiveCompanyId(emp);
    if (!emp.company_id) {
      return { ok: false, reason: 'سياق الشركة غير متوفر — أعد تسجيل الدخول' };
    }
    if (emp.dept && typeof sb_ensureDepartment === 'function') {
      var deptReady = await sb_ensureDepartment(emp.dept);
      if (!deptReady) {
        return { ok: false, reason: 'تعذّر تسجيل القسم «' + emp.dept + '» في قاعدة البيانات' };
      }
    }
    for (var i = 0; i < attempts; i++) {
      const saved = await sb_upsertEmployee(emp, { requireExisting: currentUser === 'emp' });
      if (saved) {
        delete emp._pendingRemoteSync;
        delete emp._freshDevices;
        delete emp._devicesPendingSync;
        if (typeof clearEmployeeDeletedLocally === 'function') clearEmployeeDeletedLocally(emp.id);
        emp._remoteSyncedAt = Date.now();
        emp._localEmpEditAt = Date.now();
        if (typeof applyRpcEmployeeSnapshot === 'function') {
          applyRpcEmployeeSnapshot(emp, saved, { forceRemote: true, keepLocalSalary: true });
        } else {
          if (saved.remote_attend != null) emp.remoteAttend = saved.remote_attend === true;
          if (saved.open_hours != null) emp.openHours = saved.open_hours === true;
        }
        if (typeof upsertEmployeeIntoStore === 'function') upsertEmployeeIntoStore(emp);
        if (_lid !== null && typeof KynoLoader !== 'undefined')
          KynoLoader.done(_lid, 'success', 'تمت مزامنة ' + (emp.name || 'الموظف'));
        return { ok: true };
      }
      var errMsg = (typeof sb_getLastEmployeeSaveError === 'function') ? sb_getLastEmployeeSaveError() : '';
      var errLow = String(errMsg || '').toLowerCase();
      if (errLow.indexOf('tenant_mismatch') >= 0 || errLow.indexOf('سياق الشركة') >= 0) {
        var oldId = parseInt(emp.id, 10) || 0;
        var nextGlobal = oldId + 1;
        if (typeof refreshNextEmpIdBeforeAdd === 'function') {
          await refreshNextEmpIdBeforeAdd();
          if (window.nextEmpId && window.nextEmpId > nextGlobal) nextGlobal = window.nextEmpId;
        }
        emp.id = nextGlobal;
        window.nextEmpId = nextGlobal + 1;
        if (emp.devices && emp.devices.length) {
          emp.devices.forEach(function (d) {
            if (d) d.barcode = 'ATT-' + emp.id + '-D' + (d.slot || 1);
          });
        }
        if (typeof upsertEmployeeIntoStore === 'function') upsertEmployeeIntoStore(emp);
        console.warn('autoSyncEmployeeToSupabase: reallocated employee id', oldId, '→', emp.id);
        if (i < attempts - 1) continue;
      }
      if (typeof sb_isPermanentEmployeeSaveError === 'function' && sb_isPermanentEmployeeSaveError(errMsg)) {
        break;
      }
      if (i < attempts - 1) {
        if (_lid !== null && typeof KynoLoader !== 'undefined')
          KynoLoader.update(_lid, 'إعادة محاولة المزامنة... (' + (i + 2) + '/' + attempts + ')');
        await new Promise(function(resolve) { setTimeout(resolve, 900 + (i * 700)); });
      }
    }
    var errMsg = (typeof sb_getLastEmployeeSaveError === 'function') ? sb_getLastEmployeeSaveError() : '';
    console.warn('Supabase employee save failed after retries:', errMsg);
    if (_lid !== null && typeof KynoLoader !== 'undefined')
      KynoLoader.done(_lid, 'error', 'تعذّر مزامنة ' + (emp.name || 'الموظف'));
    return { ok: false, reason: errMsg || 'فشل رفع الموظف إلى السحابة' };
  } catch (e) {
    console.warn('autoSyncEmployeeToSupabase failed:', e);
    if (_lid !== null && typeof KynoLoader !== 'undefined')
      KynoLoader.done(_lid, 'error', 'خطأ في المزامنة');
    return { ok: false, reason: e.message || String(e) };
  }
}

function sanitizeCloudUserText(msg) {
  if (msg == null || msg === '') return msg;
  var s = String(msg);
  s = s.replace(/supabase_integration\.js/gi, 'ملفات النظام');
  s = s.replace(/supabase/gi, 'السحابة');
  s = s.replace(/Schema SQL/gi, 'قاعدة البيانات');
  s = s.replace(/Edge Functions/gi, 'خادم الدخول');
  s = s.replace(/SQL Editor/gi, 'لوحة الإدارة');
  s = s.replace(/migration \d+[^\n]*/gi, 'تواصل مع الدعم الفني لتحديث النظام');
  s = s.replace(/pyxwpwbuwfrzqsnzhxip[^\s]*/gi, '');
  s = s.replace(/\s{2,}/g, ' ').replace(/ — —/g, ' —').trim();
  return s;
}

function describeSupabaseSaveError(msg) {
  if (!msg) return 'تحقق من اتصال الإنترنت على الهاتف وحاول مرة أخرى';
  var m = String(msg).toLowerCase();
  if (m.indexOf('fetch') >= 0 || m.indexOf('network') >= 0 || m.indexOf('failed to fetch') >= 0) {
    return 'الاتصال بالإنترنت ضعيف أو منقطع على الهاتف';
  }
  if (m.indexOf('not initialized') >= 0 || m.indexOf('sdk') >= 0) {
    return 'مكتبة الاتصال لم تُحمّل بعد — حدّث الصفحة';
  }
  if (m.indexOf('verify_failed') >= 0 || m.indexOf('no_tokens') >= 0) {
    return 'رمز QR لم يُرفع للسحابة — افتح «عرض QR» من لوحة الإدارة ثم انتظر «QR جاهز»';
  }
  if (m.indexOf('no_company_context') >= 0) {
    return 'سياق الشركة غير متوفر — سجّل الخروج ثم ادخل مرة أخرى';
  }
  if (m.indexOf('department not found') >= 0 || m.indexOf('departments') >= 0) {
    return 'القسم غير مسجل في السحابة — أعد إضافة الموظف بعد تسجيل الدخول';
  }
  if (m.indexOf('company_id') >= 0 || (m.indexOf('foreign key') >= 0 && m.indexOf('companies') >= 0)) {
    return 'خطأ في ربط الموظف بالشركة — أعد تسجيل الدخول من لوحة الإدارة';
  }
  if (m.indexOf('foreign key') >= 0) {
    return 'خطأ في ربط بيانات الموظف بقاعدة البيانات — تحقق من القسم المختار';
  }
  if (m.indexOf('employee_devices') >= 0 || m.indexOf('device slot') >= 0) {
    return 'تم حفظ الموظف — جارٍ رفع بيانات الجهاز/QR (أعد المحاولة أو افتح «عرض QR»)';
  }
  if (m.indexOf('duplicate') >= 0 || m.indexOf('unique') >= 0) {
    return 'تعارض في رقم الموظف — سيتم إعادة المحاولة تلقائياً';
  }
  if (m.indexOf('employee_limit_reached') >= 0 || m.indexOf('تم الوصول') >= 0) {
    return String(msg);
  }
  if (m.indexOf('subscription_inactive') >= 0 || m.indexOf('الاشتراك غير فعال') >= 0) {
    return String(msg);
  }
  if (m.indexOf('tenant_mismatch') >= 0 || m.indexOf('سياق الشركة') >= 0) {
    return String(msg);
  }
  return sanitizeCloudUserText(String(msg));
}

function describeDeviceLinkError(err) {
  var raw = typeof err === 'string' ? err : ((err && (err.error || err.message || err.code || err.details)) || '');
  var m = String(raw || '').toLowerCase();
  if (!m) return 'تعذّر ربط الجهاز في السحابة — حاول مرة أخرى';
  if (m.indexOf('failed to fetch') >= 0 || m.indexOf('network') >= 0 || m.indexOf('fetch') >= 0) {
    return 'تعذّر الوصول إلى Supabase من الهاتف. تأكد أن الموقع مفتوح على HTTPS وأن Supabase غير محجوب من الشبكة.';
  }
  if (m.indexOf('could not find the function') >= 0 || m.indexOf('pgrst202') >= 0 || m.indexOf('schema cache') >= 0) {
    return 'دالة ربط الجهاز غير موجودة في قاعدة البيانات — أعد تطبيق المايغريشنات أو نفّذ SQL إصلاح RPC.';
  }
  if (m.indexOf('could not choose') >= 0 || m.indexOf('pgrst203') >= 0 || m.indexOf('overload') >= 0) {
    return 'يوجد أكثر من نسخة لدالة ربط الجهاز في قاعدة البيانات — يجب حذف النسخة القديمة من RPC.';
  }
  if (m.indexOf('permission denied') >= 0 || m.indexOf('42501') >= 0) {
    return 'لا توجد صلاحية لتنفيذ دالة ربط الجهاز — راجع GRANT EXECUTE للدالة.';
  }
  if (m.indexOf('subscription_inactive') >= 0) {
    return 'اشتراك الشركة غير فعال — فعّل الاشتراك ثم امسح QR مرة أخرى.';
  }
  if (m.indexOf('rate_limited') >= 0) {
    return 'محاولات كثيرة خلال وقت قصير — انتظر دقائق ثم أعد مسح QR.';
  }
  if (m.indexOf('official_closure_active') >= 0) {
    return 'الرابط معطل حالياً بسبب عطلة رسمية للشركة.';
  }
  if (m.indexOf('device_already_linked') >= 0) {
    return 'هذا QR مرتبط بجهاز آخر مسبقاً.';
  }
  if (m.indexOf('fingerprint_already_used') >= 0 || m.indexOf('fingerprint_ambiguous') >= 0) {
    return 'بصمة هذا المتصفح متشابهة مع جهاز آخر. حدّث الصفحة ثم امسح QR جديداً، أو امسح بصمة الجهاز من لوحة الإدارة ثم أعد الربط.';
  }
  if (m.indexOf('not_found') >= 0 || m.indexOf('invalid_token') >= 0) {
    return 'رمز QR غير منشور أو قديم — افتح عرض QR من الإدارة وانتظر QR جاهز ثم امسح QR جديد.';
  }
  if (m.indexOf('invalid_fingerprint') >= 0) {
    return 'تعذّر إنشاء بصمة الجهاز — حدّث الصفحة وحاول مرة أخرى.';
  }
  return sanitizeCloudUserText(String(raw));
}

function updateOpenEmpDeviceFields(emp) {
  if (!emp) return;
  normalizeEmployee(emp);
  [1, 2].forEach(function(slot) {
    const dev = getDevice(emp, slot);
    const ipInput = document.getElementById('emp-ip-' + slot);
    const fpInput = document.getElementById('emp-fp-' + slot);
    const codeEl = document.getElementById('bc-code-' + slot);
    if (ipInput && dev.ip && ipInput.value !== dev.ip) ipInput.value = dev.ip;
    if (fpInput && dev.fingerprint && fpInput.value !== dev.fingerprint) fpInput.value = dev.fingerprint;
    if (codeEl) codeEl.textContent = dev.token || dev.barcode || '';
  });
}

async function refreshOpenEmpDeviceFields(empId) {
  if (!empId) return;
  try {
    if (typeof sb_refreshEmployeeDevices === 'function') {
      await sb_refreshEmployeeDevices(empId);
    }
    const fresh = employees.find(e => e.id === empId);
    updateOpenEmpDeviceFields(fresh);
  } catch (e) {
    console.warn('refreshOpenEmpDeviceFields failed:', e);
  }
}

async function openEmpForm(mode, id) {
  if (!requireActionPermission('employees', mode === 'edit' ? 'edit' : 'add')) return;
  if (mode === 'add' && !requireSubscription('إضافة موظف جديد')) return;
  if (mode === 'add' && !(await canAddEmployeeUnderCompanyLimit(true))) return;
  const emp = mode === 'edit' ? employees.find(x => x.id === id) : null;
  if (mode === 'edit' && !emp) return;
  Swal.fire({
    title: mode === 'add' ? '➕ إضافة موظف جديد' : '✏️ تعديل بيانات الموظف',
    html: empFormHtml(emp),
    customClass: { popup: 'swal-emp-wide' },
    width: 640,
    confirmButtonText: mode === 'add' ? 'إضافة الموظف' : 'حفظ التعديلات',
    cancelButtonText: 'إلغاء',
    showCancelButton: true,
    ...swalTheme(),
    cancelButtonColor: '#4a5568',
    focusConfirm: false,
    preConfirm: readEmpForm,
    didOpen: () => {
      if (emp) {
        normalizeEmployee(emp);
        setTimeout(() => [1, 2].forEach(s => renderQrCode('qr-form-' + s, getDevice(emp, s).barcode)), 250);
        updateOpenEmpDeviceFields(emp);
        let pulls = 0;
        const pullTimer = setInterval(() => {
          if (!document.getElementById('emp-form-id')) { clearInterval(pullTimer); return; }
          pulls++;
          refreshOpenEmpDeviceFields(emp.id);
          if (pulls >= 20) clearInterval(pullTimer);
        }, 3000);
      }
      setTimeout(function () {
        onSalaryTypeChange(); syncEmpOptionCards(); onEmpRoleChange();
        var dr = document.getElementById('emp-daily-rate');
        if (dr) safeAddEvent(dr, 'input', function () { this.dataset.manual = '1'; });
      }, 100);
    }
  }).then(async r => {
    if (!r.isConfirmed || !r.value) return;
    pauseRemoteSync(30000);
    window.__basmaDisableAutoSync = true;
    const v = r.value;
    let savedEmp = null;
    let newAttRec = null;
    const _prevHireDate = (mode === 'edit' && emp) ? String(emp.hireDate || '').slice(0, 10) : '';
    if (mode === 'add') {
      if (!(await canAddEmployeeUnderCompanyLimit(true))) {
        resumeRemoteSync(0);
        return;
      }
      await refreshNextEmpIdBeforeAdd();
      const newId = nextEmpId++;
      if (typeof clearEmployeeDeletedLocally === 'function') clearEmployeeDeletedLocally(newId);
      employees = (employees || []).filter(function (x) { return !x || Number(x.id) !== newId; });
      attData = (attData || []).filter(function (x) { return !x || Number(x.empId) !== newId; });
      if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(newId);
      companyId = getActiveCompanyId(null);
      if (!companyId) {
        resumeRemoteSync(0);
        nextEmpId--;
        Swal.fire({
          icon: 'error',
          title: 'سياق الشركة غير متوفر',
          text: 'انتهت الجلسة أو company_id غير موجود في JWT — سجّل الخروج ثم ادخل مرة أخرى.',
          ...swalTheme()
        });
        return;
      }
      if (typeof sb_ensureDepartment === 'function') {
        if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
          await AuthApi.ensureValidSession();
        }
        var deptReady = await sb_ensureDepartment(v.dept);
        if (!deptReady) {
          resumeRemoteSync(0);
          var authOk = typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession
            ? await AuthApi.hasAuthenticatedSession()
            : false;
          Swal.fire({
            icon: 'error',
            title: 'تعذّر تجهيز القسم',
            text: authOk
              ? ('لم يتم تسجيل القسم «' + v.dept + '» — أعد تسجيل الدخول أو تواصل مع الدعم الفني')
              : 'انتهت جلسة الدخول — سجّل الخروج ثم ادخل مرة أخرى قبل إضافة الموظف',
            ...swalTheme()
          });
          nextEmpId--;
          return;
        }
      }
      savedEmp = {
        id: newId, name: v.name, dept: v.dept, role: v.role, salary: v.salary, phone: v.phone,
        company_id: companyId,
        avatar: pickAvatar(v.name), avatarClass: pickAvatarClass(newId),
        days: 0, lateMin: 0, salBonus: 0, salStatus: 'معلق', salDeletedPeriod: '',
        checkIn: v.checkIn, checkOut: v.checkOut,
        salaryType: v.salaryType || 'monthly', salaryHalf: v.salaryType === 'biweekly' ? (v.salaryHalf || 0) : 0,
        dailyRate: v.dailyRate || 0,
        remoteAttend: !!v.remoteAttend, openHours: !!v.openHours,
        includeOvertimeInSalary: !!v.includeOvertimeInSalary,
        hireDate: v.hireDate || '',
        active: true,
        devices: buildEmpDevices(newId, v.ip1, v.ip2, null, v.fp1, v.fp2, true),
        _pendingRemoteSync: true,
        _freshDevices: true,
        _addedAt: Date.now(),
        _localEmpEditAt: Date.now(),
        _salaryLockedUntil: Date.now() + 86400000
      };
      if (savedEmp.salaryType !== 'biweekly') {
        savedEmp.salaryHalf = 0;
      }
      normalizeEmployee(savedEmp);
      employees.push(savedEmp);
      newAttRec = createAttRecord(newId, v.dept, v.name);
      newAttRec.company_id = companyId;
      newAttRec._pendingRemoteSync = true;
      newAttRec._addedAt = Date.now();
      attData.push(newAttRec);
    } else {
      const prevDev = emp.devices;
      Object.assign(emp, {
        name: v.name, dept: v.dept, role: v.role, salary: v.salary, phone: v.phone,
        days: v.days, lateMin: v.lateMin, checkIn: v.checkIn, checkOut: v.checkOut,
        salaryType: v.salaryType || 'monthly',
        salaryHalf: v.salaryType === 'biweekly' ? (v.salaryHalf || 0) : 0,
        dailyRate: v.dailyRate || 0,
        remoteAttend: !!v.remoteAttend, openHours: !!v.openHours,
        includeOvertimeInSalary: !!v.includeOvertimeInSalary,
        hireDate: v.hireDate || '',
        avatar: pickAvatar(v.name),
        devices: buildEmpDevices(emp.id, v.ip1, v.ip2, prevDev, v.fp1, v.fp2),
        _localEmpEditAt: Date.now()
      });
      normalizeEmployee(emp);
      savedEmp = emp;
      syncAttForEmployee(emp);
    }
    const _formSalary = parseExactInt(v.salary, savedEmp.salary);
    const _formSalaryHalf = v.salaryType === 'biweekly' ? parseExactInt(v.salaryHalf, 0) : 0;
    const _formSalaryType = v.salaryType || 'monthly';
    const _formDailyRate = parseExactInt(v.dailyRate, 0);
    function _restoreFormSalary(emp) {
      if (!emp) return;
      if (_formSalaryType !== 'commission') {
        emp.salary = _formSalary;
        emp.salaryType = _formSalaryType;
        emp.salaryHalf = _formSalaryType === 'biweekly' ? _formSalaryHalf : 0;
        emp.dailyRate = _formDailyRate || emp.dailyRate;
      }
    }
    _restoreFormSalary(savedEmp);
    saveData();
    const syncResult = await autoSyncEmployeeToSupabase(savedEmp, mode === 'add' ? 25 : 5);
    _restoreFormSalary(savedEmp);
    if (syncResult.ok && typeof applyEmployeeSalaryFromForm === 'function') {
      applyEmployeeSalaryFromForm(savedEmp, v);
      _restoreFormSalary(savedEmp);
      if (typeof sb_upsertEmployee === 'function') {
        try {
          await sb_upsertEmployee(savedEmp, { requireExisting: currentUser === 'emp' });
        } catch (salErr) {
          console.warn('salary resync after add/edit:', salErr);
        }
      }
    }
    var qrReady = { ok: false, reason: syncResult.reason || 'sync_failed' };
    if (syncResult.ok) {
      qrReady = await ensureEmployeeCloudQrReady(savedEmp, { retries: 6, slot: 1 });
    }
    if (newAttRec && typeof sb_upsertAttendance === 'function') {
      try { await sb_upsertAttendance(newAttRec); delete newAttRec._pendingRemoteSync; } catch (e) { console.warn('attendance sync failed:', e); }
    }
    savedEmp._localEmpEditAt = Date.now();
    upsertEmployeeIntoStore(savedEmp);
    saveData();
    if (currentUser !== 'emp') {
      var _newHireDate = String(savedEmp.hireDate || '').slice(0, 10);
      if (_newHireDate && (mode === 'add' || _newHireDate !== _prevHireDate)) {
        try {
          focusAttendanceHireMonth(savedEmp.id);
          var _bf = await backfillHireDateAbsences(savedEmp);
          if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(savedEmp.id);
          if (typeof buildAttendance === 'function') buildAttendance();
          if (typeof buildDashboard === 'function') buildDashboard();
          if (_bf && _bf.created > 0 && typeof BasmaToast !== 'undefined' && BasmaToast.success) {
            BasmaToast.success('تم إنشاء ' + _bf.created + ' سجل غياب قبل تاريخ المباشرة — اعرض «هذا الشهر» في الحضور');
          }
        } catch (e) { console.warn('hire-date absences backfill:', e); }
      }
    }
    refreshAll();
    resumeRemoteSync(30000);
    if (mode === 'add') {
      if (syncResult.ok && qrReady.ok) {
        Swal.fire({
          icon: 'success',
          title: 'تم إضافة الموظف — QR جاهز',
          html: 'تم رفع <b>' + esc(v.name) + '</b> إلى السحابة.<br><span style="font-size:12px;color:var(--text-muted)">يمكن للموظف مسح QR الآن من هاتفه (الهاتف الأول).</span>',
          ...swalTheme(),
          confirmButtonText: 'عرض QR',
          showCancelButton: true,
          cancelButtonText: 'لاحقاً'
        }).then(function (r) {
          if (r.isConfirmed) showEmployeeBarcodes(savedEmp.id);
        });
        logActivity('add', 'employees', 'إضافة موظف: ' + v.name + ' — ' + v.dept, { targetName: v.name });
      } else if (syncResult.ok && !qrReady.ok) {
        scheduleAutoSupabaseSync('employee-add-retry');
        Swal.fire({
          icon: 'warning',
          title: 'تم الحفظ — انتظر قبل مسح QR',
          html: 'الموظف في السحابة لكن <b>رمز QR لم يُفعّل بعد</b>.<br><span style="font-size:12px;color:var(--text-secondary)">' + esc(describeSupabaseSaveError(qrReady.reason)) + '</span><br><span style="font-size:12px;color:var(--text-muted)">من قائمة الموظفين → عرض QR → انتظر ثم امسح من الهاتف.</span>',
          ...swalTheme(),
          confirmButtonText: 'عرض QR الآن'
        }).then(function (r) {
          if (r.isConfirmed) showEmployeeBarcodes(savedEmp.id);
        });
        logActivity('add', 'employees', 'إضافة موظف (QR غير جاهز): ' + v.name, { targetName: v.name });
      } else {
        scheduleAutoSupabaseSync('employee-add-retry');
        var syncHint = describeSupabaseSaveError(syncResult.reason);
        employees = (employees || []).filter(function (x) { return !x || x.id !== savedEmp.id; });
        attData = (attData || []).filter(function (x) { return !x || x.empId !== savedEmp.id; });
        if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(savedEmp.id);
        if (typeof upsertEmployeeIntoStore === 'function') {
          window.employees = employees;
        }
        refreshAll();
        Swal.fire({
          icon: 'error',
          title: 'لم يتم حفظ الموظف',
          html: 'تعذّر حفظ <b>' + esc(v.name) + '</b> في السحابة، لذلك لم يتم اعتماده في النظام.<br><span style="font-size:13px;color:#fc8181">لا يوجد حفظ محلي، وQR لن يعمل حتى يتم الحفظ في قاعدة البيانات.</span><br><span style="font-size:12px;color:var(--text-secondary)">' + esc(syncHint) + '</span>',
          ...swalTheme(),
          confirmButtonText: 'حسناً'
        });
        logActivity('add', 'employees', 'فشل إضافة موظف للسحابة: ' + v.name + ' — ' + v.dept, { targetName: v.name });
      }
    } else {
      Swal.fire({ icon: 'success', title: 'تم حفظ التعديلات', ...swalTheme(), timer: 1800, showConfirmButton: false });
      logActivity('edit', 'employees', 'تعديل بيانات الموظف: ' + v.name, { targetName: v.name });
    }
  });
}

function addEmployee() { openEmpForm('add'); }

function viewEmp(id) {
  const e = employees.find(x => x.id === id);
  if (!e) return;
  normalizeEmployee(e);
  Swal.fire({
    title:e.name, html:`
      <div style="text-align:right;font-family:Cairo,sans-serif;line-height:2.2;font-size:14px">
        <div>📂 <strong>القسم:</strong> ${e.dept}</div>
        <div>💼 <strong>الوظيفة:</strong> ${e.role}</div>
        <div>📱 <strong>الهاتف:</strong> ${e.phone}</div>
        <div>💰 <strong>الراتب:</strong> ${e.salary.toLocaleString()} IQD</div>
        <div>📅 <strong>أيام الحضور:</strong> ${e.days} يوم</div>
        <div>🕐 <strong>الحضور:</strong> ${fmtTimeDisplay(e.checkIn || '08:00')}</div>
        <div>🕔 <strong>الانصراف:</strong> ${fmtTimeDisplay(e.checkOut || '17:00')}</div>
        ${e.remoteAttend ? '<div style="color:#68d391">📍 تسجيل حضور من أي مكان</div>' : ''}
        ${e.openHours ? '<div style="color:#63b3ed">🕐 دوام وقت مفتوح</div>' : ''}
        <div>⏱ <strong>التأخير:</strong> ${e.lateMin} دقيقة</div>
        ${(e.devices||[]).map(d=>'<div style="margin-top:8px;font-size:13px"><strong>'+d.label+'</strong><br>IP: <span style="direction:ltr;color:'+(d.ip?'#68d391':'#fc8181')+'>'+(d.ip||'غير مسجّل')+'</span></div>').join('')}
      </div>
    `,
    ...swalTheme(), confirmButtonText:'إغلاق', showDenyButton:true, denyButtonText:'تعديل', denyButtonColor:'#2563a8',
    showCancelButton:true, cancelButtonText:'عرض QR', cancelButtonColor:'#3182ce'
  }).then(r => { if (r.isDenied) editEmp(id); if (r.dismiss===Swal.DismissReason.cancel) showEmployeeBarcodes(id); });
}

function editEmp(id) { openEmpForm('edit', id); }

function deleteEmp(id) {
  if (!requireActionPermission('employees', 'delete')) return;
  const e = employees.find(x => x.id === id);
  if (!e) return;
  Swal.fire({
    title:'حذف الموظف', text:'هل تريد حذف «' + e.name + '»؟ سيتم حذف سجلاته من القوائم.',
    icon:'warning', showCancelButton:true, confirmButtonText:'نعم، احذف', cancelButtonText:'إلغاء',
    ...swalTheme(), confirmButtonColor:'#e53e3e', cancelButtonColor:'#00d4aa'
  }).then(async r => {
    if (!r.isConfirmed) return;
    pauseRemoteSync(10000);
    try {
      var needsCloudDelete = typeof kynoUseRpcWrites === 'function' && kynoUseRpcWrites();
      if (needsCloudDelete && typeof sb_deleteEmployee !== 'function') {
        resumeRemoteSync(0);
        Swal.fire({ icon:'error', title:'تعذر الحذف', text:'طبقة السحابة غير محمّلة — أعد تحميل الصفحة.', ...swalTheme() });
        return;
      }
      if (typeof sb_deleteEmployee === 'function') {
        const deleted = await sb_deleteEmployee(id);
        if (!deleted) {
          resumeRemoteSync(0);
          var deleteErr = typeof sb_getLastEmployeeDeleteError === 'function' ? sb_getLastEmployeeDeleteError() : '';
          var deleteMsg = typeof mapSbEmployeeDeleteError === 'function'
            ? mapSbEmployeeDeleteError(deleteErr)
            : 'لم يتم حذف الموظف من قاعدة البيانات، لذلك لم أحذفه محلياً حتى لا يرجع مرة أخرى.';
          Swal.fire({ icon:'error', title:'تعذر الحذف من السحابة', text: sanitizeCloudUserText(deleteMsg), ...swalTheme() });
          return;
        }
      } else if (needsCloudDelete) {
        resumeRemoteSync(0);
        Swal.fire({ icon:'error', title:'تعذر الحذف', text:'الحذف يتطلب اتصال السحابة في وضع الإنتاج.', ...swalTheme() });
        return;
      }
    } catch (err) {
      resumeRemoteSync(0);
      console.warn('delete employee failed:', err);
      Swal.fire({ icon:'error', title:'تعذر الحذف', text:'حدث خطأ أثناء حذف الموظف من السحابة.', ...swalTheme() });
      return;
    }
    purgeEmployeeLocalState(id);
    if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(id);
    logActivity('delete', 'employees', 'حذف الموظف: ' + e.name, { targetName: e.name });
    saveData();
    refreshAll();
    Swal.fire({ icon:'success', title:'تم الحذف', text:'تم حذف ' + e.name, ...swalTheme(), timer:2000, showConfirmButton:false });
    resumeRemoteSync(9000);
  });
}

// المرحلة 3 — تفعيل/إيقاف حساب الموظف (لا يحذف أي بيان)
function toggleEmployeeActive(id) {
  if (!requireActionPermission('employees', 'edit')) return;
  const e = employees.find(x => x.id === id);
  if (!e) return;
  const suspend = e.active !== false;
  Swal.fire({
    title: suspend ? 'إيقاف حساب الموظف' : 'تفعيل حساب الموظف',
    html: suspend
      ? 'سيتم إيقاف «' + esc(e.name) + '».<br>لن يتمكن من الدخول أو تسجيل الحضور/الانصراف.<br><span style="font-size:12px;color:var(--text-muted)">لن يُحذف أي بيان ويبقى ظاهراً في التقارير.</span>'
      : 'سيتم تفعيل «' + esc(e.name) + '» وإرجاع العمل طبيعياً.',
    icon: 'warning', showCancelButton: true,
    confirmButtonText: suspend ? 'نعم، أوقف الحساب' : 'نعم، فعّل الحساب',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: suspend ? '#e53e3e' : '#00d4aa'
  }).then(async r => {
    if (!r.isConfirmed) return;
    if (typeof sb_setEmployeeActive !== 'function') {
      Swal.fire({ icon:'error', title:'غير متاح', text:'طبقة السحابة غير محمّلة — أعد تحميل الصفحة.', ...swalTheme() });
      return;
    }
    pauseRemoteSync(8000);
    var res;
    try {
      res = await sb_setEmployeeActive(id, !suspend);
    } catch (err) {
      res = { ok: false, error: String(err && err.message || err) };
    }
    if (!res || res.ok !== true) {
      resumeRemoteSync(0);
      var msg = res && res.error === 'tenant_mismatch'
        ? 'لا تملك صلاحية تعديل هذا الموظف.'
        : 'تعذّر تحديث حالة الحساب في السحابة — تحقق من الاتصال ثم أعد المحاولة.';
      Swal.fire({ icon:'error', title:'تعذّر التحديث', text: msg, ...swalTheme() });
      return;
    }
    e.active = !suspend;
    e._localEmpEditAt = Date.now();
    logActivity('update', 'employees', (suspend ? 'إيقاف حساب الموظف: ' : 'تفعيل حساب الموظف: ') + e.name, { targetName: e.name });
    saveData();
    refreshAll();
    Swal.fire({ icon:'success', title: suspend ? 'تم إيقاف الحساب' : 'تم تفعيل الحساب', text: e.name, ...swalTheme(), timer:1800, showConfirmButton:false });
    resumeRemoteSync(7000);
  });
}


function downloadSalary() {
  const emp = getLoggedInEmp();
  if (!emp) {
    Swal.fire({ icon:'warning', title:'لا يوجد موظف محدد', ...swalTheme() });
    return;
  }
  const sal = calcEmpSalary(emp);
  const headers = ['الموظف','القسم','الراتب الأساسي','السلف','الخصومات','الإجازات/الغياب','المكافآت','الصافي','الحالة'];
  const rows = [[
    emp.name,
    emp.dept || '—',
    (sal.baseSalary || 0).toLocaleString() + ' IQD',
    (sal.loanDeduct || 0).toLocaleString() + ' IQD',
    (sal.manualDeduct || 0).toLocaleString() + ' IQD',
    ((sal.leaveDeduct || 0) + (sal.absentDeduct || 0)).toLocaleString() + ' IQD',
    (sal.bonus || 0).toLocaleString() + ' IQD',
    (sal.final != null ? sal.final : 0).toLocaleString() + ' IQD',
    emp.salStatus || 'معلق'
  ]];
  const html = buildPrintPage('كشف راتب الموظف', esc(emp.name) + ' — ' + esc(emp.dept || '—'), headers, rows, 'table{min-width:560px}');
  Swal.fire({
    title: 'كشف راتب الموظف',
    html: '<div style="text-align:right;line-height:2">' +
      '<div><b>الموظف:</b> ' + esc(emp.name) + '</div>' +
      '<div><b>الراتب الأساسي:</b> ' + (sal.baseSalary || 0).toLocaleString() + ' IQD</div>' +
      '<div><b>السلف:</b> ' + (sal.loanDeduct || 0).toLocaleString() + ' IQD</div>' +
      '<div><b>الخصومات/الغرامات:</b> ' + (sal.manualDeduct || 0).toLocaleString() + ' IQD</div>' +
      '<div><b>الإجازات والغياب:</b> ' + ((sal.leaveDeduct || 0) + (sal.absentDeduct || 0)).toLocaleString() + ' IQD</div>' +
      '<div><b>المكافآت:</b> ' + (sal.bonus || 0).toLocaleString() + ' IQD</div>' +
      '<hr style="border-color:var(--border);opacity:.4"><div style="font-size:18px"><b>الصافي:</b> ' + salaryNetInlineHtml(sal.final, false) + '</div>' +
    '</div>',
    showDenyButton: true,
    showCancelButton: true,
    confirmButtonText: 'معاينة / تحميل PDF',
    denyButtonText: 'إغلاق',
    cancelButtonText: 'إلغاء',
    ...swalTheme()
  }).then(function (r) {
    if (r.isConfirmed) {
      presentPdfActions(html, 'كشف_راتب_' + String(emp.name || 'employee').replace(/\s+/g, '_') + '_' + new Date().toISOString().slice(0, 10) + '.pdf');
    }
  });
}

function addSalaryRecord() {
  const emp = getLoggedInEmp();
  if (!emp) return;
  const salaryType = emp.salaryType || 'monthly';
  const isComm = salaryType === 'commission';
  const isBiw = salaryType === 'biweekly';
  const months = ['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
  const now = new Date();
  const currentMonth = months[now.getMonth()] + ' ' + now.getFullYear();

  // Default date range
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const defFrom = y + '-' + m + '-01';
  const defTo = y + '-' + m + '-' + String(new Date(y, now.getMonth() + 1, 0).getDate()).padStart(2, '0');

  const typeLabel = isComm ? '💰 عمولة' : (isBiw ? '📅 كل ' + getBiweeklyPeriodDays() + ' يوم' : '📋 شهري');
  const salCalc = calcEmpSalary(emp);
  const baseVal = isComm ? 0 : salCalc.baseSalary;

  let html = '<div style="text-align:right">' +
    '<div style="margin-bottom:8px;padding:8px 12px;background:rgba(99,179,237,0.1);border:1px solid rgba(99,179,237,0.2);border-radius:8px;font-size:13px;color:#63b3ed;font-weight:700">نوع الراتب: ' + typeLabel + '</div>' +
    '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الشهر</label>' +
    '<input type="text" id="sal-rec-month" class="setting-input" style="width:100%" value="' + currentMonth + '"></div>' +
    '<div style="display:flex;gap:10px;margin-bottom:10px">' +
    '<div style="flex:1"><label style="font-size:13px;display:block;margin-bottom:4px">من تاريخ</label>' +
    '<input type="date" id="sal-rec-from" class="setting-input" style="width:100%" value="' + defFrom + '"></div>' +
    '<div style="flex:1"><label style="font-size:13px;display:block;margin-bottom:4px">إلى تاريخ</label>' +
    '<input type="date" id="sal-rec-to" class="setting-input" style="width:100%" value="' + defTo + '"></div></div>' +
    '<div id="sal-rec-attend-summary" style="margin-bottom:10px;padding:10px;background:rgba(104,211,145,0.08);border:1px solid rgba(104,211,145,0.2);border-radius:8px;font-size:13px;color:#68d391"></div>';

  if (isComm) {
    html += '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">مبلغ العمولة (IQD)</label>' +
      '<input type="number" id="sal-rec-base" class="setting-input" style="width:100%" value="0" placeholder="أدخل مبلغ العمولة"></div>' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الخصومات</label>' +
      '<input type="number" id="sal-rec-deduct" class="setting-input" style="width:100%" value="0"></div>';
  } else {
    html += '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الراتب الأساسي (IQD)</label>' +
      '<input type="number" id="sal-rec-base" class="setting-input" style="width:100%" value="' + (parseInt(baseVal) || 0) + '"></div>' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الإضافي</label>' +
      '<input type="number" id="sal-rec-ot" class="setting-input" style="width:100%" value="0"></div>' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الخصومات</label>' +
      '<input type="number" id="sal-rec-deduct" class="setting-input" style="width:100%" value="0"></div>';
  }

  html += '<div><label style="font-size:13px;display:block;margin-bottom:4px">الحالة</label>' +
    '<select id="sal-rec-status" class="setting-input" style="width:100%"><option>مدفوع</option><option>معلق</option><option>مرفوض</option></select></div></div>';

  Swal.fire({
    title: '➕ إضافة سجل راتب',
    html: html,
    confirmButtonText: 'إضافة',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    width: 560,
    ...swalTheme(),
    didOpen: () => {
      // Auto-calculate attendance summary when date changes
      const calcSummary = () => {
        const fromVal = document.getElementById('sal-rec-from')?.value;
        const toVal = document.getElementById('sal-rec-to')?.value;
        const summaryEl = document.getElementById('sal-rec-attend-summary');
        if (!fromVal || !toVal || !summaryEl) { if (summaryEl) summaryEl.innerHTML = 'حدد التاريخ لحساب الحضور'; return; }

        const fromDate = new Date(fromVal + 'T00:00:00');
        const toDate = new Date(toVal + 'T23:59:59');
        const empAtts = attData.filter(r => r.empId === emp.id);
        let attendDays = 0;
        let lateDays = 0;
        let absentDays = 0;
        let totalLateMin = 0;
        let totalOvertimeMin = 0;
        empAtts.forEach(r => {
          if (!r.date) return;
          const rDate = new Date(r.date.replace(/\//g, '-') + 'T00:00:00');
          if (rDate >= fromDate && rDate <= toDate) {
            const hasCi = r.ci && r.ci !== '—';
            const hasCo = r.co && r.co !== '—';
            if (hasCi && hasCo) {
              attendDays++;
              if (!emp.openHours && hasCi && hasCo) {
                let lateMin = calcAttendanceShortMinutes(emp, r);
                if (lateMin > 0) { lateDays++; totalLateMin += lateMin; }
              }
              if (!emp.openHours) totalOvertimeMin += parseDurationMinutes(r.ot);
            } else if (r.status === 'غياب') {
              absentDays++;
            }
          }
        });

        const totalDays = Math.max(1, Math.round((toDate - fromDate) / (1000 * 60 * 60 * 24)) + 1);
        const absentDaysTotal = emp.openHours ? 0 : Math.max(0, totalDays - attendDays - absentDays);
        const daily = getEmpDailyRate(emp);
        const autoLateDeduct = calcLateDeductAmount(emp, totalLateMin, daily);
        const autoAbsentDeduct = (isComm || emp.openHours) ? 0 : Math.round((absentDays + absentDaysTotal) * daily);
        const autoDeduct = autoLateDeduct + autoAbsentDeduct;
        const autoOt = (isComm || emp.openHours) ? 0 : Math.round((totalOvertimeMin / 60) * (appSettings.overtimeHourlyRate || 30000));

        summaryEl.innerHTML = '<div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px">' +
          '<span>📅 المدة: <b>' + totalDays + '</b> يوم</span>' +
          '<span>✅ الحضور: <b>' + attendDays + '</b> يوم</span>' +
          '<span>🟡 نقص الدوام: <b>' + lateDays + '</b> يوم</span>' +
          '<span>🔴 الغياب: <b>' + (absentDays + absentDaysTotal) + '</b> يوم</span>' +
          (emp.openHours ? '<span style="color:#63b3ed">🕐 دوام مفتوح: لا تأخير/انصراف مبكر</span>' : '') +
          '</div>' +
          (!isComm ? '<div style="margin-top:6px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px">' +
          '<span style="color:#fc8181">خصم نقص دوام: <b>' + autoLateDeduct.toLocaleString() + '</b></span>' +
          '<span style="color:#fc8181">خصم غياب: <b>' + autoAbsentDeduct.toLocaleString() + '</b></span>' +
          '<span style="color:#63b3ed">إضافي: <b>' + autoOt.toLocaleString() + '</b></span></div>' : '');

        // Auto-fill deduct and ot fields
        const deductInput = document.getElementById('sal-rec-deduct');
        const otInput = document.getElementById('sal-rec-ot');
        if (deductInput && !deductInput.dataset.manual) deductInput.value = autoDeduct;
        if (otInput && !otInput.dataset.manual) otInput.value = autoOt;
      };

      setTimeout(calcSummary, 200);
      safeAddEvent(document.getElementById('sal-rec-from'), 'change', calcSummary);
      safeAddEvent(document.getElementById('sal-rec-to'), 'change', calcSummary);
      // Mark fields as manual if user edits them
      safeAddEvent(document.getElementById('sal-rec-deduct'), 'input', function () { this.dataset.manual = '1'; });
      safeAddEvent(document.getElementById('sal-rec-ot'), 'input', function () { this.dataset.manual = '1'; });
    },
    preConfirm: () => {
      const month = document.getElementById('sal-rec-month')?.value.trim();
      const base = parseInt(document.getElementById('sal-rec-base')?.value) || 0;
      const ot = isComm ? 0 : (parseInt(document.getElementById('sal-rec-ot')?.value) || 0);
      const deduct = parseInt(document.getElementById('sal-rec-deduct')?.value) || 0;
      const status = document.getElementById('sal-rec-status')?.value || 'مدفوع';
      const fromDate = document.getElementById('sal-rec-from')?.value || '';
      const toDate = document.getElementById('sal-rec-to')?.value || '';
      if (!month) { Swal.showValidationMessage('أدخل اسم الشهر'); return false; }
      var monthIso = fromDate ? String(fromDate).slice(0, 7) : salaryPeriodKey(emp.salaryType || 'monthly');
      return { month, monthIso, month_iso: monthIso, base, ot, deduct, final: base + ot - deduct, net: base + ot - deduct, status, fromDate, toDate };
    }
  }).then(async result => {
    if (result.isConfirmed && result.value) {
      if (!emp.salaryHistoryData) emp.salaryHistoryData = [];
      pauseRemoteSync(8000);
      let rec = { id: Date.now(), ...result.value };
      if (typeof sb_upsertSalaryRecord === 'function') {
        const saved = await sb_upsertSalaryRecord(emp.id, rec);
        if (saved) rec = { ...rec, ...saved };
      }
      emp.salaryHistoryData.unshift(rec);
      saveData();
      buildEmpPortal();
      Swal.fire({ icon: 'success', title: 'تم إضافة السجل', ...swalTheme(), timer: 1500, showConfirmButton: false });
      resumeRemoteSync(7000);
    }
  });
}

function editSalaryRecord(idx) {
  if (!requireActionPermission('salaries', 'edit')) return;
  const emp = getLoggedInEmp();
  if (!emp || !emp.salaryHistoryData || !emp.salaryHistoryData[idx]) return;
  const rec = emp.salaryHistoryData[idx];
  Swal.fire({
    title: '✏️ تعديل سجل راتب',
    html: '<div style="text-align:right">' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الشهر</label>' +
      '<input type="text" id="sal-edit-month" class="setting-input" style="width:100%" value="' + rec.month + '"></div>' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الراتب الأساسي</label>' +
      '<input type="number" id="sal-edit-base" class="setting-input" style="width:100%" value="' + (parseInt(rec.base) || 0) + '"></div>' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الإضافي</label>' +
      '<input type="number" id="sal-edit-ot" class="setting-input" style="width:100%" value="' + (parseInt(rec.ot) || 0) + '"></div>' +
      '<div style="margin-bottom:10px"><label style="font-size:13px;display:block;margin-bottom:4px">الخصومات</label>' +
      '<input type="number" id="sal-edit-deduct" class="setting-input" style="width:100%" value="' + (parseInt(rec.deduct) || 0) + '"></div>' +
      '<div><label style="font-size:13px;display:block;margin-bottom:4px">الحالة</label>' +
      '<select id="sal-edit-status" class="setting-input" style="width:100%"><option' + (rec.status === 'مدفوع' ? ' selected' : '') + '>مدفوع</option><option' + (rec.status === 'معلق' ? ' selected' : '') + '>معلق</option><option' + (rec.status === 'مرفوض' ? ' selected' : '') + '>مرفوض</option></select></div></div>',
    confirmButtonText: 'حفظ',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: () => {
      const month = document.getElementById('sal-edit-month')?.value.trim();
      const base = parseInt(document.getElementById('sal-edit-base')?.value) || 0;
      const ot = parseInt(document.getElementById('sal-edit-ot')?.value) || 0;
      const deduct = parseInt(document.getElementById('sal-edit-deduct')?.value) || 0;
      const status = document.getElementById('sal-edit-status')?.value || 'مدفوع';
      if (!month) { Swal.showValidationMessage('أدخل اسم الشهر'); return false; }
      return { month, base, ot, deduct, net: base + ot - deduct, status };
    }
  }).then(async result => {
    if (result.isConfirmed && result.value) {
      pauseRemoteSync(8000);
      emp.salaryHistoryData[idx] = { ...emp.salaryHistoryData[idx], ...result.value };
      if (typeof sb_upsertSalaryRecord === 'function') {
        const saved = await sb_upsertSalaryRecord(emp.id, emp.salaryHistoryData[idx]);
        if (saved) emp.salaryHistoryData[idx] = { ...emp.salaryHistoryData[idx], ...saved };
      }
      saveData();
      buildEmpPortal();
      Swal.fire({ icon: 'success', title: 'تم تعديل السجل', ...swalTheme(), timer: 1500, showConfirmButton: false });
      resumeRemoteSync(7000);
    }
  });
}

function deleteSalaryRecord(idx) {
  if (!requireActionPermission('salaries', 'delete')) return;
  const emp = getLoggedInEmp();
  if (!emp || !emp.salaryHistoryData || !emp.salaryHistoryData[idx]) return;
  const rec = emp.salaryHistoryData[idx];
  Swal.fire({
    title: '🗑️ حذف سجل راتب',
    html: 'هل تريد حذف سجل راتب <b>' + rec.month + '</b>؟<br>هذا الإجراء لا يمكن التراجع عنه.',
    icon: 'warning',
    confirmButtonText: 'نعم، حذف',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#e53e3e'
  }).then(async result => {
    if (result.isConfirmed) {
      pauseRemoteSync(8000);
      if (typeof sb_deleteSalaryRecord === 'function') {
        const deleted = await sb_deleteSalaryRecord(emp.id, rec);
        if (!deleted) {
          resumeRemoteSync(0);
          Swal.fire({ icon:'error', title:'تعذر حذف سجل الراتب من السحابة', text:'لم يتم حذفه محلياً حتى لا يرجع مرة أخرى.', ...swalTheme() });
          return;
        }
      }
      emp.salaryHistoryData.splice(idx, 1);
      saveData();
      buildEmpPortal();
      Swal.fire({ icon: 'success', title: 'تم حذف السجل', ...swalTheme(), timer: 1500, showConfirmButton: false });
      resumeRemoteSync(7000);
    }
  });
}

// exportAttExcel and exportAttPdf are defined above

// ======= Local cache maintenance =======
function listTenantStorageKeys(companyId) {
  var keys = [];
  var base = STORAGE_KEY || 'attendance_system_data';
  var cid = companyId != null ? parseInt(companyId, 10) : null;
  try {
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (!k) continue;
      if (k === base) keys.push(k);
      if (cid && k === base + '_c_' + cid) keys.push(k);
      if (!cid && k.indexOf(base + '_c_') === 0) keys.push(k);
    }
  } catch (e) { /* ignore */ }
  return keys;
}

function clearTenantBrowserCaches(options) {
  options = options || {};
  var cid = null;
  try { cid = safeActiveCompanyId(); } catch (e) { /* ignore */ }
  var keys = listTenantStorageKeys(options.allTenants ? null : cid);
  keys.forEach(function (k) {
    try { localStorage.removeItem(k); } catch (e) { /* ignore */ }
  });
  if (options.clearEmployeeSession !== false && typeof clearRegisteredDeviceCache === 'function') {
    clearRegisteredDeviceCache();
    try { delete window.__basmaEmpSession; } catch (e) { /* ignore */ }
  }
  if (options.clearTombstones !== false) {
    window.__basmaDeletedEmpIds = {};
  }
  _salaryPreviewCache = {};
  try {
    localStorage.removeItem('basma_platform_announcements_cache');
    localStorage.removeItem('basma_platform_announcements_cache_at');
    if (options.clearDismissedAnnouncements) {
      Object.keys(localStorage).forEach(function (k) {
        if (k.indexOf('basma_platform_ann_dismiss_') === 0) localStorage.removeItem(k);
      });
    }
  } catch (e) { /* ignore */ }
  window.__basmaSuppressRealtimeUntil = 0;
  if (options.clearMemory !== false) {
    employees = [];
    attData = [];
    window.leavesData = [];
    nextEmpId = 1;
    window.employees = employees;
    window.attData = attData;
    window.nextEmpId = nextEmpId;
  }
}

function requireCompanyTenantForMaintenance() {
  if (saasCurrentUser && saasCurrentUser.role === 'super_admin') {
    Swal.fire({ icon: 'info', title: 'غير متاح', text: 'صيانة البيانات المحلية مخصّصة لحسابات الشركات — سجّل دخول مدير الشركة.', ...swalTheme() });
    return false;
  }
  if (!saasCurrentUser || !saasCurrentUser.company_id) {
    Swal.fire({ icon: 'warning', title: 'لا توجد شركة', text: 'يجب تسجيل الدخول كمدير شركة.', ...swalTheme() });
    return false;
  }
  return true;
}

async function forceRefreshTenantData() {
  if (!requireActionPermission('settings', 'edit')) return;
  if (!requireCompanyTenantForMaintenance()) return;
  if (typeof syncFromSupabase !== 'function') {
    Swal.fire({ icon: 'warning', title: 'السحابة غير مفعّل', ...swalTheme() });
    return;
  }
  var companyLabel = saasCurrentUser.company_name || ('شركة #' + saasCurrentUser.company_id);
  var confirm = await Swal.fire({
    icon: 'question',
    title: 'تحديث البيانات من السيرفر',
    html: 'سيتم <b>مسح النسخة المحلية</b> لـ «' + esc(companyLabel) + '» ثم جلب الموظفين والحضور من السحابة.<br><span style="font-size:12px;color:var(--text-muted)">يُفضّل بعد حذف/إعادة إضافة موظف لإزالة البيانات القديمة المخزّنة في المتصفح.</span>',
    showCancelButton: true,
    confirmButtonText: 'نعم، حدّث',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#3182ce'
  });
  if (!confirm.isConfirmed) return;
  pauseRemoteSync(60000);
  Swal.fire({ title: '⏳ جارٍ التحديث...', text: 'جلب بيانات ' + companyLabel + ' من السحابة', allowOutsideClick: false, didOpen: function () { Swal.showLoading(); }, ...swalTheme() });
  try {
    clearTenantBrowserCaches({ clearMemory: true, clearEmployeeSession: false, clearTombstones: true });
    var ok = await syncFromSupabase({ forceRemote: true, reason: 'force-refresh', keepDisableAutoSync: true });
    if (typeof refreshNextEmpIdBeforeAdd === 'function') {
      await refreshNextEmpIdBeforeAdd();
    }
    if (typeof refreshAll === 'function') refreshAll();
    if (ok === false) {
      console.error('SOFT ERROR:', 'تعذّر الاتصال بالسحابة');
      Swal.fire({ icon: 'error', title: 'فشل التحديث', text: 'تعذّر الاتصال بالسحابة', ...swalTheme() });
      return;
    }
    Swal.fire({
      icon: 'success',
      title: 'تم تحديث البيانات',
      html: 'تم جلب <b>' + employees.length + '</b> موظف و <b>' + attData.length + '</b> سجل حضور من السيرفر.',
      ...swalTheme(),
      timer: 3500,
      showConfirmButton: false
    });
    if (typeof sbCheckConnection === 'function') sbCheckConnection();
  } catch (e) {
    Swal.fire({ icon: 'error', title: 'فشل التحديث', text: sanitizeCloudUserText(e.message || String(e)), ...swalTheme() });
  } finally {
    resumeRemoteSync(5000);
  }
}

async function strongClearBrowserCache() {
  if (!requireActionPermission('settings', 'edit')) return;
  if (!requireCompanyTenantForMaintenance()) return;
  var companyLabel = saasCurrentUser.company_name || ('شركة #' + saasCurrentUser.company_id);
  var confirm = await Swal.fire({
    icon: 'warning',
    title: 'مسح كاش المتصفح (قوي)',
    html: '<div style="text-align:right;font-size:14px;line-height:2">' +
      'سيتم حذف <b>كل البيانات المحلية</b> لـ «' + esc(companyLabel) + '» من المتصفح:<br>' +
      '• الموظفون والحضور المحفوظ محلياً<br>' +
      '• كاش الرواتب والإعلانات<br>' +
      '• سجلات الحذف المؤقتة (tombstones)<br>' +
      '• جلسات الموظف على هذا الجهاز<br><br>' +
      '<span style="font-size:12px;color:var(--accent)">جلسة الإدارة تبقى — ستُعاد تحميل الصفحة تلقائياً.</span></div>',
    showCancelButton: true,
    confirmButtonText: 'نعم، امسح وأعد التحميل',
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    confirmButtonColor: '#dd6b20'
  });
  if (!confirm.isConfirmed) return;
  try {
    clearTenantBrowserCaches({
      clearMemory: true,
      clearEmployeeSession: true,
      clearTombstones: true,
      clearDismissedAnnouncements: true
    });
    try {
      Object.keys(sessionStorage || {}).forEach(function (k) {
        if (k.indexOf('basma') >= 0 || k.indexOf('attendance') >= 0) sessionStorage.removeItem(k);
      });
    } catch (e) { /* ignore */ }
    if (typeof caches !== 'undefined' && caches.keys) {
      var names = await caches.keys();
      await Promise.all(names.map(function (n) { return caches.delete(n); }));
    }
    saveData();
    await Swal.fire({
      icon: 'success',
      title: 'تم مسح الكاش',
      text: 'سيتم إعادة تحميل الصفحة الآن...',
      ...swalTheme(),
      timer: 1400,
      showConfirmButton: false
    });
    window.location.reload();
  } catch (e) {
    Swal.fire({ icon: 'error', title: 'فشل مسح الكاش', text: sanitizeCloudUserText(e.message || String(e)), ...swalTheme() });
  }
}

// ======= Supabase UI Helpers =======
async function sbCheckConnection() {
  const dot = document.getElementById('sb-status-dot');
  const msg = document.getElementById('sb-status-msg');
  if (!dot || !msg) return;
  if (typeof _sbClient === 'undefined' || !_sbClient) {
    dot.style.background = '#718096';
    msg.textContent = '⚠️ السحابة غير مهيّأ — تحقق من الاتصال بالإنترنت';
    return;
  }
  try {
    const { error } = await _sbClient.from('app_settings').select('key').limit(1);
    if (error) {
      console.error('SOFT ERROR:', error.message || error);
      dot.style.background = '#fc8181';
      msg.textContent = '❌ تعذّر الاتصال: ' + sanitizeCloudUserText(error.message || 'خطأ غير معروف') + ' — تحقق من الإنترنت وقاعدة البيانات';
      return;
    }
    dot.style.background = '#68d391';
    msg.textContent = '✅ متصل بالسحابة';
  } catch(e) {
    dot.style.background = '#fc8181';
    msg.textContent = '❌ تعذّر الاتصال: ' + sanitizeCloudUserText(e.message || 'خطأ غير معروف') + ' — تحقق من الإنترنت وقاعدة البيانات';
  }
}

async function sbPushData() {
  if (saasCurrentUser && saasCurrentUser.role === 'super_admin') {
    Swal.fire({ icon:'info', title:'غير متاح', text:'مزامنة السحابة مخصّصة لحسابات الشركات فقط — سجّل دخول مدير الشركة.', ...swalTheme() });
    return;
  }
  if (!saasCurrentUser || !saasCurrentUser.company_id) {
    Swal.fire({ icon:'warning', title:'لا توجد شركة', text:'يجب تسجيل الدخول كمدير شركة لاستخدام المزامنة.', ...swalTheme() });
    return;
  }
  if (typeof syncToSupabase !== 'function') {
    Swal.fire({ icon:'warning', title:'السحابة غير مفعّل', text:'تحقق من تحميل ملفات النظام', ...swalTheme() });
    return;
  }
  var companyLabel = saasCurrentUser.company_name || ('شركة #' + saasCurrentUser.company_id);
  Swal.fire({ title:'⏳ جارٍ الرفع...', text:'يتم رفع بيانات ' + companyLabel + ' إلى السحابة', allowOutsideClick:false, didOpen:()=>Swal.showLoading(), ...swalTheme() });
  try {
    await syncToSupabase();
    Swal.fire({ icon:'success', title:'✅ تم الرفع بنجاح', text:'تم رفع ' + employees.length + ' موظف و ' + attData.length + ' سجل حضور', ...swalTheme(), timer:3000, showConfirmButton:false });
    sbCheckConnection();
  } catch(e) {
    Swal.fire({ icon:'error', title:'خطأ في الرفع', text: sanitizeCloudUserText(e.message || String(e)), ...swalTheme() });
  }
}

async function sbPullData() {
  if (saasCurrentUser && saasCurrentUser.role === 'super_admin') {
    Swal.fire({ icon:'info', title:'غير متاح', text:'مزامنة السحابة مخصّصة لحسابات الشركات فقط — سجّل دخول مدير الشركة.', ...swalTheme() });
    return;
  }
  if (!saasCurrentUser || !saasCurrentUser.company_id) {
    Swal.fire({ icon:'warning', title:'لا توجد شركة', text:'يجب تسجيل الدخول كمدير شركة لاستخدام المزامنة.', ...swalTheme() });
    return;
  }
  if (typeof syncFromSupabase !== 'function') {
    Swal.fire({ icon:'warning', title:'السحابة غير مفعّل', text:'تحقق من تحميل ملفات النظام', ...swalTheme() });
    return;
  }
  var companyLabel = saasCurrentUser.company_name || ('شركة #' + saasCurrentUser.company_id);
  const r = await Swal.fire({
    icon:'question', title:'جلب البيانات من السحابة',
    text:'سيتم استبدال البيانات المحلية لـ «' + companyLabel + '» بالبيانات المخزّنة في السحابة. هل أنت متأكد؟',
    showCancelButton:true, confirmButtonText:'نعم، اجلب', cancelButtonText:'إلغاء',
    ...swalTheme(), confirmButtonColor:'#2563a8'
  });
  if (!r.isConfirmed) return;
  Swal.fire({ title:'⏳ جارٍ الجلب...', allowOutsideClick:false, didOpen:()=>Swal.showLoading(), ...swalTheme() });
  try {
    await syncFromSupabase();
    Swal.fire({ icon:'success', title:'✅ تم الجلب بنجاح', text:'تم تحميل ' + employees.length + ' موظف و ' + attData.length + ' سجل حضور', ...swalTheme(), timer:3000, showConfirmButton:false });
  } catch(e) {
    Swal.fire({ icon:'error', title:'خطأ في الجلب', text: sanitizeCloudUserText(e.message || String(e)), ...swalTheme() });
  }
}

if (typeof window !== 'undefined') {
  window.mergeLocalPendingEmployees = mergeLocalPendingEmployees;
  window.mergeRemoteEmployeesWithLocal = mergeRemoteEmployeesWithLocal;
  window.fmtTimeDisplay = fmtTimeDisplay;
  window.formatWorkHoursDisplay = formatWorkHoursDisplay;
  window.calcAttendanceWorkHours = calcAttendanceWorkHours;
  window.syncAttendanceRecordHours = syncAttendanceRecordHours;
  window.formatEmployeeFinanceNotificationBody = formatEmployeeFinanceNotificationBody;
  window.refreshEmployeeDevicesUi = refreshEmployeeDevicesUi;
  window.updatePendingSyncBadge = updatePendingSyncBadge;
  window.purgeEmployeeLocalState = purgeEmployeeLocalState;
  window.filterAttendanceForEmployees = filterAttendanceForEmployees;
  window.filterRecentlyDeletedEmployees = filterRecentlyDeletedEmployees;
  window.isEmployeeRecentlyDeleted = isEmployeeRecentlyDeleted;
  window.clearEmployeeDeletedLocally = clearEmployeeDeletedLocally;
  window.clearSalaryCacheForEmployee = clearSalaryCacheForEmployee;
  window.syncSalaryAfterAttendanceChange = syncSalaryAfterAttendanceChange;
  window.getBillableLateMinutes = getBillableLateMinutes;
  window.refreshSalaryUiAfterPayrollChange = refreshSalaryUiAfterPayrollChange;
  window.prefetchSalaryPreviews = prefetchSalaryPreviews;
  window.clearTenantBrowserCaches = clearTenantBrowserCaches;
  window.sanitizeCloudUserText = sanitizeCloudUserText;
  window.forceRefreshTenantData = forceRefreshTenantData;
  window.strongClearBrowserCache = strongClearBrowserCache;
  window.refreshEmployeeClientProfileById = refreshEmployeeClientProfileById;
  window.refreshLoggedInEmployeeFromServer = refreshLoggedInEmployeeFromServer;
  window.refreshLoggedInEmployeeAttendance = refreshLoggedInEmployeeAttendance;
  window.getEmpPortalAttendanceRows = getEmpPortalAttendanceRows;
  window.fetchAllEmployeeAttendanceFromCloud = fetchAllEmployeeAttendanceFromCloud;
  window.mergeAttendanceRangeFromCloud = mergeAttendanceRangeFromCloud;
  window.requireMandatoryPunchGeo = requireMandatoryPunchGeo;
  window.isAdminOnlyAbsenceRecord = isAdminOnlyAbsenceRecord;
  window.isPunchAttendanceRecord = isPunchAttendanceRecord;
  window.isHireDateBackfillAbsence = isHireDateBackfillAbsence;
  window.backfillAllHireDateAbsences = backfillAllHireDateAbsences;
  window.focusAttendanceHireMonth = focusAttendanceHireMonth;
  window.refreshLoggedInEmployeeNotifications = refreshLoggedInEmployeeNotifications;
  window.refreshLoggedInEmployeeSalaryHistory = refreshLoggedInEmployeeSalaryHistory;
  window.startEmployeePortalPolling = startEmployeePortalPolling;
  window.stopEmployeePortalPolling = stopEmployeePortalPolling;
  window.copyRegistrationLink = copyRegistrationLink;
  window.normalizeRegistrationLinkInput = normalizeRegistrationLinkInput;
  window.clearAdminSessionForEmployeeClient = clearAdminSessionForEmployeeClient;
  window.ensureEmployeeTenantContext = ensureEmployeeTenantContext;
  window.ensureEmployeeFromServerAccess = ensureEmployeeFromServerAccess;
  window.restoreEmployeeDeviceSession = restoreEmployeeDeviceSession;
  window.getCachedEmployeeSessionIds = getCachedEmployeeSessionIds;
  window.resolveRegisteredEmployeeFromServer = resolveRegisteredEmployeeFromServer;
  window.tryAutoAdoptBrowserFingerprint = tryAutoAdoptBrowserFingerprint;
  window.applyEmpPortalSubscriptionLock = applyEmpPortalSubscriptionLock;
  window.refreshEmployeeSubscriptionForEmp = refreshEmployeeSubscriptionForEmp;
  window.markEmployeeSessionActive = markEmployeeSessionActive;
  window.clearRegisteredDeviceCache = clearRegisteredDeviceCache;
  window.showEmpPortalStatusBanner = showEmpPortalStatusBanner;
  window.ensureLoggedInEmployeeLoaded = ensureLoggedInEmployeeLoaded;
  window.displayEmpLoginNotice = displayEmpLoginNotice;
  window.upsertEmployeeIntoStore = upsertEmployeeIntoStore;
  window.deduplicateAllDeviceTokens = deduplicateAllDeviceTokens;
  window.pauseRemoteSync = pauseRemoteSync;
  window.resumeRemoteSync = resumeRemoteSync;
  window.fullEmpName = fullEmpName;
  window.attRecordDisplayName = attRecordDisplayName;
  window.syncAllAttendanceEmployeeNames = syncAllAttendanceEmployeeNames;
  window.APP_TIMEZONE = APP_TIMEZONE;
  window.todayAttDate = todayAttDate;
  window.todayIsoDate = todayIsoDate;
  window.isAttendanceRecordToday = isAttendanceRecordToday;
  window.formatAttendanceDisplayDate = formatAttendanceDisplayDate;
  window.applyAttendanceFilters = applyAttendanceFilters;
  window.openOfficialClosureForm = openOfficialClosureForm;
  window.deleteOfficialClosure = deleteOfficialClosure;
  window.renderOfficialClosuresList = renderOfficialClosuresList;
  window.officialClosureForDate = officialClosureForDate;
  window.refreshOfficialClosuresFromCloud = refreshOfficialClosuresFromCloud;
  window.countOfficialClosureDaysBetween = countOfficialClosureDaysBetween;
  window.deleteAttRecordsBatch = deleteAttRecordsBatch;
  window.loadAttendanceForBatchDelete = loadAttendanceForBatchDelete;
  window.normalizeAttendanceStore = normalizeAttendanceStore;
  window.dedupeAttendanceRecords = dedupeAttendanceRecords;
  window.attendanceRecordIso = attendanceRecordIso;
  window.attendanceRecordKey = attendanceRecordKey;
  window.previewGpsMap = previewGpsMap;
  window.scheduleGpsMapPreview = scheduleGpsMapPreview;
  window.useMyLocationForCompany = useMyLocationForCompany;
  window.openCompanyLocationMap = openCompanyLocationMap;
  window.copyCompanyCoords = copyCompanyCoords;
  window.saveGpsSettings = saveGpsSettings;
  window.formatAppTimeAmPm = formatAppTimeAmPm;
  window.syncSaasSessionContext = syncSaasSessionContext;
  window.getSaasSessionUser = getSaasSessionUser;
  window.ensureAppInteractive = ensureAppInteractive;
  window.clearStaleUiBlockers = clearStaleUiBlockers;
  window.safeBuildPage = safeBuildPage;
  window.__showPageCore = showPage;
  if (typeof window.installShowPageBridge === 'function') {
    window.installShowPageBridge();
  } else {
    window.showPage = showPage;
  }
}
