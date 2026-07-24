/**
 * Auth API — Edge Functions + HttpOnly session cookie + Supabase Auth JWT (tenant RLS)
 */
(function (global) {
  'use strict';

  var _jwtCompanyId = undefined;
  var _jwtRole = null;

  function supabaseBase() {
    return global.BasmaConfig && BasmaConfig.supabaseUrl ? BasmaConfig.supabaseUrl() : '';
  }

  function anonKey() {
    return global.BasmaConfig && BasmaConfig.supabaseAnonKey ? BasmaConfig.supabaseAnonKey() : '';
  }

  function isCrossOriginDeployment() {
    try {
      var base = supabaseBase();
      if (!base || typeof location === 'undefined' || !location.origin) return false;
      if (base.charAt(0) === '/') return false;
      return new URL(base).origin !== location.origin;
    } catch (e) {
      return false;
    }
  }

  /** HttpOnly cookie session via Edge; JWT in memory only */
  function useCookies() {
    if (global.BasmaConfig && typeof BasmaConfig.get === 'function') {
      if (global.BasmaConfig.get('authUseCookies') === false) return false;
    }
    return true;
  }

  function edgeUrl(name) {
    var base = supabaseBase();
    if (!base) return '';
    if (base.charAt(0) === '/') {
      return base.replace(/\/$/, '') + '/functions/v1/' + name;
    }
    return base.replace(/\/$/, '') + '/functions/v1/' + name;
  }

  function sleep(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  async function edgeFetch(name, options) {
    var url = edgeUrl(name);
    var key = anonKey();
    if (!url || !key) return Promise.resolve(null);
    options = options || {};
    var headers = Object.assign(
      {
        apikey: key,
        Authorization: 'Bearer ' + key
      },
      options.headers || {}
    );
    var timeoutMs = options.timeoutMs != null ? options.timeoutMs : 45000;
    var maxAttempts = options.retryNetwork === false ? 1 : 3;
    var lastErr = null;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
      var timer = controller ? setTimeout(function () { controller.abort(); }, timeoutMs) : null;
      try {
        var res = await fetch(url, {
          method: options.method || 'GET',
          headers: headers,
          body: options.body,
          credentials: 'include',
          signal: controller ? controller.signal : undefined
        });
        if (timer) clearTimeout(timer);
        return res;
      } catch (err) {
        if (timer) clearTimeout(timer);
        lastErr = err;
        if (!isNetworkFetchError(err) || attempt >= maxAttempts - 1) throw err;
        await sleep(400 + attempt * 700);
      }
    }
    throw lastErr;
  }

  function getSupabaseClient() {
    return global._sbClient || null;
  }

  var _lastLoginError = null;

  function getLastLoginError() {
    return _lastLoginError;
  }

  function removeSupabaseAuthStorageKeys() {
    try {
      Object.keys(localStorage).forEach(function (k) {
        if (/^sb-[a-z0-9-]+-auth-token$/i.test(k)) localStorage.removeItem(k);
      });
    } catch (e) { /* ignore */ }
  }

  /**
   * مسح JWT محلياً بعد إبطال refresh token على الخادم (auth-logout Edge).
   */
  async function clearSupabaseSession() {
    global.__basmaSessionActive = false;
    var sb = getSupabaseClient();
    if (sb && sb.auth) {
      try {
        if (typeof sb.auth.stopAutoRefresh === 'function') {
          sb.auth.stopAutoRefresh();
        }
        var storage = sb.auth.storage;
        var storageKey = sb.auth.storageKey;
        if (storage && storageKey && typeof storage.removeItem === 'function') {
          await storage.removeItem(storageKey);
        }
      } catch (e2) {
        console.warn('clearSupabaseSession storage:', e2);
      }
      removeSupabaseAuthStorageKeys();
    }
    clearJwtContext();
  }

  function isNetworkFetchError(err) {
    if (!err) return false;
    var msg = String(err.message || err).toLowerCase();
    return err.name === 'TypeError' && (
      msg.indexOf('failed to fetch') >= 0 ||
      msg.indexOf('networkerror') >= 0 ||
      msg.indexOf('load failed') >= 0
    );
  }

  async function verifyCredentialsViaRpc(username, password) {
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      await ensureSupabaseClient(12);
    }
    var sb = getSupabaseClient();
    if (!sb) return null;
    var clientIp = null;
    if (typeof global.currentClientIp === 'string' && global.currentClientIp) {
      clientIp = global.currentClientIp;
    }
    try {
      var rpc = await sb.rpc('saas_verify_login', {
        p_username: String(username || '').trim().toLowerCase(),
        p_password: String(password || ''),
        p_ip: clientIp
      });
      if (rpc.error || !rpc.data) {
        if (rpc.error) console.warn('verifyCredentialsViaRpc:', rpc.error.message || rpc.error);
        return null;
      }
      if (rpc.data.error === 'rate_limited') {
        _lastLoginError = 'rate_limited';
        return null;
      }
      if (rpc.data.error === 'password_reset_required') {
        _lastLoginError = 'password_reset_required';
        return null;
      }
      return rpc.data;
    } catch (e) {
      console.warn('verifyCredentialsViaRpc:', e);
      if (isNetworkFetchError(e)) _lastLoginError = 'network_error';
      return null;
    }
  }

  async function forceResetPassword(username, currentPassword, newPassword) {
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      await ensureSupabaseClient(12);
    }
    var sb = getSupabaseClient();
    if (!sb) return { ok: false, error: 'no_client' };
    var clientIp = (typeof global.currentClientIp === 'string' && global.currentClientIp) ? global.currentClientIp : null;
    try {
      var rpc = await sb.rpc('saas_force_reset_password', {
        p_username: String(username || '').trim().toLowerCase(),
        p_current_password: String(currentPassword || ''),
        p_new_password: String(newPassword || ''),
        p_ip: clientIp
      });
      if (rpc.error) return { ok: false, error: rpc.error.message || 'rpc_error' };
      return rpc.data || { ok: false, error: 'empty_response' };
    } catch (e) {
      console.warn('forceResetPassword:', e);
      return { ok: false, error: 'network_error' };
    }
  }

  async function refreshJwtContext() {
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      await ensureSupabaseClient(12);
    }
    var sb = getSupabaseClient();
    if (!sb || !sb.auth || typeof sb.auth.getSession !== 'function') {
      _jwtCompanyId = undefined;
      _jwtRole = null;
      return false;
    }
    try {
      var res = await sb.auth.getSession();
      var u = res.data && res.data.session && res.data.session.user;
      if (!u) {
        _jwtCompanyId = undefined;
        _jwtRole = null;
        return false;
      }
      var meta = u.app_metadata || {};
      _jwtRole = meta.role || null;
      if (_jwtRole === 'super_admin') {
        _jwtCompanyId = null;
      } else if (meta.company_id != null && meta.company_id !== '') {
        var n = parseInt(meta.company_id, 10);
        _jwtCompanyId = n > 0 ? n : null;
      } else {
        _jwtCompanyId = null;
      }
      return true;
    } catch (e) {
      console.warn('refreshJwtContext:', e);
      return false;
    }
  }

  async function hasAuthenticatedSession() {
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      await ensureSupabaseClient(10);
    }
    var sb = getSupabaseClient();
    if (!sb || !sb.auth || typeof sb.auth.getSession !== 'function') return false;
    try {
      var res = await sb.auth.getSession();
      return !!(res.data && res.data.session && res.data.session.access_token);
    } catch (e) {
      return false;
    }
  }

  async function tryRefreshSupabaseSession(sb) {
    if (!sb || !sb.auth || typeof sb.auth.refreshSession !== 'function') return null;
    try {
      var current = await sb.auth.getSession();
      var existing = current.data && current.data.session;
      if (!existing || !existing.refresh_token) {
        return null;
      }
      var refreshed = await sb.auth.refreshSession();
      if (refreshed.error && !(refreshed.data && refreshed.data.session)) {
        var msg = String(refreshed.error.message || refreshed.error);
        if (!/auth session missing|session not found|invalid refresh token|refresh token/i.test(msg)) {
          console.warn('refreshSession:', msg);
        }
      }
      return refreshed.data && refreshed.data.session ? refreshed.data.session : null;
    } catch (e) {
      var errMsg = String(e && e.message ? e.message : e);
      if (!/auth session missing|session not found|invalid refresh token/i.test(errMsg)) {
        console.warn('tryRefreshSupabaseSession:', e);
      }
      return null;
    }
  }

  /** تجديد JWT قبل الكتابة إلى جداول RLS — محلي فقط (لا getUser شبكياً → يمنع 403) */
  async function ensureValidSession(options) {
    options = options || {};
    if (typeof window !== 'undefined' && window.__basmaLoggingOut) return false;
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      await ensureSupabaseClient(12);
    }
    var sb = getSupabaseClient();
    if (!sb || !sb.auth) return false;
    var skipNetwork = options.skipNetworkUser === true;
    try {
      var res = await sb.auth.getSession();
      var session = res.data && res.data.session;
      if (session && session.access_token) {
        var exp = session.expires_at;
        if (!skipNetwork && exp && exp * 1000 < Date.now() + 45000) {
          session = await tryRefreshSupabaseSession(sb);
        }
        if (session && session.access_token) {
          await refreshJwtContext();
          return true;
        }
      }
      if (!skipNetwork) {
        session = await tryRefreshSupabaseSession(sb);
        if (session && session.access_token) {
          await refreshJwtContext();
          return true;
        }
      }
      return false;
    } catch (e) {
      console.warn('ensureValidSession:', e);
      return false;
    }
  }

  /** استعادة JWT قبل أي كتابة للسحابة (حضور، إعدادات، إشعارات…) */
  async function refreshAuthSessionForWrite() {
    if (await ensureValidSession()) return true;
    var sb = getSupabaseClient();
    if (!sb || !sb.auth) return false;
    try {
      var snap = await sb.auth.getSession();
      if (snap.data && snap.data.session && snap.data.session.refresh_token) {
        var session = await tryRefreshSupabaseSession(sb);
        if (session && session.access_token) {
          await refreshJwtContext();
          if (await ensureValidSession()) return true;
        }
      }
    } catch (e) { /* ignore */ }
    var expectedUserId = null;
    if (typeof global.saasCurrentUser !== 'undefined' && global.saasCurrentUser && global.saasCurrentUser.id) {
      expectedUserId = global.saasCurrentUser.id;
    } else if (typeof global._saasCurrentUser !== 'undefined' && global._saasCurrentUser && global._saasCurrentUser.id) {
      expectedUserId = global._saasCurrentUser.id;
    }
    if (expectedUserId) {
      var fromJwt = await restoreSessionFromSupabaseJwt(expectedUserId);
      if (fromJwt && await ensureValidSession()) return true;
    }
    if (useCookies()) {
      var cookieUser = await restoreSessionViaCookie();
      if (cookieUser && await ensureValidSession()) return true;
    }
    return false;
  }

  /** null = super admin (all tenants); number = company; undefined = no JWT session yet */
  function getCompanyId() {
    return _jwtCompanyId;
  }

  function getRole() {
    return _jwtRole;
  }

  function clearJwtContext() {
    _jwtCompanyId = undefined;
    _jwtRole = null;
    _foreignSessionNotified = false;
  }

  async function applySupabaseAuthSession(tokens) {
    if (!tokens || !tokens.access_token) return false;
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      var ready = await ensureSupabaseClient(15);
      if (!ready) return false;
    }
    var sb = getSupabaseClient();
    if (!sb || !sb.auth || typeof sb.auth.setSession !== 'function') return false;
    try {
      var result = await sb.auth.setSession({
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token || tokens.access_token
      });
      if (result.error) {
        console.warn('setSession:', result.error.message);
        return false;
      }
      await refreshJwtContext();
      return hasAuthenticatedSession();
    } catch (e) {
      console.warn('applySupabaseAuthSession failed:', e);
      return false;
    }
  }

  async function applyAuthPayload(json) {
    if (!json) return false;
    if (json.access_token) {
      return applySupabaseAuthSession({
        access_token: json.access_token,
        refresh_token: json.refresh_token
      });
    }
    return false;
  }

  async function loginViaEdge(username, password, attempt) {
    attempt = attempt || 0;
    _lastLoginError = null;
    if (attempt === 0) {
      try {
        await edgeFetch('auth-login', { method: 'OPTIONS', timeoutMs: 20000 });
      } catch (e) { /* ignore */ }
    }
    try {
      var res = await edgeFetch('auth-login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: username, password: password }),
        timeoutMs: 60000
      });
      if (!res || !res.ok) {
        var errJson = null;
        try {
          if (res) errJson = await res.json();
        } catch (e2) {
          errJson = null;
        }
        console.error('auth-login HTTP', res ? res.status : 'no_response', errJson || '');
        var code = errJson && errJson.error;
        if (res && res.status === 429 || code === 'rate_limited') {
          _lastLoginError = 'rate_limited';
          return null;
        }
        if (res && res.status === 403 || code === 'password_reset_required') {
          _lastLoginError = 'password_reset_required';
          return null;
        }
        if ((res && res.status === 401) || code === 'invalid_credentials') {
          var rpcUser401 = await verifyCredentialsViaRpc(username, password);
          _lastLoginError = rpcUser401 ? 'jwt_failed' : 'bad_credentials';
        } else if (code === 'rpc_permission_denied' || code === 'auth_db_error') {
          _lastLoginError = code;
          console.error('auth-login server error:', errJson);
        } else if (code === 'missing_env' || (code && String(code).indexOf('gotrue') >= 0)) {
          _lastLoginError = 'jwt_failed';
        } else if (!res) {
          _lastLoginError = 'network_error';
        } else {
          _lastLoginError = 'edge_error';
        }
        return null;
      }
      var json = await res.json();
      if (!json.user) {
        console.error('auth-login: no user in response', json);
        _lastLoginError = 'edge_error';
        return null;
      }
      global.__basmaSessionActive = !!json.session;
      var applied = await applyAuthPayload(json);
      if (!applied) {
        console.error('auth-login: JWT setSession failed');
        var rpcOk = await verifyCredentialsViaRpc(username, password);
        _lastLoginError = rpcOk ? 'jwt_failed' : 'bad_credentials';
        return null;
      }
      return json.user;
    } catch (e) {
      console.warn('Edge login failed (attempt ' + (attempt + 1) + '):', e);
      if (isNetworkFetchError(e)) _lastLoginError = 'network_error';
      if (attempt < 1) {
        await new Promise(function (r) { setTimeout(r, 1200 + attempt * 800); });
        return loginViaEdge(username, password, attempt + 1);
      }
      if (_lastLoginError === 'network_error') return null;
      var rpcData = await verifyCredentialsViaRpc(username, password);
      if (rpcData && !rpcData.error) {
        _lastLoginError = 'edge_unreachable';
      } else if (_lastLoginError !== 'rate_limited' && _lastLoginError !== 'password_reset_required') {
        _lastLoginError = rpcData ? 'edge_unreachable' : 'bad_credentials';
      }
      return null;
    }
  }

  async function restoreSessionFromSupabaseJwt(expectedUserId) {
    if (typeof window !== 'undefined' && window.__basmaLoggingOut) return null;
    if (typeof initSupabase === 'function') initSupabase();
    if (typeof ensureSupabaseClient === 'function') {
      var ready = await ensureSupabaseClient(12);
      if (!ready) return null;
    }
    var sb = getSupabaseClient();
    if (!sb || !sb.auth || typeof sb.auth.getSession !== 'function') return null;
    try {
      var valid = await ensureValidSession({ skipNetworkUser: true });
      if (!valid && !(typeof window !== 'undefined' && window.__basmaLoggingOut)) {
        var ref = await sb.auth.refreshSession();
        if (!ref.data || !ref.data.session || !ref.data.session.access_token) return null;
      }
      var res = await sb.auth.getSession();
      var session = res.data && res.data.session;
      if (!session || !session.access_token) return null;
      var meta = (session.user && session.user.app_metadata) || {};
      var saasId = meta.saas_user_id != null ? parseInt(meta.saas_user_id, 10) : 0;
      if (!saasId) return null;
      if (expectedUserId != null && parseInt(expectedUserId, 10) !== saasId) return null;
      await refreshJwtContext();
      if (typeof sb_getSaasUserById === 'function') {
        return sb_getSaasUserById(saasId);
      }
      return null;
    } catch (e) {
      console.warn('restoreSessionFromSupabaseJwt:', e);
      return null;
    }
  }

  /**
   * حماية من تسرّب بيانات بين الشركات عند فتح شركتين في نفس المتصفح:
   * كوكي الجلسة (HttpOnly) مشتركة على مستوى المتصفح/الدومين ولا يمكن أن تكون
   * خاصة بتبويب واحد، فإذا سجّل المستخدم دخول شركة B في تبويب آخر، تصبح الكوكي
   * تشير إلى B. عندما يحاول تبويب هذه الشركة A تجديد جلسته (JWT منتهي/فارغ في
   * الذاكرة) فإنه يقرأ نفس الكوكي ويحصل على مستخدم B خطأً. هذا الفحص يمنع تبني
   * جلسة مستخدم مختلف عن الهوية الحالية المعروضة في هذا التبويب.
   */
  function isForeignCookieSession(cookieUser) {
    if (!cookieUser || cookieUser.id == null) return false;
    if (typeof global.currentUser !== 'undefined' && global.currentUser !== 'admin') return false;
    var active = global.saasCurrentUser || global._saasCurrentUser;
    if (!active || active.id == null) return false; // لا هوية سابقة في هذا التبويب — استعادة أولية طبيعية
    return String(active.id) !== String(cookieUser.id);
  }

  var _foreignSessionNotified = false;

  function notifyForeignSessionConflict(cookieUser) {
    global.__basmaForeignSessionConflict = { detectedAt: Date.now(), cookieUserId: cookieUser && cookieUser.id };
    if (_foreignSessionNotified) return;
    _foreignSessionNotified = true;
    if (typeof global.handleForeignSessionConflict === 'function') {
      try { global.handleForeignSessionConflict(cookieUser); } catch (e) { console.warn('handleForeignSessionConflict:', e); }
    }
  }

  var _restoreCookieInflight = null;

  async function restoreSessionViaCookieInner() {
    if (!useCookies()) return null;
    var endpoints = ['auth-session', 'auth-login'];
    for (var i = 0; i < endpoints.length; i++) {
      try {
        var res = await edgeFetch(endpoints[i], { method: 'GET' });
        if (!res || !res.ok) continue;
        var json = await res.json();
        if (!json || !json.user) continue;
        if (isForeignCookieSession(json.user)) {
          // كوكي هذا المتصفح صارت تخصّ شركة/مستخدم آخر — لا نتبنّى جلسته في هذا التبويب
          notifyForeignSessionConflict(json.user);
          return null;
        }
        var applied = await applyAuthPayload(json);
        if (!applied) continue;
        return json.user;
      } catch (e) {
        /* auth-session may be undeployed (404/CORS) — try auth-login fallback */
      }
    }
    return null;
  }

  async function restoreSessionViaCookie() {
    if (_restoreCookieInflight) return _restoreCookieInflight;
    _restoreCookieInflight = restoreSessionViaCookieInner().finally(function () {
      _restoreCookieInflight = null;
    });
    return _restoreCookieInflight;
  }

  async function login(username, password) {
    var u = String(username || '').trim().toLowerCase();
    if (!u || !password) return null;
    return loginViaEdge(u, password);
  }

  async function restoreSession(userId) {
    var fromJwt = await restoreSessionFromSupabaseJwt(userId);
    if (fromJwt) return fromJwt;
    if (useCookies()) {
      return restoreSessionViaCookie();
    }
    return null;
  }

  async function logoutRemote() {
    var sb = getSupabaseClient();
    if (sb && sb.auth && typeof sb.auth.stopAutoRefresh === 'function') {
      try { sb.auth.stopAutoRefresh(); } catch (e) { /* ignore */ }
    }

    var saasUserId = null;
    if (global.saasCurrentUser && global.saasCurrentUser.id) {
      saasUserId = global.saasCurrentUser.id;
    } else if (global._saasCurrentUser && global._saasCurrentUser.id) {
      saasUserId = global._saasCurrentUser.id;
    }

    var refreshToken = null;
    sb = getSupabaseClient();
    if (sb && sb.auth && typeof sb.auth.getSession === 'function') {
      try {
        var snap = await sb.auth.getSession();
        if (snap.data && snap.data.session && snap.data.session.refresh_token) {
          refreshToken = snap.data.session.refresh_token;
        }
      } catch (e) { /* ignore */ }
    }

    if (sb && typeof sb.rpc === 'function') {
      try {
        await sb.rpc('saas_logout_self');
      } catch (e) {
        console.warn('saas_logout_self:', e);
      }
    }

    var logoutPayload = {
      saas_user_id: saasUserId || undefined,
      refresh_token: refreshToken || undefined
    };
    var logoutEndpoints = [
      { name: 'auth-logout', body: logoutPayload },
      { name: 'auth-login', body: Object.assign({ action: 'logout' }, logoutPayload) }
    ];
    for (var li = 0; li < logoutEndpoints.length; li++) {
      try {
        var loRes = await edgeFetch(logoutEndpoints[li].name, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(logoutEndpoints[li].body)
        });
        if (loRes && loRes.ok) break;
      } catch (e) {
        /* try fallback endpoint */
      }
    }

    if (sb && sb.auth && typeof sb.auth.signOut === 'function') {
      try {
        await sb.auth.signOut({ scope: 'global' });
      } catch (e) {
        console.warn('signOut global:', e);
      }
    }
    await clearSupabaseSession();
  }

  async function logoutLocal() {
    try {
      await logoutRemote();
    } catch (e) {
      console.warn('logoutRemote:', e);
      await clearSupabaseSession().catch(function () {});
    }
    if (global.BasmaSession) BasmaSession.clearAdminSessionMeta();
    global.currentUser = null;
    global.saasCurrentUser = null;
    global._saasCurrentUser = null;
    clearJwtContext();
    if (typeof syncWindowState === 'function') syncWindowState();
  }

  async function setPasswordBcrypt(userId, newPassword) {
    try {
      var res = await edgeFetch('auth-set-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user_id: userId, new_password: newPassword })
      });
      if (!res) return false;
      var json = await res.json();
      return res.ok && json.ok === true;
    } catch (e) {
      console.warn('auth-set-password failed:', e);
      return false;
    }
  }

  global.AuthApi = {
    login: login,
    restoreSession: restoreSession,
    restoreSessionFromSupabaseJwt: restoreSessionFromSupabaseJwt,
    logoutLocal: logoutLocal,
    logoutRemote: logoutRemote,
    loginViaEdge: loginViaEdge,
    restoreSessionViaCookie: restoreSessionViaCookie,
    useCookies: useCookies,
    isCrossOriginDeployment: isCrossOriginDeployment,
    setPasswordBcrypt: setPasswordBcrypt,
    applySupabaseAuthSession: applySupabaseAuthSession,
    refreshJwtContext: refreshJwtContext,
    ensureValidSession: ensureValidSession,
    refreshAuthSessionForWrite: refreshAuthSessionForWrite,
    hasAuthenticatedSession: hasAuthenticatedSession,
    getCompanyId: getCompanyId,
    getRole: getRole,
    clearJwtContext: clearJwtContext,
    clearSupabaseSession: clearSupabaseSession,
    getLastLoginError: getLastLoginError,
    verifyCredentialsViaRpc: verifyCredentialsViaRpc,
    forceResetPassword: forceResetPassword
  };
})(typeof window !== 'undefined' ? window : globalThis);
