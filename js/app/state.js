/**

 * Global app state — window bindings for cross-script sync (main + supabase)

 */

(function (global) {

  'use strict';



  function createDefaultAppSettings(companyName) {

    return {

      companyName: companyName || '',

      currency: 'دينار عراقي (IQD)',

      timezone: 'Asia/Baghdad (GMT+3)',

      workStart: '08:00',

      workEnd: '17:00',

      lateThreshold: 15,

      lateDeductRate: 700,

      gpsLat: '',

      gpsLng: '',

      gpsName: '',

      gpsRange: 100,

      ipRestrict: true,

      trackDevices: true,

      securityAlerts: true,

      autoBackup: true,

      overtimeHourlyRate: 30000,

      /** أيام الشهر المعتمدة — أساس المعدل اليومي والغياب والرواتب (20–31، افتراضي 30) */
      monthDays: 30,

      /** تنسيق الساعة: '12' أو '24' */
      clockFormat: '12',

      lastSyncedAt: null,

      salaryDeletedMap: {},

      financeItems: [],

      broadcastNotices: [],

      activityLog: [],

      employeeNotifications: [],

      officialClosures: [],

      departments: [],

      jobs: []

    };

  }



  global.createDefaultAppSettings = createDefaultAppSettings;



  function clampMonthDays(value) {

    var n = parseInt(value, 10);

    if (!Number.isFinite(n) || n < 20) return 30;

    if (n > 31) return 31;

    return n;

  }



  function getStandardMonthDays() {

    return clampMonthDays(global.appSettings && global.appSettings.monthDays);

  }



  function getBiweeklyPeriodDays() {

    return Math.max(1, Math.floor(getStandardMonthDays() / 2));

  }



  function getBiweeklySplitDay() {

    return getBiweeklyPeriodDays();

  }



  function calcDailyRateFromSalary(basePeriodSalary, salaryType) {

    var base = parseInt(basePeriodSalary, 10) || 0;

    if (base <= 0) return 0;

    if (salaryType === 'commission') return 0;

    if (salaryType === 'biweekly') return Math.floor(base / getBiweeklyPeriodDays());

    return Math.floor(base / getStandardMonthDays());

  }



  function getEmpDailyRate(emp) {

    if (!emp) return 0;

    var dr = parseInt(emp.dailyRate, 10);

    if (dr > 0) return dr;

    var type = emp.salaryType || 'monthly';

    if (type === 'commission') return 0;

    var base = type === 'biweekly'

      ? (parseInt(emp.salaryHalf, 10) || Math.round((parseInt(emp.salary, 10) || 0) / 2))

      : (parseInt(emp.salary, 10) || 0);

    return calcDailyRateFromSalary(base, type);

  }



  function recalcEmployeeDailyRatesFromSettings() {

    (global.employees || []).forEach(function (e) {

      if (!e || e.salaryType === 'commission') return;

      if (e.salaryType === 'biweekly') {

        var half = parseInt(e.salaryHalf, 10) || 0;

        if (half > 0) e.dailyRate = Math.floor(half / getBiweeklyPeriodDays());

      } else if ((parseInt(e.salary, 10) || 0) > 0) {

        e.dailyRate = Math.floor((parseInt(e.salary, 10) || 0) / getStandardMonthDays());

      }

    });

  }



  global.clampMonthDays = clampMonthDays;

  global.getStandardMonthDays = getStandardMonthDays;

  global.getBiweeklyPeriodDays = getBiweeklyPeriodDays;

  global.getBiweeklySplitDay = getBiweeklySplitDay;

  global.calcDailyRateFromSalary = calcDailyRateFromSalary;

  global.getEmpDailyRate = getEmpDailyRate;

  global.recalcEmployeeDailyRatesFromSettings = recalcEmployeeDailyRatesFromSettings;



  if (global.employees == null) global.employees = [];

  if (global.attData == null) global.attData = [];

  if (global.nextEmpId == null) global.nextEmpId = 1;

  if (global.empSearchQuery == null) global.empSearchQuery = '';

  if (global.appSettings == null) {

    global.appSettings = createDefaultAppSettings('');

  }

  if (global.currentUser == null) global.currentUser = null;

  if (global.saasCurrentUser == null) global.saasCurrentUser = null;

  if (global.loggedInEmpId == null) global.loggedInEmpId = null;

  if (global.charts == null) global.charts = {};

})(typeof window !== 'undefined' ? window : globalThis);

