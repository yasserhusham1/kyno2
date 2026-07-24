# KYNO v2 — Architecture Document
**تاريخ التحليل:** يوليو 2026
**المحلل:** Software Architect
**النسخة الحالية:** KYNO v1 (migration 085)

---

## 1. نظرة عامة على النظام الحالي

KYNO هو نظام SaaS متعدد المستأجرين (Multi-Tenant) لإدارة الموارد البشرية وشركات العملاء، مبني على:

| الطبقة | التقنية الحالية |
|--------|----------------|
| Frontend | Single HTML Page (index.html) + Vanilla JS |
| Backend | Supabase (PostgreSQL + RLS + RPC) |
| Auth | Custom Edge Functions (auth-login, auth-session, auth-logout, auth-set-password) |
| Deployment | Netlify + Supabase |
| Monitoring | Sentry |

---

## 2. المشاكل المعمارية في النسخة الحالية

### 2.1 مشكلة Frontend
- كل التطبيق في ملف `index.html` واحد (1100+ سطر)
- لا يوجد bundler أو module system حقيقي
- الـ JS موزّع على `js/core/`، `js/kyno/`، `js/app/` بدون حدود واضحة
- تحميل الصفحات عبر `display:none/block` بدلاً من routing
- كل الـ scripts محملة في `<head>` (30+ ملف)

### 2.2 مشكلة Database
- بيانات Finance (الخصومات/المكافآت/السلف) مخزّنة كـ JSONB نص في `app_settings` بدلاً من جدول مستقل
- جدول `app_settings` يحمل ثلاثة أدوار مختلفة: platform settings، company settings، finance items
- لا يوجد UUID — كل الـ IDs هي SERIAL integers
- جدول `notifications` قديم (legacy) لم يُستبدل بالكامل

### 2.3 مشكلة Migrations
- 85 migration file متراكمة بدلاً من schema نظيف
- بعض المigrations تُصلح أخطاء migrations سابقة
- لا يوجد seed منفصل — البيانات الابتدائية مضمّنة في migrations

### 2.4 مشكلة Auth
- كل Edge Function تحتوي على نسخة مكررة من `_shared/` (supabase.ts، session.ts، types.ts)
- `netlify/functions/supabase-proxy.js` موجود ولا يُستخدم

---

## 3. المعمارية المقترحة لـ KYNO v2

### 3.1 مبادئ التصميم

```
1. Clean Separation of Concerns
2. Multi-Tenant by Design (not by patch)
3. API-First (كل عملية لها RPC أو Edge Function)
4. Security-First (RLS على كل جدول)
5. UUID as Primary Keys
6. Audit Everything
7. Modular Frontend (بدون إعادة كتابة كاملة إذا لزم)
```

### 3.2 طبقات النظام

```
┌─────────────────────────────────────────────────────┐
│                    KYNO v2 Layers                    │
├─────────────────────────────────────────────────────┤
│  Layer 1: Client Application                         │
│  ┌──────────────┐  ┌──────────────┐                 │
│  │  Admin App   │  │  Employee    │                 │
│  │  (SPA/MPA)   │  │  Portal      │                 │
│  └──────────────┘  └──────────────┘                 │
├─────────────────────────────────────────────────────┤
│  Layer 2: API Gateway                                │
│  ┌──────────────────────────────────────────────┐   │
│  │           Supabase Edge Functions            │   │
│  │  auth-login | auth-session | auth-logout     │   │
│  │  auth-set-password | [future endpoints]      │   │
│  └──────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────┤
│  Layer 3: Business Logic                             │
│  ┌──────────────────────────────────────────────┐   │
│  │        PostgreSQL RPC Functions              │   │
│  │  Payroll | Attendance | Finance | Leaves     │   │
│  │  Employees | Subscriptions | Audit | Reports │   │
│  └──────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────┤
│  Layer 4: Data Storage                               │
│  ┌──────────────────────────────────────────────┐   │
│  │     PostgreSQL + Row Level Security (RLS)    │   │
│  │          Multi-Tenant Isolation              │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### 3.3 نموذج Multi-Tenancy

```
Tenant Isolation Strategy: Shared Database, Shared Schema, Row-Level Security

كل سجل في جداول البيانات يحتوي على company_id
RLS Policy تضمن أن كل مستخدم يرى بيانات شركته فقط
Super Admin لديه row_security = off على دوال معينة
```

### 3.4 نموذج المصادقة (Auth Model)

```
Two-Track Authentication:

Track A — Admin Login:
  Client → Edge Function (auth-login)
  → Verify credentials vs saas_users
  → Create Supabase Auth session with app_metadata
  → JWT يحتوي: saas_user_id, company_id, role

Track B — Employee Login:
  Device Fingerprint → RPC (saas_upsert_attendance_by_device)
  → Device binding check vs employee_devices
  → Anon session مع fingerprint verification
```

### 3.5 نموذج الاشتراكات (Subscription Model)

```
Company → Subscription → Plan Limits

Plans: starter → pro → enterprise
Checks: saas_assert_company_active() قبل كل عملية write
Limits: max_employees per plan
```

---

## 4. القرارات المعمارية الرئيسية لـ v2

| القرار | v1 | v2 المقترح |
|-------|-----|-----------|
| Primary Keys | SERIAL integer | UUID |
| Finance Items | JSONB in app_settings | جدول `finance_items` مستقل |
| Frontend | Single HTML file | Modular (صفحات منفصلة أو SPA حقيقي) |
| Edge Functions Shared | مكررة في كل function | مجلد `_shared` واحد مركزي |
| Migrations | 85 ملف متراكم | Schema نظيف + Seeds منفصلة |
| Settings | `app_settings` mixed | `platform_settings` + `company_settings` منفصلان |
| Notifications | جدولان + legacy | نظام موحّد |

---

## 5. القيود الثابتة (Non-Negotiable)

```
✅ Supabase (PostgreSQL)
✅ Row Level Security (RLS)
✅ Edge Functions للـ Auth
✅ RPC للـ Business Logic
✅ Multi-Tenant Architecture
✅ Arabic RTL Support
```

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الأولى (Architecture & Planning)*
