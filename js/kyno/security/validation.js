/**
 * KYNO validation — aligned with existing login/RPC rules
 */
(function (global) {
  'use strict';

  function validateUsername(username) {
    var u = String(username || '').trim().toLowerCase();
    var errors = [];
    if (u.length < 2) errors.push('اسم المستخدم قصير جداً');
    if (u.length > 64) errors.push('اسم المستخدم طويل جداً');
    if (!/^[a-z0-9._-]+$/.test(u)) errors.push('استخدم حروفاً إنجليزية صغيرة وأرقام و . _ -');
    return { valid: errors.length === 0, errors: errors, value: u };
  }

  function validatePassword(password, strict) {
    var p = String(password || '');
    var errors = [];
    if (p.length < 6) errors.push('كلمة المرور 6 أحرف على الأقل');
    if (p.length > 128) errors.push('كلمة المرور طويلة جداً');
    if (strict) {
      if (!/[A-Z]/.test(p)) errors.push('حرف كبير مطلوب');
      if (!/[a-z]/.test(p)) errors.push('حرف صغير مطلوب');
      if (!/\d/.test(p)) errors.push('رقم مطلوب');
    }
    return { valid: errors.length === 0, errors: errors };
  }

  function validateEmployee(emp) {
    var errors = [];
    if (!emp || typeof emp !== 'object') return { valid: false, errors: ['بيانات غير صالحة'] };
    if (!String(emp.name || '').trim() || String(emp.name).trim().length < 2) errors.push('الاسم مطلوب');
    var phone = String(emp.phone || '').replace(/\D/g, '');
    if (phone.length < 10) errors.push('رقم الهاتف غير صالح');
    if (emp.salary != null && isNaN(parseInt(emp.salary, 10))) errors.push('الراتب يجب أن يكون رقماً');
    return { valid: errors.length === 0, errors: errors };
  }

  function detectXSS(input) {
    var s = String(input || '');
    return /<script|javascript:|on\w+\s*=|<iframe/i.test(s);
  }

  function securityCheck(input) {
    var issues = [];
    if (detectXSS(input)) issues.push('XSS');
    return { safe: issues.length === 0, issues: issues };
  }

  global.KynoValidation = {
    validateUsername: validateUsername,
    validatePassword: validatePassword,
    validateEmployee: validateEmployee,
    detectXSS: detectXSS,
    securityCheck: securityCheck,
    sanitizeString: function (s, opts) {
      return global.KynoSanitizer ? KynoSanitizer.sanitizeString(s, opts) : String(s || '').trim();
    }
  };
})(typeof window !== 'undefined' ? window : globalThis);
