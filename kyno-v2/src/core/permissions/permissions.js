/**
 * KYNO v2 — Unified Permissions System
 *
 * مدمج من 3 ملفات في v1:
 *   js/core/permissions.js           → BasmaPermissions (canAccessPage, requireAuth)
 *   js/core/permission-matrix.js     → BasmaPermissionMatrix (modules, actions, hasActionPermission)
 *   js/core/super-admin-permissions.js → SA permissions (canSuperAdmin, normalizeSuperAdmin)
 *
 * المنطق: محتفظ به كما هو — لا تعديل في Business Logic.
 * الفرق الوحيد: تحويل من IIFE + globals إلى ES module exports.
 */

'use strict';

// =============================================================================
// 1. Role Levels (من permissions.js)
// =============================================================================

export const ROLES = {
  super_admin:   100,
  company_admin:  80,
  company_user:   50,
  employee:       10,
};

export function roleLevel(role) {
  return ROLES[role] || 0;
}

// =============================================================================
// 2. Company User — Module & Action Matrix (من permission-matrix.js)
// =============================================================================

export const MODULES = {
  dashboard:          { label: 'لوحة التحكم',             actions: { view: 'عرض' } },
  employees:          { label: 'الموظفون',                actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' } },
  attendance:         { label: 'الحضور والانصراف',        actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف', batch_delete: 'حذف دفعة', export: 'تصدير' } },
  device_mgmt:        { label: 'بصمة الأجهزة',            actions: { view: 'عرض', edit: 'تعديل' } },
  leaves:             { label: 'الإجازات والغياب',        actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' } },
  salaries:           { label: 'الرواتب',                 actions: { view: 'عرض', add: 'إصدار', edit: 'تعديل', delete: 'حذف', export: 'تصدير', paid_view: 'عرض الرواتب المدفوعة', paid_edit: 'تعديل الرواتب المدفوعة', paid_delete: 'حذف الرواتب المدفوعة' } },
  finance:            { label: 'الخصومات والسلف',         actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف', export: 'تصدير' } },
  org:                { label: 'الأقسام والوظائف',        actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' } },
  reports:            { label: 'التقارير',                actions: { view: 'عرض', export: 'تصدير' } },
  notifications:      { label: 'الإشعارات والأرشيف',     actions: { view: 'عرض', read_all: 'قراءة الكل', clear_all: 'حذف الكل', export: 'تصدير الأرشيف' } },
  settings:           { label: 'الإعدادات',               actions: { view: 'عرض', edit: 'تعديل' } },
  users_permissions:  { label: 'المستخدمون والصلاحيات',  actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' } },
};

/** للتوافق مع الكود القديم (صفحة واحدة = module key) */
export const LEGACY_PAGE_KEYS = {
  dashboard:            'dashboard',
  employees:            'employees',
  attendance:           'attendance',
  'device-mgmt':        'device_mgmt',
  leaves:               'leaves',
  salaries:             'salaries',
  finance:              'finance',
  org:                  'org',
  reports:              'reports',
  notifications:        'notifications',
  settings:             'settings',
  users_permissions:    'users_permissions',
  'users-permissions':  'users_permissions',
};

export function permKey(module, action) {
  return action === 'view' ? module : `${module}_${action}`;
}

export function isTruthyPerm(value) {
  return value === true || value === 1 || value === '1' || value === 'true';
}

function moduleHasGranularKeys(perms, mod) {
  if (!perms || !MODULES[mod]) return false;
  return Object.keys(perms).some((k) => k.startsWith(mod + '_'));
}

function isModuleFullyGranted(perms, mod) {
  if (!MODULES[mod]) return false;
  return Object.keys(MODULES[mod].actions).every((act) => perms[permKey(mod, act)] === true);
}

/** يُطبّع كائن permissions — يحوّل legacy format إلى granular keys */
export function normalizePermissions(perms) {
  if (!perms) return {};
  if (typeof perms === 'string') {
    try { perms = JSON.parse(perms) || {}; } catch { return {}; }
  }
  const out = {};
  Object.keys(perms).forEach((k) => {
    if (k === 'super_admin' && perms[k] && typeof perms[k] === 'object' && !Array.isArray(perms[k])) {
      out[k] = perms[k];
      return;
    }
    out[k] = isTruthyPerm(perms[k]);
  });
  Object.keys(MODULES).forEach((mod) => {
    const actions = MODULES[mod].actions;
    const hasGranular = moduleHasGranularKeys(perms, mod);
    if (hasGranular) {
      Object.keys(actions).forEach((act) => {
        const pk = permKey(mod, act);
        if (out[pk] === undefined) out[pk] = false;
      });
    } else if (out[mod] === true) {
      Object.keys(actions).forEach((act) => {
        const pk = permKey(mod, act);
        if (out[pk] === undefined) out[pk] = true;
      });
    } else {
      Object.keys(actions).forEach((act) => {
        const pk = permKey(mod, act);
        if (out[pk] === undefined) out[pk] = false;
      });
    }
  });
  // تراث: ارث صلاحيات الأجهزة من صلاحيات الموظفين إذا لم تُضبط
  if (!moduleHasGranularKeys(perms, 'device_mgmt')) {
    const empGranular = moduleHasGranularKeys(perms, 'employees');
    if (!empGranular && out.employees === true) {
      out.device_mgmt = true;
      out.device_mgmt_edit = true;
    } else if (out.employees_edit === true) {
      out.device_mgmt = true;
      out.device_mgmt_edit = true;
    } else if (out.employees === true || out.employees_view === true) {
      out.device_mgmt = true;
    }
  }
  return out;
}

export function isPrivilegedUser(user) {
  if (!user) return false;
  return user.role === 'super_admin' || user.role === 'company_admin';
}

/** يتحقق من صلاحية action معين لمستخدم */
export function hasActionPermission(user, module, action) {
  if (!user) return false;
  if (isPrivilegedUser(user)) return true;
  const perms = normalizePermissions(user.permissions);
  const key = permKey(module, action);
  const granular = moduleHasGranularKeys(user.permissions || {}, module);
  if (action === 'view') {
    if (perms[key] === true) return true;
    if (!granular && perms[module] === true) return true;
    return Object.keys(MODULES[module]?.actions || {}).some(
      (act) => act !== 'view' && perms[permKey(module, act)] === true
    );
  }
  if (granular) return perms[key] === true;
  if (perms[module] === true) return true;
  return perms[key] === true;
}

export function hasPagePermission(user, pageId) {
  const mod = LEGACY_PAGE_KEYS[pageId] || pageId;
  return hasActionPermission(user, mod, 'view');
}

export function permissionLabel(module, action) {
  const m = MODULES[module];
  if (!m || !m.actions[action]) return `${module}.${action}`;
  return `${m.label} — ${m.actions[action]}`;
}

/** يُرجع عدد الصلاحيات الممنوحة لمستخدم */
export function countUserPermissions(user) {
  if (!user) return 0;
  if (isPrivilegedUser(user)) {
    return Object.values(MODULES).reduce((t, m) => t + Object.keys(m.actions).length, 0);
  }
  const perms = normalizePermissions(user.permissions);
  let count = 0;
  Object.keys(MODULES).forEach((mod) => {
    Object.keys(MODULES[mod].actions).forEach((act) => {
      if (perms[permKey(mod, act)] === true) count++;
    });
  });
  return count;
}

// =============================================================================
// 3. Super Admin Permissions (من super-admin-permissions.js)
// =============================================================================

export const SA_WRITE_KEYS = [
  'companies_create', 'companies_edit', 'companies_delete', 'companies_suspend',
  'subscriptions_renew', 'subscriptions_edit', 'subscriptions_delete',
  'users_manage',
  'platform_whatsapp', 'platform_announce', 'platform_announce_manage',
  'team_manage',
];

export const SA_PERM_DEFS = [
  { key: 'view_only',                  label: 'وضع العرض فقط (بدون تعديل أو حذف)',  group: 'عام',          isMode: true },
  { key: 'companies_view',             label: 'عرض الشركات',                         group: 'الشركات',      isView: true },
  { key: 'companies_create',           label: 'إنشاء شركة',                          group: 'الشركات',      isWrite: true },
  { key: 'companies_edit',             label: 'تعديل شركة',                          group: 'الشركات',      isWrite: true },
  { key: 'companies_delete',           label: 'حذف شركة',                            group: 'الشركات',      isWrite: true },
  { key: 'companies_suspend',          label: 'إيقاف / تفعيل شركة',                 group: 'الشركات',      isWrite: true },
  { key: 'subscriptions_view',         label: 'عرض الاشتراكات',                      group: 'الاشتراكات',   isView: true },
  { key: 'subscriptions_edit',         label: 'تعديل اشتراك',                        group: 'الاشتراكات',   isWrite: true },
  { key: 'subscriptions_renew',        label: 'تمديد اشتراك',                        group: 'الاشتراكات',   isWrite: true },
  { key: 'subscriptions_delete',       label: 'حذف سجل اشتراك',                      group: 'الاشتراكات',   isWrite: true },
  { key: 'users_view',                 label: 'عرض مستخدمي الشركات',                 group: 'المستخدمون',   isView: true },
  { key: 'users_manage',               label: 'إدارة مستخدمي الشركات',               group: 'المستخدمون',   isWrite: true },
  { key: 'platform_view',              label: 'عرض إعدادات المنصة',                  group: 'المنصة',       isView: true },
  { key: 'platform_whatsapp',          label: 'تعديل أرقام واتساب',                  group: 'المنصة',       isWrite: true },
  { key: 'platform_announce',          label: 'إرسال إشعار للشركات',                 group: 'المنصة',       isWrite: true },
  { key: 'platform_announce_manage',   label: 'تعديل / حذف الإشعارات',              group: 'المنصة',       isWrite: true },
  { key: 'team_manage',                label: 'إدارة فريق السوبر أدمن',              group: 'الفريق',       isWrite: true },
  { key: 'stats_view',                 label: 'عرض الإحصائيات',                      group: 'التقارير',     isView: true },
  { key: 'monitoring_view',            label: 'مراقبة النظام',                        group: 'التقارير',     isView: true },
  { key: 'backup_manage',              label: 'مركز النسخ الاحتياطي',                group: 'التقارير',     isWrite: true },
  { key: 'settings_view',              label: 'عرض الإعدادات الشخصية',               group: 'عام',          isView: true },
];

const SA_DEFAULTS = { view_only: false, job_title: '' };
SA_PERM_DEFS.forEach((d) => {
  if (d.key !== 'view_only' && d.key !== 'job_title') SA_DEFAULTS[d.key] = true;
});

function extractSuperBlock(perms) {
  if (!perms) return {};
  if (typeof perms === 'string') {
    try { perms = JSON.parse(perms); } catch { return {}; }
  }
  if (perms.companies_view !== undefined || perms.team_manage !== undefined || perms.view_only !== undefined) {
    return perms;
  }
  const block = perms.super_admin;
  if (!block || typeof block !== 'object' || Array.isArray(block)) return {};
  return block;
}

/** يُطبّع صلاحيات Super Admin Member */
export function normalizeSuperAdminPermissions(perms) {
  const block = extractSuperBlock(perms);
  const out = { ...SA_DEFAULTS };
  Object.keys(block).forEach((k) => {
    if (k === 'job_title') {
      out.job_title = String(block[k] || '').trim();
      return;
    }
    if (k === 'view_only') {
      out.view_only = block[k] === true;
      return;
    }
    if (Object.prototype.hasOwnProperty.call(SA_DEFAULTS, k)) {
      out[k] = block[k] === true;
    }
  });
  if (out.view_only) {
    SA_WRITE_KEYS.forEach((wk) => { out[wk] = false; });
  }
  const anyGranted = SA_PERM_DEFS.some((d) => out[d.key] === true);
  if (!anyGranted && Object.keys(block).length > 0) return { ...SA_DEFAULTS };
  return out;
}

/** يتحقق من صلاحية SA Member لعملية معينة */
export function canSuperAdmin(user, action) {
  if (!user || user.role !== 'super_admin') return false;
  const n = normalizeSuperAdminPermissions(user.permissions);
  if (n.view_only && SA_WRITE_KEYS.includes(action)) return false;
  return n[action] === true;
}

/** يتحقق من صلاحية أي من العمليات */
export function canSuperAdminAny(user, actions) {
  if (!Array.isArray(actions)) return canSuperAdmin(user, actions);
  return actions.some((a) => canSuperAdmin(user, a));
}

/** يتحقق من صلاحية وصول SA Member لصفحة معينة */
export function canSuperAdminPage(user, pageId) {
  if (!user || user.role !== 'super_admin') return false;
  const map = {
    superadmin:         ['companies_view', 'stats_view', 'subscriptions_view', 'users_view', 'platform_view'],
    'sa-companies':     ['companies_view'],
    'sa-subscriptions': ['subscriptions_view', 'subscriptions_edit', 'subscriptions_renew', 'subscriptions_delete'],
    'sa-users':         ['users_view', 'users_manage'],
    'sa-platform':      ['platform_view', 'platform_whatsapp', 'platform_announce', 'platform_announce_manage'],
    'sa-stats':         ['stats_view'],
    'sa-monitoring':    ['monitoring_view', 'stats_view'],
    'sa-backup':        ['backup_manage', 'companies_view'],
    'sa-team':          ['team_manage'],
    'sa-settings':      ['settings_view'],
  };
  const perms = map[pageId];
  if (!perms) return true;
  return canSuperAdminAny(user, perms);
}

export function getSuperAdminJobTitle(user) {
  if (!user) return '';
  return normalizeSuperAdminPermissions(user.permissions).job_title || user.job_title || '';
}

export function isSuperAdminViewOnly(user) {
  if (!user || user.role !== 'super_admin') return false;
  return normalizeSuperAdminPermissions(user.permissions).view_only === true;
}

// =============================================================================
// 4. Route Guard (من permissions.js)
// =============================================================================

/**
 * يتحقق من صلاحية الوصول لصفحة
 * يدعم كلا النوعين: صفحات company (/dashboard) وصفحات SA (/sa-*)
 */
export function canAccessPage(user, pageId) {
  if (!user) return false;
  if (user.role === 'super_admin') return canSuperAdminPage(user, pageId);
  if (user.role === 'company_admin') return true;
  return hasPagePermission(user, pageId);
}
