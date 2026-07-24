# src/modules/

وحدات الأعمال — كل module في مجلده المستقل.

---

## المبدأ

كل module:
- **مجلد مستقل** يحتوي على كل ما يخصه
- **لا يعرف** بوجود modules أخرى (التواصل عبر core/)
- **يستورد** من `src/core/` فقط
- **مسؤولية واحدة** — UI + business logic لهذه الوظيفة

---

## الـ Modules

| Module | الوظيفة | الجدول الرئيسي |
|--------|---------|----------------|
| `auth/` | تسجيل الدخول والخروج | saas_users |
| `dashboard/` | لوحة التحكم والإحصائيات | (views + aggregates) |
| `employees/` | إدارة بيانات الموظفين | employees |
| `attendance/` | الحضور والانصراف وربط الأجهزة | attendance · employee_devices |
| `payroll/` | حساب وإصدار الرواتب | salary_records |
| `finance/` | الخصومات والمكافآت والسلف | finance_items |
| `leaves/` | الإجازات والغياب | leaves |
| `org/` | الأقسام والمسميات الوظيفية | departments · job_titles |
| `reports/` | التقارير والرسوم البيانية | (multiple tables) |
| `notifications/` | الإشعارات | employee_notifications · admin_notifications |
| `settings/` | إعدادات الشركة | company_settings |
| `users/` | المستخدمون والصلاحيات | saas_users |
| `employee-portal/` | بوابة الموظف (صلاحيات محدودة) | employees · attendance · salary_records · leaves |

---

## هيكل كل module

```
module-name/
├── module-name.js   ← UI logic رئيسية
├── api.js           ← RPC calls الخاصة بهذا الـ module (اختياري)
└── utils.js         ← دوال مساعدة خاصة (اختياري)
```
