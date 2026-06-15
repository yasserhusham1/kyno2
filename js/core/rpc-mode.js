/**
 * KYNO Enterprise v3 — RPC mode + Final lockdown flags
 * kynoFinalLockdown=true → RPC-only, no direct writes, no client salary logic
 */
(function (global) {
  'use strict';

  function isKynoFinalLockdown() {
    try {
      if (global.BasmaConfig && typeof global.BasmaConfig.kynoFinalLockdown === 'function') {
        return global.BasmaConfig.kynoFinalLockdown() === true;
      }
      if (global.__BASMA_LOCAL_CONFIG__ && global.__BASMA_LOCAL_CONFIG__.kynoFinalLockdown === true) {
        return true;
      }
    } catch (e) {}
    return false;
  }

  function isKynoRpcMode() {
    if (isKynoFinalLockdown()) return true;
    try {
      if (global.__kynoLockdownDetected === true) return true;
      if (global.BasmaConfig && typeof global.BasmaConfig.kynoRpcMode === 'function') {
        if (global.BasmaConfig.kynoRpcMode() === true) return true;
      }
      if (global.__BASMA_LOCAL_CONFIG__ && global.__BASMA_LOCAL_CONFIG__.kynoRpcMode === true) {
        return true;
      }
      if (global.BasmaConfig && typeof global.BasmaConfig.isProduction === 'function' && global.BasmaConfig.isProduction()) {
        return true;
      }
    } catch (e) {}
    return false;
  }

  function kynoRequiresServerSalary() {
    return isKynoFinalLockdown() || isKynoRpcMode();
  }

  global.isKynoFinalLockdown = isKynoFinalLockdown;
  global.isKynoRpcMode = isKynoRpcMode;
  global.kynoRequiresServerSalary = kynoRequiresServerSalary;
})(typeof window !== 'undefined' ? window : globalThis);
