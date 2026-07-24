/**
 * إدارة بصمة أجهزة الموظفين — تحت صفحة الحضور (سحابة)
 */
import { escapeHtml, escAttr } from '../core/safe-render.js';

function esc(v) {
  return typeof escapeHtml === 'function' ? escapeHtml(v) : String(v == null ? '' : v);
}

function swalOpts() {
  return (window.swalTheme && typeof window.swalTheme === 'function') ? window.swalTheme() : {};
}

function isDeviceEditorOpen() {
  return !!(document.getElementById('dev-edit-fp-1') || document.getElementById('dev-edit-fp-2'));
}

function setDeviceEditorSwalGuard(active) {
  window.__basmaPreserveSwal = !!active;
  window.__basmaDeviceEditorOpen = !!active;
}

function notifyDeviceEditor(msg, tone) {
  var toastOpts = { dismissible: true, center: false };
  var duration = 60000;
  if (window.BasmaToast && typeof window.BasmaToast[tone === 'error' ? 'error' : 'success'] === 'function') {
    window.BasmaToast[tone === 'error' ? 'error' : 'success'](msg, duration, toastOpts);
    return;
  }
  if (window.Swal) {
    window.Swal.fire({
      icon: tone === 'error' ? 'error' : 'success',
      title: msg,
      timer: tone === 'error' ? 0 : 1600,
      showConfirmButton: tone === 'error',
      ...swalOpts()
    });
  }
}

function canViewDevices() {
  if (typeof window.hasActionPermission !== 'function') return true;
  return window.hasActionPermission('device_mgmt', 'view');
}

function canEditDevices() {
  if (typeof window.hasActionPermission !== 'function') return true;
  return window.hasActionPermission('device_mgmt', 'edit');
}

function deviceFpSummary(dev) {
  if (!dev || !dev.fingerprint) return '<span style="color:var(--text-muted)">— غير مسجّل</span>';
  var fp = String(dev.fingerprint);
  var short = fp.length > 14 ? fp.substring(0, 14) + '…' : fp;
  return '<span dir="ltr" style="font-size:11px;color:#68d391" title="' + escAttr(fp) + '">' + esc(short) + '</span>';
}

export function buildDeviceManagement() {
  var tbody = document.getElementById('dev-mgmt-table');
  if (!tbody) return;
  if (!canViewDevices()) {
    tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-muted)">لا تملك صلاحية عرض الأجهزة</td></tr>';
    return;
  }

  var employees = window.employees || [];
  var q = (document.getElementById('dev-mgmt-search')?.value || '').trim().toLowerCase();
  var list = employees.slice();
  if (q) {
    list = list.filter(function (e) {
      return String(e.name || '').toLowerCase().indexOf(q) >= 0
        || String(e.dept || '').toLowerCase().indexOf(q) >= 0;
    });
  }
  list.sort(function (a, b) { return String(a.name || '').localeCompare(String(b.name || ''), 'ar'); });

  if (!list.length) {
    tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:28px;color:var(--text-muted)"><i class="fa fa-mobile-alt" style="font-size:32px;opacity:0.35;display:block;margin-bottom:8px"></i>لا يوجد موظفون</td></tr>';
    return;
  }

  var canEdit = canEditDevices();
  tbody.innerHTML = list.map(function (e, i) {
    if (typeof window.normalizeEmployee === 'function') window.normalizeEmployee(e);
    var d1 = (e.devices || []).find(function (d) { return d.slot === 1; });
    var d2 = (e.devices || []).find(function (d) { return d.slot === 2; });
    var editBtn = canEdit
      ? '<button type="button" class="btn-sm btn-primary" data-perm="device_mgmt.edit" onclick="openEmployeeDeviceEditor(' + e.id + ')"><i class="fa fa-pen"></i> تعديل</button>'
      : '';
    return '<tr>'
      + '<td>' + (i + 1) + '</td>'
      + '<td><strong>' + esc(e.name) + '</strong></td>'
      + '<td>' + esc(e.dept || '—') + '</td>'
      + '<td>' + deviceFpSummary(d1) + '</td>'
      + '<td>' + deviceFpSummary(d2) + '</td>'
      + '<td style="white-space:nowrap">' + editBtn + '</td>'
      + '</tr>';
  }).join('');

  if (typeof window.applyPermissionUi === 'function') window.applyPermissionUi(tbody.closest('#att-device-mgmt-card') || document);
}

export async function openEmployeeDeviceEditor(empId) {
  if (!canEditDevices()) {
    if (typeof window.requireActionPermission === 'function') window.requireActionPermission('device_mgmt', 'edit');
    return;
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    if (window.Swal) window.Swal.fire({ icon: 'error', title: 'لا يوجد اتصال بالإنترنت', text: 'لا يمكن تعديل بصمة الأجهزة بدون اتصال بالسحابة.', ...swalOpts() });
    return;
  }
  var employees = window.employees || [];
  var emp = employees.find(function (e) { return e && e.id === empId; });
  if (!emp) {
    if (window.Swal) window.Swal.fire({ icon: 'error', title: 'غير موجود', text: 'لم يُعثر على الموظف', ...swalOpts() });
    return;
  }

  setDeviceEditorSwalGuard(true);
  try {
    if (typeof window.Swal !== 'undefined') {
      window.Swal.fire({
        title: '⏳ جارٍ التحميل...',
        allowOutsideClick: false,
        didOpen: function () { window.Swal.showLoading(); },
        ...swalOpts()
      });
    }

    if (window.AuthApi && window.AuthApi.refreshAuthSessionForWrite) {
      await window.AuthApi.refreshAuthSessionForWrite();
    }
    if (typeof window.sb_refreshEmployeeDevices === 'function') {
      var refreshed = await window.sb_refreshEmployeeDevices(empId);
      if (!refreshed) throw new Error('تعذّر تحميل بيانات الجهاز من السحابة');
      emp = (window.employees || []).find(function (e) { return e && e.id === empId; }) || emp;
    } else {
      throw new Error('خدمة السحابة غير محمّلة — حدّث الصفحة وحاول مرة أخرى');
    }
    if (typeof window.normalizeEmployee === 'function') window.normalizeEmployee(emp);
    if (window.Swal && window.Swal.isVisible && window.Swal.isVisible()) window.Swal.close();
    await new Promise(function (resolve) { setTimeout(resolve, 80); });
  } catch (e) {
    setDeviceEditorSwalGuard(false);
    if (window.Swal) {
      window.Swal.fire({
        icon: 'error',
        title: 'تعذّر تحميل بصمة الأجهزة',
        text: (e && e.message) || 'تحقق من الاتصال ثم حاول مرة أخرى',
        ...swalOpts()
      });
    }
    return;
  }

  var slotBlock = function (slot) {
    var dev = (emp.devices || []).find(function (d) { return d.slot === slot; });
    var fp = dev && dev.fingerprint ? String(dev.fingerprint) : '';
    var ip = dev && dev.ip ? String(dev.ip) : '';
    var linked = dev && dev.linked_at ? String(dev.linked_at).slice(0, 16).replace('T', ' ') : '';
    return ''
      + '<div class="device-mgmt-slot" style="margin-bottom:14px;padding:12px;border:1px solid var(--border);border-radius:12px;text-align:right">'
      + '<div style="font-weight:700;color:var(--accent);margin-bottom:8px">📱 ' + (slot === 1 ? 'الهاتف الأول' : 'الهاتف الثاني') + '</div>'
      + '<label style="font-size:12px;color:var(--text-secondary);display:block;margin-bottom:4px">بصمة الجهاز</label>'
      + '<input type="text" id="dev-edit-fp-' + slot + '" dir="ltr" class="swal2-input" style="font-size:12px;margin:0 0 8px" value="' + escAttr(fp) + '" placeholder="DEV-XXXX">'
      + '<div style="font-size:11px;color:var(--text-muted);line-height:1.8">'
      + (ip ? 'IP: <span dir="ltr">' + esc(ip) + '</span><br>' : '')
      + (linked ? 'آخر ربط: ' + esc(linked) + '<br>' : '')
      + '<span style="color:#f6ad55">مسح البصمة يسمح للموظف بمسح QR من هاتف جديد</span>'
      + '</div>'
      + '<button type="button" class="btn-sm" style="margin-top:8px;background:rgba(229,62,62,0.15);color:#fc8181;border:1px solid rgba(229,62,62,0.35)" onclick="clearEmployeeDeviceSlotInForm(' + empId + ',' + slot + ')"><i class="fa fa-eraser"></i> مسح بصمة هذا الجهاز</button>'
      + '<button type="button" class="btn-sm" style="margin-top:8px;margin-right:6px;background:rgba(99,179,237,0.14);color:#63b3ed;border:1px solid rgba(99,179,237,0.35)" onclick="unlockEmployeeDeviceAttemptsInForm(' + empId + ',' + slot + ')"><i class="fa fa-unlock"></i> فتح قيد المحاولات</button>'
      + '</div>';
  };

  var html = '<div style="text-align:right;max-height:420px;overflow:auto">'
    + slotBlock(1)
    + slotBlock(2)
    + '</div>';

  var result;
  try {
    result = await window.Swal.fire({
      title: '📲 إدارة الأجهزة — ' + emp.name,
      html: html,
      width: 520,
      showCancelButton: true,
      confirmButtonText: 'حفظ',
      cancelButtonText: 'إلغاء',
      ...swalOpts(),
      preConfirm: function () {
        return {
          slot1: (document.getElementById('dev-edit-fp-1')?.value || '').trim(),
          slot2: (document.getElementById('dev-edit-fp-2')?.value || '').trim()
        };
      }
    });
  } catch (e) {
    console.error('openEmployeeDeviceEditor modal:', e);
    setDeviceEditorSwalGuard(false);
    window.Swal.fire({ icon: 'error', title: 'تعذّر فتح نافذة التعديل', text: (e && e.message) || 'حدث خطأ في واجهة إدارة الأجهزة', ...swalOpts() });
    return;
  } finally {
    setDeviceEditorSwalGuard(false);
  }

  if (!result.isConfirmed || !result.value) return;

  if (window.AuthApi && window.AuthApi.refreshAuthSessionForWrite) {
    await window.AuthApi.refreshAuthSessionForWrite();
  }

  window.__basmaPreserveSwal = true;
  window.Swal.fire({
    title: '⏳ جارٍ الحفظ في السحابة...',
    allowOutsideClick: false,
    didOpen: function () { window.Swal.showLoading(); },
    ...swalOpts()
  });

  var errors = [];
  var saved = 0;
  var jobs = [];
  [1, 2].forEach(function (slot) {
    var key = slot === 1 ? 'slot1' : 'slot2';
    var newFp = result.value[key];
    var dev = (emp.devices || []).find(function (d) { return d.slot === slot; });
    var oldFp = dev && dev.fingerprint ? String(dev.fingerprint).trim() : '';
    if (newFp === oldFp) return;
    jobs.push({ empId: empId, slot: slot, fingerprint: newFp, clearLink: !newFp });
  });

  for (var i = 0; i < jobs.length; i++) {
    var job = jobs[i];
    var res = typeof window.sb_adminManageEmployeeDevice === 'function'
      ? await window.sb_adminManageEmployeeDevice(job.empId, job.slot, { fingerprint: job.fingerprint, clearLink: job.clearLink })
      : { ok: false, error: 'service_unavailable' };
    if (res && res.ok) {
      saved++;
      applyDeviceRowToLocal(job.empId, job.slot, res.data);
    } else {
      errors.push('الهاتف ' + job.slot + ': ' + ((res && res.error) || 'فشل الحفظ'));
    }
  }

  if (typeof saveData === 'function') saveData();
  if (typeof buildDeviceManagement === 'function') buildDeviceManagement();
  if (typeof buildEmployees === 'function') buildEmployees();
  if (typeof logActivity === 'function') {
    logActivity('edit', 'employees', 'تعديل بصمة جهاز: ' + emp.name, { targetName: emp.name });
  }

  if (errors.length) {
    window.Swal.fire({
      icon: saved ? 'warning' : 'error',
      title: saved ? 'تم جزئياً' : 'فشل الحفظ',
      html: errors.map(function (e) { return esc(e); }).join('<br>'),
      ...swalOpts()
    });
  } else if (saved === 0) {
    window.Swal.fire({ icon: 'info', title: 'لا تغيير', text: 'لم يتم تعديل أي بصمة', timer: 1400, showConfirmButton: false, ...swalOpts() });
  } else {
    window.Swal.fire({ icon: 'success', title: 'تم الحفظ', text: 'تم تحديث بصمة الجهاز في السحابة', timer: 1800, showConfirmButton: false, ...swalOpts() });
  }
  window.__basmaPreserveSwal = false;
}

function applyDeviceRowToLocal(empId, slot, row) {
  if (!row) return;
  var emp = (window.employees || []).find(function (e) { return e && e.id === empId; });
  if (!emp) return;
  if (typeof window.normalizeEmployee === 'function') window.normalizeEmployee(emp);
  var dev = (emp.devices || []).find(function (d) { return d.slot === slot; });
  if (!dev) return;
  dev.fingerprint = row.fingerprint || '';
  dev.ip = row.ip || '';
  dev.linked_at = row.linked_at || '';
  dev.last_login = row.last_login || '';
  dev.tokenUsedAt = row.token_used_at || '';
  dev.deviceInfo = row.device_info || {};
  delete emp._freshDevices;
}

export async function clearEmployeeDeviceSlotInForm(empId, slot) {
  if (!canEditDevices()) {
    if (typeof window.requireActionPermission === 'function') window.requireActionPermission('device_mgmt', 'edit');
    return;
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    notifyDeviceEditor('لا يمكن مسح بصمة الجهاز بدون اتصال بالسحابة.', 'error');
    return;
  }

  var inEditor = isDeviceEditorOpen();
  if (inEditor) setDeviceEditorSwalGuard(true);

  var confirmed = false;
  if (inEditor) {
    confirmed = window.confirm('مسح بصمة الهاتف ' + (slot === 1 ? 'الأول' : 'الثاني') + ' من السحابة؟\nيمكن للموظف مسح QR مجدداً من هاتف جديد.');
  } else {
    var confirmDlg = await window.Swal.fire({
      icon: 'question',
      title: 'مسح بصمة الجهاز؟',
      html: 'سيتم مسح بصمة الهاتف ' + (slot === 1 ? 'الأول' : 'الثاني') + ' من السحابة.<br><span style="font-size:12px;color:var(--text-muted)">يمكن للموظف مسح QR مجدداً من هاتف جديد.</span>',
      showCancelButton: true,
      confirmButtonText: 'نعم، امسح',
      cancelButtonText: 'إلغاء',
      confirmButtonColor: '#e53e3e',
      ...swalOpts()
    });
    confirmed = !!(confirmDlg && confirmDlg.isConfirmed);
  }
  if (!confirmed) {
    if (inEditor) setDeviceEditorSwalGuard(true);
    return;
  }

  var clearBtn = inEditor ? document.querySelector('.device-mgmt-slot button[onclick*="clearEmployeeDeviceSlotInForm(' + empId + ',' + slot + ')"]') : null;
  var clearBtnHtml = clearBtn ? clearBtn.innerHTML : '';
  if (clearBtn) {
    clearBtn.disabled = true;
    clearBtn.innerHTML = '<i class="fa fa-spinner fa-spin"></i> جارٍ المسح...';
  }

  try {
    if (window.AuthApi && window.AuthApi.refreshAuthSessionForWrite) {
      await window.AuthApi.refreshAuthSessionForWrite();
    }

    var res = typeof window.sb_adminManageEmployeeDevice === 'function'
      ? await window.sb_adminManageEmployeeDevice(empId, slot, { clearLink: true })
      : { ok: false, error: 'service_unavailable' };

    if (res && res.ok) {
      applyDeviceRowToLocal(empId, slot, res.data);
      if (typeof saveData === 'function') saveData();
      if (typeof buildDeviceManagement === 'function') buildDeviceManagement();
      if (typeof buildEmployees === 'function') buildEmployees();
      var fpInput = document.getElementById('dev-edit-fp-' + slot);
      if (fpInput) fpInput.value = '';
      if (typeof logActivity === 'function') {
        var emp = (window.employees || []).find(function (e) { return e && e.id === empId; });
        logActivity('edit', 'employees', 'مسح بصمة جهاز (هاتف ' + slot + '): ' + (emp && emp.name ? emp.name : empId), { targetName: emp && emp.name });
      }
      if (inEditor) {
        notifyDeviceEditor('تم مسح البصمة — يمكن للموظف مسح QR الآن', 'success');
      } else {
        window.Swal.fire({ icon: 'success', title: 'تم المسح', text: 'يمكن للموظف مسح QR الآن', timer: 1600, showConfirmButton: false, ...swalOpts() });
      }
    } else {
      var errText = (res && res.error) || 'تحقق من الاتصال وأعد المحاولة';
      if (inEditor) notifyDeviceEditor('تعذّر المسح: ' + errText, 'error');
      else window.Swal.fire({ icon: 'error', title: 'تعذّر المسح', text: errText, ...swalOpts() });
    }
  } catch (e) {
    console.error('clearEmployeeDeviceSlotInForm:', e);
    if (inEditor) notifyDeviceEditor('تعذّر المسح — ' + ((e && e.message) || 'حاول مرة أخرى'), 'error');
    else window.Swal.fire({ icon: 'error', title: 'تعذّر المسح', text: (e && e.message) || 'حاول مرة أخرى', ...swalOpts() });
  } finally {
    if (clearBtn) {
      clearBtn.disabled = false;
      clearBtn.innerHTML = clearBtnHtml || '<i class="fa fa-eraser"></i> مسح بصمة هذا الجهاز';
    }
    if (inEditor) setDeviceEditorSwalGuard(true);
  }
}

export async function unlockEmployeeDeviceAttemptsInForm(empId, slot) {
  if (!canEditDevices()) {
    if (typeof window.requireActionPermission === 'function') window.requireActionPermission('device_mgmt', 'edit');
    return;
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    notifyDeviceEditor('لا يمكن فتح قيد المحاولات بدون اتصال بالسحابة.', 'error');
    return;
  }
  if (window.AuthApi && window.AuthApi.refreshAuthSessionForWrite) {
    await window.AuthApi.refreshAuthSessionForWrite();
  }
  var res = typeof window.sb_adminResetEmployeeDeviceRateLimit === 'function'
    ? await window.sb_adminResetEmployeeDeviceRateLimit(empId, slot)
    : { ok: false, error: 'service_unavailable' };
  if (res && res.ok) {
    notifyDeviceEditor('تم فتح قيد المحاولات — يمكن للموظف مسح QR أو تسجيل الحضور الآن', 'success');
  } else {
    notifyDeviceEditor('تعذّر فتح القيد: ' + ((res && res.error) || 'حاول مرة أخرى'), 'error');
  }
}

export async function refreshDeviceManagementFromCloud() {
  if (!canViewDevices()) {
    if (typeof window.requireActionPermission === 'function') window.requireActionPermission('device_mgmt', 'view');
    return;
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    window.Swal.fire({ icon: 'error', title: 'لا يوجد اتصال بالإنترنت', text: 'لا يمكن تحديث بصمة الأجهزة بدون اتصال بالسحابة.', ...swalOpts() });
    return;
  }
  var employees = window.employees || [];
  if (!employees.length) {
    buildDeviceManagement();
    return;
  }
  window.Swal.fire({
    title: '⏳ جارٍ التحديث من السحابة...',
    allowOutsideClick: false,
    didOpen: function () { window.Swal.showLoading(); },
    ...swalOpts()
  });
  if (window.AuthApi && window.AuthApi.refreshAuthSessionForWrite) {
    await window.AuthApi.refreshAuthSessionForWrite();
  }
  var refreshed = 0;
  for (var i = 0; i < employees.length; i++) {
    if (typeof window.sb_refreshEmployeeDevices === 'function') {
      var ok = await window.sb_refreshEmployeeDevices(employees[i].id);
      if (ok) refreshed++;
    }
  }
  if (typeof saveData === 'function') saveData();
  buildDeviceManagement();
  if (typeof buildEmployees === 'function') buildEmployees();
  window.Swal.fire({
    icon: 'success',
    title: 'تم التحديث',
    text: 'تم جلب بيانات ' + refreshed + ' موظف من السحابة',
    timer: 1800,
    showConfirmButton: false,
    ...swalOpts()
  });
}

function portalEventLabel(type) {
  var map = {
    portal_visit: 'زيارة الرابط',
    portal_login: 'تسجيل دخول',
    check_in: 'حضور',
    check_out: 'انصراف',
    qr_link: 'ربط QR',
    device_verify: 'تحقق جهاز',
    qr_scan_attempt: 'محاولة QR'
  };
  return map[type] || type || '—';
}

function formatPortalLogDate(iso) {
  if (!iso) return '—';
  var d = new Date(iso);
  if (isNaN(d.getTime())) return String(iso).slice(0, 16).replace('T', ' ');
  var y = d.getFullYear();
  var m = String(d.getMonth() + 1).padStart(2, '0');
  var day = String(d.getDate()).padStart(2, '0');
  var hh = String(d.getHours()).padStart(2, '0');
  var mm = String(d.getMinutes()).padStart(2, '0');
  return y + '-' + m + '-' + day + ' ' + hh + ':' + mm;
}

function formatPortalLogDay(iso) {
  if (!iso) return '—';
  if (typeof window.arabicDayNameFromDate === 'function') {
    return window.arabicDayNameFromDate(String(iso).slice(0, 10)) || '—';
  }
  return '—';
}

function formatPortalLocation(row) {
  if (!row) return '<span style="color:var(--text-muted)">—</span>';
  var meta = row.meta;
  if (typeof meta === 'string') {
    try { meta = JSON.parse(meta); } catch (e) { meta = null; }
  }
  var remoteBadge = meta && meta.remote_attend
    ? '<span style="font-size:10px;padding:2px 6px;border-radius:999px;background:rgba(104,211,145,0.15);color:#68d391;margin-left:4px">عن بُعد</span>'
    : '';
  var addressLine = meta && meta.address
    ? '<div style="font-size:11px;color:#e8f4fd;margin-bottom:2px">' + esc(String(meta.address)) + '</div>'
    : '';
  if (row.geo_lat != null && row.geo_lng != null) {
    var acc = row.geo_accuracy != null ? (' ±' + Math.round(row.geo_accuracy) + 'م') : '';
    var locHint = meta && meta.location ? (' title="' + escAttr(String(meta.location)) + '"') : '';
    return remoteBadge + addressLine + '<a href="https://maps.google.com/?q=' + encodeURIComponent(row.geo_lat + ',' + row.geo_lng) + '" target="_blank" rel="noopener" dir="ltr" style="font-size:11px;color:#63b3ed"' + locHint + '>' + esc(Number(row.geo_lat).toFixed(5) + ', ' + Number(row.geo_lng).toFixed(5) + acc) + '</a>';
  }
  if (meta && meta.location) {
    return remoteBadge + '<span style="font-size:11px;color:#e8f4fd">' + esc(String(meta.location)) + '</span>';
  }
  if (meta && meta.address) {
    return remoteBadge + '<span style="font-size:11px;color:#e8f4fd">' + esc(String(meta.address)) + '</span>';
  }
  return remoteBadge + '<span style="color:var(--text-muted)">IP فقط — الموقع غير متاح</span>';
}

var _devTrackSearchTimer = null;

export function switchDeviceMgmtTab(tab) {
  var fpCard = document.getElementById('att-device-mgmt-card');
  var trackCard = document.getElementById('att-device-track-card');
  var tabFp = document.getElementById('dev-tab-fp');
  var tabTrack = document.getElementById('dev-tab-track');
  var isTrack = tab === 'track';
  if (fpCard) fpCard.style.display = isTrack ? 'none' : '';
  if (trackCard) trackCard.style.display = isTrack ? '' : 'none';
  if (tabFp) tabFp.className = 'btn-sm' + (isTrack ? '' : ' btn-primary');
  if (tabTrack) tabTrack.className = 'btn-sm' + (isTrack ? ' btn-primary' : '');
  if (isTrack && typeof refreshDeviceTrackingLog === 'function') refreshDeviceTrackingLog();
}

export function debounceDeviceTrackingSearch() {
  if (_devTrackSearchTimer) clearTimeout(_devTrackSearchTimer);
  _devTrackSearchTimer = setTimeout(function () {
    refreshDeviceTrackingLog();
  }, 350);
}

export async function refreshDeviceTrackingLog() {
  if (!canViewDevices()) {
    if (typeof window.requireActionPermission === 'function') window.requireActionPermission('device_mgmt', 'view');
    return;
  }
  var tbody = document.getElementById('dev-track-table');
  var summaryEl = document.getElementById('dev-track-summary');
  if (!tbody) return;

  if (window.appSettings && window.appSettings.trackDevices === false) {
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:28px;color:#f6ad55"><i class="fa fa-info-circle"></i> تتبع الأجهزة معطّل — فعّله من الإعدادات لبدء تسجيل النشاط</td></tr>';
    if (summaryEl) summaryEl.innerHTML = '';
    return;
  }

  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:24px;color:#fc8181">لا يوجد اتصال — لا يمكن جلب السجل</td></tr>';
    return;
  }

  tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:24px;color:var(--text-muted)"><i class="fa fa-spinner fa-spin"></i> جارٍ التحميل...</td></tr>';

  if (window.AuthApi && window.AuthApi.refreshAuthSessionForWrite) {
    await window.AuthApi.refreshAuthSessionForWrite();
  }

  var empIdRaw = document.getElementById('dev-track-emp-id')?.value || '';
  var empId = empIdRaw ? parseInt(empIdRaw, 10) : null;
  var successRaw = document.getElementById('dev-track-success')?.value;
  var successFilter = successRaw === '1' ? true : (successRaw === '0' ? false : null);

  var data = typeof window.sb_listEmployeePortalAccessLog === 'function'
    ? await window.sb_listEmployeePortalAccessLog({
      employeeId: empId && empId > 0 ? empId : null,
      search: (document.getElementById('dev-track-search')?.value || '').trim() || null,
      eventType: document.getElementById('dev-track-event')?.value || null,
      dateFrom: document.getElementById('dev-track-from')?.value || null,
      dateTo: document.getElementById('dev-track-to')?.value || null,
      success: successFilter,
      limit: 250
    })
    : null;

  if (!data || data.ok !== true) {
    var errHint = !data ? 'تأكد من تطبيق migration 114 على قاعدة البيانات' : (data.error || 'خطأ');
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:28px;color:#fc8181">تعذّر جلب السجل: ' + esc(errHint) + '</td></tr>';
    if (summaryEl) summaryEl.innerHTML = '';
    return;
  }

  var records = data.records || [];
  var summary = data.summary || [];

  if (summaryEl) {
    summaryEl.innerHTML = [
      '<span class="dev-track-stat">إجمالي الأحداث: <b>' + esc(String(data.total || records.length)) + '</b></span>',
      '<span class="dev-track-stat">موظفون نشطون: <b>' + esc(String(summary.length)) + '</b></span>'
    ].join('');
    if (summary.length) {
      summary.slice(0, 6).forEach(function (s) {
        summaryEl.innerHTML += '<span class="dev-track-stat">' + esc(s.employee_name || ('#' + s.employee_id))
          + ' — زيارات: <b>' + esc(String(s.visit_count || 0)) + '</b>'
          + ' | دخول: <b>' + esc(String(s.login_count || 0)) + '</b>'
          + ' | بصمات: <b>' + esc(String(s.punch_count || 0)) + '</b></span>';
      });
    }
  }

  if (!records.length) {
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:28px;color:var(--text-muted)"><i class="fa fa-route" style="font-size:28px;opacity:0.35;display:block;margin-bottom:8px"></i>لا توجد أحداث مطابقة للفلتر</td></tr>';
    return;
  }

  tbody.innerHTML = records.map(function (row, i) {
    var fp = row.fingerprint ? String(row.fingerprint) : '';
    var fpShort = fp ? (fp.length > 12 ? fp.slice(0, 12) + '…' : fp) : '—';
    var okBadge = row.success
      ? '<span style="color:#68d391;font-weight:700">✓ ناجح</span>'
      : '<span style="color:#fc8181;font-weight:700">✗ فاشل</span>';
    return '<tr>'
      + '<td>' + (i + 1) + '</td>'
      + '<td><strong>' + esc(row.employee_name || ('#' + row.employee_id)) + '</strong><br><span style="font-size:11px;color:var(--text-muted)">' + esc(row.dept || '') + '</span></td>'
      + '<td>' + esc(portalEventLabel(row.event_type)) + '</td>'
      + '<td dir="ltr" style="font-size:11px">' + esc(formatPortalLogDate(row.created_at)) + '</td>'
      + '<td>' + esc(formatPortalLogDay(row.created_at)) + '</td>'
      + '<td dir="ltr" style="font-size:11px">' + esc(row.ip || '—') + '</td>'
      + '<td dir="ltr" style="font-size:11px" title="' + escAttr(fp) + '">' + esc(fpShort) + '</td>'
      + '<td>' + formatPortalLocation(row) + '</td>'
      + '<td>' + okBadge + '</td>'
      + '</tr>';
  }).join('');
}

if (typeof window !== 'undefined') {
  window.buildDeviceManagement = buildDeviceManagement;
  window.switchDeviceMgmtTab = switchDeviceMgmtTab;
  window.debounceDeviceTrackingSearch = debounceDeviceTrackingSearch;
  window.refreshDeviceTrackingLog = refreshDeviceTrackingLog;
  window.openEmployeeDeviceEditor = openEmployeeDeviceEditor;
  window.clearEmployeeDeviceSlotInForm = clearEmployeeDeviceSlotInForm;
  window.unlockEmployeeDeviceAttemptsInForm = unlockEmployeeDeviceAttemptsInForm;
  window.refreshDeviceManagementFromCloud = refreshDeviceManagementFromCloud;
}
