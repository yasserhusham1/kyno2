-- ============================================================
-- KYNO 030 — Enterprise RLS Cleanup (Zero Trust / 3-Policy Model)
-- Additive Safe Replace — لا JWT changes — لا تعطيل RLS
--
-- نموذج كل جدول حساس (بالضبط 3 سياسات PERMISSIVE):
--   1) deny_anon_<table>     → anon  USING(false)
--   2) <table>_tenant_only   → authenticated  company isolation ONLY
--   3) <table>_super_admin   → authenticated  super_admin ONLY
--
-- ❌ لا USING(true)
-- ❌ لا auth_is_super_admin() OR company_id في نفس policy
-- ❌ لا تكرار tenant_* / super_admin_access_*
-- ============================================================

-- ----------------------------------------------------------
-- 0) JWT helpers (idempotent)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_company_id()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT NULLIF(
    COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'company_id',
      auth.jwt() ->> 'company_id'
    ), ''
  )::INTEGER;
$$;

CREATE OR REPLACE FUNCTION auth_app_role()
RETURNS TEXT
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'role',
    auth.jwt() ->> 'role', ''
  );
$$;

CREATE OR REPLACE FUNCTION auth_is_super_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT auth_app_role() = 'super_admin';
$$;

CREATE OR REPLACE FUNCTION auth_effective_company_id(
  p_row_company_id INTEGER,
  p_employee_id INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT COALESCE(
    p_row_company_id,
    CASE WHEN p_employee_id IS NOT NULL THEN
      (SELECT e.company_id FROM employees e WHERE e.id = p_employee_id LIMIT 1)
    END
  );
$$;

-- ----------------------------------------------------------
-- 1) DROP كل السياسات القديمة على الجداول المستهدفة
-- ----------------------------------------------------------
DO $$
DECLARE
  r RECORD;
  tables TEXT[] := ARRAY[
    'employees', 'attendance', 'salary_records', 'departments',
    'notifications', 'employee_devices', 'saas_users', 'companies',
    'subscriptions', 'app_settings', 'audit_logs',
    'saas_sessions', 'login_attempts', 'api_rate_attempts'
  ];
BEGIN
  FOR r IN
    SELECT p.schemaname, p.tablename, p.policyname
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = ANY(tables)
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
END $$;

-- ----------------------------------------------------------
-- 2) RLS enabled (يبقى true — لا تعطيل)
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
-- 3) employees — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_employees ON employees
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY employees_tenant_only ON employees
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  );

CREATE POLICY employees_super_admin ON employees
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 4) attendance — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_attendance ON attendance
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY attendance_tenant_only ON attendance
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  );

CREATE POLICY attendance_super_admin ON attendance
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 5) salary_records — 3 policies (company_id أو عبر employee)
-- ----------------------------------------------------------
CREATE POLICY deny_anon_salary_records ON salary_records
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY salary_records_tenant_only ON salary_records
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND auth_effective_company_id(salary_records.company_id, salary_records.employee_id) = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND auth_effective_company_id(salary_records.company_id, salary_records.employee_id) = auth_company_id()
  );

CREATE POLICY salary_records_super_admin ON salary_records
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 6) departments — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_departments ON departments
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY departments_tenant_only ON departments
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  );

CREATE POLICY departments_super_admin ON departments
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 7) notifications — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_notifications ON notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY notifications_tenant_only ON notifications
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  );

CREATE POLICY notifications_super_admin ON notifications
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 8) employee_devices — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_employee_devices ON employee_devices
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY employee_devices_tenant_only ON employee_devices
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND auth_effective_company_id(employee_devices.company_id, employee_devices.employee_id) = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND auth_effective_company_id(employee_devices.company_id, employee_devices.employee_id) = auth_company_id()
  );

CREATE POLICY employee_devices_super_admin ON employee_devices
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 9) saas_users — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_saas_users ON saas_users
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY saas_users_tenant_only ON saas_users
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  );

CREATE POLICY saas_users_super_admin ON saas_users
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 10) companies — 3 policies (tenant يرى شركته فقط)
-- ----------------------------------------------------------
CREATE POLICY deny_anon_companies ON companies
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY companies_tenant_only ON companies
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND id = auth_company_id()
  );

CREATE POLICY companies_super_admin ON companies
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 11) subscriptions — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_subscriptions ON subscriptions
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY subscriptions_tenant_only ON subscriptions
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  );

CREATE POLICY subscriptions_super_admin ON subscriptions
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 12) app_settings — 3 policies (tenant بدون super_admin في نفس policy)
-- ----------------------------------------------------------
CREATE POLICY deny_anon_app_settings ON app_settings
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY app_settings_tenant_only ON app_settings
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND (
      key LIKE 'global:%'
      OR key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND key LIKE ('company:' || auth_company_id()::text || ':%')
  );

CREATE POLICY app_settings_super_admin ON app_settings
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 13) audit_logs — 3 policies
-- ----------------------------------------------------------
CREATE POLICY deny_anon_audit_logs ON audit_logs
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY audit_logs_tenant_only ON audit_logs
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NOT NULL
    AND company_id IS NOT NULL
    AND company_id = auth_company_id()
  )
  WITH CHECK (
    auth_company_id() IS NOT NULL
    AND (company_id IS NULL OR company_id = auth_company_id())
  );

CREATE POLICY audit_logs_super_admin ON audit_logs
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 14) جداول داخلية — deny فقط (service_role يتجاوز RLS)
-- ----------------------------------------------------------
CREATE POLICY deny_anon_saas_sessions ON saas_sessions
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'login_attempts') THEN
    EXECUTE 'CREATE POLICY deny_anon_login_attempts ON login_attempts FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'api_rate_attempts') THEN
    EXECUTE 'CREATE POLICY deny_anon_api_rate_attempts ON api_rate_attempts FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)';
  END IF;
END $$;

-- ----------------------------------------------------------
-- 15) GRANTs — saas_users column masking
-- ----------------------------------------------------------
REVOKE ALL ON TABLE saas_users FROM anon;
REVOKE ALL ON TABLE saas_users FROM authenticated;
GRANT SELECT (id, username, display_name, email, role, permissions, company_id, is_active, last_login, created_at)
  ON saas_users TO authenticated;
GRANT INSERT, UPDATE, DELETE ON saas_users TO authenticated;

REVOKE ALL ON TABLE login_attempts FROM anon, authenticated;
REVOKE ALL ON TABLE api_rate_attempts FROM anon, authenticated;

-- auth_tenant_owns_row: deprecated for RLS — kept for legacy RPC callers only
CREATE OR REPLACE FUNCTION auth_tenant_owns_row(row_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT
    auth_company_id() IS NOT NULL
    AND row_company_id IS NOT NULL
    AND row_company_id = auth_company_id();
$$;

COMMENT ON FUNCTION auth_tenant_owns_row(INTEGER) IS
  'Tenant match only (no super_admin). Super admin uses separate RLS policy.';
