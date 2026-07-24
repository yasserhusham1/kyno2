# src/core/

النواة المشتركة — تُستخدم من جميع أجزاء التطبيق.

---

## المجلدات والمسؤوليات

| المجلد | المسؤولية | الملفات المتوقعة |
|--------|-----------|-----------------|
| `auth/` | إدارة الجلسة والمصادقة | session.js · login.js · admin-session.js |
| `api/` | Supabase client + RPC wrapper | supabase-client.js · rpc.js · auth-api.js |
| `security/` | تشفير، تحقق، rate limiting | crypto.js · sanitizer.js · validation.js · rate-limiter.js |
| `utils/` | أدوات عامة مساعدة | toast.js · loader.js · pdf.js · time-format.js · performance.js |
| `state/` | إدارة الحالة العامة | store.js · state.js · sync-state.js |
| `permissions/` | نظام الصلاحيات | permission-matrix.js · super-admin-permissions.js · tenant-guard.js |
| `offline/` | الوضع offline والمزامنة | offline-manager.js · cloud-sync.js · conflict-resolver.js |
| `error/` | معالجة الأخطاء | error-handler.js · safe-render.js · safe-runtime.js |
| `monitoring/` | Logging و Monitoring | logger.js · sentry-init.js |

---

## القاعدة الذهبية

> `core/` لا يعرف بوجود أي module محدد.
> إذا احتج ملف في `core/` على استيراد شيء من `modules/` — هذا خطأ في التصميم.
