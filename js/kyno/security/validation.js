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
    var fieldErrors = {};
    var firstField = null;

    function addField(field, message) {
      if (!firstField) firstField = field;
      fieldErrors[field] = message;
      errors.push(message);
    }

    if (!emp || typeof emp !== 'object') {
      return { valid: false, errors: ['بيانات غير صالحة'], fieldErrors: {}, firstField: null };
    }

    var name = String(emp.name || '').trim();
    if (!name) {
      addField('name', 'يجب أن تملأ حقل الاسم الكامل');
    } else if (name.length < 2) {
      addField('name', 'الاسم قصير جداً — أدخل اسماً كاملاً');
    }

    var dept = String(emp.dept || '').trim();
    if (!dept || dept === '—') {
      addField('dept', 'يجب أن تملأ حقل القسم');
    }

    var role = String(emp.role || '').trim();
    if (!role || role === '—') {
      addField('role', 'يجب أن تملأ حقل الوظيفة');
    }

    var phoneRaw = String(emp.phone || '').trim();
    if (!phoneRaw || phoneRaw === '—') {
      addField('phone', 'يجب أن تملأ حقل الهاتف');
    } else {
      var phoneDigits = phoneRaw.replace(/\D/g, '');
      if (phoneDigits.length < 10) {
        addField('phone', 'رقم الهاتف غير صالح — أدخل 10 أرقام على الأقل (مثال: 07701234567)');
      }
    }

    var salaryType = String(emp.salaryType || emp.salary_type || 'monthly').trim();
    if (salaryType !== 'commission') {
      if (emp._salaryEmpty) {
        addField('salary', 'يجب أن تملأ حقل الراتب');
      } else if (emp.salary == null || emp.salary === '' || isNaN(parseInt(emp.salary, 10))) {
        addField('salary', 'يجب أن تملأ حقل الراتب');
      } else if (parseInt(emp.salary, 10) < 0) {
        addField('salary', 'الراتب يجب أن يكون رقماً موجباً');
      }
    }

    if (salaryType === 'biweekly') {
      if (emp._salaryHalfEmpty) {
        addField('salaryHalf', 'يجب أن تملأ حقل نصف الراتب');
      } else {
        var half = emp.salaryHalf != null ? emp.salaryHalf : emp.salary_half;
        if (half == null || half === '' || isNaN(parseInt(half, 10)) || parseInt(half, 10) < 0) {
          addField('salaryHalf', 'يجب أن تملأ حقل نصف الراتب');
        }
      }
    }

    return { valid: errors.length === 0, errors: errors, fieldErrors: fieldErrors, firstField: firstField };
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
