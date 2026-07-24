# src/

كود التطبيق الأمامي — مقسّم إلى 4 طبقات.

---

## الطبقات

### `core/` — النواة المشتركة
كل ما يُشارك بين جميع صفحات التطبيق.
لا يعرف `core/` شيئاً عن modules محددة.

```
auth/         ← إدارة الجلسة والمصادقة
api/          ← Supabase client + RPC wrapper
security/     ← تشفير، تحقق، rate limiting
utils/        ← أدوات عامة (toast, loader, pdf...)
state/        ← إدارة الحالة العامة
permissions/  ← نظام الصلاحيات
offline/      ← إدارة الوضع offline
error/        ← معالجة الأخطاء
monitoring/   ← Logging و Sentry
```

### `modules/` — وحدات الأعمال
كل module مستقل في مجلده — يحتوي على UI logic الخاص به.

```
auth/             ← صفحة الدخول
dashboard/        ← لوحة التحكم
employees/        ← إدارة الموظفين
attendance/       ← الحضور والانصراف
payroll/          ← الرواتب
finance/          ← الخصومات والمكافآت والسلف
leaves/           ← الإجازات
org/              ← الأقسام والمسميات الوظيفية
reports/          ← التقارير
notifications/    ← الإشعارات
settings/         ← الإعدادات
users/            ← المستخدمون والصلاحيات
employee-portal/  ← بوابة الموظف
```

### `super-admin/` — واجهة Super Admin
**منفصلة تماماً** عن واجهة الشركات.

```
companies/      ← إدارة الشركات
subscriptions/  ← الاشتراكات
users/          ← مستخدمو SA
team/           ← فريق SA
stats/          ← إحصائيات المنصة
monitoring/     ← مراقبة النظام
backup/         ← النسخ الاحتياطية
platform/       ← إعلانات المنصة
settings/       ← إعدادات المنصة
```

### `app/` — نقطة الدخول
```
entry.js       ← Bootstrap التطبيق
router.js      ← إدارة التنقل
main.js        ← التهيئة الرئيسية
ui-bindings.js ← ربط العناصر بالأحداث
```

---

## مبدأ الاستيراد

```
modules/ → يستورد من core/ ✅
super-admin/ → يستورد من core/ ✅
modules/ → يستورد من modules/ آخر ❌ (تجنب)
core/ → يستورد من modules/ ❌ (ممنوع)
```
