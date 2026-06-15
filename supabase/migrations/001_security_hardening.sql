-- ============================================================
-- KYNO Security Migration — RLS, Audit, Indexes, Auth RPC
-- شغّل في Supabase SQL Editor (مرة واحدة)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS audit_logs (
  id            BIGSERIAL PRIMARY KEY,
  company_id    INTEGER REFERENCES companies(id) ON DELETE SET NULL,
  actor_id      INTEGER,
  actor_name    TEXT,
  actor_role    TEXT,
  action        TEXT NOT NULL,
  category      TEXT,
  details       TEXT,
  target_name   TEXT,
  meta          JSONB DEFAULT '{}'::jsonb,
  ip_address    TEXT,
  user_agent    TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_company ON audit_logs(company_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs(action);

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit_insert_authenticated" ON audit_logs;
DROP POLICY IF EXISTS "audit_select_company" ON audit_logs;

CREATE POLICY "audit_insert_authenticated" ON audit_logs
  FOR INSERT TO authenticated, anon
  WITH CHECK (true);

CREATE POLICY "audit_select_company" ON audit_logs
  FOR SELECT TO authenticated
  USING (
    company_id IS NULL
    OR company_id::text = COALESCE(auth.jwt() ->> 'company_id', '')
    OR (auth.jwt() ->> 'role') = 'super_admin'
  );

CREATE INDEX IF NOT EXISTS idx_attendance_emp_date ON attendance(employee_id, date_iso DESC);
CREATE INDEX IF NOT EXISTS idx_attendance_status ON attendance(status);
CREATE INDEX IF NOT EXISTS idx_employees_created ON employees(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_salary_emp_month ON salary_records(employee_id, month_iso);
CREATE INDEX IF NOT EXISTS idx_saas_users_company ON saas_users(company_id);

ALTER TABLE saas_users ADD COLUMN IF NOT EXISTS password_algo TEXT DEFAULT 'legacy_b64';

CREATE OR REPLACE FUNCTION saas_verify_login(p_username TEXT, p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
BEGIN
  IF p_username IS NULL OR length(trim(p_username)) < 2 OR p_password IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT su.*, c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE su.username = trim(p_username) AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  legacy_hash := encode(convert_to(p_password, 'UTF8'), 'base64');

  IF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      RETURN NULL;
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    RETURN NULL;
  END IF;

  UPDATE saas_users SET last_login = NOW() WHERE id = u.id;

  RETURN jsonb_build_object(
    'id', u.id,
    'username', u.username,
    'display_name', COALESCE(u.display_name, ''),
    'email', COALESCE(u.email, ''),
    'role', u.role,
    'permissions', COALESCE(u.permissions, '{}'::jsonb),
    'company_id', u.company_id,
    'company_name', u.company_name,
    'company_code', u.company_code,
    'company_status', u.company_status,
    'max_employees', COALESCE(u.max_employees, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION auth_company_id() RETURNS INTEGER AS $$
  SELECT NULLIF(auth.jwt() ->> 'company_id', '')::INTEGER;
$$ LANGUAGE sql STABLE;

DROP POLICY IF EXISTS "tenant_select_employees" ON employees;
CREATE POLICY "tenant_select_employees" ON employees
  FOR SELECT TO authenticated
  USING (
    auth_company_id() IS NULL
    OR company_id = auth_company_id()
    OR (auth.jwt() ->> 'role') = 'super_admin'
  );

DROP POLICY IF EXISTS "tenant_modify_employees" ON employees;
CREATE POLICY "tenant_modify_employees" ON employees
  FOR ALL TO authenticated
  USING (
    auth_company_id() IS NULL
    OR company_id = auth_company_id()
    OR (auth.jwt() ->> 'role') = 'super_admin'
  )
  WITH CHECK (
    auth_company_id() IS NULL
    OR company_id = auth_company_id()
    OR (auth.jwt() ->> 'role') = 'super_admin'
  );
