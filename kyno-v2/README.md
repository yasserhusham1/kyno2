# KYNO v2

> نظام إدارة الموارد البشرية — SaaS متعدد المستأجرين

**الإصدار:** 2.0.0  
**الحالة:** قيد التطوير  
**التقنية:** Supabase · PostgreSQL · Vanilla JS  

---

## نظرة سريعة

KYNO v2 هو إعادة بناء كاملة لنظام KYNO v1، مع التركيز على:

- **Multi-Tenancy** — عزل بيانات كل شركة عبر RLS
- **Security-First** — مصادقة مزدوجة، تشفير كامل، صلاحيات دقيقة
- **Scalability** — تصميم قابل للتوسع حتى مليون موظف
- **Maintainability** — هيكل مجلدات واضح، كود منظم، توثيق كامل

---

## هيكل المشروع

```
kyno-v2/
├── supabase/          # قاعدة البيانات + Edge Functions
│   ├── migrations/    # Migrations مرقّمة بالترتيب
│   ├── seeds/         # بيانات ابتدائية
│   └── functions/     # Edge Functions (Auth + Critical ops)
│
├── src/               # كود التطبيق
│   ├── core/          # النواة المشتركة
│   ├── modules/       # وحدات الأعمال
│   ├── super-admin/   # واجهة Super Admin
│   └── app/           # نقطة الدخول
│
├── css/               # التنسيق
├── assets/            # الأصول الثابتة
├── config/            # الإعدادات
├── tests/             # الاختبارات
└── tools/             # أدوات التطوير
```

---

## التوثيق

| الملف | الوصف |
|-------|-------|
| [CONTRIBUTING.md](CONTRIBUTING.md) | كيفية المساهمة في المشروع |
| [CODING_STANDARDS.md](CODING_STANDARDS.md) | معايير كتابة الكود |
| [NAMING_CONVENTION.md](NAMING_CONVENTION.md) | اتفاقيات التسمية |
| [GIT_STRATEGY.md](GIT_STRATEGY.md) | استراتيجية Git والـ Branching |
| [VERSIONING.md](VERSIONING.md) | نظام الإصدارات |
| [ENV_VARS.md](ENV_VARS.md) | متغيرات البيئة |
| [DEV_RULES.md](DEV_RULES.md) | قواعد التطوير |
| [docs/v2/](../docs/v2/) | وثائق التصميم الكاملة |

---

## متطلبات التشغيل

- Node.js 18+
- Supabase CLI
- حساب Supabase (أو local dev)

---

## البدء السريع

```
1. نسخ .env.example → .env.local وملء القيم
2. supabase start  (للتطوير المحلي)
3. تطبيق الـ migrations بالترتيب من M001
4. فتح index.html في متصفح
```

---

## الحالة الحالية

- [x] Phase 1: Architecture & Planning
- [x] Phase 2: Database Design
- [x] Phase 3: Database Review
- [x] Phase 4: Database Finalization
- [x] Phase 5: Project Foundation (هذه المرحلة)
- [ ] Phase 6: Migration 001
- [ ] Phase 7: Migration 002
- [ ] Phase 8: Authentication

---

*KYNO v2 — Built with discipline, one migration at a time.*
