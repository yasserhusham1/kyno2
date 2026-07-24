# tests/

اختبارات المشروع — مقسّمة حسب النوع.

---

## المجلدات

| المجلد | النوع | الوصف |
|--------|-------|-------|
| `unit/` | Unit Tests | اختبار دوال مستقلة (utils, calculations) |
| `integration/` | Integration Tests | اختبار RPCs وتكامل قاعدة البيانات |
| `e2e/` | End-to-End Tests | اختبار سيناريوهات كاملة من UI إلى DB |

---

## الأولويات

1. **unit/** — دوال حساب الراتب، التشفير، التحقق من البيانات
2. **integration/** — RPC calls، RLS policies، Triggers
3. **e2e/** — تسجيل الدخول، تسجيل حضور، إصدار راتب

---

## القاعدة

```
لا تنتقل لـ Phase التالية إلا بعد اختبار Phase السابقة.
Migration جديد = Test جديد في integration/.
```
