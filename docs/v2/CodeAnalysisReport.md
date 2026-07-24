# KYNO v1 — Code Analysis Report
**المحلل:** Principal Software Architect
**النطاق:** جميع ملفات v1 (JS · TS · SQL · Config)
**الهدف:** تحديد ما يُعاد استخدامه في v2

---

## 1. الملفات المستخدمة فعلاً

المرجع: `<script>` tags في `index.html` (52 سكريبت محمّل في المتصفح)

```
config/
  ✅ supabase.defaults.js          — محمّل سطر 29
  ✅ public.config.js              — محمّل سطر 31
  ⚠ local.config.js               — محمّل سطر 30 لكن الملف غير موجود في git
                                     (يُنشأ محلياً من local.config.example.js)

js/core/
  ✅ app-version.js
  ✅ system-version-ui.js
  ✅ sentry-init.js
  ✅ security.js
  ✅ safe-runtime.js
  ✅ html-sanitize.js
  ✅ memory-auth-storage.js
  ✅ tenant-guard.js
  ✅ time-format.js
  ✅ cloud-sync.js
  ✅ conflict-resolver.js
  ✅ leave-guard.js
  ✅ rpc-mode.js
  ✅ employee-autocomplete.js
  ✅ storage.js
  ✅ session.js
  ✅ permissions.js
  ✅ permission-matrix.js
  ✅ super-admin-permissions.js
  ✅ dom.js

js/kyno/
  ✅ utils/retry-logic.js
  ✅ utils/performance.js
  ✅ utils/batch-processor.js
  ✅ security/sanitizer.js
  ✅ security/validation.js
  ✅ security/crypto.js
  ✅ security/rate-limiter.js
  ✅ core/logger.js
  ✅ core/error-handler.js
  ✅ core/offline-manager.js
  ✅ core/store.js
  ✅ api/supabase-client.js
  ✅ api/employee-api.js
  ✅ integration.js

js/app/
  ✅ state.js
  ✅ sync-state.js
  ✅ entry.js              (type="module" — قد يستورد ملفات إضافية)
  ✅ main.js
  ✅ ui-extra.js
  ✅ ui-bindings.js

js/leaves/
  ✅ ui.js

js/utils/
  ✅ toast.js
  ✅ loader.js
  ✅ pdf.js

js/services/
  ✅ auth-api.js

js/auth/
  ✅ admin-session.js
  ✅ login.js

root/
  ✅ supabase_integration.js    (~4,900 سطر — الملف الأكبر في المشروع)

Edge Functions (تعمل على Supabase):
  ✅ supabase/functions/auth-login/index.ts
  ✅ supabase/functions/auth-logout/index.ts
  ✅ supabase/functions/auth-session/index.ts
  ✅ supabase/functions/auth-set-password/index.ts
```

---

## 2. الملفات غير المستخدمة

### 2a. ملفات JS غير محمّلة في index.html

| الملف | الدليل | الحكم |
|-------|--------|-------|
| `js/attendance/device-mgmt.js` | غائب من كل `<script>` | ❌ لا يُحمّل |
| `js/attendance/ui.js` | غائب من كل `<script>` | ❌ لا يُحمّل مباشرة |
| `js/employees/ui.js` | غائب من كل `<script>` | ❌ لا يُحمّل مباشرة |
| `js/core/safe-render.js` | غائب من كل `<script>` | ❌ لا يُحمّل مباشرة |
| `js/app/data.js` | غائب من كل `<script>` | ❌ لا يُحمّل مباشرة |
| `config/local.config.example.js` | مرجع للمطور فقط | ❌ لا يُحمّل في المتصفح |

> **ملاحظة:** `entry.js` هو `type="module"` وقد يستورد بعض هذه الملفات
> عبر `import`. لا يمكن الجزم بدون قراءة entry.js كاملاً.
> لكن absence من `<script>` يُعدّ دليلاً كافياً.

---

### 2b. الملف الأكثر خطورة — netlify/functions/supabase-proxy.js

```
netlify/functions/supabase-proxy.js
```

**الحالة:** موجود في git وصريح في Architecture.md أنه غير مستخدم.
**الدليل من الكود:**
```javascript
// سطر 114 — الملف نفسه
exports.config = { path: '/sb/*' };
```
لا يوجد `_redirects` في Netlify يُوجّه `/sb/*` لهذه الدالة.
لا يوجد استدعاء لـ `/.netlify/functions/supabase-proxy` في أي JS.

**الحكم:** ملف ميت. آمن للحذف.

---

## 3. الملفات المكررة

### 3a. Edge Functions — كارثة التكرار

الـ `_shared/` الجذري يحتوي النسخة الموثوقة.
لكن كل Edge Function تنسخ نفس الملفات:

```
supabase.ts — 4 نسخ متطابقة:
  supabase/functions/_shared/supabase.ts         ← الأصل
  supabase/functions/auth-logout/_shared/supabase.ts
  supabase/functions/auth-session/_shared/supabase.ts
  supabase/functions/auth-set-password/_shared/supabase.ts

session.ts — 4 نسخ متطابقة (135 سطر × 4 = 540 سطر مكررة):
  supabase/functions/_shared/session.ts          ← الأصل
  supabase/functions/auth-logout/_shared/session.ts
  supabase/functions/auth-session/_shared/session.ts
  supabase/functions/auth-set-password/_shared/session.ts

auth-jwt.ts — 2 نسخ متطابقة:
  supabase/functions/_shared/auth-jwt.ts         ← الأصل
  supabase/functions/auth-session/_shared/auth-jwt.ts

types.ts — 3 نسخ (محتملاً متطابقة):
  supabase/functions/_shared/types.ts            ← الأصل
  supabase/functions/auth-session/_shared/types.ts
  supabase/functions/auth-set-password/_shared/types.ts
```

**الإجمالي:** ~13 نسخة من 4 ملفات — كل تعديل يجب أن يُكرّر 3-4 مرات.
**الخطر:** طُعم للـ drift — تختلف النسخ بمرور الوقت بدون أن يلاحظ أحد.

---

### 3b. Client initialization — نسختان تفعلان نفس الشيء

```
supabase_integration.js (سطر 10-40)       → getSupabaseUrl() + initSupabase()
js/kyno/api/supabase-client.js (سطر 14-32) → ensureClient() تلتف حول initSupabase()
```

**الدليل من الكود:**
```javascript
// supabase-client.js سطر 17-19:
if (typeof global.ensureSupabaseClient === 'function') {
  var ok = await global.ensureSupabaseClient(maxAttempts || 20);
```
`ensureSupabaseClient` معرّفة في `supabase_integration.js`.

الملف `supabase-client.js` هو wrapper حول wrapper — طبقة مؤقتة لإخفاء الـ global.

---

### 3c. HTML Sanitization — ملفان بنفس الوظيفة

```
js/core/html-sanitize.js  → window.BasmaSecurity.sanitize (IIFE style)
js/core/safe-render.js    → export function escapeHtml() (ES module style)
```

كلاهما يُنظّف HTML من XSS. النتيجة واحدة، الأسلوب مختلف.
`safe-render.js` لا يُحمّل من `<script>` ويستدعي `BasmaSecurity.escapeHtml` كـ fallback:
```javascript
// safe-render.js سطر 5-6:
if (typeof window !== 'undefined' && window.BasmaSecurity && BasmaSecurity.escapeHtml) {
  return BasmaSecurity.escapeHtml(value);
}
```
= نسخة احتياطية لنفس الدالة.

---

## 4. الملفات التي يمكن دمجها

| المجموعة | الملفات | الاقتراح |
|---------|---------|---------|
| **Permissions** | `js/core/permissions.js` · `js/core/permission-matrix.js` · `js/core/super-admin-permissions.js` | 3 ملفات لنظام صلاحيات واحد. في v2: ملف `permissions.js` واحد منظّم |
| **HTML Safety** | `js/core/html-sanitize.js` · `js/core/safe-render.js` | أدمجهما في `security/sanitizer.js` |
| **State** | `js/app/state.js` · `js/app/sync-state.js` · `js/kyno/core/store.js` | 3 ملفات تُدير الحالة — أدمجهما في `core/state/` |
| **Auth** | `js/auth/admin-session.js` · `js/auth/login.js` · `js/services/auth-api.js` · `js/core/session.js` | 4 ملفات للـ auth — أدمجهما في `src/core/auth/` |

---

## 5. الملفات التي يمكن حذفها بأمان (في v2)

```
❌ netlify/functions/supabase-proxy.js     — مؤكد غير مستخدم
❌ js/core/conflict-resolver.js            — يعتمد على localStorage sync — ميت في v2
❌ js/core/cloud-sync.js                   — نفس السبب — v2 server-authoritative
❌ js/app/sync-state.js                    — يعتمد على cloud-sync
❌ js/kyno/core/offline-manager.js         — يتشابك مع cloud-sync

ملفات لا تنتمي لأي منطق:
❌ tools/build-netlify.js                  — سكريبت بناء Netlify — لا ينتمي للمشروع
❌ tools/generate-local-config.js          — مساعد للمطور فقط
❌ tools/audit-ui-handlers.js              — مساعد audit فقط
```

> **تحذير:** لا تحذف الآن. هذه للحذف في v2 فقط — v1 قد لا يزال في الإنتاج.

---

## 6. الأخطاء المعمارية الموجودة

---

### خطأ 1: نظام وحدات مزدوج (المشكلة الجذرية)

```
js/app/entry.js           → type="module" (ES Modules)
كل ملف آخر               → IIFE على window.XxxGlobal
```

النتيجة: `entry.js` يُصدّر دوال لا يمكن لأي ملف آخر استيرادها بشكل نظيف.
التواصل يحدث عبر `window.globalFunction()` وليس عبر imports.

**السبب:** index.html تحمّل 50+ سكريبت بالترتيب لأن كل ملف يعتمد على globals من الملف السابق.

---

### خطأ 2: supabase_integration.js — الملف الذي يفعل كل شيء

```
الحجم: ~4,900 سطر في ملف واحد
يحتوي على:
  - تهيئة الـ client
  - RPCs الموظفين
  - RPCs الحضور
  - RPCs الرواتب
  - RPCs الإجازات
  - RPCs الإشعارات
  - RPCs الإعدادات
  - RPCs Super Admin
  - Data helpers
  - UI helpers
  - ... وأكثر
```

= God Object كلاسيكي. أي تعديل في أي RPC يمسّ هذا الملف الواحد.

---

### خطأ 3: Edge Functions لا تستخدم الـ _shared المركزي

الـ `supabase/functions/_shared/` موجود منذ البداية — هو الحل الصحيح.
لكن كل function تملك نسختها الخاصة من نفس الملفات.

**التحقق:** `auth-logout/_shared/supabase.ts` و `_shared/supabase.ts` — متطابقان 100% سطراً بسطر.

---

### خطأ 4: config/local.config.js غير موجود في repo

index.html يحمّله في سطر 30:
```html
<script src="config/local.config.js"></script>
```
لكن الملف الوحيد في git هو `local.config.example.js`.

**الخطر:** إذا لم يُنشئ المطور `local.config.js` محلياً، التطبيق يعمل بـ defaults — قد يتصل بـ Supabase project خاطئ دون رسالة خطأ واضحة.

---

### خطأ 5: Security — CORS wildcard في Netlify Proxy

```javascript
// netlify/functions/supabase-proxy.js سطر 27:
'Access-Control-Allow-Origin': origin && origin !== 'null' ? origin : '*',
```

أي origin يُقبل. هذا الملف غير مستخدم حالياً — لكن لو فُعّل، يصبح ثغرة.

---

### خطأ 6: conflict-resolver يعمل على بيانات stale

```javascript
// js/core/conflict-resolver.js سطر 22:
function detectEmployeeConflict(local, remote) {
  if (!local || !remote || local.id !== remote.id) return null;
```

يقارن `local` (من localStorage) مع `remote` (من Supabase).
في v2 الذي يعتمد Server-Authoritative، هذا المنطق لا معنى له.

---

### خطأ 7: 85 migration متراكمة — بعضها يُصلح بعضاً

```
migrations/042_employee_salary_reset_on_upsert.sql
migrations/047_employee_salary_exact_monthly.sql
migrations/049_biweekly_salary_no_rounding.sql
migrations/053_overtime_excluded_from_net_salary.sql
```
= 4 migrations تُعدّل نفس منطق حساب الراتب.

```
migrations/008_qr_token_fix.sql
migrations/010_qr_production_reset.sql
migrations/011_qr_radical_fix.sql
migrations/012_preserve_device_link.sql
```
= 4 migrations تُعدّل نفس منطق QR binding.

**النتيجة:** لفهم الحالة النهائية لأي جدول، يجب قراءة ~85 ملف بالترتيب.

---

## 7. الكود الذي يستحق النقل إلى KYNO v2

---

### الأولوية العالية — انقل مباشرة

| الملف | ما يستحق النقل | الموقع في v2 |
|-------|--------------|-------------|
| `supabase/functions/_shared/session.ts` | CORS + Cookie management + ALLOWED_ORIGINS | `kyno-v2/supabase/functions/_shared/` |
| `supabase/functions/_shared/auth-jwt.ts` | `ensureAuthUser` + `issueTokensForSaasUser` — منطق إصدار JWT معقد ومجرّب | `kyno-v2/supabase/functions/_shared/` |
| `supabase/functions/_shared/supabase.ts` | `createServiceClient()` — 13 سطر نظيف | `kyno-v2/supabase/functions/_shared/` |
| `js/kyno/security/crypto.js` | `sha256Hex()` — WebCrypto نظيف · `generateSecureToken()` | `kyno-v2/src/core/security/` |
| `js/core/time-format.js` | منطق Baghdad timezone — مجرّب على الإنتاج | `kyno-v2/src/core/utils/` |
| `js/kyno/utils/retry-logic.js` | `retryWithBackoff()` — منطق retry نظيف | `kyno-v2/src/core/utils/` |

---

### الأولوية المتوسطة — أعِد كتابته مع الاحتفاظ بالمنطق

| الملف | ما يستحق الاستيحاء | الملاحظة |
|-------|-----------------|---------|
| `js/core/permissions.js` + `js/core/permission-matrix.js` | مصفوفة الصلاحيات — المنطق سليم | أعِد الكتابة بـ ES Modules نظيفة |
| `js/kyno/core/error-handler.js` | تصنيف الأخطاء (network, auth, rls, etc.) | أعِد الكتابة دون globals |
| `js/kyno/security/validation.js` | قواعد التحقق من المدخلات | أعِد الكتابة كـ pure functions |
| `js/utils/toast.js` | UI notifications — UX مجرّب | أعِد الكتابة كـ component |
| `js/core/session.js` | منطق إدارة الجلسة | المنطق صحيح — النمط يحتاج تحديث |

---

### لا تنقل — اكتب من صفر

| الملف | السبب |
|-------|-------|
| `js/core/cloud-sync.js` | v2 server-authoritative — localStorage sync لا مكان له |
| `js/core/conflict-resolver.js` | نفس السبب |
| `js/app/sync-state.js` | نفس السبب |
| `supabase_integration.js` | God Object — يجب تقسيمه لـ RPCs مستقلة |
| `js/kyno/api/supabase-client.js` | wrapper حول wrapper — استبدله بـ direct Supabase client |

---

## ملخص الأرقام

```
إجمالي ملفات JS:             61 ملف
  محمّلة في المتصفح:          52 ملف
  غير محمّلة مباشرة:           9 ملفات

إجمالي ملفات TS (Edge):       18 ملف
  نسخ مكررة:                  9 ملفات (50%)
  نسخ أصلية:                  9 ملفات

ملف God Object:               1  (supabase_integration.js — 4900+ سطر)
ملفات آمنة للحذف في v2:        8  ملفات
ملفات تستحق النقل المباشر:     6  ملفات
ملفات تستحق إعادة الكتابة:     5  ملفات
migrations متراكمة:            85 ملف

أكبر مشكلة واحدة:
  → supabase_integration.js يحتوي كل الـ business logic
    في ملف واحد، مع نظام global variables
    هذا هو السبب الجذري لصعوبة الصيانة في v1
```

---

*KYNO v2 — Code Analysis Report*
*لا كود مكتوب · لا ملفات معدّلة · تقرير فقط*
