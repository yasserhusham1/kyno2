/**
 * Supabase Integration — KYNO / بصمة
 * config/local.config.js — لا service_role في الواجهة
 * تسجيل الدخول: Edge auth-login + JWT (RLS 004)
 */

var _LEGACY_SUPABASE_URL = 'https://qalcnvygyjtlmlauvzlk.supabase.co';
var _LEGACY_SUPABASE_ANON = '';

function getSupabaseUrl() {
  if (typeof window !== 'undefined' && window.BasmaConfig && BasmaConfig.supabaseUrl()) {
    return BasmaConfig.supabaseUrl();
  }
  return _LEGACY_SUPABASE_URL;
}

function isHostedSupabase() {
  return /\.supabase\.co$/i.test(String(getSupabaseUrl() || '').replace(/\/$/, ''));
}

function getSupabaseAnonKey() {
  if (typeof window !== 'undefined' && window.BasmaConfig && BasmaConfig.supabaseAnonKey()) {
    return BasmaConfig.supabaseAnonKey();
  }
  if (typeof window !== 'undefined' && window.__BASMA_LOCAL_CONFIG__ && window.__BASMA_LOCAL_CONFIG__.supabaseAnonKey) {
    return String(window.__BASMA_LOCAL_CONFIG__.supabaseAnonKey).trim();
  }
  return _LEGACY_SUPABASE_ANON;
}

function getPageSize() {
  if (typeof window !== 'undefined' && window.BasmaConfig && BasmaConfig.pageSize) {
    return BasmaConfig.pageSize();
  }
  return 100;
}

async function kynoWithRetry(fn, options) {
  if (typeof window !== 'undefined' && window.KynoRetry) {
    return KynoRetry.retryWithBackoff(fn, options || { maxRetries: 2, initialDelayMs: 400 });
  }
  return fn();
}

var EMPLOYEE_SELECT = 'id,name,dept,role,phone,salary,salary_type,salary_half,daily_rate,days,late_min,check_in,check_out,open_hours,remote_attend,include_overtime_in_salary,sal_status,sal_bonus,sal_deleted_period,avatar_url,company_id,created_at,employee_devices(id,slot,label,ip,fingerprint,pin,token,token_created_at,token_used_at,device_info,linked_at,last_login)';
var ATTENDANCE_SELECT = 'id,employee_id,emp_name,dept,date_label,date_iso,check_in,check_out,hours,late,overtime,status,company_id,created_at';

var _sbClient = null;
var _sbRealtimeChannel = null;
var _sbRealtimePullTimer = null;
var _sbRealtimePulling = false;
var _sbSyncRunning = false;
var _sbSyncQueue = [];

function hasPendingDataSync() {
  if (typeof currentUser !== 'undefined' && currentUser === 'emp') {
    var empId = typeof window !== 'undefined' ? String(window.loggedInEmpId || '') : '';
    if (!empId) return false;
    return ((window.attData || []).some(function (a) { return a && String(a.empId) === empId && a._pendingRemoteSync; })) ||
      ((window.leavesData || []).some(function (l) { return l && String(l.empId || l.employee_id) === empId && l._pendingSync; }));
  }
  return ((window.employees || []).some(function (e) { return e && e._pendingRemoteSync; })) ||
    ((window.attData || []).some(function (a) { return a && a._pendingRemoteSync; })) ||
    ((window.leavesData || []).some(function (l) { return l && l._pendingSync; }));
}

function markTenantSyncedNow() {
  window.__basmaLastSyncedAt = Date.now();
  if (window.appSettings) window.appSettings.lastSyncedAt = new Date().toISOString();
  if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
}
var _lastSbEmployeeSaveError = '';
var _lastSbEmployeeDeleteError = '';

function sb_getLastEmployeeSaveError() {
  return _lastSbEmployeeSaveError || '';
}

function sb_getLastEmployeeDeleteError() {
  return _lastSbEmployeeDeleteError || '';
}

function mapSbEmployeeDeleteError(code) {
  var c = String(code || '').toLowerCase();
  if (c === 'no_auth' || c.indexOf('jwt') >= 0) return 'انتهت جلسة الدخول — سجّل الدخول مرة أخرى ثم أعد المحاولة.';
  if (c === 'employee_not_found') return 'الموظف غير موجود في قاعدة البيانات (ربما حُذف مسبقاً).';
  if (c === 'no_company_context' || c === 'tenant_mismatch') return 'تعذّر تحديد الشركة — أعد تسجيل الدخول.';
  if (c === 'subscription_inactive') return 'الاشتراك غير فعال — لا يمكن حذف الموظف.';
  if (c === 'employee_has_dependencies') return 'لا يمكن حذف الموظف لوجود بيانات مرتبطة به في النظام.';
  if (c === 'invalid_params') return 'معرّف الموظف غير صالح.';
  return code ? String(code) : 'تعذّر الحذف من السحابة.';
}

function mapEmployeeSaveRpcError(code, payload) {
  var c = String(code || '').toLowerCase();
  var lim = payload && payload.limit != null ? parseInt(payload.limit, 10) : NaN;
  var cnt = payload && payload.count != null ? parseInt(payload.count, 10) : NaN;
  if (c.indexOf('employee_limit_reached') >= 0) {
    if (!isNaN(lim) && !isNaN(cnt)) {
      return 'تم الوصول للحد الأقصى (' + cnt + '/' + lim + ' موظف). اطلب من السوبر أدمن رفع الحد أو احذف موظفين.';
    }
    return 'تم الوصول إلى الحد الأقصى لعدد الموظفين في هذه الشركة.';
  }
  if (c.indexOf('subscription_inactive') >= 0) {
    return 'الاشتراك غير فعال — فعّل الاشتراك من لوحة السوبر أدمن ثم أعد المحاولة.';
  }
  if (c === 'no_company_context' || c === 'tenant_mismatch') {
    return 'سياق الشركة غير صحيح — سجّل الخروج ثم ادخل بحساب الشركة الصحيحة.';
  }
  if (c.indexOf('no_auth') >= 0 || c.indexOf('jwt') >= 0) {
    return 'انتهت جلسة الدخول — سجّل الدخول مرة أخرى.';
  }
  return code ? String(code) : 'فشل حفظ الموظف في السحابة';
}

function sb_isPermanentEmployeeSaveError(msg) {
  var m = String(msg || '').toLowerCase();
  if (!m) return false;
  return m.indexOf('employee_limit_reached') >= 0
    || m.indexOf('subscription_inactive') >= 0
    || m.indexOf('tenant_mismatch') >= 0
    || m.indexOf('no_company_context') >= 0
    || m.indexOf('plan_feature_denied') >= 0
    || m.indexOf('تم الوصول') >= 0
    || m.indexOf('الاشتراك غير فعال') >= 0
    || m.indexOf('سياق الشركة') >= 0;
}

async function sb_countCompanyEmployees(companyId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var cid = parseInt(companyId, 10);
  if (!cid) return null;
  try {
    var res = await _sbClient.from('employees').select('id', { count: 'exact', head: true }).eq('company_id', cid);
    if (res.error) {
      console.warn('sb_countCompanyEmployees:', res.error);
      return null;
    }
    return typeof res.count === 'number' ? res.count : 0;
  } catch (e) {
    console.warn('sb_countCompanyEmployees:', e);
    return null;
  }
}

function resolveActiveCompanyId(emp) {
  var user = typeof window !== 'undefined' ? window._saasCurrentUser || null : null;
  var id = null;
  if (typeof AuthApi !== 'undefined' && typeof AuthApi.getCompanyId === 'function') {
    var jwtCid = AuthApi.getCompanyId();
    if (jwtCid !== undefined && jwtCid !== null) id = jwtCid;
  }
  if (!id && user && user.role !== 'super_admin' && user.company_id) id = user.company_id;
  if (!id && emp && emp.company_id) id = emp.company_id;
  if (!id && typeof window !== 'undefined' && typeof window.getActiveStorageCompanyId === 'function') {
    var storeCid = window.getActiveStorageCompanyId();
    if (storeCid) id = storeCid;
  }
  if (!id && typeof window !== 'undefined') {
    try {
      var empCid = parseInt(localStorage.getItem('basma_employee_company_id') || '0', 10);
      if (empCid > 0) id = empCid;
    } catch (e) { /* ignore */ }
  }
  id = parseInt(id, 10);
  return id > 0 ? id : null;
}

function requireActiveCompanyId(emp) {
  var cid = resolveActiveCompanyId(emp);
  if (!cid || cid <= 0) {
    throw new Error('NO_COMPANY_CONTEXT');
  }
  return cid;
}

function resolveSettingsTenantPrefix(companyId) {
  var cid = companyId != null ? parseInt(companyId, 10) : resolveActiveCompanyId();
  if (!cid || cid <= 0) return null;
  return 'company:' + cid + ':';
}

function hasTenantSyncContext() {
  if (isSuperAdminSession()) return false;
  return !!resolveActiveCompanyId();
}

function kynoUseRpcWrites() {
  if (typeof window !== 'undefined' && window.__kynoLockdownDetected === true) return true;
  return (typeof isKynoFinalLockdown === 'function' && isKynoFinalLockdown())
    || (typeof isKynoRpcMode === 'function' && isKynoRpcMode());
}

function isSbPermissionDenied(err) {
  if (!err) return false;
  if (err.code === '42501' || err.code === 'PGRST301' || err.code === 'PGRST116') return true;
  if (err.status === 403 || err.statusCode === 403) return true;
  var msg = String(err.message || err.hint || err.details || err).toLowerCase();
  return msg.indexOf('permission denied') >= 0
    || msg.indexOf('row-level security') >= 0
    || msg.indexOf('violates row-level security') >= 0
    || msg.indexOf('direct_write_forbidden') >= 0;
}

function markKynoLockdownDetected() {
  if (typeof window !== 'undefined') window.__kynoLockdownDetected = true;
}

function isSuperAdminSession() {
  var u = typeof saasCurrentUser !== 'undefined' ? saasCurrentUser : window._saasCurrentUser;
  if (u && u.role === 'super_admin') return true;
  if (typeof AuthApi !== 'undefined' && AuthApi.getRole && AuthApi.getRole() === 'super_admin') return true;
  return false;
}

function kynoPlatformAdminRpc() {
  return kynoUseRpcWrites() || isSuperAdminSession();
}

function wrapSupabaseClientForLockdown(client) {
  if (!client || typeof client.from !== 'function') return client;
  if (typeof isKynoFinalLockdown !== 'function' || !isKynoFinalLockdown()) return client;
  if (client.__kynoLockdownWrapped) return client;
  var origFrom = client.from.bind(client);
  client.from = function (table) {
    var builder = origFrom(table);
    ['insert', 'update', 'upsert', 'delete'].forEach(function (method) {
      if (typeof builder[method] !== 'function') return;
      var origMethod = builder[method].bind(builder);
      builder[method] = function () {
        var err = new Error('DIRECT_WRITE_FORBIDDEN:' + table + '.' + method);
        console.error('KYNO_FINAL_LOCKDOWN blocked', table, method);
        throw err;
      };
      builder[method]._kynoOrig = origMethod;
    });
    return builder;
  };
  client.__kynoLockdownWrapped = true;
  return client;
}

function employeeToRpcPayload(emp) {
  if (typeof normalizeEmployeeSalaryFields === 'function') {
    normalizeEmployeeSalaryFields(emp);
  }
  var row = mapEmployeeToDb(emp);
  var isSuper = typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (!isSuper) {
    delete row.company_id;
  } else {
    row.company_id = resolveActiveCompanyId(emp);
  }
  return row;
}

function mapRpcEmployeeRow(data) {
  if (!data) return null;
  return {
    id: data.id,
    name: data.name,
    dept: data.dept,
    role: data.role,
    phone: data.phone,
    salary: data.salary,
    salary_type: data.salary_type,
    salary_half: data.salary_half,
    daily_rate: data.daily_rate,
    days: data.days,
    late_min: data.late_min,
    check_in: data.check_in,
    check_out: data.check_out,
    open_hours: data.open_hours,
    remote_attend: data.remote_attend,
    include_overtime_in_salary: data.include_overtime_in_salary,
    sal_status: data.sal_status,
    sal_bonus: data.sal_bonus,
    sal_deleted_period: data.sal_deleted_period,
    company_id: data.company_id
  };
}

function applyRpcEmployeeSnapshot(emp, data, options) {
  options = options || {};
  if (!emp || !data) return emp;
  var now = Date.now();
  var lockSalary = options.keepLocalSalary === true || (
    options.forceSalary !== true && options.forceRemote !== true && (
      (emp._salaryLockedUntil && now < emp._salaryLockedUntil) ||
      emp._pendingRemoteSync ||
      (emp._addedAt && (now - emp._addedAt) < 300000) ||
      (emp._localEmpEditAt && (now - emp._localEmpEditAt) < 86400000)
    )
  );
  var lockFlags = options.forceRemote !== true && (
    emp._pendingRemoteSync ||
    (emp._addedAt && (now - emp._addedAt) < 86400000) ||
    (emp._localEmpEditAt && (now - emp._localEmpEditAt) < 86400000)
  );
  var localSalary = lockSalary ? {
    salary: emp.salary,
    salaryType: emp.salaryType,
    salaryHalf: emp.salaryHalf,
    dailyRate: emp.dailyRate
  } : null;
  var localFlags = lockFlags ? {
    remoteAttend: emp.remoteAttend,
    openHours: emp.openHours
  } : null;
  if (data.id != null) emp.id = data.id;
  if (data.name != null) emp.name = data.name;
  if (data.dept != null) emp.dept = data.dept;
  if (data.role != null) emp.role = data.role;
  if (data.phone != null) emp.phone = data.phone;
  if (data.salary != null) emp.salary = data.salary;
  if (data.salary_type != null) emp.salaryType = data.salary_type;
  else if (data.salaryType != null) emp.salaryType = data.salaryType;
  if (data.salary_half != null) emp.salaryHalf = data.salary_half;
  else if (data.salaryHalf != null) emp.salaryHalf = data.salaryHalf;
  if (data.daily_rate != null) emp.dailyRate = data.daily_rate;
  else if (data.dailyRate != null) emp.dailyRate = data.dailyRate;
  if (data.days != null) emp.days = data.days;
  if (data.late_min != null) emp.lateMin = data.late_min;
  else if (data.lateMin != null) emp.lateMin = data.lateMin;
  if (data.remote_attend != null && !lockFlags) emp.remoteAttend = data.remote_attend === true;
  if (data.open_hours != null && !lockFlags) emp.openHours = data.open_hours === true;
  if (data.check_in) emp.checkIn = formatDbTime(data.check_in) || emp.checkIn;
  if (data.check_out) emp.checkOut = formatDbTime(data.check_out) || emp.checkOut;
  if (data.sal_status != null) emp.salStatus = data.sal_status;
  if (data.sal_bonus != null) emp.salBonus = data.sal_bonus;
  if (data.sal_deleted_period != null) emp.salDeletedPeriod = data.sal_deleted_period;
  if (data.company_id != null) emp.company_id = data.company_id;
  if (lockSalary && localSalary) {
    emp.salary = localSalary.salary;
    emp.salaryType = localSalary.salaryType || 'monthly';
    emp.salaryHalf = localSalary.salaryHalf;
    emp.dailyRate = localSalary.dailyRate;
  }
  if (lockFlags && localFlags) {
    emp.remoteAttend = localFlags.remoteAttend === true;
    emp.openHours = localFlags.openHours === true;
  }
  if (typeof normalizeEmployeeSalaryFields === 'function') normalizeEmployeeSalaryFields(emp);
  return emp;
}
if (typeof window !== 'undefined') window.applyRpcEmployeeSnapshot = applyRpcEmployeeSnapshot;

async function sb_previewSalary(employeeId, monthIso) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession) {
    try {
      if (!(await AuthApi.hasAuthenticatedSession())) return null;
    } catch (e) { return null; }
  }
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_preview_salary', {
      p_employee_id: employeeId,
      p_month: monthIso || null
    });
    if (rpc.error) {
      console.warn('sb_previewSalary:', rpc.error);
      return null;
    }
    if (rpc.data && rpc.data.error === 'subscription_inactive') return rpc.data;
    return rpc.data;
  } catch (e) {
    console.warn('sb_previewSalary:', e);
    return null;
  }
}

async function sb_recordClientAudit(payload) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  try {
    var body = payload || {};
    if (!body.ip_address && typeof window !== 'undefined' && window.currentClientIp) {
      body.ip_address = window.currentClientIp;
    }
    if (!body.user_agent && typeof navigator !== 'undefined') body.user_agent = navigator.userAgent || '';
    var rpc = await _sbClient.rpc('saas_record_client_audit', { p_payload: body });
    if (rpc.error) {
      console.warn('sb_recordClientAudit:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_error' };
    }
    var data = rpc.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { data = null; }
    }
    if (data && (data.ok === true || data.skipped === true)) return { ok: true, skipped: !!data.skipped };
    return { ok: false, error: (data && data.error) || 'audit_failed' };
  } catch (e) {
    console.warn('sb_recordClientAudit:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_exportCompanyData() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_export_company_data');
    if (rpc.error) {
      console.warn('sb_exportCompanyData:', rpc.error);
      return null;
    }
    return rpc.data;
  } catch (e) {
    console.warn('sb_exportCompanyData:', e);
    return null;
  }
}

async function sb_importCompanySettings(payload) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_import_company_settings', { p_payload: payload || {} });
    if (rpc.error) {
      console.warn('sb_importCompanySettings:', rpc.error);
      return null;
    }
    return rpc.data;
  } catch (e) {
    console.warn('sb_importCompanySettings:', e);
    return null;
  }
}

async function sb_importCompanyFull(payload) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_import_company_full', { p_payload: payload || {} });
    if (rpc.error) {
      console.warn('sb_importCompanyFull:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_failed' };
    }
    return rpc.data;
  } catch (e) {
    console.warn('sb_importCompanyFull:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_securityHealthReport() {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  var authOk = typeof ensureSbAuthForRead === 'function'
    ? await ensureSbAuthForRead()
    : (typeof ensureSbAuthForWrite === 'function' ? await ensureSbAuthForWrite() : false);
  if (!authOk) return { ok: false, error: 'auth_session_required' };
  try {
    var rpc = await _sbClient.rpc('saas_security_health_report');
    if (rpc.error) {
      console.warn('sb_securityHealthReport:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_failed' };
    }
    var data = rpc.data;
    if (data && typeof data === 'object' && data.ok === false) return data;
    if (data && typeof data === 'object') return Object.assign({ ok: true }, data);
    return { ok: false, error: 'empty_report' };
  } catch (e) {
    console.warn('sb_securityHealthReport:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_systemMonitoringSnapshot() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_system_monitoring_snapshot');
    if (rpc.error) {
      console.warn('sb_systemMonitoringSnapshot:', rpc.error);
      return {
        ok: false,
        error: rpc.error.message || 'rpc_failed',
        code: rpc.error.code,
        message: rpc.error.message
      };
    }
    return rpc.data;
  } catch (e) {
    console.warn('sb_systemMonitoringSnapshot:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_superExportCompany(companyId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_super_export_company', { p_company_id: companyId });
    if (rpc.error) {
      console.warn('sb_superExportCompany:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_failed' };
    }
    return rpc.data;
  } catch (e) {
    console.warn('sb_superExportCompany:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_superListAuditLogs(limit) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_super_list_audit_logs', { p_limit: limit || 100 });
    if (rpc.error) {
      console.warn('sb_superListAuditLogs:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_failed' };
    }
    return rpc.data;
  } catch (e) {
    console.warn('sb_superListAuditLogs:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_rpcIssueSalary(employeeId, monthIso) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_issue_salary', {
      p_employee_id: employeeId,
      p_month: monthIso || null
    });
    if (rpc.error) {
      console.error('sb_rpcIssueSalary:', rpc.error);
      return null;
    }
    if (!rpc.data || rpc.data.ok !== true) {
      console.warn('sb_rpcIssueSalary:', rpc.data && rpc.data.error);
      return null;
    }
    return rpc.data.data || null;
  } catch (e) {
    console.error('sb_rpcIssueSalary:', e);
    return null;
  }
}

async function sb_markSalaryRecordPaid(employeeId, monthIso) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  if (!employeeId || !monthIso) return null;
  try {
    var rpc = await _sbClient.rpc('saas_mark_salary_record_paid', {
      p_employee_id: employeeId,
      p_month: monthIso
    });
    if (rpc.error) {
      console.warn('sb_markSalaryRecordPaid:', rpc.error);
      return null;
    }
    if (!rpc.data || rpc.data.ok !== true) {
      console.warn('sb_markSalaryRecordPaid:', rpc.data && rpc.data.error);
      return null;
    }
    return rpc.data.data || null;
  } catch (e) {
    console.warn('sb_markSalaryRecordPaid:', e);
    return null;
  }
}

async function sb_updateSalaryRecordStatus(employeeId, monthIso, status, paidAt) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  if (!employeeId || !monthIso || !status) return null;
  try {
    if (kynoUseRpcWrites() || isHostedSupabase()) {
      var rpc = await _sbClient.rpc('saas_update_salary_record_status', {
        p_employee_id: employeeId,
        p_month: monthIso,
        p_status: status,
        p_paid_at: status === 'مدفوع' ? (paidAt || new Date().toISOString()) : null
      });
      if (rpc.error) {
        console.warn('sb_updateSalaryRecordStatus rpc:', rpc.error);
        return null;
      }
      if (!rpc.data || rpc.data.ok !== true) {
        console.warn('sb_updateSalaryRecordStatus rpc:', rpc.data && rpc.data.error);
        return null;
      }
      return rpc.data.data || null;
    }
    var cid = resolveActiveCompanyId();
    var updatePayload = { status: status };
    if (status === 'مدفوع') updatePayload.paid_at = paidAt || new Date().toISOString();
    else updatePayload.paid_at = null;
    var upd = _sbClient.from('salary_records')
      .update(updatePayload)
      .eq('employee_id', employeeId)
      .eq('month_iso', monthIso)
      .select()
      .maybeSingle();
    if (cid) upd = _sbClient.from('salary_records')
      .update(updatePayload)
      .eq('employee_id', employeeId)
      .eq('company_id', cid)
      .eq('month_iso', monthIso)
      .select()
      .maybeSingle();
    var res = await upd;
    if (res.error) {
      console.warn('sb_updateSalaryRecordStatus:', res.error);
      return null;
    }
    var empUpd = _sbClient.from('employees').update({ sal_status: status }).eq('id', employeeId);
    if (cid) empUpd = empUpd.eq('company_id', cid);
    await empUpd;
    return res.data || { status: status, month_iso: monthIso };
  } catch (e) {
    console.warn('sb_updateSalaryRecordStatus:', e);
    return null;
  }
}

async function sb_rpcUpsertEmployeeCore(emp) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_upsert_employee', {
      p_payload: employeeToRpcPayload(emp)
    });
    if (rpc.error) {
      _lastSbEmployeeSaveError = rpc.error.message || String(rpc.error);
      console.error('sb_rpcUpsertEmployeeCore:', rpc.error);
      return null;
    }
    if (!rpc.data || rpc.data.ok !== true) {
      var errCode = (rpc.data && rpc.data.error) || 'rpc_failed';
      _lastSbEmployeeSaveError = mapEmployeeSaveRpcError(errCode, rpc.data);
      return null;
    }
    return mapRpcEmployeeRow(rpc.data.data);
  } catch (e) {
    _lastSbEmployeeSaveError = e.message || String(e);
    console.error('sb_rpcUpsertEmployeeCore:', e);
    return null;
  }
}

async function sb_rpcDeleteEmployee(id) {
  _lastSbEmployeeDeleteError = '';
  var empId = parseInt(id, 10);
  if (!empId || empId <= 0) {
    _lastSbEmployeeDeleteError = 'invalid_params';
    return false;
  }
  if (!_sbClient && !(await ensureSupabaseClient())) {
    _lastSbEmployeeDeleteError = 'no_client';
    return false;
  }
  if (!(await ensureSbAuthForWrite())) {
    _lastSbEmployeeDeleteError = 'no_auth';
    return false;
  }
  try {
    var rpc = await _sbClient.rpc('saas_delete_employee', { p_employee_id: empId });
    if (rpc.error) {
      _lastSbEmployeeDeleteError = rpc.error.message || String(rpc.error);
      console.error('sb_rpcDeleteEmployee:', rpc.error);
      return false;
    }
    if (rpc.data && rpc.data.ok === true) return true;
    _lastSbEmployeeDeleteError = (rpc.data && rpc.data.error) || 'rpc_failed';
    console.warn('sb_rpcDeleteEmployee:', _lastSbEmployeeDeleteError, rpc.data || '');
    return false;
  } catch (e) {
    _lastSbEmployeeDeleteError = e.message || String(e);
    console.error('sb_rpcDeleteEmployee:', e);
    return false;
  }
}

async function _ensureEmployeeDeviceRow(employeeId, slot) {
  if (!_sbClient) return false;
  try {
    var ex = await _sbClient.from('employee_devices')
      .select('id')
      .eq('employee_id', employeeId)
      .eq('slot', slot)
      .maybeSingle();
    if (ex.data && ex.data.id) return true;
    var emp = (window.employees || []).find(function (e) { return e && e.id === employeeId; });
    var dev = emp && emp.devices ? emp.devices.find(function (d) { return d.slot === slot; }) : null;
    if (typeof sb_rpcUpsertEmployeeDevice === 'function') {
      return !!(await sb_rpcUpsertEmployeeDevice(employeeId, slot, {
        label: (dev && dev.label) || ('الهاتف ' + slot),
        token: dev && dev.token ? dev.token : null,
        fingerprint: (dev && dev.fingerprint) || ''
      }));
    }
    return false;
  } catch (e) {
    console.warn('_ensureEmployeeDeviceRow:', e);
    return false;
  }
}

async function sb_adminManageEmployeeDevice(employeeId, slot, options) {
  options = options || {};
  employeeId = parseInt(employeeId, 10);
  slot = parseInt(slot, 10);
  if (!employeeId || (slot !== 1 && slot !== 2)) return { ok: false, error: 'invalid_params' };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };

  var clearLink = options.clearLink === true;
  var fp = options.fingerprint != null ? String(options.fingerprint).trim() : null;

  if (kynoUseRpcWrites() || isHostedSupabase()) {
    try {
      await _ensureEmployeeDeviceRow(employeeId, slot);
      var rpc = await _sbClient.rpc('saas_admin_manage_employee_device', {
        p_employee_id: employeeId,
        p_slot: slot,
        p_fingerprint: clearLink ? null : fp,
        p_clear_link: clearLink
      });
      if (rpc.error) {
        console.error('sb_adminManageEmployeeDevice rpc:', rpc.error);
        return { ok: false, error: rpc.error.message || 'rpc_error' };
      }
      var payload = rpc.data;
      if (typeof payload === 'string') {
        try { payload = JSON.parse(payload); } catch (e) { payload = null; }
      }
      if (payload && payload.ok === true) return { ok: true, data: payload.data };
      return { ok: false, error: (payload && payload.error) || 'update_failed' };
    } catch (e) {
      console.error('sb_adminManageEmployeeDevice:', e);
      return { ok: false, error: e.message || 'exception' };
    }
  }

  try {
    await _ensureEmployeeDeviceRow(employeeId, slot);
    var empRes = await _sbClient.from('employees').select('id, company_id').eq('id', employeeId).maybeSingle();
    if (empRes.error || !empRes.data) return { ok: false, error: 'employee_not_found' };
    var updatePayload = clearLink
      ? { fingerprint: '', ip: '', linked_at: null, token_used_at: null, last_login: null, device_info: {} }
      : { fingerprint: fp || '' };
    var upd = await _sbClient.from('employee_devices')
      .update(updatePayload)
      .eq('employee_id', employeeId)
      .eq('slot', slot)
      .select()
      .maybeSingle();
    if (upd.error) return { ok: false, error: upd.error.message || 'update_failed' };
    if (!upd.data) return { ok: false, error: 'device_not_found' };
    return { ok: true, data: upd.data };
  } catch (e2) {
    console.error('sb_adminManageEmployeeDevice fallback:', e2);
    return { ok: false, error: e2.message || 'exception' };
  }
}

async function sb_rpcUpsertEmployeeDevice(employeeId, slot, dev) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  dev = dev || {};
  try {
    var rpc = await _sbClient.rpc('saas_upsert_employee_device', {
      p_employee_id: employeeId,
      p_slot: slot,
      p_payload: {
        label: dev.label || null,
        ip: dev.ip || '',
        fingerprint: dev.fingerprint || '',
        pin: dev.pin || '',
        token: dev.token || null,
        token_created_at: dev.tokenCreatedAt || dev.token_created_at || null,
        token_used_at: dev.tokenUsedAt || dev.token_used_at || null,
        device_info: dev.deviceInfo || dev.device_info || {},
        linked_at: dev.linked_at || null,
        last_login: dev.last_login || null
      }
    });
    if (rpc.error || !rpc.data || rpc.data.ok !== true) {
      console.error('sb_rpcUpsertEmployeeDevice:', rpc.error || rpc.data);
      return null;
    }
    return rpc.data.data;
  } catch (e) {
    console.error('sb_rpcUpsertEmployeeDevice:', e);
    return null;
  }
}

async function sb_rpcDeleteAttendance(rec) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (!(await ensureSbAuthForWrite())) return false;
  try {
    var dateIso = rec && (rec.dateIso || rec.date_iso) ? String(rec.dateIso || rec.date_iso).slice(0, 10) : null;
    var rpc = await _sbClient.rpc('saas_delete_attendance', {
      p_employee_id: rec && rec.empId ? rec.empId : null,
      p_date_iso: dateIso,
      p_attendance_id: rec && rec.id ? rec.id : null
    });
    if (rpc.data && rpc.data.ok === true) return true;
    if (rpc.data && rpc.data.error === 'attendance_not_found') return true;
    return false;
  } catch (e) {
    console.error('sb_rpcDeleteAttendance:', e);
    return false;
  }
}

async function sb_rpcDeleteSalaryRecord(employeeId, opts) {
  opts = opts || {};
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (!(await ensureSbAuthForWrite())) return false;
  try {
    var rpc = await _sbClient.rpc('saas_delete_salary_record', {
      p_employee_id: employeeId,
      p_month_iso: opts.monthIso || opts.month || null,
      p_period_prefix: opts.periodPrefix || null
    });
    return !!(rpc.data && rpc.data.ok === true);
  } catch (e) {
    console.error('sb_rpcDeleteSalaryRecord:', e);
    return false;
  }
}

async function sb_rpcSaveSettings(settingsObj) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (!(await ensureSbAuthForWrite())) return false;
  try {
    var rpc = await _sbClient.rpc('saas_upsert_tenant_settings', { p_settings: settingsObj || {} });
    if (rpc.error) {
      console.error('sb_rpcSaveSettings:', rpc.error);
      return false;
    }
    var data = rpc.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { data = null; }
    }
    return !!(data && data.ok === true);
  } catch (e) {
    console.error('sb_rpcSaveSettings:', e);
    return false;
  }
}

async function sb_rpcSavePlatformGlobals(payload) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'السحابة غير جاهزة' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'أعد تسجيل الدخول' };
  try {
    var body = {};
    if (payload.supportWhatsApp != null) body.support_whatsapp = String(payload.supportWhatsApp).trim();
    if (payload.supportWhatsAppTeam != null) body.support_whatsapp_team = String(payload.supportWhatsAppTeam).trim();
    if (payload.announcements != null) body.announcements = payload.announcements;
    var rpc = await _sbClient.rpc('saas_save_platform_globals', { p_payload: body });
    if (rpc.error) return { ok: false, error: rpc.error.message || String(rpc.error) };
    if (!rpc.data || rpc.data.ok !== true) return { ok: false, error: (rpc.data && rpc.data.error) || 'rpc_failed' };
    if (typeof sb_loadPlatformGlobals === 'function') await sb_loadPlatformGlobals();
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message || String(e) };
  }
}

async function sb_rpcUpsertAttendanceAdmin(rec) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_upsert_attendance_admin', {
      p_employee_id: rec.empId,
      p_date_iso: rec.dateIso,
      p_check_in: rec.ci && rec.ci !== '—' ? rec.ci : null,
      p_check_out: rec.co && rec.co !== '—' ? rec.co : null,
      p_status: rec.status || null,
      p_reason: rec._adminReason || 'admin_upsert'
    });
    if (rpc.error) {
      console.error('sb_rpcUpsertAttendanceAdmin:', rpc.error);
      return null;
    }
    if (!rpc.data || rpc.data.ok !== true) {
      console.warn('sb_rpcUpsertAttendanceAdmin:', rpc.data && rpc.data.error);
      return null;
    }
    return rpc.data.data || null;
  } catch (e) {
    console.error('sb_rpcUpsertAttendanceAdmin:', e);
    return null;
  }
}

function initSupabase() {
  try {
    if (_sbClient) return true;
    var url = getSupabaseUrl();
    var key = getSupabaseAnonKey();
    if (!url || !key) {
      console.error(
        'إعدادات الاتصال بالسحابة غير مكتملة — راجع ملف الإعدادات المحلي'
      );
      return false;
    }
    if (window.supabase && typeof window.supabase.createClient === 'function') {
      var memStorage = typeof KynoMemoryAuthStorage === 'function' ? KynoMemoryAuthStorage() : null;
      _sbClient = window.supabase.createClient(url, key, {
        auth: {
          persistSession: false,
          autoRefreshToken: true,
          detectSessionInUrl: false,
          storage: memStorage || undefined,
          storageKey: 'kyno-auth-memory'
        }
      });
      _sbClient = wrapSupabaseClientForLockdown(_sbClient);
      window._sbClient = _sbClient;
      return true;
    }
    return false;
  } catch (e) {
    console.error('initSupabase error:', e);
    return false;
  }
}

var _proxyProbed = false;

async function probeSupabaseProxyOnce() {
  if (_proxyProbed) return;
  _proxyProbed = true;
  if (typeof window === 'undefined' || !window.BasmaConfig) return;
  if (!BasmaConfig.isSupabaseProxied || !BasmaConfig.isSupabaseProxied()) return;
  var key = getSupabaseAnonKey();
  var base = BasmaConfig.supabaseUrl();
  if (!key || !base) return;
  try {
    var res = await fetch(base.replace(/\/$/, '') + '/functions/v1/auth-session', {
      headers: { apikey: key, Authorization: 'Bearer ' + key },
      credentials: 'include'
    });
    if (res.status === 404 || res.status === 502) {
      if (BasmaConfig.markProxyUnavailable) BasmaConfig.markProxyUnavailable();
      if (BasmaConfig.isNetlifyHost && BasmaConfig.isNetlifyHost()) {
        console.warn('[KYNO] supabase-proxy غير منشور على Netlify (HTTP ' + res.status + '). شغّل: netlify deploy --prod --dir=dist');
        return;
      }
      if (BasmaConfig.fallbackToDirectSupabase()) {
        console.warn('[KYNO] supabase-proxy غير منشور (HTTP ' + res.status + ') — الاتصال المباشر بـ Supabase');
      }
    }
  } catch (e) {
    if (BasmaConfig.isNetlifyHost && BasmaConfig.isNetlifyHost()) {
      if (BasmaConfig.markProxyUnavailable) BasmaConfig.markProxyUnavailable();
      console.warn('[KYNO] /sb غير متاح — نشر Netlify Function مطلوب');
      return;
    }
    if (BasmaConfig.fallbackToDirectSupabase()) {
      console.warn('[KYNO] /sb غير متاح — الاتصال المباشر بـ Supabase');
    }
  }
}

if (typeof window !== 'undefined') {
  window.__basmaResetSupabaseClient = function () {
    _sbClient = null;
    window._sbClient = null;
  };
}

async function ensureSupabaseClient(maxAttempts) {
  await probeSupabaseProxyOnce();
  if (typeof window !== 'undefined' && window.BasmaConfig && BasmaConfig.isProxyBroken && BasmaConfig.isProxyBroken()) {
    return false;
  }
  if (_sbClient) return true;
  var attempts = maxAttempts || 20;
  for (var i = 0; i < attempts; i++) {
    if (initSupabase()) return true;
    await new Promise(function (r) { setTimeout(r, 300); });
  }
  return false;
}

/** JWT صالح مطلوب لـ RLS (departments / employees …) — يجدّد مثل الكتابة */
async function ensureSbAuthForRead() {
  if (typeof window !== 'undefined' && window.__basmaLoggingOut) return false;
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    return AuthApi.refreshAuthSessionForWrite();
  }
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    var ok = await AuthApi.ensureValidSession();
    if (ok) return true;
    if (typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.id &&
        AuthApi.restoreSessionFromSupabaseJwt) {
      var restored = await AuthApi.restoreSessionFromSupabaseJwt(saasCurrentUser.id);
      if (restored) {
        return AuthApi.ensureValidSession();
      }
    }
    return false;
  }
  try {
    var bare = await _sbClient.auth.getSession();
    return !!(bare.data && bare.data.session && bare.data.session.access_token);
  } catch (e) {
    return false;
  }
}

/** JWT صالح مطلوب لـ RLS (departments / employees …) */
async function ensureSbAuthForWrite() {
  if (typeof window !== 'undefined' && window.__basmaLoggingOut) return false;
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (typeof AuthApi !== 'undefined' && AuthApi.refreshAuthSessionForWrite) {
    return AuthApi.refreshAuthSessionForWrite();
  }
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    var ok = await AuthApi.ensureValidSession();
    if (ok) return true;
    if (typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.id &&
        AuthApi.restoreSessionFromSupabaseJwt) {
      var restored = await AuthApi.restoreSessionFromSupabaseJwt(saasCurrentUser.id);
      if (restored) {
        return AuthApi.ensureValidSession();
      }
    }
    return false;
  }
  try {
    var bare = await _sbClient.auth.getSession();
    return !!(bare.data && bare.data.session && bare.data.session.access_token);
  } catch (e) {
    return false;
  }
}

function shouldPreferLocalAppSettings() {
  return !!(typeof window !== 'undefined' && window.__basmaLocalSettingsAt &&
    (Date.now() - window.__basmaLocalSettingsAt < 120000));
}

function shouldPreferLocalNotifications() {
  return !!(typeof window !== 'undefined' && window.__basmaLocalNotifAt &&
    (Date.now() - window.__basmaLocalNotifAt < 600000));
}

function mergeActivityLogRemote(localArr, remoteArr) {
  var scope = typeof getNotificationScopeId === 'function' ? getNotificationScopeId() : resolveActiveCompanyId();
  var filterScope = function (arr) {
    if (!Array.isArray(arr)) return [];
    if (typeof notificationBelongsToScope !== 'function') return arr;
    return arr.filter(function (x) { return notificationBelongsToScope(x, scope); });
  };
  var local = filterScope(localArr);
  var remote = filterScope(remoteArr);
  if (window.__basmaNotifClearedAt && Date.now() - window.__basmaNotifClearedAt < 600000 && local.length === 0) {
    return [];
  }
  var byId = {};
  function addEntry(entry) {
    if (!entry || !entry.id) return;
    if (byId[entry.id]) {
      var prev = byId[entry.id];
      var prevTs = new Date(prev.ts || 0).getTime();
      var entryTs = new Date(entry.ts || 0).getTime();
      var newer = entryTs >= prevTs ? entry : prev;
      var older = entryTs >= prevTs ? prev : entry;
      byId[entry.id] = Object.assign({}, older, newer, {
        read: prev.read === true || entry.read === true
      });
    } else {
      byId[entry.id] = Object.assign({}, entry);
    }
  }
  remote.forEach(addEntry);
  local.forEach(addEntry);
  return Object.keys(byId).map(function (id) { return byId[id]; }).sort(function (a, b) {
    return new Date(b.ts || 0).getTime() - new Date(a.ts || 0).getTime();
  }).slice(0, 500);
}

function mergeEmployeeNotificationsRemote(localArr, remoteArr) {
  var scope = typeof getNotificationScopeId === 'function' ? getNotificationScopeId() : resolveActiveCompanyId();
  var filterEmp = function (arr) {
    if (!Array.isArray(arr)) return [];
    if (scope === 'super') return [];
    return arr.filter(function (x) {
      var cid = x && x.companyId != null ? parseInt(x.companyId, 10) : NaN;
      if (!cid || isNaN(cid)) return false;
      return cid === parseInt(scope, 10);
    });
  };
  var local = filterEmp(localArr);
  var remote = filterEmp(remoteArr);
  var byId = {};
  function addEntry(entry) {
    if (!entry || !entry.id) return;
    if (byId[entry.id]) {
      var prev = byId[entry.id];
      var prevTs = new Date(prev.ts || 0).getTime();
      var entryTs = new Date(entry.ts || 0).getTime();
      var newer = entryTs >= prevTs ? entry : prev;
      var older = entryTs >= prevTs ? prev : entry;
      byId[entry.id] = Object.assign({}, older, newer, {
        read: prev.read === true || entry.read === true,
        unread: prev.unread === false ? false : (entry.unread !== undefined ? entry.unread : !entry.read)
      });
    } else {
      byId[entry.id] = Object.assign({}, entry);
    }
  }
  remote.forEach(addEntry);
  local.forEach(addEntry);
  return Object.keys(byId).map(function (id) { return byId[id]; }).sort(function (a, b) {
    return new Date(b.ts || 0).getTime() - new Date(a.ts || 0).getTime();
  }).slice(0, 300);
}

function mapRemoteLeaveRow(row) {
  if (!row) return null;
  var empId = row.employee_id;
  var emp = (typeof window !== 'undefined' && window.employees)
    ? (window.employees || []).find(function (x) { return x && x.id === empId; })
    : null;
  return {
    id: 'leave_r_' + row.id,
    _remoteId: row.id,
    empId: empId,
    empName: emp ? emp.name : '',
    dept: emp ? emp.dept : '',
    company_id: row.company_id,
    leaveType: row.leave_type,
    fromDate: row.from_date,
    toDate: row.to_date || null,
    multiplier: row.multiplier || 1,
    absenceDays: row.leave_type === 'absence_mult' ? (row.multiplier || 1) : 0,
    note: row.note || '',
    addedAt: row.added_at,
    leave_ref: row.leave_ref,
    _pendingSync: false
  };
}

function mergeLeavesRemote(localLeaves, remoteRows) {
  var remote = (remoteRows || []).map(mapRemoteLeaveRow).filter(Boolean);
  var remoteRefs = {};
  remote.forEach(function (r) {
    if (r.leave_ref) remoteRefs[r.leave_ref] = true;
    if (r.id) remoteRefs[r.id] = true;
    if (r._remoteId) remoteRefs['rid_' + r._remoteId] = true;
  });
  var merged = remote.slice();
  (localLeaves || []).forEach(function (l) {
    if (!l) return;
    if (!l._pendingSync) return;
    if (remoteRefs[l.id]) return;
    if (l._remoteId && remoteRefs['rid_' + l._remoteId]) return;
    merged.unshift(l);
  });
  return merged;
}

async function syncLeavesFromSupabase(options) {
  options = options || {};
  if (typeof sb_getLeaves !== 'function') return false;
  if (!hasTenantSyncContext() && !options.empId) return false;
  try {
    var res = await sb_getLeaves(options.empId || null);
    if (!res || !res.ok || !Array.isArray(res.data)) return false;
    window.leavesData = mergeLeavesRemote(window.leavesData || [], res.data);
    return true;
  } catch (e) {
    console.warn('syncLeavesFromSupabase:', e);
    return false;
  }
}

var _pendingSyncRetryTimer = null;
var _pendingSyncRetryBackoffMs = 4500;
function schedulePendingSyncRetry() {
  if (_pendingSyncRetryTimer) clearTimeout(_pendingSyncRetryTimer);
  if (typeof window !== 'undefined' && window.BasmaCloud && BasmaCloud.updateConnectivityBanner) {
    BasmaCloud.updateConnectivityBanner();
  }
  _pendingSyncRetryTimer = setTimeout(async function () {
    _pendingSyncRetryTimer = null;
    if (typeof window !== 'undefined' && window.__basmaSuppressRealtimeUntil &&
      Date.now() < window.__basmaSuppressRealtimeUntil) {
      schedulePendingSyncRetry();
      return;
    }
    var hasPending = hasPendingDataSync();
    if (!hasPending) {
      if (window.BasmaCloud && BasmaCloud.updateConnectivityBanner) BasmaCloud.updateConnectivityBanner();
      return;
    }
    if (typeof window.BasmaCloud !== 'undefined' && BasmaCloud.flushPendingToCloud) {
      try {
        var flushed = await BasmaCloud.flushPendingToCloud({ reason: 'pending-retry', force: true });
        if (!flushed && hasPendingDataSync()) {
          _pendingSyncRetryBackoffMs = Math.min(_pendingSyncRetryBackoffMs + 2000, 12000);
          schedulePendingSyncRetry();
        } else {
          _pendingSyncRetryBackoffMs = 4500;
        }
        return;
      } catch (e) {
        console.warn('schedulePendingSyncRetry flush:', e);
      }
    }
    if (typeof syncToSupabase !== 'function') return;
    try {
      await syncToSupabase({ reason: 'pending-retry' });
      _pendingSyncRetryBackoffMs = 4500;
    } catch (e) {
      console.warn('schedulePendingSyncRetry:', e);
      _pendingSyncRetryBackoffMs = Math.min(_pendingSyncRetryBackoffMs + 2000, 12000);
      schedulePendingSyncRetry();
    }
  }, _pendingSyncRetryBackoffMs);
}
if (typeof window !== 'undefined') {
  window.syncLeavesFromSupabase = syncLeavesFromSupabase;
  window.mergeLeavesRemote = mergeLeavesRemote;
  window.schedulePendingSyncRetry = schedulePendingSyncRetry;
  window.hasPendingDataSync = hasPendingDataSync;
  window.markTenantSyncedNow = markTenantSyncedNow;
}

function scheduleRealtimePull(reason) {
  if (window.__basmaSuppressRealtimeUntil && Date.now() < window.__basmaSuppressRealtimeUntil) return;
  if (!hasTenantSyncContext()) return;
  clearTimeout(_sbRealtimePullTimer);
  _sbRealtimePullTimer = setTimeout(async function () {
    if (window.__basmaSuppressRealtimeUntil && Date.now() < window.__basmaSuppressRealtimeUntil) return;
    if (!hasTenantSyncContext()) return;
    if (_sbRealtimePulling) return;
    _sbRealtimePulling = true;
    try {
      if (typeof sb_loadPlatformGlobals === 'function') {
        await sb_loadPlatformGlobals();
      }
      if (typeof syncFromSupabase === 'function') {
        await syncFromSupabase({ realtime: true, reason: reason || 'realtime' });
      }
    } catch (e) {
      console.warn('Realtime pull failed:', e);
    } finally {
      _sbRealtimePulling = false;
    }
  }, 150);
}

async function setupSupabaseRealtime() {
  if (_sbRealtimeChannel) return _sbRealtimeChannel;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (typeof ensureSbAuthForRead === 'function') {
    var canRead = await ensureSbAuthForRead();
    if (!canRead) return null;
  }
  try {
    var tables = window.BasmaConfig && BasmaConfig.realtimeTables
      ? BasmaConfig.realtimeTables()
      : ['employees', 'employee_devices', 'attendance', 'app_settings', 'leaves'];
    _sbRealtimeChannel = _sbClient.channel('basma-shared-state');
    tables.forEach(function (table) {
      _sbRealtimeChannel.on('postgres_changes', { event: '*', schema: 'public', table: table }, function () {
        scheduleRealtimePull(table);
      });
    });
    _sbRealtimeChannel.subscribe();
    return _sbRealtimeChannel;
  } catch (e) {
    console.warn('setupSupabaseRealtime:', e);
    return null;
  }
}

// ======= Employees =======
async function sb_getEmployees(opts) {
  opts = opts || {};
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForRead())) return null;
  try {
  var companyId = null;
  if (typeof AuthApi !== 'undefined' && AuthApi.getCompanyId) {
    var jwtCid = AuthApi.getCompanyId();
    if (jwtCid !== undefined) companyId = jwtCid;
  }
  var limit = opts.limit || getPageSize();
  var offset = opts.offset || 0;
  var end = offset + limit - 1;
  var q = _sbClient.from('employees').select(EMPLOYEE_SELECT).order('id');
  if (companyId) q = q.eq('company_id', companyId);
  q = q.range(offset, end);
  const { data, error } = await q;
  if (error) { console.error('sb_getEmployees:', error); return null; }
  return data.map(mapEmployeeFromDb);
  } catch (e) {
    console.warn('sb_getEmployees:', e);
    return null;
  }
}

function formatDbTime(value) {
  if (value == null || value === '') return '';
  var s = String(value).trim();
  var m = s.match(/^(\d{1,2}):(\d{2})/);
  if (!m) return '';
  return String(m[1]).padStart(2, '0') + ':' + m[2];
}

async function sb_refreshEmployeeDevices(empId) {
  if (!empId) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var res = await _sbClient.from('employee_devices')
      .select('slot,label,ip,fingerprint,pin,token,token_created_at,token_used_at,device_info,linked_at,last_login')
      .eq('employee_id', empId);
    if (res.error || !res.data) return null;
    var emp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (!emp) return null;
    if (typeof normalizeEmployee === 'function') normalizeEmployee(emp);
    res.data.forEach(function (row) {
      var dev = (emp.devices || []).find(function (d) { return d.slot === row.slot; });
      if (!dev) return;
      dev.fingerprint = row.fingerprint || '';
      dev.ip = row.ip || '';
      dev.pin = row.pin || dev.pin || '';
      if (row.token) dev.token = row.token;
      if (row.token_created_at) dev.tokenCreatedAt = row.token_created_at;
      if (row.token_used_at) dev.tokenUsedAt = row.token_used_at;
      else if (row.token_used_at === null) dev.tokenUsedAt = '';
      if (row.linked_at) dev.linked_at = row.linked_at;
      else if (row.linked_at === null) dev.linked_at = '';
      if (row.last_login) dev.last_login = row.last_login;
      else if (row.last_login === null) dev.last_login = '';
      if (row.device_info) dev.deviceInfo = row.device_info;
      if (row.label) dev.label = row.label;
    });
    delete emp._freshDevices;
    if (typeof saveData === 'function') saveData();
    return emp;
  } catch (e) {
    console.warn('sb_refreshEmployeeDevices:', e);
    return null;
  }
}

async function sb_upsertEmployee(emp, options) {
  options = options || {};
  _lastSbEmployeeSaveError = '';
  if (typeof KynoValidation !== 'undefined' && emp) {
    var empCheck = KynoValidation.validateEmployee(emp);
    if (!empCheck.valid) {
      _lastSbEmployeeSaveError = empCheck.errors.join(' — ');
      return null;
    }
  }
  if (!_sbClient && !(await ensureSupabaseClient())) {
    _lastSbEmployeeSaveError = 'السحابة غير جاهزة';
    return null;
  }
  if (!(await ensureSbAuthForWrite())) {
    _lastSbEmployeeSaveError = 'انتهت جلسة الدخول — سجّل الدخول مرة أخرى';
    return null;
  }
  if (options.requireExisting && emp && emp.id) {
    var ex = await _sbClient.from('employees').select('id').eq('id', emp.id).maybeSingle();
    if (ex.error || !ex.data) {
      _lastSbEmployeeSaveError = 'سجل الموظف غير موجود في قاعدة البيانات';
      return null;
    }
  }
  var data = null;
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    data = await sb_rpcUpsertEmployeeCore(emp);
  } else {
    const row = mapEmployeeToDb(emp);
    const res = await _sbClient
      .from('employees')
      .upsert(row, { onConflict: 'id' })
      .select()
      .single();
    if (res.error) {
      if (isSbPermissionDenied(res.error)) {
        markKynoLockdownDetected();
        data = await sb_rpcUpsertEmployeeCore(emp);
      } else {
        var em = res.error.message || String(res.error);
        if (em.indexOf('employee_limit_reached') >= 0) {
          _lastSbEmployeeSaveError = mapEmployeeSaveRpcError('employee_limit_reached', null);
        } else if (em.indexOf('subscription_inactive') >= 0) {
          _lastSbEmployeeSaveError = mapEmployeeSaveRpcError('subscription_inactive', null);
        } else if (em.indexOf('company_id_required') >= 0) {
          _lastSbEmployeeSaveError = 'تعذّر تحديد الشركة — أعد تسجيل الدخول.';
        } else {
          _lastSbEmployeeSaveError = em;
        }
        console.error('sb_upsertEmployee:', res.error);
        return null;
      }
    } else {
      data = res.data;
    }
  }
  if (!data) return null;
  applyRpcEmployeeSnapshot(emp, data);
  if (typeof window !== 'undefined' && typeof window.clearEmployeeDeletedLocally === 'function') {
    window.clearEmployeeDeletedLocally(data.id);
  }
  // Save devices — لا تُمسح بصمة/IP المسجّلة من الهاتف عند مزامنة الإدارة
  if (emp.devices) {
    var devCompanyId = resolveActiveCompanyId(emp);
    var deviceSaveFailed = false;
    for (const dev of emp.devices) {
      var localFp = (dev.fingerprint || '').trim();
      var localIp = (dev.ip || '').trim();
      var existingDev = null;
      var skipStaleDevice = !!(emp._freshDevices);
      try {
        if (!skipStaleDevice) {
          var exRes = await _sbClient.from('employee_devices')
            .select('fingerprint, ip, linked_at, token_used_at, last_login, device_info, token')
            .eq('employee_id', data.id)
            .eq('slot', dev.slot)
            .maybeSingle();
          if (!exRes.error && exRes.data) existingDev = exRes.data;
        }
      } catch (e) { /* ignore */ }

      var outFp = localFp;
      var outIp = localIp;
      var outLinkedAt = dev.linked_at || null;
      var outTokenUsedAt = dev.tokenUsedAt || dev.token_used_at || null;
      var outLastLogin = dev.last_login || null;
      var outDeviceInfo = dev.deviceInfo || dev.device_info || {};

      if (existingDev) {
        if (!outFp && existingDev.fingerprint) outFp = existingDev.fingerprint;
        if (!outIp && existingDev.ip) outIp = existingDev.ip;
        if (!outLinkedAt && existingDev.linked_at) outLinkedAt = existingDev.linked_at;
        if (!outTokenUsedAt && existingDev.token_used_at) outTokenUsedAt = existingDev.token_used_at;
        if (!outLastLogin && existingDev.last_login) outLastLogin = existingDev.last_login;
        if ((!outDeviceInfo || !Object.keys(outDeviceInfo).length) && existingDev.device_info) {
          outDeviceInfo = existingDev.device_info;
        }
      }

      if (kynoUseRpcWrites() || isHostedSupabase()) {
        var rpcDev = await sb_rpcUpsertEmployeeDevice(data.id, dev.slot, {
          label: dev.label || 'الهاتف ' + dev.slot,
          ip: outIp,
          fingerprint: outFp,
          pin: dev.pin || '',
          token: dev.token || null,
          tokenCreatedAt: dev.tokenCreatedAt || dev.token_created_at || null,
          tokenUsedAt: outTokenUsedAt,
          deviceInfo: outDeviceInfo,
          linked_at: outLinkedAt,
          last_login: outLastLogin
        });
        if (!rpcDev) {
          deviceSaveFailed = true;
          emp._devicesPendingSync = true;
          _lastSbEmployeeSaveError = 'employee_devices RPC failed';
          console.warn('sb_upsertEmployee: device slot', dev.slot, 'RPC failed');
          continue;
        }
        continue;
      }

      const { error: devErr } = await _sbClient.from('employee_devices').upsert({
        employee_id: data.id,
        company_id: devCompanyId,
        slot: dev.slot,
        label: dev.label || 'الهاتف ' + dev.slot,
        ip: outIp,
        fingerprint: outFp,
        pin: dev.pin || '',
        token: dev.token || null,
        token_created_at: dev.tokenCreatedAt || dev.token_created_at || null,
        token_used_at: outTokenUsedAt,
        device_info: outDeviceInfo,
        linked_at: outLinkedAt,
        last_login: outLastLogin
      }, { onConflict: 'employee_id,slot' });
      if (devErr) {
        deviceSaveFailed = true;
        emp._devicesPendingSync = true;
        _lastSbEmployeeSaveError = devErr.message || String(devErr);
        console.error('employee_devices upsert:', devErr);
        continue;
      }
    }
    if (deviceSaveFailed) {
      emp._pendingRemoteSync = true;
    }
  }
  return data;
}

function mapQrRegistrationPayload(d) {
  if (!d || !d.employee_id) return null;
  return {
    employee_id: d.employee_id,
    emp_name: d.emp_name,
    dept: d.dept,
    company_id: d.company_id,
    slot: d.slot,
    label: d.label,
    token: d.token,
    pin: d.pin,
    fingerprint: d.fingerprint,
    ip: d.ip,
    barcode: d.barcode,
    open_hours: d.open_hours === true,
    remote_attend: d.remote_attend === true,
    check_in: d.check_in,
    check_out: d.check_out
  };
}

function applyEmployeeClientProfile(emp, data) {
  if (!emp || !data) return emp;
  if (data.emp_name != null || data.name != null) emp.name = data.emp_name || data.name;
  if (data.dept != null) emp.dept = data.dept;
  if (data.role != null || data.job != null || data.job_title != null) emp.role = data.role || data.job || data.job_title || emp.role;
  if (data.phone != null || data.mobile != null || data.emp_phone != null) emp.phone = data.phone || data.mobile || data.emp_phone || '';
  if (data.salary != null || data.base_salary != null) emp.salary = parseInt(data.salary != null ? data.salary : data.base_salary, 10) || 0;
  if (data.salary_type != null || data.salaryType != null) emp.salaryType = data.salary_type || data.salaryType || emp.salaryType;
  if (data.salary_half != null || data.salaryHalf != null) emp.salaryHalf = parseInt(data.salary_half != null ? data.salary_half : data.salaryHalf, 10) || 0;
  if (data.daily_rate != null || data.dailyRate != null) emp.dailyRate = parseInt(data.daily_rate != null ? data.daily_rate : data.dailyRate, 10) || 0;
  if (data.company_id != null) emp.company_id = data.company_id;
  if (data.remote_attend != null) emp.remoteAttend = data.remote_attend === true;
  if (data.remoteAttend != null) emp.remoteAttend = data.remoteAttend === true;
  if (data.open_hours != null) emp.openHours = data.open_hours === true;
  if (data.openHours != null) emp.openHours = data.openHours === true;
  if (data.check_in) emp.checkIn = formatDbTime(data.check_in) || emp.checkIn;
  if (data.check_out) emp.checkOut = formatDbTime(data.check_out) || emp.checkOut;
  if (data.avatar_url != null) emp.avatarUrl = data.avatar_url || '';
  if (data.avatarUrl != null) emp.avatarUrl = data.avatarUrl || '';
  if (data.gps_lat != null && String(data.gps_lat).trim() !== '') {
    window.appSettings = window.appSettings || {};
    window.appSettings.gpsLat = String(data.gps_lat).trim();
  }
  if (data.gps_lng != null && String(data.gps_lng).trim() !== '') {
    window.appSettings = window.appSettings || {};
    window.appSettings.gpsLng = String(data.gps_lng).trim();
  }
  if (data.gps_range != null && String(data.gps_range).trim() !== '') {
    window.appSettings = window.appSettings || {};
    window.appSettings.gpsRange = parseInt(data.gps_range, 10) || window.appSettings.gpsRange || 100;
  }
  if (data.gps_name != null && String(data.gps_name).trim() !== '') {
    window.appSettings = window.appSettings || {};
    window.appSettings.gpsName = String(data.gps_name).trim();
  }
  if (Array.isArray(data.finance_items)) {
    window.appSettings = window.appSettings || {};
    var empId = String(emp.id);
    var others = Array.isArray(window.appSettings.financeItems)
      ? window.appSettings.financeItems.filter(function (item) {
        return !item || String(item.empId || item.emp_id || item.employee_id) !== empId;
      })
      : [];
    var mappedFinance = data.finance_items.map(function (item) {
      var out = Object.assign({}, item);
      out.empId = parseInt(out.empId != null ? out.empId : (out.emp_id != null ? out.emp_id : (out.employee_id != null ? out.employee_id : emp.id)), 10) || emp.id;
      out.amount = parseInt(out.amount, 10) || 0;
      return out;
    });
    window.appSettings.financeItems = others.concat(mappedFinance);
    emp._financeItemsLoaded = true;
    if (typeof clearSalaryCacheForEmployee === 'function') clearSalaryCacheForEmployee(emp.id);
  }
  if (typeof normalizeEmployee === 'function') normalizeEmployee(emp);
  return emp;
}

async function sb_verifyEmployeeDeviceAccess(empId, options) {
  options = options || {};
  if (!empId) return null;
  return sb_fetchEmployeeClientProfile(empId, options);
}

function mapSalaryRecordFromDb(row) {
  if (!row) return null;
  var status = row.status || 'معلق';
  var base = parseInt(row.base_salary, 10) || 0;
  var bonus = parseInt(row.bonus, 10) || 0;
  var deduct = parseInt(row.total_deduct != null ? row.total_deduct : row.deductions, 10) || 0;
  var ot = parseInt(row.overtime_amount != null ? row.overtime_amount : row.overtime, 10) || 0;
  var net = row.net_salary != null ? (parseInt(row.net_salary, 10) || 0) : Math.max(0, base + bonus + ot - deduct);
  var monthIso = row.month_iso || '';
  var monthDisplay = row.month_label || '—';
  if (monthIso) {
    var mk = String(monthIso).match(/^(\d{4})-(\d{2})(?:-(H1|H2))?$/);
    monthDisplay = mk ? mk[1] + '/' + mk[2] + '/' + (mk[3] === 'H2' ? '16' : '01') : monthIso;
  } else if (row.paid_at) {
    var pd = new Date(String(row.paid_at));
    if (!isNaN(pd.getTime())) {
      monthDisplay = pd.getFullYear() + '/' + String(pd.getMonth() + 1).padStart(2, '0') + '/' + String(pd.getDate()).padStart(2, '0');
    }
  }
  return {
    id: row.id,
    month: monthDisplay,
    monthIso: monthIso,
    base: base,
    ot: ot,
    deduct: deduct,
    net: net,
    status: status,
    days: parseInt(row.attend_days, 10) || 0,
    lateMin: parseInt(row.late_minutes, 10) || 0,
    bonus: bonus,
    paidAt: row.paid_at || null,
    issuedAt: row.issued_at || null
  };
}

async function sb_fetchEmployeeAttendance(empId, options) {
  options = options || {};
  if (!empId) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var fp = options.fingerprint != null ? options.fingerprint : getDeviceFingerprintForRpc();
  var token = options.token || null;
  if (!token && options.slot && typeof getDevice === 'function') {
    var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (localEmp) {
      var dev = getDevice(localEmp, options.slot);
      if (dev && dev.token) token = dev.token;
    }
  }
  try {
    var rpc = await _sbClient.rpc('saas_fetch_employee_attendance', {
      p_employee_id: empId,
      p_fingerprint: fp || null,
      p_token: token || null,
      p_limit: options.limit != null ? options.limit : 120
    });
    if (rpc.error) {
      console.warn('sb_fetchEmployeeAttendance:', rpc.error);
      return null;
    }
    var data = rpc.data;
    if (!data || data.ok !== true) return null;
    return (data.records || []).map(mapAttFromDb);
  } catch (e) {
    console.warn('sb_fetchEmployeeAttendance:', e);
    return null;
  }
}

async function sb_fetchEmployeeClientProfile(empId, options) {
  options = options || {};
  if (!empId) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var fp = options.fingerprint != null ? options.fingerprint : getDeviceFingerprintForRpc();
  var token = options.token || null;
  if (!token && options.slot && typeof getDevice === 'function') {
    var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (localEmp) {
      var dev = getDevice(localEmp, options.slot);
      if (dev && dev.token) token = dev.token;
    }
  }
  try {
    var rpc = await _sbClient.rpc('saas_fetch_employee_client_profile', {
      p_employee_id: empId,
      p_fingerprint: fp || null,
      p_token: token || null
    });
    if (rpc.error) {
      console.warn('sb_fetchEmployeeClientProfile:', rpc.error);
      return null;
    }
    return rpc.data || null;
  } catch (e) {
    console.warn('sb_fetchEmployeeClientProfile:', e);
    return null;
  }
}

async function sb_fetchEmployeeSalaryRecords(empId, options) {
  options = options || {};
  if (!empId) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var fp = options.fingerprint != null ? options.fingerprint : getDeviceFingerprintForRpc();
  var token = options.token || null;
  if (!token && options.slot && typeof getDevice === 'function') {
    var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (localEmp) {
      var dev = getDevice(localEmp, options.slot);
      if (dev && dev.token) token = dev.token;
    }
  }
  try {
    var rpc = await _sbClient.rpc('saas_fetch_employee_salary_records', {
      p_employee_id: empId,
      p_fingerprint: fp || null,
      p_token: token || null,
      p_limit: options.limit != null ? options.limit : 120
    });
    if (rpc.error) {
      console.warn('sb_fetchEmployeeSalaryRecords:', rpc.error);
      return null;
    }
    var data = rpc.data;
    if (!data || data.ok !== true) return null;
    return (data.records || []).map(mapSalaryRecordFromDb).filter(Boolean);
  } catch (e) {
    console.warn('sb_fetchEmployeeSalaryRecords:', e);
    return null;
  }
}

async function sb_updateEmployeeAvatar(empId, avatarUrl, options) {
  options = options || {};
  if (!empId || !avatarUrl) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var fp = options.fingerprint != null ? options.fingerprint : getDeviceFingerprintForRpc();
  var token = options.token || null;
  if (!token && options.slot && typeof getDevice === 'function') {
    var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (localEmp) {
      var dev = getDevice(localEmp, options.slot);
      if (dev && dev.token) token = dev.token;
    }
  }
  try {
    var rpc = await _sbClient.rpc('saas_update_employee_avatar', {
      p_employee_id: empId,
      p_avatar_url: avatarUrl,
      p_fingerprint: fp || null,
      p_token: token || null
    });
    if (rpc.error) {
      console.warn('sb_updateEmployeeAvatar:', rpc.error);
      return null;
    }
    var data = rpc.data;
    if (!data || data.ok !== true) return null;
    return data.avatar_url || avatarUrl;
  } catch (e) {
    console.warn('sb_updateEmployeeAvatar:', e);
    return null;
  }
}

async function sb_fetchEmployeeNotifications(empId, options) {
  options = options || {};
  if (!empId) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var fp = options.fingerprint != null ? options.fingerprint : getDeviceFingerprintForRpc();
  var token = options.token || null;
  if (!token && options.slot && typeof getDevice === 'function') {
    var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
    if (localEmp) {
      var dev = getDevice(localEmp, options.slot);
      if (dev && dev.token) token = dev.token;
    }
  }
  try {
    var rpc = await _sbClient.rpc('saas_fetch_employee_notifications', {
      p_employee_id: empId,
      p_fingerprint: fp || null,
      p_token: token || null,
      p_limit: options.limit != null ? options.limit : 80
    });
    if (rpc.error) {
      console.warn('sb_fetchEmployeeNotifications:', rpc.error);
      return null;
    }
    var data = rpc.data;
    if (!data || data.ok !== true) return null;
    if (Array.isArray(data.notifications)) return data.notifications;
    return []
      .concat(Array.isArray(data.table_notifications) ? data.table_notifications : [])
      .concat(Array.isArray(data.settings_notifications) ? data.settings_notifications : []);
  } catch (e) {
    console.warn('sb_fetchEmployeeNotifications:', e);
    return null;
  }
}

/** الهاتف + الإدارة: حلّ QR مع إصلاح ذاتي (011) */
async function sb_resolveQrRegistration(parsed) {
  parsed = parsed || {};
  if (!_sbClient && !(await ensureSupabaseClient())) {
    return { ok: false, error: 'no_client' };
  }
  try {
    var params = {};
    if (parsed.token) params.p_token = parsed.token;
    if (parsed.empId) params.p_employee_id = parsed.empId;
    if (parsed.slot) params.p_slot = parsed.slot;
    if (!params.p_token && !(params.p_employee_id && params.p_slot)) {
      return { ok: false, error: 'invalid_qr' };
    }
    var res = await _sbClient.rpc('saas_resolve_qr_registration', params);
    if (res.error) {
      console.warn('sb_resolveQrRegistration:', res.error);
      return { ok: false, error: res.error.message || 'rpc_error' };
    }
    var d = res.data;
    if (!d || d.ok !== true) {
      return { ok: false, error: (d && d.error) || 'not_found' };
    }
    return { ok: true, data: d, source: d.source || '' };
  } catch (e) {
    console.warn('sb_resolveQrRegistration:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_lookupDeviceRegistration(parsed) {
  var r = await sb_resolveQrRegistration(parsed);
  if (!r.ok) return null;
  return mapQrRegistrationPayload(r.data);
}

async function sb_linkDeviceByToken(token, fingerprint, ip, deviceInfo, empId, slot) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var params = {
      p_fingerprint: fingerprint,
      p_ip: ip || null,
      p_device_info: deviceInfo || {}
    };
    if (token) params.p_token = token;
    if (empId) params.p_employee_id = empId;
    if (slot) params.p_slot = slot;
    var res = await _sbClient.rpc('saas_link_device_by_token', params);
    if (res.error) {
      console.warn('sb_linkDeviceByToken:', res.error);
      return null;
    }
    return res.data || null;
  } catch (e) {
    console.warn('sb_linkDeviceByToken:', e);
    return null;
  }
}

/** تحقق أن الهاتف سيجد QR عبر saas_resolve_qr_registration */
async function sb_verifyDeviceRegistrationReady(parsed) {
  var r = await sb_resolveQrRegistration(parsed);
  return !!(r.ok && r.data && r.data.employee_id);
}

async function sb_pushDeviceTokensForEmployee(emp) {
  if (!emp || !emp.id) return { ok: false, reason: 'no_employee', pushed: 0, verified: false };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, reason: 'no_client', pushed: 0, verified: false };
  if (!(await ensureSbAuthForWrite())) return { ok: false, reason: 'no_auth', pushed: 0, verified: false };

  emp.company_id = resolveActiveCompanyId(emp);
  if (emp.dept && typeof sb_ensureDepartment === 'function') {
    var deptOk = await sb_ensureDepartment(emp.dept);
    if (!deptOk) return { ok: false, reason: 'dept_failed', pushed: 0, verified: false };
  }

  var saved = await sb_upsertEmployee(emp);
  if (!saved) {
    var err = _lastSbEmployeeSaveError || 'employee_save_failed';
    return { ok: false, reason: err, pushed: 0, verified: false };
  }

  var devices = emp.devices || [];
  var pushed = 0;
  var primary = null;
  for (var i = 0; i < devices.length; i++) {
    var dev = devices[i];
    if (!dev || !dev.slot) continue;
    var tok = (dev.token || '').trim();
    if (!tok || tok.length < 10) continue;
    if (!primary) primary = { token: tok, slot: dev.slot };
    try {
      var rpc = await _sbClient.rpc('saas_publish_employee_qr', {
        p_employee_id: emp.id,
        p_slot: dev.slot,
        p_token: tok,
        p_label: dev.label || ('الهاتف ' + dev.slot)
      });
      if (!rpc.error && rpc.data && rpc.data.ok) {
        pushed++;
        continue;
      }
      console.warn('sb_pushDeviceTokensForEmployee publish:', rpc.error || rpc.data);
    } catch (e) {
      console.warn('sb_pushDeviceTokensForEmployee:', e);
    }
  }

  var verified = false;
  if (primary) {
    verified = await sb_verifyDeviceRegistrationReady({
      token: primary.token,
      empId: emp.id,
      slot: primary.slot
    });
  }
  if (!verified && pushed === 0) {
    for (var j = 0; j < devices.length; j++) {
      var d2 = devices[j];
      if (!d2 || !d2.token) continue;
      verified = await sb_verifyDeviceRegistrationReady({
        token: d2.token,
        empId: emp.id,
        slot: d2.slot
      });
      if (verified) break;
    }
  }

  if (!verified) {
    return {
      ok: false,
      reason: pushed > 0 ? 'verify_failed' : 'no_tokens_pushed',
      pushed: pushed,
      verified: false
    };
  }
  return { ok: true, pushed: pushed, verified: true, reason: '' };
}

async function sb_deleteSalaryRecord(employeeId, opts) {
  opts = opts || {};
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (!(await ensureSbAuthForWrite())) return false;
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    return sb_rpcDeleteSalaryRecord(employeeId, opts);
  }
  var monthIso = opts.monthIso || opts.month || '';
  if (!employeeId) return false;
  try {
    var q = _sbClient.from('salary_records').delete().eq('employee_id', employeeId);
    if (monthIso) {
      q = q.eq('month_iso', monthIso);
    } else if (opts.periodPrefix) {
      q = q.like('month_iso', String(opts.periodPrefix) + '%');
    } else {
      return false;
    }
    var res = await q;
    if (res.error) {
      console.error('sb_deleteSalaryRecord:', res.error);
      return false;
    }
    return true;
  } catch (e) {
    console.error('sb_deleteSalaryRecord:', e);
    return false;
  }
}

function getDeviceFingerprintForRpc() {
  if (typeof getDeviceFingerprint === 'function') return getDeviceFingerprint();
  return '';
}

async function sb_upsertAttendanceFromDevice(rec) {
  if (!rec || !rec.empId) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var fp = getDeviceFingerprintForRpc();
  var emp = (window.employees || []).find(function (e) { return e && e.id === rec.empId; });
  var punchType = rec._punchType || null;
  var useServerPunch = punchType === 'check_in' || punchType === 'check_out';
  try {
    if (kynoUseRpcWrites() && !useServerPunch) {
      var adminRow = await sb_rpcUpsertAttendanceAdmin(rec);
      if (!adminRow) return { ok: false, error: 'admin_rpc_failed' };
      return {
        ok: true,
        id: adminRow.id,
        employee_id: adminRow.employee_id,
        check_in: adminRow.check_in,
        check_out: adminRow.check_out,
        date_iso: adminRow.date_iso,
        date_label: adminRow.date_label,
        hours: adminRow.hours,
        late: adminRow.late,
        overtime: adminRow.overtime,
        status: adminRow.status,
        server_authoritative: true
      };
    }
    var rpcParams = {
      p_employee_id: rec.empId,
      p_fingerprint: fp || null,
      p_punch_type: punchType
    };
    if (useServerPunch) {
      rpcParams.p_emp_name = rec.emp || (emp && emp.name) || null;
      rpcParams.p_dept = rec.dept || (emp && emp.dept) || null;
      if (!kynoUseRpcWrites()) {
        rpcParams.p_days = emp && emp.days != null ? emp.days : null;
        rpcParams.p_late_min = emp && emp.lateMin != null ? emp.lateMin : null;
      }
    } else {
      rpcParams.p_date_iso = rec.dateIso || null;
      rpcParams.p_date_label = rec.date || rec.dateIso || '';
      rpcParams.p_check_in = rec.ci && rec.ci !== '—' ? rec.ci : null;
      rpcParams.p_check_out = rec.co && rec.co !== '—' ? rec.co : null;
      rpcParams.p_hours = rec.hrs && rec.hrs !== '—' ? rec.hrs : null;
      rpcParams.p_late = rec.late && rec.late !== '—' ? rec.late : null;
      rpcParams.p_overtime = rec.ot && rec.ot !== '—' ? rec.ot : null;
      rpcParams.p_status = rec.status || 'طبيعي';
      rpcParams.p_emp_name = rec.emp || (emp && emp.name) || null;
      rpcParams.p_dept = rec.dept || (emp && emp.dept) || null;
      rpcParams.p_days = emp && emp.days != null ? emp.days : null;
      rpcParams.p_late_min = emp && emp.lateMin != null ? emp.lateMin : null;
    }
    var rpcName = (kynoUseRpcWrites() && useServerPunch)
      ? 'saas_upsert_attendance_employee'
      : 'saas_upsert_attendance_by_device';
    var rpc = await _sbClient.rpc(rpcName, rpcParams);
    if (rpc.error) {
      console.warn('sb_upsertAttendanceFromDevice:', rpc.error);
      return null;
    }
    var d = rpc.data;
    if (!d || d.ok !== true) {
      console.warn('sb_upsertAttendanceFromDevice:', d && d.error, d && d.detail);
      return { ok: false, error: d && d.error, detail: d && d.detail };
    }
    return {
      ok: true,
      id: d.attendance_id,
      employee_id: d.employee_id,
      check_in: d.check_in,
      check_out: d.check_out,
      date_iso: d.date_iso,
      date_label: d.date_label,
      hours: d.hours,
      late: d.late,
      overtime: d.overtime,
      status: d.status,
      server_authoritative: d.server_authoritative === true
    };
  } catch (e) {
    console.warn('sb_upsertAttendanceFromDevice:', e);
    return null;
  }
}

async function sb_patchEmployeeStatsFromDevice(emp) {
  if (!emp || !emp.id) return false;
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  var fp = getDeviceFingerprintForRpc();
  var todayIso = typeof todayIsoDate === 'function' ? todayIsoDate() : new Date().toISOString().slice(0, 10);
  var todayLabel = typeof todayAttDate === 'function' ? todayAttDate() : todayIso;
  try {
    var rpc = await _sbClient.rpc('saas_upsert_attendance_by_device', {
      p_employee_id: emp.id,
      p_fingerprint: fp || null,
      p_date_iso: todayIso,
      p_date_label: todayLabel,
      p_days: emp.days != null ? emp.days : null,
      p_late_min: emp.lateMin != null ? emp.lateMin : null
    });
    if (rpc.error || !rpc.data || rpc.data.ok !== true) return false;
    return true;
  } catch (e) {
    console.warn('sb_patchEmployeeStatsFromDevice:', e);
    return false;
  }
}

async function sb_deleteEmployee(id) {
  _lastSbEmployeeDeleteError = '';
  if (!_sbClient && !(await ensureSupabaseClient())) {
    _lastSbEmployeeDeleteError = 'no_client';
    return false;
  }
  if (!(await ensureSbAuthForWrite())) {
    _lastSbEmployeeDeleteError = 'no_auth';
    return false;
  }
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    return sb_rpcDeleteEmployee(id);
  }
  const { error } = await _sbClient.from('employees').delete().eq('id', id);
  if (error) {
    _lastSbEmployeeDeleteError = error.message || String(error);
    console.error('sb_deleteEmployee:', error);
    return false;
  }
  return true;
}

// ======= Attendance =======
async function sb_getAttendance(filters) {
  filters = filters || {};
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForRead())) return null;

  if (kynoUseRpcWrites() || isHostedSupabase()) {
    try {
      var limit = filters.limit || getPageSize();
      var offset = filters.offset || 0;
      var rpc = await _sbClient.rpc('saas_list_attendance', {
        p_limit: limit,
        p_offset: offset,
        p_employee_id: filters.employeeId || null,
        p_date_from: filters.dateFrom || null,
        p_date_to: filters.dateTo || null
      });
      if (rpc.error) {
        console.error('sb_getAttendance rpc:', rpc.error);
        return null;
      }
      var payload = rpc.data;
      if (typeof payload === 'string') {
        try { payload = JSON.parse(payload); } catch (e) { payload = null; }
      }
      if (!payload || payload.ok !== true || !Array.isArray(payload.data)) return null;
      var rows = payload.data;
      if (filters.status) {
        rows = rows.filter(function (r) { return r.status === filters.status; });
      }
      return rows.map(mapAttFromDb);
    } catch (e) {
      console.error('sb_getAttendance rpc:', e);
      return null;
    }
  }

  var companyId = null;
  if (typeof AuthApi !== 'undefined' && AuthApi.getCompanyId) {
    var jwtCid = AuthApi.getCompanyId();
    if (jwtCid !== undefined) companyId = jwtCid;
  }
  var limit = filters.limit || getPageSize();
  var offset = filters.offset || 0;
  var end = offset + limit - 1;
  var q = _sbClient.from('attendance').select(ATTENDANCE_SELECT).order('date_iso', { ascending: false });
  if (companyId) q = q.eq('company_id', companyId);
  if (filters.employeeId) q = q.eq('employee_id', filters.employeeId);
  if (filters.dateFrom) q = q.gte('date_iso', filters.dateFrom);
  if (filters.dateTo) q = q.lte('date_iso', filters.dateTo);
  if (filters.status) q = q.eq('status', filters.status);
  q = q.range(offset, end);
  const { data, error } = await q;
  if (error) { console.error('sb_getAttendance:', error); return null; }
  return data.map(mapAttFromDb);
}

async function sb_upsertAttendance(rec) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!window.__basmaBulkSyncRunning && typeof AuthApi !== 'undefined' && AuthApi.refreshJwtContext) {
    await AuthApi.refreshJwtContext();
  }
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    if (!rec || !rec.empId || !rec.dateIso) {
      console.warn('sb_upsertAttendance: missing empId/dateIso for RPC admin path');
      return null;
    }
    return sb_rpcUpsertAttendanceAdmin(rec);
  }
  if (rec && rec.empId && !rec.company_id) {
    var empMatch = (window.employees || []).find(function (e) { return e.id === rec.empId; });
    if (empMatch && empMatch.company_id) rec.company_id = empMatch.company_id;
  }
  rec.company_id = resolveActiveCompanyId(rec);
  const row = mapAttToDb(rec);
  if (!row.company_id) {
    console.warn('sb_upsertAttendance: missing company_id');
    return null;
  }
  if (!row.date_iso) {
    console.warn('sb_upsertAttendance: missing date_iso');
    return null;
  }
  const { data, error } = await _sbClient
    .from('attendance')
    .upsert(row, { onConflict: 'employee_id,date_iso' })
    .select().single();
  if (error) {
    if (isSbPermissionDenied(error)) {
      markKynoLockdownDetected();
      if (rec && rec.empId && rec.dateIso) return sb_rpcUpsertAttendanceAdmin(rec);
    }
    console.error('sb_upsertAttendance:', error);
    return null;
  }
  return data;
}

async function sb_deleteAttendance(rec) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    return sb_rpcDeleteAttendance(rec);
  }
  try {
    if (rec && rec.id) {
      const { error } = await _sbClient.from('attendance').delete().eq('id', rec.id);
      if (error) { console.error('sb_deleteAttendance:', error); return false; }
      return true;
    }
    if (rec && rec.empId && rec.dateIso) {
      const { error } = await _sbClient.from('attendance').delete()
        .eq('employee_id', rec.empId).eq('date_iso', rec.dateIso);
      if (error) { console.error('sb_deleteAttendance:', error); return false; }
      return true;
    }
    return false;
  } catch (e) {
    console.error('sb_deleteAttendance exception:', e);
    return false;
  }
}

// ======= Salary Records =======
async function sb_getSalaryRecords(employeeId) {
  if (!_sbClient) return null;
  let q = _sbClient.from('salary_records').select('*').order('month_iso', { ascending: false });
  if (employeeId) q = q.eq('employee_id', employeeId);
  const { data, error } = await q;
  if (error) { console.error('sb_getSalaryRecords:', error); return null; }
  return data;
}

async function sb_issueSalary(employeeId, monthIso, salaryData) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    return sb_rpcIssueSalary(employeeId, monthIso);
  }
  var empRow = (window.employees || []).find(function (e) { return e && e.id === employeeId; });
  var companyId = empRow && empRow.company_id ? empRow.company_id : resolveActiveCompanyId(empRow);
  if (!companyId) {
    console.warn('sb_issueSalary: missing company_id');
    return null;
  }
  const { data, error } = await _sbClient
    .from('salary_records')
    .upsert({
      employee_id:     employeeId,
      company_id:      companyId,
      month_iso:       monthIso,
      month_label:     salaryData.monthLabel,
      base_salary:     salaryData.baseSalary,
      attend_days:     salaryData.attendDays,
      late_minutes:    salaryData.totalLateMin,
      late_deduct:     salaryData.lateDeduct,
      overtime_amount: salaryData.ot,
      bonus:           salaryData.bonus,
      total_deduct:    salaryData.totalDeduct,
      net_salary:      salaryData.final,
      status:          salaryData.status || 'مُصدر',
      paid_at:         salaryData.status === 'مدفوع' ? (salaryData.paidAt || new Date().toISOString()) : null,
      issued_at:       new Date().toISOString()
    }, { onConflict: 'employee_id,month_iso' })
    .select().single();
  if (error) { console.error('sb_issueSalary:', error); return null; }
  return data;
}

async function sb_upsertSalaryRecord(employeeId, rec) {
  if (!employeeId || !rec) return null;
  var monthIso = rec.monthIso || rec.month_iso || null;
  if (!monthIso) return null;
  var wantedStatus = rec.status || rec.salStatus || 'مُصدر';
  var saved = await sb_issueSalary(employeeId, monthIso, {
    monthLabel: rec.month || rec.month_label || monthIso,
    baseSalary: rec.base != null ? rec.base : rec.base_salary,
    attendDays: rec.days != null ? rec.days : rec.attend_days,
    totalLateMin: rec.lateMin != null ? rec.lateMin : rec.late_minutes,
    lateDeduct: rec.lateDeduct != null ? rec.lateDeduct : rec.late_deduct,
    ot: rec.ot != null ? rec.ot : rec.overtime_amount,
    bonus: rec.bonus,
    totalDeduct: rec.deduct != null ? rec.deduct : rec.total_deduct,
    final: rec.final != null ? rec.final : rec.net_salary,
    status: wantedStatus,
    paidAt: rec.paidAt || rec.paid_at || null
  });
  if (saved && wantedStatus && saved.status !== wantedStatus) {
    if (typeof sb_updateSalaryRecordStatus === 'function') {
      var updated = await sb_updateSalaryRecordStatus(employeeId, monthIso, wantedStatus, rec.paidAt || rec.paid_at || null);
      if (updated) return updated;
    }
    if (wantedStatus === 'مدفوع' && typeof sb_markSalaryRecordPaid === 'function') {
      var paid = await sb_markSalaryRecordPaid(employeeId, monthIso);
      if (paid) return paid;
    }
  }
  return saved;
}

// ======= Settings (مفاتيح company:{id}:… مطلوبة لـ RLS 004) =======
function settingsTenantPrefix(companyId) {
  var prefix = resolveSettingsTenantPrefix(companyId);
  if (!prefix) {
    throw new Error('NO_COMPANY_CONTEXT');
  }
  return prefix;
}

function settingsDbKey(shortKey, companyId) {
  var k = String(shortKey || '');
  if (k.indexOf('global:') === 0 || k.indexOf('company:') === 0) return k;
  return settingsTenantPrefix(companyId) + k;
}

function settingsShortKey(dbKey, companyId) {
  var k = String(dbKey || '');
  var prefix = resolveSettingsTenantPrefix(companyId);
  if (prefix && k.indexOf(prefix) === 0) return k.slice(prefix.length);
  if (/^company:\d+:/.test(k)) return null;
  if (k.indexOf('global:') === 0) return k.slice('global:'.length);
  return k;
}

async function sb_getSettings() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForRead())) return null;
  var cid = null;
  try { cid = resolveActiveCompanyId(); } catch (e) { cid = null; }
  var isSuper = isSuperAdminSession();
  if (!cid && !isSuper) return {};
  var prefix = cid ? ('company:' + cid + ':') : null;
  var rows = [];
  try {
    if (prefix) {
      var tenantRes = await _sbClient.from('app_settings')
        .select('key, value')
        .like('key', prefix + '%');
      if (tenantRes.error) {
        console.error('sb_getSettings tenant:', tenantRes.error);
        return null;
      }
      rows = rows.concat(tenantRes.data || []);
    }
    if (isSuper) {
      var globalRes = await _sbClient.from('app_settings')
        .select('key, value')
        .like('key', 'global:%');
      if (globalRes.error) {
        console.error('sb_getSettings global:', globalRes.error);
        if (!rows.length) return null;
      } else {
        rows = rows.concat(globalRes.data || []);
      }
    }
  } catch (e) {
    console.error('sb_getSettings:', e);
    return null;
  }
  const settings = {};
  if (!cid && !isSuper) return settings;
  (rows || []).forEach(function (r) {
    var key = String(r.key || '');
    if (!isSuper) {
      if (key.indexOf('global:') === 0) return;
      if (!prefix || key.indexOf(prefix) !== 0) return;
    } else if (prefix && key.indexOf('global:') !== 0 && key.indexOf(prefix) !== 0 && /^company:\d+:/.test(key)) {
      return;
    }
    var shortKey = settingsShortKey(key, cid);
    if (!shortKey) return;
    var isTenantKey = prefix && key.indexOf(prefix) === 0;
    if (settings[shortKey] !== undefined && !isTenantKey) return;
    settings[shortKey] = r.value;
  });
  return settings;
}

async function sb_fetchTenantSettingKeys(shortKeys) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var cid = null;
  try { cid = resolveActiveCompanyId(); } catch (e) { cid = null; }
  if (!cid || !Array.isArray(shortKeys) || !shortKeys.length) return null;
  var prefix = 'company:' + cid + ':';
  var dbKeys = shortKeys.map(function (k) { return prefix + String(k); });
  try {
    var res = await _sbClient.from('app_settings').select('key, value').in('key', dbKeys);
    if (res.error) {
      console.error('sb_fetchTenantSettingKeys:', res.error);
      return null;
    }
    var out = {};
    (res.data || []).forEach(function (r) {
      var short = settingsShortKey(r.key, cid);
      if (short) out[short] = r.value;
    });
    return out;
  } catch (e) {
    console.warn('sb_fetchTenantSettingKeys:', e);
    return null;
  }
}

/** تطبيق إعدادات السحابة — لا تستبدل محلياً بعد حفظ حديث */
function applyRemoteAppSettings(settings, options) {
  options = options || {};
  if (!settings) return;
  var isSuper = typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.role === 'super_admin';
  var preferLocal = !options.forceRemote && shouldPreferLocalAppSettings();
  var gpsChanged = false;

  // GPS مشترك بين كل مستخدمي الشركة — يُحدَّث دائماً من السحابة
  if (settings.gps_name != null) window.appSettings.gpsName = settings.gps_name;
  if (settings.gps_lat != null && String(settings.gps_lat).trim() !== '') {
    var nextLat = String(settings.gps_lat).trim();
    if (window.appSettings.gpsLat !== nextLat) gpsChanged = true;
    window.appSettings.gpsLat = nextLat;
  }
  if (settings.gps_lng != null && String(settings.gps_lng).trim() !== '') {
    var nextLng = String(settings.gps_lng).trim();
    if (window.appSettings.gpsLng !== nextLng) gpsChanged = true;
    window.appSettings.gpsLng = nextLng;
  }
  if (settings.gps_range != null && String(settings.gps_range).trim() !== '') {
    var nextRange = parseInt(settings.gps_range, 10) || window.appSettings.gpsRange;
    if (window.appSettings.gpsRange !== nextRange) gpsChanged = true;
    window.appSettings.gpsRange = nextRange;
  }

  // إعدادات مشتركة — تُسحب دائماً (مثل GPS)
  if (settings.month_days != null && String(settings.month_days).trim() !== '') {
    window.appSettings.monthDays = clampMonthDays(settings.month_days);
  }
  if (settings.clock_format != null && String(settings.clock_format).trim() !== '') {
    var cf = String(settings.clock_format).trim() === '24' ? '24' : '12';
    if (window.appSettings.clockFormat !== cf) {
      window.appSettings.clockFormat = cf;
      if (typeof BasmaTime !== 'undefined' && BasmaTime.migrateAllTimesToClockFormat) {
        BasmaTime.migrateAllTimesToClockFormat(cf);
      }
    }
  }

  if (!preferLocal) {
    if (settings.company_name != null && settings.company_name !== '') {
      window.appSettings.companyName = settings.company_name;
    }
    if (settings.currency != null && settings.currency !== '') {
      window.appSettings.currency = settings.currency;
    }
    if (settings.timezone != null && settings.timezone !== '') {
      window.appSettings.timezone = settings.timezone;
    }
    if (settings.work_start) window.appSettings.workStart = settings.work_start;
    if (settings.work_end) window.appSettings.workEnd = settings.work_end;
    if (settings.late_threshold) {
      window.appSettings.lateThreshold = parseInt(settings.late_threshold, 10);
    }
    if (settings.late_deduct_rate) {
      window.appSettings.lateDeductRate = parseInt(settings.late_deduct_rate, 10);
    }
    if (settings.salary_deleted_map) {
      try { window.appSettings.salaryDeletedMap = JSON.parse(settings.salary_deleted_map) || {}; } catch (e) {}
    }
    if (settings.finance_items) {
      try { window.appSettings.financeItems = JSON.parse(settings.finance_items) || []; } catch (e) {}
    }
  }
  if (!isSuper && settings.activity_log) {
    try {
      window.appSettings.activityLog = mergeActivityLogRemote(
        window.appSettings.activityLog,
        JSON.parse(settings.activity_log) || []
      );
    } catch (e) {}
  } else if (isSuper && typeof filterNotificationsForCurrentTenant === 'function') {
    filterNotificationsForCurrentTenant();
  }
  if (!isSuper && settings.employee_notifications) {
    try {
      var remoteEmpNotifs = JSON.parse(settings.employee_notifications) || [];
      if (shouldPreferLocalNotifications()) {
        var localEmpNotifs = window.appSettings.employeeNotifications || [];
        var localEmpIds = {};
        localEmpNotifs.forEach(function (n) { if (n && n.id) localEmpIds[n.id] = true; });
        remoteEmpNotifs.forEach(function (n) {
          if (!n || !n.id || localEmpIds[n.id]) return;
          localEmpNotifs.unshift(n);
        });
        window.appSettings.employeeNotifications = mergeEmployeeNotificationsRemote(localEmpNotifs, []);
      } else {
        window.appSettings.employeeNotifications = mergeEmployeeNotificationsRemote(
          window.appSettings.employeeNotifications,
          remoteEmpNotifs
        );
      }
    } catch (e) {}
  }
  if (gpsChanged) {
    if (typeof syncSettingsUi === 'function') syncSettingsUi();
    if (typeof previewGpsMap === 'function') previewGpsMap();
  }
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
  if (document.getElementById('page-notifications') &&
      document.getElementById('page-notifications').classList.contains('active') &&
      typeof buildNotifications === 'function') {
    buildNotifications();
  }
  // أقسام ووظائف مشتركة بين كل مستخدمي الشركة — تُسحب دائماً (مثل GPS)
  if (settings.departments_json) {
    try {
      var remoteDepts = JSON.parse(settings.departments_json) || [];
      window.appSettings.departments = dedupeOrgNames(remoteDepts);
    } catch (e) {}
  }
  if (settings.jobs_json) {
    try {
      var remoteJobs = JSON.parse(settings.jobs_json) || [];
      window.appSettings.jobs = dedupeOrgNames(remoteJobs);
    } catch (e) {}
  }
  if (!isSuper && !preferLocal) {
    if ((!settings.company_name || settings.company_name === '') && saasCurrentUser && saasCurrentUser.company_name) {
      window.appSettings.companyName = saasCurrentUser.company_name;
    }
  }
  if (!isSuper) {
    if (!settings.departments_json && (!window.appSettings.departments || !window.appSettings.departments.length)) {
      window.appSettings.departments = [];
    }
    if (!settings.jobs_json && (!window.appSettings.jobs || !window.appSettings.jobs.length)) {
      window.appSettings.jobs = [];
    }
  }
}

function canMutateOrgLists() {
  return typeof hasActionPermission === 'function' && hasActionPermission('org', 'edit');
}

/** قبل الرفع: لا يستبدل مستخدم بلا صلاحية org قوائم السحابة بنسخته المحلية القديمة */
async function mergeRemoteOrgListsBeforeSave() {
  if (typeof sb_getSettings !== 'function') return;
  if (canMutateOrgLists() && shouldPreferLocalAppSettings()) return;
  try {
    var remote = await sb_getSettings();
    if (!remote) return;
    var remoteDepts = [];
    var remoteJobs = [];
    if (remote.departments_json) {
      try { remoteDepts = JSON.parse(remote.departments_json) || []; } catch (e) { /* ignore */ }
    }
    if (remote.jobs_json) {
      try { remoteJobs = JSON.parse(remote.jobs_json) || []; } catch (e) { /* ignore */ }
    }
    if (typeof sb_getDepartmentNames === 'function') {
      var tableDepts = await sb_getDepartmentNames();
      if (tableDepts && tableDepts.length) {
        remoteDepts = dedupeOrgNames(remoteDepts.concat(tableDepts));
      }
    }
    if (canMutateOrgLists()) {
      window.appSettings.departments = mergeOrgStringLists(window.appSettings.departments, remoteDepts);
      window.appSettings.jobs = mergeOrgStringLists(window.appSettings.jobs, remoteJobs);
    } else {
      window.appSettings.departments = dedupeOrgNames(remoteDepts);
      window.appSettings.jobs = dedupeOrgNames(remoteJobs);
    }
  } catch (e) {
    console.warn('mergeRemoteOrgListsBeforeSave:', e);
  }
}

function dedupeOrgNames(list) {
  var out = [];
  var seen = {};
  (list || []).forEach(function (item) {
    var v = String(item || '').replace(/\s+/g, ' ').trim();
    if (!v || seen[v]) return;
    seen[v] = true;
    out.push(v);
  });
  return out;
}

function mergeOrgStringLists(localArr, remoteArr) {
  var out = Array.isArray(localArr) ? localArr.slice() : [];
  var seen = {};
  out.forEach(function (item) {
    var k = String(item || '').trim();
    if (k) seen[k] = true;
  });
  (remoteArr || []).forEach(function (item) {
    var v = String(item || '').trim();
    if (v && !seen[v]) {
      out.push(v);
      seen[v] = true;
    }
  });
  return out;
}

async function sb_getDepartmentNames() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var companyId = resolveActiveCompanyId();
    var q = _sbClient.from('departments').select('name').order('name');
    if (companyId) q = q.eq('company_id', companyId);
    var res = await q;
    if (res.error) {
      console.warn('sb_getDepartmentNames:', res.error);
      return null;
    }
    return (res.data || []).map(function (r) { return r.name; }).filter(Boolean);
  } catch (e) {
    console.warn('sb_getDepartmentNames:', e);
    return null;
  }
}

async function sb_saveSettings(settingsObj, companyIdOverride) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (!(await ensureSbAuthForWrite())) {
    if (typeof window !== 'undefined' && (window.__basmaLoggingOut || window.__basmaSilentSettingsSave)) return false;
    console.warn('sb_saveSettings: no JWT — أعد تسجيل الدخول');
    return false;
  }
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    return sb_rpcSaveSettings(settingsObj || {});
  }
  var cid = companyIdOverride != null ? parseInt(companyIdOverride, 10) : resolveActiveCompanyId();
  const rows = Object.entries(settingsObj).map(function (entry) {
    return {
      key: settingsDbKey(entry[0], cid),
      value: String(entry[1]),
      updated_at: new Date().toISOString()
    };
  });
  const { error } = await _sbClient
    .from('app_settings')
    .upsert(rows, { onConflict: 'key' });
  if (error) {
    if (isSbPermissionDenied(error)) {
      markKynoLockdownDetected();
      return sb_rpcSaveSettings(settingsObj || {});
    }
    console.error('sb_saveSettings:', error);
    return false;
  }
  return true;
}

function sb_buildDefaultSettingsPayload(companyName) {
  return {
    company_name: companyName || '',
    currency: 'دينار عراقي (IQD)',
    timezone: 'Asia/Baghdad (GMT+3)',
    work_start: '08:00',
    work_end: '17:00',
    late_threshold: 15,
    late_deduct_rate: 700,
    month_days: '30',
    clock_format: '12',
    departments_json: '[]',
    jobs_json: '[]',
    salary_deleted_map: '{}',
    finance_items: '[]',
    activity_log: '[]',
    employee_notifications: '[]',
    gps_name: '',
    gps_lat: '',
    gps_lng: '',
    gps_range: '100'
  };
}

async function sb_seedCompanyDefaultSettings(companyId, companyName) {
  if (!companyId) return false;
  return sb_saveSettings(sb_buildDefaultSettingsPayload(companyName), companyId);
}

// ======= Platform globals (super admin → all tenants) =======
function _parsePlatformAnnouncements(raw) {
  if (raw == null) return [];
  try {
    if (Array.isArray(raw)) return raw.filter(function (a) { return a && a.message; });
    var list = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (Array.isArray(list)) return list.filter(function (a) { return a && a.message; });
    return [];
  } catch (e) {
    return [];
  }
}

function _loadPlatformAnnouncementsCache() {
  try {
    var raw = localStorage.getItem('basma_platform_announcements_cache');
    if (!raw) return null;
    var list = _parsePlatformAnnouncements(raw);
    return list.length ? list : null;
  } catch (e) {
    return null;
  }
}

function _savePlatformAnnouncementsCache(list) {
  try {
    localStorage.setItem('basma_platform_announcements_cache', JSON.stringify(list || []));
    localStorage.setItem('basma_platform_announcements_cache_at', String(Date.now()));
  } catch (e) {}
}

function hydratePlatformAnnouncementsFromCache() {
  var cached = _loadPlatformAnnouncementsCache();
  if (!cached || !cached.length) return;
  window.platformSettings = window.platformSettings || {};
  window.platformSettings.announcements = cached;
  if (typeof renderPlatformAnnouncementsRail === 'function') renderPlatformAnnouncementsRail();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
}

function cleanupDismissedAnnouncements(prevList, nextList) {
  try {
    var nextIds = {};
    (nextList || []).forEach(function (a) { if (a && a.id) nextIds[a.id] = a.updatedAt || a.createdAt || ''; });
    (prevList || []).forEach(function (a) {
      if (!a || !a.id) return;
      if (!nextIds[a.id]) {
        sessionStorage.removeItem('basma_platform_ann_dismiss_' + a.id);
        localStorage.removeItem('basma_platform_ann_dismiss_' + a.id);
      }
    });
  } catch (e) {}
}

function applyPlatformGlobals(globals) {
  if (!globals) return;
  window.platformSettings = window.platformSettings || {};
  var prev = window.platformSettings.announcements || [];
  if (globals.supportWhatsApp != null && String(globals.supportWhatsApp).trim()) {
    window.platformSettings.supportWhatsApp = String(globals.supportWhatsApp).trim();
    try { localStorage.setItem('platform_support_whatsapp', window.platformSettings.supportWhatsApp); } catch (e) {}
  }
  if (globals.supportWhatsAppTeam != null && String(globals.supportWhatsAppTeam).trim()) {
    window.platformSettings.supportWhatsAppTeam = String(globals.supportWhatsAppTeam).trim();
    try { localStorage.setItem('platform_support_whatsapp_team', window.platformSettings.supportWhatsAppTeam); } catch (e) {}
  }
  if (Array.isArray(globals.announcements)) {
    window.platformSettings.announcements = globals.announcements;
    _savePlatformAnnouncementsCache(globals.announcements);
    cleanupDismissedAnnouncements(prev, globals.announcements);
  }
  if (typeof renderPlatformAnnouncementsRail === 'function') renderPlatformAnnouncementsRail();
  if (typeof syncCompanySupportUi === 'function') syncCompanySupportUi();
  if (typeof updateNotifBadges === 'function') updateNotifBadges();
}

async function sb_getGlobalPlatformSettings() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var q = _sbClient.from('app_settings').select('key, value').in('key', [
      'global:support_whatsapp',
      'global:support_whatsapp_team',
      'global:platform_announcements'
    ]);
    var res = await q;
    if (res.error) {
      console.error('sb_getGlobalPlatformSettings:', res.error);
      return null;
    }
    var out = { supportWhatsApp: '07733344940', supportWhatsAppTeam: '07733344940', announcements: [] };
    (res.data || []).forEach(function (r) {
      if (r.key === 'global:support_whatsapp') out.supportWhatsApp = r.value || out.supportWhatsApp;
      if (r.key === 'global:support_whatsapp_team') out.supportWhatsAppTeam = r.value || out.supportWhatsAppTeam;
      if (r.key === 'global:platform_announcements') out.announcements = _parsePlatformAnnouncements(r.value);
    });
    if (!out.supportWhatsAppTeam) out.supportWhatsAppTeam = out.supportWhatsApp;
    return out;
  } catch (e) {
    console.warn('sb_getGlobalPlatformSettings:', e);
    return null;
  }
}

async function sb_fetchPublicSupportWhatsApp() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    return await kynoWithRetry(async function () {
      var rpcRes = await _sbClient.rpc('get_platform_support_whatsapp');
      if (!rpcRes.error && rpcRes.data) return String(rpcRes.data).trim();
      return null;
    }, { maxRetries: 2 });
  } catch (e) {
    console.warn('sb_fetchPublicSupportWhatsApp:', e);
  }
  return null;
}

async function sb_fetchPlatformAnnouncementsRemote() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var annRpc = await _sbClient.rpc('get_platform_announcements');
    if (!annRpc.error && annRpc.data != null) {
      return _parsePlatformAnnouncements(annRpc.data);
    }
  } catch (e) {
    console.warn('get_platform_announcements:', e);
  }
  try {
    var fullRpc = await _sbClient.rpc('get_platform_public_settings');
    if (!fullRpc.error && fullRpc.data) {
      var d = fullRpc.data;
      if (typeof d === 'string') {
        try { d = JSON.parse(d); } catch (e) { d = null; }
      }
      if (d && d.announcements != null) return _parsePlatformAnnouncements(d.announcements);
    }
  } catch (e) {
    console.warn('get_platform_public_settings announcements:', e);
  }
  return null;
}

function sb_subscriptionDaysLeft(subOrEndDate) {
  var end = subOrEndDate && typeof subOrEndDate === 'object' ? subOrEndDate.end_date : subOrEndDate;
  return _subDaysLeftFromEnd(end);
}

async function sb_loadPlatformGlobals() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  // إعدادات عامة — لا حاجة لـ getUser() على الشبكة (يمنع أخطاء ERR_CONNECTION_CLOSED عند polling)
  var globals = null;
  var announcements = await sb_fetchPlatformAnnouncementsRemote();
  try {
    var rpcRes = await _sbClient.rpc('get_platform_public_settings');
    if (!rpcRes.error && rpcRes.data) {
      var d = rpcRes.data;
      if (typeof d === 'string') {
        try { d = JSON.parse(d); } catch (e) { d = null; }
      }
      if (d && typeof d === 'object') {
        globals = {
          supportWhatsApp: d.support_whatsapp || d.supportWhatsApp || '07733344940',
          supportWhatsAppTeam: d.support_whatsapp_team || d.supportWhatsAppTeam || '',
          announcements: announcements != null ? announcements : _parsePlatformAnnouncements(d.announcements)
        };
      }
    } else if (rpcRes.error) {
      console.warn('get_platform_public_settings:', rpcRes.error.message || rpcRes.error);
    }
  } catch (e) {
    console.warn('sb_loadPlatformGlobals rpc:', e);
  }
  if (!globals) globals = await sb_getGlobalPlatformSettings();
  if (globals && announcements != null) globals.announcements = announcements;
  if (globals) {
    applyPlatformGlobals(globals);
  } else if (announcements != null) {
    applyPlatformGlobals({ announcements: announcements });
  }
  return globals;
}

function startPlatformGlobalsPolling() {
  if (window._platformGlobalsPollTimer) clearInterval(window._platformGlobalsPollTimer);
  window._platformGlobalsPollTimer = setInterval(function () {
    if (typeof currentUser === 'undefined' || currentUser !== 'admin') return;
    if (!saasCurrentUser || saasCurrentUser.role === 'super_admin' || !saasCurrentUser.company_id) return;
    if (document.hidden) return;
    if (typeof navigator !== 'undefined' && navigator.onLine === false) return;
    if (typeof sb_loadPlatformGlobals === 'function') {
      sb_loadPlatformGlobals().catch(function (e) { console.warn('platform poll:', e); });
    }
  }, 30000);
}

if (typeof window !== 'undefined') {
  window.applyPlatformGlobals = applyPlatformGlobals;
  window.sb_loadPlatformGlobals = sb_loadPlatformGlobals;
  window.sb_savePlatformGlobals = sb_savePlatformGlobals;
  window.sb_fetchPublicSupportWhatsApp = sb_fetchPublicSupportWhatsApp;
  window.hydratePlatformAnnouncementsFromCache = hydratePlatformAnnouncementsFromCache;
  window.sb_subscriptionDaysLeft = sb_subscriptionDaysLeft;
  window.sb_calcSubscriptionDurationDays = sb_calcSubscriptionDurationDays;
  window.startPlatformGlobalsPolling = startPlatformGlobalsPolling;
  window.sb_fetchPlatformAnnouncementsRemote = sb_fetchPlatformAnnouncementsRemote;
  window._savePlatformAnnouncementsCache = _savePlatformAnnouncementsCache;
}

async function sb_savePlatformGlobals(payload) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'السحابة غير جاهزة' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'أعد تسجيل الدخول' };
  var isSuper = typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (!isSuper) return { ok: false, error: 'للسوبر أدمن فقط' };
  payload = payload || {};
  var rows = [];
  if (payload.supportWhatsApp != null) {
    rows.push({
      key: 'global:support_whatsapp',
      value: String(payload.supportWhatsApp).trim(),
      updated_at: new Date().toISOString()
    });
  }
  if (payload.supportWhatsAppTeam != null) {
    rows.push({
      key: 'global:support_whatsapp_team',
      value: String(payload.supportWhatsAppTeam).trim(),
      updated_at: new Date().toISOString()
    });
  }
  if (payload.announcements != null) {
    rows.push({
      key: 'global:platform_announcements',
      value: JSON.stringify(payload.announcements || []),
      updated_at: new Date().toISOString()
    });
  }
  if (!rows.length) return { ok: false, error: 'لا توجد بيانات للحفظ' };
  if (kynoUseRpcWrites() || isHostedSupabase()) {
    return sb_rpcSavePlatformGlobals(payload);
  }
  var res = await _sbClient.from('app_settings').upsert(rows, { onConflict: 'key' });
  if (res.error) {
    if (isSbPermissionDenied(res.error)) {
      markKynoLockdownDetected();
      return sb_rpcSavePlatformGlobals(payload);
    }
    return { ok: false, error: res.error.message || String(res.error) };
  }
  await sb_loadPlatformGlobals();
  return { ok: true };
}

// ======= Departments & IDs =======
async function sb_getNextEmployeeId() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  // معرّف الموظف عالمي في الجدول — لا يُقيَّد بشركة واحدة
  var q = _sbClient.from('employees').select('id').order('id', { ascending: false }).limit(1);
  const { data, error } = await q;
  if (error) { console.warn('sb_getNextEmployeeId:', error); return null; }
  if (!data || !data.length) return 1;
  return (parseInt(data[0].id, 10) || 0) + 1;
}

async function sb_ensureDepartment(name) {
  if (!name) return true;
  return sb_ensureDepartments([name]);
}

async function sb_ensureDepartments(names) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  var list = (names || []).map(function (n) { return String(n || '').trim(); }).filter(Boolean);
  if (!list.length) return true;
  var authed = await ensureSbAuthForWrite();
  if (!authed) {
    console.warn('sb_ensureDepartments: no JWT — أعد تسجيل الدخول من لوحة الإدارة');
    return false;
  }
  try {
    for (var i = 0; i < list.length; i++) {
      var deptName = list[i];
      var rpcRes = await _sbClient.rpc('saas_ensure_department', { p_name: deptName });
      if (!rpcRes.error && rpcRes.data && rpcRes.data.ok === true) continue;
      if (rpcRes.error && /Could not find the function|42883|PGRST202/i.test(rpcRes.error.message || '')) {
        if (kynoUseRpcWrites() || isHostedSupabase()) {
          console.warn('sb_ensureDepartment: RPC missing in lockdown mode');
          return false;
        }
        var companyId = resolveActiveCompanyId();
        var { data: existing, error: selErr } = await _sbClient
          .from('departments')
          .select('name')
          .eq('name', deptName)
          .maybeSingle();
        if (!selErr && existing) continue;
        var { error: insErr } = await _sbClient
          .from('departments')
          .upsert({ name: deptName, company_id: companyId }, { onConflict: 'name', ignoreDuplicates: true });
        if (!insErr) continue;
        console.warn('sb_ensureDepartment fallback:', insErr);
        return false;
      }
      if (rpcRes.error) {
        console.warn('sb_ensureDepartment rpc:', rpcRes.error);
        return false;
      }
      if (rpcRes.data && rpcRes.data.ok === false) {
        console.warn('sb_ensureDepartment:', rpcRes.data.error);
        return false;
      }
    }
    return true;
  } catch (e) {
    console.warn('sb_ensureDepartments:', e);
    return false;
  }
}

async function sb_deleteDepartment(name) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };
  var n = String(name || '').replace(/\s+/g, ' ').trim();
  if (!n) return { ok: false, error: 'invalid_name' };
  try {
    var rpcRes = await _sbClient.rpc('saas_delete_department', { p_name: n });
    if (!rpcRes.error && rpcRes.data && rpcRes.data.ok === true) return { ok: true, data: rpcRes.data };
    if (rpcRes.error && /Could not find the function|42883|PGRST202/i.test(rpcRes.error.message || '')) {
      var companyId = resolveActiveCompanyId();
      var q = _sbClient.from('departments').delete().eq('name', n);
      if (companyId) q = q.eq('company_id', companyId);
      var delRes = await q;
      if (delRes.error) return { ok: false, error: delRes.error.message || 'delete_failed' };
      return { ok: true };
    }
    if (rpcRes.data && rpcRes.data.error === 'in_use') {
      return { ok: false, error: 'in_use', count: rpcRes.data.count };
    }
    return {
      ok: false,
      error: (rpcRes.data && rpcRes.data.error) || (rpcRes.error && rpcRes.error.message) || 'delete_failed'
    };
  } catch (e) {
    return { ok: false, error: e.message || 'delete_failed' };
  }
}

async function sb_renameDepartment(oldName, newName) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };
  var oldN = String(oldName || '').replace(/\s+/g, ' ').trim();
  var newN = String(newName || '').replace(/\s+/g, ' ').trim();
  if (!oldN || !newN || oldN === newN) return { ok: false, error: 'invalid_names' };
  try {
    var rpcRes = await _sbClient.rpc('saas_rename_department', { p_old: oldN, p_new: newN });
    if (!rpcRes.error && rpcRes.data && rpcRes.data.ok === true) return { ok: true, data: rpcRes.data };
    if (rpcRes.error && /Could not find the function|42883|PGRST202/i.test(rpcRes.error.message || '')) {
      var ensured = await sb_ensureDepartment(newN);
      if (!ensured) return { ok: false, error: 'ensure_failed' };
      var companyId = resolveActiveCompanyId();
      var empQ = _sbClient.from('employees').update({ dept: newN }).eq('dept', oldN);
      if (companyId) empQ = empQ.eq('company_id', companyId);
      await empQ;
      var delRes = await sb_deleteDepartment(oldN);
      return delRes.ok ? { ok: true } : delRes;
    }
    if (rpcRes.data && rpcRes.data.error) {
      return { ok: false, error: rpcRes.data.error };
    }
    return { ok: false, error: (rpcRes.error && rpcRes.error.message) || 'rename_failed' };
  } catch (e) {
    return { ok: false, error: e.message || 'rename_failed' };
  }
}

// ======= Real-time Subscription =======
function sb_subscribeAttendance(callback) {
  if (!_sbClient) return null;
  return _sbClient
    .channel('attendance-changes')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'attendance' }, payload => {
      callback(payload);
    })
    .subscribe();
}

// ======= Data Sync: localStorage ↔ Supabase =======
function kynoStableSyncString(value) {
  try {
    return JSON.stringify(value, function (key, val) {
      if (key && key.charAt(0) === '_') return undefined;
      if (typeof val === 'function') return undefined;
      return val;
    });
  } catch (e) {
    return String(Date.now());
  }
}

function kynoSyncHash(value) {
  var s = kynoStableSyncString(value);
  var h = 0;
  for (var i = 0; i < s.length; i++) {
    h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  }
  return String(h);
}

function kynoEmployeeSyncHash(emp) {
  if (!emp) return '';
  return kynoSyncHash({
    id: emp.id,
    company_id: emp.company_id,
    name: emp.name,
    phone: emp.phone,
    dept: emp.dept,
    role: emp.role,
    salary: emp.salary,
    salaryType: emp.salaryType,
    salaryHalf: emp.salaryHalf,
    dailyRate: emp.dailyRate,
    checkIn: emp.checkIn,
    checkOut: emp.checkOut,
    remoteAttend: emp.remoteAttend,
    openHours: emp.openHours,
    avatarUrl: emp.avatarUrl,
    lateDeductRate: emp.lateDeductRate,
    salStatus: emp.salStatus,
    salBonus: emp.salBonus,
    salDeletedPeriod: emp.salDeletedPeriod,
    days: emp.days,
    lateMin: emp.lateMin,
    devices: emp.devices || []
  });
}

function kynoAttendanceSyncHash(att) {
  if (!att) return '';
  return kynoSyncHash({
    empId: att.empId,
    company_id: att.company_id,
    dateIso: att.dateIso,
    date: att.date,
    ci: att.ci,
    co: att.co,
    hrs: att.hrs,
    late: att.late,
    ot: att.ot,
    status: att.status,
    dept: att.dept,
    emp: att.emp
  });
}

async function kynoRunLimited(items, limit, worker) {
  var list = items || [];
  var concurrency = Math.max(1, Math.min(limit || 6, list.length || 1));
  var index = 0;
  var ok = 0;
  async function next() {
    while (index < list.length) {
      var current = list[index++];
      if (await worker(current)) ok++;
    }
  }
  var runners = [];
  for (var i = 0; i < concurrency; i++) runners.push(next());
  await Promise.all(runners);
  return ok;
}

async function syncToSupabase(options) {
  options = options || {};
  if (_sbSyncRunning) {
    return new Promise(function (resolve) {
      _sbSyncQueue.push({ options: options, resolve: resolve });
    });
  }
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (typeof currentUser !== 'undefined' && currentUser === 'emp' && !options.allowEmployeeClientFullSync) {
    if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
    return !hasPendingDataSync();
  }
  if (typeof AuthApi !== 'undefined') {
    if (AuthApi.ensureValidSession) await AuthApi.ensureValidSession();
    else if (AuthApi.refreshJwtContext) await AuthApi.refreshJwtContext();
    if (AuthApi.hasAuthenticatedSession) {
      var hasJwt = await AuthApi.hasAuthenticatedSession();
      if (!hasJwt) return false;
    }
    var role = AuthApi.getRole ? AuthApi.getRole() : null;
    var tenantCid = AuthApi.getCompanyId ? AuthApi.getCompanyId() : undefined;
    if (role === 'super_admin') {
      return false;
    }
    if (role !== 'super_admin' && (tenantCid === undefined || tenantCid === null)) {
      console.warn('syncToSupabase: no tenant company_id in JWT — skipped');
      return false;
    }
  }
  var isSuperSync = typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.role === 'super_admin';
  if (isSuperSync) {
    return false;
  }
  var activeCid = resolveActiveCompanyId();
  _sbSyncRunning = true;
  window.__basmaDisableAutoSync = true;
  try {
    await mergeRemoteOrgListsBeforeSave();
    var settingsPayload = {
      company_name: window.appSettings.companyName || (saasCurrentUser && saasCurrentUser.company_name) || '',
      currency: window.appSettings.currency,
      timezone: window.appSettings.timezone || 'Asia/Baghdad (GMT+3)',
      work_start: window.appSettings.workStart || '08:00',
      work_end: window.appSettings.workEnd || '17:00',
      late_threshold: window.appSettings.lateThreshold || 15,
      late_deduct_rate: window.appSettings.lateDeductRate || 700,
      month_days: String(typeof getStandardMonthDays === 'function' ? getStandardMonthDays() : (window.appSettings.monthDays || 30)),
      clock_format: (window.appSettings && window.appSettings.clockFormat === '24') ? '24' : '12',
      departments_json: JSON.stringify(window.appSettings.departments || []),
      jobs_json: JSON.stringify(window.appSettings.jobs || []),
      salary_deleted_map: JSON.stringify(window.appSettings.salaryDeletedMap || {}),
      finance_items: JSON.stringify(window.appSettings.financeItems || []),
      gps_name: window.appSettings.gpsName || '',
      gps_lat: window.appSettings.gpsLat || '',
      gps_lng: window.appSettings.gpsLng || '',
      gps_range: String(window.appSettings.gpsRange || 100)
    };
    if (!isSuperSync) {
      settingsPayload.activity_log = JSON.stringify((window.appSettings.activityLog || []).slice(0, 500));
      settingsPayload.employee_notifications = JSON.stringify((window.appSettings.employeeNotifications || []).slice(0, 300));
    }
    if (!canMutateOrgLists()) {
      delete settingsPayload.departments_json;
      delete settingsPayload.jobs_json;
    }
    var settingsOnly = options.settingsOnly === true;
    if (settingsOnly) {
      var settingsOkOnly = await sb_saveSettings(settingsPayload);
      if (!settingsOkOnly) console.warn('syncToSupabase: settings sync failed');
      if (settingsOkOnly) markTenantSyncedNow();
      return !!settingsOkOnly;
    }
    var tenantEmployees = (window.employees || []).filter(function (emp) {
      if (!emp) return false;
      if (!emp.company_id) return false;
      return parseInt(emp.company_id, 10) === activeCid;
    });
    var tenantAttendance = (window.attData || []).filter(function (att) {
      if (!att) return false;
      if (!att.company_id) return false;
      return parseInt(att.company_id, 10) === activeCid;
    });
    var employeesToSync = tenantEmployees.filter(function (emp) {
      var h = kynoEmployeeSyncHash(emp);
      emp._nextSyncHash = h;
      return options.forceFullSync || emp._pendingRemoteSync || emp._freshDevices || emp._devicesPendingSync || emp._lastCloudSyncHash !== h;
    });
    var attendanceToSync = tenantAttendance.filter(function (att) {
      var h = kynoAttendanceSyncHash(att);
      att._nextSyncHash = h;
      return options.forceFullSync || att._pendingRemoteSync || att._lastCloudSyncHash !== h;
    });

    window.__basmaBulkSyncRunning = true;
    if (typeof updatePendingSyncBadge === 'function') updatePendingSyncBadge();
    await kynoRunLimited(employeesToSync, options.employeeConcurrency || 6, async function (emp) {
      emp.company_id = resolveActiveCompanyId(emp);
      if (typeof window.isEmployeeRecentlyDeleted === 'function' &&
          window.isEmployeeRecentlyDeleted(emp.id) &&
          !emp._pendingRemoteSync && !emp._addedAt && !emp._devicesPendingSync) {
        return false;
      }
      var savedEmp = await sb_upsertEmployee(emp);
      if (savedEmp) {
        emp._lastCloudSyncHash = emp._nextSyncHash;
        emp._remoteSyncedAt = Date.now();
        delete emp._pendingRemoteSync;
        delete emp._devicesPendingSync;
        delete emp._nextSyncHash;
        if (typeof window.clearEmployeeDeletedLocally === 'function') window.clearEmployeeDeletedLocally(emp.id);
        return true;
      }
      return false;
    });

    await kynoRunLimited(attendanceToSync, options.attendanceConcurrency || 16, async function (att) {
      if (att.empId && !att.company_id) {
        var empRef = (window.employees || []).find(function (e) { return e.id === att.empId; });
        if (empRef && empRef.company_id) att.company_id = empRef.company_id;
      }
      att.company_id = resolveActiveCompanyId(att);
      var savedAtt = await sb_upsertAttendance(att);
      if (savedAtt) {
        att._lastCloudSyncHash = att._nextSyncHash;
        att._remoteSyncedAt = Date.now();
        delete att._pendingRemoteSync;
        delete att._nextSyncHash;
        return true;
      }
      return false;
    });
    window.__basmaBulkSyncRunning = false;

    var leavesToSync = (window.leavesData || []).filter(function (leave) {
      if (!leave || !leave._pendingSync) return false;
      if (leave.company_id && activeCid && parseInt(leave.company_id, 10) !== parseInt(activeCid, 10)) return false;
      return true;
    });
    if (leavesToSync.length && typeof sb_upsertLeave === 'function') {
      await kynoRunLimited(leavesToSync, options.leavesConcurrency || 6, async function (leave) {
        leave.company_id = leave.company_id || activeCid;
        var res = await sb_upsertLeave(leave);
        if (res && res.ok && res.data) {
          leave._remoteId = res.data.id || leave._remoteId;
          leave._pendingSync = false;
          return true;
        }
        leave._pendingSync = true;
        return false;
      });
    }

    var settingsOk = await sb_saveSettings(settingsPayload);
    if (!settingsOk) console.warn('syncToSupabase: settings sync failed (employees/attendance may still be saved)');
    if ((employeesToSync.length || attendanceToSync.length || leavesToSync.length) && typeof syncWindowState === 'function') syncWindowState();
    if ((employeesToSync.length || attendanceToSync.length || leavesToSync.length) && typeof saveData === 'function') {
      var prevDisable = window.__basmaDisableAutoSync;
      window.__basmaDisableAutoSync = true;
      try { saveData(); } catch (e) { console.warn('syncToSupabase local stamp save:', e); }
      window.__basmaDisableAutoSync = prevDisable;
    }
    markTenantSyncedNow();
    return true;
  } catch (_se) {
    window.__basmaBulkSyncRunning = false;
    throw _se;
  } finally {
    window.__basmaBulkSyncRunning = false;
    _sbSyncRunning = false;
    if (!options.keepDisableAutoSync) window.__basmaDisableAutoSync = false;
    if (_sbSyncQueue.length) {
      var nextJob = _sbSyncQueue.shift();
      syncToSupabase(nextJob.options).then(nextJob.resolve);
    }
  }
}

async function syncFromSupabase(options) {
  options = options || {};
  if (!_sbClient && !(await ensureSupabaseClient())) {
    console.warn('syncFromSupabase: not ready');
    return false;
  }
  if (isSuperAdminSession()) {
    return false;
  }
  if (!resolveActiveCompanyId()) {
    return false;
  }
  window.__basmaDisableAutoSync = true;
  try {
    var emps = await sb_getEmployees({ limit: 500 });
    if (emps === null && !options.realtime) {
      console.warn('syncFromSupabase: employees fetch failed');
      return false;
    }
    var atts = await sb_getAttendance({ limit: 3000 });
    var settings = await sb_getSettings();
    if (emps !== null) {
      if (options.forceRemote) {
        if (typeof filterRecentlyDeletedEmployees === 'function') {
          emps = filterRecentlyDeletedEmployees(emps);
        }
        window.employees = emps || [];
      } else {
        if (typeof filterRecentlyDeletedEmployees === 'function') {
          emps = filterRecentlyDeletedEmployees(emps);
        }
        if (typeof mergeRemoteEmployeesWithLocal === 'function') {
          emps = mergeRemoteEmployeesWithLocal(emps);
        } else if (typeof mergeLocalPendingEmployees === 'function') {
          emps = mergeLocalPendingEmployees(emps);
        }
        window.employees = emps;
      }
      window.nextEmpId = (window.employees || []).length
        ? Math.max.apply(null, (window.employees || []).map(function (e) { return e.id; })) + 1
        : 1;
      (window.employees || []).forEach(function (emp) {
        var h = kynoEmployeeSyncHash(emp);
        if (!emp._pendingRemoteSync) {
          emp._lastCloudSyncHash = h;
        }
        delete emp._nextSyncHash;
      });
    }
    if (atts !== null) {
      if (options.forceRemote) {
        if (typeof filterAttendanceForEmployees === 'function') {
          window.attData = filterAttendanceForEmployees(window.employees || [], atts);
        } else {
          window.attData = atts || [];
        }
        if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
      } else {
        if (typeof mergeLocalPendingAttendance === 'function') {
          atts = mergeLocalPendingAttendance(atts, window.employees || []);
        }
        if (typeof filterAttendanceForEmployees === 'function') {
          window.attData = filterAttendanceForEmployees(window.employees || [], atts);
        } else {
          window.attData = atts;
        }
      }
      if (typeof normalizeAttendanceStore === 'function') normalizeAttendanceStore();
      (window.attData || []).forEach(function (att) {
        var h = kynoAttendanceSyncHash(att);
        if (!att._pendingRemoteSync) {
          att._lastCloudSyncHash = h;
        }
        delete att._nextSyncHash;
      });
    }
    if (typeof syncAllAttendanceEmployeeNames === 'function') {
      syncAllAttendanceEmployeeNames();
    }
    if (typeof syncLeavesFromSupabase === 'function') {
      await syncLeavesFromSupabase();
    }
    if (settings !== null) {
      applyRemoteAppSettings(settings, { forceRemote: !!options.forceRemote });
      if (typeof filterNotificationsForCurrentTenant === 'function') filterNotificationsForCurrentTenant();
      var tableDepts = await sb_getDepartmentNames();
      if (tableDepts !== null && tableDepts.length) {
        var jsonDepts = window.appSettings.departments || [];
        window.appSettings.departments = dedupeOrgNames(jsonDepts.concat(tableDepts));
      }
    }
    if (typeof sb_loadPlatformGlobals === 'function') await sb_loadPlatformGlobals();
    if (typeof syncWindowState === 'function') syncWindowState();
    if (typeof saveData === 'function') saveData();
    if (typeof refreshAll === 'function') refreshAll();
    if (document.getElementById('page-org') && document.getElementById('page-org').classList.contains('active') &&
        typeof buildOrgPage === 'function') {
      buildOrgPage();
    }
    if (document.getElementById('page-settings')?.classList.contains('active')) {
      if (typeof syncSettingsUi === 'function') syncSettingsUi();
      if (typeof previewGpsMap === 'function') previewGpsMap();
    }
    if (!options.realtime) await setupSupabaseRealtime();
    markTenantSyncedNow();
    var syncedCid = resolveActiveCompanyId();
    if (syncedCid) {
      try { localStorage.setItem('basma_tenant_verified_c_' + syncedCid, String(Date.now())); } catch (e) { /* ignore */ }
      if (typeof window.clearCompanyTenantFresh === 'function') window.clearCompanyTenantFresh(syncedCid);
      if (typeof filterLocalDataByCompany === 'function') filterLocalDataByCompany(syncedCid);
      if (typeof filterNotificationsForCurrentTenant === 'function') filterNotificationsForCurrentTenant();
    }
    return true;
  } catch (e) {
    console.warn('syncFromSupabase failed:', e);
    return false;
  } finally {
    if (!options.keepDisableAutoSync) window.__basmaDisableAutoSync = false;
  }
}

// ============================================================
// SaaS Multi-Tenant
// ============================================================
function _normalizeSaasPermissions(perms) {
  if (!perms) return {};
  if (typeof perms === 'string') {
    try { return JSON.parse(perms) || {}; } catch (e) { return {}; }
  }
  return perms;
}

async function sb_saasLogin(username, password) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var safeUser = String(username || '').trim();
    if (!safeUser || !password) return null;
    var rpcRes = await _sbClient.rpc('saas_verify_login', {
      p_username: safeUser,
      p_password: String(password),
      p_ip: (typeof window !== 'undefined' && window.currentClientIp) ? window.currentClientIp : null
    });
    if (!rpcRes.error && rpcRes.data) {
      var d = rpcRes.data;
      if (d.error === 'rate_limited') return null;
      if (d.error === 'password_reset_required') return null;
      return {
        id: d.id,
        username: d.username,
        display_name: d.display_name || '',
        email: d.email || '',
        role: d.role,
        permissions: _normalizeSaasPermissions(d.permissions),
        company_id: d.company_id || null,
        company_name: d.company_name || null,
        company_code: d.company_code || null,
        company_status: d.company_status || null,
        max_employees: parseInt(d.max_employees, 10) || 0
      };
    }
    console.warn('sb_saasLogin: use Edge auth-login only', rpcRes.error);
    return null;
  } catch (e) {
    console.error('sb_saasLogin:', e);
    return null;
  }
}

async function sb_getSaasUserById(userId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  var uid = parseInt(userId, 10);
  if (!uid) return null;
  try {
    var rpcRes = await _sbClient.rpc('saas_get_user_profile', { p_user_id: uid });
    if (!rpcRes.error && rpcRes.data) {
      var d = rpcRes.data;
      return {
        id: d.id,
        username: d.username,
        display_name: d.display_name || '',
        email: d.email || '',
        role: d.role,
        permissions: _normalizeSaasPermissions(d.permissions),
        company_id: d.company_id || null,
        company_name: d.company_name || null,
        company_code: d.company_code || null,
        company_status: d.company_status || null,
        max_employees: parseInt(d.max_employees, 10) || 0
      };
    }
    if (typeof saasCurrentUser !== 'undefined' && saasCurrentUser && saasCurrentUser.company_id) {
      var list = await sb_getCompanyUsers(saasCurrentUser.company_id);
      var hit = (list || []).find(function (u) { return Number(u.id) === uid; });
      if (hit) {
        return {
          id: hit.id,
          username: hit.username,
          display_name: hit.display_name || '',
          email: hit.email || '',
          role: hit.role,
          permissions: _normalizeSaasPermissions(hit.permissions),
          company_id: hit.company_id || saasCurrentUser.company_id,
          company_name: saasCurrentUser.company_name || null,
          company_code: saasCurrentUser.company_code || null,
          company_status: saasCurrentUser.company_status || null,
          max_employees: saasCurrentUser.max_employees || 0
        };
      }
    }
    return null;
  } catch (e) {
    return null;
  }
}

// ======= Companies =======
async function sb_getCompanies() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    const { data, error } = await _sbClient
      .from('v_companies_summary')
      .select('*')
      .order('id');
    if (!error) return data;
    if (error.code === 'PGRST205' || (error.message && error.message.indexOf('v_companies_summary') >= 0)) {
      const { data: d2, error: e2 } = await _sbClient.from('companies').select('*').order('id');
      if (e2) { console.error('sb_getCompanies:', e2); return null; }
      return (d2 || []).map(function (c) {
        return Object.assign({}, c, {
          employee_count: c.employee_count != null ? c.employee_count : 0,
          subscription_status: c.subscription_status || c.status || 'pending'
        });
      });
    }
    console.error('sb_getCompanies:', error);
    return null;
  } catch (e) { console.error('sb_getCompanies exception:', e); return null; }
}

// ======= Companies (super_admin — RPC after 033 lockdown) =======
async function sb_rpcSuperUpsertCompany(company) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_super_upsert_company', {
      p_payload: {
        id: company.id || null,
        company_name: company.company_name || company.name || '',
        company_code: company.company_code || company.code || '',
        status: company.status || 'active',
        max_employees: parseInt(company.max_employees || 50) || 50,
        notes: company.notes || ''
      }
    });
    if (rpc.error) {
      console.error('sb_rpcSuperUpsertCompany:', rpc.error);
      return null;
    }
    if (!rpc.data || rpc.data.ok !== true) {
      console.error('sb_rpcSuperUpsertCompany:', rpc.data && rpc.data.error);
      return null;
    }
    return rpc.data.data;
  } catch (e) {
    console.error('sb_rpcSuperUpsertCompany:', e);
    return null;
  }
}

async function sb_upsertCompany(company) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  if (kynoPlatformAdminRpc()) {
    return sb_rpcSuperUpsertCompany(company);
  }
  const row = {
    company_name:  company.company_name || company.name || '',
    company_code:  company.company_code || company.code || '',
    status:        company.status || 'active',
    max_employees: parseInt(company.max_employees || 50) || 50,
    notes:         company.notes || ''
  };
  try {
    if (company.id) {
      const { data, error } = await _sbClient
        .from('companies')
        .update(row)
        .eq('id', company.id)
        .select()
        .single();
      if (error) { console.error('sb_upsertCompany update:', error); return null; }
      return data;
    }
    const { data, error } = await _sbClient
      .from('companies')
      .insert(row)
      .select()
      .single();
    if (error) { console.error('sb_upsertCompany insert:', error); return null; }
    return data;
  } catch (e) {
    console.error('sb_upsertCompany exception:', e);
    return null;
  }
}

async function sb_generateCompanyCode() {
  if (!_sbClient && !(await ensureSupabaseClient())) return 'KYNO-' + Date.now().toString(36).toUpperCase();
  for (var i = 0; i < 10; i++) {
    var code = 'KYNO-' + Date.now().toString(36).toUpperCase().slice(-5) + Math.random().toString(36).slice(2, 6).toUpperCase();
    var chk = await _sbClient.from('companies').select('id').eq('company_code', code).maybeSingle();
    if (!chk.error && !chk.data) return code;
  }
  return 'KYNO-' + Date.now();
}

async function sb_createCompanyWithAdmin(data) {
  if (!data || !data.name) return { ok: false, error: 'بيانات غير صالحة' };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'انتهت جلسة الدخول' };

  var code = (data.code || data.company_code || '').trim().toUpperCase();
  if (!code) code = await sb_generateCompanyCode();

  var company = null;
  if (kynoPlatformAdminRpc()) {
    company = await sb_rpcSuperUpsertCompany({
      company_name: data.name || data.company_name,
      company_code: code,
      max_employees: parseInt(data.max_employees, 10) || 50,
      status: 'pending'
    });
    if (!company) {
      return { ok: false, error: 'فشل إنشاء الشركة — تواصل مع الدعم الفني لتحديث النظام' };
    }
  } else {
    var ins = await _sbClient.from('companies').insert({
      company_name: data.name || data.company_name,
      company_code: code,
      max_employees: parseInt(data.max_employees, 10) || 50,
      status: 'pending'
    }).select().single();

    if (ins.error) {
      if (ins.error.code === '23505') return { ok: false, error: 'كود الشركة مستخدم — حاول مرة أخرى' };
      return { ok: false, error: ins.error.message || 'insert_failed' };
    }
    company = ins.data;
  }

  var userRes = await sb_upsertCompanyUser({
    username: data.username,
    email: data.email || '',
    password: data.password,
    role: 'company_admin',
    display_name: data.display_name || data.username
  }, company.id);

  if (!userRes.ok) {
    if (kynoPlatformAdminRpc()) {
      await _sbClient.rpc('saas_super_delete_company', { p_company_id: company.id });
    } else {
      await _sbClient.from('companies').delete().eq('id', company.id);
    }
    return { ok: false, error: userRes.error || 'فشل إنشاء مدير الشركة — اسم المستخدم قد يكون مستخدماً' };
  }

  if (typeof sb_seedCompanyDefaultSettings === 'function') {
    try {
      await sb_seedCompanyDefaultSettings(company.id, company.company_name || data.name || '');
    } catch (seedErr) {
      console.warn('sb_seedCompanyDefaultSettings:', seedErr);
    }
  }

  if (typeof window.markCompanyTenantFresh === 'function') {
    window.markCompanyTenantFresh(company.id);
  }

  return { ok: true, company: company, admin: userRes.user, code: code };
}

async function sb_toggleCompanyStatus(companyId, newStatus) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (kynoPlatformAdminRpc()) {
    try {
      var rpc = await _sbClient.rpc('saas_super_toggle_company_status', {
        p_company_id: companyId,
        p_status: newStatus
      });
      return !!(rpc.data && rpc.data.ok === true);
    } catch (e) {
      console.error('sb_toggleCompanyStatus rpc:', e);
      return false;
    }
  }
  const { error } = await _sbClient
    .from('companies')
    .update({ status: newStatus, updated_at: new Date().toISOString() })
    .eq('id', companyId);
  if (error) { console.error('sb_toggleCompanyStatus:', error); return false; }
  return true;
}

async function sb_deleteCompany(companyId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (kynoPlatformAdminRpc()) {
    try {
      var rpc = await _sbClient.rpc('saas_super_delete_company', { p_company_id: companyId });
      return !!(rpc.data && rpc.data.ok === true);
    } catch (e) {
      console.error('sb_deleteCompany rpc:', e);
      return false;
    }
  }
  // Delete subscription, users, employees, attendance first
  await _sbClient.from('subscriptions').delete().eq('company_id', companyId);
  await _sbClient.from('saas_users').delete().eq('company_id', companyId);
  await _sbClient.from('employee_devices').delete()
    .in('employee_id', (await _sbClient.from('employees').select('id').eq('company_id', companyId)).data?.map(e => e.id) || []);
  await _sbClient.from('attendance').delete().eq('company_id', companyId);
  await _sbClient.from('salary_records').delete().eq('company_id', companyId);
  await _sbClient.from('employees').delete().eq('company_id', companyId);
  const { error } = await _sbClient.from('companies').delete().eq('id', companyId);
  if (error) { console.error('sb_deleteCompany:', error); return false; }
  return true;
}

// ======= Subscriptions =======
function sb_normalizeMoneyInt(value, fallback) {
  if (value === null || value === undefined || value === '') {
    return Math.max(0, Math.round(Number(fallback) || 0));
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.round(value));
  }
  var normalized = String(value)
    .replace(/[٠-٩]/g, function (d) { return String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)); })
    .replace(/[۰-۹]/g, function (d) { return String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)); })
    .replace(/[^\d,٬.-]/g, '')
    .replace(/[٬,]/g, '');
  if (!normalized || normalized === '-' || normalized === '.') {
    return Math.max(0, Math.round(Number(fallback) || 0));
  }
  var n = Number(normalized);
  if (!Number.isFinite(n)) {
    return Math.max(0, Math.round(Number(fallback) || 0));
  }
  return Math.max(0, Math.round(n));
}

async function sb_getSubscription(companyId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  const { data, error } = await _sbClient
    .from('subscriptions')
    .select('*')
    .eq('company_id', companyId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) { console.error('sb_getSubscription:', error); return null; }
  return data;
}

async function sb_getAllSubscriptions() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  const { data, error } = await _sbClient
    .from('subscriptions')
    .select('*, companies(company_name, company_code)')
    .order('created_at', { ascending: false });
  if (error) { console.error('sb_getAllSubscriptions:', error); return null; }
  return data;
}

function _subDateOnlyIso(value) {
  if (!value) return '';
  var s = String(value).slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : '';
}

function _subTodayIsoLocal() {
  var d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

function _subDaysLeftFromEnd(endDateIso) {
  var end = _subDateOnlyIso(endDateIso);
  if (!end) return 0;
  var today = _subTodayIsoLocal();
  var e = new Date(end + 'T12:00:00');
  var t = new Date(today + 'T12:00:00');
  return Math.ceil((e - t) / 86400000);
}

function _subIsPastEndDate(endDateIso) {
  var end = _subDateOnlyIso(endDateIso);
  if (!end) return true;
  return end < _subTodayIsoLocal();
}

function _parseSubscriptionStatusRpcPayload(data) {
  var payload = data;
  if (typeof payload === 'string') {
    try { payload = JSON.parse(payload); } catch (e) { payload = null; }
  }
  if (!payload || typeof payload.valid !== 'boolean') return null;
  return {
    valid: payload.valid === true,
    status: payload.status || (payload.valid ? 'active' : 'expired'),
    message: payload.message || '',
    end_date: payload.end_date,
    daysLeft: payload.daysLeft != null ? payload.daysLeft : payload.days_left,
    warning: payload.warning === true
  };
}

async function sb_renewSubscription(companyId, durationDays, amount, notes) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };
  durationDays = parseInt(durationDays, 10) || 30;
  var paymentAmount = sb_normalizeMoneyInt(amount, 0);
  if (kynoPlatformAdminRpc()) {
    try {
      var rpc = await _sbClient.rpc('saas_super_renew_subscription', {
        p_company_id: companyId,
        p_duration_days: durationDays,
        p_amount: paymentAmount,
        p_notes: notes || null,
        p_plan_name: null
      });
      if (rpc.error) {
        console.error('sb_renewSubscription rpc error:', rpc.error);
        return { ok: false, error: rpc.error.message || 'rpc_error' };
      }
      var renewPayload = rpc.data;
      if (typeof renewPayload === 'string') {
        try { renewPayload = JSON.parse(renewPayload); } catch (e) { renewPayload = null; }
      }
      if (renewPayload && renewPayload.ok === true) return { ok: true };
      var renewErr = (renewPayload && renewPayload.error) || 'renew_failed';
      console.error('sb_renewSubscription:', renewErr, renewPayload);
      return { ok: false, error: renewErr };
    } catch (e) {
      console.error('sb_renewSubscription rpc:', e);
      return { ok: false, error: e.message || 'exception' };
    }
  }
  try {
    const existing = await sb_getSubscription(companyId);
    const now = new Date();
    let startDate, endDate;
    if (existing && existing.status === 'active' && !_subIsPastEndDate(existing.end_date)) {
      const currentEnd = _subDateOnlyIso(existing.end_date);
      startDate = existing.start_date || _subTodayIsoLocal();
      endDate = new Date(currentEnd + 'T12:00:00');
      endDate.setDate(endDate.getDate() + durationDays);
    } else {
      startDate = _subTodayIsoLocal();
      endDate = new Date(now);
      endDate.setDate(endDate.getDate() + durationDays);
    }
    const endDateStr = endDate.getFullYear() + '-' + String(endDate.getMonth() + 1).padStart(2, '0') + '-' + String(endDate.getDate()).padStart(2, '0');
    const activatedBy = window._saasCurrentUser ? window._saasCurrentUser.username : 'system';
    const durationMonths = Math.max(1, Math.ceil(durationDays / 30));
    const noteText = notes || ('تمديد ' + durationDays + ' يوم');
    if (existing) {
      const { error } = await _sbClient
        .from('subscriptions')
        .update({
          start_date: startDate,
          end_date: endDateStr,
          status: 'active',
          duration_months: durationMonths,
          amount: paymentAmount,
          notes: noteText,
          activated_by: activatedBy,
          updated_at: new Date().toISOString()
        })
        .eq('id', existing.id);
      if (error) { console.error('sb_renewSubscription update:', error); return { ok: false, error: error.message || 'update_failed' }; }
    } else {
      const { error } = await _sbClient
        .from('subscriptions')
        .insert({
          company_id: companyId,
          plan_name: 'PRO',
          start_date: startDate,
          end_date: endDateStr,
          status: 'active',
          duration_months: durationMonths,
          amount: paymentAmount,
          notes: noteText,
          activated_by: activatedBy
        });
      if (error) { console.error('sb_renewSubscription insert:', error); return { ok: false, error: error.message || 'insert_failed' }; }
    }
    await _sbClient.from('companies').update({ status: 'active' }).eq('id', companyId);
    return { ok: true };
  } catch (e) {
    console.error('sb_renewSubscription exception:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

function sb_calcSubscriptionDurationDays(sub) {
  if (!sub) return 30;
  if (sub.start_date && sub.end_date) {
    return Math.max(1, Math.round((new Date(sub.end_date) - new Date(sub.start_date)) / 86400000));
  }
  if (sub.duration_months) return Math.max(1, sub.duration_months * 30);
  return 30;
}

async function sb_updateSubscriptionDetails(opts) {
  opts = opts || {};
  var subscriptionId = parseInt(opts.subscriptionId, 10);
  var companyId = parseInt(opts.companyId, 10);
  if (!subscriptionId || !companyId) return { ok: false, error: 'invalid_params' };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };

  var durationDays = opts.durationDays != null ? Math.max(1, parseInt(opts.durationDays, 10) || 30) : null;
  var maxEmployees = opts.maxEmployees != null ? Math.max(1, parseInt(opts.maxEmployees, 10) || 50) : null;
  var companyName = opts.companyName != null ? String(opts.companyName).trim() : null;
  var amount = opts.amount != null ? sb_normalizeMoneyInt(opts.amount, 0) : null;

  if (kynoPlatformAdminRpc()) {
    try {
      var rpc = await _sbClient.rpc('saas_super_edit_subscription', {
        p_subscription_id: subscriptionId,
        p_company_name: companyName,
        p_max_employees: maxEmployees,
        p_duration_days: durationDays,
        p_amount: amount
      });
      if (rpc.error) {
        console.error('sb_updateSubscriptionDetails rpc:', rpc.error);
        return { ok: false, error: rpc.error.message || 'rpc_error' };
      }
      var payload = rpc.data;
      if (typeof payload === 'string') {
        try { payload = JSON.parse(payload); } catch (e) { payload = null; }
      }
      if (payload && payload.ok === true) return { ok: true, data: payload.data };
      return { ok: false, error: (payload && payload.error) || 'edit_failed' };
    } catch (e) {
      console.error('sb_updateSubscriptionDetails rpc:', e);
      return { ok: false, error: e.message || 'exception' };
    }
  }

  try {
    var companies = await sb_getCompanies();
    var company = (companies || []).find(function (c) { return c && c.id === companyId; });
    if (!company) return { ok: false, error: 'company_not_found' };

    if (companyName || maxEmployees != null) {
      var updated = await sb_upsertCompany({
        id: companyId,
        company_name: companyName || company.company_name,
        company_code: company.company_code,
        status: company.status,
        max_employees: maxEmployees != null ? maxEmployees : company.max_employees,
        notes: company.notes || ''
      });
      if (!updated) return { ok: false, error: 'company_update_failed' };
    }

    var subs = await sb_getAllSubscriptions();
    var sub = (subs || []).find(function (s) { return s && s.id === subscriptionId; });
    if (!sub) return { ok: false, error: 'subscription_not_found' };

    var updatePayload = { updated_at: new Date().toISOString() };
    if (durationDays != null) {
      var startDate = _subTodayIsoLocal();
      var endD = new Date(startDate + 'T12:00:00');
      endD.setDate(endD.getDate() + durationDays);
      var endDateStr = endD.getFullYear() + '-' + String(endD.getMonth() + 1).padStart(2, '0') + '-' + String(endD.getDate()).padStart(2, '0');
      updatePayload.start_date = startDate;
      updatePayload.end_date = endDateStr;
      updatePayload.duration_months = Math.max(1, Math.ceil(durationDays / 30));
      updatePayload.status = _subIsPastEndDate(endDateStr) ? 'expired' : 'active';
    }
    if (amount != null) updatePayload.amount = amount;

    if (Object.keys(updatePayload).length > 1) {
      var res = await _sbClient.from('subscriptions').update(updatePayload).eq('id', subscriptionId);
      if (res.error) {
        console.error('sb_updateSubscriptionDetails:', res.error);
        return { ok: false, error: res.error.message || 'update_failed' };
      }
    }
    return { ok: true };
  } catch (e) {
    console.error('sb_updateSubscriptionDetails:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_deleteSubscription(subscriptionId) {
  if (!subscriptionId) return { ok: false, error: 'invalid_id' };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };
  if (kynoPlatformAdminRpc()) {
    try {
      var rpc = await _sbClient.rpc('saas_super_delete_subscription', {
        p_subscription_id: subscriptionId
      });
      if (rpc.error) return { ok: false, error: rpc.error.message || 'rpc_error' };
      if (!rpc.data || rpc.data.ok !== true) return { ok: false, error: (rpc.data && rpc.data.error) || 'not_found' };
      return { ok: true };
    } catch (e) {
      return { ok: false, error: e.message || 'exception' };
    }
  }
  try {
    var del = await _sbClient
      .from('subscriptions')
      .delete({ count: 'exact' })
      .eq('id', subscriptionId);
    if (del.error) {
      console.error('sb_deleteSubscription:', del.error);
      return { ok: false, error: del.error.message || 'delete_failed' };
    }
    if (!del.count) return { ok: false, error: 'not_found' };
    return { ok: true };
  } catch (e) {
    console.error('sb_deleteSubscription exception:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_checkSubscriptionStatus(companyId) {
  var cid = parseInt(companyId, 10);
  if (!cid) return { valid: true, status: 'active', message: '' };

  if (!_sbClient && !(await ensureSupabaseClient())) {
    return { valid: true, status: 'active', message: '' };
  }

  try {
    var statusRpc = await _sbClient.rpc('saas_get_company_subscription_status', { p_company_id: cid });
    if (!statusRpc.error && statusRpc.data) {
      var rpcStatus = _parseSubscriptionStatusRpcPayload(statusRpc.data);
      if (rpcStatus) return rpcStatus;
    } else if (statusRpc.error) {
      console.warn('sb_checkSubscriptionStatus rpc:', statusRpc.error);
    }
  } catch (e) {
    console.warn('sb_checkSubscriptionStatus rpc exception:', e);
  }

  const sub = await sb_getSubscription(cid);
  if (!sub) return { valid: false, status: 'pending', message: 'لا يوجد اشتراك نشط', daysLeft: 0 };
  if (sub.status === 'suspended') {
    return { valid: false, status: 'suspended', message: 'حساب الشركة موقوف. تواصل مع الدعم الفني.', end_date: sub.end_date, daysLeft: 0 };
  }
  var pastEnd = _subIsPastEndDate(sub.end_date);
  if (sub.status === 'pending' || pastEnd) {
    if (sub.status === 'active' && pastEnd) {
      if (kynoUseRpcWrites() || isHostedSupabase()) {
        try {
          await _sbClient.rpc('saas_mark_subscription_expired', { p_subscription_id: sub.id });
        } catch (e) { /* read-only degrade */ }
      } else if (await ensureSbAuthForWrite()) {
        try {
          await _sbClient.from('subscriptions').update({ status: 'expired' }).eq('id', sub.id);
        } catch (e2) { /* ignore */ }
      }
    }
    var expiredDaysLeft = _subDaysLeftFromEnd(sub.end_date);
    return {
      valid: false, status: 'expired',
      message: 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      end_date: sub.end_date, daysLeft: expiredDaysLeft
    };
  }
  if (sub.status === 'expired' && !pastEnd) {
    var repairedDaysLeft = _subDaysLeftFromEnd(sub.end_date);
    var repairedWarning = repairedDaysLeft <= 10;
    return {
      valid: true, status: 'active',
      daysLeft: Math.max(repairedDaysLeft, 0), warning: repairedWarning,
      message: repairedWarning ? ('ينتهي الاشتراك خلال ' + Math.max(repairedDaysLeft, 0) + ' يوم') : '',
      end_date: sub.end_date
    };
  }
  var daysLeft = _subDaysLeftFromEnd(sub.end_date);
  var warning = daysLeft <= 10;
  return {
    valid: true, status: 'active',
    daysLeft: Math.max(daysLeft, 0), warning,
    message: warning ? ('ينتهي الاشتراك خلال ' + Math.max(daysLeft, 0) + ' يوم') : '',
    end_date: sub.end_date
  };
}

// Legacy hash for saas_users rows only — new passwords: AuthApi.setPasswordBcrypt (Edge)
function _saasHashPassword(password) {
  try { return btoa(String(password || '')); } catch (e) { return String(password || ''); }
}

// ======= Company Users (مدير الشركة) =======
function _mapCompanyUserRpcError(code) {
  var map = {
    invalid_args: 'بيانات غير صالحة',
    invalid_role: 'دور غير مسموح',
    forbidden: 'لا تملك صلاحية إدارة المستخدمين — سجّل خروجاً ثم ادخل كمدير شركة',
    user_not_found: 'المستخدم غير موجود',
    username_taken: 'اسم المستخدم مستخدم مسبقاً',
    password_required: 'كلمة المرور مطلوبة (6 أحرف على الأقل)',
    password_hash_failed: 'تعذّر تشفير كلمة المرور — تواصل مع الدعم الفني',
    password_verify_failed: 'فشل التحقق من كلمة المرور — تواصل مع الدعم الفني',
    no_auth: 'انتهت جلسة الدخول — سجّل الدخول مرة أخرى',
    self_delete: 'لا يمكنك حذف حسابك الحالي',
    delete_failed: 'تعذّر الحذف — تواصل مع الدعم الفني'
  };
  return map[code] || code || 'حدث خطأ';
}

async function sb_getCompanyUsers(companyId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return [];
  if (!(await ensureSbAuthForWrite())) return [];
  var cid = parseInt(companyId, 10);
  if (!cid) return [];
  try {
    var rpc = await _sbClient.rpc('saas_list_company_users', { p_company_id: cid });
    if (!rpc.error && rpc.data != null) {
      var list = rpc.data;
      if (typeof list === 'string') {
        try { list = JSON.parse(list); } catch (e) { list = []; }
      }
      if (Array.isArray(list)) return list;
    }
    if (rpc.error && /Could not find the function|42883|PGRST202/i.test(rpc.error.message || '')) {
      var res = await _sbClient
        .from('saas_users')
        .select('id, username, display_name, email, role, permissions, company_id, is_active, last_login, created_at')
        .eq('company_id', cid)
        .neq('role', 'super_admin')
        .order('id');
      if (res.error) {
        console.error('sb_getCompanyUsers fallback:', res.error);
        return [];
      }
      return res.data || [];
    }
    if (rpc.error) console.warn('sb_getCompanyUsers:', rpc.error);
    if (rpc.data && Array.isArray(rpc.data)) return rpc.data;
    return [];
  } catch (e) {
    console.warn('sb_getCompanyUsers:', e);
    return [];
  }
}

async function _sbVerifyCompanyUserPassword(username, password, userId, companyId) {
  var uname = String(username || '').trim().toLowerCase();
  if (!uname || !password || !userId || !companyId) return true;
  if (typeof AuthApi === 'undefined' || !AuthApi.verifyCredentialsViaRpc) return true;
  var verified = await AuthApi.verifyCredentialsViaRpc(uname, password);
  if (verified) return true;
  try {
    var repair = await _sbClient.rpc('saas_rehash_company_user_password', {
      p_user_id: parseInt(userId, 10),
      p_company_id: parseInt(companyId, 10),
      p_password: String(password)
    });
    if (repair.error) {
      console.warn('saas_rehash_company_user_password:', repair.error.message || repair.error);
      return false;
    }
    if (repair.data && repair.data.ok === false) {
      console.warn('saas_rehash_company_user_password:', repair.data.error);
      return false;
    }
    return !!(await AuthApi.verifyCredentialsViaRpc(uname, password));
  } catch (e) {
    console.warn('_sbVerifyCompanyUserPassword:', e);
    return false;
  }
}

async function sb_upsertCompanyUser(user, companyId) {
  if (!user || !companyId) return { ok: false, error: 'invalid_args' };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'no_auth' };
  var cid = parseInt(companyId, 10);
  if (!cid) return { ok: false, error: 'invalid_company' };
  try {
    var uname = String(user.username || '').trim().toLowerCase();
    var params = {
      p_company_id: cid,
      p_username: uname,
      p_display_name: user.display_name || '',
      p_email: user.email || null,
      p_role: user.role || 'company_user',
      p_is_active: user.is_active !== false
    };
    if (user.permissions !== undefined && user.permissions !== null) {
      params.p_permissions = user.permissions;
    }
    if (user.id) params.p_user_id = user.id;
    if (user.password) params.p_password = String(user.password);
    var rpc = await _sbClient.rpc('saas_upsert_company_user', params);
    if (rpc.error) {
      console.warn('sb_upsertCompanyUser:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_error' };
    }
    var d = rpc.data;
    if (d && d.ok === true) {
      var savedUser = d.user || null;
      if (user.password && savedUser && savedUser.id) {
        var pwdOk = await _sbVerifyCompanyUserPassword(uname, user.password, savedUser.id, cid);
        if (!pwdOk) {
          return {
            ok: false,
            error: _mapCompanyUserRpcError('password_verify_failed'),
            user: savedUser,
            password_verified: false
          };
        }
      }
      return { ok: true, user: savedUser, password_verified: true };
    }
    return { ok: false, error: _mapCompanyUserRpcError(d && d.error) };
  } catch (e) {
    console.warn('sb_upsertCompanyUser:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_deleteCompanyUser(userId, companyId) {
  if (!userId || !companyId) return { ok: false, error: _mapCompanyUserRpcError('invalid_args') };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (typeof AuthApi !== 'undefined' && AuthApi.ensureValidSession) {
    await AuthApi.ensureValidSession();
  }
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: _mapCompanyUserRpcError('no_auth') };
  var uid = parseInt(userId, 10);
  var cid = parseInt(companyId, 10);
  if (typeof AuthApi !== 'undefined' && AuthApi.getCompanyId) {
    var jwtCid = AuthApi.getCompanyId();
    if (jwtCid != null && parseInt(jwtCid, 10) > 0) cid = parseInt(jwtCid, 10);
  }
  if (!uid || !cid) return { ok: false, error: _mapCompanyUserRpcError('invalid_args') };
  if (!uid || !cid) return { ok: false, error: 'invalid_args' };
  if (typeof saasCurrentUser !== 'undefined' && saasCurrentUser && Number(saasCurrentUser.id) === uid) {
    return { ok: false, error: _mapCompanyUserRpcError('self_delete') };
  }
  try {
    var rpc = await _sbClient.rpc('saas_delete_company_user', {
      p_user_id: uid,
      p_company_id: cid
    });
    if (!rpc.error && rpc.data && rpc.data.ok === true) return { ok: true };
    if (!rpc.error && rpc.data && rpc.data.ok === false) {
      return { ok: false, error: _mapCompanyUserRpcError(rpc.data.error) };
    }
    if (rpc.error && !/Could not find the function|42883|PGRST202/i.test(rpc.error.message || '')) {
      console.warn('sb_deleteCompanyUser rpc:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_error' };
    }
    var del = await _sbClient
      .from('saas_users')
      .delete({ count: 'exact' })
      .eq('id', uid)
      .eq('company_id', cid)
      .neq('role', 'super_admin');
    if (del.error) {
      console.warn('sb_deleteCompanyUser fallback:', del.error);
      return { ok: false, error: del.error.message || 'delete_failed' };
    }
    if (!del.count) return { ok: false, error: _mapCompanyUserRpcError('delete_failed') };
    return { ok: true };
  } catch (e) {
    console.warn('sb_deleteCompanyUser:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

// ======= SaaS Users (Company Admins) =======
async function sb_getSaasUsers(companyId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  let q = _sbClient.from('saas_users').select('id, username, email, role, company_id, is_active, last_login, created_at');
  if (companyId) q = q.eq('company_id', companyId);
  const { data, error } = await q.order('id');
  if (error) { console.error('sb_getSaasUsers:', error); return null; }
  return data;
}

async function sb_upsertSaasUser(user) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  var cid = user.company_id ? parseInt(user.company_id, 10) : 0;
  var role = user.role || 'company_admin';
  if (cid && (role === 'company_admin' || role === 'company_user')) {
    var rpcRes = await sb_upsertCompanyUser({
      id: user.id,
      username: user.username,
      display_name: user.display_name || user.username || '',
      email: user.email || '',
      password: user.password,
      role: role,
      permissions: user.permissions,
      is_active: user.is_active
    }, cid);
    if (rpcRes.ok) {
      return rpcRes.user || {
        id: user.id,
        username: user.username,
        role: role,
        company_id: cid
      };
    }
    console.error('sb_upsertSaasUser:', rpcRes.error);
    return null;
  }
  const row = {
    username:      user.username,
    email:         user.email || null,
    password_hash: user.password ? _saasHashPassword(user.password) : undefined,
    role:          role,
    company_id:    user.company_id || null,
    is_active:     user.is_active !== false
  };
  if (!row.password_hash) delete row.password_hash;
  if (user.id) row.id = user.id;
  const { data, error } = await _sbClient
    .from('saas_users')
    .upsert(row, { onConflict: 'username' })
    .select()
    .single();
  if (error) { console.error('sb_upsertSaasUser:', error); return null; }
  if (user.password && data && data.id && typeof AuthApi !== 'undefined' && AuthApi.setPasswordBcrypt) {
    await AuthApi.setPasswordBcrypt(data.id, user.password);
  }
  return data;
}

async function sb_updateSaasAccount(userId, fields) {
  if (!userId || !fields) return { ok: false, error: 'بيانات غير صالحة' };
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'انتهت جلسة الدخول — سجّل الدخول مرة أخرى' };

  var uid = parseInt(userId, 10);
  if (!uid) return { ok: false, error: 'بيانات غير صالحة' };

  var username = fields.username != null ? String(fields.username).trim() : null;
  var email = fields.email != null ? String(fields.email).trim() : null;
  var password = fields.password ? String(fields.password) : null;

  if (username && username.length < 3) return { ok: false, error: 'اسم المستخدم 3 أحرف على الأقل' };
  if (password && password.length > 0 && password.length < 6) {
    return { ok: false, error: 'كلمة المرور 6 أحرف على الأقل' };
  }

  var errMap = {
    invalid_args: 'بيانات غير صالحة',
    forbidden: 'غير مصرح',
    self_only: 'يمكنك تحديث حسابك فقط',
    user_not_found: 'المستخدم غير موجود',
    username_taken: 'اسم المستخدم مستخدم مسبقاً',
    password_hash_failed: 'فشل تشفير كلمة المرور — تواصل مع الدعم الفني',
    permission_denied: 'لا تملك صلاحية تنفيذ هذه العملية'
  };

  var displayName = fields.display_name != null ? String(fields.display_name).trim() : null;
  var jobTitle = fields.job_title != null ? String(fields.job_title).trim() : null;

  try {
    var rpc = await _sbClient.rpc('saas_update_saas_account', {
      p_user_id: uid,
      p_username: username || null,
      p_email: email,
      p_password: password || null,
      p_display_name: displayName,
      p_job_title: jobTitle
    });

    if (!rpc.error && rpc.data && rpc.data.ok === true) {
      return { ok: true, data: rpc.data.user || { username: username, email: email } };
    }
    if (!rpc.error && rpc.data && rpc.data.ok === false) {
      return { ok: false, error: errMap[rpc.data.error] || rpc.data.error };
    }

    var rpcMissing = rpc.error && /Could not find the function|42883|PGRST202/i.test(rpc.error.message || '');

    if (!rpcMissing && rpc.error) {
      console.warn('sb_updateSaasAccount rpc:', rpc.error);
      return { ok: false, error: rpc.error.message || 'rpc_error' };
    }

    if (typeof saasCurrentUser !== 'undefined' && saasCurrentUser) {
      if (saasCurrentUser.role !== 'super_admin') return { ok: false, error: 'غير مصرح' };
      if (Number(saasCurrentUser.id) !== uid) return { ok: false, error: 'يمكنك تحديث حسابك فقط' };
    }

    var patch = { updated_at: new Date().toISOString() };
    if (username) patch.username = username.toLowerCase();
    if (email !== null && email !== undefined) patch.email = email || null;

    var upd = await _sbClient
      .from('saas_users')
      .update(patch)
      .eq('id', uid)
      .eq('role', 'super_admin')
      .select('id, username, email, role')
      .maybeSingle();

    if (upd.error) {
      if (upd.error.code === '23505') return { ok: false, error: 'اسم المستخدم مستخدم مسبقاً' };
      console.warn('sb_updateSaasAccount fallback:', upd.error);
      return { ok: false, error: upd.error.message || 'update_failed' };
    }
    if (!upd.data) return { ok: false, error: 'المستخدم غير موجود' };

    if (password && password.length >= 6) {
      var pwdOk = false;
      if (typeof AuthApi !== 'undefined' && AuthApi.setPasswordBcrypt) {
        pwdOk = await AuthApi.setPasswordBcrypt(uid, password);
      }
      if (!pwdOk) {
        return {
          ok: false,
          error: 'تعذّر تحديث كلمة المرور — تواصل مع الدعم الفني'
        };
      }
    }

    return { ok: true, data: upd.data };
  } catch (e) {
    console.warn('sb_updateSaasAccount:', e);
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_deleteSaasUser(userId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  const { error } = await _sbClient.from('saas_users').delete().eq('id', userId);
  if (error) { console.error('sb_deleteSaasUser:', error); return false; }
  return true;
}

async function sb_listSuperAdmins() {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client', data: [] };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'auth', data: [] };
  try {
    var rpc = await _sbClient.rpc('saas_list_super_admins');
    if (rpc.error) return { ok: false, error: rpc.error.message || 'rpc_error', data: [] };
    if (!rpc.data || rpc.data.ok !== true) {
      return { ok: false, error: (rpc.data && rpc.data.error) || 'rpc_failed', data: [] };
    }
    return { ok: true, data: rpc.data.data || [] };
  } catch (e) {
    return { ok: false, error: e.message || 'exception', data: [] };
  }
}

async function sb_upsertSuperAdmin(payload) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'auth' };
  var errMap = {
    permission_denied: 'لا تملك صلاحية إدارة الفريق',
    username_taken: 'اسم المستخدم مستخدم مسبقاً',
    username_required: 'اسم المستخدم 3 أحرف على الأقل',
    password_required: 'كلمة المرور 6 أحرف على الأقل',
    user_not_found: 'المستخدم غير موجود'
  };
  try {
    var rpc = await _sbClient.rpc('saas_upsert_super_admin', { p_payload: payload || {} });
    if (rpc.error) return { ok: false, error: rpc.error.message || 'rpc_error' };
    if (!rpc.data || rpc.data.ok !== true) {
      return { ok: false, error: errMap[rpc.data && rpc.data.error] || (rpc.data && rpc.data.error) || 'rpc_failed' };
    }
    return { ok: true, data: rpc.data.data || null };
  } catch (e) {
    return { ok: false, error: e.message || 'exception' };
  }
}

async function sb_deleteSuperAdmin(userId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return { ok: false, error: 'no_client' };
  if (!(await ensureSbAuthForWrite())) return { ok: false, error: 'auth' };
  var errMap = {
    permission_denied: 'لا تملك صلاحية إدارة الفريق',
    cannot_delete_self: 'لا يمكنك حذف حسابك',
    last_super_admin: 'لا يمكن حذف آخر سوبر أدمن نشط',
    user_not_found: 'المستخدم غير موجود'
  };
  try {
    var rpc = await _sbClient.rpc('saas_delete_super_admin', { p_user_id: parseInt(userId, 10) });
    if (rpc.error) return { ok: false, error: rpc.error.message || 'rpc_error' };
    if (!rpc.data || rpc.data.ok !== true) {
      return { ok: false, error: errMap[rpc.data && rpc.data.error] || (rpc.data && rpc.data.error) || 'rpc_failed' };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message || 'exception' };
  }
}

if (typeof window !== 'undefined') {
  window.sb_listSuperAdmins = sb_listSuperAdmins;
  window.sb_upsertSuperAdmin = sb_upsertSuperAdmin;
  window.sb_deleteSuperAdmin = sb_deleteSuperAdmin;
}

// Modify existing getEmployees/getAttendance to respect company_id filter

// Patch company_id on writes
var _orig_mapEmployeeToDb = mapEmployeeToDb;
mapEmployeeToDb = function (emp) {
  var row = _orig_mapEmployeeToDb(emp);
  row.company_id = resolveActiveCompanyId(emp);
  return row;
};
var _orig_mapAttToDb = mapAttToDb;
mapAttToDb = function (rec) {
  var row = _orig_mapAttToDb(rec);
  row.company_id = resolveActiveCompanyId(rec);
  return row;
};
var _orig_mapAttFromDb = mapAttFromDb;
mapAttFromDb = function (row) {
  var rec = _orig_mapAttFromDb(row);
  rec.company_id = row.company_id || null;
  return rec;
};
var _orig_mapEmployeeFromDb = mapEmployeeFromDb;
mapEmployeeFromDb = function (row) {
  var emp = _orig_mapEmployeeFromDb(row);
  emp.company_id = row.company_id || null;
  if (typeof normalizeEmployeeSalaryFields === 'function') normalizeEmployeeSalaryFields(emp);
  return emp;
};

// ======= Data Mappers =======
function mapEmployeeFromDb(row) {
  return {
    id:           row.id,
    name:         row.name,
    dept:         row.dept,
    role:         row.role,
    phone:        row.phone || '—',
    salary:       row.salary || 0,
    salaryType:   row.salary_type || 'monthly',
    salaryHalf:   row.salary_half || 0,
    dailyRate:    row.daily_rate || 0,
    days:         row.days || 0,
    lateMin:      row.late_min || 0,
    checkIn:      formatDbTime(row.check_in) || '08:00',
    checkOut:     formatDbTime(row.check_out) || '17:00',
    openHours:    row.open_hours === true,
    remoteAttend: row.remote_attend === true,
    includeOvertimeInSalary: row.include_overtime_in_salary === true,
    salStatus:    row.sal_status || 'معلق',
    salBonus:     row.sal_bonus || 0,
    salDeletedPeriod: row.sal_deleted_period || '',
    avatarUrl:    row.avatar_url || '',
    company_id:   row.company_id != null ? row.company_id : undefined,
    devices: (row.employee_devices || []).map(d => ({
      slot: d.slot, label: d.label,
      ip: d.ip || '', fingerprint: d.fingerprint || '',
      pin: d.pin || '', token: d.token || '',
      tokenCreatedAt: d.token_created_at || '',
      tokenUsedAt: d.token_used_at || '',
      deviceInfo: d.device_info || null,
      linked_at: d.linked_at || '',
      last_login: d.last_login || '',
      barcode: 'ATT-' + row.id + '-D' + d.slot
    }))
  };
}

function mapEmployeeToDb(emp) {
  var salaryType = emp.salaryType || 'monthly';
  var salary = typeof parseExactInt === 'function' ? parseExactInt(emp.salary, 0) : (parseInt(emp.salary, 10) || 0);
  var salaryHalf = salaryType === 'biweekly'
    ? (typeof parseExactInt === 'function' ? parseExactInt(emp.salaryHalf, 0) : (parseInt(emp.salaryHalf, 10) || 0))
    : 0;
  var dailyRate = typeof parseExactInt === 'function' ? parseExactInt(emp.dailyRate, 0) : (parseInt(emp.dailyRate, 10) || 0);
  return {
    id:           emp.id || undefined,
    name:         emp.name,
    dept:         emp.dept,
    role:         emp.role,
    phone:        emp.phone || '—',
    salary:       salary,
    salary_type:  salaryType,
    salary_half:  salaryHalf,
    daily_rate:   dailyRate,
    days:         typeof parseExactInt === 'function' ? parseExactInt(emp.days, 0) : (emp.days || 0),
    late_min:     typeof parseExactInt === 'function' ? parseExactInt(emp.lateMin, 0) : (emp.lateMin || 0),
    check_in:     emp.checkIn || '08:00',
    check_out:    emp.checkOut || '17:00',
    open_hours:   emp.openHours === true,
    remote_attend: emp.remoteAttend === true,
    include_overtime_in_salary: emp.includeOvertimeInSalary === true,
    sal_status:   emp.salStatus || 'معلق',
    sal_bonus:    typeof parseExactInt === 'function' ? parseExactInt(emp.salBonus, 0) : (emp.salBonus || 0),
    sal_deleted_period: emp.salDeletedPeriod || '',
    avatar_url:   emp.avatarUrl || null
  };
}

function mapAttFromDb(row) {
  return {
    id:      row.id,
    empId:   row.employee_id,
    emp:     row.emp_name,
    dept:    row.dept,
    date:    row.date_label,
    dateIso: row.date_iso,
    ci:      row.check_in || '—',
    co:      row.check_out || '—',
    hrs:     row.hours || '—',
    late:    row.late || '—',
    ot:      row.overtime || '—',
    status:  row.status || 'غياب',
    company_id: row.company_id != null ? row.company_id : undefined
  };
}

function mapAttToDb(rec) {
  return {
    id:           rec.id || undefined,
    employee_id:  rec.empId,
    emp_name:     rec.emp,
    dept:         rec.dept,
    date_label:   rec.date,
    date_iso:     rec.dateIso || null,
    check_in:     rec.ci !== '—' ? rec.ci : null,
    check_out:    rec.co !== '—' ? rec.co : null,
    hours:        rec.hrs !== '—' ? rec.hrs : null,
    late:         rec.late !== '—' ? rec.late : null,
    overtime:     rec.ot !== '—' ? rec.ot : null,
    status:       rec.status || 'غياب',
    company_id:   rec.company_id != null ? rec.company_id : resolveActiveCompanyId(rec)
  };
}

document.addEventListener('DOMContentLoaded', function () {
  setTimeout(async function () {
    initSupabase();
    if (typeof hydratePlatformAnnouncementsFromCache === 'function') {
      hydratePlatformAnnouncementsFromCache();
    }
    await setupSupabaseRealtime();
    if (typeof sb_fetchPublicSupportWhatsApp === 'function') {
      var wa = await sb_fetchPublicSupportWhatsApp();
      if (wa) {
        window.platformSettings = window.platformSettings || {};
        window.platformSettings.supportWhatsApp = wa;
        try { localStorage.setItem('platform_support_whatsapp', wa); } catch (e) {}
      }
    }
    if (typeof currentUser !== 'undefined' && currentUser) return;
    var app = document.getElementById('app');
    if (app && app.style.display === 'block') return;
    if (typeof runAutoLoginRestore === 'function') await runAutoLoginRestore();
  }, 300);
});

// ============================================================
// KYNO Leaves & Notifications — Supabase Integration
// ============================================================

async function sb_upsertLeave(leave) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var payload = {
      emp_id:     leave.empId,
      company_id: leave.company_id || null,
      leave_type: leave.leaveType,
      from_date:  leave.fromDate,
      to_date:    leave.toDate || null,
      multiplier: leave.leaveType === 'absence_mult' ? (leave.absenceDays || leave.multiplier || 1) : (leave.multiplier || 1),
      note:       leave.note || '',
      leave_ref:  leave.id
    };
    if (leave._remoteId) payload.id = leave._remoteId;
    var rpc = await _sbClient.rpc('saas_upsert_leave', { p_payload: payload });
    if (rpc.error) { console.warn('sb_upsertLeave:', rpc.error); return null; }
    return rpc.data;
  } catch(e) { console.warn('sb_upsertLeave:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_upsertLeave = sb_upsertLeave;

async function sb_deleteLeave(remoteId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_delete_leave', { p_leave_id: remoteId });
    if (rpc.error) { console.warn('sb_deleteLeave:', rpc.error); return null; }
    return rpc.data;
  } catch(e) { console.warn('sb_deleteLeave:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_deleteLeave = sb_deleteLeave;

async function sb_deleteLeaveByRef(leaveRef) {
  if (!leaveRef) return null;
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var res = await sb_getLeaves();
    if (!res || !res.ok || !Array.isArray(res.data)) return null;
    var row = res.data.find(function (r) { return r && r.leave_ref === leaveRef; });
    if (!row || !row.id) return null;
    return sb_deleteLeave(row.id);
  } catch (e) {
    console.warn('sb_deleteLeaveByRef:', e);
    return null;
  }
}
if (typeof window !== 'undefined') window.sb_deleteLeaveByRef = sb_deleteLeaveByRef;

async function sb_getLeaves(empId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    if (empId && typeof currentUser !== 'undefined' && currentUser === 'emp') {
      var fp = getDeviceFingerprintForRpc();
      var token = null;
      var localEmp = (window.employees || []).find(function (e) { return e && e.id === empId; });
      if (localEmp && typeof getDevice === 'function') {
        var slot = parseInt(localStorage.getItem('basma_registered_slot') || '0', 10) || 1;
        var dev = getDevice(localEmp, slot);
        if (dev && dev.token) token = dev.token;
      }
      var empRpc = await _sbClient.rpc('saas_fetch_employee_leaves', {
        p_employee_id: empId,
        p_fingerprint: fp || null,
        p_token: token || null,
        p_limit: 120
      });
      if (empRpc.error) { console.warn('sb_getLeaves employee:', empRpc.error); return null; }
      if (!empRpc.data || empRpc.data.ok === false) return null;
      return { ok: true, data: empRpc.data.data || [] };
    }
    var params = empId ? { p_employee_id: empId } : {};
    var rpc = await _sbClient.rpc('saas_get_leaves', params);
    if (rpc.error) { console.warn('sb_getLeaves:', rpc.error); return null; }
    if (!rpc.data || rpc.data.ok === false) return null;
    return { ok: true, data: rpc.data.data || [] };
  } catch(e) { console.warn('sb_getLeaves:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_getLeaves = sb_getLeaves;

async function sb_addEmployeeNotification(empId, title, body, type, ref) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_add_employee_notification', {
      p_employee_id: empId,
      p_title: title,
      p_body:  body  || '',
      p_type:  type  || 'info',
      p_ref:   ref   || null
    });
    if (rpc.error) { console.warn('sb_addEmployeeNotification:', rpc.error); return null; }
    return rpc.data;
  } catch(e) { console.warn('sb_addEmployeeNotification:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_addEmployeeNotification = sb_addEmployeeNotification;

async function sb_getEmployeeNotifications(empId) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var params = empId ? { p_employee_id: empId } : {};
    var rpc = await _sbClient.rpc('saas_get_employee_notifications', params);
    if (rpc.error) { console.warn('sb_getEmployeeNotifications:', rpc.error); return null; }
    if (!rpc.data || rpc.data.ok === false) return null;
    return { ok: true, data: rpc.data.data || [] };
  } catch(e) { console.warn('sb_getEmployeeNotifications:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_getEmployeeNotifications = sb_getEmployeeNotifications;

async function sb_markEmpNotifRead(notifRef, options) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (notifRef == null || notifRef === '') return null;
  options = options || {};
  try {
    var params = {};
    var refStr = String(notifRef);
    if (/^\d+$/.test(refStr)) {
      params.p_notif_id = parseInt(refStr, 10);
    } else {
      params.p_notif_ref = refStr;
    }

    var hasAuthUser = false;
    try {
      if (typeof AuthApi !== 'undefined' && typeof AuthApi.ensureValidSession === 'function') {
        hasAuthUser = await AuthApi.ensureValidSession({ skipNetworkUser: true });
      }
    } catch (e) { /* ignore */ }
    if (!hasAuthUser && typeof window !== 'undefined' && window.saasCurrentUser && window.saasCurrentUser.id) {
      hasAuthUser = true;
    }

    var empId = options.employeeId || parseInt((typeof localStorage !== 'undefined' && localStorage.getItem('basma_registered_emp')) || '0', 10);
    var fp = typeof getDeviceFingerprintForRpc === 'function' ? getDeviceFingerprintForRpc() : null;
    var token = options.token || null;

    var rpcName = 'saas_mark_emp_notification_read';
    if (!hasAuthUser && empId > 0 && (fp || token)) {
      rpcName = 'saas_mark_employee_portal_notification_read';
      params = {
        p_employee_id: empId,
        p_fingerprint: fp || null,
        p_token: token || null
      };
      if (/^\d+$/.test(refStr)) {
        params.p_notif_id = parseInt(refStr, 10);
      } else {
        params.p_notif_ref = refStr;
      }
    }

    var rpc = await _sbClient.rpc(rpcName, params);
    if (rpc.error) { console.warn('sb_markEmpNotifRead:', rpc.error); return null; }
    return rpc.data;
  } catch(e) { console.warn('sb_markEmpNotifRead:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_markEmpNotifRead = sb_markEmpNotifRead;

async function sb_addAdminNotification(title, body, type) {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  if (!(await ensureSbAuthForWrite())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_add_admin_notification', {
      p_title: title,
      p_body:  body || '',
      p_type:  type || 'info'
    });
    if (rpc.error) { console.warn('sb_addAdminNotification:', rpc.error); return null; }
    return rpc.data;
  } catch(e) { console.warn('sb_addAdminNotification:', e); return null; }
}
if (typeof window !== 'undefined') window.sb_addAdminNotification = sb_addAdminNotification;

async function sb_getSuperAdminPrefs() {
  if (!_sbClient && !(await ensureSupabaseClient())) return null;
  try {
    var rpc = await _sbClient.rpc('saas_get_super_admin_prefs', {});
    if (rpc.error) {
      if (rpc.error.code === '57014') {
        console.warn('sb_getSuperAdminPrefs timeout: using empty prefs until migration 072 is applied');
        return {};
      }
      console.warn('sb_getSuperAdminPrefs:', rpc.error);
      return null;
    }
    var data = rpc.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { data = null; }
    }
    if (!data || data.ok === false) return null;
    return data.prefs || {};
  } catch (e) { console.warn('sb_getSuperAdminPrefs:', e); return null; }
}

function slimSuperAdminActivityLogForCloud(logArr, max) {
  max = max || 120;
  if (!Array.isArray(logArr)) return [];
  return logArr.slice(0, max).map(function (entry) {
    if (!entry || typeof entry !== 'object') return entry;
    return {
      id: entry.id,
      ts: entry.ts,
      action: entry.action,
      category: entry.category,
      actorName: entry.actorName,
      actorRole: entry.actorRole,
      details: String(entry.details || '').slice(0, 240),
      targetName: String(entry.targetName || '').slice(0, 80),
      read: entry.read === true,
      companyId: entry.companyId,
      scope: entry.scope
    };
  });
}

function normalizeSuperAdminPrefsPayload(prefs) {
  var payload = prefs && typeof prefs === 'object' ? Object.assign({}, prefs) : {};
  if (payload.activity_log != null) {
    if (typeof payload.activity_log === 'string') {
      try { payload.activity_log = JSON.parse(payload.activity_log); } catch (e) { payload.activity_log = []; }
    }
    if (Array.isArray(payload.activity_log)) {
      payload.activity_log = slimSuperAdminActivityLogForCloud(payload.activity_log, 120);
    }
  }
  return payload;
}

async function sb_saveSuperAdminPrefs(prefs) {
  if (!_sbClient && !(await ensureSupabaseClient())) return false;
  if (!(await ensureSbAuthForWrite())) return false;
  try {
    var payload = normalizeSuperAdminPrefsPayload(prefs);
    var rpc = await _sbClient.rpc('saas_upsert_super_admin_prefs', { p_prefs: payload });
    if (rpc.error) {
      if (rpc.error.code === '57014' && payload.activity_log) {
        payload.activity_log = slimSuperAdminActivityLogForCloud(payload.activity_log, 60);
        rpc = await _sbClient.rpc('saas_upsert_super_admin_prefs', { p_prefs: payload });
      }
      if (rpc.error) {
        console.warn('sb_saveSuperAdminPrefs:', rpc.error);
        return false;
      }
    }
    var data = rpc.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { data = null; }
    }
    return !!(data && data.ok);
  } catch (e) { console.warn('sb_saveSuperAdminPrefs:', e); return false; }
}

if (typeof window !== 'undefined') {
  window.sb_getSuperAdminPrefs = sb_getSuperAdminPrefs;
  window.sb_saveSuperAdminPrefs = sb_saveSuperAdminPrefs;
  window.slimSuperAdminActivityLogForCloud = slimSuperAdminActivityLogForCloud;
  window.sb_recordClientAudit = sb_recordClientAudit;
  window.sb_exportCompanyData = sb_exportCompanyData;
  window.sb_importCompanySettings = sb_importCompanySettings;
  window.sb_importCompanyFull = sb_importCompanyFull;
  window.sb_securityHealthReport = sb_securityHealthReport;
  window.sb_systemMonitoringSnapshot = sb_systemMonitoringSnapshot;
  window.sb_superExportCompany = sb_superExportCompany;
  window.sb_superListAuditLogs = sb_superListAuditLogs;
  window.sb_deleteEmployee = sb_deleteEmployee;
  window.sb_getLastEmployeeDeleteError = sb_getLastEmployeeDeleteError;
  window.mapSbEmployeeDeleteError = mapSbEmployeeDeleteError;
  window.sb_countCompanyEmployees = sb_countCompanyEmployees;
  window.sb_isPermanentEmployeeSaveError = sb_isPermanentEmployeeSaveError;
  window.ensureSbAuthForWrite = ensureSbAuthForWrite;
  window.ensureSbAuthForRead = ensureSbAuthForRead;
}
