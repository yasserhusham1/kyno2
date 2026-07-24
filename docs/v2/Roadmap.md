# KYNO v2 — Development Roadmap
**المنهجية:** مراحل صغيرة قابلة للتسليم والاختبار
**المبدأ:** كل مرحلة تُبنى فوق المرحلة السابقة

---

## نظرة عامة على المراحل

```
Phase 01 — Architecture & Planning      ← نحن هنا الآن
Phase 02 — Database Schema
Phase 03 — Authentication
Phase 04 — Multi-Tenant Core
Phase 05 — Employee Management
Phase 06 — Attendance System
Phase 07 — Payroll Engine
Phase 08 — Finance Module
Phase 09 — Leaves System
Phase 10 — Notifications
Phase 11 — Reports & Analytics
Phase 12 — Settings & Configuration
Phase 13 — Users & Permissions
Phase 14 — Subscriptions & Plans
Phase 15 — Super Admin Panel
Phase 16 — Employee Portal
Phase 17 — Backup & Export
Phase 18 — Monitoring & Audit
Phase 19 — Security Hardening
Phase 20 — Testing & QA
Phase 21 — Production Deployment
Phase 22 — Post-Launch (v2.1+)
```

---

## التفاصيل

---

### Phase 01 — Architecture & Planning ✅ (الآن)
**الهدف:** تصميم كامل قبل كتابة سطر كود

```
المخرجات:
  ✅ Architecture.md
  ✅ Modules.md
  ✅ FolderStructure.md
  ✅ DatabasePlan.md
  ✅ ERD.md
  ✅ Roles.md
  ✅ Roadmap.md
  ✅ CleanupReport.md
```

---

### Phase 02 — Database Schema
**الهدف:** قاعدة بيانات نظيفة من الصفر

```
المهام:
  - إنشاء migration واحد نظيف (baseline) يحتوي كل الجداول
  - تطبيق UUID كـ Primary Keys
  - إنشاء جميع الـ Indexes
  - إعداد RLS على كل جدول
  - إنشاء جدول finance_items المستقل
  - إنشاء جدولي platform_settings وcompany_settings
  - إنشاء جدول plans
  - إضافة حقل deleted_at للـ Soft Delete

المخرجات:
  - supabase/migrations/001_kyno_v2_baseline.sql
  - supabase/seeds/001_super_admin.sql
  - supabase/seeds/002_plans.sql
```

---

### Phase 03 — Authentication
**الهدف:** نظام مصادقة نظيف وآمن

```
المهام:
  - تصميم JWT payload الجديد
  - إنشاء Edge Function auth-login المحسّنة
  - توحيد مجلد _shared واحد للجميع
  - Edge Function auth-logout
  - Edge Function auth-session
  - Edge Function auth-set-password
  - نظام تسجيل دخول الموظف (fingerprint)
  - RPC auth_company_id() وauth_is_super_admin()

المخرجات:
  - supabase/functions/ محدّثة بـ _shared مركزي واحد
  - RPCs للـ auth helpers
```

---

### Phase 04 — Multi-Tenant Core
**الهدف:** عزل المستأجرين على مستوى قاعدة البيانات

```
المهام:
  - RLS policies لجميع الجداول
  - saas_assert_tenant() RPC
  - saas_assert_company_active() RPC
  - saas_assert_employee_limit() RPC
  - اختبار التأكد من عزل البيانات بين شركتين

المخرجات:
  - supabase/migrations/002_rls_policies.sql
  - supabase/migrations/003_tenant_helpers.sql
```

---

### Phase 05 — Employee Management
**الهدف:** CRUD كامل للموظفين

```
المهام:
  - saas_upsert_employee() RPC
  - saas_delete_employee() RPC
  - saas_get_employees() RPC
  - saas_update_employee_role() RPC
  - رفع صورة الموظف (Supabase Storage)
  - employee-api.js محدّث

المخرجات:
  - supabase/migrations/004_employees_rpc.sql
  - src/modules/employees/employees.js
```

---

### Phase 06 — Attendance System
**الهدف:** تسجيل الحضور + ربط الأجهزة

```
المهام:
  - saas_upsert_attendance_admin() RPC
  - saas_upsert_attendance_by_device() RPC (anon)
  - saas_upsert_attendance_employee() RPC
  - saas_recalculate_attendance_day() RPC
  - Device binding (QR + fingerprint)
  - إدارة بصمة الأجهزة (admin)
  - GPS validation
  - تصدير Excel/PDF

المخرجات:
  - supabase/migrations/005_attendance_rpc.sql
  - supabase/migrations/006_device_binding.sql
  - src/modules/attendance/
```

---

### Phase 07 — Payroll Engine
**الهدف:** محرك رواتب server-authoritative كامل

```
المهام:
  - saas_v3_compute_salary() — الحساب الأساسي
  - saas_preview_salary() — معاينة قبل الإصدار
  - saas_issue_salary() — إصدار الراتب
  - saas_recalculate_salary() — إعادة الحساب
  - دعم: monthly, biweekly, commission, daily
  - saas_v3_period_bounds() — حدود الفترة
  - saas_v3_parse_late_minutes() وparse_ot_minutes()
  - تصدير Excel/PDF

المخرجات:
  - supabase/migrations/007_payroll_rpc.sql
  - src/modules/payroll/payroll.js
```

---

### Phase 08 — Finance Module
**الهدف:** نظام مالي نظيف (خصومات، مكافآت، سلف)

```
المهام:
  - إنشاء جدول finance_items المستقل
  - saas_upsert_finance_item() RPC
  - saas_delete_finance_item() RPC
  - saas_get_finance_items() RPC
  - saas_v3_finance_totals() — مجموع لكل موظف/فترة
  - دعم: deduction, bonus, loan (direct/installments)
  - ربط الرواتب بـ finance_items

المخرجات:
  - supabase/migrations/008_finance_items.sql
  - src/modules/finance/finance.js
```

---

### Phase 09 — Leaves System
**الهدف:** إدارة الإجازات والغياب

```
المهام:
  - saas_upsert_leave() RPC
  - saas_delete_leave() RPC
  - saas_get_leaves() RPC
  - Realtime subscription على leaves
  - ربط الإجازات بحساب الراتب
  - إشعارات تلقائية عند إضافة إجازة

المخرجات:
  - supabase/migrations/009_leaves_rpc.sql
  - src/modules/leaves/leaves.js
```

---

### Phase 10 — Notifications
**الهدف:** نظام إشعارات موحّد

```
المهام:
  - saas_get_employee_notifications() RPC
  - saas_get_admin_notifications() RPC
  - saas_mark_notifications_read() RPC
  - إشعارات تلقائية (راتب صُدر، إجازة أُضيفت، سلفة...)
  - Realtime via Supabase Realtime

المخرجات:
  - supabase/migrations/010_notifications_rpc.sql
  - src/modules/notifications/notifications.js
```

---

### Phase 11 — Reports & Analytics
**الهدف:** تقارير وتحليلات متعددة

```
المهام:
  - saas_get_attendance_report() RPC
  - saas_get_payroll_report() RPC
  - saas_get_department_performance() RPC
  - رسوم بيانية (Chart.js)
  - تصدير Excel/PDF

المخرجات:
  - supabase/migrations/011_reports_rpc.sql
  - src/modules/reports/
```

---

### Phase 12 — Settings & Configuration
**الهدف:** إعدادات الشركة والمنصة منفصلة

```
المهام:
  - saas_get_company_settings() RPC
  - saas_save_company_settings() RPC
  - إعدادات GPS
  - إعدادات الراتب (معدل التأخير، معدل الإضافي)
  - إعدادات عامة (العملة، المنطقة الزمنية)

المخرجات:
  - supabase/migrations/012_settings_rpc.sql
  - src/modules/settings/settings.js
```

---

### Phase 13 — Users & Permissions
**الهدف:** إدارة مستخدمي الشركة بصلاحيات تفصيلية

```
المهام:
  - saas_create_company_user() RPC
  - saas_update_company_user() RPC
  - saas_delete_company_user() RPC
  - permission matrix UI
  - reset password

المخرجات:
  - supabase/migrations/013_company_users_rpc.sql
  - src/modules/users/users.js
```

---

### Phase 14 — Subscriptions & Plans
**الهدف:** نظام اشتراكات مرن

```
المهام:
  - جدول plans
  - saas_activate_subscription() RPC
  - saas_renew_subscription() RPC
  - saas_suspend_company() RPC
  - saas_get_plan_limits() RPC
  - banner انتهاء الاشتراك

المخرجات:
  - supabase/migrations/014_subscriptions_rpc.sql
```

---

### Phase 15 — Super Admin Panel
**الهدف:** لوحة تحكم المنصة الكاملة

```
المهام:
  - dashboard إحصائيات المنصة
  - إدارة الشركات (CRUD)
  - إدارة الاشتراكات
  - إدارة المستخدمين
  - فريق SA بصلاحيات مخصصة
  - الإعلانات (platform announcements)
  - إعدادات المنصة (WhatsApp)

المخرجات:
  - supabase/migrations/015_super_admin_rpc.sql
  - src/super-admin/
```

---

### Phase 16 — Employee Portal
**الهدف:** بوابة موظف سلسة

```
المهام:
  - صفحة الرئيسية (حضور/انصراف)
  - صفحة الراتب
  - صفحة الملف الشخصي
  - إشعارات الموظف
  - تحسين UX

المخرجات:
  - src/modules/employee-portal/
```

---

### Phase 17 — Backup & Export
**الهدف:** نسخ احتياطي موثوق

```
المهام:
  - saas_super_export_company() RPC
  - saas_import_company() RPC
  - تصدير/استيراد JSON
  - Backup Center للـ Super Admin

المخرجات:
  - supabase/migrations/016_backup_rpc.sql
  - src/super-admin/backup/
```

---

### Phase 18 — Monitoring & Audit
**الهدف:** مراقبة النظام وسجل التدقيق

```
المهام:
  - saas_system_monitoring_snapshot() RPC
  - saas_super_list_audit_logs() RPC
  - saas_security_health_report() RPC
  - لوحة System Monitoring

المخرجات:
  - supabase/migrations/017_monitoring_rpc.sql
  - src/super-admin/monitoring/
```

---

### Phase 19 — Security Hardening
**الهدف:** تصليب الأمان للإنتاج

```
المهام:
  - مراجعة جميع RLS policies
  - Rate limiting
  - CORS headers
  - Content Security Policy
  - اختبار أمني شامل
  - تقرير أمان نهائي

المخرجات:
  - supabase/migrations/018_security_hardening.sql
  - docs/v2/SecurityReport.md
```

---

### Phase 20 — Testing & QA
**الهدف:** ضمان جودة الإطلاق

```
المهام:
  - اختبارات وحدة للـ RPCs الرئيسية
  - اختبارات تكامل (Multi-Tenant isolation)
  - اختبارات Payroll (جميع أنواع الراتب)
  - اختبارات Device Binding
  - اختبارات Subscription limits

المخرجات:
  - tests/integration/
  - tests/enterprise/
```

---

### Phase 21 — Production Deployment
**الهدف:** إطلاق v2 في الإنتاج

```
المهام:
  - إعداد Supabase project
  - تطبيق migrations بالترتيب
  - تطبيق seeds
  - deploy Edge Functions
  - deploy Frontend على Netlify/Vercel
  - اختبار نهائي على الإنتاج

المخرجات:
  - KYNO v2 Live 🚀
```

---

### Phase 22 — Post-Launch (v2.1+)
**الهدف:** ميزات مستقبلية

```
مقترحات:
  - PWA للموظف (تطبيق ويب تقدمي)
  - Approval Workflow للإجازات
  - Report Builder مرن
  - إشعارات Push
  - Multi-language (EN/AR)
  - API Public للتكامل مع أنظمة خارجية
  - Scheduled Backup تلقائي
```

---

## ملخص الجدول الزمني

| المرحلة | الوصف | الأولوية |
|---------|-------|---------|
| 01 | Architecture & Planning | ✅ منجز |
| 02 | Database Schema | عالية جداً |
| 03 | Authentication | عالية جداً |
| 04 | Multi-Tenant Core | عالية جداً |
| 05 | Employee Management | عالية |
| 06 | Attendance System | عالية |
| 07 | Payroll Engine | عالية |
| 08 | Finance Module | متوسطة-عالية |
| 09 | Leaves System | متوسطة-عالية |
| 10 | Notifications | متوسطة |
| 11 | Reports & Analytics | متوسطة |
| 12-18 | باقي Modules | متوسطة |
| 19 | Security Hardening | عالية جداً |
| 20 | Testing & QA | عالية |
| 21 | Production Deploy | نهائي |

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الأولى (Architecture & Planning)*
