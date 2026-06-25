/**
 * ربط أزرار الواجهة + فحص ذاتي للدوال (Super Admin / شركات / موظفون)
 */
(function (global) {
  'use strict';

  var SA_HANDLERS = [
    'openAddCompanyForm', 'openEditCompanyFormById', 'openEditCompanyForm', 'openCompanyDetails',
    'toggleCompanyStatus', 'deleteCompany', 'openRenewSubscription', 'openEditSubscriptionForm',
    'deleteSubscription', 'openAddCompanyAdminForm', 'openEditCompanyAdminForm', 'deleteSaasUser',
    'toggleSACompanyPanel', 'openCompanyUserForm', 'deleteCompanyUser', 'buildCompanyUsersPage',
    'savePlatformWhatsAppNumbers', 'openCreatePlatformAnnouncement', 'openEditPlatformAnnouncement',
    'deletePlatformAnnouncement', 'openSuperAdminTeamForm', 'deleteSuperAdminTeamMember',
    'openSuperAdminAccountSettings', 'openAddSaasUserForm', 'saSelectBackupCompany',
    'saFilterBackupCompanies', 'saRunBackupExport', 'saVerifyBackupIntegrity', 'saRunBackupImport',
    'runSecurityHealthReport', 'buildSuperAdminDashboard', 'buildSACompaniesPage',
    'buildSASubscriptionsPage', 'buildSAUsersPage', 'buildSATeamPage', 'buildSAPlatformPage',
    'buildSAStatsPage', 'buildSAMonitoringPage', 'buildSABackupPage', 'buildSASettingsPage'
  ];

  var CORE_HANDLERS = [
    'showPage', 'doLogout', 'toggleSidebar', 'closeSidebar', 'doLogin', 'switchLoginTab',
    'addEmployee', 'buildEmployees', 'buildAttendance', 'buildDashboard', 'buildReports',
    'buildSalaries', 'buildFinancePage', 'buildOrgPage', 'buildNotifications', 'buildLeaves',
    'openAddLeaveForm', 'contactSuperAdmin', 'contactSupportTeam', 'setTheme',
    'refreshDeviceManagementFromCloud', 'buildDeviceManagement'
  ];

  function bindTopbarClicks() {
    if (document.documentElement.dataset.topbarBound === '1') return;
    document.documentElement.dataset.topbarBound = '1';
    safeAddEvent(document, 'click', function (e) {
      var notif = e.target && e.target.closest ? e.target.closest('.topbar-notif, [data-goto-page]') : null;
      if (!notif) return;
      var pageId = notif.getAttribute('data-goto-page') || 'notifications';
      e.preventDefault();
      if (typeof global.showPage === 'function') global.showPage(pageId);
    }, true);
  }

  function auditUiHandlers() {
    var missing = [];
    var ok = [];
    CORE_HANDLERS.concat(SA_HANDLERS).forEach(function (name) {
      if (typeof global[name] === 'function') ok.push(name);
      else missing.push(name);
    });
    var report = {
      ok: ok.length,
      missing: missing.length,
      missingList: missing,
      modulesReady: !!global.__basmaModulesReady,
      showPage: typeof global.showPage,
      currentUser: global.currentUser,
      saasRole: global.saasCurrentUser && global.saasCurrentUser.role
    };
    console.group('[KYNO UI Audit]');
    console.log('✓ دوال موجودة:', ok.length);
    console.log('✕ دوال ناقصة:', missing.length, missing);
    console.log('Modules ready:', report.modulesReady);
    console.log('Session:', report.currentUser, report.saasRole);
    console.groupEnd();
    return report;
  }

  global.KYNO_UI_BINDINGS = {
    SA_HANDLERS: SA_HANDLERS,
    CORE_HANDLERS: CORE_HANDLERS,
    auditUiHandlers: auditUiHandlers,
    bindTopbarClicks: bindTopbarClicks
  };
  global.auditUiHandlers = auditUiHandlers;

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', bindTopbarClicks);
    } else {
      bindTopbarClicks();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
