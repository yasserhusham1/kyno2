/**
 * صلاحيات فريق السوبر أدمن — واجهة + تحقق (السيرفر يفرض عبر RPC)
 */
(function (global) {
  'use strict';

  var WRITE_KEYS = [
    'companies_create', 'companies_edit', 'companies_delete', 'companies_suspend',
    'subscriptions_renew', 'subscriptions_edit', 'subscriptions_delete',
    'users_manage',
    'platform_whatsapp', 'platform_announce', 'platform_announce_manage',
    'team_manage'
  ];

  var PERM_DEFS = [
    { key: 'view_only', label: 'وضع العرض فقط (بدون تعديل أو حذف)', group: 'عام', isMode: true },
    { key: 'companies_view', label: 'عرض الشركات', group: 'الشركات', isView: true },
    { key: 'companies_create', label: 'إنشاء شركة', group: 'الشركات', isWrite: true },
    { key: 'companies_edit', label: 'تعديل شركة', group: 'الشركات', isWrite: true },
    { key: 'companies_delete', label: 'حذف شركة', group: 'الشركات', isWrite: true },
    { key: 'companies_suspend', label: 'إيقاف / تفعيل شركة', group: 'الشركات', isWrite: true },
    { key: 'subscriptions_view', label: 'عرض الاشتراكات', group: 'الاشتراكات', isView: true },
    { key: 'subscriptions_edit', label: 'تعديل اشتراك', group: 'الاشتراكات', isWrite: true },
    { key: 'subscriptions_renew', label: 'تمديد اشتراك', group: 'الاشتراكات', isWrite: true },
    { key: 'subscriptions_delete', label: 'حذف سجل اشتراك', group: 'الاشتراكات', isWrite: true },
    { key: 'users_view', label: 'عرض مستخدمي الشركات', group: 'المستخدمون', isView: true },
    { key: 'users_manage', label: 'إدارة مستخدمي الشركات', group: 'المستخدمون', isWrite: true },
    { key: 'platform_view', label: 'عرض إعدادات المنصة', group: 'المنصة', isView: true },
    { key: 'platform_whatsapp', label: 'تعديل أرقام واتساب', group: 'المنصة', isWrite: true },
    { key: 'platform_announce', label: 'إرسال إشعار للشركات', group: 'المنصة', isWrite: true },
    { key: 'platform_announce_manage', label: 'تعديل / حذف الإشعارات', group: 'المنصة', isWrite: true },
    { key: 'team_manage', label: 'إدارة فريق السوبر أدمن', group: 'الفريق', isWrite: true },
    { key: 'stats_view', label: 'عرض الإحصائيات', group: 'التقارير', isView: true },
    { key: 'monitoring_view', label: 'مراقبة النظام', group: 'التقارير', isView: true },
    { key: 'backup_manage', label: 'مركز النسخ الاحتياطي', group: 'التقارير', isWrite: true },
    { key: 'settings_view', label: 'عرض الإعدادات الشخصية', group: 'عام', isView: true }
  ];

  var DEFAULTS = { view_only: false, job_title: '' };
  PERM_DEFS.forEach(function (d) {
    if (d.key !== 'view_only' && d.key !== 'job_title') DEFAULTS[d.key] = true;
  });

  function getCurrentUser() {
    if (typeof global.syncSaasSessionContext === 'function') {
      try { global.syncSaasSessionContext(); } catch (e) { /* ignore */ }
    }
    return global.saasCurrentUser || global._saasCurrentUser || null;
  }

  function isSuperAdminUser(user) {
    user = user || getCurrentUser();
    return !!(user && user.role === 'super_admin');
  }

  function extractSuperBlock(perms) {
    if (!perms) return {};
    if (typeof perms === 'string') {
      try { perms = JSON.parse(perms); } catch (e) { return {}; }
    }
    if (perms.companies_view !== undefined || perms.team_manage !== undefined || perms.view_only !== undefined) {
      return perms;
    }
    var block = perms.super_admin;
    if (!block || typeof block !== 'object' || Array.isArray(block)) return {};
    return block;
  }

  function emptySuperAdminPermissions() {
    var out = { view_only: false, job_title: '' };
    PERM_DEFS.forEach(function (d) {
      if (d.key !== 'view_only' && d.key !== 'job_title') out[d.key] = false;
    });
    return out;
  }

  function applySuperAdminSessionPermissions(user) {
    if (!user || user.role !== 'super_admin') return user;
    var saBlock = normalizeSuperAdminPermissions(user.permissions);
    user.permissions = { super_admin: saBlock };
    if (saBlock.job_title) user.job_title = saBlock.job_title;
    return user;
  }

  function isWritePerm(key) {
    return WRITE_KEYS.indexOf(key) >= 0;
  }

  function normalizeSuperAdminPermissions(perms) {
    var block = extractSuperBlock(perms);
    var out = Object.assign({}, DEFAULTS);
    Object.keys(block).forEach(function (k) {
      if (k === 'job_title') {
        out.job_title = String(block[k] || '').trim();
        return;
      }
      if (k === 'view_only') {
        out.view_only = block[k] === true;
        return;
      }
      if (Object.prototype.hasOwnProperty.call(DEFAULTS, k)) {
        out[k] = block[k] === true;
      }
    });
    if (out.view_only) {
      WRITE_KEYS.forEach(function (wk) { out[wk] = false; });
    }
    if (!out.job_title && block.job_title) out.job_title = String(block.job_title).trim();
    var anyGranted = PERM_DEFS.some(function (d) { return out[d.key] === true; });
    if (!anyGranted && Object.keys(block).length > 0) {
      return Object.assign({}, DEFAULTS);
    }
    return out;
  }

  function buildPermissionsPayload(normalized, jobTitle) {
    var payload = { super_admin: {} };
    Object.keys(DEFAULTS).forEach(function (k) {
      if (k === 'job_title') return;
      payload.super_admin[k] = normalized[k] === true;
    });
    payload.super_admin.job_title = String(jobTitle || normalized.job_title || '').trim();
    if (normalized.view_only) {
      WRITE_KEYS.forEach(function (wk) { payload.super_admin[wk] = false; });
    }
    return payload;
  }

  function isSuperAdminViewOnly(user) {
    if (!isSuperAdminUser(user)) return false;
    user = user || getCurrentUser();
    return normalizeSuperAdminPermissions(user.permissions).view_only === true;
  }

  function getSuperAdminJobTitle(user) {
    user = user || getCurrentUser();
    if (!user) return '';
    var n = normalizeSuperAdminPermissions(user.permissions);
    return n.job_title || user.job_title || '';
  }

  function getSuperAdminDisplayName(user) {
    user = user || getCurrentUser();
    if (!user) return '';
    var dn = String(user.display_name || '').trim();
    return dn || String(user.username || '').trim() || 'الإدارة';
  }

  function canSuperAdmin(action, user) {
    if (!isSuperAdminUser(user)) return false;
    user = user || getCurrentUser();
    var n = normalizeSuperAdminPermissions(user.permissions);
    if (n.view_only && isWritePerm(action)) return false;
    if (n[action] === false) return false;
    return n[action] === true;
  }

  function canSuperAdminAny(actions, user) {
    if (!Array.isArray(actions)) return canSuperAdmin(actions, user);
    for (var i = 0; i < actions.length; i++) {
      if (canSuperAdmin(actions[i], user)) return true;
    }
    return false;
  }

  function canSuperAdminPage(pageId, user) {
    if (!isSuperAdminUser(user)) return false;
    user = user || getCurrentUser();
    if (!user) return pageId === 'superadmin' || pageId === 'sa-settings';
    var map = {
      superadmin: ['companies_view', 'stats_view', 'subscriptions_view', 'users_view', 'platform_view'],
      'sa-companies': ['companies_view'],
      'sa-subscriptions': ['subscriptions_view', 'subscriptions_edit', 'subscriptions_renew', 'subscriptions_delete'],
      'sa-users': ['users_view', 'users_manage'],
      'sa-platform': ['platform_view', 'platform_whatsapp', 'platform_announce', 'platform_announce_manage'],
      'sa-stats': ['stats_view'],
      'sa-monitoring': ['monitoring_view', 'stats_view'],
      'sa-backup': ['backup_manage', 'companies_view'],
      'sa-team': ['team_manage'],
      'sa-settings': ['settings_view']
    };
    var perms = map[pageId];
    if (!perms) return true;
    return canSuperAdminAny(perms, user);
  }

  function superAdminPermissionMatrixHtml(selected, idPrefix) {
    idPrefix = idPrefix || 'sa-perm-';
    var block = extractSuperBlock(selected || {});
    selected = normalizeSuperAdminPermissions({ super_admin: block });
    var groups = {};
    PERM_DEFS.forEach(function (d) {
      if (!groups[d.group]) groups[d.group] = [];
      groups[d.group].push(d);
    });
    var html = '';
    Object.keys(groups).forEach(function (g) {
      html += '<div class="perm-group-title sa-perm-group-title">' + g + '</div>';
      html += '<div class="perm-grid sa-perm-grid">';
      groups[g].forEach(function (d) {
        var checked = selected[d.key] === true ? ' checked' : '';
        var cls = 'perm-card sa-perm-card';
        if (d.isView) cls += ' sa-perm-view';
        if (d.isWrite) cls += ' sa-perm-write';
        if (d.isMode) cls += ' sa-perm-mode';
        if (checked) cls += ' active';
        html += '<label class="' + cls + '">' +
          '<input type="checkbox" class="perm-check sa-super-perm" id="' + idPrefix + d.key + '" data-perm="' + d.key + '"' +
          (d.isWrite ? ' data-write="1"' : '') + (d.isMode ? ' data-mode="view_only"' : '') + checked + '>' +
          '<span class="sa-perm-label">' + d.label + '</span></label>';
      });
      html += '</div>';
    });
    return html;
  }

  function bindSuperAdminPermissionMatrix(idPrefix) {
    idPrefix = idPrefix || 'sa-perm-';
    var modeEl = document.getElementById(idPrefix + 'view_only');
    var writeEls = document.querySelectorAll('.sa-super-perm[data-write="1"]');
    function syncViewOnly() {
      var on = !!(modeEl && modeEl.checked);
      writeEls.forEach(function (el) {
        el.disabled = on;
        if (on) {
          el.checked = false;
          var card = el.closest('.perm-card');
          if (card) card.classList.remove('active');
        }
      });
    }
    if (modeEl) {
      modeEl.addEventListener('change', syncViewOnly);
      syncViewOnly();
    }
    if (typeof bindPermissionCards === 'function') bindPermissionCards();
  }

  function readSuperAdminPermissionMatrix(idPrefix) {
    idPrefix = idPrefix || 'sa-perm-';
    var out = emptySuperAdminPermissions();
    PERM_DEFS.forEach(function (d) {
      var el = document.getElementById(idPrefix + d.key);
      out[d.key] = !!(el && el.checked);
    });
    if (out.view_only) {
      WRITE_KEYS.forEach(function (wk) { out[wk] = false; });
    }
    return out;
  }

  function platformAnnouncementSenderMeta(user) {
    user = user || getCurrentUser();
    return {
      senderId: user && user.id ? user.id : null,
      senderName: getSuperAdminDisplayName(user),
      senderJobTitle: getSuperAdminJobTitle(user)
    };
  }

  global.SUPER_ADMIN_WRITE_KEYS = WRITE_KEYS;
  global.SUPER_ADMIN_PERM_DEFS = PERM_DEFS;
  global.normalizeSuperAdminPermissions = normalizeSuperAdminPermissions;
  global.extractSuperAdminPermBlock = extractSuperBlock;
  global.emptySuperAdminPermissions = emptySuperAdminPermissions;
  global.applySuperAdminSessionPermissions = applySuperAdminSessionPermissions;
  global.buildSuperAdminPermissionsPayload = buildPermissionsPayload;
  global.getSuperAdminJobTitle = getSuperAdminJobTitle;
  global.getSuperAdminDisplayName = getSuperAdminDisplayName;
  global.isSuperAdminViewOnly = isSuperAdminViewOnly;
  global.canSuperAdmin = canSuperAdmin;
  global.canSuperAdminAny = canSuperAdminAny;
  global.canSuperAdminPage = canSuperAdminPage;
  global.isSuperAdminUser = isSuperAdminUser;
  global.superAdminPermissionMatrixHtml = superAdminPermissionMatrixHtml;
  global.bindSuperAdminPermissionMatrix = bindSuperAdminPermissionMatrix;
  global.readSuperAdminPermissionMatrix = readSuperAdminPermissionMatrix;
  global.platformAnnouncementSenderMeta = platformAnnouncementSenderMeta;
})(typeof window !== 'undefined' ? window : globalThis);
