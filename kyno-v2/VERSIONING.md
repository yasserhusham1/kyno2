# KYNO v2 — Versioning Strategy

نظام الإصدارات للمشروع.

---

## 1. Semantic Versioning

النظام المتّبع: `v{MAJOR}.{MINOR}.{PATCH}`

| الجزء | متى يتغير | مثال |
|-------|-----------|------|
| `MAJOR` | تغيير جذري يكسر التوافق | v2.0.0 → v3.0.0 |
| `MINOR` | ميزة جديدة — متوافقة مع السابق | v2.0.0 → v2.1.0 |
| `PATCH` | إصلاح خطأ — لا كسر في التوافق | v2.0.0 → v2.0.1 |

---

## 2. Database Versioning

### الـ Migrations
الـ migrations هي إصدارات قاعدة البيانات — لا تُحذف، لا تُعدَّل.

```
النسخة الحالية = رقم آخر migration مطبّق
DB v1 = M001 مطبّق
DB v5 = M001 → M005 مطبّقة
DB v22 = M001 → M022 مطبّقة (النسخة الكاملة)
```

### إصدار قاعدة البيانات في platform_settings
```
key = 'db_migration_version'
value = 'M022'  ← آخر migration مطبّق
```

---

## 3. جدول الإصدارات المخطط

| الإصدار | الـ Migrations | الميزات الرئيسية | الحالة |
|---------|---------------|-----------------|--------|
| v2.0.0-alpha | M001 → M022 | Schema كامل + Auth أساسية | ⏳ قادم |
| v2.0.0-beta | + Edge Functions | Auth مكتملة + Companies | ⏳ قادم |
| v2.0.0 | Full | كل الـ modules الأساسية | ⏳ قادم |
| v2.1.0 | + Branches | Multi-Branch support | ⏳ مستقبل |
| v2.2.0 | + Shifts | إدارة الورديات | ⏳ مستقبل |

---

## 4. Changelog

### الصيغة

```markdown
## [v2.0.0] - YYYY-MM-DD

### Added
- ميزات جديدة

### Fixed
- أخطاء مُصلَحة

### Changed
- تغييرات في السلوك الموجود

### Migration Notes
- M015: تم حذف plan_tier من companies
- M017: admin_notifications.is_read → read_at
```

---

## 5. Release Process

```
1. تأكد من أن dev مستقر وجميع tests تجتاز
2. أنشئ branch: release/v2.0.0
3. حدّث VERSIONING.md وأضف changelog
4. PR → main
5. بعد Merge: أضف Git Tag: v2.0.0
6. انشر على Netlify/Hosting
```

---

*هذا الملف جزء من KYNO v2 — Project Foundation*
