/**
 * Route / permission guards
 */
(function (global) {
  'use strict';

  var ROLES = { super_admin: 100, company_admin: 80, company_user: 50, employee: 10 };

  function currentRole() {
    var u = global._saasCurrentUser || global.saasCurrentUser;
    if (global.currentUser === 'emp') return 'employee';
    return u && u.role ? u.role : null;
  }

  function roleLevel(role) {
    return ROLES[role] || 0;
  }

  function canAccessPage(pageId) {
    if (global.currentUser === 'emp') {
      return ['emp-home', 'emp-salary', 'emp-profile', 'notifications'].indexOf(pageId) >= 0;
    }
    if (!global.currentUser || global.currentUser !== 'admin') return false;
    var u = global._saasCurrentUser || global.saasCurrentUser;
    if (!u) return false;
    if (u.role === 'super_admin') return true;
    if (u.role === 'company_admin') return true;
    if (typeof global.hasCompanyPermission === 'function') {
      return global.hasCompanyPermission(pageId);
    }
    return false;
  }

  function requireAuth(pageId) {
    if (!global.currentUser) {
      if (global.BasmaToast) BasmaToast.warn('يجب تسجيل الدخول أولاً');
      return false;
    }
    if (pageId && !canAccessPage(pageId)) {
      if (global.BasmaToast) BasmaToast.error('لا تملك صلاحية الوصول');
      return false;
    }
    return true;
  }

  global.BasmaPermissions = {
    ROLES: ROLES,
    currentRole: currentRole,
    canAccessPage: canAccessPage,
    requireAuth: requireAuth
  };
})(typeof window !== 'undefined' ? window : globalThis);
