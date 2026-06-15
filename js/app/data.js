/**

 * Local persistence — load / save (معزّول لكل شركة)

 */

import { escapeHtml } from '../core/safe-render.js';



const DEFAULT_EMPLOYEES = [];

const DEFAULT_ATT_DATA = [];

const LEGACY_STORAGE_KEY = 'attendance_system_data';



function getActiveStorageCompanyId() {

  if (window.__basmaActiveCompanyId != null) {

    var active = parseInt(window.__basmaActiveCompanyId, 10);

    if (active > 0) return active;

  }

  var user = window.saasCurrentUser || window._saasCurrentUser || null;

  if (user && user.role !== 'super_admin' && user.company_id != null) {

    var cid = parseInt(user.company_id, 10);

    if (cid > 0) return cid;

  }

  try {

    var empCid = parseInt(localStorage.getItem('basma_employee_company_id') || '0', 10);

    if (empCid > 0) return empCid;

  } catch (e) { /* ignore */ }

  return null;

}



function tenantStorageKey(companyId) {

  var cid = companyId != null ? parseInt(companyId, 10) : getActiveStorageCompanyId();

  if (!cid || cid <= 0) return window.STORAGE_KEY || LEGACY_STORAGE_KEY;

  return (window.STORAGE_KEY || LEGACY_STORAGE_KEY) + '_c_' + cid;

}



function filterLocalDataByCompany(companyId) {

  var cid = parseInt(companyId, 10);

  if (!cid) return;

  window.employees = (window.employees || []).filter(function (e) {

    if (!e) return false;

    if (!e.company_id) return false;

    return parseInt(e.company_id, 10) === cid;

  });

  window.attData = (window.attData || []).filter(function (r) {

    if (!r) return false;

    if (!r.company_id) return false;

    return parseInt(r.company_id, 10) === cid;

  });

  window.leavesData = (window.leavesData || []).filter(function (l) {

    if (!l) return false;

    if (!l.company_id) return false;

    return parseInt(l.company_id, 10) === cid;

  });

  if (typeof filterNotificationsForCurrentTenant === 'function') {

    filterNotificationsForCurrentTenant();

  }

}



function parseStorageBlob(raw) {
  if (!raw) return null;
  try { return JSON.parse(raw); } catch (e) { return null; }
}

function storageBlobCompanyIds(data) {
  var ids = {};
  if (!data) return ids;
  ['employees', 'attData', 'leavesData'].forEach(function (key) {
    (data[key] || []).forEach(function (r) {
      if (r && r.company_id != null) {
        var c = parseInt(r.company_id, 10);
        if (c > 0) ids[c] = true;
      }
    });
  });
  return ids;
}

function tenantStorageIsContaminated(companyId) {
  var cid = parseInt(companyId, 10);
  if (!cid) return false;
  try {
    var raw = localStorage.getItem(tenantStorageKey(cid));
    if (!raw) return false;
    var data = parseStorageBlob(raw);
    if (!data) return false;
    var ids = Object.keys(storageBlobCompanyIds(data)).map(function (k) { return parseInt(k, 10); });
    if (!ids.length) return false;
    return ids.some(function (id) { return id !== cid; });
  } catch (e) { return false; }
}

function tenantStorageSettingsMismatch(companyId, expectedCompanyName) {
  var cid = parseInt(companyId, 10);
  var expected = String(expectedCompanyName || '').replace(/\s+/g, ' ').trim();
  if (!cid || !expected) return false;
  try {
    var raw = localStorage.getItem(tenantStorageKey(cid));
    if (!raw) return false;
    var data = parseStorageBlob(raw);
    if (!data || !data.appSettings) return false;
    var stored = String(data.appSettings.companyName || '').replace(/\s+/g, ' ').trim();
    if (stored && stored !== expected) return true;
    return false;
  } catch (e) { return false; }
}

function wipeTenantStorage(companyId) {
  var cid = parseInt(companyId, 10);
  if (!cid) return;
  try { localStorage.removeItem(tenantStorageKey(cid)); } catch (e) { /* ignore */ }
}

function migrateLegacyStorageIfNeeded(companyId, options) {

  options = options || {};

  if (options.skipLegacyMigrate) return false;

  var cid = parseInt(companyId, 10);

  if (!cid) return false;

  var base = window.STORAGE_KEY || LEGACY_STORAGE_KEY;

  var tenantKey = base + '_c_' + cid;

  try {

    if (localStorage.getItem(tenantKey)) return false;

    var legacy = localStorage.getItem(base);

    if (!legacy) return false;

    var data = parseStorageBlob(legacy);

    if (!data) return false;

    var companyIds = storageBlobCompanyIds(data);

    var ids = Object.keys(companyIds).map(function (k) { return parseInt(k, 10); });

    if (ids.length === 1 && ids[0] === cid) {

      localStorage.setItem(tenantKey, legacy);

      localStorage.removeItem(base);

      return true;

    }

    if (ids.length === 0) {

      var migratedTo = localStorage.getItem('basma_legacy_migrated_to');

      if (!migratedTo) {

        localStorage.setItem(tenantKey, legacy);

        localStorage.setItem('basma_legacy_migrated_to', String(cid));

        localStorage.removeItem(base);

        return true;

      }

      return false;

    }

    console.warn('migrateLegacyStorageIfNeeded: skipped foreign legacy for company', cid, ids);

    return false;

  } catch (e) { console.warn('migrateLegacyStorageIfNeeded:', e); }

  return false;

}



export function migrateAttEmpIds() {

  const employees = window.employees || [];

  const attData = window.attData || [];

  attData.forEach((r) => {

    if (r.empId) return;

    const match = employees.find(

      (e) =>

        (typeof shortEmpName === 'function' && shortEmpName(e.name) === r.emp) ||

        e.name.includes((r.emp || '').split(' ')[0])

    );

    if (match) r.empId = match.id;

  });

}



export function loadData(options) {

  options = options || {};

  var cid = options.companyId != null ? parseInt(options.companyId, 10) : getActiveStorageCompanyId();

  if (cid && !options.skipLegacyMigrate) migrateLegacyStorageIfNeeded(cid, options);

  const STORAGE_KEY = tenantStorageKey(cid);

  var preservedAppSettings = options.preserveAppSettings || null;

  try {

    const saved = localStorage.getItem(STORAGE_KEY);

    if (saved) {

      const data = JSON.parse(saved);

      var isSuperLoad = isSuperAdminLocalSession() || data._superAdminCloudOnly === true;

      if (isSuperLoad) {
        window.employees = [];
        window.attData = [];
        window.leavesData = [];
        window.nextEmpId = 1;
        if (!preservedAppSettings && data.appSettings) {
          if (!Array.isArray(window.appSettings.activityLog)) window.appSettings.activityLog = [];
          window.appSettings.activityLog = (data.appSettings.activityLog || []).slice(0, 150);
        }
      } else {
        window.employees = data.employees || [...DEFAULT_EMPLOYEES];

        window.attData = data.attData || [...DEFAULT_ATT_DATA];

        window.leavesData = data.leavesData || [];

        window.nextEmpId =

          data.nextEmpId || Math.max(0, ...(window.employees || []).map((e) => e.id)) + 1;

        if (!preservedAppSettings && data.appSettings) {
          var user = window.saasCurrentUser || window._saasCurrentUser || null;
          var expectedName = user && user.company_name ? String(user.company_name).replace(/\s+/g, ' ').trim() : '';
          var storedName = String(data.appSettings.companyName || '').replace(/\s+/g, ' ').trim();
          if (!expectedName || !storedName || storedName === expectedName) {
            Object.assign(window.appSettings, data.appSettings);
          } else {
            console.warn('loadData: skipped foreign appSettings for company', cid, storedName, 'expected', expectedName);
          }
        }
      }

      const appSettings = window.appSettings;

      if (appSettings.trackDevices === undefined) appSettings.trackDevices = true;
      if (appSettings.ipRestrict === undefined) appSettings.ipRestrict = true;
      if (appSettings.securityAlerts === undefined) appSettings.securityAlerts = true;
      if (appSettings.autoBackup === undefined) appSettings.autoBackup = true;

      if (!appSettings.salaryDeletedMap || typeof appSettings.salaryDeletedMap !== 'object') {

        appSettings.salaryDeletedMap = {};

      }

      if (!Array.isArray(appSettings.financeItems)) appSettings.financeItems = [];

      if (!Array.isArray(appSettings.activityLog)) appSettings.activityLog = [];

      if (!Array.isArray(appSettings.employeeNotifications)) {

        appSettings.employeeNotifications = [];

      }

      if (typeof ensureOrgLists === 'function') ensureOrgLists();

      if (!appSettings.clockFormat) appSettings.clockFormat = '12';

      if (appSettings.monthDays == null) appSettings.monthDays = 30;

      migrateAttEmpIds();

      var loadCid = cid || getActiveStorageCompanyId();

      if (loadCid) {

        filterLocalDataByCompany(loadCid);

      }

      if (typeof syncWindowState === 'function') syncWindowState();

      return;

    }

  } catch (e) {

    console.warn('loadData', e);

  }

  window.employees = [];

  window.attData = [];

  window.leavesData = [];

  window.nextEmpId = 1;

  if (typeof syncWindowState === 'function') syncWindowState();

}



function isSuperAdminLocalSession() {
  var user = window.saasCurrentUser || window._saasCurrentUser || null;
  return !!(user && user.role === 'super_admin' && window.currentUser === 'admin');
}

function buildSuperAdminStoragePayload(appSettings) {
  var settings = appSettings || {};
  return {
    employees: [],
    attData: [],
    leavesData: [],
    nextEmpId: 1,
    appSettings: {
      companyName: settings.companyName || '',
      currency: settings.currency || '',
      timezone: settings.timezone || '',
      clockFormat: settings.clockFormat || '12',
      monthDays: settings.monthDays != null ? settings.monthDays : 30,
      activityLog: Array.isArray(settings.activityLog) ? settings.activityLog.slice(0, 150) : [],
      employeeNotifications: [],
      departments: [],
      jobs: [],
      financeItems: [],
      salaryDeletedMap: {}
    },
    _cacheAt: Date.now(),
    _cacheRole: 'admin',
    _superAdminCloudOnly: true
  };
}

export function compactSuperAdminLocalStorage() {
  if (!isSuperAdminLocalSession()) return false;
  var key = tenantStorageKey();
  try {
    var raw = localStorage.getItem(key);
    if (raw && raw.length > 500000) {
      localStorage.removeItem(key);
    }
    saveData();
    return true;
  } catch (e) {
    console.warn('compactSuperAdminLocalStorage:', e);
    try { localStorage.removeItem(key); } catch (e2) { /* ignore */ }
    return false;
  }
}

export function saveData() {

  const STORAGE_KEY = tenantStorageKey();

  var saveCid = getActiveStorageCompanyId();

  if (saveCid && typeof BasmaTenant !== 'undefined' && BasmaTenant.stampTenantOnAllRecords) {

    BasmaTenant.stampTenantOnAllRecords(saveCid);

  }

  const employees = window.employees || [];

  const attData = window.attData || [];

  const leavesData = window.leavesData || [];

  const nextEmpId = window.nextEmpId || 1;

  const appSettings = window.appSettings || {};

  var payload = isSuperAdminLocalSession()
    ? buildSuperAdminStoragePayload(appSettings)
    : {
        employees,
        attData,
        leavesData,
        nextEmpId,
        appSettings,
        _cacheAt: Date.now(),
        _cacheRole: typeof window !== 'undefined' ? window.currentUser : null
      };

  try {

    localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));

    if (typeof syncWindowState === 'function') syncWindowState();

    if (typeof scheduleAutoSupabaseSync === 'function') {

      scheduleAutoSupabaseSync('saveData');

    }

    if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();

  } catch (e) {

    console.warn('saveData error:', e);

    if (e.name === 'QuotaExceededError') {
      console.warn('localStorage quota exceeded');
      if (isSuperAdminLocalSession()) {
        try {
          localStorage.removeItem(STORAGE_KEY);
          localStorage.setItem(STORAGE_KEY, JSON.stringify(buildSuperAdminStoragePayload(appSettings)));
          return;
        } catch (e2) {
          console.warn('saveData super admin compact retry failed:', e2);
        }
      }
    }

  }

}



/** تبديل مخزن البيانات المحلي عند دخول شركة — يمنع خلط بيانات الشركات */

export function switchTenantDataStore(companyId, options) {

  options = options || {};

  var nextCid = companyId != null ? parseInt(companyId, 10) : null;

  var prevCid = getActiveStorageCompanyId();



  if (options.savePrevious !== false && prevCid && prevCid !== nextCid) {

    try { saveData(); } catch (e) { console.warn('switchTenantDataStore save previous:', e); }

  }



  window.__basmaActiveCompanyId = nextCid && nextCid > 0 ? nextCid : null;

  var resetAppSettings = null;

  if (options.resetSettings) {

    var factory = typeof window.createDefaultAppSettings === 'function'

      ? window.createDefaultAppSettings

      : function (name) { return { companyName: name || '' }; };

    resetAppSettings = factory(options.companyName || '');

    window.appSettings = resetAppSettings;

  }



  loadData({

    companyId: nextCid,

    skipLegacyMigrate: options.skipLegacyMigrate || options.resetSettings,

    preserveAppSettings: resetAppSettings

  });



  if (resetAppSettings) {

    window.appSettings = Object.assign(resetAppSettings, {

      companyName: options.companyName || resetAppSettings.companyName || '',

      departments: [],

      jobs: []

    });

  }



  if (nextCid) {

    filterLocalDataByCompany(nextCid);

    if (typeof filterNotificationsForCurrentTenant === 'function') {

      filterNotificationsForCurrentTenant();

    }

  }



  window.employees = window.employees || [];

  window.attData = window.attData || [];

  window.leavesData = window.leavesData || [];

  window.nextEmpId = window.nextEmpId || 1;



  if (typeof syncWindowState === 'function') syncWindowState();

}



export function isCompanyTenantFresh(companyId) {

  var cid = parseInt(companyId, 10);

  if (!cid) return false;

  try { return !!localStorage.getItem('basma_tenant_fresh_c_' + cid); } catch (e) { return false; }

}



export function markCompanyTenantFresh(companyId) {

  var cid = parseInt(companyId, 10);

  if (!cid) return;

  try {

    localStorage.setItem('basma_tenant_fresh_c_' + cid, String(Date.now()));

    localStorage.removeItem('basma_tenant_verified_c_' + cid);

  } catch (e) { /* ignore */ }

  wipeTenantStorage(cid);

}



export function clearCompanyTenantFresh(companyId) {

  var cid = parseInt(companyId, 10);

  if (!cid) return;

  try { localStorage.removeItem('basma_tenant_fresh_c_' + cid); } catch (e) { /* ignore */ }

}



/** تهيئة محلية صفرية — شركة جديدة بدون أي بيانات من شركات أخرى */

export function bootstrapZeroTenantStore(companyId, companyName) {

  var cid = parseInt(companyId, 10);

  if (!cid) return false;

  wipeTenantStorage(cid);

  try { localStorage.removeItem('basma_tenant_verified_c_' + cid); } catch (e) { /* ignore */ }

  window.__basmaActiveCompanyId = cid;

  var factory = typeof window.createDefaultAppSettings === 'function'

    ? window.createDefaultAppSettings

    : function (n) { return { companyName: n || '', departments: [], jobs: [] }; };

  window.employees = [];

  window.attData = [];

  window.leavesData = [];

  window.nextEmpId = 1;

  window.appSettings = factory(companyName || '');

  window.appSettings.companyName = companyName || window.appSettings.companyName || '';

  window.appSettings.departments = [];

  window.appSettings.jobs = [];

  window.appSettings.activityLog = [];

  window.appSettings.employeeNotifications = [];

  window.appSettings.financeItems = [];

  window.appSettings.salaryDeletedMap = {};

  window.__basmaLocalSettingsAt = 0;

  window.__basmaLocalNotifAt = 0;

  if (typeof filterNotificationsForCurrentTenant === 'function') filterNotificationsForCurrentTenant();

  if (typeof syncWindowState === 'function') syncWindowState();

  try { saveData(); } catch (e) { console.warn('bootstrapZeroTenantStore save:', e); }

  window.__basmaTenantNeedsCloudReset = true;

  return true;

}



export function prepareCompanyTenantSession(user) {

  if (!user || user.role === 'super_admin' || !user.company_id) return false;

  var cid = parseInt(user.company_id, 10);

  if (!cid) return false;

  var tenantKey = tenantStorageKey(cid);

  var hadStorage = false;

  try { hadStorage = !!localStorage.getItem(tenantKey); } catch (e) { /* ignore */ }

  var verifiedKey = 'basma_tenant_verified_c_' + cid;

  var wasVerified = false;

  try { wasVerified = !!localStorage.getItem(verifiedKey); } catch (e) { /* ignore */ }

  var isFresh = isCompanyTenantFresh(cid);

  var contaminated = tenantStorageIsContaminated(cid);

  var settingsMismatch = tenantStorageSettingsMismatch(cid, user.company_name);

  var needsZeroBootstrap = isFresh || contaminated || settingsMismatch || !wasVerified;

  if (contaminated || settingsMismatch) {

    console.info('prepareCompanyTenantSession: تنظيف ذاكرة محلية للشركة', cid, '—', contaminated ? 'كانت مخلوطة ببيانات شركة أخرى' : 'تغيّر اسم الشركة');

    wipeTenantStorage(cid);

    hadStorage = false;

    try { localStorage.removeItem(verifiedKey); } catch (e) { /* ignore */ }

  }

  if (needsZeroBootstrap) {

    bootstrapZeroTenantStore(cid, user.company_name || '');

  } else {

    switchTenantDataStore(cid, {

      savePrevious: true,

      resetSettings: false,

      skipLegacyMigrate: true,

      companyName: user.company_name || ''

    });

    window.__basmaTenantNeedsCloudReset = false;

  }

  try {
    localStorage.removeItem('basma_registered_emp');
    localStorage.removeItem('basma_registered_slot');
    localStorage.removeItem('basma_emp_session');
    localStorage.removeItem('basma_employee_company_id');
  } catch (e) { /* ignore */ }

  if (user.company_name) {

    window.appSettings.companyName = String(user.company_name).trim();

  }

  if (needsZeroBootstrap && typeof saveData === 'function') {

    try { saveData(); } catch (e) { console.warn('prepareCompanyTenantSession save:', e); }

  }

  return true;

}



export function clearTenantDataStore() {

  try { saveData(); } catch (e) {}

  window.__basmaActiveCompanyId = null;

}



if (typeof window !== 'undefined') {

  window.loadData = loadData;

  window.saveData = saveData;

  window.migrateAttEmpIds = migrateAttEmpIds;

  window.switchTenantDataStore = switchTenantDataStore;

  window.prepareCompanyTenantSession = prepareCompanyTenantSession;

  window.clearTenantDataStore = clearTenantDataStore;

  window.compactSuperAdminLocalStorage = compactSuperAdminLocalStorage;

  window.getActiveStorageCompanyId = getActiveStorageCompanyId;

  window.tenantStorageKey = tenantStorageKey;

  window.filterLocalDataByCompany = filterLocalDataByCompany;

  window.tenantStorageIsContaminated = tenantStorageIsContaminated;

  window.wipeTenantStorage = wipeTenantStorage;

  window.bootstrapZeroTenantStore = bootstrapZeroTenantStore;

  window.markCompanyTenantFresh = markCompanyTenantFresh;

  window.clearCompanyTenantFresh = clearCompanyTenantFresh;

  window.isCompanyTenantFresh = isCompanyTenantFresh;

}



export { escapeHtml, wipeTenantStorage, tenantStorageIsContaminated, tenantStorageSettingsMismatch };

