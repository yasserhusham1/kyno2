# KYNO v2 — Database Architecture Review
**المراجع:** Senior PostgreSQL Database Architect
**المراجَع:** DatabaseSpecification.md + MigrationPlan.md
**التاريخ:** يوليو 2026
**الحالة:** مراجعة قبل كتابة أول Migration

---

## ملخص تنفيذي

التصميم **قوي في أساسه** ويعكس تحسناً جوهرياً عن v1. تم تجنب معظم أخطاء v1 المعمارية. لكن قبل كتابة أي SQL، توجد **8 مشاكل حرجة** يجب معالجتها، و**11 تحسيناً مهماً**، و**6 توصيات للمستقبل**.

```
المشاكل الحرجة (يجب إصلاحها قبل M001)  : 8
المشاكل المهمة (يجب إصلاحها قبل M010) : 11
توصيات مستقبلية (تُضاف لاحقاً)        : 6
```

---

---

## ✅ نقاط القوة

---

### ✅ 1. فصل الجداول بشكل صحيح
التصميم يحقق هدفه الرئيسي: `finance_items` كجدول حقيقي، `platform_settings` مفصولة عن `company_settings`، الـ 18 جدول لكل منها مسؤولية واحدة واضحة. هذا الفصل يحل أكبر مشكلة في v1.

### ✅ 2. UUID كـ Primary Keys
اختيار UUID بدلاً من SERIAL صحيح تماماً: يمنع تسريب معلومات عن حجم البيانات، ويدعم distributed inserts مستقبلاً، ويُبسّط Backup/Restore بين بيئات مختلفة.

### ✅ 3. تحسين جدول attendance بشكل جوهري
تحويل `check_in_time` → TIME و`late_minutes` → INTEGER بدلاً من نصوص عربية في v1 هو القرار الأهم تقنياً. يُلغي الحاجة لـ parsing functions معقدة في كل استعلام حساب.

### ✅ 4. Soft Delete على الجداول الصحيحة
تطبيق `deleted_at` على: companies, saas_users, employees, departments, leaves. هذه هي الجداول التي تحتاج فعلاً للـ Soft Delete، وليس على جداول كالـ attendance وaudit_logs.

### ✅ 5. audit_logs تصميم ممتاز
إضافة `before_state` و`after_state` كـ JSONB، و`ip_address` كـ INET، و`target_id` هي إضافات قيّمة جداً مقارنة بـ v1. يجعل التدقيق قابلاً للتحقيق (forensically sound).

### ✅ 6. الـ Denormalization موثّق
وجود `dept_name` في employees وattendance موثّق بوضوح كقرار متعمّد للأداء. هذا النهج صح: اتخاذ قرار واعٍ وتوثيقه أفضل من تركه غامضاً.

### ✅ 7. finance_items بتصميم ناضج
عمود `installments_paid` مقابل `installment_count` يتيح تتبع السداد بدقة. إضافة `apply_period` يحل مشكلة ربط الخصومات بفترات محددة. هذا تصميم متقدم.

### ✅ 8. job_titles كجدول مستقل
تحويل النص المجرد في v1 إلى جدول بحث مع UNIQUE constraint يمنع الأسماء المكررة ويُنظم البيانات.

### ✅ 9. Cascade Rules مدروسة
الاختيار بين CASCADE و SET NULL لكل FK مدروس: حذف شركة يُحذف كل شيء معها (CASCADE)، حذف مستخدم لا يُحذف المحتوى الذي أنشأه (SET NULL). هذا صحيح تماماً.

### ✅ 10. الفهارس Composite المطلوبة موجودة
`(employee_id, date_iso DESC)` على attendance، `(company_id, period_key DESC)` على salary_records، `(company_id, status)` على subscriptions - هذه الاستعلامات الأكثر تكراراً مغطاة.

---

---

## ⚠ المشاكل

---

### ─── المجموعة الأولى: مشاكل حرجة (يجب إصلاحها قبل كتابة M001) ───

---

### ⚠ C1. تعارض ENUM Types مع CHECK Constraints
**التصنيف:** حرجي  
**الجداول المتأثرة:** جميع الجداول

**المشكلة:**
MigrationPlan (M002) يُنشئ Custom ENUM Types مثل `user_role_enum`، `attendance_status_enum`...
لكن DatabaseSpecification يستخدم CHECK constraints لنفس القيم مثل:
`CHECK: status IN ('active', 'suspended', 'pending', 'expired')`

هذا يعني نظامَين للقيود على نفس البيانات — أحدهما يُلغي الآخر ويخلق غموضاً:
- هل عمود `status` في companies من نوع `company_status_enum` أم `TEXT` مع CHECK؟
- إذا أردت إضافة قيمة جديدة لاحقاً: مع ENUM تحتاج `ALTER TYPE` (معقد في Supabase)، مع CHECK تحتاج فقط `ALTER TABLE ADD CONSTRAINT`.
- ENUMs في PostgreSQL لا يمكن حذف قيمة منها أبداً حتى لو أردت ذلك.

**الخطورة:**
في Supabase خصوصاً، تعديل ENUM يتطلب إنشاء type جديد وتحويل الأعمدة — عملية معقدة ومحفوفة بالمخاطر.

**الحل المطلوب:**
اختر نهجاً واحداً فقط. **التوصية: استخدم CHECK Constraints فقط وأزل M002 بالكامل.**
- أكثر مرونة
- أسهل في التعديل مستقبلاً
- متوافق تماماً مع Supabase migrations
- لا يحتاج `ALTER TYPE` عند إضافة حالة جديدة

---

### ⚠ C2. employee_devices: غياب انتهاء صلاحية الـ Token
**التصنيف:** حرجي أمنياً  
**الجدول:** `employee_devices`

**المشكلة:**
`registration_token` مخزّن كـ TEXT بدون عمود `token_expires_at`. هذا يعني:
- توكن QR قد يظل صالحاً إلى الأبد بعد توليده
- مهاجم يحصل على التوكن لاحقاً يمكنه ربط جهاز غير مصرح

**الحل المطلوب:**
إضافة عمود `token_expires_at TIMESTAMPTZ` للجدول، مع TTL قصير (15-30 دقيقة).

---

### ⚠ C3. leaves: غياب دورة الموافقة (Approval Lifecycle)
**التصنيف:** حرجي وظيفياً  
**الجدول:** `leaves`

**المشكلة:**
الجدول لا يحتوي على `approval_status`. كل إجازة مُضافة "مقبولة" تلقائياً. هذا قد يكون مقبولاً الآن، لكنه يُصعّب إضافة Approval Workflow لاحقاً دون تعديل الجدول.

**الحل المطلوب:**
إضافة الأعمدة التالية:
- `approval_status TEXT DEFAULT 'approved'` — القيم: pending / approved / rejected
- `approved_by_id UUID FK → saas_users.id ON DELETE SET NULL` — من وافق
- `approved_at TIMESTAMPTZ` — متى وافق

بهذا التصميم، يعمل النظام كما هو الآن (approved تلقائياً)، ويدعم Approval Workflow مستقبلاً بدون تغيير schema.

---

### ⚠ C4. عدم اتساق company_id عبر الجداول (Cross-Table Integrity)
**التصنيف:** حرجي للبيانات  
**الجداول:** attendance · salary_records · finance_items · leaves · employee_notifications

**المشكلة:**
كل هذه الجداول تحتوي على `company_id` و`employee_id`. لكن لا يوجد constraint يضمن أن:
`finance_items.company_id = employees.company_id WHERE employees.id = finance_items.employee_id`

يعني: يمكن نظرياً إدراج سجل finance_item لموظف من شركة A مع company_id لشركة B. هذا كارثي في نظام Multi-Tenant.

**الحل المطلوب:**
تطبيق هذا القيد عبر Trigger على كل جدول يحمل `(employee_id, company_id)` — trigger يتحقق أن `employee.company_id = inserted_row.company_id`.

---

### ⚠ C5. salary_records: غياب لقطة معدلات الحساب
**التصنيف:** حرجي مالياً  
**الجدول:** `salary_records`

**المشكلة:**
عند إصدار راتب، يُحسب بناءً على `late_deduct_rate` و`overtime_hourly_rate` المخزنتين في `company_settings`. لكن هذه المعدلات قد تتغير لاحقاً. الكشف التاريخي لا يُظهر المعدلات التي استُخدمت فعلاً، مما يجعل التدقيق المالي صعباً.

**الحل المطلوب:**
إضافة عمودين:
- `late_deduct_rate INTEGER` — المعدل الفعلي المستخدم في الحساب (snapshot)
- `overtime_hourly_rate INTEGER` — معدل الإضافي المستخدم

---

### ⚠ C6. companies: تعارض plan_tier مع plan_id
**التصنيف:** حرجي للاتساق  
**الجدول:** `companies`

**المشكلة:**
الجدول يحتوي على:
- `plan_id UUID FK → plans.id` — المصدر الموثوق
- `plan_tier TEXT` — denormalized من plans.slug
- `max_employees INTEGER` — denormalized من plans.max_employees

إذا تغيرت خطة الشركة (upgrade/downgrade)، يجب تحديث الثلاثة معاً. إذا فشل trigger أو RPC، تصبح البيانات غير متسقة.

**الحل المطلوب:**
إزالة `plan_tier` كعمود مستقل. يُقرأ من الانضمام مع `plans` عند الحاجة.
`max_employees` يبقى لأنه قد يُخصَّص (custom limit لشركة بعينها بخلاف الخطة).
أو إبقاؤهما مع trigger يضمن التزامنهما.

---

### ⚠ C7. employee_devices: حد الـ Slots مقيد جداً
**التصنيف:** حرجي للقابلية للتوسع  
**الجدول:** `employee_devices`

**المشكلة:**
`CHECK: slot IN (1, 2)` يحدد كل موظف بجهازَين فقط. هذا يعني:
- لا يمكن موظف يستخدم 3 أجهزة (هاتف عمل + هاتف شخصي + تابلت)
- بعض الشركات قد تسمح بأكثر
- مستقبلاً مع Mobile App + Web App + Desktop App قد يكون التطبيق نفسه "جهازاً"

**الحل المطلوب:**
تغيير `CHECK: slot IN (1, 2)` إلى `CHECK: slot BETWEEN 1 AND 5`
وإضافة إعداد في `company_settings: key='max_devices_per_employee'` للتحكم بالحد.

---

### ⚠ C8. platform_settings: غياب created_at
**التصنيف:** حرجي للتدقيق  
**الجدول:** `platform_settings`

**المشكلة:**
الجدول يحتوي على `updated_at` ولكن لا `created_at`. هذا يُصعّب تتبع متى أُضيف كل إعداد لأول مرة.

**الحل المطلوب:**
إضافة `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.

---

### ─── المجموعة الثانية: مشاكل مهمة (يجب إصلاحها قبل M010) ───

---

### ⚠ I1. غياب Partitioning على جداول النمو الكبير
**التصنيف:** مهم للأداء  
**الجداول:** `attendance` · `audit_logs`

عند 100 مليون سجل في attendance بدون partitioning، أي query يمسّ نطاقاً زمنياً ستُجري sequential scan على ملايين الصفوف حتى مع الفهارس.

**التفاصيل:**
- `attendance` يُرشَّح عادةً بـ `(company_id, date_iso BETWEEN ...)` — مثالي للـ Range Partitioning بـ `date_iso` (سنوياً أو ربع سنوياً)
- `audit_logs` يُرشَّح بـ `(created_at ...)` — Range Partitioning بـ `created_at` (ربع سنوياً)

**الحل المطلوب:**
إضافة هذه الجداول كـ Partitioned Tables منذ البداية. تعديل الـ Partitioning لاحقاً على جدول ضخم شبه مستحيل بدون downtime.

---

### ⚠ I2. غياب Trigram Index على حقول البحث النصي
**التصنيف:** مهم للأداء  
**الجداول:** `employees` · `departments` · `job_titles`

بحث autocomplete على `employees.name` بـ `ILIKE '%أحمد%'` بدون trigram index يُجري full table scan. مع 500K موظف هذا مشكلة.

**الحل المطلوب:**
إضافة `GIN index using pg_trgm` (التي تم تفعيلها في M001) على:
- `employees.name`
- `employees.dept_name` (للفلترة)
- `departments.name`
- `job_titles.name`

---

### ⚠ I3. غياب Partial Indexes على جداول Soft Delete
**التصنيف:** مهم للأداء  
**الجداول:** `companies` · `saas_users` · `employees` · `departments` · `leaves`

المشكلة: جميع queries على هذه الجداول تضيف `WHERE deleted_at IS NULL`. لكن الـ indexes الحالية لا تستفيد من هذا الفلتر.

**الحل المطلوب:**
إضافة Partial Indexes على الأعمدة الرئيسية بشرط `WHERE deleted_at IS NULL`:
- `employees`: INDEX على `(company_id, is_active) WHERE deleted_at IS NULL`
- `departments`: INDEX على `company_id WHERE deleted_at IS NULL` (للمدمجة مع UNIQUE)
- `saas_users`: INDEX على `(company_id, role) WHERE deleted_at IS NULL`

---

### ⚠ I4. finance_items: غياب Index على (employee_id, apply_period)
**التصنيف:** مهم للأداء  
**الجدول:** `finance_items`

حساب الراتب يستعلم بـ:
`WHERE employee_id = X AND status = 'active' AND (apply_period = Y OR apply_period IS NULL)`

الـ INDEX الموجود على `(employee_id, status)` لا يغطي `apply_period`.

**الحل المطلوب:**
إضافة INDEX على `(employee_id, apply_period, status)`.

---

### ⚠ I5. صعوبة Multi-Language في plans
**التصنيف:** مهم للتوسع  
**الجدول:** `plans`

الحل الحالي: عمودان `display_name` + `display_name_ar` يدعمان لغتين فقط.
إضافة لغة ثالثة = تعديل schema.

**الحل المقترح:**
استبدال العمودين بـ `display_name JSONB DEFAULT '{}'`
مثال: `{"ar": "الباقة الاحترافية", "en": "Pro Plan", "ku": "..."}`

هذا يدعم أي عدد من اللغات بدون تعديل schema.

---

### ⚠ I6. fingerprint الجهاز مخزّن كـ Plain Text
**التصنيف:** مهم أمنياً  
**الجدول:** `employee_devices`

وصف العمود يقول "بصمة الجهاز المشفّرة" لكن النوع TEXT بدون أي تحديد لخوارزمية التشفير. إذا خُزّنت البصمة كنص خام (مثل UserAgent + Screen + Canvas)، يمكن استخراجها من DB.

**الحل المطلوب:**
إضافة وصف تقني واضح في DatabaseSpecification:
- `fingerprint` يجب أن يُخزَّن كـ SHA-256 hash للبصمة (hex, 64 char)
- إضافة CHECK: `length(fingerprint) = 64 OR fingerprint = ''`
- لا تُخزَّن البصمة الخام أبداً

---

### ⚠ I7. employee_devices: anon READ يحتاج تحديداً أدق
**التصنيف:** مهم أمنياً  
**الجدول:** `employee_devices`

السياسة الحالية: "anon يستطيع القراءة عبر RPC" — هذه الجملة غامضة. RLS مباشر على الجدول لـ anon سيُعرّض بيانات الأجهزة لجميع المجهولين.

**الحل المطلوب:**
تحديد في الـ Spec بوضوح:
- لا SELECT مباشر لـ anon على `employee_devices`
- RLS policy: anon → `FALSE` (ممنوع الوصول المباشر)
- ONLY عبر `SECURITY DEFINER` RPC تتحقق من الـ fingerprint وتُرجع BOOLEAN فقط، لا بيانات الجهاز

---

### ⚠ I8. salary_records: period_key TEXT لا يضمن الترتيب الصحيح
**التصنيف:** مهم للأداء  
**الجدول:** `salary_records`

القيم:
- `'2026-01'` — ترتيب نصي صحيح
- `'2026-01-H1'` و `'2026-01-H2'` — `'2026-01-H2' > '2026-01-H1'` ✓
- لكن `'2026-01-H2' > '2026-01'` ← تعارض! النصف الثاني لشهر أحدث من الشهر كامل؟

**الحل المطلوب:**
إضافة عمود `period_sort_key TEXT` بصيغة موحدة تضمن الترتيب الصحيح:
- شهري: `'2026-01-0'`
- نصف أول: `'2026-01-1'`
- نصف ثاني: `'2026-01-2'`
أو استخدام `period_start DATE` كمعيار الترتيب دائماً.

---

### ⚠ I9. push_token غير موجود في employee_devices
**التصنيف:** مهم للمستقبل  
**الجدول:** `employee_devices`

`employee_devices` يحتوي معلومات الجهاز لكن لا `push_notification_token`. هذا يعني:
- Mobile App مستقبلاً لن يستطيع استقبال Push Notifications
- إضافة push_token لاحقاً = تعديل جدول حساس

**الحل المطلوب:**
إضافة `push_token TEXT` (nullable) للجدول منذ البداية.

---

### ⚠ I10. admin_notifications: غياب read_by_user_id
**التصنيف:** مهم للوظيفة  
**الجدول:** `admin_notifications`

الجدول يحتوي `is_read BOOLEAN` فقط. لكن الشركة قد يكون لها عدة مستخدمين (company_admin + company_users). كل مستخدم قد يحتاج تتبع قراءته الخاصة.

**الحل المطلوب:**
تغيير `is_read BOOLEAN` إلى حل أكثر مرونة:
إما `read_at TIMESTAMPTZ` (آخر قارئ)، أو جدول pivot `admin_notification_reads(notification_id, user_id, read_at)` للشركات ذات المستخدمين المتعددين.

---

### ⚠ I11. platform_announcements.target: بنية غير موثوقة
**التصنيف:** مهم للبيانات  
**الجدول:** `platform_announcements`

العمود `target TEXT DEFAULT 'all'` مع قيم مثل `'all'` أو `'plan:pro'` أو `'company:UUID'`.
هذا encoding نصي هشّ: لا يوجد constraint يمنع قيمة مثل `'plan:qwerty'` (plan غير موجود).

**الحل المطلوب:**
تغيير البنية:
- `target_type TEXT` — القيم: `all` / `plan` / `company`
- `target_id UUID` — يُملأ فقط إذا target_type != 'all'
- CHECK: `(target_type = 'all' AND target_id IS NULL) OR (target_type IN ('plan','company') AND target_id IS NOT NULL)`

---

---

## 💡 التحسينات المقترحة

---

### 💡 T1. إضافة جدول branches (للمستقبل)
**الأولوية:** متوسطة  
النظام حالياً يدعم فرعاً واحداً (موقع GPS واحد في company_settings). المستقبل يتطلب:

**الجدول المقترح: `branches`**
- `id UUID PK`
- `company_id UUID FK → companies`
- `name TEXT`
- `address TEXT`
- `gps_lat NUMERIC`
- `gps_lng NUMERIC`
- `gps_range INTEGER`
- `is_active BOOLEAN`
- `created_at / updated_at`

**التأثير على الجداول الموجودة:**
- إضافة `branch_id UUID FK → branches.id ON DELETE SET NULL` إلى `employees`
- إضافة `branch_id UUID FK → branches.id ON DELETE SET NULL` إلى `attendance`

**توصية:** لا تُضف الآن لكن صمّم `company_settings` بحيث يدعم مفاتيح مثل `branch:UUID:gps_lat` مستقبلاً.

---

### 💡 T2. إضافة جدول shifts للورديات
**الأولوية:** متوسطة  

حالياً `employees.check_in` و`employees.check_out` هي قيم ثابتة. الشركات ذات الورديات المتعددة تحتاج أكثر.

**الجدول المقترح: `shifts`**
- `id UUID PK`
- `company_id UUID FK → companies`
- `name TEXT` (صباحي / مسائي / ليلي)
- `check_in TIME`
- `check_out TIME`
- `days_of_week SMALLINT[]` (أيام التطبيق: [0,1,2,3,4])
- `is_active BOOLEAN`

**التأثير:** إضافة `shift_id UUID FK → shifts` في `employees`.

**توصية:** لا تُضف الآن. لكن لا تجعل check_in/check_out NOT NULL في employees — اتركهما nullable لدعم shift assignment لاحقاً.

---

### 💡 T3. إضافة Views للاستعلامات الشائعة
**الأولوية:** عالية  

**Views مقترحة:**

`v_active_employees` — موظفون نشطون بدون حذف ناعم:
- تُعرض في: صفحة الموظفين، قوائم الاستعلام

`v_active_subscriptions` — اشتراكات فعّالة:
- تُعرض في: لوحة SA، التحقق من النشاط

`v_employee_with_dept` — موظف مع قسمه الحالي (بدون denormalization):
- للتقارير فقط — ليس للـ hot paths

`v_company_dashboard_stats` — إحصائيات لوحة التحكم:
- عدد الموظفين، الاشتراك الحالي، آخر نشاط

**توصية:** أضف هذه Views في Migration منفصل بعد M023.

---

### 💡 T4. Materialized Views للـ Dashboard KPIs
**الأولوية:** مستقبلية (مع النمو)

عند 10K شركة، استعلام `COUNT(DISTINCT employee_id) WHERE company_id = X AND date_iso = TODAY` في attendance على 100M صف سيستغرق وقتاً.

**Materialized Views مقترحة:**

`mv_daily_attendance_summary` — ملخص يومي للحضور لكل شركة:
- تُحدَّث بـ REFRESH كل ساعة أو عند طلب dashboard

`mv_monthly_payroll_summary` — ملخص الرواتب الشهرية:
- تُحدَّث عند إصدار الرواتب

**توصية:** أضفها عند الحاجة الفعلية — ليس في المرحلة الأولى.

---

### 💡 T5. إضافة payroll_rules للقواعد المعقدة
**الأولوية:** مستقبلية  

حالياً قواعد الراتب (late_deduct_rate، overtime_hourly_rate) في company_settings كـ flat key-value. للشركات الكبيرة التي تحتاج:
- معدلات مختلفة حسب القسم
- معدلات مختلفة حسب نوع العقد
- قواعد تدرجية

**الجدول المقترح: `payroll_rules`**
- `id UUID PK`
- `company_id UUID FK → companies`
- `rule_name TEXT`
- `applies_to TEXT` (all / dept:UUID / job_title:UUID)
- `rule_type TEXT` (late_deduct / overtime / absence_deduct)
- `value NUMERIC`
- `is_active BOOLEAN`

**توصية:** احتفظ بـ company_settings للقواعد البسيطة، وأضف هذا الجدول مستقبلاً.

---

### 💡 T6. استراتيجية Archiving للبيانات القديمة
**الأولوية:** مهمة مستقبلاً  

`attendance` و`audit_logs` ستنمو بلا حدود. بدون استراتيجية:
- قاعدة البيانات ستكبر بشكل كبير
- النسخ الاحتياطية ستستغرق وقتاً طويلاً
- الـ migrations المستقبلية ستكون خطرة

**الاستراتيجية المقترحة:**
- `attendance`: الاحتفاظ بـ 2 سنة حية + archive الأقدم في جدول `attendance_archive`
- `audit_logs`: الاحتفاظ بـ 1 سنة حية + archive الأقدم
- تنفيذ بـ `pg_partman` أو cron job شهري

**توصية:** خطط لهذا من اليوم عبر تنفيذ Partitioning في C4.

---

---

## 🚀 توصيات قبل كتابة أول Migration

---

### 🚀 قائمة التعديلات الإلزامية على DatabaseSpecification.md

قبل كتابة M001، يجب تحديث DatabaseSpecification.md بالتعديلات التالية:

---

#### التعديل 1: إزالة M002 (Enums) من MigrationPlan
- حذف Migration 002 كاملاً
- استخدام CHECK constraints فقط في جميع الجداول
- تحديث ترقيم الـ migrations: M002 → M003 يصبح M002، M003 → M004 يصبح M003، وهكذا
- **المجموع الجديد: 22 Migration بدلاً من 23**

---

#### التعديل 2: employee_devices — إضافة/تعديل أعمدة
إضافة إلى جدول `employee_devices`:
- `token_expires_at TIMESTAMPTZ` — انتهاء صلاحية رمز QR
- `push_token TEXT` — رمز الإشعارات (nullable)
- تعديل CHECK: `slot BETWEEN 1 AND 5` بدلاً من `slot IN (1, 2)`
- إضافة وصف: fingerprint = SHA-256 hash (64 char hex)

---

#### التعديل 3: leaves — إضافة حقول الموافقة
إضافة إلى جدول `leaves`:
- `approval_status TEXT NOT NULL DEFAULT 'approved'`  
  CHECK: `approval_status IN ('pending', 'approved', 'rejected')`
- `approved_by_id UUID FK → saas_users.id ON DELETE SET NULL`
- `approved_at TIMESTAMPTZ`

---

#### التعديل 4: salary_records — إضافة لقطة المعدلات
إضافة إلى جدول `salary_records`:
- `late_deduct_rate INTEGER NOT NULL DEFAULT 0`
- `overtime_hourly_rate INTEGER NOT NULL DEFAULT 0`

---

#### التعديل 5: platform_settings — إضافة created_at
إضافة إلى جدول `platform_settings`:
- `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`

---

#### التعديل 6: companies — معالجة plan_tier
**خياران:**
- **الخيار أ (موصى به):** حذف `plan_tier` كعمود، قراءته دائماً من JOIN مع plans
- **الخيار ب:** إبقاؤه مع إضافة trigger يُزامنه دائماً مع plans.slug عند تغيير plan_id

---

#### التعديل 7: platform_announcements — هيكلة target
تعديل عمود `target TEXT` إلى:
- `target_type TEXT NOT NULL DEFAULT 'all'` CHECK IN ('all', 'plan', 'company')
- `target_id UUID` — nullable

---

#### التعديل 8: إضافة Partitioning لـ attendance وaudit_logs
في DatabaseSpecification: إضافة قسم "Partitioning Strategy":
- `attendance`: RANGE Partitioning بـ `date_iso` (partition سنوياً)
- `audit_logs`: RANGE Partitioning بـ `created_at` (partition ربع سنوياً)
- الـ migrations الخاصة بهذين الجدولين تُعدَّل لإنشائهما كـ Partitioned Tables

---

#### التعديل 9: إضافة Indexes مفقودة
إضافة هذه الفهارس في DatabaseSpecification:

لـ `employees`:
- GIN index على `name` (pg_trgm) للبحث
- Partial INDEX على `(company_id, is_active) WHERE deleted_at IS NULL`

لـ `finance_items`:
- INDEX على `(employee_id, apply_period, status)`

لـ `salary_records`:
- إضافة `period_start DATE NOT NULL` أو `period_sort_key TEXT` لضمان الترتيب

---

#### التعديل 10: توضيح anon policy لـ employee_devices
في قسم RLS لـ `employee_devices`:
تغيير "READ بـ anon مسموح" إلى:
"لا SELECT مباشر لـ anon — فقط عبر SECURITY DEFINER RPC تُرجع BOOLEAN"

---

### 🚀 ترتيب التعديلات المقترح

```
الأولوية 1 (قبل M001):
  ✔ حل تعارض ENUM vs CHECK       → حذف M002
  ✔ تعديل token في employee_devices  → إضافة token_expires_at
  ✔ تعديل leaves → إضافة approval_status
  ✔ تعديل salary_records → إضافة rate snapshot

الأولوية 2 (قبل M008):
  ✔ تعديل companies → حسم plan_tier
  ✔ تعديل platform_announcements → هيكلة target
  ✔ تعديل platform_settings → إضافة created_at

الأولوية 3 (قبل M012 - attendance):
  ✔ تحديد Partitioning على attendance وaudit_logs
  ✔ إضافة الفهارس المفقودة
  ✔ تعديل slot في employee_devices
```

---

### 🚀 الخلاصة النهائية

التصميم في مستوى احترافي جيد ومعظم القرارات سليمة. التعديلات المطلوبة ليست إعادة تصميم — بل ضبط دقيق قبل البدء بالتنفيذ.

```
الحالة بعد تطبيق التعديلات العشرة: ✅ جاهز لكتابة أول Migration
```

---

*هذا الملف جزء من KYNO v2 Planning — المرحلة الثالثة (Database Architecture Review)*
*لا يحتوي على أي SQL — مراجعة وتوصيات فقط*
