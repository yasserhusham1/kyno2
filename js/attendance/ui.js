/**
 * Attendance table UI — escaped dynamic fields
 */
import { escapeHtml, setElementHtml, escAttr } from '../core/safe-render.js';

export function buildAttendance() {
  const tbody = document.getElementById('att-table');
  if (!tbody) return;

  const employees = window.employees || [];
  const attData = window.attData || [];
  const esc = escapeHtml;
  const canEditAtt = typeof window.hasActionPermission === 'function' ? window.hasActionPermission('attendance', 'edit') : true;
  const canDeleteAtt = typeof window.hasActionPermission === 'function' ? window.hasActionPermission('attendance', 'delete') : true;
  const todayAttDateFn =
    typeof window.todayAttDate === 'function' ? window.todayAttDate : () => '';
  const isTodayFn =
    typeof window.isAttendanceRecordToday === 'function'
      ? window.isAttendanceRecordToday
      : (r) => r && r.date === todayAttDateFn();

  const deptFilter = document.getElementById('att-filter-dept');
  if (deptFilter) {
    const currentVal = deptFilter.value;
    const depts = [...new Set(employees.map((e) => e.dept))];
    deptFilter.innerHTML =
      '<option value="">كل الأقسام</option>' +
      depts.map((d) => '<option value="' + escAttr(d) + '">' + esc(d) + '</option>').join('');
    deptFilter.value = currentVal;
  }

  const fDept = document.getElementById('att-filter-dept')?.value || '';
  const fPeriod = document.getElementById('att-filter-period')?.value || 'today';
  const fStatus = document.getElementById('att-filter-status')?.value || '';
  const fName =
    typeof window.getEmployeeNameQuery === 'function'
      ? window.getEmployeeNameQuery('att-filter-name')
      : (document.getElementById('att-filter-name')?.value || '').trim().toLowerCase();

  let filtered = [...attData];
  if (fDept) filtered = filtered.filter((r) => r.dept === fDept);
  if (fStatus) filtered = filtered.filter((r) => r.status === fStatus);
  if (fName) {
    filtered = filtered.filter((r) =>
      typeof window.attendanceRecordMatchesNameQuery === 'function'
        ? window.attendanceRecordMatchesNameQuery(r, fName, employees)
        : String(r.emp || '').toLowerCase().includes(fName)
    );
  }

  if (fPeriod === 'today') {
    filtered = filtered.filter((r) => isTodayFn(r));
  } else if (fPeriod === 'week') {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 6);
    cutoff.setHours(0, 0, 0, 0);
    filtered = filtered.filter((r) => {
      const iso = r.dateIso || r.date_iso || '';
      if (iso) return new Date(iso) >= cutoff;
      return false;
    });
  }

  const statusMap = {
    طبيعي: 'badge-success',
    متأخر: 'badge-warning',
    غياب: 'badge-danger',
    إضافي: 'badge-info'
  };
  const statusIcon = { طبيعي: '🟢', متأخر: '🟡', غياب: '🔴', إضافي: '🔵' };

  if (filtered.length === 0) {
    setElementHtml(
      tbody,
      '<tr><td colspan="11" style="text-align:center;padding:32px;color:var(--text-muted)"><i class="fa fa-calendar-check" style="font-size:36px;opacity:0.3;display:block;margin-bottom:8px"></i>لا توجد سجلات حضور مطابقة</td></tr>'
    );
    return;
  }

  const rows = filtered
    .map((r, i) => {
      const fmt = typeof window.fmtTimeDisplay === 'function' ? window.fmtTimeDisplay : function (t) { return t; };
      const ciDisplay = r.ci !== '—' ? esc(fmt(r.ci)) : '<span style="color:#fc8181">—</span>';
      const coDisplay = r.co !== '—' ? esc(fmt(r.co)) : '<span style="color:#fc8181">—</span>';
      const attEmp = employees.find((e) => e.id === r.empId);
      const eType = attEmp ? attEmp.salaryType || 'monthly' : 'monthly';
      const typeBadge =
        eType === 'commission'
          ? '<span style="font-size:9px;padding:1px 5px;border-radius:3px;background:rgba(246,224,94,0.15);color:#f6e05e;margin-right:3px">عمولة</span>'
          : eType === 'biweekly'
            ? '<span style="font-size:9px;padding:1px 5px;border-radius:3px;background:rgba(99,179,237,0.15);color:#63b3ed;margin-right:3px">15ي</span>'
            : '';
      const dateDisplay =
        typeof window.formatAttendanceDisplayDate === 'function'
          ? window.formatAttendanceDisplayDate(r)
          : r.date;
      const fmtHrs = typeof window.formatWorkHoursDisplay === 'function'
        ? window.formatWorkHoursDisplay(r, attEmp)
        : (r.hrs !== '—' ? r.hrs : '—');
      const dateJs = escAttr(r.date).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
      return (
        '<tr>' +
        '<td>' +
        (i + 1) +
        '</td>' +
        '<td><strong>' +
        typeBadge +
        esc(typeof window.attRecordDisplayName === 'function' ? window.attRecordDisplayName(r) : (r.emp || '')) +
        '</strong></td>' +
        '<td style="color:var(--text-muted)">' +
        esc(r.dept) +
        '</td>' +
        '<td>' +
        esc(dateDisplay) +
        '</td>' +
        '<td style="direction:ltr;text-align:right">' +
        ciDisplay +
        '</td>' +
        '<td style="direction:ltr;text-align:right">' +
        coDisplay +
        '</td>' +
        '<td>' +
        esc(fmtHrs) +
        '</td>' +
        '<td>' +
        (r.late !== '—' ? '<span style="color:#f6e05e">⏱ ' + esc(r.late) + '</span>' : '—') +
        '</td>' +
        '<td>' +
        (r.ot !== '—' ? '<span style="color:#63b3ed">+ ' + esc(r.ot) + '</span>' : '—') +
        '</td>' +
        '<td><span class="badge ' +
        (statusMap[r.status] || 'badge-success') +
        '">' +
        (statusIcon[r.status] || '') +
        ' ' +
        esc(r.status) +
        '</span></td>' +
        '<td>' +
        (canEditAtt ? '<button class="btn-sm btn-primary" style="padding:5px 10px;margin:2px" onclick="editAttRecord(' +
        r.empId +
        ", '" +
        dateJs +
        '\')" title="تعديل"><i class="fa fa-edit"></i></button>' : '') +
        (canDeleteAtt ? '<button class="btn-sm btn-danger" style="padding:5px 10px;margin:2px" onclick="deleteAttRecord(' +
        r.empId +
        ", '" +
        dateJs +
        '\')" title="حذف"><i class="fa fa-trash"></i></button>' : '') +
        '</td>' +
        '</tr>'
      );
    })
    .join('');

  setElementHtml(tbody, rows);
}

if (typeof window !== 'undefined') {
  window.buildAttendance = buildAttendance;
}
