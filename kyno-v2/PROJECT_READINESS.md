# KYNO v2 — Project Readiness Report
**المراجع:** Principal Software Architect + PostgreSQL Expert + Security Reviewer
**تاريخ المراجعة:** يوليو 2026
**النطاق:** 15 وثيقة — Architecture · Database · Security · Developer Experience

---

## نسب الجاهزية

```
┌──────────────────────────────────────────────────────────────┐
│                   KYNO v2 — Readiness Scores                 │
├─────────────────────────────────┬────────────┬───────────────┤
│ المجال                           │ النسبة     │ الحالة        │
├─────────────────────────────────┼────────────┼───────────────┤
│ ✅ جاهزية الوثائق والتصميم       │  93 / 100  │ ممتاز         │
│ ✅ جاهزية قاعدة البيانات         │  89 / 100  │ جيد جداً      │
│ ✅ جاهزية الكود (Foundation)     │  88 / 100  │ جيد جداً      │
│ ✅ جاهزية الأمن                  │  87 / 100  │ جيد جداً      │
│ ✅ جاهزية التوسع (Scalability)   │  88 / 100  │ جيد جداً      │
│ ✅ جاهزية الإطلاق (Launch-Ready) │  72 / 100  │ تحتاج أعمال   │
├─────────────────────────────────┼────────────┼───────────────┤
│ 📊 المتوسط الكلي                  │  86 / 100  │ جاهز مع ملاحظات│
└─────────────────────────────────┴────────────┴───────────────┘
```

> **ملاحظة:** "جاهزية الإطلاق" منخفضة بشكل متوقع — المشروع لم يُبنَ بعد.
> النسبة تعكس مرحلة التخطيط والتأسيس، وليس التطوير المكتمل.

---

---

## 1. Consistency Review — تحقق من التوافق

---

### ✅ ما هو متوافق تماماً

| الوثيقة ← الوثيقة | الحالة | الملاحظة |
|-------------------|--------|---------|
| DatabaseSpecification.md ↔ ERD.md | ✅ متوافق | جميع الجداول والأعمدة متطابقة بعد Phase 4 |
| DatabaseSpecification.md ↔ MigrationPlan.md | ✅ متوافق | كل migration يُنشئ ما هو محدد في Spec |
| Architecture.md ↔ DatabaseSpecification.md | ✅ متوافق | Multi-Tenant، UUID، RLS، Edge Functions |
| Architecture.md ↔ FolderStructure.md | ✅ متوافق | الطبقات تنعكس في بنية المجلدات |
| Roles.md ↔ DatabaseSpecification.md (RLS Matrix) | ✅ متوافق | الصلاحيات الموثّقة متوافقة مع RLS المخطط |
| FolderStructure.md ↔ kyno-v2/ الفعلية | ✅ متوافق | جميع المجلدات منشأة |
| CODING_STANDARDS.md ↔ NAMING_CONVENTION.md | ✅ متوافق | لا تعارض بين المعيارين |
| ENV_VARS.md ↔ .env.example | ✅ متوافق | جميع المتغيرات موثّقة |
| GIT_STRATEGY.md ↔ DEV_RULES.md | ✅ متوافق | القواعد متناسقة |

---

### ⚠ تعارضات وجدت — تحتاج انتباهاً

---

#### تعارض 1: Roadmap.md — مخطط قديم للـ Migrations
**الملف:** `docs/v2/Roadmap.md` — Phase 02
**المشكلة:**
Roadmap.md (مكتوب في Phase 1) يذكر:
```
"001_kyno_v2_baseline.sql" — migration واحد يحتوي كل الجداول
"002_rls_policies.sql"
"003_tenant_helpers.sql"
```
لكن MigrationPlan.md (الموثّق المعتمد) يحدد **22 migration** منفصل.

**السبب:** Roadmap.md كُتب قبل Phase 2 (Database Design) وقبل Phase 4 (Finalization).
**الخطورة:** منخفضة — MigrationPlan.md هو المرجع الموثوق.
**الحل:** يكفي ملاحظة ذهنية أن MigrationPlan.md يُلغي تفاصيل Roadmap Phase 02. لا تعديل ضروري.

---

#### تعارض 2: Super Admin Member — غياب في Schema
**الملفان:** `docs/v2/Roles.md` ↔ `docs/v2/DatabaseSpecification.md`
**المشكلة:**
Roles.md يعرّف **5 مستويات مستخدم**، ضمنها:
- Level 4: **Super Admin Member** (SAM) — عضو فريق المنصة بصلاحيات مخصصة

لكن DatabaseSpec تحدد CHECK constraint في `saas_users`:
```
CHECK: role IN ('super_admin', 'company_admin', 'company_user')
```
`super_admin_member` غير موجود كقيمة صريحة في الـ Schema.

**التساؤل:** هل SAM يُخزَّن كـ `role = 'super_admin'` مع `permissions JSONB` محدودة؟

**الإجابة المنطقية:**
- نعم — SAM يُخزَّن كـ `role = 'super_admin'` بحيث يخضع لنفس RLS bypass
- الفرق الوحيد في `permissions JSONB` التي تحدد ما يراه في الـ UI
- هذا تصميم صحيح وظيفياً لكنه **غير موثّق بوضوح**

**الخطورة:** متوسطة — تؤثر على كتابة M005 (saas_users) وعلى RPC إنشاء SA Members.
**يجب حله قبل:** M005

---

#### تعارض 3: Modules.md "Devices" ↔ FolderStructure "attendance/device-mgmt.js"
**الملفان:** `docs/v2/Modules.md` ↔ `docs/v2/FolderStructure.md`
**المشكلة:**
- Modules.md يُدرج Devices كـ Module رقم 5 منفصل
- FolderStructure.md يضع `device-mgmt.js` داخل `attendance/`

**الخطورة:** منخفضة — القرار الفعلي (دمج Devices في Attendance) موثّق في Modules.md نفسه.
**الحل:** لا تعديل مطلوب — القرار واضح.

---

---

## 2. Missing Requirements — المتطلبات الغائبة

---

### ✅ Features موجودة في Roadmap ومُغطّاة في Database

| Feature | مكانها في DB | الحالة |
|---------|------------|--------|
| Device fingerprint auth | employee_devices.fingerprint (SHA-256) | ✅ |
| GPS validation | company_settings keys: gps_lat/lng/range | ✅ |
| Approval Workflow للإجازات | leaves.approval_status/approved_by_id | ✅ |
| Multi-language plans | plans.display_name JSONB | ✅ |
| Subscription banner | subscriptions.end_date + status | ✅ |
| Finance items (deductions/bonuses/loans) | finance_items جدول مستقل | ✅ |
| Audit trail | audit_logs (append-only, partitioned) | ✅ |
| Push notifications | employee_devices.push_token | ✅ |

---

### ⚠ Features في Roadmap بدون جداول مخصصة

| Feature | الحالة | التبرير |
|---------|--------|---------|
| Analytics/Reports | ❌ جدول مستقل | يستخدم existing tables + future Materialized Views — مقبول |
| Backup | ❌ جدول مستقل | يعمل عبر RPCs على الجداول الموجودة — مقبول |
| Monitoring | ❌ جدول مستقل | يستخدم audit_logs + system health RPCs — مقبول |
| Support (WhatsApp) | ❌ جدول مستقل | يستخدم platform_settings.support_whatsapp — مقبول |
| API Keys (Phase 22) | ❌ api_keys table | مستقبلي — مقبول |
| Scheduled Backup | ❌ | مستقبلي — مقبول |

**تقييم:** جميع الغيابات متعمدة ومبررة. لا مشكلة.

---

### ⚠ جداول بدون Migration Integrity Triggers واضحة

| الجدول | المشكلة |
|--------|---------|
| `attendance` (M011) | لا يذكر MigrationPlan trigger يتحقق أن `company_id = employees.company_id` |
| `salary_records` (M012) | نفس المشكلة |
| `finance_items` (M013) | ✅ مذكور |
| `leaves` (M014) | ✅ مذكور |

**الخطورة:** متوسطة — غياب الـ trigger يعني إمكانية إدراج بيانات attendance لشركة A بـ company_id لشركة B.
**يجب حله قبل:** M011 و M012.

---

---

## 3. Migration Validation — مراجعة الترتيب

---

### ✅ الترتيب الكامل مُراجَع

```
M001 → Extensions          لا FKs — ✅
M002 → Helper Functions    لا FKs — ✅
M003 → plans               لا FKs صادرة — ✅
M004 → companies           plan_id → plans (M003) ✅
M005 → saas_users          company_id → companies (M004) ✅
M006 → subscriptions       company_id → companies (M004) ✅
                           plan_id → plans (M003) ✅
                           activated_by_id → saas_users (M005) ✅
M007 → departments         company_id → companies (M004) ✅
M008 → job_titles          company_id → companies (M004) ✅
M009 → employees           company_id → companies (M004) ✅
                           dept_id → departments (M007) ✅
                           job_title_id → job_titles (M008) ✅
M010 → employee_devices    employee_id → employees (M009) ✅
                           company_id → companies (M004) ✅
M011 → attendance          employee_id → employees (M009) ✅
M012 → salary_records      employee_id → employees (M009) ✅
M013 → finance_items       employee_id → employees (M009) ✅
                           created_by_id → saas_users (M005) ✅
M014 → leaves              employee_id → employees (M009) ✅
                           created_by_id → saas_users (M005) ✅
                           approved_by_id → saas_users (M005) ✅
M015 → platform_settings   updated_by_id → saas_users (M005) ✅
M016 → company_settings    company_id → companies (M004) ✅
M017 → notifications       company_id → companies (M004) ✅
                           read_by_id → saas_users (M005) ✅
M018 → announcements       created_by_id → saas_users (M005) ✅
M019 → audit_logs          company_id → companies (M004) ✅
                           actor_id → saas_users (M005) ✅
M020 → RLS Core            يعتمد M002 functions ✅
M021 → RLS System          يعتمد M002 functions ✅
M022 → Seeds               يعتمد M003, M005, M015 ✅
```

**النتيجة: لا FK يكسر الترتيب — جميع الاعتماديات صحيحة ✅**

---

### ⚠ ملاحظة تقنية: Triggers في M007/M008

**الملف:** `docs/v2/MigrationPlan.md`
**المشكلة:**
M007 (departments) يُنشئ trigger: "عند تعديل اسم القسم → تُحدَّث `employees.dept_name`"
M008 (job_titles) يُنشئ trigger: "عند تعديل المسمى → تُحدَّث `employees.job_title`"

لكن جدول `employees` يُنشأ في M009 — بعد M007 وM008.

**الحقيقة التقنية:**
في PostgreSQL، دوال PL/pgSQL تُترجَم (compile) عند الاستدعاء لا عند الإنشاء.
هذا يعني يمكن إنشاء دالة تذكر جدول `employees` دون وجوده — الخطأ سيظهر فقط عند تشغيل الـ trigger.

**الواقع العملي:**
بما أن الـ migrations تُطبَّق على قاعدة بيانات فارغة وبالترتيب، لن يُستدعى trigger M007 بين M007 وM009 — لا توجد بيانات. ✅

**التوصية:** لا مشكلة تقنية، لكن يُفضَّل توثيق هذا الترتيب في M009 بملاحظة: "هذا الـ migration يُفعّل triggers تم إنشاؤها في M007 وM008."

---

---

## 4. Security Validation — مراجعة الأمان

---

### ✅ نقاط الأمان المُطبَّقة

| المجال | الحالة | التفاصيل |
|--------|--------|---------|
| **JWT Design** | ✅ | payload: {saas_user_id, company_id, role} |
| **Custom Auth** | ✅ | Edge Functions مستقلة — لا Supabase Auth |
| **fingerprint hashing** | ✅ | SHA-256 موثّق + CHECK constraint |
| **QR Token TTL** | ✅ | token_expires_at مضاف |
| **Password Storage** | ✅ | bcrypt via pgcrypto (M001) |
| **RLS on all tables** | ✅ | M020 + M021 تُغطي جميع الجداول |
| **anon on employee_devices** | ✅ | لا SELECT مباشر — SECURITY DEFINER RPC فقط |
| **audit_logs append-only** | ✅ | لا UPDATE، لا DELETE policy |
| **SECURITY DEFINER** | ✅ | للعمليات التي تتجاوز RLS بشكل مقصود |
| **Cross-Tenant Check** | ✅ | company_id IS NULL OR role != 'super_admin' |
| **config.toml auth settings** | ✅ | verify_jwt مضبوط لكل function |
| **No secrets in migrations** | ✅ | موثّق في قواعد المشروع |
| **Supabase Secrets** | ✅ | ENV_VARS.md يوجه لـ Supabase Secrets للإنتاج |

---

### ⚠ ملاحظات أمنية تحتاج انتباهاً

---

#### ملاحظة أمنية 1: Supabase Storage Policies
**المشكلة:**
`employees.avatar_url` و `companies.logo_url` تُشير إلى Supabase Storage.
لم تُحدَّد storage bucket policies في أي وثيقة.

**الخطر:** مستخدم شركة A قد يصل لصورة موظف شركة B إذا لم تُضبَّط policies صحيحة.

**التوصية:** قبل Phase 5 (Employee Management)، توثيق:
- bucket name: `avatars` (private)
- سياسة: `auth_company_id() = employee.company_id`
- سياسة: صاحب الصورة فقط أو company_admin يستطيع الرفع

---

#### ملاحظة أمنية 2: Content Security Policy (CSP)
**المشكلة:**
CODING_STANDARDS.md يذكر `❌ لا console.log في Production` لكن لا ذكر لـ CSP headers.

**التوصية:** توثيق CSP في netlify.toml أو CODING_STANDARDS.md قبل Phase 21 (Production).
ليس ضرورياً الآن ولكن يُذكَّر به.

---

#### ملاحظة أمنية 3: rate_limiting — طبقة تطبيق vs DB
**الحالة:** موثّق في CODING_STANDARDS.md بأنه يُطبَّق على Auth endpoints.
**الملاحظة:** تطبيقه في Edge Functions وليس DB — هذا صحيح.
لكن يجب التأكد أنه يُطبَّق في auth-login وauth-employee-attend قبل الإنتاج.

---

#### ملاحظة أمنية 4: SA member — غياب SECURITY DEFINER scope
**المشكلة:**
SA Member له `permissions JSONB` تحدد ما يراه — لكن لا يوجد توثيق لكيفية التحقق منها في RPCs.
**التوصية:** عند كتابة RPCs الخاصة بـ SA Member، يجب التحقق من `permissions` JSONB، ليس من role فقط.

---

---

## 5. Scalability Validation — مراجعة قابلية التوسع

---

### السيناريو: 10,000 شركة · 500,000 موظف · 100 مليون حضور

---

### ✅ نقاط التوسع المُؤمَّنة

| المشكلة المتوقعة | الحل المطبّق | الجدول |
|-----------------|------------|--------|
| 100M attendance → scan بطيء | **Partitioned Table** (by date_iso yearly) | attendance |
| audit_logs ينمو بلا حدود | **Partitioned Table** (by created_at quarterly) | audit_logs |
| بحث اسم موظف بطيء | **GIN Trigram Index** على name | employees · departments · job_titles |
| queries على soft-deleted records | **Partial Indexes** (WHERE deleted_at IS NULL) | employees · saas_users |
| حساب راتب — جلب finance_items | **Composite Index** (employee_id, apply_period, status) | finance_items |
| لوحة تحكم — إحصائيات شركة | **Composite Index** (company_id, date_iso DESC) | attendance |

---

### ⚠ نقاط اختناق محتملة عند النمو

---

#### اختناق 1: لا استراتيجية لإنشاء partitions المستقبلية
**المشكلة:**
`attendance` و `audit_logs` تحتاج partition جديد لكل سنة/ربع.
MigrationPlan يُنشئ partitions 2026 فقط — ماذا عن 2027 وما بعد؟

**الخطر:** في بداية 2027، ستذهب سجلات الحضور إلى `attendance_default` partition بدون تحسين.

**التوصية:**
- إنشاء migration تلقائي (أو scheduled function) كل سنة ينشئ partition الجديد
- يمكن استخدام `pg_partman` extension أو cron job بسيط
- يُضاف لـ MigrationPlan كـ "M023+ — Annual Partition Creation"

---

#### اختناق 2: salary_records بدون partitioning
**الوضع:**
500K موظف × 24 فترة/سنة = 12M سجل/سنة → 120M بعد 10 سنوات.

**الحالة الحالية:** لا partitioning على salary_records.

**التقييم:**
- مع الـ composite indexes الموجودة، PostgreSQL يتحمل 100M+ سجل على جدول واحد بكفاءة.
- salary_records يُستعلَم دائماً بـ `company_id` أو `employee_id` — لا full scans.
- **قرار:** لا partitioning ضروري حتى السنة الخامسة أو حتى تظهر مشاكل أداء فعلية.

---

#### اختناق 3: company_settings — بدون caching
**الوضع:**
كل عملية تقريباً تحتاج company_settings (timezone, gps_lat/lng, late_deduct_rate...).
مع 10K شركة، قد يصبح هذا الجدول hot read.

**التوصية:**
- عند بناء الـ application layer، استخدم simple in-memory caching (30 ثانية) للـ settings
- لا يؤثر على DB design الحالي

---

---

## 6. Developer Experience — تجربة المطور

---

### ✅ ما يعمل جيداً

| العنصر | التقييم |
|--------|---------|
| هيكل المجلدات | ✅ واضح ومنطقي |
| README لكل مجلد | ✅ يشرح المحتوى والقواعد |
| CODING_STANDARDS.md | ✅ شامل ومحدد |
| NAMING_CONVENTION.md | ✅ يغطي DB, JS, CSS, Git |
| GIT_STRATEGY.md | ✅ واضح مع أمثلة |
| DEV_RULES.md | ✅ القاعدة الذهبية واضحة |
| CONTRIBUTING.md | ✅ Checklist عملي |
| .env.example | ✅ كامل مع تعليقات |
| supabase/config.toml | ✅ JWT verification مضبوط لكل function |

---

### ⚠ نقاط تحتاج تحسين في DX

---

#### ملاحظة DX1: src/core/auth/ مقابل src/modules/auth/
**المشكلة:**
مطور جديد قد يرتبك:
- `src/core/auth/` — session management, JWT utilities
- `src/modules/auth/` — login page UI

**التوصية:** إضافة جملة توضيحية في `src/core/README.md`:
```
core/auth/ = "كيفية التحقق من الجلسة" (utilities)
modules/auth/ = "صفحة تسجيل الدخول" (UI)
```

---

#### ملاحظة DX2: اسم مجلد org/
**المشكلة:**
`src/modules/org/` — غير واضح لمطور جديد.
**التوصية:** إضافة جملة في README الخاص به: "يحتوي Departments + Job Titles management".
لا تغيير للاسم — org/ مقبول كـ abbreviation لـ Organization Structure.

---

#### ملاحظة DX3: غياب Quick Start guide
**المشكلة:**
README.md يذكر "تطبيق migrations بالترتيب من M001" لكن لا شرح للخطوات التفصيلية.
**التوصية:** إضافة قسم "Quick Start" في README.md الرئيسي بعد كتابة M001.

---

---

## ملخص المشاكل المُكتشَفة

---

```
┌────┬──────────────────────────────────────────────────┬──────────┬──────────────────┐
│ #  │ المشكلة                                           │ الخطورة  │ يجب حلها قبل    │
├────┼──────────────────────────────────────────────────┼──────────┼──────────────────┤
│ 1  │ SAM role غير موثّق في saas_users CHECK           │ متوسطة   │ M005 (saas_users)│
│ 2  │ attendance/salary_records بدون integrity triggers│ متوسطة   │ M011 و M012      │
│ 3  │ لا استراتيجية إنشاء partitions مستقبلية          │ متوسطة   │ بعد M011 و M019  │
│ 4  │ Supabase Storage policies غير موثّقة             │ منخفضة   │ Phase 5 (Employees)│
│ 5  │ Roadmap.md Phase 02 يذكر بنية migrations قديمة  │ منخفضة   │ لا إجراء مطلوب  │
│ 6  │ src/core/auth vs src/modules/auth غير موثّق بوضوح│ منخفضة   │ عند بناء Auth    │
│ 7  │ org/ folder name غامض بدون توضيح                │ منخفضة   │ عند بناء module  │
└────┴──────────────────────────────────────────────────┴──────────┴──────────────────┘
```

**لا يوجد أي مشكلة تؤثر على M001.**
**المشاكل المتوسطة تُحَل في Migrations 5، 11، و12.**

---

---

## القرار النهائي

```
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║                                                                      ║
║       ✅  READY FOR MIGRATION 001  ✅                                ║
║                                                                      ║
║                                                                      ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  المشروع جاهز للبدء في كتابة أول Migration.                          ║
║                                                                      ║
║  M001: Extensions & Core Setup لا يتأثر بأي من المشاكل المُكتشَفة.   ║
║                                                                      ║
║  الشروط الوحيدة قبل migrations لاحقة:                                ║
║                                                                      ║
║  ◉ قبل M005: وثّق سلوك SAM (super_admin role + permissions JSONB)   ║
║  ◉ قبل M011: أضف cross-table integrity trigger لـ attendance         ║
║  ◉ قبل M012: أضف cross-table integrity trigger لـ salary_records     ║
║  ◉ بعد M019: أضف استراتيجية إنشاء partitions سنوياً                 ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## ماذا بعد؟

```
الخطوة التالية الوحيدة المطلوبة:

  كتابة SQL لـ Migration 001
  → 001_extensions_core_setup.sql
  → يُفعّل: pgcrypto · uuid-ossp · pg_trgm
  → يُنشئ: schema comment بإصدار KYNO v2

  الحجم المتوقع: ~10-15 سطر SQL فقط.
  الاعتماديات: لا شيء.
  الخطورة: صفر.
```

---

*KYNO v2 — Pre-Implementation Validation Report*
*المرحلة السادسة مكتملة — الطريق واضح للتنفيذ*
