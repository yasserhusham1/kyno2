# supabase/migrations/

Migrations قاعدة البيانات — مرقّمة ومرتّبة.

---

## ترتيب التنفيذ

| Migration | الوصف | الحالة |
|-----------|-------|--------|
| M001 | Extensions & Core Setup | ⏳ قادم |
| M002 | Database Helper Functions | ⏳ قادم |
| M003 | Table: plans | ⏳ قادم |
| M004 | Table: companies | ⏳ قادم |
| M005 | Table: saas_users | ⏳ قادم |
| M006 | Table: subscriptions | ⏳ قادم |
| M007 | Table: departments | ⏳ قادم |
| M008 | Table: job_titles | ⏳ قادم |
| M009 | Table: employees | ⏳ قادم |
| M010 | Table: employee_devices | ⏳ قادم |
| M011 | Table: attendance (Partitioned) | ⏳ قادم |
| M012 | Table: salary_records | ⏳ قادم |
| M013 | Table: finance_items | ⏳ قادم |
| M014 | Table: leaves | ⏳ قادم |
| M015 | Table: platform_settings | ⏳ قادم |
| M016 | Table: company_settings | ⏳ قادم |
| M017 | Tables: Notifications | ⏳ قادم |
| M018 | Table: platform_announcements | ⏳ قادم |
| M019 | Table: audit_logs (Partitioned) | ⏳ قادم |
| M020 | RLS: Core & Business Tables | ⏳ قادم |
| M021 | RLS: System & Audit Tables | ⏳ قادم |
| M022 | Seeds: Initial Data | ⏳ قادم |

---

## قواعد صارمة

```
❌ لا تُعدِّل migration موجودة أبداً
❌ لا تحذف migration موجودة
❌ لا تُغيِّر ترتيب الأرقام
✅ كل migration جديد يأخذ الرقم التالي
✅ كل migration: مهمة واحدة واضحة
✅ وصف قصير في اسم الملف
```

---

## المرجع

راجع `docs/v2/MigrationPlan.md` للتفاصيل الكاملة لكل migration.
