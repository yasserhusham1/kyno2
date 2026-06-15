-- ============================================================
-- KYNO 029 — RLS Tenant Isolation Final (Production Security)
-- Additive / Safe Replace — لا حذف جداول — لا تعديل JWT
--
-- يعتمد على claims في app_metadata (كما في auth-login):
--   role, company_id, saas_user_id
-- دوال: auth_company_id(), auth_app_role(), auth_is_super_admin(), auth_tenant_owns_row()
--
-- ترتيب آمن: إنشاء السياسات الصحيحة أولاً → ثم DROP السياسات الخطيرة
-- ============================================================

-- ----------------------------------------------------------
-- 0) JWT helper functions (idempotent — من 004)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_company_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT NULLIF(
    COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'company_id',
      auth.jwt() ->> 'company_id'
    ),
    ''
  )::INTEGER;
$$;

CREATE OR REPLACE FUNCTION auth_app_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'role',
    auth.jwt() ->> 'role',
    ''
  );
$$;

CREATE OR REPLACE FUNCTION auth_is_super_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT auth_app_role() = 'super_admin';
$$;

CREATE OR REPLACE FUNCTION auth_tenant_owns_row(row_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND row_company_id IS NOT NULL
      AND row_company_id = auth_company_id()
    );
$$;

CREATE OR REPLACE FUNCTION auth_row_company_id_from_employee(p_employee_id INTEGER)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT e.company_id FROM employees e WHERE e.id = p_employee_id LIMIT 1;
$$;

-- ----------------------------------------------------------
-- 1) تفعيل RLS على كل الجداول الحساسة
-- ----------------------------------------------------------
ALTER TABLE employees        ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance       ENABLE ROW LEVEL SECURITY;
ALTER TABLE salary_records   ENABLE ROW LEVEL SECURITY;
ALTER TABLE departments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications    ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE saas_users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE companies        ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings     ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE saas_sessions    ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'login_attempts') THEN
    EXECUTE 'ALTER TABLE login_attempts ENABLE ROW LEVEL SECURITY';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'api_rate_attempts') THEN
    EXECUTE 'ALTER TABLE api_rate_attempts ENABLE ROW LEVEL SECURITY';
  END IF;
END $$;

-- ----------------------------------------------------------
-- 2) سياسات آمنة (قبل حذف admin_all_*)
-- ----------------------------------------------------------

-- ---------- employees ----------
DROP POLICY IF EXISTS "employees_deny_anon" ON employees;
DROP POLICY IF EXISTS "employees_select_tenant" ON employees;
DROP POLICY IF EXISTS "employees_insert_tenant" ON employees;
DROP POLICY IF EXISTS "employees_update_tenant" ON employees;
DROP POLICY IF EXISTS "employees_delete_tenant" ON employees;
DROP POLICY IF EXISTS "tenant_employees_only" ON employees;
DROP POLICY IF EXISTS "super_admin_access_employees" ON employees;

CREATE POLICY "employees_deny_anon" ON employees
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_employees_only" ON employees
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

CREATE POLICY "super_admin_access_employees" ON employees
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- attendance ----------
DROP POLICY IF EXISTS "attendance_deny_anon" ON attendance;
DROP POLICY IF EXISTS "attendance_select_tenant" ON attendance;
DROP POLICY IF EXISTS "attendance_insert_tenant" ON attendance;
DROP POLICY IF EXISTS "attendance_update_tenant" ON attendance;
DROP POLICY IF EXISTS "attendance_delete_tenant" ON attendance;
DROP POLICY IF EXISTS "tenant_attendance_only" ON attendance;
DROP POLICY IF EXISTS "super_admin_access_attendance" ON attendance;

CREATE POLICY "attendance_deny_anon" ON attendance
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_attendance_only" ON attendance
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

CREATE POLICY "super_admin_access_attendance" ON attendance
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- salary_records ----------
DROP POLICY IF EXISTS "salary_deny_anon" ON salary_records;
DROP POLICY IF EXISTS "salary_tenant" ON salary_records;
DROP POLICY IF EXISTS "tenant_salary_only" ON salary_records;
DROP POLICY IF EXISTS "super_admin_access_salary" ON salary_records;

CREATE POLICY "salary_deny_anon" ON salary_records
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_salary_only" ON salary_records
  FOR ALL TO authenticated
  USING (
    auth_tenant_owns_row(
      COALESCE(
        salary_records.company_id,
        auth_row_company_id_from_employee(salary_records.employee_id)
      )
    )
  )
  WITH CHECK (
    auth_tenant_owns_row(
      COALESCE(
        salary_records.company_id,
        auth_row_company_id_from_employee(salary_records.employee_id)
      )
    )
  );

CREATE POLICY "super_admin_access_salary" ON salary_records
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- departments ----------
DROP POLICY IF EXISTS "departments_deny_anon" ON departments;
DROP POLICY IF EXISTS "departments_tenant" ON departments;
DROP POLICY IF EXISTS "tenant_departments_only" ON departments;
DROP POLICY IF EXISTS "super_admin_access_departments" ON departments;

CREATE POLICY "departments_deny_anon" ON departments
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_departments_only" ON departments
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

CREATE POLICY "super_admin_access_departments" ON departments
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- notifications ----------
DROP POLICY IF EXISTS "notifications_deny_anon" ON notifications;
DROP POLICY IF EXISTS "notifications_tenant" ON notifications;
DROP POLICY IF EXISTS "tenant_notifications_only" ON notifications;
DROP POLICY IF EXISTS "super_admin_access_notifications" ON notifications;

CREATE POLICY "notifications_deny_anon" ON notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_notifications_only" ON notifications
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

CREATE POLICY "super_admin_access_notifications" ON notifications
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- employee_devices ----------
DROP POLICY IF EXISTS "devices_deny_anon" ON employee_devices;
DROP POLICY IF EXISTS "devices_tenant" ON employee_devices;
DROP POLICY IF EXISTS "tenant_devices_only" ON employee_devices;
DROP POLICY IF EXISTS "super_admin_access_devices" ON employee_devices;

CREATE POLICY "devices_deny_anon" ON employee_devices
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_devices_only" ON employee_devices
  FOR ALL TO authenticated
  USING (
    auth_tenant_owns_row(
      COALESCE(
        employee_devices.company_id,
        auth_row_company_id_from_employee(employee_devices.employee_id)
      )
    )
  )
  WITH CHECK (
    auth_tenant_owns_row(
      COALESCE(
        employee_devices.company_id,
        auth_row_company_id_from_employee(employee_devices.employee_id)
      )
    )
  );

CREATE POLICY "super_admin_access_devices" ON employee_devices
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- saas_users ----------
DROP POLICY IF EXISTS "saas_users_deny_anon" ON saas_users;
DROP POLICY IF EXISTS "saas_users_select_tenant" ON saas_users;
DROP POLICY IF EXISTS "saas_users_insert_super" ON saas_users;
DROP POLICY IF EXISTS "saas_users_update_tenant" ON saas_users;
DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
DROP POLICY IF EXISTS "saas_users_delete_tenant" ON saas_users;
DROP POLICY IF EXISTS "tenant_saas_users_only" ON saas_users;
DROP POLICY IF EXISTS "super_admin_access_saas_users" ON saas_users;

CREATE POLICY "saas_users_deny_anon" ON saas_users
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_saas_users_only" ON saas_users
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR (company_id IS NOT NULL AND company_id = auth_company_id())
  );

CREATE POLICY "saas_users_insert_tenant" ON saas_users
  FOR INSERT TO authenticated
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "saas_users_update_tenant" ON saas_users
  FOR UPDATE TO authenticated
  USING (auth_is_super_admin() OR company_id = auth_company_id())
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (auth_is_super_admin() OR (company_id = auth_company_id() AND auth_can_manage_tenant_users(company_id)));

CREATE POLICY "super_admin_access_saas_users" ON saas_users
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- companies ----------
DROP POLICY IF EXISTS "companies_deny_anon" ON companies;
DROP POLICY IF EXISTS "companies_select_tenant" ON companies;
DROP POLICY IF EXISTS "companies_modify_super" ON companies;
DROP POLICY IF EXISTS "companies_insert_super" ON companies;
DROP POLICY IF EXISTS "companies_update_super" ON companies;
DROP POLICY IF EXISTS "companies_delete_super" ON companies;
DROP POLICY IF EXISTS "tenant_companies_only" ON companies;
DROP POLICY IF EXISTS "super_admin_access_companies" ON companies;

CREATE POLICY "companies_deny_anon" ON companies
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_companies_only" ON companies
  FOR SELECT TO authenticated
  USING (auth_is_super_admin() OR id = auth_company_id());

CREATE POLICY "companies_insert_super" ON companies
  FOR INSERT TO authenticated
  WITH CHECK (auth_is_super_admin());

CREATE POLICY "companies_update_super" ON companies
  FOR UPDATE TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

CREATE POLICY "companies_delete_super" ON companies
  FOR DELETE TO authenticated
  USING (auth_is_super_admin());

CREATE POLICY "super_admin_access_companies" ON companies
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- subscriptions ----------
DROP POLICY IF EXISTS "subscriptions_deny_anon" ON subscriptions;
DROP POLICY IF EXISTS "subscriptions_tenant" ON subscriptions;
DROP POLICY IF EXISTS "tenant_subscriptions_only" ON subscriptions;
DROP POLICY IF EXISTS "super_admin_access_subscriptions" ON subscriptions;

CREATE POLICY "subscriptions_deny_anon" ON subscriptions
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_subscriptions_only" ON subscriptions
  FOR ALL TO authenticated
  USING (auth_is_super_admin() OR company_id = auth_company_id())
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "super_admin_access_subscriptions" ON subscriptions
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- app_settings ----------
DROP POLICY IF EXISTS "settings_deny_anon" ON app_settings;
DROP POLICY IF EXISTS "settings_select_tenant" ON app_settings;
DROP POLICY IF EXISTS "settings_write_tenant" ON app_settings;
DROP POLICY IF EXISTS "settings_update_tenant" ON app_settings;
DROP POLICY IF EXISTS "tenant_settings_only" ON app_settings;
DROP POLICY IF EXISTS "super_admin_access_settings" ON app_settings;

CREATE POLICY "settings_deny_anon" ON app_settings
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "tenant_settings_only" ON app_settings
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR key LIKE 'global:%'
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  );

CREATE POLICY "settings_write_tenant" ON app_settings
  FOR INSERT TO authenticated
  WITH CHECK (
    auth_is_super_admin()
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  );

CREATE POLICY "settings_update_tenant" ON app_settings
  FOR UPDATE TO authenticated
  USING (
    auth_is_super_admin()
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  )
  WITH CHECK (
    auth_is_super_admin()
    OR key LIKE ('company:' || auth_company_id()::text || ':%')
  );

CREATE POLICY "super_admin_access_settings" ON app_settings
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ---------- audit_logs ----------
DROP POLICY IF EXISTS "audit_insert_authenticated" ON audit_logs;
DROP POLICY IF EXISTS "audit_select_company" ON audit_logs;
DROP POLICY IF EXISTS "audit_insert_tenant" ON audit_logs;
DROP POLICY IF EXISTS "audit_select_tenant" ON audit_logs;

CREATE POLICY "audit_insert_tenant" ON audit_logs
  FOR INSERT TO authenticated
  WITH CHECK (company_id IS NULL OR auth_tenant_owns_row(company_id));

CREATE POLICY "audit_select_tenant" ON audit_logs
  FOR SELECT TO authenticated
  USING (auth_is_super_admin() OR auth_tenant_owns_row(company_id) OR company_id IS NULL);

-- ---------- saas_sessions ----------
DROP POLICY IF EXISTS "saas_sessions_service_only" ON saas_sessions;
DROP POLICY IF EXISTS "saas_sessions_deny_all" ON saas_sessions;

CREATE POLICY "saas_sessions_deny_all" ON saas_sessions
  FOR ALL TO anon, authenticated
  USING (false) WITH CHECK (false);

-- ---------- rate-limit tables (service_role only) ----------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'login_attempts') THEN
    EXECUTE 'DROP POLICY IF EXISTS login_attempts_deny_all ON login_attempts';
    EXECUTE 'CREATE POLICY login_attempts_deny_all ON login_attempts FOR ALL USING (false) WITH CHECK (false)';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'api_rate_attempts') THEN
    EXECUTE 'DROP POLICY IF EXISTS api_rate_attempts_deny_all ON api_rate_attempts';
    EXECUTE 'CREATE POLICY api_rate_attempts_deny_all ON api_rate_attempts FOR ALL USING (false) WITH CHECK (false)';
  END IF;
END $$;

-- ----------------------------------------------------------
-- 3) DROP كل السياسات الخطيرة (بعد وجود البديل الآمن)
-- ----------------------------------------------------------
DROP POLICY IF EXISTS "admin_all_employees" ON employees;
DROP POLICY IF EXISTS "admin_all_attendance" ON attendance;
DROP POLICY IF EXISTS "admin_all_devices" ON employee_devices;
DROP POLICY IF EXISTS "admin_all_salary" ON salary_records;
DROP POLICY IF EXISTS "admin_all_settings" ON app_settings;
DROP POLICY IF EXISTS "admin_all_notif" ON notifications;
DROP POLICY IF EXISTS "admin_all_departments" ON departments;
DROP POLICY IF EXISTS "admin_all_companies" ON companies;
DROP POLICY IF EXISTS "admin_all_saas_users" ON saas_users;
DROP POLICY IF EXISTS "admin_all_subscriptions" ON subscriptions;

DROP POLICY IF EXISTS "anon_all_employees" ON employees;
DROP POLICY IF EXISTS "anon_all_attendance" ON attendance;
DROP POLICY IF EXISTS "anon_all_devices" ON employee_devices;
DROP POLICY IF EXISTS "anon_all_salary" ON salary_records;
DROP POLICY IF EXISTS "anon_all_settings" ON app_settings;
DROP POLICY IF EXISTS "anon_all_notif" ON notifications;
DROP POLICY IF EXISTS "anon_all_departments" ON departments;
DROP POLICY IF EXISTS "anon_all_companies" ON companies;
DROP POLICY IF EXISTS "anon_all_saas_users" ON saas_users;
DROP POLICY IF EXISTS "anon_all_subscriptions" ON subscriptions;

-- سياسات 001/002 الضعيفة (USING true / company_id IS NOT NULL فقط)
DROP POLICY IF EXISTS "tenant_select_employees" ON employees;
DROP POLICY IF EXISTS "tenant_insert_employees" ON employees;
DROP POLICY IF EXISTS "tenant_update_employees" ON employees;
DROP POLICY IF EXISTS "tenant_delete_employees" ON employees;
DROP POLICY IF EXISTS "tenant_modify_employees" ON employees;
DROP POLICY IF EXISTS "tenant_attendance_all" ON attendance;
DROP POLICY IF EXISTS "tenant_devices_all" ON employee_devices;
DROP POLICY IF EXISTS "settings_read" ON app_settings;
DROP POLICY IF EXISTS "settings_write" ON app_settings;
DROP POLICY IF EXISTS "settings_update" ON app_settings;

-- سياسات deny_* بـ USING(false) كـ PERMISSIVE لا تفيد مع OR — لا نُنشئها
-- العزل: deny_anon + tenant_* + super_admin (عبر auth_tenant_owns_row)

-- ----------------------------------------------------------
-- 4) تقييد GRANTs على الجداول الحساسة
-- ----------------------------------------------------------
REVOKE ALL ON TABLE login_attempts FROM anon, authenticated;
REVOKE ALL ON TABLE api_rate_attempts FROM anon, authenticated;

-- saas_users: إخفاء password_hash (من 004)
REVOKE ALL ON TABLE saas_users FROM anon;
REVOKE ALL ON TABLE saas_users FROM authenticated;
GRANT SELECT (id, username, display_name, email, role, permissions, company_id, is_active, last_login, created_at)
  ON saas_users TO authenticated;
GRANT INSERT, UPDATE, DELETE ON saas_users TO authenticated;

-- ----------------------------------------------------------
-- 5) ملاحظة RPCs — SECURITY DEFINER تتجاوز RLS (مقصود)
-- saas_upsert_attendance_by_device, saas_verify_login, saas_link_device_by_token
-- يجب أن تتحقق داخلياً من company/subscription/device (024–027)
-- ----------------------------------------------------------

COMMENT ON FUNCTION auth_tenant_owns_row(INTEGER) IS
  'Tenant isolation: super_admin OR matching app_metadata.company_id';
