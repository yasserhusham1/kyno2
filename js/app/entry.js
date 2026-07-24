/**
 * ES Module bootstrap — Phase 3
 * يحمّل وحدات الواجهة ويربطها بـ window للتوافق مع onclick في HTML
 */
import '../core/safe-render.js';
import {
  loadData,
  saveData,
  migrateAttEmpIds,
  switchTenantDataStore,
  prepareCompanyTenantSession,
  clearTenantDataStore,
  bootstrapZeroTenantStore,
  markCompanyTenantFresh,
  clearCompanyTenantFresh,
  wipeTenantStorage
} from './data.js?v=20260716f';
import { buildEmployees } from '../employees/ui.js?v=20260716e';
import { buildAttendance } from '../attendance/ui.js?v=20260709e';
import {
  buildDeviceManagement,
  openEmployeeDeviceEditor,
  clearEmployeeDeviceSlotInForm,
  unlockEmployeeDeviceAttemptsInForm,
  refreshDeviceManagementFromCloud,
  switchDeviceMgmtTab,
  debounceDeviceTrackingSearch,
  refreshDeviceTrackingLog
} from '../attendance/device-mgmt.js?v=20260721a';

window.loadData = loadData;
window.saveData = saveData;
window.migrateAttEmpIds = migrateAttEmpIds;
window.switchTenantDataStore = switchTenantDataStore;
window.prepareCompanyTenantSession = prepareCompanyTenantSession;
window.clearTenantDataStore = clearTenantDataStore;
window.bootstrapZeroTenantStore = bootstrapZeroTenantStore;
window.markCompanyTenantFresh = markCompanyTenantFresh;
window.clearCompanyTenantFresh = clearCompanyTenantFresh;
window.wipeTenantStorage = wipeTenantStorage;
window.buildEmployees = buildEmployees;
window.buildAttendance = buildAttendance;
window.buildDeviceManagement = buildDeviceManagement;
window.openEmployeeDeviceEditor = openEmployeeDeviceEditor;
window.clearEmployeeDeviceSlotInForm = clearEmployeeDeviceSlotInForm;
window.unlockEmployeeDeviceAttemptsInForm = unlockEmployeeDeviceAttemptsInForm;
window.refreshDeviceManagementFromCloud = refreshDeviceManagementFromCloud;
window.switchDeviceMgmtTab = switchDeviceMgmtTab;
window.debounceDeviceTrackingSearch = debounceDeviceTrackingSearch;
window.refreshDeviceTrackingLog = refreshDeviceTrackingLog;

window.__basmaModulesReady = true;
window.dispatchEvent(new CustomEvent('basma:modules-ready'));

console.log('[KYNO] ES modules loaded');
