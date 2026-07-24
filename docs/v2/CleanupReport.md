# KYNO v2 — Cleanup Report
**النوع:** تقرير تحليلي — بدون حذف أو تعديل
**الهدف:** رصد ما يمكن تنظيفه عند بناء v2

---

> ⚠️ هذا التقرير للقراءة فقط. لا يُحذف أو يُعدّل أي ملف في v1.
> هذه القائمة تُستخدم كمرجع عند بناء v2 من الصفر.

---

## 1. كود مكرر (Duplicated Code)

### 1.1 ملفات `_shared` في Edge Functions
**المشكلة:** كل Edge Function تحمل نسخة خاصة من ملفات `_shared`

```
المكررات الموجودة:
supabase/functions/auth-session/_shared/supabase.ts
supabase/functions/auth-logout/_shared/supabase.ts
supabase/functions/auth-set-password/_shared/supabase.ts
supabase/functions/_shared/supabase.ts              ← نسخة "مركزية" موجودة بالفعل!

supabase/functions/auth-session/_shared/session.ts
supabase/functions/auth-logout/_shared/session.ts
supabase/functions/auth-set-password/_shared/session.ts
supabase/functions/_shared/session.ts

supabase/functions/auth-session/_shared/auth-jwt.ts
supabase/functions/_shared/auth-jwt.ts

supabase/functions/auth-session/_shared/types.ts
supabase/functions/auth-set-password/_shared/types.ts
supabase/functions/_shared/types.ts

الحل في v2: استخدام supabase/functions/_shared/ الواحدة للجميع
```

### 1.2 auth-api مكرر
```
المكررات:
js/services/auth-api.js
js/auth/login.js          ← كلاهما يتعامل مع Auth

الحل في v2: ملف واحد src/core/api/auth-api.js
```

### 1.3 وظائف مكررة بين js/core/ و js/kyno/
```
المكررات المحتملة:
js/core/security.js
js/kyno/security/sanitizer.js
js/kyno/security/validation.js
js/kyno/security/rate-limiter.js
  ← ثلاث ملفات أمان + ملف security مباشر في core

js/core/session.js
js/auth/admin-session.js
  ← ملفان للجلسة

الحل في v2: src/core/security/ موحّدة
```

### 1.4 safe-render و safe-runtime
```
js/core/safe-render.js
js/core/safe-runtime.js
  ← وظيفتان متشابهتان في مجالهما

الحل في v2: دمجهما في src/core/error/safe.js
```

---

## 2. ملفات زائدة (Unused / Deprecated Files)

### 2.1 netlify/functions/supabase-proxy.js
```
الملف: netlify/functions/supabase-proxy.js
السبب: وُجد لتجاوز CORS قبل نظام Edge Functions
الحالة: على الأرجح غير مستخدم بعد Edge Functions
الحل في v2: لا يُنشأ مثيل له
```

### 2.2 supabase_integration.js في الجذر
```
الملف: supabase_integration.js (في root)
المشكلة: ملف تكامل Supabase في مجلد الجذر بدلاً من js/
الحل في v2: ينتقل لـ src/core/api/supabase-client.js
```

### 2.3 ملفات apply-migration-*.ps1 المتعددة
```
الملفات:
tools/apply-migration-076.ps1
tools/apply-migration-078.ps1
tools/apply-migration-079.ps1
tools/apply-migration-api.ps1

المشكلة: سكريبتات نشر يدوية لكل migration
الحل في v2: سكريبت deploy واحد شامل
```

### 2.4 ملفات SQL في tools/
```
الملفات:
tools/sql/check-super-admin.sql
tools/sql/kyno-merged-migrations-000-084.sql
tools/sql/kyno-merged-migrations-001-084.sql

المشكلة: نسختان من merged migrations (000 و001)
الحل في v2: schema نظيف من الصفر — لا حاجة لدمج migrations
```

---

## 3. Features متكررة (Overlapping Features)

### 3.1 نظامان للإشعارات متداخلان
```
notifications (جدول legacy): موجود من البداية
admin_notifications (جدول جديد): أُضيف في migration 050
employee_notifications (جدول جديد): أُضيف في migration 050

المشكلة: جدول notifications القديم لم يُحذف، والجداول الجديدة تؤدي نفس الغرض
الحل في v2: إزالة legacy notifications، إبقاء admin_notifications + employee_notifications
```

### 3.2 app_settings تؤدي ثلاثة أدوار
```
الدور 1 — إعدادات المنصة:
  key: 'platform:system_version'
  key: 'platform:whatsapp_number'
  key: 'global:sa_user:X:prefs'

الدور 2 — إعدادات الشركة:
  key: 'company:1:currency'
  key: 'company:1:timezone'
  key: 'company:1:gps_lat'
  key: 'company:1:late_deduct_rate'
  key: 'company:1:overtime_hourly_rate'

الدور 3 — بيانات Finance:
  key: 'company:1:finance_items'  ← JSON كامل للخصومات/السلف

المشكلة: جدول واحد يحمل 3 مسؤوليات مختلفة
الحل في v2:
  platform_settings  ← الدور 1
  company_settings   ← الدور 2
  finance_items      ← الدور 3 كجدول مستقل
```

### 3.3 حقلا date_label و emp_name في attendance
```
جدول attendance يحتوي:
  emp_name: TEXT   ← نسخة مكررة من employees.name
  dept: TEXT       ← نسخة مكررة من employees.dept
  date_label: TEXT ← نسخة نصية من date_iso

المشكلة: denormalization يسبب عدم تناسق البيانات
الملاحظة: مقبول للأداء (لا JOIN في كل استعلام) — لكن يجب التوثيق
الحل في v2: إبقاؤه مع توثيق كـ denormalized intentionally
```

---

## 4. ملفات يمكن دمجها (Mergeable Files)

### 4.1 ملفات الـ JS في js/core/
```
يمكن دمجها:
js/core/app-version.js          ┐
js/core/system-version-ui.js    ┘ → src/core/utils/version.js

js/core/safe-render.js          ┐
js/core/safe-runtime.js         ┘ → src/core/error/safe.js

js/core/cloud-sync.js           ┐
js/core/conflict-resolver.js    ┘ → src/core/offline/sync.js (موجود بالفعل في kyno/)

js/core/storage.js              → src/core/state/ (دمج مع store.js)

js/core/dom.js                  → دمج مع ui-bindings.js أو utils/dom.js
```

### 4.2 ملفات الـ deployment
```
يمكن دمجها:
tools/deploy-edge-auth.ps1        ┐
tools/deploy-edge-auth-api.ps1    ┘ → tools/deploy-functions.ps1

tools/deploy-netlify-api.ps1      ┐
tools/build-netlify-release.ps1   ┘ → tools/deploy-frontend.ps1

tools/apply-migration-076.ps1     ┐
tools/apply-migration-078.ps1     │ → tools/apply-migration.ps1 (واحد عام)
tools/apply-migration-079.ps1     │
tools/apply-migration-api.ps1     ┘
```

---

## 5. هيكل متشعب ومعقد (Architecture Complexity)

### 5.1 تداخل js/core/ و js/kyno/
```
المشكلة: وجود مجلدين موازيين بدون تمييز واضح
  js/core/      ← الكود القديم
  js/kyno/      ← الكود الجديد (أُضيف تدريجياً)

مثال التداخل:
  js/core/security.js
  js/kyno/security/sanitizer.js
  js/kyno/security/validation.js
  → الأمان في مكانين مختلفين

  js/core/session.js
  js/auth/admin-session.js
  → الجلسة في مكانين

الحل في v2: src/core/ واحدة بهيكل واضح
```

### 5.2 index.html ضخم جداً
```
الملف: index.html
الحجم: 1122 سطر
المحتوى: Login page + ALL admin pages + Employee Portal pages
         كل الصفحات في صفحة واحدة مع display:none

المشكلة:
  - لا code splitting
  - تحميل كل الكود عند فتح الموقع
  - صعوبة الصيانة
  - لا routing حقيقي

الحل في v2: Modular pages أو SPA حقيقي
```

### 5.3 تحميل 30+ ملف JS في `<head>`
```
المشكلة: كل الـ scripts محملة في <head> بدون bundler
  - لا minification
  - لا code splitting  
  - لا lazy loading
  - cache busting يدوي (?v=20260619)

الحل في v2: module system حقيقي أو bundler (Vite/Rollup)
```

---

## 6. ملاحظات على قاعدة البيانات

### 6.1 85 migration file متراكمة
```
المشكلة:
  - migrations/001 تُصلح مشاكل
  - migrations/030-040 تُصلح مشاكل migrations سابقة
  - صعب فهم الـ schema الحالي بدون قراءة الكل

الحل في v2: migration واحد baseline نظيف
```

### 6.2 SERIAL integers بدلاً من UUID
```
المشكلة:
  - sequential IDs يُسرّبون معلومات (عدد الشركات، الموظفين)
  - أصعب في merge بيانات من environments مختلفة
  - لا تتوافق مع best practices الحديثة

الحل في v2: UUID لجميع primary keys
```

### 6.3 حقول TEXT لبيانات رقمية في attendance
```
المشكلة في جدول attendance:
  check_in  TEXT  ← يجب أن يكون TIME
  check_out TEXT  ← يجب أن يكون TIME
  hours     TEXT  ← يجب أن يكون INTERVAL أو INTEGER (minutes)
  late      TEXT  ← '22د' — يجب أن يكون INTEGER (minutes)
  overtime  TEXT  ← '1س 30د' — يجب أن يكون INTEGER (minutes)

تأثير: الحساب يتطلب RPCs معقدة لتحويل النصوص (parse_late_minutes، parse_ot_minutes)

الحل في v2: حقول رقمية مناسبة
```

---

## ملخص تنفيذي

| النوع | العدد | الأولوية |
|-------|-------|---------|
| كود مكرر | 4 مجموعات | عالية |
| ملفات زائدة | 6 ملفات | متوسطة |
| Features متكررة | 3 حالات | عالية |
| ملفات قابلة للدمج | 8 مجموعات | متوسطة |
| مشاكل معمارية | 3 مشاكل رئيسية | عالية جداً |
| مشاكل قاعدة البيانات | 3 مشاكل | عالية جداً |

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الأولى (Architecture & Planning)*
*لا تُحذف أو تُعدّل أي ملفات في v1 — هذا تقرير تحليلي فقط*
