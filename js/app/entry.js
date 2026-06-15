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
} from './data.js';
import { buildEmployees } from '../employees/ui.js';
import { buildAttendance } from '../attendance/ui.js';
import {
  buildDeviceManagement,
  openEmployeeDeviceEditor,
  clearEmployeeDeviceSlotInForm,
  refreshDeviceManagementFromCloud
} from '../attendance/device-mgmt.js';

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
window.refreshDeviceManagementFromCloud = refreshDeviceManagementFromCloud;

window.__basmaModulesReady = true;
window.dispatchEvent(new CustomEvent('basma:modules-ready'));

console.log('[KYNO] ES modules loaded');
