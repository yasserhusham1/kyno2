# KYNO v2 — Entity Relationship Diagram (ERD)
**نوع الوثيقة:** نظري — علاقات الجداول فقط بدون SQL
**النسخة:** النهائية بعد Database Finalization (المرحلة الرابعة)

---

## مخطط العلاقات النظري

```
╔══════════════════════════════════════════════════════════════════════╗
║                      KYNO v2 — ERD (Final)                          ║
╚══════════════════════════════════════════════════════════════════════╝

═══════════════════════════════════════
 CORE / PLATFORM LAYER
═══════════════════════════════════════

┌─────────────────────┐        ┌──────────────────────┐
│        plans        │        │   platform_settings   │
│─────────────────────│        │──────────────────────│
│ id (PK, UUID)       │        │ id (PK, UUID)         │
│ slug (UNIQUE)       │        │ key (UNIQUE)          │
│ display_name (JSONB)│        │ value                 │
│  {"ar":"..","en":""}│        │ description           │
│ max_employees       │        │ is_public             │
│ price_monthly       │        │ created_at ◄ جديد     │
│ price_yearly        │        │ updated_at            │
│ features (JSONB)    │        │ updated_by_id (FK)───►saas_users
│ is_active           │        └──────────────────────┘
│ sort_order          │
└──────────┬──────────┘
           │ 1
           │ one plan → many companies (via plan_id)
           │ N
           ▼
┌─────────────────────────────────────────┐
│                 companies               │
│─────────────────────────────────────────│
│ id (PK, UUID)                           │
│ company_name                            │
│ company_code (UNIQUE)                   │
│ status (active/suspended/pending/expired│
│ plan_id ────────────────────────────── ►│ (FK → plans.id  SET NULL)
│ max_employees ◄ قابل للتخصيص            │
│ logo_url                                │
│ country                                 │
│ notes                                   │
│ created_at / updated_at / deleted_at    │
└─────────────────────────────────────────┘
NOTE: تم حذف plan_tier — يُقرأ من JOIN مع plans دائماً
       │
       │ 1 company → many of everything below
       │
       ├──────────────────────────────────────────────────
       │                                                  │
       ▼                                                  ▼
┌──────────────────────┐                  ┌───────────────────────┐
│      saas_users      │                  │      subscriptions    │
│──────────────────────│                  │───────────────────────│
│ id (PK, UUID)        │                  │ id (PK, UUID)         │
│ username (UNIQUE)    │                  │ company_id (FK)       │
│ display_name         │                  │ plan_id (FK)          │
│ email                │                  │ plan_name (snapshot)  │
│ password_hash        │                  │ start_date            │
│ password_algo        │                  │ end_date              │
│ role                 │◄── super_admin   │ status                │
│  company_admin       │    company_user  │ duration_months       │
│ permissions (JSONB)  │                  │ amount                │
│ company_id (FK)      │                  │ activated_by_id (FK)─►saas_users
│ is_active            │                  │ activated_by_name     │
│ force_password_reset │                  │ notes                 │
│ last_login           │                  │ created_at            │
│ created_at / updated │                  └───────────────────────┘
│ deleted_at           │
└──────────────────────┘

═══════════════════════════════════════
 BUSINESS LAYER
═══════════════════════════════════════

                    companies
                        │
       ┌────────────────┼───────────────────────────────────┐
       │                │                │                  │
       ▼                ▼                ▼                  ▼
┌────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐
│ departments│  │  job_titles  │  │   employees  │  │ company_settings│
│────────────│  │──────────────│  │──────────────│  │─────────────────│
│ id (PK)    │  │ id (PK)      │  │ id (PK, UUID)│  │ id (PK)         │
│ company_id │  │ company_id   │  │ company_id(FK│  │ company_id (FK) │
│ name       │  │ name         │  │ name         │  │ key             │
│ description│  │ is_active    │  │ dept_id ─────┼─►│departments.id   │
│ is_active  │  └──────────────┘  │ dept_name ◄  │  │ value           │
└─────┬──────┘  (↑ جدول جديد v2) │ job_title_id─┼─►│job_titles.id   │
      │                           │ job_title ◄  │  │ updated_at      │
      │ dept_name denormalized    │ phone/email  │  └─────────────────┘
      └──────────────────────────►│ salary       │
                                  │ salary_type  │
                                  │ salary_half  │
                                  │ daily_rate   │
                                  │ check_in/out │
                                  │ open_hours   │
                                  │ remote_attend│
                                  │ avatar_url   │
                                  │ sal_status   │
                                  │ next_sal_bonus│
                                  │ is_active    │
                                  │ created_at   │
                                  │ updated_at   │
                                  │ deleted_at   │
                                  └──────┬───────┘
                                         │
                                         │ 1 employee → many records below
                                         │
          ┌─────────────┬────────────────┼───────────────┬──────────────────┐
          │             │                │               │                  │
          ▼             ▼                ▼               ▼                  ▼
┌─────────────┐ ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  attendance │ │ emp_devices    │ │salary_records│ │     leaves       │ │  finance_items   │
│ (PARTITIONED│ │────────────────│ │──────────────│ │──────────────────│ │──────────────────│
│  by date_iso│ │ id (PK)        │ │ id (PK)      │ │ id (PK)          │ │ id (PK)          │
│─────────────│ │ employee_id FK │ │ employee_id  │ │ employee_id FK   │ │ company_id FK    │
│ id (PK)     │ │ company_id FK  │ │ company_id   │ │ company_id FK    │ │ employee_id FK   │
│ employee_id │ │ slot (1-5)◄    │ │ period_key   │ │ leave_ref (UNIQ) │ │ type             │
│ company_id  │ │ label          │ │ period_start◄│ │ leave_type       │ │  deduction       │
│ emp_name    │ │ fingerprint    │ │ period_label │ │ from_date        │ │  bonus           │
│ dept_name   │ │ (SHA-256 hash) │ │ salary_type  │ │ to_date          │ │  loan            │
│ date_iso    │ │ ip             │ │ base_salary  │ │ multiplier       │ │ amount           │
│ check_in_t  │ │ reg_token      │ │ attend_days  │ │ deduct_from_sal  │ │ loan_mode        │
│ check_out_t │ │ token_exp_at ◄ │ │ absent_days  │ │ note             │ │ installment_count│
│ work_minutes│ │ token_used_at  │ │ late_minutes │ │ approval_status◄ │ │ installments_paid│
│ late_minutes│ │ push_token ◄   │ │ late_deduct  │ │  pending         │ │ apply_period     │
│ overtime_min│ │ device_info    │ │ late_rate ◄  │ │  approved        │ │ status           │
│ status      │ │  (JSONB)       │ │ overtime_min │ │  rejected        │ │ note             │
│ source      │ │ linked_at      │ │ overtime_amt │ │ approved_by_id◄─►│saas_users.id     │
│ notes       │ │ last_used_at   │ │ ovt_rate ◄   │ │ approved_at ◄    │ │ created_by_id───►saas_users│
│ created_at  │ └────────────────┘ │ bonus        │ │ created_by_id   │ │ created_at       │
│ updated_at  │                    │ manual_deduct│ │  ───────────────►│saas_users.id     │
└─────────────┘                    │ loan_deduct  │ │ created_at       │ └──────────────────┘
                                   │ total_deduct │ │ updated_at       │
                                   │ net_salary   │ │ deleted_at       │
                                   │ daily_rate   │ └──────────────────┘
                                   │ period_days  │
                                   │ status       │
                                   │ issued_at    │
                                   │ paid_at      │
                                   └──────────────┘

═══════════════════════════════════════
 NOTIFICATION LAYER
═══════════════════════════════════════

                    companies
                        │
            ┌───────────┴──────────────┐
            ▼                          ▼
┌──────────────────────┐    ┌──────────────────────────┐
│ employee_notifications│   │    admin_notifications    │
│──────────────────────│    │──────────────────────────│
│ id (PK)              │    │ id (PK)                   │
│ employee_id (FK)     │    │ company_id (FK)           │
│ company_id (FK)      │    │ notif_type                │
│ notif_type           │    │ title                     │
│ title                │    │ body                      │
│ body                 │    │ read_at ◄ بدلاً عن is_read│
│ is_read              │    │ read_by_id (FK) ─────────►saas_users
│ action_url           │    │ meta (JSONB)              │
│ meta (JSONB)         │    │ created_at                │
│ created_at           │    └──────────────────────────┘
└──────────────────────┘

                              saas_users
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │    platform_announcements    │
                    │─────────────────────────────│
                    │ id (PK)                      │
                    │ title                        │
                    │ body                         │
                    │ type                         │
                    │ target_type ◄ (all/plan/co)  │
                    │ target_id ◄ (UUID or NULL)   │
                    │ is_active                    │
                    │ show_from                    │
                    │ expires_at                   │
                    │ created_by_id (FK) ─────────►saas_users
                    │ created_at / updated_at      │
                    └─────────────────────────────┘

═══════════════════════════════════════
 AUDIT LAYER
═══════════════════════════════════════

┌──────────────────────────────────────────┐
│         audit_logs (PARTITIONED)         │
│          Range by created_at             │
│──────────────────────────────────────────│
│ id (PK)                                  │
│ company_id ─────────────────────────────►│ (FK SET NULL → companies)
│ actor_id ───────────────────────────────►│ (FK SET NULL → saas_users)
│ actor_name (snapshot)                    │
│ actor_role (snapshot)                    │
│ action                                   │
│ category                                 │
│ details                                  │
│ target_id                                │
│ target_name                              │
│ before_state (JSONB)                     │
│ after_state (JSONB)                      │
│ ip_address (INET)                        │
│ user_agent                               │
│ meta (JSONB)                             │
│ created_at                               │
└──────────────────────────────────────────┘
   ↑ لا حذف — append only
   ↑ لا تعديل — immutable
   ↑ Partition by quarter: Q1/Q2/Q3/Q4
```

---

## ملخص العلاقات النصية

### علاقات companies
```
companies (1) ──── (N) saas_users
companies (1) ──── (N) employees
companies (1) ──── (N) departments
companies (1) ──── (N) job_titles
companies (1) ──── (N) attendance
companies (1) ──── (N) salary_records
companies (1) ──── (N) subscriptions
companies (1) ──── (N) leaves
companies (1) ──── (N) finance_items
companies (1) ──── (N) admin_notifications
companies (1) ──── (N) audit_logs
companies (1) ──── (N) company_settings
companies (1) ──── (N) employee_devices
companies (N) ──── (1) plans
```

### علاقات employees
```
employees (1) ──── (N) attendance
employees (1) ──── (N) employee_devices
employees (1) ──── (N) salary_records
employees (1) ──── (N) leaves
employees (1) ──── (N) finance_items
employees (1) ──── (N) employee_notifications
employees (N) ──── (1) departments     [via dept_id — FK رسمي]
employees (N) ──── (1) job_titles      [via job_title_id — FK رسمي]
```

### علاقات saas_users
```
saas_users ──── (creates) subscriptions    [activated_by_id]
saas_users ──── (creates) finance_items    [created_by_id]
saas_users ──── (creates) leaves           [created_by_id]
saas_users ──── (approves) leaves          [approved_by_id — جديد]
saas_users ──── (creates) platform_announcements [created_by_id]
saas_users ──── (reads) admin_notifications      [read_by_id — جديد]
saas_users ──── (updates) platform_settings      [updated_by_id]
saas_users ──── (actor in) audit_logs            [actor_id]
```

---

## خريطة الـ Partitioned Tables

```
┌─────────────────────────────────────────────────────────────┐
│                       attendance                            │
│                    RANGE (date_iso)                         │
├─────────────────┬─────────────────┬─────────────────────────┤
│ attendance_2026 │ attendance_2027  │ attendance_default      │
│ (2026-01 →      │ (2027-01 →       │ (كل ما خارج النطاق)   │
│  2026-12)       │  2027-12)        │                         │
└─────────────────┴─────────────────┴─────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                       audit_logs                            │
│                    RANGE (created_at)                       │
├──────────────┬──────────────┬──────────────┬────────────────┤
│ _2026_q1     │ _2026_q2     │ _2026_q3     │ _2026_q4       │
│ (Jan-Mar)    │ (Apr-Jun)    │ (Jul-Sep)    │ (Oct-Dec)      │
└──────────────┴──────────────┴──────────────┴────────────────┘
```

---

## التغييرات مقارنة بـ ERD الأصلي

| التغيير | التأثير |
|---------|---------|
| حذف `companies.plan_tier` | يُقرأ الآن من JOIN مع plans |
| `plans.display_name` → JSONB | دعم متعدد اللغات |
| إضافة `job_titles` كجدول مستقل | FK رسمي من employees |
| `employee_devices.slot` → BETWEEN 1 AND 5 | مرونة أكبر |
| إضافة `token_expires_at` + `push_token` في devices | أمان + Mobile |
| إضافة `approval_status/approved_by_id/approved_at` في leaves | Approval Workflow |
| إضافة `period_start` + rate snapshots في salary_records | تدقيق مالي صحيح |
| إضافة `created_at` في platform_settings | اكتمال التدقيق |
| `admin_notifications.is_read` → `read_at + read_by_id` | تتبع دقيق |
| `platform_announcements.target` → `target_type + target_id` | سلامة البيانات |
| attendance → Partitioned Table | أداء عند 100M سجل |
| audit_logs → Partitioned Table | تحكم في النمو |

---

## ملاحظات تصميمية

```
1. كل الجداول التشغيلية ترتبط بـ companies عبر company_id
   → يضمن Multi-Tenant isolation على مستوى البيانات

2. audit_logs: append-only + Partitioned
   → لا يجب أن يكون له UPDATE أو DELETE policy في RLS
   → يُقسَّم ربع سنوياً للتحكم في الحجم

3. attendance: Partitioned by date_iso (سنوياً)
   → يضمن الأداء عند 100 مليون سجل

4. employee_devices:
   → لا SELECT مباشر لـ anon
   → التحقق من fingerprint فقط عبر SECURITY DEFINER RPC → BOOLEAN
   → fingerprint = SHA-256 hash (64 char hex) — لا تُخزَّن البصمة الخام

5. departments و job_titles:
   → dept_name و job_title في employees محفوظان كـ denormalized snapshot
   → Trigger يُزامنهما تلقائياً عند تغيير الاسم

6. leaves.approval_status = 'approved' by default
   → يعمل النظام كما هو الآن بدون Approval Workflow
   → قابل للتحول لـ workflow كامل مستقبلاً بدون تغيير schema

7. finance_items و leaves و attendance:
   → Trigger يتحقق أن company_id يطابق employees.company_id
   → يمنع تلوث البيانات بين شركات مختلفة (Cross-Tenant integrity)
```

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الرابعة (Database Finalization)*
*النسخة النهائية — معدّل بعد Database Architecture Review*
