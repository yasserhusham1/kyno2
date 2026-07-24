# KYNO v2 — Folder Structure
**النوع:** SaaS Web Application
**الهيكل:** Professional Modular Structure

---

## الهيكل الكامل المقترح

```
kyno-v2/
│
├── 📁 supabase/                        # كل ما يخص Supabase
│   ├── 📁 migrations/                  # Migration files بترتيب زمني
│   │   └── 001_kyno_v2_baseline.sql    # Schema الأساسي النظيف
│   │
│   ├── 📁 seeds/                       # بيانات ابتدائية منفصلة عن migrations
│   │   ├── 001_super_admin.sql
│   │   ├── 002_lookup_data.sql
│   │   └── 003_demo_company.sql
│   │
│   ├── 📁 functions/                   # Edge Functions
│   │   ├── 📁 _shared/                 # مشترك بين جميع functions (مجلد واحد فقط)
│   │   │   ├── supabase.ts
│   │   │   ├── session.ts
│   │   │   ├── auth-jwt.ts
│   │   │   └── types.ts
│   │   │
│   │   ├── 📁 auth-login/
│   │   │   └── index.ts
│   │   ├── 📁 auth-logout/
│   │   │   └── index.ts
│   │   ├── 📁 auth-session/
│   │   │   └── index.ts
│   │   ├── 📁 auth-set-password/
│   │   │   └── index.ts
│   │   └── tsconfig.json
│   │
│   └── config.toml
│
├── 📁 src/                             # كود التطبيق الأمامي
│   │
│   ├── 📁 core/                        # النواة المشتركة بين كل الصفحات
│   │   ├── 📁 auth/                    # المصادقة
│   │   │   ├── session.js
│   │   │   ├── login.js
│   │   │   └── admin-session.js
│   │   │
│   │   ├── 📁 api/                     # طبقة API الموحّدة
│   │   │   ├── supabase-client.js      # Supabase client singleton
│   │   │   ├── rpc.js                  # RPC wrapper
│   │   │   └── auth-api.js             # Auth API calls
│   │   │
│   │   ├── 📁 security/                # الأمان
│   │   │   ├── crypto.js
│   │   │   ├── sanitizer.js
│   │   │   ├── validation.js
│   │   │   └── rate-limiter.js
│   │   │
│   │   ├── 📁 utils/                   # أدوات مساعدة عامة
│   │   │   ├── toast.js
│   │   │   ├── loader.js
│   │   │   ├── pdf.js
│   │   │   ├── time-format.js
│   │   │   ├── performance.js
│   │   │   ├── retry-logic.js
│   │   │   └── batch-processor.js
│   │   │
│   │   ├── 📁 state/                   # إدارة الحالة
│   │   │   ├── store.js
│   │   │   ├── state.js
│   │   │   └── sync-state.js
│   │   │
│   │   ├── 📁 permissions/             # نظام الصلاحيات
│   │   │   ├── permission-matrix.js
│   │   │   ├── super-admin-permissions.js
│   │   │   └── tenant-guard.js
│   │   │
│   │   ├── 📁 offline/                 # إدارة الوضع غير المتصل
│   │   │   ├── offline-manager.js
│   │   │   ├── cloud-sync.js
│   │   │   └── conflict-resolver.js
│   │   │
│   │   ├── 📁 error/                   # معالجة الأخطاء
│   │   │   ├── error-handler.js
│   │   │   ├── safe-render.js
│   │   │   └── safe-runtime.js
│   │   │
│   │   └── 📁 monitoring/              # المراقبة
│   │       ├── logger.js
│   │       └── sentry-init.js
│   │
│   ├── 📁 modules/                     # Modules التطبيق
│   │   │
│   │   ├── 📁 auth/                    # صفحة الدخول
│   │   │   └── login.html              # أو login.js للـ UI
│   │   │
│   │   ├── 📁 dashboard/               # لوحة التحكم
│   │   │   └── dashboard.js
│   │   │
│   │   ├── 📁 employees/               # الموظفون
│   │   │   └── employees.js
│   │   │
│   │   ├── 📁 attendance/              # الحضور والانصراف
│   │   │   ├── attendance.js
│   │   │   └── device-mgmt.js
│   │   │
│   │   ├── 📁 payroll/                 # الرواتب
│   │   │   └── payroll.js
│   │   │
│   │   ├── 📁 finance/                 # الخصومات والمكافآت والسلف
│   │   │   └── finance.js
│   │   │
│   │   ├── 📁 leaves/                  # الإجازات والغياب
│   │   │   └── leaves.js
│   │   │
│   │   ├── 📁 org/                     # الأقسام والوظائف
│   │   │   └── org.js
│   │   │
│   │   ├── 📁 reports/                 # التقارير
│   │   │   ├── reports.js
│   │   │   └── chart-analytics.js
│   │   │
│   │   ├── 📁 notifications/           # الإشعارات
│   │   │   └── notifications.js
│   │   │
│   │   ├── 📁 settings/                # الإعدادات
│   │   │   └── settings.js
│   │   │
│   │   ├── 📁 users/                   # المستخدمون والصلاحيات
│   │   │   └── users.js
│   │   │
│   │   └── 📁 employee-portal/         # بوابة الموظف
│   │       ├── emp-home.js
│   │       ├── emp-salary.js
│   │       └── emp-profile.js
│   │
│   ├── 📁 super-admin/                 # واجهة Super Admin (منفصلة)
│   │   ├── 📁 companies/
│   │   ├── 📁 subscriptions/
│   │   ├── 📁 users/
│   │   ├── 📁 team/
│   │   ├── 📁 stats/
│   │   ├── 📁 monitoring/
│   │   ├── 📁 backup/
│   │   ├── 📁 platform/
│   │   └── 📁 settings/
│   │
│   └── 📁 app/                         # نقطة الدخول والربط
│       ├── entry.js                    # نقطة الدخول الرئيسية
│       ├── router.js                   # إدارة التنقل بين الصفحات
│       ├── main.js                     # التهيئة الرئيسية
│       └── ui-bindings.js             # ربط العناصر بالأحداث
│
├── 📁 css/                             # ملفات التنسيق
│   ├── app.css                         # CSS الرئيسي
│   ├── 📁 components/                  # CSS للمكونات
│   │   ├── sidebar.css
│   │   ├── cards.css
│   │   ├── tables.css
│   │   └── forms.css
│   └── 📁 themes/
│       ├── dark.css
│       └── light.css
│
├── 📁 assets/                          # الأصول الثابتة
│   ├── kyno-logo.png
│   └── 📁 icons/
│
├── 📁 config/                          # ملفات الإعداد
│   ├── public.config.js                # إعدادات عامة
│   ├── local.config.example.js         # مثال الإعداد المحلي
│   └── supabase.defaults.js            # إعدادات Supabase الافتراضية
│
├── 📁 docs/                            # التوثيق
│   ├── 📁 v2/                          # وثائق KYNO v2
│   │   ├── Architecture.md
│   │   ├── Modules.md
│   │   ├── FolderStructure.md
│   │   ├── DatabasePlan.md
│   │   ├── ERD.md
│   │   ├── Roles.md
│   │   ├── Roadmap.md
│   │   └── CleanupReport.md
│   └── KYNO-دليل-العملاء.html
│
├── 📁 tests/                           # الاختبارات
│   ├── 📁 unit/
│   ├── 📁 integration/
│   └── 📁 enterprise/
│
├── 📁 tools/                           # أدوات التطوير والنشر
│   ├── deploy-edge-auth-api.ps1
│   └── build-netlify-release.ps1
│
├── index.html                          # نقطة الدخول HTML
├── netlify.toml                        # إعدادات Netlify
├── .env.example                        # مثال متغيرات البيئة
└── README.md
```

---

## شرح وظيفة كل مجلد رئيسي

| المجلد | الوظيفة |
|--------|---------|
| `supabase/migrations/` | تغييرات قاعدة البيانات بالترتيب |
| `supabase/seeds/` | بيانات ابتدائية لا تتغير |
| `supabase/functions/` | Edge Functions للـ Auth وعمليات حساسة |
| `supabase/functions/_shared/` | كود مشترك بين جميع Edge Functions (ملف واحد فقط) |
| `src/core/` | النواة: auth، api، security، utils، state، permissions، offline، error، monitoring |
| `src/modules/` | كل module في مجلده: employees، attendance، payroll... |
| `src/super-admin/` | واجهة Super Admin مفصولة تماماً عن واجهة الشركة |
| `src/app/` | نقطة الدخول، الـ router، التهيئة العامة |
| `css/` | التنسيق مقسم حسب المكونات والثيمات |
| `config/` | ملفات الإعداد (لا secrets هنا) |
| `docs/v2/` | وثائق التصميم الكاملة |
| `tests/` | كل أنواع الاختبارات |
| `tools/` | سكريبتات النشر والصيانة |

---

## المبادئ في الهيكل

```
1. Separation of Concerns: كل module مستقل في مجلده
2. Core vs Feature: النواة المشتركة في src/core/، الميزات في src/modules/
3. Super Admin Isolation: واجهة SA منفصلة تماماً
4. Single _shared: ملف مشترك واحد للـ Edge Functions
5. Config vs Code: الإعدادات في config/، الكود في src/
```

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الأولى (Architecture & Planning)*
