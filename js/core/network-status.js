/**
 * KYNO — حالة الشبكة والمزامنة (مسؤول + موظف)
 * فحص فعلي للسحابة — REST / Auth health / RPC (بدون app_settings للموظف).
 */
(function (global) {
  'use strict';

  var THRESHOLDS = { excellent: 400, good: 900, fair: 2000 };
  var _state = {
    online: true,
    quality: 'unknown',
    latencyMs: null,
    label: 'جارٍ الفحص...',
    detail: '',
    checking: false,
    lastCheckAt: null
  };
  var _initDone = false;

  function isBrowserOnline() {
    return typeof navigator === 'undefined' ? true : navigator.onLine !== false;
  }

  function resolveSupabaseBaseUrl() {
    if (global.BasmaConfig && typeof global.BasmaConfig.supabaseUrl === 'function') {
      var u = global.BasmaConfig.supabaseUrl();
      if (u) return String(u).replace(/\/$/, '');
    }
    if (typeof global.getSupabaseUrl === 'function') {
      var legacy = global.getSupabaseUrl();
      if (legacy) return String(legacy).replace(/\/$/, '');
    }
    return '';
  }

  function resolveSupabaseAnonKey() {
    if (global.BasmaConfig && typeof global.BasmaConfig.supabaseAnonKey === 'function') {
      var k = global.BasmaConfig.supabaseAnonKey();
      if (k) return k;
    }
    if (typeof global.getSupabaseAnonKey === 'function') {
      return global.getSupabaseAnonKey();
    }
    return '';
  }

  function isTransportError(err) {
    if (!err) return false;
    var msg = String(err.message || err || '').toLowerCase();
    return msg.indexOf('failed to fetch') >= 0
      || msg.indexOf('networkerror') >= 0
      || msg.indexOf('network request failed') >= 0
      || msg.indexOf('load failed') >= 0
      || msg.indexOf('timeout') >= 0
      || msg.indexOf('connection closed') >= 0
      || msg.indexOf('aborted') >= 0;
  }

  function qualityFromLatency(ms, hadError) {
    if (!isBrowserOnline()) {
      return { quality: 'offline', label: 'غير متصل', detail: 'لا يوجد اتصال بالإنترنت' };
    }
    if (hadError) {
      return { quality: 'offline', label: 'غير متصل', detail: 'تعذّر الوصول للسحابة' };
    }
    if (!Number.isFinite(ms)) {
      return { quality: 'good', label: 'متصل', detail: 'الاتصال متاح' };
    }
    if (ms <= THRESHOLDS.excellent) {
      return { quality: 'excellent', label: 'شبكة ممتازة', detail: ms + ' ms' };
    }
    if (ms <= THRESHOLDS.good) {
      return { quality: 'good', label: 'شبكة جيدة', detail: ms + ' ms' };
    }
    if (ms <= THRESHOLDS.fair) {
      return { quality: 'fair', label: 'شبكة مقبولة', detail: ms + ' ms' };
    }
    return { quality: 'weak', label: 'شبكة ضعيفة', detail: ms + ' ms' };
  }

  function shouldShowNetworkUi() {
    var loginPage = document.getElementById('login-page');
    if (loginPage && loginPage.style.display !== 'none') return false;
    return global.currentUser === 'admin' || global.currentUser === 'emp';
  }

  function applyUi() {
    var el = document.getElementById('topbar-network-status');
    if (!el) return;
    if (!shouldShowNetworkUi()) {
      el.style.display = 'none';
      return;
    }
    el.style.display = '';
    el.classList.remove('net-excellent', 'net-good', 'net-fair', 'net-weak', 'net-offline', 'net-unknown', 'net-checking');
    el.classList.add('net-' + (_state.checking ? 'checking' : _state.quality));
    var label = el.querySelector('.network-status-label');
    var detail = el.querySelector('.network-status-detail');
    var btn = el.querySelector('.network-status-refresh');
    if (label) label.textContent = _state.checking ? 'جارٍ الفحص...' : _state.label;
    if (detail) detail.textContent = _state.checking ? '' : (_state.detail || '');
    if (btn) btn.disabled = !!_state.checking;
    el.setAttribute('title', (_state.label || '') + (_state.detail ? ' — ' + _state.detail : ''));
  }

  async function ensureClient() {
    if (global._sbClient) return global._sbClient;
    if (typeof global.initSupabase === 'function') global.initSupabase();
    if (typeof global.ensureSupabaseClient === 'function') {
      await global.ensureSupabaseClient();
    }
    return global._sbClient || null;
  }

  async function probeViaRestHead() {
    var base = resolveSupabaseBaseUrl();
    var key = resolveSupabaseAnonKey();
    if (!base || !key) return { ok: false, ms: null, transport: true };
    var start = performance.now();
    try {
      var res = await fetch(base + '/rest/v1/', {
        method: 'HEAD',
        cache: 'no-store',
        mode: 'cors',
        headers: { apikey: key, Authorization: 'Bearer ' + key }
      });
      return {
        ok: !!(res && res.status > 0 && res.status < 600),
        ms: Math.round(performance.now() - start),
        transport: false
      };
    } catch (e) {
      return { ok: false, ms: Math.round(performance.now() - start), transport: true };
    }
  }

  async function probeViaAuthHealth() {
    var base = resolveSupabaseBaseUrl();
    if (!base) return { ok: false, ms: null, transport: true };
    var start = performance.now();
    try {
      var res = await fetch(base + '/auth/v1/health', {
        method: 'GET',
        cache: 'no-store',
        mode: 'cors'
      });
      return {
        ok: !!(res && res.status > 0 && res.status < 600),
        ms: Math.round(performance.now() - start),
        transport: false
      };
    } catch (e) {
      return { ok: false, ms: Math.round(performance.now() - start), transport: true };
    }
  }

  async function probeReachability() {
    var rest = await probeViaRestHead();
    if (rest.ok) return rest;
    var health = await probeViaAuthHealth();
    if (health.ok) return health;
    if (!rest.transport && !health.transport) return rest;
    if (!rest.transport) return rest;
    if (!health.transport) return health;
    return {
      ok: false,
      ms: Math.min(rest.ms || 9999, health.ms || 9999),
      transport: true
    };
  }

  async function probeEmployeeRpc() {
    var empId = parseInt(global.loggedInEmpId || '0', 10);
    if (!empId) return null;
    var client = await ensureClient();
    if (!client) return { ok: false, transport: true };
    var start = performance.now();
    try {
      var rpc = await client.rpc('saas_employee_login_gate', { p_employee_id: empId });
      var ms = Math.round(performance.now() - start);
      if (rpc.error && isTransportError(rpc.error)) {
        return { ok: false, ms: ms, transport: true };
      }
      return { ok: true, ms: ms, transport: false };
    } catch (e) {
      return {
        ok: false,
        ms: Math.round(performance.now() - start),
        transport: isTransportError(e)
      };
    }
  }

  async function probeAdminRpc() {
    var client = await ensureClient();
    if (!client) return probeReachability();
    var start = performance.now();
    try {
      if (typeof global.ensureSbAuthForRead === 'function') {
        await global.ensureSbAuthForRead();
      }
      var res = await client.from('app_settings').select('key').limit(1);
      var ms = Math.round(performance.now() - start);
      if (res.error && isTransportError(res.error)) {
        return { ok: false, ms: ms, transport: true };
      }
      if (res.error) {
        return probeReachability();
      }
      return { ok: true, ms: ms, transport: false };
    } catch (e) {
      if (isTransportError(e)) {
        return { ok: false, ms: Math.round(performance.now() - start), transport: true };
      }
      return probeReachability();
    }
  }

  function runEmployeeSyncRecovery() {
    if (global.currentUser !== 'emp') return;
    if (typeof global.refreshLoggedInEmployeeAttendance === 'function') {
      global.refreshLoggedInEmployeeAttendance({ limit: 120 }).catch(function (e) {
        console.warn('network recovery attendance:', e);
      });
    }
    if (typeof global.schedulePendingSyncRetry === 'function') {
      global.schedulePendingSyncRetry();
    }
    if (global.BasmaCloud && global.BasmaCloud.flushPendingToCloud) {
      global.BasmaCloud.flushPendingToCloud({ reason: 'network-recovery', force: true }).catch(function () {});
    }
  }

  async function probe(force) {
    if (_state.checking && !force) return _state;
    _state.checking = true;
    applyUi();

    if (!isBrowserOnline()) {
      _state.online = false;
      _state.quality = 'offline';
      _state.latencyMs = null;
      _state.label = 'غير متصل';
      _state.detail = 'تحقق من Wi-Fi أو بيانات الهاتف';
      _state.checking = false;
      _state.lastCheckAt = Date.now();
      applyUi();
      return _state;
    }

    var wasOffline = _state.quality === 'offline';
    var result = null;

    if (global.currentUser === 'emp') {
      result = await probeReachability();
      if (global.loggedInEmpId) {
        var empRpc = await probeEmployeeRpc();
        if (empRpc && empRpc.ok) {
          result = empRpc;
        } else if (result && result.ok && empRpc && Number.isFinite(empRpc.ms)) {
          result.ms = Math.max(result.ms || 0, empRpc.ms);
        }
      }
    } else if (global.currentUser === 'admin') {
      result = await probeAdminRpc();
    } else {
      result = await probeReachability();
    }

    var hadError = !result || !result.ok;
    var q = qualityFromLatency(result && result.ms, hadError);
    _state.online = !hadError;
    _state.quality = q.quality;
    _state.latencyMs = hadError ? null : (result && result.ms);
    _state.label = q.label;
    _state.detail = hadError ? 'تعذّر الوصول للسحابة — اضغط تحديث ↻' : q.detail;
    _state.checking = false;
    _state.lastCheckAt = Date.now();
    applyUi();

    if (global.BasmaCloud && global.BasmaCloud.updateConnectivityBanner) {
      global.BasmaCloud.updateConnectivityBanner();
    }
    if (typeof global.applyEmpPortalSubscriptionLock === 'function') {
      try { global.applyEmpPortalSubscriptionLock(); } catch (e) { /* ignore */ }
    }
    if (!hadError && (wasOffline || force) && global.currentUser === 'emp') {
      runEmployeeSyncRecovery();
    }
    return _state;
  }

  function init() {
    if (_initDone) return;
    _initDone = true;
    window.addEventListener('online', function () { probe(true); });
    window.addEventListener('offline', function () { probe(true); });
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) probe(true);
    });
    probe(false);
    setInterval(function () {
      if (_state.checking) return;
      probe(false);
    }, 60000);
  }

  global.BasmaNetworkStatus = {
    init: init,
    probe: probe,
    getState: function () { return Object.assign({}, _state); },
    applyUi: applyUi
  };
})(typeof window !== 'undefined' ? window : globalThis);
