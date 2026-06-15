/**
 * انسخ هذا الملف إلى local.config.js وعدّل القيم.
 * local.config.js مُستثنى من Git (.gitignore)
 */
window.__BASMA_LOCAL_CONFIG__ = {
  supabaseUrl: 'https://qalcnvygyjltmlauvzlk.supabase.co',
  supabaseAnonKey: 'YOUR_ANON_KEY_HERE',
  appEnv: 'development',
  /** على Netlify يُعطّل تلقائياً (cross-origin) — يعتمد JWT من auth-login */
  authUseCookies: true,
  /**
   * مطلوب بعد migration 033 على Supabase:
   * kynoRpcMode: true
   * kynoFinalLockdown: true
   * (في appEnv: 'production' يُفعّلان تلقائياً إن لم تُحدَّدا)
   */
  kynoRpcMode: false,
  kynoFinalLockdown: false,
  realtimeTables: ['employees', 'employee_devices', 'attendance', 'app_settings', 'leaves'],
  pageSize: 100
};
