/**
 * واجهة تسجيل الدخول — مسؤول + موظف
 */
async function pickEmployeeLoginAccount(candidates, title, subtitle) {
  if (!candidates || !candidates.length) return null;
  if (candidates.length === 1) return candidates[0];
  var esc = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml : function (s) { return String(s || ''); };
  var opts = candidates.map(function (e) {
    return '<option value="' + e.id + '">' + esc(e.name) + ' — ' + esc(e.dept) + '</option>';
  }).join('');
  var result = await Swal.fire({
    title: title || 'اختر حسابك',
    html: '<div style="text-align:right"><label style="font-size:13px;display:block;margin-bottom:6px">' + (subtitle || 'اختر الموظف') + '</label><select id="remote-emp-select" class="setting-input" style="width:100%">' + opts + '</select></div>',
    confirmButtonText: 'دخول',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: function () { return document.getElementById('remote-emp-select')?.value; }
  });
  if (!result.value) return null;
  return (typeof employees !== 'undefined' ? employees : []).find(function (e) { return e.id === parseInt(result.value, 10); }) || null;
}

async function resolveEmployeeForLogin(ip, fp, ipRestrictOn) {
  if (typeof restoreEmployeeDeviceSession === 'function') restoreEmployeeDeviceSession();
  var emp = findEmployeeByDevice(ip, fp);
  if (emp) {
    if (typeof refreshEmployeeClientProfileById === 'function') {
      emp = await refreshEmployeeClientProfileById(emp.id) || emp;
    }
    if (typeof ensureEmployeeTenantContext === 'function') ensureEmployeeTenantContext(emp);
    return emp;
  }
  var cached = typeof getCachedEmployeeSessionIds === 'function'
    ? getCachedEmployeeSessionIds()
    : { empId: 0, slot: 1, companyId: 0 };
  var cachedId = cached.empId;
  var cachedSlot = cached.slot;
  if (cachedId && ipRestrictOn && typeof sb_verifyEmployeeDeviceAccess === 'function') {
    var serverAccess = await sb_verifyEmployeeDeviceAccess(cachedId, { fingerprint: fp, slot: cachedSlot });
    if (serverAccess && serverAccess.ok === true) {
      if (typeof ensureEmployeeFromServerAccess === 'function') {
        emp = await ensureEmployeeFromServerAccess(cachedId, cachedSlot, fp, serverAccess);
      } else if (typeof refreshEmployeeClientProfileById === 'function') {
        emp = await refreshEmployeeClientProfileById(cachedId, { slot: cachedSlot }) || null;
      }
      if (emp) return emp;
    }
  }
  if (ipRestrictOn && typeof resolveRegisteredEmployeeFromServer === 'function') {
    emp = await resolveRegisteredEmployeeFromServer(fp, ipRestrictOn);
    if (emp) return emp;
  }
  if (ipRestrictOn && fp && typeof tryAutoAdoptBrowserFingerprint === 'function') {
    var adoptedResolve = await tryAutoAdoptBrowserFingerprint(fp, ip);
    if (adoptedResolve && typeof resolveRegisteredEmployeeFromServer === 'function') {
      emp = await resolveRegisteredEmployeeFromServer(fp, ipRestrictOn);
      if (emp) return emp;
    }
  }
  if (cachedId && typeof refreshEmployeeClientProfileById === 'function') {
    var cachedEmp = await refreshEmployeeClientProfileById(cachedId, { slot: cachedSlot });
    if (cachedEmp) {
      if (cachedEmp.remoteAttend) return cachedEmp;
      if (!ipRestrictOn) return cachedEmp;
    }
  }
  var emps = (typeof employees !== 'undefined' ? employees : []).filter(function (e) {
    if (!e || !e.id) return false;
    if (typeof isEmployeeRecentlyDeleted === 'function' && isEmployeeRecentlyDeleted(e.id)) return false;
    return true;
  });
  var remoteEmps = emps.filter(function (e) { return e.remoteAttend; });
  async function refreshOne(candidate) {
    if (!candidate || typeof refreshEmployeeClientProfileById !== 'function') return candidate;
    return await refreshEmployeeClientProfileById(candidate.id) || candidate;
  }
  if (ipRestrictOn) {
    if (remoteEmps.length === 1) return refreshOne(remoteEmps[0]);
    if (remoteEmps.length > 1) {
      var pickedRemote = await pickEmployeeLoginAccount(remoteEmps, '📍 تسجيل حضور عن بُعد', 'اختر حسابك');
      return pickedRemote ? refreshOne(pickedRemote) : null;
    }
    return null;
  }
  if (remoteEmps.length === 1) return refreshOne(remoteEmps[0]);
  if (emps.length === 1) return refreshOne(emps[0]);
  var pickedOpen = await pickEmployeeLoginAccount(emps, '🔓 وضع الدخول المفتوح', 'اختر حسابك للدخول');
  return pickedOpen ? refreshOne(pickedOpen) : null;
}

async function refreshEmpLoginIp() {
  const ipEl = document.getElementById('emp-login-ip');
  const st = document.getElementById('emp-login-status');
  const btn = document.getElementById('btn-emp-login');
  if (!ipEl) return;
  if (typeof restoreEmployeeDeviceSession === 'function') restoreEmployeeDeviceSession();
  if (typeof setSubscriptionStatus === 'function') setSubscriptionStatus(null);
  else window._subscriptionStatus = null;
  ipEl.value = 'جارٍ الكشف...';
  if (st) st.textContent = 'يتم التحقق من الجهاز...';
  if (btn) btn.disabled = true;
  try {
    var ipPromise = fetchClientIp();
    currentClientIp = typeof withClientTimeout === 'function'
      ? await withClientTimeout(ipPromise, 7000, 'employee_login_ip')
      : await ipPromise;
  } catch (e) {
    console.warn('refreshEmpLoginIp ip:', e);
    currentClientIp = '';
  }
  const fp = getDeviceFingerprint();
  const ipDisplay = currentClientIp || 'غير متاح';
  ipEl.value = ipDisplay;
  const fpEl = document.getElementById('emp-login-fp');
  if (fpEl) fpEl.value = fp;
  const ipRestrictOn = appSettings.ipRestrict !== false;
  if (typeof sb_refreshEmployeeDevices !== 'function' && typeof syncFromSupabase === 'function' &&
      typeof hasTenantSyncContext === 'function' && hasTenantSyncContext()) {
    try { await syncFromSupabase({ reason: 'employee-login-preview' }); } catch (e) {}
  }
  if (!ipRestrictOn) {
    if (st) st.innerHTML = '✅ وضع الدخول المفتوح — اضغط تسجيل الدخول';
    if (btn) btn.disabled = false;
    return;
  }
  const emp = findEmployeeByDevice(currentClientIp, fp);
  const cached = typeof getCachedEmployeeSessionIds === 'function'
    ? getCachedEmployeeSessionIds()
    : { empId: 0, slot: 1, companyId: 0 };
  const cachedId = cached.empId;
  const cachedSlot = cached.slot;
  const remoteEmps = (typeof employees !== 'undefined' ? employees : []).filter(function (e) { return e && e.remoteAttend; });
  if (!currentClientIp && !fp && !remoteEmps.length && !cachedId) {
    if (st) st.textContent = 'تعذّر كشف الجهاز';
    return;
  }
  if (emp) {
    var nameSafe = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(emp.name) : emp.name;
    if (st) st.innerHTML = '✅ جهاز مصرّح: <strong>' + nameSafe + '</strong>';
    if (btn) btn.disabled = false;
    return;
  }
  if (cachedId && typeof sb_verifyEmployeeDeviceAccess === 'function') {
    try {
      var verifyPromise = sb_verifyEmployeeDeviceAccess(cachedId, { fingerprint: fp, slot: cachedSlot });
      var access = typeof withClientTimeout === 'function'
        ? await withClientTimeout(verifyPromise, 12000, 'employee_login_verify')
        : await verifyPromise;
      if (access && access.ok === true) {
        if (st) st.innerHTML = '✅ جهاز مسجّل — اضغط تسجيل الدخول';
        if (btn) btn.disabled = false;
        return;
      }
      if (typeof tryAutoAdoptBrowserFingerprint === 'function') {
        var adoptedVerify = await tryAutoAdoptBrowserFingerprint(fp, currentClientIp);
        if (adoptedVerify) {
          var verifyRetryPromise = sb_verifyEmployeeDeviceAccess(cachedId, { fingerprint: fp, slot: cachedSlot });
          var accessRetry = typeof withClientTimeout === 'function'
            ? await withClientTimeout(verifyRetryPromise, 12000, 'employee_login_verify_retry')
            : await verifyRetryPromise;
          if (accessRetry && accessRetry.ok === true) {
            if (st) st.innerHTML = '✅ جهاز مسجّل — اضغط تسجيل الدخول';
            if (btn) btn.disabled = false;
            return;
          }
        }
      }
    } catch (e) {
      console.warn('refreshEmpLoginIp verify:', e);
    }
  }
  if (ipRestrictOn && fp && typeof sb_resolveEmployeeByFingerprint === 'function') {
    try {
      var resolvePromise = sb_resolveEmployeeByFingerprint(fp);
      var resolved = typeof withClientTimeout === 'function'
        ? await withClientTimeout(resolvePromise, 12000, 'employee_login_resolve')
        : await resolvePromise;
      if ((!resolved || resolved.ok !== true) && typeof tryAutoAdoptBrowserFingerprint === 'function') {
        var adoptedLogin = await tryAutoAdoptBrowserFingerprint(fp, currentClientIp);
        if (adoptedLogin) {
          resolvePromise = sb_resolveEmployeeByFingerprint(fp);
          resolved = typeof withClientTimeout === 'function'
            ? await withClientTimeout(resolvePromise, 12000, 'employee_login_resolve_retry')
            : await resolvePromise;
        }
      }
      if (resolved && resolved.ok === true && resolved.employee_id) {
        markEmployeeSessionActive(resolved.employee_id, resolved.slot || 1, resolved.company_id);
        if (st) st.innerHTML = '✅ جهاز مسجّل — اضغط تسجيل الدخول';
        if (btn) btn.disabled = false;
        return;
      }
      if (resolved && resolved.error === 'subscription_inactive') {
        if (st) st.innerHTML = '⛔ اشتراك الشركة غير فعال — تواصل مع الإدارة';
        if (btn) btn.disabled = true;
        return;
      }
      if (resolved && (resolved.error === 'employee_suspended' || resolved.active === false)) {
        if (st) st.innerHTML = '⛔ تم إيقاف الحساب — يرجى مراجعة الإدارة';
        if (btn) btn.disabled = true;
        return;
      }
    } catch (e) {
      console.warn('refreshEmpLoginIp fingerprint resolve:', e);
    }
  }
  if (remoteEmps.length === 1) {
    var remoteName = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(remoteEmps[0].name) : remoteEmps[0].name;
    if (st) st.innerHTML = '✅ حضور عن بُعد: <strong>' + remoteName + '</strong>';
    if (btn) btn.disabled = false;
  } else if (remoteEmps.length > 1) {
    if (st) st.innerHTML = '✅ حسابات عن بُعد — اختر حسابك عند الدخول';
    if (btn) btn.disabled = false;
  } else {
    var fpSafe = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(fp) : String(fp || '');
    var ipSafe = currentClientIp && typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(currentClientIp) : (currentClientIp || '');
    if (st) st.innerHTML = '❌ جهاز غير مسجّل<br><span style="font-size:11px;direction:ltr">بصمة: ' + fpSafe + (ipSafe ? ' | IP: ' + ipSafe : '') + '</span><br><span style="font-size:11px;color:var(--accent)">امسح QR من إدارة الموظفين أو فعّل «حضور من أي مكان» للموظف</span>';
    if (btn) btn.disabled = true;
  }
}

function switchLoginTab(type, el) {
  document.querySelectorAll('.login-tab').forEach(t => t.classList.remove('active'));
  var tabEl = el || (typeof event !== 'undefined' && event && event.target ? event.target : null);
  if (tabEl) tabEl.classList.add('active');
  document.getElementById('admin-form').style.display = type === 'admin' ? 'block' : 'none';
  document.getElementById('emp-form').style.display = type === 'emp' ? 'block' : 'none';
  if (type === 'emp') {
    if (typeof displayEmpLoginNotice === 'function') displayEmpLoginNotice();
    refreshEmpLoginIp();
  }
}

function _setLoginLoading(loading) {
  const btn = document.getElementById('btn-admin-login');
  const txt = document.getElementById('btn-login-text');
  const ico = document.getElementById('btn-login-icon');
  if (!btn) return;
  btn.disabled = loading;
  if (txt) txt.textContent = loading ? 'جارٍ التحقق...' : 'تسجيل الدخول';
  if (ico) ico.className = loading ? 'fa fa-spinner fa-spin' : 'fa fa-sign-in-alt';
}

function _showLoginError(msg) {
  const el = document.getElementById('login-error-msg');
  if (!el) return;
  if (!msg) {
    el.style.display = 'none';
    el.textContent = '';
    return;
  }
  el.style.display = 'block';
  el.textContent = msg;
}

function _showPasswordResetPrompt(username, currentPassword) {
  Swal.fire({
    icon: 'warning',
    title: 'تغيير كلمة المرور مطلوب',
    html: '<p style="margin-bottom:12px">حسابك يستخدم كلمة مرور افتراضية. يجب تعيين كلمة مرور جديدة قبل الدخول.</p>' +
      '<input id="swal-new-pass" type="password" class="swal2-input" placeholder="كلمة المرور الجديدة (8+ أحرف)" style="margin:0">' +
      '<input id="swal-new-pass2" type="password" class="swal2-input" placeholder="تأكيد كلمة المرور" style="margin:8px 0 0">',
    confirmButtonText: 'حفظ كلمة المرور',
    showCancelButton: true,
    cancelButtonText: 'إلغاء',
    ...swalTheme(),
    preConfirm: function () {
      var np = (document.getElementById('swal-new-pass').value || '').trim();
      var np2 = (document.getElementById('swal-new-pass2').value || '').trim();
      if (np.length < 8) {
        Swal.showValidationMessage('كلمة المرور يجب أن تكون 8 أحرف على الأقل');
        return false;
      }
      if (np !== np2) {
        Swal.showValidationMessage('كلمتا المرور غير متطابقتين');
        return false;
      }
      return np;
    }
  }).then(async function (result) {
    if (!result.isConfirmed || !result.value) return;
    if (typeof AuthApi === 'undefined' || !AuthApi.forceResetPassword) {
      _showLoginError('تعذّر تغيير كلمة المرور — RPC غير متاح.');
      return;
    }
    var res = await AuthApi.forceResetPassword(username, currentPassword, result.value);
    if (res && res.ok) {
      Swal.fire({ icon: 'success', title: 'تم تغيير كلمة المرور', text: 'سجّل الدخول بكلمة المرور الجديدة.', ...swalTheme() });
    } else {
      _showLoginError('فشل تغيير كلمة المرور: ' + ((res && res.error) || 'خطأ غير معروف'));
    }
  });
}

function _showLoginBlocked(msg) {
  const el = document.getElementById('login-error-msg');
  if (!el) return;
  el.style.display = 'block';
  var msgSafe = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(msg || '') : String(msg || '');
  var waSubBtn = typeof contactSuperAdminFromLogin === 'function'
    ? '<button type="button" class="subscription-wa-btn" onclick="contactSuperAdminFromLogin()" title="تجديد الاشتراك"><i class="fa fa-credit-card"></i> تجديد الاشتراك</button>'
    : '';
  var waTeamBtn = typeof contactSupportTeamFromLogin === 'function'
    ? '<button type="button" class="subscription-wa-btn" onclick="contactSupportTeamFromLogin()" title="فريق الدعم"><i class="fa-brands fa-whatsapp"></i> فريق الدعم</button>'
    : '';
  el.innerHTML = '<div style="margin-bottom:10px;font-weight:700;line-height:1.7">' + msgSafe + '</div>' +
    '<div style="display:flex;flex-wrap:wrap;gap:8px;justify-content:center;margin-top:8px">' + waSubBtn + waTeamBtn + '</div>';
}

function doLogin(role) {
  if (role === 'admin') {
    const u = (document.getElementById('username').value || '').trim().toLowerCase();
    const p = document.getElementById('password').value || '';
    if (!u || !p) {
      _showLoginError('يرجى إدخال اسم المستخدم وكلمة المرور');
      return;
    }
    if (typeof KynoValidation !== 'undefined') {
      var uCheck = KynoValidation.validateUsername(u);
      if (!uCheck.valid) {
        _showLoginError(uCheck.errors.join(' — '));
        return;
      }
      var sec = KynoValidation.securityCheck(u);
      if (!sec.safe) {
        _showLoginError('محاولة دخول غير صالحة');
        return;
      }
    }
    try {
      if (typeof KynoRateLimiter !== 'undefined') {
        KynoRateLimiter.checkRateLimit('login', u);
      }
    } catch (rlErr) {
      _showLoginError('محاولات كثيرة — انتظر ' + (rlErr.retryAfter || 60) + ' ثانية');
      return;
    }
    _showLoginError('');
    _setLoginLoading(true);
    (async () => {
      try {
        let saasUser = null;
        if (typeof AuthApi !== 'undefined' && AuthApi.login) {
          saasUser = await AuthApi.login(u, p);
        }
        document.getElementById('password').value = '';
        if (!saasUser) {
          _setLoginLoading(false);
          var loginErr = typeof AuthApi !== 'undefined' && AuthApi.getLastLoginError ? AuthApi.getLastLoginError() : '';
          if (loginErr === 'password_reset_required') {
            _showPasswordResetPrompt(u, p);
            return;
          }
          if (loginErr === 'jwt_failed') {
            _showLoginError('كلمة المرور صحيحة لكن فشل تفعيل الجلسة — أعد المحاولة أو تواصل مع الدعم الفني.');
          } else if (loginErr === 'rpc_permission_denied' || loginErr === 'auth_db_error') {
            _showLoginError('خطأ في خادم الدخول — أعد المحاولة لاحقاً أو تواصل مع الدعم الفني.');
          } else if (loginErr === 'rate_limited') {
            _showLoginError('تم تجاوز عدد المحاولات، حاول لاحقاً.');
          } else if (loginErr === 'network_error' || loginErr === 'edge_unreachable') {
            _showLoginError('تعذّر الاتصال بالخادم.\n\n• أعد تحميل الصفحة (Ctrl+Shift+R) بعد رفع آخر نسخة من dist/\n• على Netlify: تأكد من وجود ملف _redirects داخل dist\n• عطّل VPN أو AdBlock مؤقتاً\n• محلياً: غيّر DNS إلى 8.8.8.8 أو استخدم نشر Netlify');
          } else if (loginErr === 'bad_credentials') {
            _showLoginError('اسم المستخدم أو كلمة المرور غير صحيحة.');
          } else {
            _showLoginError('اسم المستخدم أو كلمة المرور غير صحيحة.');
          }
          return;
        }
        if (typeof KynoRateLimiter !== 'undefined' && KynoRateLimiter.RateLimiters && KynoRateLimiter.RateLimiters.login) {
          KynoRateLimiter.RateLimiters.login.reset(u);
        }
        if (typeof KynoStore !== 'undefined' && global.kynoStore) {
          kynoStore.notify({ event: 'login', userId: saasUser.id });
        }
        if (typeof AuthApi !== 'undefined' && AuthApi.hasAuthenticatedSession) {
          var jwtReady = await AuthApi.hasAuthenticatedSession();
          if (!jwtReady) {
            _setLoginLoading(false);
            _showLoginError('تم التحقق من الحساب لكن فشل تفعيل الجلسة — أعد المحاولة أو تواصل مع الدعم الفني.');
            if (typeof AuthApi.clearSupabaseSession === 'function') await AuthApi.clearSupabaseSession();
            return;
          }
        }
        if (saasUser.company_status === 'suspended') {
          _setLoginLoading(false);
          window._loginBlockedCompany = { name: saasUser.company_name || '', code: saasUser.company_code || '' };
          if (typeof AuthApi.clearSupabaseSession === 'function') await AuthApi.clearSupabaseSession();
          _showLoginBlocked('حساب الشركة موقوف. تواصل مع الدعم الفني.');
          return;
        }
        if (saasUser.role === 'super_admin' && typeof applySuperAdminSessionPermissions === 'function') {
          applySuperAdminSessionPermissions(saasUser);
        } else {
          saasUser.permissions = normalizePermissions(saasUser.permissions);
        }
        saasCurrentUser = saasUser;
        window._saasCurrentUser = saasUser;
        if (typeof AuthApi !== 'undefined' && AuthApi.refreshJwtContext) {
          await AuthApi.refreshJwtContext();
        }
        if ((saasUser.role === 'company_admin' || saasUser.role === 'company_user') && saasUser.company_id) {
          if (typeof prepareCompanyTenantSession === 'function') {
            prepareCompanyTenantSession(saasUser);
          }
          if (typeof sb_checkSubscriptionStatus === 'function') {
            var subSt = await sb_checkSubscriptionStatus(saasUser.company_id);
            if (typeof setSubscriptionStatus === 'function') setSubscriptionStatus(subSt);
            else { _subscriptionStatus = subSt; window._subscriptionStatus = subSt; }
          }
          var curSub = typeof getSubscriptionStatus === 'function' ? getSubscriptionStatus() : _subscriptionStatus;
          if (curSub && curSub.valid === false) {
            _setLoginLoading(false);
            window._loginBlockedCompany = { name: saasUser.company_name || '', code: saasUser.company_code || '' };
            if (typeof AuthApi.clearSupabaseSession === 'function') await AuthApi.clearSupabaseSession();
            _showLoginBlocked('حساب الشركة موقوف. تواصل مع الدعم الفني.');
            return;
          }
        } else {
          var activeSub = { valid: true, status: 'active', warning: false };
          if (typeof setSubscriptionStatus === 'function') setSubscriptionStatus(activeSub);
          else { _subscriptionStatus = activeSub; window._subscriptionStatus = activeSub; }
        }
        window._loginBlockedCompany = null;
        currentUser = 'admin';
        window.currentUser = 'admin';
        if (typeof syncWindowState === 'function') syncWindowState();
        saveAdminSession(saasUser);
        if (typeof pauseRemoteSync === 'function') pauseRemoteSync(20000);
        if (typeof filterNotificationsForCurrentTenant === 'function') filterNotificationsForCurrentTenant();
        if (typeof syncFromSupabase === 'function') {
          var syncOk = true;
          try {
            syncOk = await syncFromSupabase({
              reason: 'post-login',
              keepDisableAutoSync: true,
              forceRemote: !!window.__basmaTenantNeedsCloudReset,
              quick: true
            });
            window.__basmaTenantNeedsCloudReset = false;
          } catch (syncErr) {
            syncOk = false;
            console.warn('post-login syncFromSupabase:', syncErr);
          }
          if (syncOk === false && saasUser.company_id && typeof Swal !== 'undefined') {
            Swal.fire({
              icon: 'warning',
              title: 'تعذّر مزامنة البيانات',
              text: 'تم تسجيل الدخول لكن جلب بيانات الشركة من السحابة فشل — تحقق من الاتصال ثم حدّث الصفحة.',
              confirmButtonText: 'متابعة',
              ...(typeof swalTheme === 'function' ? swalTheme() : {})
            });
          }
        }
        _setLoginLoading(false);
        if (typeof ensureAppInteractive === 'function') ensureAppInteractive();
        launchApp();
        if (typeof clearStaleUiBlockers === 'function') {
          setTimeout(clearStaleUiBlockers, 0);
          setTimeout(clearStaleUiBlockers, 500);
        }
        if (typeof filterNotificationsForCurrentTenant === 'function') filterNotificationsForCurrentTenant();
        if (typeof resumeRemoteSync === 'function') resumeRemoteSync(4000);
        if (typeof BasmaCloud !== 'undefined' && BasmaCloud.initCloudSync) BasmaCloud.initCloudSync();
        if (typeof sb_loadPlatformGlobals === 'function') {
          try { await sb_loadPlatformGlobals(); } catch (e) { console.warn('post-login sb_loadPlatformGlobals:', e); }
        }
        var loginLabel = saasUser.display_name || saasUser.username || 'مستخدم';
        var loginRole = saasUser.role === 'company_admin' ? 'مدير شركة'
          : (saasUser.role === 'company_user' ? 'مستخدم شركة' : (saasUser.role === 'super_admin' ? 'مسؤول النظام' : saasUser.role));
        logActivity('login', 'system', 'تسجيل دخول: ' + loginLabel + ' (' + loginRole + ')');
      } catch (err) {
        _setLoginLoading(false);
        _showLoginError('حدث خطأ أثناء تسجيل الدخول: ' + (err.message || err));
        console.error('doLogin error:', err);
      }
    })();
    return;
  }

  (async () => {
    const ip = currentClientIp || await fetchClientIp();
    currentClientIp = ip;
    const fp = getDeviceFingerprint();
    const cached = typeof getCachedEmployeeSessionIds === 'function'
      ? getCachedEmployeeSessionIds()
      : { empId: 0, slot: 1, companyId: 0 };
    const cachedSlot = cached.slot;
    await refreshEmployeesFromSupabaseForEmployeeClient('employee-login');
    const ipRestrictOn = appSettings.ipRestrict !== false;
    let emp = await resolveEmployeeForLogin(ip, fp, ipRestrictOn);
    if (ipRestrictOn && !emp && typeof tryAutoAdoptBrowserFingerprint === 'function') {
      var adoptedEmp = await tryAutoAdoptBrowserFingerprint(fp, ip);
      if (adoptedEmp) emp = await resolveEmployeeForLogin(ip, fp, ipRestrictOn);
    }
    if (ipRestrictOn && !emp) {
      var fpEsc = typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(fp) : fp;
      var ipEsc = ip && typeof BasmaSecurity !== 'undefined' ? BasmaSecurity.escapeHtml(ip) : ip;
      Swal.fire({ icon: 'error', title: 'جهاز غير مصرّح', html: 'بصمة: <b style="direction:ltr;color:#68d391">' + fpEsc + '</b>' + (ipEsc ? '<br>IP: <b style="direction:ltr;color:#63b3ed">' + ipEsc + '</b>' : '') + '<br><span style="font-size:13px;color:var(--accent)">امسح QR من إدارة الموظفين أو فعّل «حضور من أي مكان» للموظف</span>', ...swalTheme() });
      return;
    }
    if (emp) {
      var dev = (emp.devices || []).find(function (d) { return d.fingerprint === fp; });
      if (!dev && typeof getDevice === 'function') dev = getDevice(emp, cachedSlot);
      if (dev) {
        if (ip && dev.ip !== ip) dev.ip = ip;
        if (!dev.fingerprint && fp) dev.fingerprint = fp;
        dev.last_login = new Date().toISOString();
        dev.deviceInfo = getDeviceInfo();
        markEmployeeSessionActive(emp.id, dev.slot, emp.company_id);
        saveData();
      } else if (emp.remoteAttend || !ipRestrictOn) {
        markEmployeeSessionActive(emp.id, 1, emp.company_id);
      }
    }
    if (!emp) {
      Swal.fire({ icon: 'error', title: 'تعذّر الدخول', text: 'لم يتم التعرف على الجهاز أو حساب الموظف.', ...swalTheme() });
      return;
    }
    if (typeof sb_employeeLoginGate === 'function') {
      try {
        var loginGate = await sb_employeeLoginGate(emp.id);
        if (loginGate && loginGate.active === false) {
          emp.active = false;
          Swal.fire({ icon: 'error', title: 'تم إيقاف الحساب', text: (loginGate.message || 'تم إيقاف حسابك، يرجى مراجعة الإدارة.'), ...swalTheme() });
          return;
        }
        if (loginGate && loginGate.active === true) emp.active = true;
      } catch (gateErr) {
        console.warn('employee login gate:', gateErr);
      }
    }
    var empCid = emp.company_id != null ? parseInt(emp.company_id, 10) : null;
    if (!empCid) {
      empCid = null;
    }
    if (empCid && typeof sb_checkSubscriptionStatus === 'function') {
      try {
        var empSub = await sb_checkSubscriptionStatus(empCid);
        if (typeof setSubscriptionStatus === 'function') setSubscriptionStatus(empSub);
        else { window._subscriptionStatus = empSub; _subscriptionStatus = empSub; }
      } catch (subErr) {
        console.warn('employee subscription check:', subErr);
      }
    }
    if (typeof clearAdminSessionForEmployeeClient === 'function') clearAdminSessionForEmployeeClient();
    window.loggedInEmpId = emp.id;
    currentUser = 'emp';
    var loginDev = emp.devices && emp.devices.find(function (d) { return d.fingerprint === fp; });
    markEmployeeSessionActive(emp.id, loginDev ? loginDev.slot : 1, emp.company_id);
    if (typeof refreshLoggedInEmployeeAttendance === 'function') {
      try { await refreshLoggedInEmployeeAttendance(); } catch (e) {
        console.warn('employee login attendance refresh:', e);
      }
    }
    if (typeof refreshLoggedInEmployeeNotifications === 'function') {
      try { await refreshLoggedInEmployeeNotifications(); } catch (e) {
        console.warn('employee login notifications refresh:', e);
      }
    }
    if (typeof refreshLoggedInEmployeeSalaryHistory === 'function') {
      try { await refreshLoggedInEmployeeSalaryHistory(); } catch (e) {
        console.warn('employee login salary history refresh:', e);
      }
    }
    if (typeof syncWindowState === 'function') syncWindowState();
    logActivity('login', 'system', 'تسجيل دخول موظف: ' + (emp ? emp.name : ''), { targetName: emp ? emp.name : '', empId: emp ? emp.id : null, targetEmpId: emp ? emp.id : null });
    if (typeof logEmployeePortalEvent === 'function') {
      logEmployeePortalEvent('portal_login', { empId: emp.id, success: true, ip: currentClientIp });
    }
    launchApp();
  })();
}
