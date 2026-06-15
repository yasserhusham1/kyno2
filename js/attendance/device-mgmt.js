/**
 * إدارة بصمة أجهزة الموظفين — تحت صفحة الحضور (سحابة)
 */
import { escapeHtml, escAttr } from '../core/safe-render.js';

function esc(v) {
  return typeof escapeHtml === 'function' ? escapeHtml(v) : String(v == null ? '' : v);
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
  var employees = window.employees || [];
  var emp = employees.find(function (e) { return e && e.id === empId; });
  if (!emp) {
    if (window.Swal) window.Swal.fire({ icon: 'error', title: 'غير موجود', text: 'لم يُعثر على الموظف', ...(typeof swalTheme === 'function' ? swalTheme() : {}) });
    return;
  }

  if (typeof window.Swal !== 'undefined') {
    window.Swal.fire({
      title: '⏳ جارٍ التحميل...',
      allowOutsideClick: false,
      didOpen: function () { window.Swal.showLoading(); },
      ...(typeof swalTheme === 'function' ? swalTheme() : {})
    });
  }

  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    await AuthApi.refreshAuthSessionForWrite();
  }
  if (typeof sb_refreshEmployeeDevices === 'function') {
    await sb_refreshEmployeeDevices(empId);
    emp = (window.employees || []).find(function (e) { return e && e.id === empId; }) || emp;
  }
  if (typeof window.normalizeEmployee === 'function') window.normalizeEmployee(emp);

  if (window.Swal) window.Swal.close();

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
      + '</div>';
  };

  var html = '<div style="text-align:right;max-height:420px;overflow:auto">'
    + slotBlock(1)
    + slotBlock(2)
    + '</div>';

  var result = await window.Swal.fire({
    title: '📲 إدارة الأجهزة — ' + emp.name,
    html: html,
    width: 520,
    showCancelButton: true,
    confirmButtonText: 'حفظ',
    cancelButtonText: 'إلغاء',
    ...(typeof swalTheme === 'function' ? swalTheme() : {}),
    preConfirm: function () {
      return {
        slot1: (document.getElementById('dev-edit-fp-1')?.value || '').trim(),
        slot2: (document.getElementById('dev-edit-fp-2')?.value || '').trim()
      };
    }
  });

  if (!result.isConfirmed || !result.value) return;

  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    await AuthApi.refreshAuthSessionForWrite();
  }

  window.Swal.fire({
    title: '⏳ جارٍ الحفظ في السحابة...',
    allowOutsideClick: false,
    didOpen: function () { window.Swal.showLoading(); },
    ...(typeof swalTheme === 'function' ? swalTheme() : {})
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
    var res = typeof sb_adminManageEmployeeDevice === 'function'
      ? await sb_adminManageEmployeeDevice(job.empId, job.slot, { fingerprint: job.fingerprint, clearLink: job.clearLink })
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
      ...(typeof swalTheme === 'function' ? swalTheme() : {})
    });
  } else if (saved === 0) {
    window.Swal.fire({ icon: 'info', title: 'لا تغيير', text: 'لم يتم تعديل أي بصمة', timer: 1400, showConfirmButton: false, ...(typeof swalTheme === 'function' ? swalTheme() : {}) });
  } else {
    window.Swal.fire({ icon: 'success', title: 'تم الحفظ', text: 'تم تحديث بصمة الجهاز في السحابة', timer: 1800, showConfirmButton: false, ...(typeof swalTheme === 'function' ? swalTheme() : {}) });
  }
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
  var confirm = await window.Swal.fire({
    icon: 'question',
    title: 'مسح بصمة الجهاز؟',
    html: 'سيتم مسح بصمة الهاتف ' + (slot === 1 ? 'الأول' : 'الثاني') + ' من السحابة.<br><span style="font-size:12px;color:var(--text-muted)">يمكن للموظف مسح QR مجدداً من هاتف جديد.</span>',
    showCancelButton: true,
    confirmButtonText: 'نعم، امسح',
    cancelButtonText: 'إلغاء',
    confirmButtonColor: '#e53e3e',
    ...(typeof swalTheme === 'function' ? swalTheme() : {})
  });
  if (!confirm.isConfirmed) return;

  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    await AuthApi.refreshAuthSessionForWrite();
  }

  window.Swal.fire({
    title: '⏳ جارٍ المسح...',
    allowOutsideClick: false,
    didOpen: function () { window.Swal.showLoading(); },
    ...(typeof swalTheme === 'function' ? swalTheme() : {})
  });

  var res = typeof sb_adminManageEmployeeDevice === 'function'
    ? await sb_adminManageEmployeeDevice(empId, slot, { clearLink: true })
    : { ok: false, error: 'service_unavailable' };

  if (res && res.ok) {
    applyDeviceRowToLocal(empId, slot, res.data);
    if (typeof saveData === 'function') saveData();
    if (typeof buildEmployees === 'function') buildEmployees();
    var fpInput = document.getElementById('dev-edit-fp-' + slot);
    if (fpInput) fpInput.value = '';
    if (typeof logActivity === 'function') {
      var emp = (window.employees || []).find(function (e) { return e && e.id === empId; });
      logActivity('edit', 'employees', 'مسح بصمة جهاز (هاتف ' + slot + '): ' + (emp && emp.name ? emp.name : empId), { targetName: emp && emp.name });
    }
    window.Swal.fire({ icon: 'success', title: 'تم المسح', text: 'يمكن للموظف مسح QR الآن', timer: 1600, showConfirmButton: false, ...(typeof swalTheme === 'function' ? swalTheme() : {}) });
  } else {
    window.Swal.fire({
      icon: 'error',
      title: 'تعذّر المسح',
      text: (res && res.error) || 'تحقق من الاتصال وأعد المحاولة',
      ...(typeof swalTheme === 'function' ? swalTheme() : {})
    });
  }
}

export async function refreshDeviceManagementFromCloud() {
  if (!canViewDevices()) {
    if (typeof window.requireActionPermission === 'function') window.requireActionPermission('device_mgmt', 'view');
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
    ...(typeof swalTheme === 'function' ? swalTheme() : {})
  });
  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    await AuthApi.refreshAuthSessionForWrite();
  }
  var refreshed = 0;
  for (var i = 0; i < employees.length; i++) {
    if (typeof sb_refreshEmployeeDevices === 'function') {
      var ok = await sb_refreshEmployeeDevices(employees[i].id);
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
    ...(typeof swalTheme === 'function' ? swalTheme() : {})
  });
}

if (typeof window !== 'undefined') {
  window.buildDeviceManagement = buildDeviceManagement;
  window.openEmployeeDeviceEditor = openEmployeeDeviceEditor;
  window.clearEmployeeDeviceSlotInForm = clearEmployeeDeviceSlotInForm;
  window.refreshDeviceManagementFromCloud = refreshDeviceManagementFromCloud;
}
