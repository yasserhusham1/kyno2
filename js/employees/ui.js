/**
 * Employees grid UI
 */
import { escapeHtml, setElementHtml } from '../core/safe-render.js';

export function buildEmployees() {
  const grid = document.getElementById('emp-grid');
  if (!grid) return;

  const employees = window.employees || [];
  const empSearchQuery = (window.empSearchQuery || '').toLowerCase();
  const canEdit = typeof window.hasActionPermission === 'function' ? window.hasActionPermission('employees', 'edit') : true;
  const canDelete = typeof window.hasActionPermission === 'function' ? window.hasActionPermission('employees', 'delete') : true;
  const sanitizeAvatarUrl =
    typeof window.sanitizeAvatarUrl === 'function' ? window.sanitizeAvatarUrl : () => '';

  const list = employees.filter((e) => {
    if (!empSearchQuery) return true;
    const q = empSearchQuery;
    return (
      String(e.name || '').toLowerCase().includes(q) ||
      String(e.dept || '').toLowerCase().includes(q) ||
      String(e.role || '').toLowerCase().includes(q) ||
      (e.phone && String(e.phone).includes(q))
    );
  });

  if (!list.length) {
    setElementHtml(
      grid,
      `<div style="grid-column:1/-1;text-align:center;padding:48px;color:var(--text-muted)"><i class="fa fa-users" style="font-size:48px;opacity:0.3;display:block;margin-bottom:12px"></i>${empSearchQuery ? 'لا توجد نتائج للبحث' : 'لا يوجد موظفون — اضغط إضافة موظف'}</div>`
    );
    return;
  }

  const html = list
    .map((e) => {
      const esc = escapeHtml;
      const avatarSafe = sanitizeAvatarUrl(e.avatarUrl);
      const fmtTime =
        typeof window.fmtTimeDisplay === 'function'
          ? window.fmtTimeDisplay
          : typeof window.formatDisplayTime === 'function'
            ? window.formatDisplayTime
            : (t) => t;
      const checkInDisplay = fmtTime(e.checkIn || '08:00');
      const checkOutDisplay = fmtTime(e.checkOut || '17:00');
      const deviceBadges = (e.devices || [])
        .map((d) => {
          if (d.fingerprint) {
            return (
              '<span class="emp-ip-badge" title="بصمة: ' +
              esc(d.fingerprint) +
              '">📱 ' +
              esc(d.fingerprint.substring(0, 10)) +
              '...</span>'
            );
          }
          if (d.ip) return '<span class="emp-ip-badge">' + esc(d.ip) + '</span>';
          return '';
        })
        .join('');
      return `
    <div class="emp-card">
      <div class="emp-card-top">
        <div class="emp-avatar ${esc(e.avatarClass)}" style="position:relative;overflow:hidden">${avatarSafe ? '<img src="' + avatarSafe + '" style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;border-radius:14px">' : esc(e.avatar)}</div>
        <div>
          <div class="emp-name">${esc(e.name)}</div>
          <div class="emp-dept">${esc(e.dept)}</div>
          <div class="emp-role">${esc(e.role)}</div>
        </div>
      </div>
      <div class="emp-stats">
        <div class="emp-stat">
          <div class="emp-stat-val" style="color:var(--accent)">${e.days}</div>
          <div class="emp-stat-lbl">أيام حضور</div>
        </div>
        <div class="emp-stat">
          <div class="emp-stat-val" style="color:${e.lateMin > 0 ? '#f6e05e' : '#68d391'}">${e.lateMin > 0 ? e.lateMin + 'د' : '0'}</div>
          <div class="emp-stat-lbl">تأخير</div>
        </div>
        <div class="emp-stat" style="grid-column:1/-1">
          <div class="emp-stat-val" style="color:#63b3ed;font-size:14px">${Number(e.salary || 0).toLocaleString()} IQD</div>
          <div class="emp-stat-lbl">الراتب الشهري</div>
        </div>
      </div>
      <div style="font-size:11px;color:var(--text-muted);margin:8px 0"><i class="fa fa-clock"></i> ${esc(checkInDisplay)} → ${esc(checkOutDisplay)}${e.remoteAttend ? ' · <span style="color:#68d391">📍 أي مكان</span>' : ''}${e.openHours ? ' · <span style="color:#63b3ed">🕐 مفتوح</span>' : ''}</div>
      <div style="margin-bottom:8px">${deviceBadges || '<span style="font-size:10px;color:var(--text-muted)">بدون أجهزة مسجّلة</span>'}</div>
      <div class="emp-actions">
        <button class="btn-sm btn-primary" onclick="viewEmp(${e.id})" title="تفاصيل"><i class="fa fa-eye"></i></button>
        ${canEdit ? `<button class="btn-sm btn-primary" onclick="editEmp(${e.id})" title="تعديل"><i class="fa fa-edit"></i></button>` : ''}
        <button class="btn-sm btn-primary" onclick="showEmployeeBarcodes(${e.id})" title="QR"><i class="fa fa-qrcode"></i></button>
        ${(typeof hasActionPermission !== 'function' || hasActionPermission('leaves','add')) ? `<button class="btn-sm" style="background:linear-gradient(135deg,#744210,#975a16)" onclick="openAddLeaveForm(${e.id})" title="إضافة إجازة"><i class="fa fa-calendar-alt"></i></button>` : ''}
        ${canDelete ? `<button class="btn-sm btn-danger" onclick="deleteEmp(${e.id})" title="حذف"><i class="fa fa-trash"></i></button>` : ''}
      </div>
    </div>`;
    })
    .join('');

  setElementHtml(grid, html);
}

if (typeof window !== 'undefined') {
  window.buildEmployees = buildEmployees;
}
