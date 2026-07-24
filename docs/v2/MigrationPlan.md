# KYNO v2 — Migration Plan (النسخة النهائية)
**إجمالي الـ Migrations:** 22
**المنهجية:** كل migration يؤدي مهمة واحدة محددة
**القاعدة:** لا migration يُعدّل migration سابق — additive فقط

> ⚠️ هذا الملف وصف نظري فقط. لا SQL. لا تنفيذ.
> بعد الاعتماد الكامل لهذه الخطة ننتقل لكتابة الـ SQL الفعلي.

> **سجل التغييرات:** تم حذف `M002 — Enum Types` الموجود في النسخة السابقة.
> السبب: استخدام CHECK Constraints فقط بدلاً من ENUMs لمرونة أعلى في Supabase migrations.
> الترقيم الجديد: M002 → M003 → ... → M022 (22 migration بدلاً من 23).

---

## نظرة عامة — الطبقات

```
Layer 1 — Foundation     : M001 → M002  (الأساس: Extensions + Helper Functions)
Layer 2 — Core Tables    : M003 → M006  (plans, companies, saas_users, subscriptions)
Layer 3 — Business Tables: M007 → M012  (departments, job_titles, employees, devices, attendance, salary)
Layer 4 — Finance Tables : M013 → M014  (finance_items, leaves)
Layer 5 — System Tables  : M015 → M018  (platform_settings, company_settings, notifications, announcements)
Layer 6 — Audit Table    : M019         (audit_logs)
Layer 7 — RLS Policies   : M020 → M021  (سياسات الأمان لكل جدول)
Layer 8 — Seeds          : M022         (بيانات ابتدائية)
```

---

---

## Layer 1 — Foundation

---

### Migration 001 — Extensions & Core Setup
**الغرض:** تهيئة PostgreSQL extensions المطلوبة

**ما يُنشئه:**
- تفعيل extension: `pgcrypto` (لتوليد UUID وتشفير كلمات المرور)
- تفعيل extension: `uuid-ossp` (للـ UUID generation)
- تفعيل extension: `pg_trgm` (لدعم البحث النصي المتقدم — GIN indexes على name fields)
- إنشاء schema `public` مع comment يحمل إصدار KYNO v2

**لا يعتمد على:** لا شيء  
**يُعتمد عليه من:** جميع الـ migrations التالية

---

### Migration 002 — Database Helper Functions
**الغرض:** الدوال المساعدة الأساسية المطلوبة لعمل RLS

> ملاحظة: هذه ليست application RPCs — هذه database utility functions ضرورية لعمل RLS.
> لا تحتوي على ENUMs (تم حذف M002 القديم وهذا هو M003 القديم مُرحَّلاً).

**ما يُنشئه:**
- Function: `kyno_now()` — إرجاع الوقت الحالي بمنطقة زمنية Baghdad
- Function: `kyno_date_today()` — إرجاع تاريخ اليوم بمنطقة Baghdad
- Function: `auth_jwt_claim(claim TEXT)` — استخراج قيمة من JWT بأمان
- Function: `auth_saas_user_id()` — استخراج UUID المستخدم من JWT
- Function: `auth_company_id()` — استخراج UUID الشركة من JWT
- Function: `auth_user_role()` — استخراج role المستخدم من JWT
- Function: `auth_is_super_admin()` — هل المستخدم super_admin؟ (BOOLEAN)
- Function: `auth_is_company_admin()` — هل المستخدم company_admin؟
- Function: `auth_belongs_to_company(cid UUID)` — هل المستخدم ينتمي لهذه الشركة؟
- Function: `generate_leave_ref()` — توليد رقم مرجعي للإجازات (LEAVE-YYYYMMDD-XXXX)
- Function: `generate_notif_ref()` — توليد رقم مرجعي للإشعارات
- Function: `verify_company_id_match(emp_id UUID, cid UUID)` — التحقق من تطابق company_id

**لا يعتمد على:** Migration 001  
**يُعتمد عليه من:** جميع RLS policies في M020, M021

---

---

## Layer 2 — Core Tables

---

### Migration 003 — Table: plans
**الغرض:** إنشاء جدول خطط الاشتراك

**ما يُنشئه:**
- جدول `plans` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- UNIQUE constraint على `slug`
- INDEX على `is_active`
- CHECK constraints (max_employees > 0 · price >= 0)
- عمود `display_name JSONB` للدعم متعدد اللغات `{"ar": "...", "en": "..."}`
- Trigger: `updated_at` auto-update عند التعديل

**لا يعتمد على:** M001, M002  
**يُعتمد عليه من:** M004 (companies) · M006 (subscriptions)

---

### Migration 004 — Table: companies
**الغرض:** إنشاء جدول الشركات — محور الـ Multi-Tenant

**ما يُنشئه:**
- جدول `companies` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- UNIQUE constraint على `company_code`
- FK: `plan_id → plans.id` (ON DELETE SET NULL)
- INDEX على `status`
- INDEX على `plan_id`
- INDEX partial على `deleted_at WHERE deleted_at IS NULL`
- CHECK constraints (status values · max_employees > 0)
- Trigger: `updated_at` auto-update

> **ملاحظة:** تم حذف عمود `plan_tier` من هذا الجدول. يُقرأ plan_tier دائماً من JOIN مع `plans` عبر `plan_id`.

**لا يعتمد على:** M003  
**يُعتمد عليه من:** جميع الجداول التشغيلية

---

### Migration 005 — Table: saas_users
**الغرض:** إنشاء جدول مستخدمي المنصة

**ما يُنشئه:**
- جدول `saas_users` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- UNIQUE constraint على `username`
- FK: `company_id → companies.id` (ON DELETE SET NULL)
- INDEX على `company_id`
- INDEX على `role`
- INDEX على `is_active`
- Partial INDEX على `(company_id, role) WHERE deleted_at IS NULL`
- CHECK: `role IN ('super_admin', 'company_admin', 'company_user')`
- CHECK: `company_id IS NULL OR role != 'super_admin'`
- Trigger: `updated_at` auto-update

**لا يعتمد على:** M004  
**يُعتمد عليه من:** M006, M013, M014, M015, M018, M019, M020, M021

---

### Migration 006 — Table: subscriptions
**الغرض:** إنشاء جدول اشتراكات الشركات

**ما يُنشئه:**
- جدول `subscriptions` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- FK: `plan_id → plans.id` (ON DELETE SET NULL)
- FK: `activated_by_id → saas_users.id` (ON DELETE SET NULL)
- INDEX على `company_id`
- INDEX على `status`
- INDEX على `end_date`
- INDEX composite على `(company_id, status)`
- CHECK constraints (status values · end_date >= start_date · amount >= 0)
- Trigger: `updated_at` auto-update

**لا يعتمد على:** M004, M005  
**يُعتمد عليه من:** M020 (RLS يحتاج check subscription)

---

---

## Layer 3 — Business Tables

---

### Migration 007 — Table: departments
**الغرض:** إنشاء جدول الأقسام

**ما يُنشئه:**
- جدول `departments` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- INDEX على `company_id`
- **GIN INDEX على `name` (pg_trgm)** — للبحث النصي
- UNIQUE constraint على `(company_id, lower(trim(name)))`
- CHECK: `trim(name) <> ''`
- Trigger: `updated_at` auto-update
- **Trigger: عند تعديل اسم القسم → تُحدَّث `dept_name` في employees تلقائياً**

**لا يعتمد على:** M004  
**يُعتمد عليه من:** M009 (employees.dept_id)

---

### Migration 008 — Table: job_titles
**الغرض:** إنشاء جدول المسميات الوظيفية

**ما يُنشئه:**
- جدول `job_titles` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- INDEX على `company_id`
- **GIN INDEX على `name` (pg_trgm)** — للبحث النصي
- UNIQUE constraint على `(company_id, lower(trim(name)))`
- CHECK: `trim(name) <> ''`
- Trigger: `updated_at` auto-update
- **Trigger: عند تعديل اسم المسمى → تُحدَّث `job_title` في employees تلقائياً**

**لا يعتمد على:** M004  
**يُعتمد عليه من:** M009 (employees.job_title_id)

---

### Migration 009 — Table: employees
**الغرض:** إنشاء جدول الموظفين

**ما يُنشئه:**
- جدول `employees` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- FK: `dept_id → departments.id` (ON DELETE SET NULL)
- FK: `job_title_id → job_titles.id` (ON DELETE SET NULL)
- INDEX على `company_id`
- INDEX على `dept_id`
- INDEX على `is_active`
- INDEX composite على `(company_id, is_active)`
- INDEX على `created_at DESC`
- **GIN INDEX على `name` (pg_trgm)** — للبحث النصي والـ autocomplete
- **Partial INDEX على `(company_id, is_active) WHERE deleted_at IS NULL`** — الأداء على الموظفين النشطين
- CHECK constraints (salary_type · salary >= 0 · name not empty)
- Trigger: `updated_at` auto-update

**لا يعتمد على:** M004, M007, M008  
**يُعتمد عليه من:** M010, M011, M012, M013, M014, M015, M016, M017

---

### Migration 010 — Table: employee_devices
**الغرض:** إنشاء جدول ربط الأجهزة بالموظفين

**ما يُنشئه:**
- جدول `employee_devices` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `employee_id → employees.id` (ON DELETE CASCADE)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- INDEX على `employee_id`
- INDEX على `fingerprint` — للبحث السريع عند تسجيل الحضور
- INDEX partial على `registration_token WHERE registration_token IS NOT NULL`
- INDEX partial على `push_token WHERE push_token IS NOT NULL`
- UNIQUE constraint على `(employee_id, slot)`
- CHECK: `slot BETWEEN 1 AND 5`
- CHECK: `length(fingerprint) = 64 OR fingerprint = ''`
- CHECK: `token_expires_at IS NULL OR token_expires_at > token_created_at`
- Trigger: `updated_at` auto-update

> **أعمدة جديدة (بعد Review):** `token_expires_at`, `push_token`

**لا يعتمد على:** M009  
**يُعتمد عليه من:** لا شيء مباشر

---

### Migration 011 — Table: attendance (Partitioned)
**الغرض:** إنشاء جدول سجلات الحضور والانصراف — كـ Partitioned Table

**ما يُنشئه:**
- جدول `attendance` كـ **RANGE Partitioned Table** على `date_iso`
- PRIMARY KEY على `(id, date_iso)` — مطلوب للـ Partitioned Table
- FK: `employee_id → employees.id` (ON DELETE CASCADE)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- INDEX على `company_id`
- INDEX composite على `(employee_id, date_iso DESC)`
- INDEX composite على `(company_id, date_iso DESC)`
- INDEX على `status`
- UNIQUE constraint على `(employee_id, date_iso)`
- CHECK constraints (status values · minutes >= 0 · source values)
- Trigger: `updated_at` auto-update
- **إنشاء أول partition:** `attendance_2026` (DATE RANGE: 2026-01-01 → 2026-12-31)
- **إنشاء `attendance_default` partition** للسجلات خارج النطاق المحدد

**لا يعتمد على:** M009  
**يُعتمد عليه من:** لا شيء مباشر

---

### Migration 012 — Table: salary_records
**الغرض:** إنشاء جدول كشوف الرواتب

**ما يُنشئه:**
- جدول `salary_records` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `employee_id → employees.id` (ON DELETE CASCADE)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- INDEX على `company_id`
- INDEX composite على `(employee_id, period_start DESC)` — ترتيب زمني صحيح
- INDEX composite على `(company_id, period_start DESC)`
- INDEX على `status`
- UNIQUE constraint على `(employee_id, period_key)`
- CHECK constraints (status values · net_salary >= 0 · salary_type values)
- CHECK: `late_deduct_rate >= 0 AND overtime_hourly_rate >= 0`
- Trigger: `updated_at` auto-update

> **أعمدة جديدة (بعد Review):** `period_start DATE`, `late_deduct_rate INTEGER`, `overtime_hourly_rate INTEGER`

**لا يعتمد على:** M009  
**يُعتمد عليه من:** لا شيء مباشر

---

---

## Layer 4 — Finance Tables

---

### Migration 013 — Table: finance_items
**الغرض:** إنشاء جدول الخصومات والمكافآت والسلف

**ما يُنشئه:**
- جدول `finance_items` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- FK: `employee_id → employees.id` (ON DELETE CASCADE)
- FK: `created_by_id → saas_users.id` (ON DELETE SET NULL)
- INDEX على `company_id`
- INDEX على `employee_id`
- INDEX composite على `(employee_id, status)`
- INDEX composite على `(company_id, type)`
- INDEX على `apply_period`
- **INDEX composite على `(employee_id, apply_period, status)`** — للحساب الشهري المتكامل
- CHECK constraints (type · status · amount > 0 · loan_mode · installments)
- Trigger: `updated_at` auto-update
- **Trigger: BEFORE INSERT/UPDATE — يتحقق أن `company_id` يطابق `employees.company_id`**

**لا يعتمد على:** M005, M009  
**يُعتمد عليه من:** لا شيء مباشر

---

### Migration 014 — Table: leaves
**الغرض:** إنشاء جدول الإجازات والغياب

**ما يُنشئه:**
- جدول `leaves` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `employee_id → employees.id` (ON DELETE CASCADE)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- FK: `created_by_id → saas_users.id` (ON DELETE SET NULL)
- **FK: `approved_by_id → saas_users.id` (ON DELETE SET NULL)**
- UNIQUE constraint على `leave_ref`
- INDEX على `employee_id`
- INDEX على `company_id`
- INDEX composite على `(employee_id, from_date DESC)`
- INDEX composite على `(company_id, from_date DESC)`
- INDEX على `leave_type`
- **INDEX على `(company_id, approval_status)`** — لقوائم الموافقات
- CHECK constraints (leave_type · to_date >= from_date · multiplier >= 1)
- **CHECK: `approval_status IN ('pending', 'approved', 'rejected')`**
- **CHECK: `approved_at IS NULL OR approved_by_id IS NOT NULL`**
- Trigger: `updated_at` auto-update
- Trigger: auto-generate `leave_ref` عند الإدراج
- **Trigger: BEFORE INSERT/UPDATE — يتحقق أن `company_id` يطابق `employees.company_id`**

> **أعمدة جديدة (بعد Review):** `approval_status`, `approved_by_id`, `approved_at`

**لا يعتمد على:** M005, M009  
**يُعتمد عليه من:** لا شيء مباشر

---

---

## Layer 5 — System Tables

---

### Migration 015 — Table: platform_settings
**الغرض:** إنشاء جدول إعدادات المنصة

**ما يُنشئه:**
- جدول `platform_settings` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `updated_by_id → saas_users.id` (ON DELETE SET NULL)
- UNIQUE constraint على `key`
- INDEX على `is_public`
- CHECK: `trim(key) <> ''`
- **`created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`** — مضاف بعد Review
- Trigger: `updated_at` auto-update

**لا يعتمد على:** M005 (للـ FK فقط — NULLABLE)  
**يُعتمد عليه من:** لا شيء مباشر

---

### Migration 016 — Table: company_settings
**الغرض:** إنشاء جدول إعدادات الشركات

**ما يُنشئه:**
- جدول `company_settings` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- UNIQUE constraint على `(company_id, key)`
- INDEX على `company_id`
- CHECK: `trim(key) <> ''`
- Trigger: `updated_at` auto-update

**لا يعتمد على:** M004  
**يُعتمد عليه من:** لا شيء مباشر

---

### Migration 017 — Tables: Notifications
**الغرض:** إنشاء جدولي إشعارات الموظفين والمسؤولين

**ما يُنشئه:**

**جدول `employee_notifications`:**
- PRIMARY KEY على `id` (UUID)
- FK: `employee_id → employees.id` (ON DELETE CASCADE)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- UNIQUE constraint على `notif_ref`
- INDEX composite على `(employee_id, is_read)`
- INDEX على `company_id`
- INDEX على `created_at DESC`
- CHECK: `notif_type IN (values)`
- Trigger: auto-generate `notif_ref`

**جدول `admin_notifications`:**
- PRIMARY KEY على `id` (UUID)
- FK: `company_id → companies.id` (ON DELETE CASCADE)
- **FK: `read_by_id → saas_users.id` (ON DELETE SET NULL)**
- INDEX composite على `(company_id, read_at)` — NULL = غير مقروء
- INDEX على `created_at DESC`
- CHECK: `notif_type IN (values)`
- **CHECK: `read_at IS NULL OR read_by_id IS NOT NULL`**

> **تغيير (بعد Review):** `admin_notifications.is_read BOOLEAN` → `read_at TIMESTAMPTZ + read_by_id UUID`

**لا يعتمد على:** M004, M009  
**يُعتمد عليه من:** لا شيء مباشر

---

### Migration 018 — Table: platform_announcements
**الغرض:** إنشاء جدول إعلانات المنصة

**ما يُنشئه:**
- جدول `platform_announcements` بجميع أعمدته
- PRIMARY KEY على `id` (UUID)
- FK: `created_by_id → saas_users.id` (ON DELETE SET NULL)
- INDEX على `is_active`
- INDEX على `expires_at`
- INDEX composite على `(is_active, expires_at)`
- **INDEX على `target_type`**
- CHECK: `type IN ('info', 'warning', 'maintenance', 'urgent')`
- **CHECK: `target_type IN ('all', 'plan', 'company')`**
- **CHECK: `(target_type = 'all' AND target_id IS NULL) OR (target_type IN ('plan','company') AND target_id IS NOT NULL)`**
- Trigger: `updated_at` auto-update

> **تغيير (بعد Review):** عمود `target TEXT` → `target_type TEXT + target_id UUID` مع CHECK constraint يضمن الاتساق

**لا يعتمد على:** M005  
**يُعتمد عليه من:** لا شيء مباشر

---

---

## Layer 6 — Audit Table

---

### Migration 019 — Table: audit_logs (Partitioned)
**الغرض:** إنشاء جدول سجل التدقيق — append-only، Partitioned

**ما يُنشئه:**
- جدول `audit_logs` كـ **RANGE Partitioned Table** على `created_at`
- PRIMARY KEY على `(id, created_at)` — مطلوب للـ Partitioned Table
- FK: `company_id → companies.id` (ON DELETE SET NULL) — NULLABLE
- FK: `actor_id → saas_users.id` (ON DELETE SET NULL) — NULLABLE
- INDEX على `company_id`
- INDEX على `actor_id`
- INDEX على `action`
- INDEX على `category`
- INDEX على `created_at DESC`
- INDEX composite على `(company_id, created_at DESC)`
- **إنشاء 4 partitions للعام الحالي:** `audit_logs_2026_q1` / `_q2` / `_q3` / `_q4`
- **إنشاء `audit_logs_default` partition** للسجلات خارج النطاق
- تفعيل `REPLICA IDENTITY FULL` للـ Realtime (للمراقبة المباشرة)

**ملاحظات تصميمية مهمة:**
- لا `updated_at` trigger — السجل لا يُعدَّل أبداً
- RLS: لا UPDATE policy، لا DELETE policy — append-only مطلق

**لا يعتمد على:** M004, M005  
**يُعتمد عليه من:** لا شيء مباشر

---

---

## Layer 7 — RLS Policies

---

### Migration 020 — RLS: Core & Business Tables
**الغرض:** تطبيق Row Level Security على جداول الطبقات 2 و 3 و 4

**ما يُنشئه:**

**تفعيل RLS على الجداول:**
- `companies`
- `saas_users`
- `subscriptions`
- `departments`
- `job_titles`
- `employees`
- `employee_devices`
- `attendance`
- `salary_records`
- `finance_items`
- `leaves`

**Policies لكل جدول:**

**`companies`:**
- SELECT: `auth_is_super_admin()` فقط للكل · المصادق يرى شركته فقط
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs فقط

**`saas_users`:**
- SELECT: المستخدم يرى سجله دائماً · company_admin يرى مستخدمي شركته · SA يرى الكل
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs فقط (soft delete)

**`subscriptions`:**
- SELECT: company_admin يرى اشتراكات شركته · SA يرى الكل
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs فقط (SA only)

**`departments` و `job_titles`:**
- SELECT: المستخدم المصادق من نفس الشركة
- INSERT/UPDATE/DELETE: company_admin/user بصلاحية · SA يرى الكل

**`employees`:**
- SELECT: المستخدم المصادق من نفس الشركة
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs للعمليات الحساسة

**`employee_devices`:**
- **لا SELECT مباشر لـ anon** — RLS policy: anon → FALSE
- SELECT: company يرى أجهزة موظفيها (authenticated)
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs فقط

**`attendance`:**
- SELECT: الشركة ترى سجلات موظفيها · الموظف يرى سجله فقط
- INSERT/UPDATE: SECURITY DEFINER RPCs فقط
- DELETE: company_admin/user بصلاحية batch_delete

**`salary_records`:**
- SELECT: الشركة ترى رواتب موظفيها · الموظف يرى راتبه فقط
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs فقط

**`finance_items`:**
- SELECT: الشركة ترى حركاتها المالية
- INSERT/UPDATE/DELETE: company_admin/user بصلاحية · SA يرى الكل

**`leaves`:**
- SELECT: الشركة ترى إجازات موظفيها · الموظف يرى إجازاته فقط
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs

**لا يعتمد على:** جميع migrations السابقة  
**يُعتمد عليه من:** M021

---

### Migration 021 — RLS: System & Notification & Audit Tables
**الغرض:** تطبيق Row Level Security على الجداول المتبقية

**ما يُنشئه:**

**تفعيل RLS على:**
- `platform_settings`
- `company_settings`
- `employee_notifications`
- `admin_notifications`
- `platform_announcements`
- `audit_logs`

**Policies:**

**`platform_settings`:**
- SELECT: anon يرى السجلات `is_public = true` · SA يرى الكل
- INSERT/UPDATE/DELETE: SA فقط عبر SECURITY DEFINER

**`company_settings`:**
- SELECT: الشركة ترى إعداداتها فقط
- INSERT/UPDATE: company_admin/user بصلاحية settings.edit

**`employee_notifications`:**
- SELECT: الموظف يرى إشعاراته فقط
- الشركة ترى كل إشعارات موظفيها
- INSERT/UPDATE: SECURITY DEFINER RPCs فقط

**`admin_notifications`:**
- SELECT: الشركة ترى إشعاراتها
- INSERT/UPDATE/DELETE: SECURITY DEFINER RPCs

**`platform_announcements`:**
- SELECT: جميع المستخدمين المصادقين (للإعلانات النشطة)
- INSERT/UPDATE/DELETE: SA فقط عبر SECURITY DEFINER

**`audit_logs`:**
- SELECT: الشركة ترى logs شركتها · SA يرى الكل
- INSERT: SECURITY DEFINER فقط
- UPDATE: ممنوع لجميع الأدوار — NO POLICY
- DELETE: ممنوع لجميع الأدوار — NO POLICY

**لا يعتمد على:** جميع migrations السابقة  
**يُعتمد عليه من:** M022

---

---

## Layer 8 — Seeds

---

### Migration 022 — Initial Seeds
**الغرض:** إدخال البيانات الابتدائية الضرورية لتشغيل النظام

**ما يُدرج:**

**1 · خطط الاشتراك (plans):**
- `starter` — `{"ar": "الباقة الأساسية", "en": "Starter Plan"}` · 50 موظف
- `pro` — `{"ar": "الباقة الاحترافية", "en": "Pro Plan"}` · 200 موظف
- `enterprise` — `{"ar": "باقة المؤسسات", "en": "Enterprise Plan"}` · 1000 موظف

**2 · إعدادات المنصة (platform_settings):**
- `system_version` = '2.0.0' (is_public: false)
- `platform_name` = 'KYNO' (is_public: true)
- `platform_name_ar` = 'كينو' (is_public: true)
- `support_whatsapp` = '' (is_public: true — يُملأ لاحقاً)
- `maintenance_mode` = 'false' (is_public: true)

**3 · حساب Super Admin (saas_users):**
- username يُحدَّد في وقت التشغيل (لا يُكتب في migration)
- role = 'super_admin'
- password يُعيَّن عبر Edge Function بعد الإنشاء

> ملاحظة: كلمة مرور الـ Super Admin لا تُخزَّن أبداً في migration — تُعيَّن عبر
> Edge Function `auth-set-password` بعد الإنشاء مباشرة.

**لا يعتمد على:** جميع migrations السابقة  
**يُعتمد عليه من:** لا شيء — هذا آخر migration

---

---

## ترتيب التنفيذ

```
001 → 002 → 003 → 004 → 005 → 006
                   ↓
             007 → 008 → 009 → 010 → 011 → 012
                              ↓
                         013 → 014
                               ↓
                   015 → 016 → 017 → 018 → 019
                                            ↓
                                      020 → 021 → 022
```

---

## جدول الاعتماديات الكامل

| Migration | يعتمد على |
|-----------|-----------|
| M001 | — |
| M002 | M001 |
| M003 | M001, M002 |
| M004 | M003 |
| M005 | M004 |
| M006 | M004, M005 |
| M007 | M004 |
| M008 | M004 |
| M009 | M004, M007, M008 |
| M010 | M009 |
| M011 | M009 |
| M012 | M009 |
| M013 | M005, M009 |
| M014 | M005, M009 |
| M015 | M005 |
| M016 | M004 |
| M017 | M004, M009 |
| M018 | M005 |
| M019 | M004, M005 |
| M020 | M002, M003–M014 |
| M021 | M002, M015–M019 |
| M022 | M020, M021 |

---

## قواعد مهمة للـ Migrations في v2

```
1. كل migration: additive فقط — لا يعدل migrations سابقة
2. كل migration: يحتوي على معرّف فريد ووصف واضح
3. كل migration: قابل للتطبيق على بيئات مختلفة بنفس النتيجة (idempotent حيثما أمكن)
4. Triggers: تُنشأ في نفس migration إنشاء الجدول
5. RLS Policies: مجمّعة في migrations مستقلة (020 · 021) — ليست مبعثرة
6. Seeds: migration منفصل قابل للتخطي في بيئة الإنتاج عند الترقية
7. لا تخزين secrets في migrations — كلمات المرور تُعيَّن لاحقاً عبر Edge Functions
8. لا ENUM Types — يُستخدم CHECK constraints فقط للمرونة في التعديل المستقبلي
9. Partitioned Tables: attendance (by date_iso) + audit_logs (by created_at) — ينشآن من البداية كـ Partitioned
```

---

## المرحلة القادمة — بعد الاعتماد

```
بعد موافقتك على هذا التصميم:

الخطوة 1: كتابة SQL لـ Migration 001 → اعتماد
الخطوة 2: كتابة SQL لـ Migration 002 → اعتماد
الخطوة 3: كتابة SQL لـ Migration 003 → اعتماد
...
التسلسل: migration بعد migration حتى M022

لن نبدأ migration تالٍ إلا بعد اعتماد السابق.
```

---

## سجل التغييرات

| التغيير | التفاصيل |
|---------|----------|
| حذف M002 (Enum Types) | استبدال ENUMs بـ CHECK constraints في كل جدول |
| إعادة ترقيم M003→M022 | يصبح الكل -1 رقم، المجموع 22 بدلاً من 23 |
| M002 جديد (Functions) | يتضمن `verify_company_id_match()` للنزاهة المتقاطعة |
| M004 (companies) | ملاحظة حذف `plan_tier` |
| M010 (employee_devices) | أعمدة جديدة: `token_expires_at`, `push_token` + تعديل CHECK slot |
| M011 (attendance) | ينشأ كـ Partitioned Table |
| M012 (salary_records) | أعمدة جديدة: `period_start`, `late_deduct_rate`, `overtime_hourly_rate` |
| M014 (leaves) | أعمدة جديدة: `approval_status`, `approved_by_id`, `approved_at` |
| M015 (platform_settings) | عمود جديد: `created_at` |
| M017 (admin_notifications) | تغيير `is_read` → `read_at + read_by_id` |
| M018 (platform_announcements) | تغيير `target` → `target_type + target_id` |
| M019 (audit_logs) | ينشأ كـ Partitioned Table |

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الرابعة (Database Finalization)*
*النسخة النهائية — جاهز للمراجعة قبل كتابة الـ Migrations الفعلية*
