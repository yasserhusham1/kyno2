# tools/

أدوات التطوير والنشر — سكريبتات مساعدة فقط.

---

## الملفات المتوقعة

| الملف | الوصف |
|-------|-------|
| `deploy-edge-functions.ps1` | نشر Edge Functions |
| `apply-migration.ps1` | تطبيق migration محدد |
| `build-release.ps1` | بناء نسخة الإنتاج |
| `serve-local.ps1` | تشغيل بيئة تطوير محلية |

### `sql/`
ملفات SQL مساعدة (ليست migrations):
- `check-db-status.sql` — فحص حالة قاعدة البيانات
- `bootstrap-super-admin.sql` — إنشاء SA الأول

---

## القاعدة

```
✅ أدوات تساعد على التطوير
✅ سكريبتات يدوية للطوارئ
❌ لا business logic هنا
❌ لا تُعدِّل قاعدة البيانات مباشرة (استخدم migrations)
```
