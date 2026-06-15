/**
 * KYNO employee API — validation + retry wrapper around supabase_integration
 */
(function (global) {
  'use strict';

  async function upsertEmployee(emp, options) {
    options = options || {};
    if (global.KynoValidation) {
      var v = KynoValidation.validateEmployee(emp);
      if (!v.valid) {
        if (global.kynoLogger) kynoLogger.warn('employee validation failed', { errors: v.errors });
        return null;
      }
    }
    var run = function () {
      if (typeof global.sb_upsertEmployee !== 'function') {
        return Promise.resolve(null);
      }
      return global.sb_upsertEmployee(emp, options);
    };
    if (global.KynoRetry && options.retry !== false) {
      return KynoRetry.retryWithBackoff(run, { maxRetries: 2, initialDelayMs: 400 });
    }
    return run();
  }

  async function listEmployees(opts) {
    opts = opts || {};
    var run = function () {
      if (typeof global.sb_getEmployees !== 'function') return Promise.resolve(null);
      return global.sb_getEmployees(opts);
    };
    if (global.KynoRetry && opts.retry !== false) {
      return KynoRetry.retryWithBackoff(run, { maxRetries: 2, initialDelayMs: 400 });
    }
    return run();
  }

  global.KynoEmployeeApi = {
    upsertEmployee: upsertEmployee,
    listEmployees: listEmployees
  };
})(typeof window !== 'undefined' ? window : globalThis);
