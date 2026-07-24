# KYNO v1 — Refactoring Plan
**المحلل:** Principal Software Architect
**الهدف:** تصنيف كل ملف قبل نقله أو حذفه
**إجمالي الملفات المدروسة:** 193 ملف

---

## قاموس التصنيفات

```
KEEP    → انقل كما هو إلى v2 — لا تعديل
REFACTOR → منطق صالح — يحتاج إعادة هيكلة (ES Modules, إزالة globals)
MERGE   → يُدمج مع ملف آخر في v2
DELETE  → احذف — غير مستخدم أو مكرر أو خطر
LEGACY  → يبقى في v1 — لا يُنقل — معمارية قديمة لا مكان لها في v2
```

---

---

## 1. KEEP — انقل كما هو (9 ملفات)

---

### Edge Functions — _shared الجذري

| الملف | السبب | يعتمد عليه | آمن للحذف |
|-------|-------|-----------|---------|
| `supabase/functions/_shared/session.ts` | CORS + Cookie + allowed origins — مجرّب على الإنتاج | auth-login, auth-logout, auth-session, auth-set-password | لا |
| `supabase/functions/_shared/auth-jwt.ts` | issueTokensForSaasUser — منطق معقد ومجرّب | auth-session, auth-login | لا |
| `supabase/functions/_shared/supabase.ts` | createServiceClient — 13 سطر نظيف | جميع Edge Functions | لا |
| `supabase/functions/_shared/types.ts` | SaasUserProfile type definitions | auth-jwt.ts, index.ts files | لا |
| `supabase/functions/env.d.ts` | Deno env type declarations | جميع functions | لا |

---

### JavaScript — Logic نظيف قابل للنقل المباشر

| الملف | السبب | يعتمد عليه | آمن للحذف |
|-------|-------|-----------|---------|
| `js/kyno/security/crypto.js` | sha256Hex + generateSecureToken — WebCrypto نظيف | supabase_integration.js | لا |
| `js/core/time-format.js` | Baghdad timezone — مجرّب على الإنتاج | main.js, supabase_integration.js | لا |
| `js/kyno/utils/retry-logic.js` | retryWithBackoff — منطق retry نظيف | supabase-client.js | لا |
| `js/kyno/security/rate-limiter.js` | Client-side rate limiter — Map-based, لا localStorage | KynoIntegration | لا |

---

### Config — Reference Template

| الملف | السبب | يعتمد عليه | آمن للحذف |
|-------|-------|-----------|---------|
| `config/local.config.example.js` | قالب للمطور — توثيق الـ keys المطلوبة | لا أحد | نعم (لكن احتفظ كمرجع) |

---

---

## 2. REFACTOR — أعِد الهيكلة واحتفظ بالمنطق (19 ملفاً)

---

### Edge Functions — أزل الـ _shared المحلية وأصلح الـ imports

| الملف | المشكلة | التعديل المطلوب |
|-------|---------|----------------|
| `supabase/functions/auth-login/index.ts` | تستورد من `../_shared/` المحلية غير موجودة | استبدل imports لتشير إلى `/_shared/` الجذري |
| `supabase/functions/auth-logout/index.ts` | نفس المشكلة | نفس الحل |
| `supabase/functions/auth-session/index.ts` | نفس المشكلة | نفس الحل |
| `supabase/functions/auth-set-password/index.ts` | نفس المشكلة | نفس الحل |

**الاعتماديات:** لا يعتمد عليها شيء خارجها.
**آمن للتعديل:** نعم — تعديل imports فقط.

---

### JavaScript — منطق صالح يحتاج تحديث النمط

| الملف | المشكلة | التعديل المطلوب | يعتمد عليه |
|-------|---------|----------------|---------|
| `js/kyno/security/validation.js` | IIFE + globals | أعِد كتابته كـ ES module — pure functions | supabase_integration.js |
| `js/kyno/core/error-handler.js` | IIFE + globals | أزل الـ globals — نفس منطق تصنيف الأخطاء | KynoIntegration |
| `js/kyno/core/logger.js` | IIFE + window.kynoLogger | أعِد كتابته كـ ES module logger | عدة ملفات |
| `js/kyno/utils/batch-processor.js` | IIFE + globals | أعِد كتابته كـ ES module | supabase_integration.js |
| `js/kyno/utils/performance.js` | IIFE + globals | أعِد كتابته — تتبع الأداء مفيد | index.html |
| `js/core/tenant-guard.js` | يعتمد على globals | أعِد كتابته — منطق الـ company_id guard مفيد | أجزاء من main.js |
| `js/core/sentry-init.js` | v1-specific config | أعِد الكتابة لـ v2 settings | index.html |
| `js/utils/toast.js` | IIFE + globals | أعِد كتابته — UX مجرّب | معظم الـ modules |
| `js/utils/loader.js` | IIFE + globals | أعِد كتابته — loading state مفيد | معظم الـ modules |
| `js/utils/pdf.js` | يعتمد على jspdf global | أعِد كتابته كـ module | salary, reports |
| `js/core/session.js` | logic جيد — يخلط in-memory مع cookie | فصل concerns — احتفظ بمنطق session meta | auth-api, admin-session |
| `js/auth/admin-session.js` | session handling جيد — مع globals | أعِد كتابته كـ ES module | main.js |
| `js/services/auth-api.js` | يستدعي Edge Functions — جيد | أعِد كتابته كـ ES module | login.js, admin-session |
| `config/supabase.defaults.js` | يعتمد على v1 structure | أعِد هيكلته لـ v2 | index.html |
| `config/public.config.js` | يعتمد على v1 globals | أعِد هيكلته لـ v2 | index.html |

---

---

## 3. MERGE — ادمج في ملف واحد (7 ملفات → 2 ملفات)

---

### مجموعة 1: Sanitization (4 ملفات → ملف واحد)

**الهدف:** `kyno-v2/src/core/security/sanitizer.js`

| الملف | ما يُساهم به | يعتمد عليه |
|-------|------------|---------|
| `js/core/security.js` | escapeHtml, escClass, stripDangerousHTML | معظم ملفات الـ UI |
| `js/core/html-sanitize.js` | sanitize, sanitizeAttr | entry.js imports |
| `js/core/safe-render.js` | escapeHtml ES module version | entry.js, module imports |
| `js/kyno/security/sanitizer.js` | sanitizeUserInput, stripScripts | supabase_integration.js |

**ملاحظة:** الأربعة تفعل نفس الشيء بأساليب مختلفة — IIFE، ES module، با globals.
**الحل:** ملف واحد كـ ES module نظيف.

---

### مجموعة 2: Permissions (3 ملفات → ملف واحد)

**الهدف:** `kyno-v2/src/core/permissions/permissions.js`

| الملف | ما يُساهم به | يعتمد عليه |
|-------|------------|---------|
| `js/core/permissions.js` | canAccessPage, permission check | main.js, ui-bindings |
| `js/core/permission-matrix.js` | PermissionMatrix, action checks | admin-session, ui-bindings |
| `js/core/super-admin-permissions.js` | SA-specific permissions | main.js |

**ملاحظة:** ثلاثة ملفات تُشكّل نظام صلاحيات واحداً.
**الحل:** نظام صلاحيات موحّد كـ ES module.

---

---

## 4. DELETE — احذف (21 ملفاً)

---

### مجموعة A: Netlify Proxy — مؤكد غير مستخدم

| الملف | الدليل | آمن للحذف |
|-------|--------|---------|
| `netlify/functions/supabase-proxy.js` | لا `_redirects` → لا يُستدعى أبداً. موثّق في Architecture.md كـ "unused" | ✅ نعم |

---

### مجموعة B: Edge Functions _shared المكررة (9 ملفات)

كلها **متطابقة 100%** مع نظيرتها في `supabase/functions/_shared/`.

| الملف المكرر | الأصل الصحيح | آمن للحذف |
|------------|------------|---------|
| `auth-logout/_shared/supabase.ts` | `_shared/supabase.ts` | ✅ نعم |
| `auth-logout/_shared/session.ts` | `_shared/session.ts` | ✅ نعم |
| `auth-session/_shared/supabase.ts` | `_shared/supabase.ts` | ✅ نعم |
| `auth-session/_shared/session.ts` | `_shared/session.ts` | ✅ نعم |
| `auth-session/_shared/auth-jwt.ts` | `_shared/auth-jwt.ts` | ✅ نعم |
| `auth-session/_shared/types.ts` | `_shared/types.ts` | ✅ نعم |
| `auth-set-password/_shared/supabase.ts` | `_shared/supabase.ts` | ✅ نعم |
| `auth-set-password/_shared/session.ts` | `_shared/session.ts` | ✅ نعم |
| `auth-set-password/_shared/types.ts` | `_shared/types.ts` | ✅ نعم |

> **تحذير:** قبل الحذف، تأكد أن كل function تستورد من `../_shared/` الجذري.
> هذا يتطلب تعديل import paths أولاً (جزء من REFACTOR المجموعة أعلاه).

---

### مجموعة C: Tools — أدوات مطور خارج نطاق التطبيق

| الملف | السبب | آمن للحذف |
|-------|-------|---------|
| `tools/build-netlify.js` | سكريبت بناء محلي — لا ينتمي للـ repo | ✅ نعم |
| `tools/generate-local-config.js` | يُنشئ `local.config.js` — one-time helper | ✅ نعم |
| `tools/audit-ui-handlers.js` | أداة تدقيق للمطور فقط | ✅ نعم |

---

### مجموعة D: SQL Tools — استُخدمت مرة واحدة أو للتشخيص

| الملف | السبب | آمن للحذف |
|-------|-------|---------|
| `tools/sql/kyno-merged-migrations-000-084.sql` | نسخة مدمجة للأرشيف — لا قيمة عملية | ✅ نعم |
| `tools/sql/fresh-start-empty-data.sql` | سكريبت تهيئة تطوير | ✅ نعم |
| `tools/sql/production-go-live.sql` | نُفّذ مرة واحدة — مؤرشف | ✅ نعم |
| `tools/sql/fix-super-admin-permissions.sql` | إصلاح طارئ — مُطبَّق | ✅ نعم |
| `tools/sql/check-super-admin.sql` | أداة تشخيص | ✅ نعم |
| `tools/sql/check-db-migration-markers.sql` | أداة تشخيص | ✅ نعم |
| `tools/sql/create-v-companies-summary.sql` | موجود في migration 085 | ✅ نعم |
| `tools/sql/production-go-live.sql` | نُفّذ — مؤرشف | ✅ نعم |

---

---

## 5. LEGACY — يبقى في v1 فقط (~125 ملف)

---

### 5a. God Object (1 ملف — الأكبر والأخطر)

| الملف | السبب | الحجم |
|-------|-------|-------|
| `supabase_integration.js` | كل الـ RPCs في ملف واحد مع globals — يُستبدل بـ RPCs مستقلة في v2 | ~4,900 سطر |

---

### 5b. معمارية LocalStorage (5 ملفات)

هذه الملفات تعتمد على نمط "local-first + cloud sync" الذي لا وجود له في v2.

| الملف | السبب |
|-------|-------|
| `js/core/cloud-sync.js` | localStorage queue + remote flush — v2 server-authoritative |
| `js/core/conflict-resolver.js` | local vs remote comparison — لا معنى له في v2 |
| `js/app/sync-state.js` | يعتمد على cloud-sync مباشرة |
| `js/kyno/core/offline-manager.js` | يتشابك مع pauseRemoteSync من cloud-sync |
| `js/core/storage.js` | localStorage wrapper — v2 يعتمد على server state |

---

### 5c. Global State Architecture (4 ملفات)

| الملف | السبب |
|-------|-------|
| `js/kyno/core/store.js` | Global state store على window — يُستبدل بـ module state في v2 |
| `js/app/state.js` | Global app state — نفس السبب |
| `js/core/memory-auth-storage.js` | in-memory + localStorage auth — v2 يستخدم JWT cookies |
| `js/core/rpc-mode.js` | يُبدّل بين local/rpc mode — v2 هو RPC-only |

---

### 5d. v1 Application Layer (10 ملفات)

هذه ملفات UI/Bootstrap مرتبطة ارتباطاً عضوياً بـ `index.html` الوحيد.

| الملف | السبب |
|-------|-------|
| `index.html` | الـ SPA الوحيد — v2 له بنية صفحات منفصلة |
| `css/app.css` | CSS مرتبط بـ v1 HTML classes |
| `js/app/main.js` | v1 bootstrap + page navigation |
| `js/app/entry.js` | ES module entry لـ v1 — يستورد v1 UI modules |
| `js/app/ui-bindings.js` | bindings لعناصر v1 HTML |
| `js/app/ui-extra.js` | UI helpers خاصة بـ v1 |
| `js/app/data.js` | localStorage data layer — v2 لا يستخدم localStorage |
| `js/core/system-version-ui.js` | يُحدّث version في v1 DOM |
| `js/core/safe-runtime.js` | v1-specific safe execution wrapper |
| `js/core/app-version.js` | v1 version string |

---

### 5e. v1 Module UIs (5 ملفات)

مرتبطة بـ HTML الـ v1 و DOM IDs خاصة بها.

| الملف | السبب |
|-------|-------|
| `js/leaves/ui.js` | يبني HTML لـ v1 leaves section |
| `js/attendance/ui.js` | يبني HTML لـ v1 attendance section |
| `js/employees/ui.js` | يبني HTML لـ v1 employees section |
| `js/attendance/device-mgmt.js` | v1 device management UI |
| `js/analytics/chart-analytics.js` | مرتبط بـ Chart.js + v1 DOM containers |

---

### 5f. v1 DOM Utilities (4 ملفات)

| الملف | السبب |
|-------|-------|
| `js/core/dom.js` | DOM helpers لـ v1 HTML structure |
| `js/core/employee-autocomplete.js` | v1 DOM autocomplete |
| `js/core/leave-guard.js` | v1 leave validation tied to DOM |
| `js/auth/login.js` | v1 login page logic |

---

### 5g. v1 API Layer (3 ملفات)

| الملف | السبب |
|-------|-------|
| `js/kyno/api/supabase-client.js` | wrapper حول initSupabase من supabase_integration.js |
| `js/kyno/api/employee-api.js` | Employee RPCs — ستُكتب من صفر في v2 |
| `js/kyno/integration.js` | Bootstrap hooks لـ v1 modules فقط |

---

### 5h. v1 Database — 85 Migration (85 ملف)

```
supabase/migrations/000_kyno_baseline_schema.sql
supabase/migrations/001_security_hardening.sql
...
supabase/migrations/085_v_companies_summary.sql
```

**السبب:** v2 يبدأ بـ Schema جديد من صفر (22 migration منفصل).
هذه الـ 85 ملف هي التاريخ القانوني لـ v1 DB — لا تُحذف، لا تُنقل.
**الحالة:** أرشيف مرجعي في مكانه.

---

### 5i. Deno Configuration (6 ملفات)

| الملف | السبب |
|-------|-------|
| `supabase/functions/deno.json` | يُعاد إنشاؤه في v2 من صفر |
| `supabase/functions/auth-login/deno.json` | نفس السبب |
| `supabase/functions/auth-logout/deno.json` | نفس السبب |
| `supabase/functions/auth-session/deno.json` | نفس السبب |
| `supabase/functions/auth-set-password/deno.json` | نفس السبب |
| `supabase/functions/tsconfig.json` | نفس السبب |

---

### 5j. Documentation Only (2 ملف)

| الملف | السبب |
|-------|-------|
| `docs/KYNO-دليل-العملاء.html` | دليل v1 للعملاء — يبقى كمرجع |
| `docs/RESET-SUPER-ADMIN-PASSWORD.sql` | أداة emergency لـ v1 — أرشيف |

---

---

## الأرقام النهائية

```
┌────────────────────────────────────────────────────────────────────┐
│                    KYNO v1 — Refactoring Summary                   │
├─────────────────────────────┬────────┬─────────────────────────────┤
│ التصنيف                      │ العدد  │ الوجهة في v2                │
├─────────────────────────────┼────────┼─────────────────────────────┤
│ KEEP — انقل كما هو            │   9    │ kyno-v2/ مباشرة             │
│ REFACTOR — أعِد الهيكلة       │  19    │ kyno-v2/ بعد إعادة كتابة   │
│ MERGE — ادمج مع غيره          │   7    │ ينتج 2 ملف في kyno-v2/      │
│ DELETE — احذف فوراً           │  21    │ —                           │
│ LEGACY — يبقى في v1           │ ~125   │ لا ينتقل                    │
├─────────────────────────────┼────────┼─────────────────────────────┤
│ TOTAL                        │ ~181   │                             │
└─────────────────────────────┴────────┴─────────────────────────────┘

ملف يُنقل إلى v2 (KEEP + REFACTOR + MERGE):  35 ملف من 181
ملف يُحذف (DELETE):                           21 ملف
ملف يبقى LEGACY ولا يُنقل:                  ~125 ملف
```

---

## ترتيب التنفيذ المقترح

```
الخطوة 1 — DELETE (فوراً، آمن):
  احذف 9 ملفات _shared مكررة
  احذف netlify/functions/supabase-proxy.js
  احذف tools/ الـ 3 ملفات JS
  احذف tools/sql/ الـ 7 ملفات
  = 20 ملف تختفي فوراً — المشروع يبقى يعمل

الخطوة 2 — KEEP (نقل مباشر إلى v2):
  copy _shared/*.ts → kyno-v2/supabase/functions/_shared/
  copy js/kyno/security/crypto.js → kyno-v2/src/core/security/
  copy js/core/time-format.js → kyno-v2/src/core/utils/
  copy js/kyno/utils/retry-logic.js → kyno-v2/src/core/utils/
  copy js/kyno/security/rate-limiter.js → kyno-v2/src/core/security/

الخطوة 3 — REFACTOR (Edge Functions أولاً):
  أصلح import paths في 4 Edge Functions
  → يُمكّن حذف _shared المحلية التي ستبقى بعد الخطوة 1

الخطوة 4 — MERGE (الـ sanitizers والـ permissions):
  أنشئ sanitizer.js موحّد
  أنشئ permissions.js موحّد

الخطوة 5 — REFACTOR (JS Utilities):
  أعِد كتابة validation, logger, error-handler, session, auth-api
```

---

*KYNO v1 — Refactoring Plan*
*لا ملف مُعدَّل في هذا التقرير — قرارات فقط*
