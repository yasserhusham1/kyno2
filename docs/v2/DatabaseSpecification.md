# KYNO v2 — Database Specification
**قاعدة البيانات:** PostgreSQL via Supabase
**الاستراتيجية:** Shared Database · Shared Schema · Row Level Security
**نهج المفاتيح:** UUID لجميع Primary Keys
**Multi-Tenant:** company_id في كل جدول تشغيلي

---

## جدول المحتوى

| # | الجدول | التصنيف | الاعتمادية |
|---|--------|---------|-----------|
| 01 | `plans` | Lookup | لا اعتمادية |
| 02 | `companies` | Core | plans |
| 03 | `saas_users` | Core | companies |
| 04 | `subscriptions` | Core | companies · plans · saas_users |
| 05 | `departments` | Business | companies |
| 06 | `job_titles` | Business | companies |
| 07 | `employees` | Business | companies · departments · job_titles |
| 08 | `employee_devices` | Security | employees · companies |
| 09 | `attendance` | Business | employees · companies |
| 10 | `salary_records` | Business | employees · companies |
| 11 | `finance_items` | Business | employees · companies · saas_users |
| 12 | `leaves` | Business | employees · companies · saas_users |
| 13 | `platform_settings` | System | لا اعتمادية |
| 14 | `company_settings` | System | companies |
| 15 | `employee_notifications` | Notification | employees · companies |
| 16 | `admin_notifications` | Notification | companies |
| 17 | `platform_announcements` | System | saas_users |
| 18 | `audit_logs` | Audit | companies · saas_users (soft) |

**المجموع: 18 جدول**

---

---

## ┌── LOOKUP LAYER ──────────────────────────────────────────────

---

### 01 · `plans`
**الغرض:** خطط الاشتراك المتاحة في المنصة — جدول مرجعي ثابت نسبياً

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `slug` | TEXT | UNIQUE · NOT NULL | المعرف النصي: starter / pro / enterprise |
| `display_name` | JSONB | NOT NULL · DEFAULT '{}' | الاسم متعدد اللغات: {"ar": "الباقة الاحترافية", "en": "Pro Plan"} |
| `max_employees` | INTEGER | NOT NULL · CHECK > 0 | الحد الأقصى للموظفين |
| `price_monthly` | NUMERIC(10,2) | NOT NULL · DEFAULT 0 | السعر الشهري |
| `price_yearly` | NUMERIC(10,2) | NOT NULL · DEFAULT 0 | السعر السنوي |
| `features` | JSONB | NOT NULL · DEFAULT '{}' | قائمة الميزات المتاحة |
| `is_active` | BOOLEAN | NOT NULL · DEFAULT TRUE | هل الخطة متاحة للبيع |
| `sort_order` | SMALLINT | NOT NULL · DEFAULT 0 | ترتيب العرض |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- لا FK صادرة
- مُرجَع إليه من: `companies.plan_id` · `subscriptions.plan_id`

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `slug`
- INDEX على `is_active`

**Constraints:**
- CHECK: `max_employees > 0`
- CHECK: `price_monthly >= 0`
- CHECK: `price_yearly >= 0`

---

---

## ┌── CORE LAYER ────────────────────────────────────────────────

---

### 02 · `companies`
**الغرض:** الشركات المشتركة في المنصة — محور النظام Multi-Tenant

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_name` | TEXT | NOT NULL | اسم الشركة |
| `company_code` | TEXT | UNIQUE · NOT NULL | الكود المختصر الفريد |
| `status` | TEXT | NOT NULL · DEFAULT 'pending' | active / suspended / pending / expired |
| `plan_id` | UUID | FK → plans.id · SET NULL | الخطة الحالية |
| `max_employees` | INTEGER | NOT NULL · DEFAULT 50 | الحد الأقصى (قابل للتخصيص per company) |
| `logo_url` | TEXT | | رابط شعار الشركة |
| `country` | TEXT | DEFAULT 'IQ' | رمز البلد |
| `notes` | TEXT | DEFAULT '' | ملاحظات داخلية للـ SA |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `deleted_at` | TIMESTAMPTZ | | Soft Delete |

**العلاقات:**
- `plan_id` → `plans.id` (ON DELETE SET NULL)
- مُرجَع إليه من: جميع الجداول التشغيلية عبر `company_id`

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `company_code`
- INDEX على `status`
- INDEX على `plan_id`
- INDEX على `deleted_at` (partial: WHERE deleted_at IS NULL)

**Constraints:**
- CHECK: `status IN ('active', 'suspended', 'pending', 'expired')`
- CHECK: `max_employees > 0`

> **ملاحظة (تعديل v2 Review):** تم حذف عمود `plan_tier` (denormalized). `plan_tier` يُقرأ دائماً من JOIN مع `plans` عبر `plan_id` — لا يُخزَّن مكرراً تفادياً لاختلاف البيانات.

**RLS:** غير مطبّق مباشرة — يُقرأ عبر RPCs أو super admin فقط

---

### 03 · `saas_users`
**الغرض:** جميع مستخدمي المنصة: Super Admin، Company Admin، Company User

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `username` | TEXT | UNIQUE · NOT NULL | اسم المستخدم |
| `display_name` | TEXT | DEFAULT '' | الاسم للعرض |
| `email` | TEXT | | البريد الإلكتروني (اختياري) |
| `password_hash` | TEXT | | Hash كلمة المرور (bcrypt) |
| `password_algo` | TEXT | DEFAULT 'bcrypt' | خوارزمية التشفير |
| `role` | TEXT | NOT NULL · DEFAULT 'company_user' | super_admin / company_admin / company_user |
| `permissions` | JSONB | NOT NULL · DEFAULT '{}' | مصفوفة الصلاحيات التفصيلية |
| `company_id` | UUID | FK → companies.id · SET NULL | NULL للـ super_admin |
| `is_active` | BOOLEAN | NOT NULL · DEFAULT TRUE | |
| `force_password_reset` | BOOLEAN | NOT NULL · DEFAULT FALSE | |
| `last_login` | TIMESTAMPTZ | | آخر تسجيل دخول |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `deleted_at` | TIMESTAMPTZ | | Soft Delete |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE SET NULL) · NULLABLE للـ super_admin
- مُرجَع إليه من: `subscriptions.activated_by_id` · `finance_items.created_by_id` · `leaves.created_by_id` · `platform_announcements.created_by_id` · `audit_logs.actor_id`

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `username`
- INDEX على `company_id`
- INDEX على `role`
- INDEX على `is_active`

**Constraints:**
- CHECK: `role IN ('super_admin', 'company_admin', 'company_user')`
- CHECK: `company_id IS NULL OR role != 'super_admin'` — super_admin لا ينتمي لشركة

**RLS:**
- مستخدم مصادق يرى سجله فقط
- company_admin/user يرى مستخدمي شركته فقط
- super_admin يرى الكل (عبر SECURITY DEFINER)

---

### 04 · `subscriptions`
**الغرض:** سجل تاريخي لاشتراكات الشركات — يُمكّن تتبع التجديدات والتغييرات

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `plan_id` | UUID | FK → plans.id · SET NULL | الخطة |
| `plan_name` | TEXT | DEFAULT '' | نسخة denormalized لحفظ التاريخ |
| `start_date` | DATE | | تاريخ بدء الاشتراك |
| `end_date` | DATE | | تاريخ انتهاء الاشتراك |
| `status` | TEXT | NOT NULL · DEFAULT 'pending' | active / expired / cancelled / pending |
| `duration_months` | INTEGER | DEFAULT 1 | مدة الاشتراك بالأشهر |
| `amount` | NUMERIC(12,2) | DEFAULT 0 | المبلغ المدفوع |
| `notes` | TEXT | DEFAULT '' | ملاحظات |
| `activated_by_id` | UUID | FK → saas_users.id · SET NULL | SA الذي فعّل الاشتراك |
| `activated_by_name` | TEXT | DEFAULT '' | الاسم denormalized |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)
- `plan_id` → `plans.id` (ON DELETE SET NULL)
- `activated_by_id` → `saas_users.id` (ON DELETE SET NULL)

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `company_id`
- INDEX على `status`
- INDEX على `end_date`
- INDEX على `(company_id, status)` — composite للاستعلام الشائع

**Constraints:**
- CHECK: `status IN ('active', 'expired', 'cancelled', 'pending')`
- CHECK: `end_date IS NULL OR end_date >= start_date`
- CHECK: `amount >= 0`

**RLS:** يُقرأ ويُكتب عبر SECURITY DEFINER RPCs فقط

---

---

## ┌── BUSINESS LAYER ────────────────────────────────────────────

---

### 05 · `departments`
**الغرض:** أقسام الشركة — جدول بحث للـ employees وattendance

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `name` | TEXT | NOT NULL | اسم القسم |
| `description` | TEXT | DEFAULT '' | وصف القسم |
| `is_active` | BOOLEAN | NOT NULL · DEFAULT TRUE | |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)
- مُرجَع إليه من: `employees.dept_id`

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `company_id`
- UNIQUE على `(company_id, lower(trim(name)))` — لا قسمان بنفس الاسم في شركة واحدة
- **GIN INDEX على `name` (pg_trgm)** — للبحث النصي السريع

**Constraints:**
- UNIQUE: `(company_id, lower(trim(name)))`
- CHECK: `trim(name) <> ''`

**RLS:** الشركة ترى وتعدل أقسامها فقط

---

### 06 · `job_titles`
**الغرض:** المسميات الوظيفية للشركة — جدول بحث جديد في v2 (كان TEXT في v1)

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `name` | TEXT | NOT NULL | المسمى الوظيفي |
| `is_active` | BOOLEAN | NOT NULL · DEFAULT TRUE | |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)
- مُرجَع إليه من: `employees.job_title_id`

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `company_id`
- UNIQUE على `(company_id, lower(trim(name)))`
- **GIN INDEX على `name` (pg_trgm)** — للبحث النصي السريع

**Constraints:**
- UNIQUE: `(company_id, lower(trim(name)))`
- CHECK: `trim(name) <> ''`

**RLS:** الشركة ترى وتعدل مسمياتها فقط

---

### 07 · `employees`
**الغرض:** بيانات الموظفين الكاملة — المحور الرئيسي للـ Business Layer

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `name` | TEXT | NOT NULL | الاسم الكامل |
| `dept_id` | UUID | FK → departments.id · SET NULL | القسم (FK رسمي) |
| `dept_name` | TEXT | DEFAULT '' | اسم القسم (denormalized للأداء) |
| `job_title_id` | UUID | FK → job_titles.id · SET NULL | المسمى الوظيفي (FK) |
| `job_title` | TEXT | DEFAULT '' | المسمى الوظيفي (denormalized) |
| `phone` | TEXT | DEFAULT '' | رقم الهاتف |
| `email` | TEXT | DEFAULT '' | البريد الإلكتروني |
| `avatar_url` | TEXT | | رابط الصورة |
| `salary` | INTEGER | NOT NULL · DEFAULT 0 | الراتب الشهري |
| `salary_type` | TEXT | NOT NULL · DEFAULT 'monthly' | monthly / biweekly / commission / daily |
| `salary_half` | INTEGER | NOT NULL · DEFAULT 0 | راتب النصف (للـ biweekly) |
| `daily_rate` | INTEGER | NOT NULL · DEFAULT 0 | المعدل اليومي |
| `check_in` | TIME | DEFAULT '08:00' | وقت الحضور الرسمي |
| `check_out` | TIME | DEFAULT '17:00' | وقت الانصراف الرسمي |
| `open_hours` | BOOLEAN | NOT NULL · DEFAULT FALSE | ساعات مفتوحة (لا حساب تأخير/إضافي) |
| `remote_attend` | BOOLEAN | NOT NULL · DEFAULT FALSE | دوام عن بعد |
| `include_overtime_in_salary` | BOOLEAN | NOT NULL · DEFAULT FALSE | تضمين الإضافي في الراتب |
| `sal_status` | TEXT | DEFAULT 'pending' | حالة الراتب الحالية |
| `next_salary_bonus` | INTEGER | NOT NULL · DEFAULT 0 | مكافأة تضاف للراتب القادم مرة واحدة |
| `is_active` | BOOLEAN | NOT NULL · DEFAULT TRUE | الموظف نشط |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `deleted_at` | TIMESTAMPTZ | | Soft Delete |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)
- `dept_id` → `departments.id` (ON DELETE SET NULL)
- `job_title_id` → `job_titles.id` (ON DELETE SET NULL)
- مُرجَع إليه من: `attendance` · `employee_devices` · `salary_records` · `finance_items` · `leaves` · `employee_notifications`

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `company_id`
- INDEX على `dept_id`
- INDEX على `is_active`
- INDEX على `(company_id, is_active)` — composite للاستعلام الشائع
- INDEX على `created_at DESC`
- **GIN INDEX على `name` (pg_trgm)** — للبحث النصي السريع (ILIKE autocomplete)
- **Partial INDEX على `(company_id, is_active) WHERE deleted_at IS NULL`** — لاستعلامات الموظفين النشطين

**Constraints:**
- CHECK: `salary_type IN ('monthly', 'biweekly', 'commission', 'daily')`
- CHECK: `salary >= 0`
- CHECK: `daily_rate >= 0`
- CHECK: `trim(name) <> ''`

**ملاحظة Trigger للنزاهة:**
عند إدراج/تحديث سجل في attendance أو finance_items أو salary_records أو leaves يجب أن يُطابق `company_id` في الجدول الفرعي `company_id` الموجود في `employees` لنفس `employee_id`. يُطبّق عبر BEFORE INSERT/UPDATE Trigger على كل جدول.

**ملاحظة denormalization:**
`dept_name` و `job_title` محفوظان كـ text مكرر من جداولهما الأصلية.
هذا متعمّد للأداء — يُجنّب JOIN في استعلامات الحضور والرواتب.
تُحدَّث هذه الحقول تلقائياً عند تعديل القسم أو المسمى عبر trigger أو RPC.

---

### 08 · `employee_devices`
**الغرض:** ربط أجهزة الموظفين (Device Binding) للحضور بالبصمة

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `employee_id` | UUID | FK → employees.id · CASCADE · NOT NULL | الموظف |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `slot` | SMALLINT | NOT NULL · CHECK BETWEEN 1 AND 5 | رقم الجهاز (1 إلى 5) |
| `label` | TEXT | DEFAULT '' | وصف الجهاز (الهاتف الأول...) |
| `fingerprint` | TEXT | DEFAULT '' | SHA-256 hash للبصمة (hex 64 char) — لا تُخزَّن البصمة الخام |
| `ip` | TEXT | DEFAULT '' | آخر IP مسجّل |
| `registration_token` | TEXT | | رمز QR مؤقت للربط |
| `token_created_at` | TIMESTAMPTZ | | وقت توليد الرمز |
| `token_expires_at` | TIMESTAMPTZ | | **وقت انتهاء صلاحية الرمز (TTL: 30 دقيقة)** |
| `token_used_at` | TIMESTAMPTZ | | وقت استخدام الرمز |
| `push_token` | TEXT | | **رمز Push Notification للـ Mobile App** |
| `device_info` | JSONB | DEFAULT '{}' | معلومات الجهاز (OS, browser, screen) |
| `linked_at` | TIMESTAMPTZ | | تاريخ الربط الناجح |
| `last_used_at` | TIMESTAMPTZ | | آخر استخدام |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `employee_id` → `employees.id` (ON DELETE CASCADE)
- `company_id` → `companies.id` (ON DELETE CASCADE)

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `(employee_id, slot)` — موظف يملك جهازاً واحداً في كل slot
- INDEX على `employee_id`
- INDEX على `fingerprint` — للبحث السريع عند تسجيل الحضور
- INDEX partial على `registration_token WHERE registration_token IS NOT NULL`
- INDEX partial على `push_token WHERE push_token IS NOT NULL`

**Constraints:**
- UNIQUE: `(employee_id, slot)`
- CHECK: `slot BETWEEN 1 AND 5`
- CHECK: `length(fingerprint) = 64 OR fingerprint = ''` — يضمن SHA-256 hash فقط
- CHECK: `token_expires_at IS NULL OR token_expires_at > token_created_at`

**RLS:**
- **لا SELECT مباشر لـ anon** — ممنوع الوصول المباشر للجدول
- التحقق من الـ fingerprint يتم حصراً عبر `SECURITY DEFINER` RPC تُرجع BOOLEAN فقط
- WRITE: فقط عبر SECURITY DEFINER RPCs

---

### 09 · `attendance`
**الغرض:** سجلات الحضور والانصراف اليومية

> **تغيير جوهري من v1:** الأعمدة `check_in`, `check_out` كانت TEXT → الآن TIME.
> `late`, `overtime`, `hours` كانت TEXT (نص عربي) → الآن INTEGER (بالدقائق).

> **استراتيجية Partitioning (تعديل Review):**
> هذا الجدول يُنشأ كـ **Partitioned Table** (RANGE Partitioning على `date_iso` — partition سنوياً).
> الهدف: ضمان الأداء عند 100 مليون سجل.
> كل partition يُغطي سنة كاملة: `attendance_2026`, `attendance_2027`, إلخ.
> الـ indexes والـ constraints تنطبق تلقائياً على كل partition.

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `employee_id` | UUID | FK → employees.id · CASCADE · NOT NULL | الموظف |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `emp_name` | TEXT | NOT NULL | الاسم (denormalized) |
| `dept_name` | TEXT | DEFAULT '' | القسم (denormalized) |
| `date_iso` | DATE | NOT NULL | التاريخ |
| `check_in_time` | TIME | | وقت الحضور الفعلي |
| `check_out_time` | TIME | | وقت الانصراف الفعلي |
| `work_minutes` | INTEGER | DEFAULT 0 · CHECK >= 0 | مجموع دقائق العمل |
| `late_minutes` | INTEGER | DEFAULT 0 · CHECK >= 0 | دقائق التأخير |
| `overtime_minutes` | INTEGER | DEFAULT 0 · CHECK >= 0 | دقائق العمل الإضافي |
| `status` | TEXT | NOT NULL · DEFAULT 'present' | present / late / absent / overtime / holiday / leave |
| `source` | TEXT | DEFAULT 'device' | مصدر السجل: device / admin / import |
| `notes` | TEXT | DEFAULT '' | ملاحظات |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `employee_id` → `employees.id` (ON DELETE CASCADE)
- `company_id` → `companies.id` (ON DELETE CASCADE)

**Indexes:**
- PRIMARY KEY على `id` (local per partition)
- UNIQUE على `(employee_id, date_iso)` — سجل واحد لكل موظف في اليوم
- INDEX على `company_id`
- INDEX على `(employee_id, date_iso DESC)` — composite للاستعلامات التاريخية
- INDEX على `(company_id, date_iso DESC)` — للوحة التحكم
- INDEX على `status`

**Constraints:**
- UNIQUE: `(employee_id, date_iso)`
- CHECK: `status IN ('present', 'late', 'absent', 'overtime', 'holiday', 'leave')`
- CHECK: `work_minutes >= 0`
- CHECK: `late_minutes >= 0`
- CHECK: `overtime_minutes >= 0`
- CHECK: `source IN ('device', 'admin', 'import')`

**RLS:** الشركة ترى سجلاتها · الموظف يرى سجلاته فقط (عبر بوابة الموظف)

---

### 10 · `salary_records`
**الغرض:** سجلات الرواتب المُصدرة — أرشيف كشوف الرواتب

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `employee_id` | UUID | FK → employees.id · CASCADE · NOT NULL | الموظف |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `period_key` | TEXT | NOT NULL | مفتاح الفترة: '2026-01' أو '2026-01-H1' |
| `period_start` | DATE | NOT NULL | **تاريخ بداية الفترة — للترتيب الزمني الصحيح** |
| `period_label` | TEXT | NOT NULL | الاسم: 'يناير 2026' / 'النصف الأول يناير' |
| `salary_type` | TEXT | NOT NULL | monthly / biweekly / commission / daily |
| `base_salary` | INTEGER | NOT NULL · DEFAULT 0 | الراتب الأساسي للفترة |
| `attend_days` | INTEGER | NOT NULL · DEFAULT 0 | أيام الحضور الفعلية |
| `absent_days` | INTEGER | NOT NULL · DEFAULT 0 | أيام الغياب |
| `late_minutes` | INTEGER | NOT NULL · DEFAULT 0 | مجموع دقائق التأخير |
| `late_deduct` | INTEGER | NOT NULL · DEFAULT 0 | خصم التأخير |
| `overtime_minutes` | INTEGER | NOT NULL · DEFAULT 0 | مجموع دقائق الإضافي |
| `overtime_amount` | INTEGER | NOT NULL · DEFAULT 0 | قيمة الإضافي |
| `bonus` | INTEGER | NOT NULL · DEFAULT 0 | المكافآت |
| `manual_deduct` | INTEGER | NOT NULL · DEFAULT 0 | الخصومات اليدوية |
| `loan_deduct` | INTEGER | NOT NULL · DEFAULT 0 | خصم السلف |
| `total_deduct` | INTEGER | NOT NULL · DEFAULT 0 | مجموع الخصومات |
| `net_salary` | INTEGER | NOT NULL · DEFAULT 0 | صافي الراتب |
| `daily_rate` | INTEGER | NOT NULL · DEFAULT 0 | المعدل اليومي المستخدم في الحساب (snapshot) |
| `late_deduct_rate` | INTEGER | NOT NULL · DEFAULT 0 | **معدل خصم التأخير المستخدم — snapshot لحظة الإصدار** |
| `overtime_hourly_rate` | INTEGER | NOT NULL · DEFAULT 0 | **معدل ساعة الإضافي المستخدم — snapshot لحظة الإصدار** |
| `period_days` | SMALLINT | NOT NULL · DEFAULT 30 | عدد أيام الفترة |
| `status` | TEXT | NOT NULL · DEFAULT 'pending' | pending / issued / paid |
| `issued_at` | TIMESTAMPTZ | | تاريخ الإصدار |
| `paid_at` | TIMESTAMPTZ | | تاريخ الدفع |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `employee_id` → `employees.id` (ON DELETE CASCADE)
- `company_id` → `companies.id` (ON DELETE CASCADE)

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `(employee_id, period_key)` — راتب واحد لكل موظف في كل فترة
- INDEX على `company_id`
- INDEX على `(employee_id, period_start DESC)` — ترتيب زمني صحيح
- INDEX على `(company_id, period_start DESC)` — ترتيب زمني صحيح
- INDEX على `status`

**Constraints:**
- UNIQUE: `(employee_id, period_key)`
- CHECK: `status IN ('pending', 'issued', 'paid')`
- CHECK: `net_salary >= 0`
- CHECK: `base_salary >= 0`
- CHECK: `late_deduct_rate >= 0`
- CHECK: `overtime_hourly_rate >= 0`
- CHECK: `salary_type IN ('monthly', 'biweekly', 'commission', 'daily')`

**RLS:** الشركة ترى رواتب موظفيها · الموظف يرى راتبه فقط

---

### 11 · `finance_items`
**الغرض:** الخصومات والمكافآت والسلف — جدول مستقل بدلاً من JSONB في v1

> **تغيير جوهري من v1:** في v1 كانت هذه البيانات مخزّنة كـ TEXT (JSON serialized) في جدول `app_settings` تحت المفتاح `company:X:finance_items`. الآن جدول حقيقي بأعمدة واضحة.

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `employee_id` | UUID | FK → employees.id · CASCADE · NOT NULL | الموظف |
| `type` | TEXT | NOT NULL | deduction / bonus / loan |
| `amount` | INTEGER | NOT NULL · CHECK > 0 | المبلغ |
| `loan_mode` | TEXT | | direct / installments (فقط للسلف) |
| `installment_count` | SMALLINT | DEFAULT 1 | عدد الأقساط |
| `installments_paid` | SMALLINT | NOT NULL · DEFAULT 0 | عدد الأقساط المسددة |
| `apply_period` | TEXT | | مفتاح الفترة التي تُطبّق فيها (NULL = الكل) |
| `status` | TEXT | NOT NULL · DEFAULT 'active' | active / paid / cancelled |
| `note` | TEXT | DEFAULT '' | ملاحظة |
| `created_by_id` | UUID | FK → saas_users.id · SET NULL | من أضاف الحركة |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)
- `employee_id` → `employees.id` (ON DELETE CASCADE)
- `created_by_id` → `saas_users.id` (ON DELETE SET NULL)

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `company_id`
- INDEX على `employee_id`
- INDEX على `(employee_id, status)` — للحسابات السريعة
- INDEX على `(company_id, type)`
- INDEX على `apply_period`
- **INDEX على `(employee_id, apply_period, status)`** — للحساب الشهري المتكامل

**Constraints:**
- CHECK: `type IN ('deduction', 'bonus', 'loan')`
- CHECK: `amount > 0`
- CHECK: `status IN ('active', 'paid', 'cancelled')`
- CHECK: `loan_mode IS NULL OR loan_mode IN ('direct', 'installments')`
- CHECK: `installment_count >= 1`
- CHECK: `installments_paid >= 0`
- CHECK: `installments_paid <= installment_count`

**RLS:** الشركة ترى وتعدل حركاتها المالية · الموظف لا يرى هذه البيانات مباشرة

---

### 12 · `leaves`
**الغرض:** إجازات الموظفين والغياب بأنواعه المختلفة

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `leave_ref` | TEXT | UNIQUE | رقم مرجعي تلقائي (LEAVE-YYYYMMDD-XXXX) |
| `employee_id` | UUID | FK → employees.id · CASCADE · NOT NULL | الموظف |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `leave_type` | TEXT | NOT NULL | paid_open / unpaid_open / paid_single / unpaid_single / absence_mult |
| `from_date` | DATE | NOT NULL | تاريخ البداية |
| `to_date` | DATE | | تاريخ النهاية (NULL للإجازات المفتوحة غير المنتهية) |
| `multiplier` | SMALLINT | DEFAULT 1 · CHECK >= 1 | مضاعف الغياب (للـ absence_mult) |
| `deduct_from_salary` | BOOLEAN | NOT NULL · DEFAULT FALSE | هل تُخصم من الراتب |
| `note` | TEXT | DEFAULT '' | ملاحظة |
| `approval_status` | TEXT | NOT NULL · DEFAULT 'approved' | **pending / approved / rejected** |
| `approved_by_id` | UUID | FK → saas_users.id · SET NULL | **من وافق على الإجازة** |
| `approved_at` | TIMESTAMPTZ | | **وقت الموافقة** |
| `created_by_id` | UUID | FK → saas_users.id · SET NULL | من أضاف الإجازة |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `deleted_at` | TIMESTAMPTZ | | Soft Delete |

**العلاقات:**
- `employee_id` → `employees.id` (ON DELETE CASCADE)
- `company_id` → `companies.id` (ON DELETE CASCADE)
- `created_by_id` → `saas_users.id` (ON DELETE SET NULL)
- `approved_by_id` → `saas_users.id` (ON DELETE SET NULL)

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `leave_ref`
- INDEX على `employee_id`
- INDEX على `company_id`
- INDEX على `(employee_id, from_date DESC)`
- INDEX على `(company_id, from_date DESC)`
- INDEX على `leave_type`
- **INDEX على `(company_id, approval_status)`** — لقوائم الموافقات المعلقة

**Constraints:**
- CHECK: `leave_type IN ('paid_open', 'unpaid_open', 'paid_single', 'unpaid_single', 'absence_mult')`
- CHECK: `to_date IS NULL OR to_date >= from_date`
- CHECK: `multiplier >= 1`
- CHECK: `approval_status IN ('pending', 'approved', 'rejected')`
- CHECK: `approved_at IS NULL OR approved_by_id IS NOT NULL` — لا وقت موافقة بدون موافق

**RLS:** الشركة ترى وتعدل إجازات موظفيها · الموظف يرى إجازاته فقط

---

---

## ┌── SYSTEM LAYER ──────────────────────────────────────────────

---

### 13 · `platform_settings`
**الغرض:** إعدادات المنصة العامة — يُديرها Super Admin فقط

> **تغيير من v1:** كانت مخلوطة مع إعدادات الشركات في جدول `app_settings`.

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `key` | TEXT | UNIQUE · NOT NULL | المفتاح (system_version، whatsapp_support...) |
| `value` | TEXT | DEFAULT '' | القيمة |
| `description` | TEXT | DEFAULT '' | وصف الإعداد |
| `is_public` | BOOLEAN | NOT NULL · DEFAULT FALSE | هل يظهر للشركات |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | **تاريخ الإنشاء** |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_by_id` | UUID | FK → saas_users.id · SET NULL | من عدّله |

**العلاقات:**
- `updated_by_id` → `saas_users.id` (ON DELETE SET NULL)

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `key`
- INDEX على `is_public`

**Constraints:**
- CHECK: `trim(key) <> ''`

**RLS:**
- READ: مسموح للكل إذا `is_public = true`
- READ/WRITE: Super Admin فقط عبر SECURITY DEFINER

---

### 14 · `company_settings`
**الغرض:** إعدادات خاصة بكل شركة — مفصولة عن إعدادات المنصة

> **تغيير من v1:** كانت مخلوطة مع إعدادات المنصة وبيانات Finance في `app_settings`.

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `key` | TEXT | NOT NULL | المفتاح (currency، timezone، gps_lat...) |
| `value` | TEXT | DEFAULT '' | القيمة |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**أمثلة على المفاتيح المعيارية:**
- `currency` — العملة (IQD)
- `timezone` — المنطقة الزمنية (Asia/Baghdad)
- `month_days` — أيام الشهر المعتمدة (30)
- `clock_format` — تنسيق الساعة (12/24)
- `late_deduct_rate` — قيمة خصم الدقيقة
- `overtime_hourly_rate` — قيمة ساعة الإضافي
- `gps_name` — اسم موقع الشركة
- `gps_lat` — خط العرض
- `gps_lng` — خط الطول
- `gps_range` — نطاق السماح (متر)
- `company_name` — اسم الشركة للعرض

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `(company_id, key)`
- INDEX على `company_id`

**Constraints:**
- UNIQUE: `(company_id, key)`
- CHECK: `trim(key) <> ''`

**RLS:** الشركة ترى وتعدل إعداداتها فقط

---

---

## ┌── NOTIFICATION LAYER ────────────────────────────────────────

---

### 15 · `employee_notifications`
**الغرض:** إشعارات موجّهة للموظفين (مالية، إجازات، تنبيهات)

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `notif_ref` | TEXT | UNIQUE | رقم مرجعي تلقائي |
| `employee_id` | UUID | FK → employees.id · CASCADE · NOT NULL | الموظف |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `notif_type` | TEXT | NOT NULL · DEFAULT 'info' | info / salary / leave / finance / warning / system |
| `title` | TEXT | NOT NULL | عنوان الإشعار |
| `body` | TEXT | DEFAULT '' | نص الإشعار |
| `is_read` | BOOLEAN | NOT NULL · DEFAULT FALSE | هل قرأه الموظف |
| `action_url` | TEXT | | رابط اختياري |
| `meta` | JSONB | DEFAULT '{}' | بيانات إضافية مرتبطة |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `employee_id` → `employees.id` (ON DELETE CASCADE)
- `company_id` → `companies.id` (ON DELETE CASCADE)

**Indexes:**
- PRIMARY KEY على `id`
- UNIQUE على `notif_ref`
- INDEX على `(employee_id, is_read)`
- INDEX على `company_id`
- INDEX على `created_at DESC`

**Constraints:**
- CHECK: `notif_type IN ('info', 'salary', 'leave', 'finance', 'warning', 'system')`

**RLS:** الموظف يرى إشعاراته فقط · الشركة تُنشئها وترى الكل

---

### 16 · `admin_notifications`
**الغرض:** إشعارات موجّهة لمسؤولي الشركة

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · CASCADE · NOT NULL | الشركة |
| `notif_type` | TEXT | NOT NULL · DEFAULT 'info' | info / warning / system / subscription / security |
| `title` | TEXT | NOT NULL | عنوان الإشعار |
| `body` | TEXT | DEFAULT '' | نص الإشعار |
| `read_at` | TIMESTAMPTZ | | **وقت القراءة — NULL = لم يُقرأ بعد** |
| `read_by_id` | UUID | FK → saas_users.id · SET NULL | **من قرأ الإشعار** |
| `meta` | JSONB | DEFAULT '{}' | بيانات إضافية |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE CASCADE)
- `read_by_id` → `saas_users.id` (ON DELETE SET NULL)

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `(company_id, read_at)` — NULL read_at = غير مقروء
- INDEX على `created_at DESC`

**Constraints:**
- CHECK: `notif_type IN ('info', 'warning', 'system', 'subscription', 'security')`
- CHECK: `read_at IS NULL OR read_by_id IS NOT NULL` — لا وقت قراءة بدون قارئ

**RLS:** الشركة ترى إشعاراتها فقط

---

### 17 · `platform_announcements`
**الغرض:** إعلانات المنصة من Super Admin لجميع الشركات — جدول مستقل جديد

> **جديد في v2:** في v1 كانت مخزّنة كـ JSONB في app_settings.

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `title` | TEXT | NOT NULL | عنوان الإعلان |
| `body` | TEXT | DEFAULT '' | نص الإعلان |
| `type` | TEXT | NOT NULL · DEFAULT 'info' | info / warning / maintenance / urgent |
| `target_type` | TEXT | NOT NULL · DEFAULT 'all' | **all / plan / company** |
| `target_id` | UUID | | **UUID الخطة أو الشركة (NULL إذا target_type = 'all')** |
| `is_active` | BOOLEAN | NOT NULL · DEFAULT TRUE | هل الإعلان ظاهر |
| `show_from` | TIMESTAMPTZ | | تاريخ البدء |
| `expires_at` | TIMESTAMPTZ | | تاريخ الانتهاء (NULL = لا ينتهي) |
| `created_by_id` | UUID | FK → saas_users.id · SET NULL | SA الذي أنشأه |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `created_by_id` → `saas_users.id` (ON DELETE SET NULL)

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `is_active`
- INDEX على `expires_at`
- INDEX على `(is_active, expires_at)` — composite للاستعلام الشائع

**Constraints:**
- CHECK: `type IN ('info', 'warning', 'maintenance', 'urgent')`
- CHECK: `target_type IN ('all', 'plan', 'company')`
- CHECK: `(target_type = 'all' AND target_id IS NULL) OR (target_type IN ('plan','company') AND target_id IS NOT NULL)`

**RLS:**
- READ: جميع المستخدمين المصادقين (للإعلانات النشطة)
- WRITE: Super Admin فقط عبر SECURITY DEFINER

---

---

## ┌── AUDIT LAYER ───────────────────────────────────────────────

---

### 18 · `audit_logs`
**الغرض:** سجل تدقيق غير قابل للتعديل أو الحذف — كل عملية مهمة في النظام

> **استراتيجية Partitioning (تعديل Review):**
> هذا الجدول يُنشأ كـ **Partitioned Table** (RANGE Partitioning على `created_at` — partition ربع سنوياً).
> الهدف: التحكم في النمو غير المحدود والأداء عند الاستعلام التاريخي.
> كل partition يُغطي ربع سنة: `audit_logs_2026_q1`, `audit_logs_2026_q2`, إلخ.

**أهم الأعمدة:**

| العمود | النوع | القيد | الوصف |
|--------|-------|-------|-------|
| `id` | UUID | PK · DEFAULT gen_random_uuid() | المعرف الفريد |
| `company_id` | UUID | FK → companies.id · SET NULL · NULLABLE | الشركة (NULL لعمليات المنصة) |
| `actor_id` | UUID | FK → saas_users.id · SET NULL · NULLABLE | المستخدم (NULL للنظام) |
| `actor_name` | TEXT | DEFAULT '' | الاسم denormalized |
| `actor_role` | TEXT | DEFAULT '' | الدور denormalized |
| `action` | TEXT | NOT NULL | اسم العملية (employee_created، salary_issued...) |
| `category` | TEXT | NOT NULL | تصنيف (employees / payroll / attendance / auth / system...) |
| `details` | TEXT | DEFAULT '' | وصف تفصيلي |
| `target_id` | TEXT | | UUID السجل المُتأثر |
| `target_name` | TEXT | DEFAULT '' | اسم السجل المُتأثر |
| `before_state` | JSONB | | حالة السجل قبل التغيير |
| `after_state` | JSONB | | حالة السجل بعد التغيير |
| `ip_address` | INET | | عنوان IP |
| `user_agent` | TEXT | | معلومات المتصفح |
| `meta` | JSONB | DEFAULT '{}' | بيانات إضافية |
| `created_at` | TIMESTAMPTZ | NOT NULL · DEFAULT NOW() | |

**العلاقات:**
- `company_id` → `companies.id` (ON DELETE SET NULL) — NULLABLE
- `actor_id` → `saas_users.id` (ON DELETE SET NULL) — NULLABLE

**Indexes:**
- PRIMARY KEY على `id`
- INDEX على `company_id`
- INDEX على `actor_id`
- INDEX على `action`
- INDEX على `category`
- INDEX على `created_at DESC`
- INDEX على `(company_id, created_at DESC)` — composite للعرض الشائع

**Constraints:**
- لا DELETE في RLS — append-only
- لا UPDATE في RLS — immutable

**RLS:**
- INSERT: عبر SECURITY DEFINER فقط (لا يكتب المستخدم مباشرة)
- SELECT: مسؤول الشركة يرى logs شركته · Super Admin يرى الكل
- UPDATE: ممنوع لجميع الأدوار
- DELETE: ممنوع لجميع الأدوار

---

---

## ملخص المفاتيح والقيود الكاملة

### مفاتيح أساسية (Primary Keys)
- جميع الجداول: `id UUID DEFAULT gen_random_uuid()` ← 18 جدول

### مفاتيح خارجية (Foreign Keys)
| الجدول | العمود | المرجع | عند الحذف |
|--------|--------|--------|-----------|
| companies | plan_id | plans.id | SET NULL |
| saas_users | company_id | companies.id | SET NULL |
| subscriptions | company_id | companies.id | CASCADE |
| subscriptions | plan_id | plans.id | SET NULL |
| subscriptions | activated_by_id | saas_users.id | SET NULL |
| departments | company_id | companies.id | CASCADE |
| job_titles | company_id | companies.id | CASCADE |
| employees | company_id | companies.id | CASCADE |
| employees | dept_id | departments.id | SET NULL |
| employees | job_title_id | job_titles.id | SET NULL |
| employee_devices | employee_id | employees.id | CASCADE |
| employee_devices | company_id | companies.id | CASCADE |
| attendance | employee_id | employees.id | CASCADE |
| attendance | company_id | companies.id | CASCADE |
| salary_records | employee_id | employees.id | CASCADE |
| salary_records | company_id | companies.id | CASCADE |
| finance_items | company_id | companies.id | CASCADE |
| finance_items | employee_id | employees.id | CASCADE |
| finance_items | created_by_id | saas_users.id | SET NULL |
| leaves | employee_id | employees.id | CASCADE |
| leaves | company_id | companies.id | CASCADE |
| leaves | created_by_id | saas_users.id | SET NULL |
| leaves | approved_by_id | saas_users.id | SET NULL |
| company_settings | company_id | companies.id | CASCADE |
| employee_notifications | employee_id | employees.id | CASCADE |
| employee_notifications | company_id | companies.id | CASCADE |
| admin_notifications | company_id | companies.id | CASCADE |
| admin_notifications | read_by_id | saas_users.id | SET NULL |
| platform_announcements | created_by_id | saas_users.id | SET NULL |
| platform_settings | updated_by_id | saas_users.id | SET NULL |
| audit_logs | company_id | companies.id | SET NULL |
| audit_logs | actor_id | saas_users.id | SET NULL |

### Unique Constraints
| الجدول | الأعمدة |
|--------|--------|
| plans | slug |
| companies | company_code |
| saas_users | username |
| departments | (company_id, lower(trim(name))) |
| job_titles | (company_id, lower(trim(name))) |
| employee_devices | (employee_id, slot) |
| attendance | (employee_id, date_iso) |
| salary_records | (employee_id, period_key) |
| leaves | leave_ref |
| employee_notifications | notif_ref |
| platform_settings | key |
| company_settings | (company_id, key) |

### Soft Delete (deleted_at)
- `companies`
- `saas_users`
- `employees`
- `departments`
- `leaves`

---

## مصفوفة RLS الكاملة

| الجدول | anon R | auth R | auth W | SA | ملاحظة |
|--------|--------|--------|--------|----|----|
| plans | ✅ | ✅ | ❌ | ✅ | للقراءة العامة |
| companies | ❌ | own | SA-only | ✅ | عبر RPCs |
| saas_users | ❌ | own/co | own | ✅ | |
| subscriptions | ❌ | own-co | ❌ | ✅ | عبر RPCs |
| departments | ❌ | own-co | own-co | ✅ | |
| job_titles | ❌ | own-co | own-co | ✅ | |
| employees | ❌ | own-co | own-co | ✅ | |
| employee_devices | ❌ DEFINER | own-co | ❌ | ✅ | لا SELECT مباشر — RPC BOOLEAN فقط |
| attendance | ❌ | own-co | own-co | ✅ | موظف يرى سجله |
| salary_records | ❌ | own-co | ❌ | ✅ | عبر RPCs |
| finance_items | ❌ | own-co | own-co | ✅ | |
| leaves | ❌ | own-co | own-co | ✅ | |
| platform_settings | 🌐 pub | ✅ | ❌ | ✅ | is_public فقط للـ anon |
| company_settings | ❌ | own-co | own-co | ✅ | |
| employee_notifications | ❌ | own-emp | ❌ | ✅ | موظف يرى إشعاراته |
| admin_notifications | ❌ | own-co | own-co | ✅ | |
| platform_announcements | ❌ | ✅ R | ❌ | ✅ | كل مصادَق يقرأ |
| audit_logs | ❌ | own-co R | ❌ DEFINER | ✅ | append-only |

---

---

## سجل التغييرات (Changelog)

| التعديل | السبب | المرحلة |
|---------|-------|---------|
| حذف `plans.display_name_ar` + تحويل `display_name` إلى JSONB | دعم متعدد اللغات بدون تغيير schema | Review C1/I5 |
| حذف `companies.plan_tier` | تجنب عدم الاتساق مع plans | Review C6 |
| إضافة `employee_devices.token_expires_at` | أمان TTL للـ QR Tokens | Review C2 |
| إضافة `employee_devices.push_token` | دعم Mobile Push Notifications | Review I9 |
| تغيير `employee_devices.slot` من `IN(1,2)` إلى `BETWEEN 1 AND 5` | مرونة أعلى | Review C7 |
| إضافة `leaves.approval_status/approved_by_id/approved_at` | دعم Approval Workflow | Review C3 |
| إضافة `salary_records.period_start` | ترتيب زمني صحيح | Review I8 |
| إضافة `salary_records.late_deduct_rate/overtime_hourly_rate` | snapshot المعدلات | Review C5 |
| إضافة `platform_settings.created_at` | اكتمال التدقيق | Review C8 |
| تغيير `admin_notifications.is_read` → `read_at + read_by_id` | تتبع القراءة متعدد المستخدمين | Review I10 |
| تقسيم `platform_announcements.target` → `target_type + target_id` | سلامة البيانات | Review I11 |
| Partitioning على `attendance` و `audit_logs` | أداء على 100M سجل | Review I1 |
| GIN Trigram indexes على `name` في employees/departments/job_titles | بحث نصي سريع | Review I2 |
| Partial indexes على جداول Soft Delete | أداء استعلامات نشطة | Review I3 |
| إضافة INDEX `(employee_id, apply_period, status)` في finance_items | حساب الراتب المتكامل | Review I4 |
| تحديد fingerprint = SHA-256 hash | أمان بيانات الجهاز | Review I6 |
| تعديل anon RLS على employee_devices → لا SELECT مباشر | أمان المصادقة | Review I7 |

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الرابعة (Database Finalization)*
*النسخة النهائية — جاهز للمراجعة قبل كتابة الـ Migrations*
