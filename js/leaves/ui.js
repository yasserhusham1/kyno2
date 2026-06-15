// ============================================================
// KYNO Leaves UI — نظام الإجازات والغياب والإشعارات
// ============================================================

// ─── ثوابت ───────────────────────────────────────────────
var LEAVE_TYPES = {
  paid_open:     { label: 'إجازة مفتوحة براتب',        icon: 'fa-calendar-check', color: '#68d391', badgeClass: 'leave-paid-open'    },
  unpaid_open:   { label: 'إجازة مفتوحة بدون راتب',    icon: 'fa-calendar-times', color: '#fc8181', badgeClass: 'leave-unpaid-open'  },
  paid_single:   { label: 'إجازة مدفوعة (يوم واحد)',   icon: 'fa-calendar-day',   color: '#63b3ed', badgeClass: 'leave-paid-single'  },
  unpaid_single: { label: 'إجازة غير مدفوعة (يوم)',    icon: 'fa-calendar-minus', color: '#f6ad55', badgeClass: 'leave-unpaid-single'},
  absence_mult:  { label: 'غياب مضاعف',                icon: 'fa-user-slash',     color: '#e53e3e', badgeClass: 'leave-absence-mult' }
};

// ─── مساعدات التاريخ ──────────────────────────────────────
function _leaveDateLabel(iso) {
  if (!iso) return '—';
  var d = new Date(iso + 'T12:00:00');
  return d.toLocaleDateString('ar-IQ', { year:'numeric', month:'short', day:'numeric' });
}

function _leaveDaysCount(fromDate, toDate) {
  if (!fromDate) return 1;
  if (!toDate) return 1;
  var a = new Date(fromDate + 'T00:00:00');
  var b = new Date(toDate   + 'T00:00:00');
  return Math.max(1, Math.round((b - a) / 86400000) + 1);
}

function _absenceDaysCount(leave) {
  if (!leave) return 1;
  var n = parseInt(leave.absenceDays != null ? leave.absenceDays : (leave.absence_days != null ? leave.absence_days : leave.multiplier), 10);
  return Math.max(1, Number.isFinite(n) ? n : 1);
}

function _leaveInPeriod(leave, period) {
  if (!leave || !leave.fromDate) return false;
  var from = new Date(leave.fromDate + 'T12:00:00');
  var to   = leave.toDate ? new Date(leave.toDate + 'T12:00:00') : from;
  return to >= period.start && from <= period.end;
}

function _leaveUniqueRef(empId) {
  return 'leave_' + empId + '_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7);
}

function _todayIso() {
  var d = new Date();
  return d.getFullYear() + '-' +
    String(d.getMonth() + 1).padStart(2, '0') + '-' +
    String(d.getDate()).padStart(2, '0');
}

// ─── حساب خصومات الإجازات لفترة الراتب ─────────────────
function calcLeaveDeductionsForPeriod(emp, period) {
  var result = { deduct: 0, days: 0, items: [] };
  if (!emp || !emp.id || !period) return result;
  var dailyRate = typeof getEmpDailyRate === 'function' ? getEmpDailyRate(emp) : 0;
  if (!dailyRate && emp && (emp.salary || 0) > 0) {
    var md = typeof getStandardMonthDays === 'function' ? getStandardMonthDays() : 30;
    dailyRate = Math.floor((emp.salary || 0) / md);
  }
  if (!dailyRate) return result;

  var empLeaves = (window.leavesData || []).filter(function(l) {
    return l && l.empId === emp.id && _leaveInPeriod(l, period);
  });

  empLeaves.forEach(function(l) {
    var lInfo = LEAVE_TYPES[l.leaveType] || LEAVE_TYPES.paid_single;
    if (l.leaveType === 'unpaid_open') {
      var days = _leaveDaysCount(l.fromDate, l.toDate);
      var d    = Math.round(days * dailyRate);
      result.deduct += d;
      result.days   += days;
      result.items.push({ label: lInfo.label, days: days, deduct: d });
    } else if (l.leaveType === 'unpaid_single') {
      result.deduct += dailyRate;
      result.days   += 1;
      result.items.push({ label: lInfo.label, days: 1, deduct: dailyRate });
    } else if (l.leaveType === 'absence_mult') {
      var absDays = _absenceDaysCount(l);
      var extra  = Math.round(absDays * dailyRate);
      result.deduct += extra;
      result.days   += absDays;
      result.items.push({ label: 'غياب ' + absDays + ' يوم', days: absDays, deduct: extra });
    }
  });
  return result;
}
window.calcLeaveDeductionsForPeriod = calcLeaveDeductionsForPeriod;

// ─── مساعد الصلاحيات ─────────────────────────────────────
function _leavesCanAdd()    { return typeof hasActionPermission !== 'function' || hasActionPermission('leaves','add'); }
function _leavesCanEdit()   { return typeof hasActionPermission !== 'function' || hasActionPermission('leaves','edit'); }
function _leavesCanDelete() { return typeof hasActionPermission !== 'function' || hasActionPermission('leaves','delete'); }

// ─── بناء صفحة الإجازات (للمسؤول) ───────────────────────
function buildLeaves() {
  var container = document.getElementById('leaves-content');
  if (!container) return;

  var filterEmp  = (document.getElementById('leaves-filter-emp')  || {}).value || '';
  var filterType = (document.getElementById('leaves-filter-type') || {}).value || '';
  var filterDept = (document.getElementById('leaves-filter-dept') || {}).value || '';

  var leaves = (window.leavesData || []).slice().sort(function(a, b) {
    return (b.fromDate || '') > (a.fromDate || '') ? 1 : -1;
  });

  if (filterEmp)  leaves = leaves.filter(function(l){ return l.empName && l.empName.indexOf(filterEmp) >= 0; });
  if (filterType) leaves = leaves.filter(function(l){ return l.leaveType === filterType; });
  if (filterDept) leaves = leaves.filter(function(l){ return l.dept === filterDept; });

  // إحصائيات
  var totalUnpaidDays = 0, totalMultipleAbs = 0, totalPaid = 0;
  leaves.forEach(function(l) {
    if (l.leaveType === 'unpaid_open')   totalUnpaidDays += _leaveDaysCount(l.fromDate, l.toDate);
    if (l.leaveType === 'unpaid_single') totalUnpaidDays++;
    if (l.leaveType === 'absence_mult')  totalMultipleAbs += _absenceDaysCount(l);
    if (l.leaveType === 'paid_open' || l.leaveType === 'paid_single') totalPaid++;
  });

  var canEdit   = _leavesCanEdit();
  var canDelete = _leavesCanDelete();

  var html = '<div class="leaves-stats">' +
    '<div class="leave-stat-card"><i class="fa fa-calendar-check"></i><div class="leave-stat-val green">' + totalPaid + '</div><div class="leave-stat-lbl">إجازة مدفوعة</div></div>' +
    '<div class="leave-stat-card"><i class="fa fa-calendar-times"></i><div class="leave-stat-val red">' + totalUnpaidDays + '</div><div class="leave-stat-lbl">أيام بدون راتب</div></div>' +
    '<div class="leave-stat-card"><i class="fa fa-user-slash"></i><div class="leave-stat-val orange">' + totalMultipleAbs + '</div><div class="leave-stat-lbl">غياب مضاعف</div></div>' +
  '</div>';

  if (leaves.length === 0) {
    html += '<div style="text-align:center;padding:48px;color:var(--text-muted)">' +
      '<i class="fa fa-calendar-alt" style="font-size:48px;opacity:0.3;display:block;margin-bottom:12px"></i>' +
      'لا توجد إجازات مسجلة</div>';
    container.innerHTML = html;
    return;
  }

  html += '<div class="table-wrap"><table><thead><tr>' +
    '<th>#</th><th>الموظف</th><th>القسم</th><th>النوع</th>' +
    '<th>من</th><th>إلى</th><th>الأيام</th><th>تفصيل الغياب</th>' +
    '<th>ملاحظة</th><th>الخصم</th><th>إجراءات</th>' +
    '</tr></thead><tbody>';

  leaves.forEach(function(l, i) {
    var emp       = (window.employees || []).find(function(e){ return e && e.id === l.empId; });
    var dailyRate = emp ? (typeof getEmpDailyRate === 'function' ? getEmpDailyRate(emp) : 0) : 0;
    if (!dailyRate && emp && (emp.salary || 0) > 0) {
      var md = typeof getStandardMonthDays === 'function' ? getStandardMonthDays() : 30;
      dailyRate = Math.floor((emp.salary || 0) / md);
    }
    var lInfo     = LEAVE_TYPES[l.leaveType] || LEAVE_TYPES.paid_single;
    var days      = (l.leaveType === 'paid_open' || l.leaveType === 'unpaid_open')
                    ? _leaveDaysCount(l.fromDate, l.toDate) : 1;
    var deduct    = 0;
    if (l.leaveType === 'unpaid_open')   deduct = Math.round(days * dailyRate);
    if (l.leaveType === 'unpaid_single') deduct = dailyRate;
    if (l.leaveType === 'absence_mult')  deduct = Math.round(_absenceDaysCount(l) * dailyRate);

    var actions = '';
    if (canEdit)   actions += '<button class="btn-icon-edit" onclick="editLeave(\'' + _esc(l.id) + '\')" title="تعديل"><i class="fa fa-edit"></i></button>';
    if (canDelete) actions += '<button class="btn-icon-red"  onclick="deleteLeave(\'' + _esc(l.id) + '\')" title="حذف"><i class="fa fa-trash"></i></button>';

    html += '<tr>' +
      '<td>' + (i + 1) + '</td>' +
      '<td><strong>' + _esc(l.empName || '—') + '</strong></td>' +
      '<td>' + _esc(l.dept || '—') + '</td>' +
      '<td><span class="leave-badge ' + lInfo.badgeClass + '">' +
        '<i class="fa ' + lInfo.icon + '"></i> ' + lInfo.label + '</span></td>' +
      '<td>' + _leaveDateLabel(l.fromDate) + '</td>' +
      '<td>' + (l.toDate ? _leaveDateLabel(l.toDate) : '—') + '</td>' +
      '<td>' + (l.leaveType === 'absence_mult' ? _absenceDaysCount(l) : days) + '</td>' +
      '<td>' + (l.leaveType === 'absence_mult' ? 'غياب ' + _absenceDaysCount(l) + ' يوم' : '—') + '</td>' +
      '<td style="max-width:140px;overflow:hidden;text-overflow:ellipsis">' + _esc(l.note || '—') + '</td>' +
      '<td style="color:' + (deduct > 0 ? '#fc8181' : '#68d391') + ';font-weight:700">' +
        (deduct > 0 ? '-' + deduct.toLocaleString() + ' IQD' : 'بدون خصم') + '</td>' +
      '<td style="display:flex;gap:4px">' + (actions || '—') + '</td>' +
      '</tr>';
  });

  html += '</tbody></table></div>';
  container.innerHTML = html;
}
window.buildLeaves = buildLeaves;

// ─── فلترة الإجازات ──────────────────────────────────────
function filterLeaves() {
  buildLeaves();
}
window.filterLeaves = filterLeaves;

// ─── تعديل إجازة ─────────────────────────────────────────
function editLeave(leaveId) {
  if (!leaveId) return;
  var leave = (window.leavesData || []).find(function(l){ return l && l.id === leaveId; });
  if (!leave) return;

  var empOptions = (window.employees || []).map(function(e) {
    return '<option value="' + e.id + '"' + (e.id === leave.empId ? ' selected' : '') + '>' +
      _esc(e.name) + ' — ' + _esc(e.dept || '') + '</option>';
  }).join('');

  var isOpen = leave.leaveType === 'paid_open' || leave.leaveType === 'unpaid_open';

  Swal.fire({
    title: '✏️ تعديل الإجازة',
    html:
      '<div class="leave-form">' +
      '<div class="leave-form-row">' +
        '<label>الموظف</label>' +
        '<select id="lf-emp" disabled style="opacity:0.6">' + empOptions + '</select>' +
      '</div>' +
      '<div class="leave-form-row">' +
        '<label>نوع الإجازة <span style="color:#fc8181">*</span></label>' +
        '<select id="lf-type" onchange="onLeaveTypeChange()">' +
          '<option value="paid_open"'     + (leave.leaveType==='paid_open'     ?' selected':'') + '>📅 إجازة مفتوحة براتب</option>' +
          '<option value="unpaid_open"'   + (leave.leaveType==='unpaid_open'   ?' selected':'') + '>📅 إجازة مفتوحة بدون راتب</option>' +
          '<option value="paid_single"'   + (leave.leaveType==='paid_single'   ?' selected':'') + '>📋 إجازة مدفوعة (يوم واحد)</option>' +
          '<option value="unpaid_single"' + (leave.leaveType==='unpaid_single' ?' selected':'') + '>📋 إجازة غير مدفوعة (يوم)</option>' +
          '<option value="absence_mult"'  + (leave.leaveType==='absence_mult'  ?' selected':'') + '>🚫 غياب مضاعف</option>' +
        '</select>' +
      '</div>' +
      '<div class="leave-form-row" id="lf-date-row">' +
        '<label id="lf-from-lbl">' + (isOpen ? 'تاريخ البداية' : 'تاريخ الإجازة') + ' <span style="color:#fc8181">*</span></label>' +
        '<input type="date" id="lf-from" value="' + (leave.fromDate || '') + '">' +
      '</div>' +
      '<div class="leave-form-row" id="lf-to-row" style="' + (isOpen ? '' : 'display:none') + '">' +
        '<label>تاريخ الانتهاء</label>' +
        '<input type="date" id="lf-to" value="' + (leave.toDate || leave.fromDate || '') + '">' +
      '</div>' +
      '<div class="leave-form-row" id="lf-mult-row" style="' + (leave.leaveType==='absence_mult' ? '' : 'display:none') + '">' +
        '<label>عدد أيام الغياب</label>' +
        '<input type="number" id="lf-mult" min="1" max="31" value="' + _absenceDaysCount(leave) + '" style="width:100px">' +
      '</div>' +
      '<div class="leave-form-row" id="lf-preview-row" style="padding:10px;background:rgba(0,0,0,0.15);border-radius:8px;font-size:13px;color:var(--text-secondary)"></div>' +
      '<div class="leave-form-row">' +
        '<label>ملاحظة</label>' +
        '<textarea id="lf-note" rows="2" style="width:100%;padding:8px;background:var(--bg-secondary);border:1px solid var(--border);border-radius:8px;color:var(--text-primary);resize:vertical">' +
          _esc(leave.note || '') +
        '</textarea>' +
      '</div>' +
      '</div>',
    customClass: { popup: 'swal-emp-wide' },
    width: 560,
    confirmButtonText: '✅ حفظ التعديل',
    cancelButtonText: 'إلغاء',
    showCancelButton: true,
    focusConfirm: false,
    didOpen: function() { onLeaveTypeChange(); _updateLeavePreview(); },
    preConfirm: function() {
      var ltype = document.getElementById('lf-type').value;
      var from  = document.getElementById('lf-from').value;
      var to    = (document.getElementById('lf-to') || {}).value || '';
      var mult  = parseInt((document.getElementById('lf-mult') || {}).value || '2', 10);
      var note  = (document.getElementById('lf-note') || {}).value || '';
      if (!from) { Swal.showValidationMessage('اختر تاريخ الإجازة'); return false; }
      if ((ltype === 'paid_open' || ltype === 'unpaid_open') && to && to < from) {
        Swal.showValidationMessage('تاريخ الانتهاء يجب أن يكون بعد تاريخ البداية'); return false;
      }
      return {
        empId:      leave.empId,
        leaveType:  ltype,
        fromDate:   from,
        toDate:     (ltype === 'paid_open' || ltype === 'unpaid_open') ? (to || from) : null,
        multiplier: ltype === 'absence_mult' ? Math.max(1, mult || 1) : 1,
        absenceDays: ltype === 'absence_mult' ? Math.max(1, mult || 1) : 0,
        note:       note.trim()
      };
    },
    ...swalTheme()
  }).then(function(r) {
    if (!r.isConfirmed || !r.value) return;
    saveLeave(r.value, leaveId);
  });
}
window.editLeave = editLeave;

// ─── نموذج إضافة إجازة ───────────────────────────────────
function openAddLeaveForm(preEmpId) {
  var empOptions = (window.employees || []).map(function(e) {
    return '<option value="' + e.id + '"' + (preEmpId && e.id === preEmpId ? ' selected' : '') + '>' +
      _esc(e.name) + ' — ' + _esc(e.dept || '') + '</option>';
  }).join('');

  var today = _todayIso();

  Swal.fire({
    title: '📅 إضافة إجازة / غياب',
    html:
      '<div class="leave-form">' +
      '<div class="leave-form-row">' +
        '<label>الموظف <span style="color:#fc8181">*</span></label>' +
        '<select id="lf-emp" onchange="onLeaveEmpChange()">' +
          '<option value="">— اختر الموظف —</option>' + empOptions +
        '</select>' +
      '</div>' +
      '<div class="leave-form-row">' +
        '<label>نوع الإجازة <span style="color:#fc8181">*</span></label>' +
        '<select id="lf-type" onchange="onLeaveTypeChange()">' +
          '<option value="paid_open">📅 إجازة مفتوحة براتب (من→إلى)</option>' +
          '<option value="unpaid_open">📅 إجازة مفتوحة بدون راتب (من→إلى)</option>' +
          '<option value="paid_single">📋 إجازة مدفوعة (يوم واحد)</option>' +
          '<option value="unpaid_single">📋 إجازة غير مدفوعة (يوم خصم)</option>' +
          '<option value="absence_mult">🚫 غياب مضاعف</option>' +
        '</select>' +
      '</div>' +
      '<div class="leave-form-row" id="lf-date-row">' +
        '<label id="lf-from-lbl">تاريخ الإجازة <span style="color:#fc8181">*</span></label>' +
        '<input type="date" id="lf-from" value="' + today + '">' +
      '</div>' +
      '<div class="leave-form-row" id="lf-to-row" style="display:none">' +
        '<label>تاريخ الانتهاء <span style="color:#fc8181">*</span></label>' +
        '<input type="date" id="lf-to" value="' + today + '">' +
      '</div>' +
      '<div class="leave-form-row" id="lf-mult-row" style="display:none">' +
        '<label>عدد أيام الغياب</label>' +
        '<input type="number" id="lf-mult" min="1" max="31" value="1" style="width:100px">' +
      '</div>' +
      '<div class="leave-form-row" id="lf-preview-row" style="padding:10px;background:rgba(0,0,0,0.15);border-radius:8px;font-size:13px;color:var(--text-secondary)"></div>' +
      '<div class="leave-form-row">' +
        '<label>ملاحظة</label>' +
        '<textarea id="lf-note" rows="2" style="width:100%;padding:8px;background:var(--bg-secondary);border:1px solid var(--border);border-radius:8px;color:var(--text-primary);resize:vertical" placeholder="سبب الإجازة أو ملاحظة..."></textarea>' +
      '</div>' +
      '</div>',
    customClass: { popup: 'swal-emp-wide' },
    width: 560,
    confirmButtonText: '✅ حفظ الإجازة',
    cancelButtonText: 'إلغاء',
    showCancelButton: true,
    focusConfirm: false,
    didOpen: function() {
      onLeaveTypeChange();
      if (preEmpId) onLeaveEmpChange();
    },
    preConfirm: function() {
      var empId = parseInt(document.getElementById('lf-emp').value, 10);
      var ltype = document.getElementById('lf-type').value;
      var from  = document.getElementById('lf-from').value;
      var to    = document.getElementById('lf-to') ? document.getElementById('lf-to').value : '';
      var mult  = parseInt((document.getElementById('lf-mult') || {}).value || '2', 10);
      var note  = (document.getElementById('lf-note') || {}).value || '';

      if (!empId) { Swal.showValidationMessage('اختر الموظف'); return false; }
      if (!from)  { Swal.showValidationMessage('اختر تاريخ الإجازة'); return false; }
      if ((ltype === 'paid_open' || ltype === 'unpaid_open') && to && to < from) {
        Swal.showValidationMessage('تاريخ الانتهاء يجب أن يكون بعد تاريخ البداية');
        return false;
      }

      return {
        empId: empId,
        leaveType: ltype,
        fromDate:  from,
        toDate:    (ltype === 'paid_open' || ltype === 'unpaid_open') ? (to || from) : null,
        multiplier: ltype === 'absence_mult' ? Math.max(1, mult || 1) : 1,
        absenceDays: ltype === 'absence_mult' ? Math.max(1, mult || 1) : 0,
        note: note.trim()
      };
    },
    ...swalTheme()
  }).then(function(r) {
    if (!r.isConfirmed || !r.value) return;
    saveLeave(r.value);
  });
}
window.openAddLeaveForm = openAddLeaveForm;

// ─── مستمعي تغيير النموذج ─────────────────────────────────
function onLeaveTypeChange() {
  var ltype   = (document.getElementById('lf-type') || {}).value || 'paid_single';
  var toRow   = document.getElementById('lf-to-row');
  var multRow = document.getElementById('lf-mult-row');
  var fromLbl = document.getElementById('lf-from-lbl');

  var isOpen = ltype === 'paid_open' || ltype === 'unpaid_open';
  if (toRow)   toRow.style.display   = isOpen ? '' : 'none';
  if (multRow) multRow.style.display = ltype === 'absence_mult' ? '' : 'none';
  if (fromLbl) fromLbl.innerHTML = isOpen ? 'تاريخ البداية <span style="color:#fc8181">*</span>' : 'تاريخ الإجازة <span style="color:#fc8181">*</span>';

  _updateLeavePreview();
}
window.onLeaveTypeChange = onLeaveTypeChange;

function onLeaveEmpChange() {
  _updateLeavePreview();
}
window.onLeaveEmpChange = onLeaveEmpChange;

function _updateLeavePreview() {
  var prev = document.getElementById('lf-preview-row');
  if (!prev) return;
  var empId = parseInt((document.getElementById('lf-emp') || {}).value || '0', 10);
  var ltype = (document.getElementById('lf-type') || {}).value || 'paid_single';
  var from  = (document.getElementById('lf-from') || {}).value || '';
  var to    = (document.getElementById('lf-to')   || {}).value || '';
  var mult  = parseInt((document.getElementById('lf-mult') || {}).value || '1', 10) || 1;

  if (!empId) { prev.innerHTML = ''; return; }

  var emp = (window.employees || []).find(function(e){ return e && e.id === empId; });
  if (!emp) { prev.innerHTML = ''; return; }

  var dailyRate = typeof getEmpDailyRate === 'function' ? getEmpDailyRate(emp) : 0;
  if (!dailyRate && emp && (emp.salary || 0) > 0) {
    var md = typeof getStandardMonthDays === 'function' ? getStandardMonthDays() : 30;
    dailyRate = Math.floor((emp.salary || 0) / md);
  }
  var days      = (ltype === 'paid_open' || ltype === 'unpaid_open') ? _leaveDaysCount(from, to) : 1;
  var deduct    = 0;
  var deductLabel = '';

  if (ltype === 'unpaid_open')   { deduct = Math.round(days * dailyRate); deductLabel = 'خصم: <b style="color:#fc8181">' + deduct.toLocaleString() + ' IQD</b> (' + days + ' يوم × ' + dailyRate.toLocaleString() + ')'; }
  if (ltype === 'unpaid_single') { deduct = dailyRate; deductLabel = 'خصم: <b style="color:#fc8181">' + deduct.toLocaleString() + ' IQD</b> (يوم واحد)'; }
  if (ltype === 'absence_mult')  { deduct = Math.round(Math.max(1, mult) * dailyRate); deductLabel = 'خصم: <b style="color:#e53e3e">' + deduct.toLocaleString() + ' IQD</b> (غياب ' + Math.max(1, mult) + ' يوم × ' + dailyRate.toLocaleString() + ')'; }
  if (ltype === 'paid_open' || ltype === 'paid_single') { deductLabel = '<b style="color:#68d391">بدون خصم — إجازة مدفوعة</b>'; }

  prev.innerHTML = '<i class="fa fa-info-circle" style="color:#63b3ed;margin-left:6px"></i>' +
    '<b>' + _esc(emp.name) + '</b> — المعدل اليومي: ' + dailyRate.toLocaleString() + ' IQD — ' + deductLabel;
}

// ─── دالة التحديث الشامل بعد أي عملية إجازة ─────────────
function _refreshAfterLeaveChange() {
  buildLeaves();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
  if (typeof buildLeaveBadge === 'function') buildLeaveBadge();
  if (typeof buildDashboard === 'function' && document.getElementById('page-dashboard') &&
      document.getElementById('page-dashboard').classList.contains('active')) buildDashboard();
  if (typeof buildEmpPortal === 'function' && window.currentUser === 'emp') {
    var loggedEmp = typeof getLoggedInEmp === 'function' ? getLoggedInEmp() : null;
    if (loggedEmp) {
      buildEmployeeLeaves(loggedEmp.id);
      buildEmployeeLeaveNotifs(loggedEmp.id);
    }
  }
  if (typeof buildNotifications === 'function' && document.getElementById('page-notifications') &&
      document.getElementById('page-notifications').classList.contains('active')) buildNotifications();
}

// ─── حفظ الإجازة ─────────────────────────────────────────
function saveLeave(data, existingId) {
  if (!data || !data.empId) return;

  var emp = (window.employees || []).find(function(e){ return e && e.id === data.empId; });
  if (!emp) return;

  var cid = (typeof getActiveStorageCompanyId === 'function') ? getActiveStorageCompanyId()
          : (emp.company_id || null);

  window.leavesData = window.leavesData || [];

  var leave;
  if (existingId) {
    // تعديل إجازة موجودة
    var idx = window.leavesData.findIndex(function(l){ return l && l.id === existingId; });
    if (idx >= 0) {
      leave = window.leavesData[idx];
      leave.leaveType  = data.leaveType;
      leave.fromDate   = data.fromDate;
      leave.toDate     = data.toDate || null;
      leave.multiplier = data.multiplier || 1;
      leave.absenceDays = data.absenceDays || (data.leaveType === 'absence_mult' ? data.multiplier || 1 : 0);
      leave.note       = data.note || '';
      leave.empName    = emp.name;
      leave.dept       = emp.dept || '';
      leave.company_id = leave.company_id || cid;
      leave._pendingSync = true;
    }
  }

  if (!leave) {
    // إضافة إجازة جديدة
    leave = {
      id:         _leaveUniqueRef(data.empId),
      empId:      data.empId,
      empName:    emp.name,
      dept:       emp.dept || '',
      company_id: cid,
      leaveType:  data.leaveType,
      fromDate:   data.fromDate,
      toDate:     data.toDate || null,
      multiplier: data.multiplier || 1,
      absenceDays: data.absenceDays || (data.leaveType === 'absence_mult' ? data.multiplier || 1 : 0),
      note:       data.note || '',
      addedAt:    new Date().toISOString(),
      _pendingSync: true
    };
    window.leavesData.unshift(leave);

    // إشعار الموظف (فقط عند الإضافة، ليس التعديل)
    _addLeaveNotification(leave, emp);
    // إشعار المسؤول
    _addAdminLeaveNotification(leave, emp, existingId ? 'edit' : 'add');
  } else {
    _addAdminLeaveNotification(leave, emp, 'edit');
  }

  if (typeof saveData === 'function') saveData();
  if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(data.empId);

  // مزامنة مع Supabase مع مؤشر التحميل
  _syncLeaveToSupabase(leave, existingId);

  // تحديث شامل فوري
  _refreshAfterLeaveChange();
}
window.saveLeave = saveLeave;

// ─── حذف إجازة ───────────────────────────────────────────
function deleteLeave(leaveId) {
  if (!leaveId) return;
  Swal.fire({
    title: 'حذف الإجازة؟',
    text: 'سيتم حذف هذه الإجازة نهائياً وإلغاء أثرها على الراتب.',
    icon: 'warning',
    showCancelButton: true,
    confirmButtonText: 'حذف',
    cancelButtonText: 'إلغاء',
    confirmButtonColor: '#e53e3e',
    ...swalTheme()
  }).then(function(r) {
    if (!r.isConfirmed) return;
    var idx = (window.leavesData || []).findIndex(function(l){ return l && l.id === leaveId; });
    if (idx < 0) return;
    var removed = window.leavesData.splice(idx, 1)[0];
    if (removed) {
      var emp = (window.employees || []).find(function(e){ return e && e.id === removed.empId; });
      _addAdminLeaveNotification(removed, emp, 'delete');
    }
    if (typeof saveData === 'function') saveData();
    if (removed && removed.empId && typeof clearSalaryCacheForEmployee === 'function') {
      clearSalaryCacheForEmployee(removed.empId);
    }

    if (removed && typeof sb_deleteLeave === 'function') {
      var dlid = typeof KynoLoader !== 'undefined' ? KynoLoader.start('حذف الإجازة...') : null;
      var deletePromise = removed._remoteId
        ? sb_deleteLeave(removed._remoteId)
        : (typeof sb_deleteLeaveByRef === 'function' ? sb_deleteLeaveByRef(removed.id) : Promise.resolve(null));
      deletePromise.then(function() {
        if (dlid !== null && typeof KynoLoader !== 'undefined') KynoLoader.done(dlid, 'success', 'تم حذف الإجازة');
        if (removed && removed.empId && typeof refreshSalaryUiAfterPayrollChange === 'function') {
          refreshSalaryUiAfterPayrollChange([removed.empId]).catch(function (e) {
            console.warn('refreshSalaryUiAfterPayrollChange:', e);
          });
        }
      }).catch(function(e) {
        console.warn('sb_deleteLeave:', e);
        if (dlid !== null && typeof KynoLoader !== 'undefined') KynoLoader.done(dlid, 'error', 'تعذّر حذف الإجازة');
      });
    }

    // تحديث شامل فوري
    _refreshAfterLeaveChange();
  });
}
window.deleteLeave = deleteLeave;

// ─── إشعار الموظف ────────────────────────────────────────
function _addLeaveNotification(leave, emp) {
  if (!emp) return;
  var lInfo    = LEAVE_TYPES[leave.leaveType] || {};
  var dailyRate = typeof getEmpDailyRate === 'function' ? getEmpDailyRate(emp) : 0;
  if (!dailyRate && emp && (emp.salary || 0) > 0) {
    var md = typeof getStandardMonthDays === 'function' ? getStandardMonthDays() : 30;
    dailyRate = Math.floor((emp.salary || 0) / md);
  }
  var days      = (leave.leaveType === 'paid_open' || leave.leaveType === 'unpaid_open')
                  ? _leaveDaysCount(leave.fromDate, leave.toDate) : 1;
  var deduct = 0;
  if (leave.leaveType === 'unpaid_open')   deduct = Math.round(days * dailyRate);
  if (leave.leaveType === 'unpaid_single') deduct = dailyRate;
  if (leave.leaveType === 'absence_mult')  {
    days = _absenceDaysCount(leave);
    deduct = Math.round(days * dailyRate);
  }

  var body = lInfo.label + ' — ' + _leaveDateLabel(leave.fromDate);
  if (leave.toDate) body += ' إلى ' + _leaveDateLabel(leave.toDate);
  if (leave.leaveType === 'absence_mult') body += ' — غياب ' + days + ' يوم';
  if (deduct > 0) body += ' — خصم: ' + deduct.toLocaleString() + ' IQD';
  if (leave.note) body += ' — ' + leave.note;

  var notif = {
    id:     'leavn_' + leave.id,
    empId:  emp.id,
    type:   'leave',
    icon:   leave.leaveType === 'absence_mult' ? 'red' : (deduct > 0 ? 'orange' : 'green'),
    ico:    'fa-' + (lInfo.icon || 'calendar-alt'),
    title:  'إجازة جديدة: ' + lInfo.label,
    body:   body,
    unread: true,
    read:   false,
    ts:     new Date().toISOString(),
    store:  'empNotif',
    companyId: leave.company_id ||
      (typeof getActiveStorageCompanyId === 'function' ? getActiveStorageCompanyId() : null) ||
      (typeof saasCurrentUser !== 'undefined' && saasCurrentUser ? saasCurrentUser.company_id : null)
  };

  var appSettings = window.appSettings || {};
  appSettings.employeeNotifications = appSettings.employeeNotifications || [];
  appSettings.employeeNotifications.unshift(notif);

  // مزامنة مع Supabase
  if (typeof sb_addEmployeeNotification === 'function') {
    sb_addEmployeeNotification(emp.id, notif.title, notif.body, 'leave', notif.id)
      .catch(function(e){ console.warn('sb_addEmployeeNotification:', e); });
  }
  if (typeof schedulePersistNotifications === 'function') schedulePersistNotifications();
  if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
}

// ─── إشعار المسؤول (عبر logActivity الموحّد) ─────────────
function _addAdminLeaveNotification(leave, emp, action) {
  if (typeof logActivity !== 'function') return;
  var lInfo   = LEAVE_TYPES[leave.leaveType] || {};
  var empName = emp ? emp.name : (leave.empName || '');
  var dateStr = _leaveDateLabel(leave.fromDate);
  if (leave.toDate && leave.toDate !== leave.fromDate) dateStr += ' → ' + _leaveDateLabel(leave.toDate);
  var details = empName + ' — ' + (lInfo.label || leave.leaveType) + ' (' + dateStr + ')';
  if (leave.leaveType === 'absence_mult') details += ' — غياب ' + _absenceDaysCount(leave) + ' يوم';
  if (leave.note) details += ' — ' + leave.note;
  logActivity(action === 'edit' ? 'edit' : (action === 'delete' ? 'delete' : 'add'), 'leaves', details, {
    targetName: empName,
    empId: emp ? emp.id : leave.empId,
    targetEmpId: emp ? emp.id : leave.empId,
    leaveId: leave.id
  });
}

// ─── مزامنة إجازة مع Supabase ────────────────────────────
function _syncLeaveToSupabase(leave, isEdit) {
  if (typeof sb_upsertLeave !== 'function') return;
  var lid = typeof KynoLoader !== 'undefined'
    ? KynoLoader.start(isEdit ? 'تعديل الإجازة...' : 'حفظ الإجازة...')
    : null;

  sb_upsertLeave(leave).then(function(res) {
    if (res && res.ok && res.data && res.data.id) {
      leave._remoteId = res.data.id;
      leave._pendingSync = false;
      if (typeof saveData === 'function') saveData();
      if (lid !== null && typeof KynoLoader !== 'undefined')
        KynoLoader.done(lid, 'success', isEdit ? 'تم تعديل الإجازة' : 'تم حفظ الإجازة');
      if (leave.empId && typeof refreshSalaryUiAfterPayrollChange === 'function') {
        refreshSalaryUiAfterPayrollChange([leave.empId]).catch(function (e) {
          console.warn('refreshSalaryUiAfterPayrollChange:', e);
        });
      }
      return;
    }
    leave._pendingSync = true;
    if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
    if (typeof showPersistWarning === 'function') showPersistWarning('تعذّر حفظ الإجازة في السحابة — سيتم إعادة المحاولة');
    if (lid !== null && typeof KynoLoader !== 'undefined')
      KynoLoader.done(lid, 'error', 'تعذّر حفظ الإجازة');
  }).catch(function(e) {
    console.warn('sb_upsertLeave:', e);
    leave._pendingSync = true;
    if (typeof schedulePendingSyncRetry === 'function') schedulePendingSyncRetry();
    if (lid !== null && typeof KynoLoader !== 'undefined')
      KynoLoader.done(lid, 'error', 'تعذّر حفظ الإجازة');
  });
}

// ─── عرض إجازات الموظف في بروفايله ──────────────────────
function buildEmployeeLeaves(empId) {
  var container = document.getElementById('emp-leaves-list');
  if (!container) return;

  var empLeaves = (window.leavesData || []).filter(function(l){
    return l && l.empId === empId;
  }).sort(function(a, b){
    return (b.fromDate || '') > (a.fromDate || '') ? 1 : -1;
  });

  if (empLeaves.length === 0) {
    container.innerHTML = '<div style="text-align:center;padding:24px;color:var(--text-muted);font-size:13px">لا توجد إجازات مسجلة</div>';
    return;
  }

  var html = empLeaves.map(function(l) {
    var lInfo = LEAVE_TYPES[l.leaveType] || LEAVE_TYPES.paid_single;
    var days  = (l.leaveType === 'paid_open' || l.leaveType === 'unpaid_open')
                ? _leaveDaysCount(l.fromDate, l.toDate) : 1;
    var dateStr = _leaveDateLabel(l.fromDate);
    if (l.toDate && l.toDate !== l.fromDate) dateStr += ' → ' + _leaveDateLabel(l.toDate);
    return '<div class="emp-leave-item">' +
      '<div class="emp-leave-icon" style="background:' + lInfo.color + '20;color:' + lInfo.color + '">' +
        '<i class="fa ' + lInfo.icon + '"></i>' +
      '</div>' +
      '<div class="emp-leave-info">' +
        '<div class="emp-leave-type">' + (l.leaveType === 'absence_mult' ? ('غياب ' + _absenceDaysCount(l) + ' يوم') : lInfo.label) + '</div>' +
        '<div class="emp-leave-date">' + dateStr + ' — ' + (l.leaveType === 'absence_mult' ? _absenceDaysCount(l) : days) + ' يوم</div>' +
        (l.note ? '<div class="emp-leave-note">' + _esc(l.note) + '</div>' : '') +
      '</div>' +
    '</div>';
  }).join('');

  container.innerHTML = html;
}
window.buildEmployeeLeaves = buildEmployeeLeaves;

// ─── عرض إشعارات الموظف ──────────────────────────────────
function buildEmployeeLeaveNotifs(empId) {
  var container = document.getElementById('emp-leave-notifs');
  if (!container) return;
  if (typeof isEmployeePortalLocked === 'function' && isEmployeePortalLocked()) {
    container.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:8px">الإشعارات غير متاحة — الاشتراك منتهٍ</div>';
    return;
  }

  var sid = String(empId);
  var notifs = (((window.appSettings || {}).employeeNotifications) || []).filter(function(n) {
    return n && String(n.empId) === sid;
  });

  if (notifs.length === 0) {
    container.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:8px">لا توجد إشعارات مالية أو إجازات</div>';
    return;
  }

  container.innerHTML = notifs.slice(0, 10).map(function(n) {
    var isUnread = n.unread !== undefined ? !!n.unread : !n.read;
    var fType = n.financeType || n.type || '';
    var title = n.title || ((typeof NOTIF_FINANCE_LABELS !== 'undefined' && NOTIF_FINANCE_LABELS[fType]) ? NOTIF_FINANCE_LABELS[fType] : 'إشعار');
    var body = n.body || n.note || '';
    if (!body && (n.financeType || n.action) && typeof formatEmployeeFinanceNotificationBody === 'function') {
      var formatted = formatEmployeeFinanceNotificationBody(n);
      body = formatted.body;
      if (!n.title && formatted.title) title = formatted.title;
    } else if (!body && n.amount != null && typeof exactMoneyValue === 'function') {
      var amt = exactMoneyValue(n.amount, 0);
      if (amt > 0) body = 'بقيمة ' + amt.toLocaleString() + ' IQD';
    }
    var color = (fType === 'bonus') ? '#68d391'
      : (fType === 'loan' ? '#f6ad55'
      : (fType === 'deduction' || fType === 'absence' ? '#fc8181' : '#63b3ed'));
    var icon = n.ico || (fType === 'bonus' ? 'fa-gift' : (fType === 'loan' ? 'fa-hand-holding-usd' : (fType === 'leave' || fType === 'absence' ? 'fa-calendar-alt' : 'fa-minus-circle')));
    return '<div class="emp-notif-item ' + (isUnread ? 'unread' : '') + '" onclick="markLeaveNotifRead(\'' + _esc(String(n.id || '')) + '\')">' +
      '<i class="fa ' + _esc(icon) + '" style="color:' + color + ';margin-left:8px"></i>' +
      '<div><div style="font-size:13px;font-weight:600">' + _esc(title) + '</div>' +
      '<div style="font-size:11px;color:var(--text-muted)">' + _esc(body) + '</div></div>' +
    '</div>';
  }).join('');
}
window.buildEmployeeLeaveNotifs = buildEmployeeLeaveNotifs;

function markLeaveNotifRead(notifId) {
  var notifs = ((window.appSettings || {}).employeeNotifications) || [];
  var n = notifs.find(function(x){ return x && x.id === notifId; });
  if (n) {
    n.unread = false;
    n.read = true;
  }
  if (typeof saveData === 'function') saveData();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
  if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
  buildEmployeeLeaveNotifs((window.loggedInEmpId != null ? parseInt(window.loggedInEmpId, 10) : (n && n.empId)));
  if (typeof sb_markEmpNotifRead === 'function') {
    sb_markEmpNotifRead((n && n._remoteId) || notifId).catch(function(e){ console.warn('markEmpNotifRead:', e); });
  }
}
window.markLeaveNotifRead = markLeaveNotifRead;

// ─── عدد الإشعارات غير المقروءة للموظف ──────────────────
function countEmpLeaveUnread(empId) {
  var sid = String(empId);
  return ((window.appSettings || {}).employeeNotifications || []).filter(function(n) {
    var isUnread = n.unread !== undefined ? !!n.unread : !n.read;
    return n && String(n.empId) === sid && isUnread;
  }).length;
}
window.countEmpLeaveUnread = countEmpLeaveUnread;

// ─── شارة الإجازات في التنقل ─────────────────────────────
function buildLeaveBadge() {
  var el = document.getElementById('leaves-nav-badge');
  if (!el) return;
  var pending = (window.leavesData || []).filter(function(l){ return l && l._pendingSync; }).length;
  el.textContent = pending > 0 ? pending : '';
  el.style.display = pending > 0 ? '' : 'none';
}
window.buildLeaveBadge = buildLeaveBadge;

// ─── دالة مساعدة للإفلات من HTML ─────────────────────────
function _esc(s) {
  if (typeof BasmaSecurity !== 'undefined' && BasmaSecurity.escapeHtml) {
    return BasmaSecurity.escapeHtml(s);
  }
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function _escAttr(s) {
  return _esc(s).replace(/`/g, '&#96;');
}

// ─── تحميل الإجازات من Supabase ──────────────────────────
async function loadLeavesFromSupabase() {
  if (typeof syncLeavesFromSupabase === 'function') {
    try {
      var ok = await syncLeavesFromSupabase();
      if (ok) {
        if (typeof saveData === 'function') saveData();
        buildLeaves();
        buildLeaveBadge();
      }
    } catch (e) {
      console.warn('loadLeavesFromSupabase:', e);
    }
    return;
  }
  if (typeof sb_getLeaves !== 'function') return;
  try {
    var res = await sb_getLeaves();
    if (!res || !res.ok || !Array.isArray(res.data)) return;
    var remote = res.data.map(function(row) {
      return {
        id:         'leave_r_' + row.id,
        _remoteId:  row.id,
        empId:      row.employee_id,
        empName:    (function(){ var e = (window.employees||[]).find(function(x){ return x&&x.id===row.employee_id; }); return e ? e.name : ''; })(),
        dept:       (function(){ var e = (window.employees||[]).find(function(x){ return x&&x.id===row.employee_id; }); return e ? e.dept : ''; })(),
        company_id: row.company_id,
        leaveType:  row.leave_type,
        fromDate:   row.from_date,
        toDate:     row.to_date || null,
        multiplier: row.multiplier || 1,
        note:       row.note || '',
        addedAt:    row.added_at,
        leave_ref:  row.leave_ref,
        _pendingSync: false
      };
    });

    // دمج: احتفظ بالمحلي المعلّق، أضف الجديد من السحابة
    var localPending = (window.leavesData || []).filter(function(l){ return l && l._pendingSync; });
    var remoteRefs   = {};
    remote.forEach(function(r){ if (r.leave_ref) remoteRefs[r.leave_ref] = true; });

    var merged = remote.slice();
    localPending.forEach(function(l) {
      if (!remoteRefs[l.id]) merged.unshift(l);
    });

    window.leavesData = merged;
    if (typeof saveData === 'function') saveData();
    buildLeaves();
    buildLeaveBadge();
  } catch(e) {
    console.warn('loadLeavesFromSupabase:', e);
  }
}
window.loadLeavesFromSupabase = loadLeavesFromSupabase;

// ─── تحميل إشعارات الموظف من Supabase ───────────────────
async function loadEmpNotifsFromSupabase(empId) {
  if (!empId) return;
  if (typeof refreshLoggedInEmployeeNotifications === 'function') {
    try {
      await refreshLoggedInEmployeeNotifications({ limit: 80 });
    } catch (e) {
      console.warn('loadEmpNotifsFromSupabase:', e);
    }
    buildEmployeeLeaveNotifs(empId);
    if (typeof updateNotifBadges === 'function') updateNotifBadges();
    if (typeof renderEmployeeFinanceNotificationsRail === 'function') renderEmployeeFinanceNotificationsRail();
    return;
  }
  if (typeof sb_getEmployeeNotifications !== 'function') return;
  try {
    var res = await sb_getEmployeeNotifications(empId);
    if (!res || !res.ok || !Array.isArray(res.data)) return;
    var sid = String(empId);

    var remote = res.data.map(function(row) {
      return {
        id:     row.notif_ref || ('sbn_' + row.id),
        empId:  row.employee_id,
        type:   row.notif_type || 'info',
        icon:   row.notif_type === 'leave' ? 'blue' : 'info',
        ico:    row.notif_type === 'leave' ? 'fa-calendar-alt' : 'fa-bell',
        title:  row.title,
        body:   row.body || '',
        unread: !row.is_read,
        read:   !!row.is_read,
        ts:     new Date(row.created_at || 0).toISOString(),
        store:  'empNotif',
        companyId: row.company_id || (typeof getActiveStorageCompanyId === 'function' ? getActiveStorageCompanyId() : null)
      };
    });

    var appSettings = window.appSettings || (window.appSettings = {});
    appSettings.employeeNotifications = appSettings.employeeNotifications || [];
    var existing = (appSettings.employeeNotifications || []).filter(function(n){
      return n && String(n.empId) === sid;
    });
    var existIds = {};
    existing.forEach(function(n){ existIds[n.id] = true; });

    remote.forEach(function(rn) {
      var old = existing.find(function(n){ return n && n.id === rn.id; });
      if (old) {
        old.type = rn.type;
        old.icon = rn.icon;
        old.ico = rn.ico;
        old.title = rn.title;
        old.body = rn.body;
        old.ts = rn.ts || old.ts;
        old.store = rn.store;
        if (old.read !== true && old.unread !== false) old.unread = rn.unread;
        if (rn.unread === false) {
          old.unread = false;
          old.read = true;
        }
      } else if (!existIds[rn.id]) {
        appSettings.employeeNotifications.push(rn);
      }
    });

    if (typeof saveData === 'function') saveData();
    buildEmployeeLeaveNotifs(empId);
    if (typeof updateNotifBadges === 'function') updateNotifBadges();
  } catch(e) {
    console.warn('loadEmpNotifsFromSupabase:', e);
  }
}
window.loadEmpNotifsFromSupabase = loadEmpNotifsFromSupabase;
