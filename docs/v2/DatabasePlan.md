# KYNO v2 — Database Plan
**قاعدة البيانات:** PostgreSQL via Supabase
**الاستراتيجية:** Shared Database, Shared Schema, Row Level Security

---

## تصنيف الجداول

---

### 🔵 Core Tables — الجداول الأساسية
*جداول البنية التحتية للـ Multi-Tenant SaaS*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| `companies` | `companies` | إضافة UUID، حقل logo_url، حقل country |
| `saas_users` | `saas_users` | إضافة UUID، تحسين حقل permissions |
| `subscriptions` | `subscriptions` | إضافة plan_id كـ FK، تحسين الحالات |

**الجداول الجديدة في v2:**
- `plans` — جدول خطط الاشتراك (starter, pro, enterprise) مع الحدود

---

### 🟢 Business Tables — جداول البيانات التشغيلية
*بيانات عمل الشركات اليومية*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| `employees` | `employees` | فصل salary info في جدول منفصل مستقبلاً، إضافة UUID |
| `departments` | `departments` | لا تغيير جوهري |
| `attendance` | `attendance` | تنظيف حقول النص (check_in, late, overtime) → TIME/INTEGER |
| `employee_devices` | `employee_devices` | لا تغيير جوهري |
| `salary_records` | `salary_records` | إضافة salary_type, period_type |
| `leaves` | `leaves` | لا تغيير جوهري |
| — | `finance_items` | **جديد** — نقل من JSONB في app_settings إلى جدول حقيقي |

**أهم تغيير في v2:**
جدول `finance_items` المستقل بدلاً من تخزين البيانات كـ JSONB في `app_settings`.

---

### 🔴 Security Tables — جداول الأمان
*المصادقة والأجهزة والجلسات*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| `employee_devices` | `employee_devices` | لا تغيير جوهري |
| — | `auth_sessions` | **جديد** — تتبع جلسات المسؤولين (يمكن إضافته) |

**ملاحظة:** Supabase يدير جلسات GoTrue، لكن يمكن إضافة جدول للـ custom sessions.

---

### 🟡 System Tables — جداول النظام
*إعدادات وإعلانات المنصة*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| `app_settings` | `platform_settings` | **تقسيم** — إعدادات المنصة فقط |
| `app_settings` | `company_settings` | **جديد** — إعدادات الشركات مستقلة |

**التحسين الرئيسي:** تقسيم `app_settings` الحالية (تحمل 3 أدوار) إلى:
- `platform_settings` — key-value للمنصة (system_version، platform WhatsApp...)
- `company_settings` — key-value لكل شركة (currency، timezone، gps، late_deduct_rate...)

---

### 🟣 Audit Tables — جداول التدقيق
*سجل غير قابل للحذف لكل العمليات*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| `audit_logs` | `audit_logs` | إضافة حقول أوضح (ip_address، user_agent) |

---

### ⚪ Lookup Tables — جداول البيانات المرجعية
*بيانات ثابتة يُرجع إليها*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| — | `plans` | **جديد** — خطط الاشتراك (starter/pro/enterprise) |
| `departments` | `departments` | يبقى كما هو |

---

### 🔔 Notification Tables — جداول الإشعارات
*كل أنواع الإشعارات*

| الجدول (v1) | الجدول (v2) | التغييرات |
|------------|------------|----------|
| `notifications` (legacy) | محذوف | استبدله `admin_notifications` |
| `employee_notifications` | `employee_notifications` | لا تغيير |
| `admin_notifications` | `admin_notifications` | لا تغيير |

---

## ملخص كامل جداول v2

### جداول موجودة من v1 (محتفظ بها مع تحسينات)
1. `companies`
2. `saas_users`
3. `employees`
4. `departments`
5. `attendance`
6. `employee_devices`
7. `salary_records`
8. `subscriptions`
9. `leaves`
10. `audit_logs`
11. `employee_notifications`
12. `admin_notifications`

### جداول جديدة في v2
13. `plans` — خطط الاشتراك
14. `finance_items` — الخصومات/المكافآت/السلف (بدلاً من JSONB)
15. `platform_settings` — إعدادات المنصة (بديل جزء من app_settings)
16. `company_settings` — إعدادات الشركات (بديل جزء من app_settings)

### جداول ستُحذف في v2
- `notifications` (legacy) — استُبدل بـ `admin_notifications`
- `app_settings` — تُقسّم إلى `platform_settings` + `company_settings`

---

## تحسينات تقنية في v2

### 1. Primary Keys
```
v1: SERIAL (integer auto-increment)
v2: UUID (uuid DEFAULT gen_random_uuid())
```

### 2. Timestamps
```
v1: TIMESTAMPTZ DEFAULT NOW()
v2: نفس الأسلوب — محتفظ به
```

### 3. Soft Delete
```
v1: لا يوجد — الحذف نهائي
v2: إضافة deleted_at TIMESTAMPTZ للجداول المهمة
    (employees, salary_records, leaves)
```

### 4. Finance Items
```
v1: مخزّنة كـ TEXT (JSONB serialized) في app_settings
    key: 'company:1:finance_items'
    
v2: جدول finance_items مستقل مع:
    id, company_id, employee_id, type, amount,
    loan_mode, installment_count, period_key,
    status, note, created_at
```

### 5. Settings
```
v1: app_settings — key-value واحدة للكل
    مثال: 'company:1:currency', 'platform:system_version'
    
v2: platform_settings — للمنصة فقط
    company_settings — لكل شركة مع company_id
```

---

## قواعد RLS في v2

```
قاعدة 1: كل جدول تشغيلي يجب أن يحتوي على company_id
قاعدة 2: كل جدول تشغيلي يجب أن يحتوي على RLS مفعّل
قاعدة 3: السياسة الأساسية:
         auth_company_id() = company_id
         أو auth_is_super_admin() = true

قاعدة 4: audit_logs و platform_settings بدون RLS للكتابة
          (SECURITY DEFINER functions فقط)

قاعدة 5: employee_devices قابلة للقراءة بـ anon للـ attendance
```

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الأولى (Architecture & Planning)*
