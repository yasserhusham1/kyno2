/**
 * جلسة المسؤول — حفظ/استعادة بدون كلمات مرور
 */
function saveAdminSession(user) {
  if (typeof BasmaSession !== 'undefined') { BasmaSession.saveAdminSessionMeta(user); return; }
  if (!user || !user.id) return;
  try {
    localStorage.setItem(ADMIN_SESSION_KEY, JSON.stringify({
      id: user.id,
      ts: Date.now(),
      user: {
        id: user.id,
        username: user.username,
        display_name: user.display_name || '',
        email: user.email || '',
        role: user.role,
        permissions: user.permissions || {},
        company_id: user.company_id != null ? (parseInt(user.company_id, 10) || null) : null,
        company_name: user.company_name || null,
        company_code: user.company_code || null,
        company_status: user.company_status || null,
        max_employees: user.max_employees || 0
      }
    }));
  } catch (e) {}
}

function applyAdminSession(user) {
  if (!user || !user.id) return false;
  if (user.role === 'super_admin' && typeof applySuperAdminSessionPermissions === 'function') {
    applySuperAdminSessionPermissions(user);
  } else {
    user.permissions = normalizePermissions(user.permissions);
  }
  if (user.company_id != null) user.company_id = parseInt(user.company_id, 10) || user.company_id;
  saasCurrentUser = user;
  window._saasCurrentUser = user;
  currentUser = 'admin';
  if (typeof AuthApi !== 'undefined' && AuthApi.refreshJwtContext) {
    AuthApi.refreshJwtContext().catch(function () {});
  }
  if (typeof syncWindowState === 'function') syncWindowState();
  return true;
}

async function verifyAdminSessionRemote(userId, timeoutMs) {
  if (typeof AuthApi !== 'undefined' && AuthApi.restoreSession) {
    try {
      if (typeof initSupabase === 'function') initSupabase();
      if (typeof ensureSupabaseClient === 'function') {
        var ready = await ensureSupabaseClient(18);
        if (!ready && !AuthApi.restoreSessionViaCookie) return null;
      }
      return await Promise.race([
        AuthApi.restoreSession(userId),
        new Promise(function (resolve) {
          setTimeout(function () { resolve(null); }, timeoutMs || 8000);
        })
      ]);
    } catch (e) {
      console.warn('verifyAdminSessionRemote failed:', e);
      return null;
    }
  }
  return null;
}

async function tryAutoAdminLogin() {
  try {
    if (currentUser) return true;
    if (typeof hasActiveEmployeeSession === 'function' && hasActiveEmployeeSession()) {
      if (typeof clearAdminSessionForEmployeeClient === 'function') clearAdminSessionForEmployeeClient();
      return false;
    }

    if (typeof AuthApi !== 'undefined' && AuthApi.restoreSessionViaCookie && AuthApi.useCookies && AuthApi.useCookies()) {
      var cookieUser = await AuthApi.restoreSessionViaCookie();
      if (cookieUser) {
        if (cookieUser.company_status === 'suspended') {
          clearAdminSession();
          return false;
        }
        applyAdminSession(cookieUser);
        saveAdminSession(cookieUser);
        if ((cookieUser.role === 'company_admin' || cookieUser.role === 'company_user') && cookieUser.company_id) {
          if (typeof prepareCompanyTenantSession === 'function') {
            prepareCompanyTenantSession(cookieUser);
          }
        }
        pauseRemoteSync(8000);
        if (typeof syncFromSupabase === 'function') {
          var forceRemote = !!window.__basmaTenantNeedsCloudReset;
          try {
            await syncFromSupabase({ reason: 'admin-cookie-login', forceRemote: forceRemote, keepDisableAutoSync: true });
          } catch (e) { console.warn('admin-cookie-login sync:', e); }
          window.__basmaTenantNeedsCloudReset = false;
        }
        launchApp();
        if (!window.__basmaTenantNeedsCloudReset && typeof syncDepartmentsToSupabase === 'function') syncDepartmentsToSupabase();
        resumeRemoteSync(8000);
        if (typeof BasmaCloud !== 'undefined' && BasmaCloud.initCloudSync) BasmaCloud.initCloudSync();
        return true;
      }
    }

    var raw = localStorage.getItem(ADMIN_SESSION_KEY);
    if (!raw) return false;
    var session = JSON.parse(raw);
    if (!session || !session.id) return false;

    var cachedUser = session.user || null;
    var remoteUser = await verifyAdminSessionRemote(session.id, 8000);
    if (remoteUser) {
      if (remoteUser.company_status === 'suspended') {
        clearAdminSession();
        currentUser = null;
        saasCurrentUser = null;
        window._saasCurrentUser = null;
        if (typeof AuthApi !== 'undefined' && AuthApi.clearJwtContext) AuthApi.clearJwtContext();
        if (typeof syncWindowState === 'function') syncWindowState();
        return false;
      }
      applyAdminSession(remoteUser);
      saveAdminSession(remoteUser);
      if ((remoteUser.role === 'company_admin' || remoteUser.role === 'company_user') && remoteUser.company_id) {
        if (typeof prepareCompanyTenantSession === 'function') {
          prepareCompanyTenantSession(remoteUser);
        }
        if (typeof sb_checkSubscriptionStatus === 'function') {
          try { _subscriptionStatus = await sb_checkSubscriptionStatus(remoteUser.company_id); } catch (e) {}
        }
      } else {
        _subscriptionStatus = { valid: true, status: 'active', warning: false };
      }
    } else if (!cachedUser) {
      return false;
    } else {
      var jwtOk = false;
      if (typeof AuthApi !== 'undefined') {
        if (AuthApi.ensureValidSession) {
          jwtOk = await AuthApi.ensureValidSession();
        } else if (AuthApi.hasAuthenticatedSession) {
          jwtOk = await AuthApi.hasAuthenticatedSession();
        }
        if (!jwtOk && AuthApi.restoreSessionFromSupabaseJwt) {
          var jwtUser = await AuthApi.restoreSessionFromSupabaseJwt(session.id);
          if (jwtUser) {
            applyAdminSession(jwtUser);
            saveAdminSession(jwtUser);
            jwtOk = true;
          }
        }
      }
      if (!jwtOk) {
        clearAdminSession();
        if (typeof AuthApi !== 'undefined' && AuthApi.clearSupabaseSession) {
          await AuthApi.clearSupabaseSession();
        }
        return false;
      }
      if (!saasCurrentUser && cachedUser) {
        applyAdminSession(cachedUser);
      }
      if (typeof sb_getSaasUserById === 'function') {
        try {
          var freshUser = await sb_getSaasUserById(session.id);
          if (freshUser) {
            applyAdminSession(freshUser);
            saveAdminSession(freshUser);
          }
        } catch (freshErr) {
          console.warn('refresh admin permissions:', freshErr);
        }
      }
      if (saasCurrentUser && saasCurrentUser.role === 'super_admin') {
        _subscriptionStatus = { valid: true, status: 'active', warning: false };
      } else if (saasCurrentUser && (saasCurrentUser.role === 'company_admin' || saasCurrentUser.role === 'company_user') && saasCurrentUser.company_id) {
        if (typeof prepareCompanyTenantSession === 'function') {
          prepareCompanyTenantSession(saasCurrentUser);
        }
        if (typeof sb_checkSubscriptionStatus === 'function') {
          try { _subscriptionStatus = await sb_checkSubscriptionStatus(saasCurrentUser.company_id); } catch (e) {}
        }
      } else if (!_subscriptionStatus) {
        _subscriptionStatus = { valid: true, status: 'active', warning: false };
      }
    }

    pauseRemoteSync(8000);
    if (typeof syncFromSupabase === 'function') {
      var forceRemoteLogin = !!window.__basmaTenantNeedsCloudReset;
      try {
        await syncFromSupabase({ reason: 'admin-auto-login', forceRemote: forceRemoteLogin, keepDisableAutoSync: true });
      } catch (e) {
        console.warn('admin auto-login sync failed:', e);
      }
      window.__basmaTenantNeedsCloudReset = false;
    }
    launchApp();
    if (!window.__basmaTenantNeedsCloudReset && typeof syncDepartmentsToSupabase === 'function') syncDepartmentsToSupabase();
    if (typeof sb_loadPlatformGlobals === 'function') {
      sb_loadPlatformGlobals().catch(function (e) { console.warn('auto-login platform globals:', e); });
    }
    resumeRemoteSync(8000);
    if (typeof BasmaCloud !== 'undefined' && BasmaCloud.initCloudSync) BasmaCloud.initCloudSync();
    return true;
  } catch (e) {
    console.warn('tryAutoAdminLogin error:', e);
    return false;
  }
}

function clearAdminSession() {
  if (typeof BasmaSession !== 'undefined') BasmaSession.clearAdminSessionMeta();
  try { localStorage.removeItem(ADMIN_SESSION_KEY); } catch (e) {}
}
