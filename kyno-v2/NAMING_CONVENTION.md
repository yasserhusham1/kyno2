# KYNO v2 — Naming Convention

اتفاقيات التسمية في المشروع — تُطبَّق على الكل بدون استثناء.

---

## 1. قاعدة البيانات

### الجداول
```
snake_case · جمع
✅ employees · salary_records · finance_items · audit_logs
❌ Employee · salaryRecord · FinanceItem
```

### الأعمدة
```
snake_case · مفرد (عدا الـ plurals الصريحة)
✅ employee_id · company_id · created_at · is_active · deleted_at
✅ dept_name · job_title · base_salary · late_minutes
❌ employeeId · CompanyID · CreatedAt
```

### المفاتيح الخارجية
```
{table_singular}_id
✅ employee_id · company_id · plan_id · dept_id
✅ approved_by_id · created_by_id · actor_id (FK → saas_users)
❌ emp · compId · the_employee
```

### الأنواع (Types) و Enums
```
لا نستخدم ENUMs — CHECK constraints فقط
القيم في CHECK: snake_case lowercase
✅ 'active' · 'company_admin' · 'paid_single' · 'pending'
❌ 'Active' · 'CompanyAdmin' · 'PaidSingle'
```

### الـ Functions (PostgreSQL)
```
snake_case · فعل + اسم
✅ auth_jwt_claim() · generate_leave_ref() · verify_company_id_match()
✅ kyno_now() · auth_is_super_admin() · auth_company_id()
❌ GetUser() · doAuth() · f1()
```

### الـ Indexes
```
idx_{table}_{columns}
✅ idx_employees_company_id
✅ idx_attendance_employee_date_iso
✅ idx_salary_company_period_start
❌ index1 · my_idx · emp_idx
```

---

## 2. JavaScript

### المتغيرات والدوال
```
camelCase
✅ employeeId · companyData · isLoading · fetchEmployees()
❌ employee_id · CompanyData · FetchEmployees
```

### الثوابت (Constants)
```
SCREAMING_SNAKE_CASE للثوابت العامة
✅ MAX_DEVICES_PER_EMPLOYEE · DEFAULT_PAGE_SIZE · API_TIMEOUT_MS
```

### الكلاسات (Classes) — نادراً
```
PascalCase
✅ OfflineManager · ErrorHandler · RateLimiter
```

### الملفات
```
kebab-case · وصفي
✅ supabase-client.js · permission-matrix.js · time-format.js
✅ offline-manager.js · rate-limiter.js
❌ supabaseClient.js · PermissionMatrix.js · time_format.js
```

### الدوال الـ async
```
✅ تبدأ بـ: fetch · get · load · create · update · delete · send
✅ fetchEmployees() · getCompanyStats() · createLeave()
✅ updateEmployee() · deleteFinanceItem() · sendNotification()
❌ employees() · data() · doEmployee()
```

### Event Handlers
```
✅ on + FineAction: onLoginSubmit · onEmployeeDelete · onPageLoad
✅ handle + Action: handleFormSubmit · handleSearch
```

---

## 3. Edge Functions

### أسماء الـ Functions
```
kebab-case · action-resource
✅ auth-login · auth-logout · auth-employee-attend · auth-set-password
❌ login · authLogin · LoginFunction
```

---

## 4. ملفات CSS

```
kebab-case
✅ sidebar.css · employee-card.css · dark-theme.css
❌ sidebar_styles.css · EmployeeCard.css
```

### Class Names (CSS)
```
BEM-like: block__element--modifier
✅ .employee-card · .employee-card__name · .employee-card--active
✅ .sidebar · .sidebar__item · .sidebar__item--selected
```

---

## 5. Git

### أسماء الـ Branches
```
{type}/{description}
✅ feat/auth-login
✅ fix/attendance-date-calculation
✅ migration/m001-extensions
✅ docs/update-readme
```

### Commit Messages
```
{type}: {short description}

types: feat · fix · migration · docs · refactor · test · chore
✅ feat: add employee fingerprint verification
✅ migration: M001 extensions and core setup
✅ fix: correct late minutes calculation in payroll
❌ update stuff · fix · wip · changes
```

---

## 6. متغيرات البيئة

```
SCREAMING_SNAKE_CASE · مسبوقة بـ KYNO_
✅ KYNO_SUPABASE_URL
✅ KYNO_SUPABASE_ANON_KEY
✅ KYNO_JWT_SECRET
✅ KYNO_APP_ENV
❌ supabaseUrl · SUPABASE_KEY · url
```

---

*هذا الملف جزء من KYNO v2 — Project Foundation*
