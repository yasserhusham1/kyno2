/**
 * مصفوفة صلاحيات تفصيلية — عرض / إضافة / تعديل / حذف لكل وحدة
 */
(function (global) {
  'use strict';

  var MODULES = {
    dashboard: {
      label: 'لوحة التحكم',
      actions: { view: 'عرض' }
    },
    employees: {
      label: 'الموظفون',
      actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' }
    },
    attendance: {
      label: 'الحضور والانصراف',
      actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف', batch_delete: 'حذف دفعة', export: 'تصدير' }
    },
    device_mgmt: {
      label: 'بصمة الأجهزة',
      actions: { view: 'عرض', edit: 'تعديل' }
    },
    leaves: {
      label: 'الإجازات والغياب',
      actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' }
    },
    salaries: {
      label: 'الرواتب',
      actions: { view: 'عرض', add: 'إصدار', edit: 'تعديل', delete: 'حذف', export: 'تصدير', paid_view: 'عرض الرواتب المدفوعة', paid_edit: 'تعديل الرواتب المدفوعة', paid_delete: 'حذف الرواتب المدفوعة' }
    },
    finance: {
      label: 'الخصومات والسلف',
      actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف', export: 'تصدير' }
    },
    org: {
      label: 'الأقسام والوظائف',
      actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' }
    },
    reports: {
      label: 'التقارير',
      actions: { view: 'عرض', export: 'تصدير' }
    },
    notifications: {
      label: 'الإشعارات والأرشيف',
      actions: {
        view: 'عرض',
        read_all: 'قراءة الكل',
        clear_all: 'حذف الكل',
        export: 'تصدير الأرشيف'
      }
    },
    settings: {
      label: 'الإعدادات',
      actions: { view: 'عرض', edit: 'تعديل' }
    },
    users_permissions: {
      label: 'المستخدمون والصلاحيات',
      actions: { view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف' }
    }
  };

  /** للتوافق مع الكود القديم (صفحة واحدة = true) */
  var LEGACY_PAGE_KEYS = {
    dashboard: 'dashboard',
    employees: 'employees',
    attendance: 'attendance',
    'device-mgmt': 'device_mgmt',
    leaves: 'leaves',
    salaries: 'salaries',
    finance: 'finance',
    org: 'org',
    reports: 'reports',
    notifications: 'notifications',
    settings: 'settings',
    users_permissions: 'users_permissions',
    'users-permissions': 'users_permissions'
  };

  function permKey(module, action) {
    return action === 'view' ? module : module + '_' + action;
  }

  function moduleHasGranularKeys(perms, mod) {
    if (!perms || !MODULES[mod]) return false;
    return Object.keys(perms).some(function (k) {
      return k.indexOf(mod + '_') === 0;
    });
  }

  function isModuleFullyGranted(perms, mod) {
    if (!MODULES[mod]) return false;
    return Object.keys(MODULES[mod].actions).every(function (act) {
      return perms[permKey(mod, act)] === true;
    });
  }

  function isTruthyPerm(value) {
    return value === true || value === 1 || value === '1' || value === 'true';
  }

  function normalizePermissions(perms) {
    if (!perms) return {};
    if (typeof perms === 'string') {
      try { perms = JSON.parse(perms) || {}; } catch (e) { return {}; }
    }
    var out = {};
    Object.keys(perms).forEach(function (k) {
      if (k === 'super_admin' && perms[k] && typeof perms[k] === 'object' && !Array.isArray(perms[k])) {
        out[k] = perms[k];
        return;
      }
      out[k] = isTruthyPerm(perms[k]);
    });
    Object.keys(MODULES).forEach(function (mod) {
      var actions = MODULES[mod].actions;
      var hasGranular = moduleHasGranularKeys(perms, mod);

      if (hasGranular) {
        Object.keys(actions).forEach(function (act) {
          var pk = permKey(mod, act);
          if (out[pk] === undefined) out[pk] = false;
        });
      } else if (out[mod] === true) {
        Object.keys(actions).forEach(function (act) {
          var pk = permKey(mod, act);
          if (out[pk] === undefined) out[pk] = true;
        });
      } else {
        Object.keys(actions).forEach(function (act) {
          var pk = permKey(mod, act);
          if (out[pk] === undefined) out[pk] = false;
        });
      }
    });
    // تراث: إذا لم تُضبط صلاحيات البصمة بعد، ارث من صلاحيات الموظفين
    if (!moduleHasGranularKeys(perms, 'device_mgmt')) {
      var empGranular = moduleHasGranularKeys(perms, 'employees');
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

  function isPrivilegedUser(user) {
    if (!user) return false;
    return user.role === 'super_admin' || user.role === 'company_admin';
  }

  function getCurrentUser() {
    return global.saasCurrentUser || global._saasCurrentUser || null;
  }

  function hasActionPermission(module, action) {
    var user = getCurrentUser();
    if (!user) return false;
    if (isPrivilegedUser(user)) return true;
    if (global.currentUser !== 'admin') return false;
    var perms = normalizePermissions(user.permissions);
    var key = permKey(module, action);
    var granular = moduleHasGranularKeys(user.permissions || {}, module);
    if (action === 'view') {
      if (perms[key] === true) return true;
      if (!granular && perms[module] === true) return true;
      return Object.keys(MODULES[module].actions).some(function (act) {
        return act !== 'view' && perms[permKey(module, act)] === true;
      });
    }
    if (granular) return perms[key] === true;
    if (perms[module] === true) return true;
    return perms[key] === true;
  }

  function hasCompanyPermission(pageId) {
    var mod = LEGACY_PAGE_KEYS[pageId] || pageId;
    return hasActionPermission(mod, 'view');
  }

  function permissionLabel(module, action) {
    var m = MODULES[module];
    if (!m || !m.actions[action]) return module + '.' + action;
    return m.label + ' — ' + m.actions[action];
  }

  function denyPermission(module, action) {
    var label = permissionLabel(module, action);
    if (typeof global.Swal !== 'undefined') {
      global.Swal.fire({
        icon: 'warning',
        title: 'غير مسموح',
        html: 'لا تملك صلاحية: <b>' + label + '</b>',
        confirmButtonText: 'حسناً',
        ...(typeof swalTheme === 'function' ? swalTheme() : {})
      });
    } else if (global.BasmaToast) {
      global.BasmaToast.warn('لا تملك صلاحية: ' + label);
    }
    return false;
  }

  function requireActionPermission(module, action) {
    if (hasActionPermission(module, action)) return true;
    denyPermission(module, action);
    return false;
  }

  function permissionMatrixHtml(perms) {
    perms = normalizePermissions(perms);
    var escLabel = typeof global.esc === 'function' ? global.esc : function (v) { return String(v || ''); };
    var html = '';
    Object.keys(MODULES).forEach(function (mod) {
      var def = MODULES[mod];
      html += '<div class="perm-module-block">';
      html += '<div class="perm-module-title"><i class="fa fa-layer-group"></i> ' + escLabel(def.label) + '</div>';
      html += '<div class="perm-action-grid">';
      Object.keys(def.actions).forEach(function (act) {
        var pk = permKey(mod, act);
        var checked = perms[pk] === true;
        var active = checked ? ' active' : '';
        html += ''
          + '<label class="emp-option-card perm-card perm-action-card' + active + '">'
          + '<input type="checkbox" class="perm-check" data-module="' + escLabel(mod) + '" data-action="' + escLabel(act) + '" value="' + escLabel(pk) + '" ' + (checked ? 'checked' : '') + ' style="display:none">'
          + '<span class="option-check" aria-hidden="true"></span>'
          + '<span class="emp-option-title">' + escLabel(def.actions[act]) + '</span>'
          + '</label>';
      });
      html += '</div></div>';
    });
    return html;
  }

  function readPermissionsFromForm(root, existingPerms) {
    var result = {};
    Object.keys(MODULES).forEach(function (mod) {
      result[mod] = false;
      Object.keys(MODULES[mod].actions).forEach(function (act) {
        result[permKey(mod, act)] = false;
      });
    });
    var scope = root && root.querySelectorAll ? root : null;
    if (!scope && global.document) {
      var popup = global.document.querySelector('.swal2-popup .perm-matrix-wrap');
      scope = popup || global.document.querySelector('.perm-matrix-wrap');
    }
    var checks = scope && scope.querySelectorAll
      ? scope.querySelectorAll('.perm-check')
      : (global.document ? global.document.querySelectorAll('.perm-matrix-wrap .perm-check') : []);
    checks.forEach(function (ch) {
      if (!ch || !ch.value || ch.classList.contains('sa-super-perm')) return;
      result[ch.value] = !!ch.checked;
    });
    Object.keys(MODULES).forEach(function (mod) {
      if (!moduleHasGranularKeys(result, mod)) {
        result[mod] = isModuleFullyGranted(result, mod);
      }
    });
    if (existingPerms) {
      var base = normalizePermissions(existingPerms);
      Object.keys(base).forEach(function (k) {
        if (result[k] === undefined) result[k] = base[k];
      });
    }
    return result;
  }

  function countGrantedPermissions(perms) {
    perms = normalizePermissions(perms);
    if (isPrivilegedUser({ permissions: perms, role: 'company_user' })) return 999;
    var n = 0;
    Object.keys(MODULES).forEach(function (mod) {
      Object.keys(MODULES[mod].actions).forEach(function (act) {
        if (hasActionPermission.call(null, mod, act)) n++;
      });
    });
    return n;
  }

  function countUserPermissions(perms, role) {
    if (role === 'company_admin' || role === 'super_admin') {
      var total = 0;
      Object.keys(MODULES).forEach(function (mod) {
        total += Object.keys(MODULES[mod].actions).length;
      });
      return total;
    }
    perms = normalizePermissions(perms);
    var c = 0;
    Object.keys(MODULES).forEach(function (mod) {
      Object.keys(MODULES[mod].actions).forEach(function (act) {
        var pk = permKey(mod, act);
        if (perms[pk] === true) c++;
      });
    });
    return c;
  }

  function applyPermissionUi(root) {
    if (!global.document) return;
    var scope = root && root.querySelectorAll ? root : global.document;
    var nodes = scope.querySelectorAll ? scope.querySelectorAll('[data-perm]') : [];
    nodes.forEach(function (el) {
      var raw = el.getAttribute('data-perm') || '';
      var parts = raw.split('.');
      if (parts.length < 2) return;
      var allowed = hasActionPermission(parts[0], parts[1]);
      el.style.display = allowed ? '' : 'none';
      el.disabled = !allowed;
      el.setAttribute('aria-hidden', allowed ? 'false' : 'true');
    });
  }

  /** للعرض في جدول المستخدمين */
  var companyPermissionPages = {};
  Object.keys(MODULES).forEach(function (k) {
    companyPermissionPages[k] = MODULES[k].label;
  });

  global.BasmaPermissionMatrix = {
    MODULES: MODULES,
    permKey: permKey,
    normalizePermissions: normalizePermissions,
    hasActionPermission: hasActionPermission,
    hasCompanyPermission: hasCompanyPermission,
    permissionLabel: permissionLabel,
    denyPermission: denyPermission,
    requireActionPermission: requireActionPermission,
    permissionMatrixHtml: permissionMatrixHtml,
    readPermissionsFromForm: readPermissionsFromForm,
    countUserPermissions: countUserPermissions,
    applyPermissionUi: applyPermissionUi,
    companyPermissionPages: companyPermissionPages
  };

  global.normalizePermissions = normalizePermissions;
  global.hasCompanyPermission = hasCompanyPermission;
  global.hasActionPermission = hasActionPermission;
  global.requireActionPermission = requireActionPermission;
  global.permissionMatrixHtml = permissionMatrixHtml;
  global.readPermissionsFromForm = readPermissionsFromForm;
  global.applyPermissionUi = applyPermissionUi;
  global.companyPermissionPages = companyPermissionPages;
  global.countUserPermissions = countUserPermissions;
})(typeof window !== 'undefined' ? window : globalThis);
