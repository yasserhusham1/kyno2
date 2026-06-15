-- ============================================================
-- KYNO â€” Merged migrations (manual SQL Editor run)
-- Range: 000+1..84 â€” 85 file(s)
-- Generated: 2026-06-11 20:06
-- NOTE: Empty DB needs 000_kyno_baseline_schema.sql first if not included
-- NOTE: SQL Editor may timeout - split batches 001-030, 031-060, 061-084 if needed
-- ============================================================


-- ============================================================
-- BEGIN: 000_kyno_baseline_schema.sql
-- ============================================================

-- ============================================================
-- KYNO 000 — Baseline schema (قاعدة فارغة جديدة)
-- شغّل هذا أولاً قبل 001..084
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ─── companies ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS companies (
  id              SERIAL PRIMARY KEY,
  company_name    TEXT NOT NULL DEFAULT '',
  company_code    TEXT NOT NULL UNIQUE,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('active', 'suspended', 'pending')),
  max_employees   INTEGER NOT NULL DEFAULT 50,
  plan_tier       TEXT DEFAULT 'starter',
  notes           TEXT DEFAULT '',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── saas_users ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS saas_users (
  id                    SERIAL PRIMARY KEY,
  username              TEXT NOT NULL UNIQUE,
  display_name          TEXT DEFAULT '',
  email                 TEXT,
  password_hash         TEXT,
  password_algo         TEXT DEFAULT 'legacy_b64',
  role                  TEXT NOT NULL DEFAULT 'company_user'
                        CHECK (role IN ('super_admin', 'company_admin', 'company_user')),
  permissions           JSONB NOT NULL DEFAULT '{}'::jsonb,
  company_id            INTEGER REFERENCES companies(id) ON DELETE SET NULL,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  force_password_reset  BOOLEAN NOT NULL DEFAULT FALSE,
  last_login            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_saas_users_company ON saas_users(company_id);
CREATE INDEX IF NOT EXISTS idx_saas_users_role ON saas_users(role);

-- ─── employees ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS employees (
  id                          SERIAL PRIMARY KEY,
  company_id                  INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name                        TEXT NOT NULL DEFAULT '',
  dept                        TEXT DEFAULT '',
  role                        TEXT DEFAULT '',
  phone                       TEXT DEFAULT '—',
  salary                      INTEGER NOT NULL DEFAULT 0,
  salary_type                 TEXT NOT NULL DEFAULT 'monthly',
  salary_half                 INTEGER NOT NULL DEFAULT 0,
  daily_rate                  INTEGER NOT NULL DEFAULT 0,
  days                        INTEGER NOT NULL DEFAULT 0,
  late_min                    INTEGER NOT NULL DEFAULT 0,
  check_in                    TIME DEFAULT '08:00',
  check_out                   TIME DEFAULT '17:00',
  open_hours                  BOOLEAN NOT NULL DEFAULT FALSE,
  remote_attend               BOOLEAN NOT NULL DEFAULT FALSE,
  include_overtime_in_salary  BOOLEAN NOT NULL DEFAULT FALSE,
  sal_status                  TEXT DEFAULT 'معلق',
  sal_bonus                   INTEGER NOT NULL DEFAULT 0,
  sal_deleted_period          TEXT DEFAULT '',
  avatar_url                  TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_employees_company ON employees(company_id);
CREATE INDEX IF NOT EXISTS idx_employees_created ON employees(created_at DESC);

-- ─── departments ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS departments (
  id          SERIAL PRIMARY KEY,
  company_id  INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_departments_company_name
  ON departments (company_id, lower(trim(name)));

-- ─── attendance ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS attendance (
  id           SERIAL PRIMARY KEY,
  employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id   INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  emp_name     TEXT DEFAULT '',
  dept         TEXT DEFAULT '',
  date_label   TEXT DEFAULT '',
  date_iso     DATE NOT NULL,
  check_in     TEXT DEFAULT '—',
  check_out    TEXT DEFAULT '—',
  hours        TEXT DEFAULT '—',
  late         TEXT DEFAULT '—',
  overtime     TEXT DEFAULT '—',
  status       TEXT DEFAULT 'طبيعي',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (employee_id, date_iso)
);

CREATE INDEX IF NOT EXISTS idx_attendance_emp_date ON attendance(employee_id, date_iso DESC);
CREATE INDEX IF NOT EXISTS idx_attendance_company ON attendance(company_id);
CREATE INDEX IF NOT EXISTS idx_attendance_status ON attendance(status);

-- ─── employee_devices ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS employee_devices (
  id               SERIAL PRIMARY KEY,
  employee_id      INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id       INTEGER REFERENCES companies(id) ON DELETE CASCADE,
  slot             SMALLINT NOT NULL,
  label            TEXT DEFAULT '',
  ip               TEXT DEFAULT '',
  fingerprint      TEXT DEFAULT '',
  pin              TEXT DEFAULT '',
  token            TEXT,
  token_created_at TIMESTAMPTZ,
  token_used_at    TIMESTAMPTZ,
  device_info      JSONB DEFAULT '{}'::jsonb,
  linked_at        TIMESTAMPTZ,
  last_login       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (employee_id, slot)
);

CREATE INDEX IF NOT EXISTS idx_employee_devices_emp ON employee_devices(employee_id);

-- ─── salary_records ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS salary_records (
  id               SERIAL PRIMARY KEY,
  employee_id      INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id       INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  month_iso        TEXT NOT NULL,
  month_label      TEXT DEFAULT '',
  base_salary      INTEGER NOT NULL DEFAULT 0,
  attend_days      INTEGER NOT NULL DEFAULT 0,
  late_minutes     INTEGER NOT NULL DEFAULT 0,
  late_deduct      INTEGER NOT NULL DEFAULT 0,
  absent_days      INTEGER NOT NULL DEFAULT 0,
  overtime_amount  INTEGER NOT NULL DEFAULT 0,
  bonus            INTEGER NOT NULL DEFAULT 0,
  total_deduct     INTEGER NOT NULL DEFAULT 0,
  net_salary       INTEGER NOT NULL DEFAULT 0,
  status           TEXT DEFAULT 'معلق',
  issued_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (employee_id, month_iso)
);

CREATE INDEX IF NOT EXISTS idx_salary_emp_month ON salary_records(employee_id, month_iso);

-- ─── subscriptions ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  id               SERIAL PRIMARY KEY,
  company_id       INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  plan_name        TEXT DEFAULT 'PRO',
  start_date       DATE,
  end_date         DATE,
  status           TEXT NOT NULL DEFAULT 'pending',
  duration_months  INTEGER DEFAULT 1,
  amount           NUMERIC(12,2) DEFAULT 0,
  notes            TEXT DEFAULT '',
  activated_by     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_company ON subscriptions(company_id);

-- ─── app_settings ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS app_settings (
  id          SERIAL PRIMARY KEY,
  key         TEXT NOT NULL UNIQUE,
  value       TEXT DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── notifications (legacy admin feed) ─────────────────────
CREATE TABLE IF NOT EXISTS notifications (
  id          SERIAL PRIMARY KEY,
  company_id  INTEGER REFERENCES companies(id) ON DELETE CASCADE,
  title       TEXT DEFAULT '',
  body        TEXT DEFAULT '',
  notif_type  TEXT DEFAULT 'info',
  unread      BOOLEAN DEFAULT TRUE,
  meta        JSONB DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_company ON notifications(company_id);

COMMENT ON SCHEMA public IS 'KYNO baseline — run migrations 001..084 after this file';

-- END: 000_kyno_baseline_schema.sql

-- ============================================================
-- BEGIN: 001_security_hardening.sql
-- ============================================================

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

-- END: 001_security_hardening.sql

-- ============================================================
-- BEGIN: 002_strict_rls.sql
-- ============================================================

-- ============================================================
-- KYNO Phase 2 — Strict RLS (شغّل بعد 001_security_hardening.sql)
-- تحذير: فعّل strictRls:true في config/local.config.js بعد التأكد
-- ============================================================

-- إزالة السياسات المفتوحة للـ anon (قراءة/كتابة بدون حدود)
DROP POLICY IF EXISTS "anon_all_employees"      ON employees;
DROP POLICY IF EXISTS "anon_all_attendance"     ON attendance;
DROP POLICY IF EXISTS "anon_all_devices"        ON employee_devices;
DROP POLICY IF EXISTS "anon_all_salary"         ON salary_records;
DROP POLICY IF EXISTS "anon_all_settings"       ON app_settings;
DROP POLICY IF EXISTS "anon_all_notif"          ON notifications;
DROP POLICY IF EXISTS "anon_all_departments"    ON departments;

-- RLS على جداول SaaS
ALTER TABLE companies     ENABLE ROW LEVEL SECURITY;
ALTER TABLE saas_users    ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs    ENABLE ROW LEVEL SECURITY;

-- الموظفون: authenticated فقط + company scope
DROP POLICY IF EXISTS "tenant_select_employees" ON employees;
DROP POLICY IF EXISTS "tenant_modify_employees" ON employees;

CREATE POLICY "tenant_select_employees" ON employees
  FOR SELECT TO authenticated, anon
  USING (
    company_id = COALESCE(NULLIF(current_setting('request.jwt.claim.company_id', true), '')::INTEGER, company_id)
    OR current_setting('request.jwt.claim.role', true) = 'super_admin'
  );

CREATE POLICY "tenant_insert_employees" ON employees
  FOR INSERT TO authenticated, anon
  WITH CHECK (company_id IS NOT NULL);

CREATE POLICY "tenant_update_employees" ON employees
  FOR UPDATE TO authenticated, anon
  USING (true) WITH CHECK (company_id IS NOT NULL);

CREATE POLICY "tenant_delete_employees" ON employees
  FOR DELETE TO authenticated, anon
  USING (true);

-- الحضور
DROP POLICY IF EXISTS "admin_all_attendance" ON attendance;
CREATE POLICY "tenant_attendance_all" ON attendance
  FOR ALL TO authenticated, anon
  USING (company_id IS NOT NULL)
  WITH CHECK (company_id IS NOT NULL);

-- الأجهزة
DROP POLICY IF EXISTS "admin_all_devices" ON employee_devices;
CREATE POLICY "tenant_devices_all" ON employee_devices
  FOR ALL TO authenticated, anon
  USING (true) WITH CHECK (true);

-- الإعدادات — company_id via key prefix optional; allow read settings
DROP POLICY IF EXISTS "admin_all_settings" ON app_settings;
CREATE POLICY "settings_read" ON app_settings
  FOR SELECT TO authenticated, anon USING (true);
CREATE POLICY "settings_write" ON app_settings
  FOR INSERT TO authenticated, anon WITH CHECK (true);
CREATE POLICY "settings_update" ON app_settings
  FOR UPDATE TO authenticated, anon USING (true) WITH CHECK (true);

-- RPC للعمليات الحساسة بدون كشف password_hash
CREATE OR REPLACE FUNCTION saas_get_user_profile(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE u RECORD;
BEGIN
  SELECT su.id, su.username, su.display_name, su.email, su.role, su.permissions, su.company_id,
         c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE su.id = p_user_id AND su.is_active = true
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', COALESCE(u.display_name, ''),
    'email', COALESCE(u.email, ''), 'role', u.role, 'permissions', COALESCE(u.permissions, '{}'::jsonb),
    'company_id', u.company_id, 'company_name', u.company_name, 'company_code', u.company_code,
    'company_status', u.company_status, 'max_employees', COALESCE(u.max_employees, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) TO anon, authenticated;

-- ترقية كلمة المرور إلى sha256 (اختياري — من لوحة SQL)
-- UPDATE saas_users SET password_algo = 'sha256', password_hash = encode(digest('YOUR_PASSWORD' || ':' || id::text, 'sha256'), 'hex') WHERE username = 'admin';

-- END: 002_strict_rls.sql

-- ============================================================
-- BEGIN: 003_auth_sessions_bcrypt.sql
-- ============================================================

-- ============================================================
-- KYNO Phase 3 — Sessions (HttpOnly via Edge) + bcrypt passwords
-- شغّل بعد 001 و 002
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- على Supabase: pgcrypto في schema extensions — يجب تضمينه في search_path
-- ============================================================
-- 1) Server-side sessions (token hash only — never store raw token)
-- ============================================================
CREATE TABLE IF NOT EXISTS saas_sessions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      INTEGER NOT NULL REFERENCES saas_users(id) ON DELETE CASCADE,
  token_hash   TEXT NOT NULL UNIQUE,
  expires_at   TIMESTAMPTZ NOT NULL,
  user_agent   TEXT,
  ip_address   TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  revoked_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_saas_sessions_user ON saas_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_saas_sessions_expires ON saas_sessions(expires_at);

ALTER TABLE saas_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "saas_sessions_service_only" ON saas_sessions;
CREATE POLICY "saas_sessions_service_only" ON saas_sessions
  FOR ALL TO authenticated, anon
  USING (false) WITH CHECK (false);

-- ============================================================
-- 2) Login — legacy_b64 | sha256 | bcrypt (pgcrypto crypt)
-- ============================================================
CREATE OR REPLACE FUNCTION saas_verify_login(p_username TEXT, p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
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

  IF u.password_algo = 'bcrypt' THEN
    IF u.password_hash IS NULL OR u.password_hash = '' THEN
      RETURN NULL;
    END IF;
    IF extensions.crypt(p_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      RETURN NULL;
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
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

-- ============================================================
-- 3) Session create / verify / revoke (called from Edge Functions)
-- ============================================================
CREATE OR REPLACE FUNCTION saas_create_session(
  p_user_id INTEGER,
  p_token_hash TEXT,
  p_expires_at TIMESTAMPTZ,
  p_user_agent TEXT DEFAULT NULL,
  p_ip_address TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE sid UUID;
BEGIN
  IF p_user_id IS NULL OR p_token_hash IS NULL OR length(p_token_hash) < 16 THEN
    RETURN NULL;
  END IF;
  DELETE FROM saas_sessions
  WHERE user_id = p_user_id AND revoked_at IS NULL AND expires_at < NOW();
  INSERT INTO saas_sessions (user_id, token_hash, expires_at, user_agent, ip_address)
  VALUES (p_user_id, p_token_hash, p_expires_at, p_user_agent, p_ip_address)
  RETURNING id INTO sid;
  RETURN sid;
END;
$$;

CREATE OR REPLACE FUNCTION saas_verify_session(p_token_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s RECORD;
  u RECORD;
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) < 16 THEN RETURN NULL; END IF;

  SELECT * INTO s FROM saas_sessions
  WHERE token_hash = p_token_hash
    AND revoked_at IS NULL
    AND expires_at > NOW()
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT su.id, su.username, su.display_name, su.email, su.role, su.permissions, su.company_id,
         c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE su.id = s.user_id AND su.is_active = true;

  IF NOT FOUND THEN RETURN NULL; END IF;

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
    'max_employees', COALESCE(u.max_employees, 0),
    'session_id', s.id
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_revoke_session(p_token_hash TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE saas_sessions SET revoked_at = NOW()
  WHERE token_hash = p_token_hash AND revoked_at IS NULL;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION saas_hash_password_bcrypt(p_password TEXT)
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT extensions.crypt(p_password, extensions.gen_salt('bf'::text, 10));
$$;

REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION saas_create_session(INTEGER, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION saas_verify_session(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION saas_revoke_session(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION saas_hash_password_bcrypt(TEXT) TO service_role;

-- END: 003_auth_sessions_bcrypt.sql

-- ============================================================
-- BEGIN: 004_tenant_rls_production.sql
-- ============================================================

-- ============================================================
-- KYNO 004 — RLS إنتاجي صارم (عزل الشركات + حماية الجلسات)
-- شغّل بعد 001 + 002 + 003
--
-- ⚠️ مهم: سياسات العزل تعتمد على JWT (auth.jwt) بعد ربط Supabase Auth
-- أو إصدار Access Token من Edge Function عند تسجيل الدخول.
-- بدون JWT صالح، العميل (anon) لن يقرأ/يكتب جداول البيانات مباشرة — وهذا مقصود.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
-- 0) company_id — إلزامي قبل RLS (إن لم تُشغّل الجزء SaaS من supabase_schema.sql)
-- ============================================================
ALTER TABLE employees        ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE attendance       ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE employee_devices ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE salary_records   ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE notifications    ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;
ALTER TABLE departments      ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id) DEFAULT 1;

UPDATE employees        SET company_id = 1 WHERE company_id IS NULL;
UPDATE attendance       SET company_id = 1 WHERE company_id IS NULL;
UPDATE employee_devices SET company_id = 1 WHERE company_id IS NULL;
UPDATE salary_records   SET company_id = 1 WHERE company_id IS NULL;
UPDATE notifications    SET company_id = 1 WHERE company_id IS NULL;
UPDATE departments      SET company_id = 1 WHERE company_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_employees_company    ON employees(company_id);
CREATE INDEX IF NOT EXISTS idx_attendance_company   ON attendance(company_id);
CREATE INDEX IF NOT EXISTS idx_devices_company      ON employee_devices(company_id);
CREATE INDEX IF NOT EXISTS idx_salary_company       ON salary_records(company_id);
CREATE INDEX IF NOT EXISTS idx_notif_company        ON notifications(company_id);
CREATE INDEX IF NOT EXISTS idx_departments_company  ON departments(company_id);

-- ============================================================
-- 1) دوال مساعدة لقراءة claims من JWT
-- ============================================================
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

-- ============================================================
-- 2) saas_sessions — لا وصول مباشر من الواجهة (فقط service_role + RPC)
-- ============================================================
ALTER TABLE saas_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "saas_sessions_service_only" ON saas_sessions;
DROP POLICY IF EXISTS "saas_sessions_deny_all" ON saas_sessions;

CREATE POLICY "saas_sessions_deny_all" ON saas_sessions
  FOR ALL TO anon, authenticated
  USING (false) WITH CHECK (false);

-- service_role يتجاوز RLS تلقائياً عند Edge Functions

-- ============================================================
-- 3) saas_users — منع تسريب password_hash وعزل الشركات
-- ============================================================
ALTER TABLE saas_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_saas_users" ON saas_users;
DROP POLICY IF EXISTS "saas_users_deny_anon" ON saas_users;
DROP POLICY IF EXISTS "saas_users_select_tenant" ON saas_users;
DROP POLICY IF EXISTS "saas_users_modify_super" ON saas_users;

-- منع anon بالكامل (يوقف fallback القديم .eq('password_hash') من المتصفح)
CREATE POLICY "saas_users_deny_anon" ON saas_users
  FOR ALL TO anon
  USING (false) WITH CHECK (false);

-- authenticated: قراءة مستخدمي نفس الشركة فقط (بدون أعمدة حساسة عبر VIEW لاحقاً)
CREATE POLICY "saas_users_select_tenant" ON saas_users
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      company_id IS NOT NULL
      AND company_id = auth_company_id()
    )
    OR id::text = auth.uid()::text
  );

CREATE POLICY "saas_users_insert_super" ON saas_users
  FOR INSERT TO authenticated
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "saas_users_update_tenant" ON saas_users
  FOR UPDATE TO authenticated
  USING (auth_is_super_admin() OR company_id = auth_company_id())
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

CREATE POLICY "saas_users_delete_super" ON saas_users
  FOR DELETE TO authenticated
  USING (auth_is_super_admin());

-- إخفاء password_hash عن الأدوار العامة (عمودية)
REVOKE ALL ON TABLE saas_users FROM anon;
REVOKE ALL ON TABLE saas_users FROM authenticated;
GRANT SELECT (id, username, display_name, email, role, permissions, company_id, is_active, last_login, created_at)
  ON saas_users TO authenticated;
GRANT INSERT, UPDATE ON saas_users TO authenticated;

-- ============================================================
-- 4) companies & subscriptions
-- ============================================================
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_companies" ON companies;
DROP POLICY IF EXISTS "anon_all_subscriptions" ON subscriptions;

CREATE POLICY "companies_deny_anon" ON companies
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "companies_select_tenant" ON companies
  FOR SELECT TO authenticated
  USING (auth_is_super_admin() OR id = auth_company_id());

CREATE POLICY "companies_modify_super" ON companies
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

CREATE POLICY "subscriptions_deny_anon" ON subscriptions
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "subscriptions_tenant" ON subscriptions
  FOR ALL TO authenticated
  USING (auth_is_super_admin() OR company_id = auth_company_id())
  WITH CHECK (auth_is_super_admin() OR company_id = auth_company_id());

-- ============================================================
-- 5) employees — عزل company_id صارم (استبدال سياسات 002 الضعيفة)
-- ============================================================
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_employees" ON employees;
DROP POLICY IF EXISTS "tenant_insert_employees" ON employees;
DROP POLICY IF EXISTS "tenant_update_employees" ON employees;
DROP POLICY IF EXISTS "tenant_delete_employees" ON employees;
DROP POLICY IF EXISTS "tenant_modify_employees" ON employees;
DROP POLICY IF EXISTS "anon_all_employees" ON employees;

CREATE POLICY "employees_deny_anon" ON employees
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "employees_select_tenant" ON employees
  FOR SELECT TO authenticated
  USING (auth_tenant_owns_row(company_id));

CREATE POLICY "employees_insert_tenant" ON employees
  FOR INSERT TO authenticated
  WITH CHECK (
    company_id IS NOT NULL
    AND auth_tenant_owns_row(company_id)
  );

CREATE POLICY "employees_update_tenant" ON employees
  FOR UPDATE TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (auth_tenant_owns_row(company_id));

CREATE POLICY "employees_delete_tenant" ON employees
  FOR DELETE TO authenticated
  USING (auth_tenant_owns_row(company_id));

-- ============================================================
-- 6) attendance
-- ============================================================
ALTER TABLE attendance ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_attendance_all" ON attendance;
DROP POLICY IF EXISTS "admin_all_attendance" ON attendance;
DROP POLICY IF EXISTS "anon_all_attendance" ON attendance;

CREATE POLICY "attendance_deny_anon" ON attendance
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "attendance_select_tenant" ON attendance
  FOR SELECT TO authenticated
  USING (auth_tenant_owns_row(company_id));

CREATE POLICY "attendance_insert_tenant" ON attendance
  FOR INSERT TO authenticated
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

CREATE POLICY "attendance_update_tenant" ON attendance
  FOR UPDATE TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (auth_tenant_owns_row(company_id));

CREATE POLICY "attendance_delete_tenant" ON attendance
  FOR DELETE TO authenticated
  USING (auth_tenant_owns_row(company_id));

-- ============================================================
-- 7) employee_devices — عبر company_id من employees
-- ============================================================
ALTER TABLE employee_devices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_devices_all" ON employee_devices;
DROP POLICY IF EXISTS "anon_all_devices" ON employee_devices;

CREATE POLICY "devices_deny_anon" ON employee_devices
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "devices_tenant" ON employee_devices
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = employee_devices.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = employee_devices.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  );

-- ============================================================
-- 8) salary_records
-- ============================================================
ALTER TABLE salary_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_salary" ON salary_records;

CREATE POLICY "salary_deny_anon" ON salary_records
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "salary_tenant" ON salary_records
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = salary_records.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM employees e
      WHERE e.id = salary_records.employee_id
        AND auth_tenant_owns_row(e.company_id)
    )
  );

-- ============================================================
-- 9) app_settings — مفاتيح عامة vs مفاتيح شركة (key: company:{id}:...)
-- ============================================================
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "settings_read" ON app_settings;
DROP POLICY IF EXISTS "settings_write" ON app_settings;
DROP POLICY IF EXISTS "settings_update" ON app_settings;
DROP POLICY IF EXISTS "anon_all_settings" ON app_settings;

CREATE POLICY "settings_deny_anon" ON app_settings
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "settings_select_tenant" ON app_settings
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

-- ============================================================
-- 10) departments — company_id إلزامي
-- ============================================================
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_departments" ON departments;

CREATE POLICY "departments_deny_anon" ON departments
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "departments_tenant" ON departments
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

-- ============================================================
-- 11) notifications
-- ============================================================
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_notif" ON notifications;

CREATE POLICY "notifications_deny_anon" ON notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY "notifications_tenant" ON notifications
  FOR ALL TO authenticated
  USING (auth_tenant_owns_row(company_id))
  WITH CHECK (company_id IS NOT NULL AND auth_tenant_owns_row(company_id));

-- ============================================================
-- 12) audit_logs
-- ============================================================
DROP POLICY IF EXISTS "audit_insert_authenticated" ON audit_logs;
DROP POLICY IF EXISTS "audit_select_company" ON audit_logs;

CREATE POLICY "audit_insert_tenant" ON audit_logs
  FOR INSERT TO authenticated, anon
  WITH CHECK (
    company_id IS NULL
    OR auth_tenant_owns_row(company_id)
  );

CREATE POLICY "audit_select_tenant" ON audit_logs
  FOR SELECT TO authenticated
  USING (auth_tenant_owns_row(company_id) OR company_id IS NULL);

-- ============================================================
-- 13) تقييد RPCs الحساسة
-- ============================================================
REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_get_user_profile(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) TO service_role;

-- منع enumerate users عبر anon
REVOKE EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) FROM anon;

-- END: 004_tenant_rls_production.sql

-- ============================================================
-- BEGIN: 005_device_registration_rpc.sql
-- ============================================================

-- ============================================================
-- 005 — تسجيل جهاز الموظف عبر QR بدون JWT (anon-safe RPC)
-- شغّل بعد 004 — يُحدَّث بالكامل في 008_qr_token_fix.sql
-- ============================================================

CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token,
        'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''),
        'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;
  END IF;

  IF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', COALESCE(d.token, tok),
        'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''),
        'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;

    SELECT e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employees e
    WHERE e.id = p_employee_id
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', p_slot,
        'label', 'الهاتف ' || p_slot::text,
        'token', tok,
        'pin', NULL,
        'fingerprint', '',
        'ip', '',
        'barcode', 'ATT-' || d.emp_id::text || '-D' || p_slot::text
      );
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION saas_link_device_by_token(
  p_token TEXT,
  p_fingerprint TEXT,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  now_ts TIMESTAMPTZ := NOW();
BEGIN
  IF p_token IS NULL OR length(trim(p_token)) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;
  IF p_fingerprint IS NULL OR length(trim(p_fingerprint)) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  SELECT ed.*, e.name AS emp_name
  INTO d
  FROM employee_devices ed
  JOIN employees e ON e.id = ed.employee_id
  WHERE ed.token = trim(p_token)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> trim(p_fingerprint) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = trim(p_fingerprint),
    ip = COALESCE(NULLIF(trim(p_ip), ''), ip),
    device_info = COALESCE(p_device_info, device_info, '{}'::jsonb),
    linked_at = COALESCE(linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;

-- END: 005_device_registration_rpc.sql

-- ============================================================
-- BEGIN: 006_app_settings_tenant_keys.sql
-- ============================================================

-- ============================================================
-- 006 — ترحيل مفاتيح app_settings إلى company:{id}:key (RLS 004)
-- آمن عند وجود مفاتيح company:1:… مسبقاً (لا duplicate key)
-- ============================================================

-- 1) احذف المفاتيح القديمة إذا النسخة الجديدة موجودة already
DELETE FROM app_settings AS old
WHERE old.key NOT LIKE 'company:%'
  AND old.key NOT LIKE 'global:%'
  AND EXISTS (
    SELECT 1 FROM app_settings AS newer
    WHERE newer.key = 'company:1:' || old.key
  );

-- 2) أعد تسمية ما تبقّى من مفاتيح قديمة
UPDATE app_settings
SET key = 'company:1:' || key
WHERE key NOT LIKE 'company:%'
  AND key NOT LIKE 'global:%';

-- END: 006_app_settings_tenant_keys.sql

-- ============================================================
-- BEGIN: 007_departments_rpc.sql
-- ============================================================

-- ============================================================
-- 007 — إنشاء قسم للشركة عبر RPC (تجاوز مشاكل upsert المباشر + RLS)
-- شغّل بعد 004
-- ============================================================

CREATE OR REPLACE FUNCTION saas_ensure_department(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  n TEXT := NULLIF(trim(p_name), '');
BEGIN
  IF n IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  IF EXISTS (SELECT 1 FROM departments WHERE name = n LIMIT 1) THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n);
  END IF;

  INSERT INTO departments (name, company_id) VALUES (n, cid);
  RETURN jsonb_build_object('ok', true, 'created', true, 'name', n, 'company_id', cid);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n);
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_ensure_department(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_ensure_department(TEXT) TO authenticated;

-- السماح بقراءة الأقسام للمستخدم المصادق (إن كان GRANT ناقصاً)
GRANT SELECT, INSERT, UPDATE ON departments TO authenticated;

-- END: 007_departments_rpc.sql

-- ============================================================
-- BEGIN: 008_qr_token_fix.sql
-- ============================================================

-- ============================================================
-- 008 — إصلاح QR: fallback بالموظف/slot + رفع token فوري
-- شغّل بعد 005
-- ============================================================

-- 1) lookup: إن فشل token جرّب employee_id + slot (reg=ATT-X-DY في الرابط)
CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token,
        'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''),
        'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;
  END IF;

  IF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', COALESCE(d.token, tok),
        'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''),
        'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;

    SELECT e.id AS emp_id, e.name AS emp_name, e.dept, e.company_id
    INTO d
    FROM employees e
    WHERE e.id = p_employee_id
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'employee_id', d.emp_id,
        'emp_name', d.emp_name,
        'dept', d.dept,
        'company_id', d.company_id,
        'slot', p_slot,
        'label', 'الهاتف ' || p_slot::text,
        'token', tok,
        'pin', NULL,
        'fingerprint', '',
        'ip', '',
        'barcode', 'ATT-' || d.emp_id::text || '-D' || p_slot::text
      );
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

-- 2) رفع token من لوحة الإدارة (قبل مسح QR)
CREATE OR REPLACE FUNCTION saas_upsert_device_token(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  SELECT company_id INTO cid FROM employees WHERE id = p_employee_id;
  IF cid IS NULL THEN cid := 1; END IF;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id
  ) VALUES (
    p_employee_id,
    p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok,
    NOW(),
    cid
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, EXCLUDED.token_created_at),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = COALESCE(employee_devices.company_id, EXCLUDED.company_id);

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'slot', p_slot,
    'token', tok
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

-- END: 008_qr_token_fix.sql

-- ============================================================
-- BEGIN: 009_audit_log_rpc.sql
-- ============================================================

-- ============================================================
-- 009 — تسجيل audit_logs عبر RPC (لا يعطل حفظ الإعدادات/GPS)
-- شغّل بعد 004
-- ============================================================

CREATE OR REPLACE FUNCTION saas_insert_audit_log(
  p_action TEXT,
  p_category TEXT DEFAULT NULL,
  p_details TEXT DEFAULT NULL,
  p_target_name TEXT DEFAULT NULL,
  p_actor_id INTEGER DEFAULT NULL,
  p_actor_name TEXT DEFAULT NULL,
  p_actor_role TEXT DEFAULT NULL,
  p_meta JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta
  ) VALUES (
    cid,
    p_actor_id,
    NULLIF(trim(p_actor_name), ''),
    NULLIF(trim(p_actor_role), ''),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    COALESCE(p_meta, '{}'::jsonb)
  );

  RETURN jsonb_build_object('ok', true);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_insert_audit_log(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_insert_audit_log(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, JSONB) TO authenticated;

GRANT SELECT, INSERT ON audit_logs TO authenticated;

-- END: 009_audit_log_rpc.sql

-- ============================================================
-- BEGIN: 010_qr_production_reset.sql
-- ============================================================

-- ============================================================
-- 010 — QR إنتاجي: إعادة ضبط الجهاز عند إصدار token جديد
-- (مهم بعد حذف موظف وإضافة آخر على نفس الهاتف)
-- شغّل بعد 008
-- ============================================================

CREATE OR REPLACE FUNCTION saas_upsert_device_token(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  SELECT company_id INTO cid FROM employees WHERE id = p_employee_id;
  IF cid IS NULL THEN cid := 1; END IF;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login
  ) VALUES (
    p_employee_id,
    p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok,
    NOW(),
    cid,
    '', '', NULL, NULL, NULL
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = COALESCE(employee_devices.company_id, EXCLUDED.company_id),
    fingerprint = '',
    ip = '',
    linked_at = NULL,
    token_used_at = NULL,
    last_login = NULL,
    device_info = '{}'::jsonb;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'slot', p_slot,
    'token', tok
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_device_token(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

-- END: 010_qr_production_reset.sql

-- ============================================================
-- BEGIN: 011_qr_radical_fix.sql
-- ============================================================

-- ============================================================
-- 011 — حل جذري QR: نشر من الإدارة + حلّ ذاتي على الهاتف
-- شغّل مرة واحدة بعد 008/010
-- ============================================================

-- ── 1) الإدارة: نشر QR (موظف + أجهزة + token) في عملية واحدة ──
CREATE OR REPLACE FUNCTION saas_publish_employee_qr(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT id, name, dept, company_id INTO e
  FROM employees WHERE id = p_employee_id LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login, device_info
  ) VALUES (
    p_employee_id, p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok, NOW(), COALESCE(e.company_id, 1),
    '', '', NULL, NULL, NULL, '{}'::jsonb
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = COALESCE(employee_devices.company_id, EXCLUDED.company_id),
    fingerprint = '',
    ip = '',
    linked_at = NULL,
    token_used_at = NULL,
    last_login = NULL,
    device_info = '{}'::jsonb;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', e.id,
    'emp_name', e.name,
    'dept', e.dept,
    'company_id', e.company_id,
    'slot', p_slot,
    'token', tok,
    'barcode', 'ATT-' || e.id::text || '-D' || p_slot::text
  );
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ── 2) الهاتف: بحث + إصلاح ذاتي إن وُجد الموظف ولم يُرفع token ──
CREATE OR REPLACE FUNCTION saas_resolve_qr_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  sl SMALLINT := p_slot;
BEGIN
  -- أ) بحث بالـ token
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, emp.id AS emp_id, emp.name AS emp_name, emp.dept, emp.company_id
    INTO d
    FROM employee_devices ed
    JOIN employees emp ON emp.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'ok', true, 'source', 'token',
        'employee_id', d.emp_id, 'emp_name', d.emp_name, 'dept', d.dept,
        'company_id', d.company_id, 'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token, 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text
      );
    END IF;
  END IF;

  -- ب) بحث برقم الموظف + slot
  IF p_employee_id IS NOT NULL AND sl IS NOT NULL THEN
    SELECT id, name, dept, company_id INTO e
    FROM employees WHERE id = p_employee_id LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
    END IF;

    SELECT ed.* INTO d
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id AND ed.slot = sl
    LIMIT 1;

    IF FOUND THEN
      -- إصلاح ذاتي: token في الرابط ≠ DB → حدّث token وامسح بصمة قديمة
      IF tok IS NOT NULL AND length(tok) >= 10 AND (d.token IS NULL OR d.token <> tok) THEN
        UPDATE employee_devices SET
          token = tok,
          token_created_at = COALESCE(token_created_at, NOW()),
          fingerprint = '', ip = '',
          linked_at = NULL, token_used_at = NULL, last_login = NULL
        WHERE id = d.id;
        d.token := tok;
        d.fingerprint := '';
      END IF;

      RETURN jsonb_build_object(
        'ok', true, 'source', 'employee_slot',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', COALESCE(d.label, 'الهاتف ' || sl::text),
        'token', COALESCE(d.token, tok), 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text
      );
    END IF;

    -- ج) الموظف موجود لكن لا صف جهاز → أنشئه (إصلاح ذاتي)
    IF tok IS NOT NULL AND length(tok) >= 10 THEN
      INSERT INTO employee_devices (
        employee_id, slot, label, token, token_created_at, company_id,
        fingerprint, ip, device_info
      ) VALUES (
        p_employee_id, sl, 'الهاتف ' || sl::text, tok, NOW(), COALESCE(e.company_id, 1),
        '', '', '{}'::jsonb
      )
      ON CONFLICT (employee_id, slot) DO UPDATE SET
        token = EXCLUDED.token,
        fingerprint = '', ip = '';

      RETURN jsonb_build_object(
        'ok', true, 'source', 'auto_created',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', 'الهاتف ' || sl::text,
        'token', tok, 'pin', NULL,
        'fingerprint', '', 'ip', '',
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', true, 'source', 'employee_only',
      'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
      'company_id', e.company_id, 'slot', sl,
      'label', 'الهاتف ' || sl::text,
      'token', tok, 'pin', NULL,
      'fingerprint', '', 'ip', '',
      'barcode', 'ATT-' || e.id::text || '-D' || sl::text
    );
  END IF;

  IF tok IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'token_not_found');
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_qr');
END;
$$;

-- ── 3) تحديث lookup القديم ليستخدم نفس المنطق ──
CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r JSONB;
BEGIN
  r := saas_resolve_qr_registration(p_token, p_employee_id, p_slot);
  IF r IS NULL OR (r->>'ok')::boolean IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  RETURN r - 'ok' - 'source' - 'error';
END;
$$;

REVOKE ALL ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

-- END: 011_qr_radical_fix.sql

-- ============================================================
-- BEGIN: 012_preserve_device_link.sql
-- ============================================================

-- ============================================================
-- 012 — عدم مسح بصمة/IP عند إعادة نشر QR بنفس token
-- شغّل بعد 011
-- ============================================================

DROP FUNCTION IF EXISTS saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB);

CREATE OR REPLACE FUNCTION saas_publish_employee_qr(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  prev RECORD;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT id, name, dept, company_id INTO e
  FROM employees WHERE id = p_employee_id LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  SELECT token, fingerprint, ip, linked_at, token_used_at, last_login
  INTO prev
  FROM employee_devices
  WHERE employee_id = p_employee_id AND slot = p_slot
  LIMIT 1;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login, device_info
  ) VALUES (
    p_employee_id, p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok, NOW(), COALESCE(e.company_id, 1),
    '', '', NULL, NULL, NULL, '{}'::jsonb
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = COALESCE(employee_devices.company_id, EXCLUDED.company_id),
    fingerprint = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN ''
      ELSE COALESCE(employee_devices.fingerprint, '')
    END,
    ip = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN ''
      ELSE COALESCE(employee_devices.ip, '')
    END,
    linked_at = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.linked_at
    END,
    token_used_at = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.token_used_at
    END,
    last_login = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.last_login
    END,
    device_info = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN '{}'::jsonb
      ELSE COALESCE(employee_devices.device_info, '{}'::jsonb)
    END;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', e.id,
    'emp_name', e.name,
    'dept', e.dept,
    'company_id', e.company_id,
    'slot', p_slot,
    'token', tok,
    'barcode', 'ATT-' || e.id::text || '-D' || p_slot::text,
    'preserved_link', prev IS NOT NULL AND prev.token IS NOT NULL AND prev.token = tok
      AND COALESCE(prev.fingerprint, '') <> ''
  );
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ربط الجهاز بالـ token أو برقم الموظف + slot
CREATE OR REPLACE FUNCTION saas_link_device_by_token(
  p_token TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  now_ts TIMESTAMPTZ := NOW();
  tok TEXT := NULLIF(trim(p_token), '');
  fp TEXT := NULLIF(trim(p_fingerprint), '');
BEGIN
  IF fp IS NULL OR length(fp) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.name AS emp_name
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> fp THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = fp,
    ip = COALESCE(NULLIF(trim(p_ip), ''), ip),
    device_info = COALESCE(p_device_info, device_info, '{}'::jsonb),
    linked_at = COALESCE(linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'fingerprint', fp,
    'ip', COALESCE(NULLIF(trim(p_ip), ''), d.ip, '')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;

-- END: 012_preserve_device_link.sql

-- ============================================================
-- BEGIN: 013_app_settings_cleanup.sql
-- ============================================================

-- ============================================================
-- 013 — تنظيف مفاتيح app_settings المكررة (قديمة vs company:1:)
-- يمنع عودة «شركة النخبة العراقية» من مفتاح قديم
-- شغّل بعد 006
-- ============================================================

DELETE FROM app_settings AS old
WHERE old.key NOT LIKE 'company:%'
  AND old.key NOT LIKE 'global:%'
  AND EXISTS (
    SELECT 1 FROM app_settings AS newer
    WHERE newer.key = 'company:1:' || old.key
  );

-- تأكد أن المفاتيح القديمة المتبقية أُعيدت تسميتها
UPDATE app_settings
SET key = 'company:1:' || key
WHERE key NOT LIKE 'company:%'
  AND key NOT LIKE 'global:%';

-- END: 013_app_settings_cleanup.sql

-- ============================================================
-- BEGIN: 014_company_users_rpc.sql
-- ============================================================

-- ============================================================
-- 014 — إدارة مستخدمي الشركة (مدير الشركة)
-- شغّل بعد 004/003
-- ============================================================

CREATE OR REPLACE FUNCTION saas_list_company_users(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := p_company_id;
BEGIN
  IF cid IS NULL OR cid <= 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (auth_app_role() = 'company_admin' AND auth_company_id() = cid) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', u.id,
      'username', u.username,
      'display_name', COALESCE(u.display_name, ''),
      'email', COALESCE(u.email, ''),
      'role', u.role,
      'permissions', COALESCE(u.permissions, '{}'::jsonb),
      'company_id', u.company_id,
      'is_active', COALESCE(u.is_active, true),
      'last_login', u.last_login,
      'created_at', u.created_at
    ) ORDER BY u.id)
    FROM saas_users u
    WHERE u.company_id = cid
      AND u.role <> 'super_admin'
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (auth_app_role() = 'company_admin' AND auth_company_id() = cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', row_out.company_id,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_company_user(
  p_user_id INTEGER,
  p_company_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uid INTEGER := p_user_id;
BEGIN
  IF uid IS NULL OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (auth_app_role() = 'company_admin' AND auth_company_id() = cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  DELETE FROM saas_users WHERE id = uid AND company_id = cid;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_list_company_users(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_company_users(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) TO authenticated;

-- السماح لمدير الشركة بحذف مستخدمي شركته (RLS 004 كان super_admin فقط)
DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_app_role() = 'company_admin'
      AND company_id = auth_company_id()
      AND role <> 'super_admin'
    )
  );

-- END: 014_company_users_rpc.sql

-- ============================================================
-- BEGIN: 015_company_user_delete_fix.sql
-- ============================================================

-- ============================================================
-- 015 — إصلاح حذف مستخدمي الشركة (مدير الشركة)
-- شغّل بعد 014
-- ============================================================

GRANT DELETE ON TABLE saas_users TO authenticated;

CREATE OR REPLACE FUNCTION saas_delete_company_user(
  p_user_id INTEGER,
  p_company_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  deleted_count INTEGER;
BEGIN
  IF uid IS NULL OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := NULLIF(COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'saas_user_id',
    auth.jwt() ->> 'saas_user_id'
  ), '')::INTEGER;

  IF actor_id IS NOT NULL AND actor_id = uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_delete');
  END IF;

  IF NOT auth_is_super_admin()
     AND NOT (
       auth_app_role() IN ('company_admin', 'super_admin')
       AND auth_company_id() IS NOT NULL
       AND auth_company_id() = cid
     ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  DELETE FROM saas_sessions WHERE user_id = uid;
  DELETE FROM saas_users WHERE id = uid AND company_id = cid;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;

  IF deleted_count < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'delete_failed');
  END IF;

  RETURN jsonb_build_object('ok', true, 'deleted_id', uid);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
DROP POLICY IF EXISTS "saas_users_delete_tenant" ON saas_users;

CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_app_role() IN ('company_admin', 'super_admin')
      AND company_id IS NOT NULL
      AND company_id = auth_company_id()
      AND role <> 'super_admin'
    )
  );

REVOKE ALL ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) TO authenticated;

-- END: 015_company_user_delete_fix.sql

-- ============================================================
-- BEGIN: 016_company_users_login_delete_fix.sql
-- ============================================================

-- ============================================================
-- 016 — إصلاح دخول مستخدمي الشركة + صلاحية الحذف لمدير الشركة
-- شغّل بعد 014 و 015
-- ============================================================

-- ----------------------------------------------------------
-- 1) هوية المستخدم من JWT + التحقق من DB (أدق من claims فقط)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_saas_user_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT NULLIF(
    COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'saas_user_id',
      auth.jwt() ->> 'saas_user_id'
    ),
    ''
  )::INTEGER;
$$;

CREATE OR REPLACE FUNCTION auth_can_manage_tenant_users(p_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  actor_id INTEGER;
  actor_role TEXT;
  actor_cid INTEGER;
  actor_perms JSONB;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN FALSE;
  END IF;

  IF auth_is_super_admin() THEN
    RETURN TRUE;
  END IF;

  actor_id := auth_saas_user_id();
  IF actor_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT role, company_id, COALESCE(permissions, '{}'::jsonb)
  INTO actor_role, actor_cid, actor_perms
  FROM saas_users
  WHERE id = actor_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF actor_cid IS NULL OR actor_cid <> p_company_id THEN
    RETURN FALSE;
  END IF;

  IF actor_role IN ('company_admin', 'super_admin') THEN
    RETURN TRUE;
  END IF;

  IF actor_role = 'company_user'
     AND COALESCE((actor_perms ->> 'users_permissions')::boolean, false) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION auth_can_manage_tenant_users(INTEGER) TO authenticated;

-- ----------------------------------------------------------
-- 2) إصلاح تسجيل الدخول (حساسية حروف اسم المستخدم + bcrypt)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_verify_login(p_username TEXT, p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
  uname TEXT := lower(trim(p_username));
BEGIN
  IF uname IS NULL OR length(uname) < 2 OR p_password IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT su.*, c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE lower(su.username) = uname AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  legacy_hash := encode(convert_to(p_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR u.password_hash = '' THEN
      RETURN NULL;
    END IF;
    IF extensions.crypt(p_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      RETURN NULL;
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
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

-- مستخدمون أُضيفوا بـ bcrypt لكن password_algo بقي legacy
UPDATE saas_users
SET password_algo = 'bcrypt'
WHERE password_hash LIKE '$2%'
  AND COALESCE(password_algo, 'legacy_b64') <> 'bcrypt';

REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT) TO anon, authenticated;

GRANT EXECUTE ON FUNCTION saas_hash_password_bcrypt(TEXT) TO authenticated, service_role;

-- ----------------------------------------------------------
-- 3) RPCs — صلاحية من DB (مدير الشركة وليس super_admin فقط)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_list_company_users(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
BEGIN
  IF cid IS NULL OR cid <= 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', u.id,
      'username', u.username,
      'display_name', COALESCE(u.display_name, ''),
      'email', COALESCE(u.email, ''),
      'role', u.role,
      'permissions', COALESCE(u.permissions, '{}'::jsonb),
      'company_id', u.company_id,
      'is_active', COALESCE(u.is_active, true),
      'last_login', u.last_login,
      'created_at', u.created_at
    ) ORDER BY u.id)
    FROM saas_users u
    WHERE u.company_id = cid
      AND u.role <> 'super_admin'
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', row_out.company_id,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_company_user(
  p_user_id INTEGER,
  p_company_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  deleted_count INTEGER;
BEGIN
  IF uid IS NULL OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();

  IF actor_id IS NOT NULL AND actor_id = uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_delete');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  DELETE FROM saas_sessions WHERE user_id = uid;
  DELETE FROM saas_users WHERE id = uid AND company_id = cid;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;

  IF deleted_count < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'delete_failed');
  END IF;

  RETURN jsonb_build_object('ok', true, 'deleted_id', uid);
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT DELETE ON TABLE saas_users TO authenticated;

DROP POLICY IF EXISTS "saas_users_delete_super" ON saas_users;
DROP POLICY IF EXISTS "saas_users_delete_tenant" ON saas_users;

CREATE POLICY "saas_users_delete_tenant" ON saas_users
  FOR DELETE TO authenticated
  USING (
    role <> 'super_admin'
    AND auth_can_manage_tenant_users(company_id)
  );

REVOKE ALL ON FUNCTION saas_list_company_users(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_company_users(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_company_user(INTEGER, INTEGER) TO authenticated;

-- END: 016_company_users_login_delete_fix.sql

-- ============================================================
-- BEGIN: 017_super_admin_account_update.sql
-- ============================================================

-- ============================================================
-- 017 — تحديث حساب السوبر أدمن (اسم مستخدم / بريد / كلمة مرور)
-- شغّل بعد 016
-- ============================================================

CREATE OR REPLACE FUNCTION saas_update_saas_account(
  p_user_id INTEGER,
  p_username TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_password TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  uname TEXT;
  hash TEXT;
  row_out RECORD;
BEGIN
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();

  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF actor_id IS NOT NULL AND actor_id <> uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_only');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users WHERE id = uid AND role = 'super_admin' AND is_active = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  uname := lower(trim(COALESCE(p_username, '')));
  IF uname IS NOT NULL AND length(uname) >= 3 THEN
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname AND id <> uid) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;
  ELSE
    uname := NULL;
  END IF;

  UPDATE saas_users SET
    username = COALESCE(uname, username),
    email = CASE WHEN p_email IS NOT NULL THEN NULLIF(trim(p_email), '') ELSE email END,
    updated_at = NOW()
  WHERE id = uid AND role = 'super_admin'
  RETURNING * INTO row_out;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;
    UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', row_out.id,
      'username', row_out.username,
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT) TO authenticated;

-- END: 017_super_admin_account_update.sql

-- ============================================================
-- BEGIN: 018_platform_globals.sql
-- ============================================================

-- 018 — إعدادات المنصة العامة: واتساب الدعم + إشعارات البث للشركات

INSERT INTO app_settings (key, value, updated_at)
VALUES
  ('global:support_whatsapp', '07733344940', NOW()),
  ('global:platform_announcements', '[]', NOW())
ON CONFLICT (key) DO NOTHING;

-- رقم واتساب الدعم — قابل للقراءة قبل تسجيل الدخول (صفحة الدخول)
CREATE OR REPLACE FUNCTION get_platform_support_whatsapp()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
    '07733344940'
  );
$$;

REVOKE ALL ON FUNCTION get_platform_support_whatsapp() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_platform_support_whatsapp() TO anon, authenticated;

-- END: 018_platform_globals.sql

-- ============================================================
-- BEGIN: 019_support_whatsapp_team.sql
-- ============================================================

-- 019 — رقم واتساب فريق الدعم (منفصل عن تفعيل الاشتراك)

INSERT INTO app_settings (key, value, updated_at)
VALUES ('global:support_whatsapp_team', '07733344940', NOW())
ON CONFLICT (key) DO NOTHING;

-- END: 019_support_whatsapp_team.sql

-- ============================================================
-- BEGIN: 020_platform_public_settings_rpc.sql
-- ============================================================

-- 020 — RPC لجلب إعدادات المنصة (إشعارات + واتساب) للشركات المسجّلة

CREATE OR REPLACE FUNCTION get_platform_public_settings()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'support_whatsapp', COALESCE(
      (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
      '07733344940'
    ),
    'support_whatsapp_team', COALESCE(
      NULLIF(TRIM((SELECT value FROM app_settings WHERE key = 'global:support_whatsapp_team' LIMIT 1)), ''),
      (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
      '07733344940'
    ),
    'announcements', COALESCE(
      (SELECT value::jsonb FROM app_settings WHERE key = 'global:platform_announcements' LIMIT 1),
      '[]'::jsonb
    )
  );
$$;

REVOKE ALL ON FUNCTION get_platform_public_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_platform_public_settings() TO authenticated;

-- END: 020_platform_public_settings_rpc.sql

-- ============================================================
-- BEGIN: 021_platform_announcements_anon_read.sql
-- ============================================================

-- 021 — السماح لجميع العملاء (anon + authenticated) بقراءة إشعارات المنصة

CREATE OR REPLACE FUNCTION get_platform_public_settings()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'support_whatsapp', COALESCE(
      (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
      '07733344940'
    ),
    'support_whatsapp_team', COALESCE(
      NULLIF(TRIM((SELECT value FROM app_settings WHERE key = 'global:support_whatsapp_team' LIMIT 1)), ''),
      (SELECT value FROM app_settings WHERE key = 'global:support_whatsapp' LIMIT 1),
      '07733344940'
    ),
    'announcements', COALESCE(
      (SELECT value::jsonb FROM app_settings WHERE key = 'global:platform_announcements' LIMIT 1),
      '[]'::jsonb
    )
  );
$$;

CREATE OR REPLACE FUNCTION get_platform_announcements()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value::jsonb FROM app_settings WHERE key = 'global:platform_announcements' LIMIT 1),
    '[]'::jsonb
  );
$$;

REVOKE ALL ON FUNCTION get_platform_public_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION get_platform_announcements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_platform_public_settings() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_platform_announcements() TO anon, authenticated;

-- END: 021_platform_announcements_anon_read.sql

-- ============================================================
-- BEGIN: 022_employee_schema_and_device_attendance.sql
-- ============================================================

-- ============================================================
-- KYNO 022 — أعمدة الموظف + حضور من الهاتف بدون JWT
-- ============================================================

ALTER TABLE employees ADD COLUMN IF NOT EXISTS open_hours BOOLEAN DEFAULT FALSE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS remote_attend BOOLEAN DEFAULT FALSE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS sal_deleted_period TEXT DEFAULT '';

UPDATE employees SET open_hours = FALSE WHERE open_hours IS NULL;
UPDATE employees SET remote_attend = FALSE WHERE remote_attend IS NULL;
UPDATE employees SET sal_deleted_period = '' WHERE sal_deleted_period IS NULL;

-- حفظ حضور/تحديث إحصائيات الموظف من بوابة الهاتف (anon — بدون JWT)
CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

  IF emp.remote_attend IS TRUE THEN
    dev_ok := TRUE;
  ELSIF fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id
        AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  IF NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso),
    p_date_iso,
    NULLIF(trim(p_check_in), ''),
    NULLIF(trim(p_check_out), ''),
    NULLIF(trim(p_hours), ''),
    NULLIF(trim(p_late), ''),
    NULLIF(trim(p_overtime), ''),
    COALESCE(NULLIF(trim(p_status), ''), 'طبيعي'),
    co_id
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id
  RETURNING id INTO att_id;

  RETURN jsonb_build_object('ok', true, 'attendance_id', att_id, 'employee_id', p_employee_id);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
) TO anon, authenticated;

-- END: 022_employee_schema_and_device_attendance.sql

-- ============================================================
-- BEGIN: 023_departments_delete_rename.sql
-- ============================================================

-- ============================================================
-- KYNO 023 — حذف/إعادة تسمية الأقسام (عزل company_id)
-- ============================================================

CREATE OR REPLACE FUNCTION saas_ensure_department(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  n TEXT := NULLIF(trim(p_name), '');
BEGIN
  IF n IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  IF EXISTS (
    SELECT 1 FROM departments
    WHERE name = n AND company_id = cid
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n, 'company_id', cid);
  END IF;

  INSERT INTO departments (name, company_id) VALUES (n, cid);
  RETURN jsonb_build_object('ok', true, 'created', true, 'name', n, 'company_id', cid);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', true, 'exists', true, 'name', n);
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_department(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  n TEXT := NULLIF(trim(p_name), '');
  used_count INTEGER := 0;
BEGIN
  IF n IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_name');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  SELECT COUNT(*) INTO used_count
  FROM employees e
  WHERE e.dept = n AND e.company_id = cid;

  IF used_count > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'in_use', 'count', used_count);
  END IF;

  DELETE FROM departments
  WHERE name = n AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'deleted', true, 'name', n, 'company_id', cid);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_rename_department(p_old TEXT, p_new TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  old_n TEXT := NULLIF(trim(p_old), '');
  new_n TEXT := NULLIF(trim(p_new), '');
BEGIN
  IF old_n IS NULL OR new_n IS NULL OR old_n = new_n THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_names');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    cid := 1;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM departments WHERE name = old_n AND company_id = cid LIMIT 1
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF EXISTS (
    SELECT 1 FROM departments WHERE name = new_n AND company_id = cid AND name <> old_n LIMIT 1
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate');
  END IF;

  UPDATE departments SET name = new_n
  WHERE name = old_n AND company_id = cid;

  UPDATE employees SET dept = new_n
  WHERE dept = old_n AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'renamed', true, 'from', old_n, 'to', new_n, 'company_id', cid);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_delete_department(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_rename_department(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_department(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION saas_rename_department(TEXT, TEXT) TO authenticated;

-- END: 023_departments_delete_rename.sql

-- ============================================================
-- BEGIN: 024_production_guards.sql
-- ============================================================

-- ============================================================
-- KYNO 024 — Login rate limit + Subscription + Employee limits
-- Additive — لا DROP POLICY — لا تغيير JWT
-- ============================================================

-- ----------------------------------------------------------
-- 1) Login attempts (brute-force protection)
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS login_attempts (
  id          BIGSERIAL PRIMARY KEY,
  username    TEXT NOT NULL DEFAULT '',
  ip_address  TEXT NOT NULL DEFAULT '',
  success     BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_user_time
  ON login_attempts (lower(username), created_at DESC);

CREATE INDEX IF NOT EXISTS idx_login_attempts_ip_time
  ON login_attempts (ip_address, created_at DESC)
  WHERE ip_address <> '';

CREATE OR REPLACE FUNCTION saas_check_login_rate_limit(
  p_username TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uname TEXT := lower(trim(COALESCE(p_username, '')));
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  window_start TIMESTAMPTZ := NOW() - INTERVAL '15 minutes';
  fail_user INTEGER := 0;
  fail_ip INTEGER := 0;
  max_fail INTEGER := 5;
BEGIN
  IF uname = '' THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  SELECT COUNT(*) INTO fail_user
  FROM login_attempts
  WHERE lower(username) = uname
    AND success = false
    AND created_at >= window_start;

  IF fail_user >= max_fail THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'error', 'rate_limited',
      'retry_after_sec', 900,
      'reason', 'username'
    );
  END IF;

  IF ip IS NOT NULL THEN
    SELECT COUNT(*) INTO fail_ip
    FROM login_attempts
    WHERE ip_address = ip
      AND success = false
      AND created_at >= window_start;

    IF fail_ip >= max_fail THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'retry_after_sec', 900,
        'reason', 'ip'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

CREATE OR REPLACE FUNCTION saas_record_login_attempt(
  p_username TEXT,
  p_ip TEXT DEFAULT NULL,
  p_success BOOLEAN DEFAULT false
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO login_attempts (username, ip_address, success)
  VALUES (
    lower(trim(COALESCE(p_username, ''))),
    COALESCE(NULLIF(trim(p_ip), ''), ''),
    COALESCE(p_success, false)
  );
  DELETE FROM login_attempts WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$;

REVOKE ALL ON TABLE login_attempts FROM PUBLIC;
REVOKE ALL ON TABLE login_attempts FROM anon, authenticated;
GRANT ALL ON TABLE login_attempts TO service_role;

REVOKE ALL ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_record_login_attempt(TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION saas_record_login_attempt(TEXT, TEXT, BOOLEAN) TO service_role;

-- ----------------------------------------------------------
-- 2) Subscription active check (server-side)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_assert_company_active(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_suspended');
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
  END IF;

  IF sub.status IN ('suspended', 'expired', 'pending') OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'status', sub.status
    );
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ----------------------------------------------------------
-- 3) Employee limit check (server-side)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_assert_employee_limit(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lim INTEGER := 0;
  cnt INTEGER := 0;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT COALESCE(max_employees, 0) INTO lim FROM companies WHERE id = p_company_id LIMIT 1;
  IF lim IS NULL OR lim <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'unlimited', true);
  END IF;

  SELECT COUNT(*) INTO cnt FROM employees WHERE company_id = p_company_id;

  IF cnt >= lim THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'employee_limit_reached',
      'limit', lim,
      'count', cnt
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'limit', lim, 'count', cnt);
END;
$$;

-- ----------------------------------------------------------
-- 4) Triggers — employees + salary_records INSERT
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_guard_employees_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  chk JSONB;
  cid INTEGER;
BEGIN
  cid := NEW.company_id;
  IF cid IS NULL OR cid <= 0 THEN
    RAISE EXCEPTION 'company_id_required' USING ERRCODE = '23514';
  END IF;

  chk := saas_assert_company_active(cid);
  IF COALESCE((chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'subscription_inactive:%', COALESCE(chk->>'error', 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  chk := saas_assert_employee_limit(cid);
  IF COALESCE((chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'employee_limit_reached:%', COALESCE(chk->>'error', 'limit')
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_guard_salary_records_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  chk JSONB;
  cid INTEGER;
BEGIN
  cid := NEW.company_id;
  IF cid IS NULL OR cid <= 0 THEN
    SELECT e.company_id INTO cid FROM employees e WHERE e.id = NEW.employee_id LIMIT 1;
    IF cid IS NOT NULL THEN
      NEW.company_id := cid;
    END IF;
  END IF;

  IF NEW.company_id IS NULL OR NEW.company_id <= 0 THEN
    RAISE EXCEPTION 'company_id_required' USING ERRCODE = '23514';
  END IF;

  chk := saas_assert_company_active(NEW.company_id);
  IF COALESCE((chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'subscription_inactive:%', COALESCE(chk->>'error', 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS employees_production_guard_insert ON employees;
CREATE TRIGGER employees_production_guard_insert
  BEFORE INSERT ON employees
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_employees_insert();

DROP TRIGGER IF EXISTS salary_records_production_guard_insert ON salary_records;
CREATE TRIGGER salary_records_production_guard_insert
  BEFORE INSERT ON salary_records
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_salary_records_insert();

-- ----------------------------------------------------------
-- 5) saas_verify_login — rate limit + optional IP (backward compatible)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_verify_login(
  p_username TEXT,
  p_password TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
  uname TEXT := lower(trim(p_username));
  rate JSONB;
BEGIN
  IF uname IS NULL OR length(uname) < 2 OR p_password IS NULL THEN
    RETURN NULL;
  END IF;

  rate := saas_check_login_rate_limit(uname, p_ip);
  IF COALESCE((rate->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate->>'retry_after_sec')::integer, 900)
    );
  END IF;

  SELECT su.*, c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE lower(su.username) = uname AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM saas_record_login_attempt(uname, p_ip, false);
    RETURN NULL;
  END IF;

  legacy_hash := encode(convert_to(p_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR u.password_hash = '' THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
    IF extensions.crypt(p_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    PERFORM saas_record_login_attempt(uname, p_ip, false);
    RETURN NULL;
  END IF;

  PERFORM saas_record_login_attempt(uname, p_ip, true);
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

DROP FUNCTION IF EXISTS saas_verify_login(TEXT, TEXT);
REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------
-- 6) saas_upsert_company_user — subscription guard
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
  active_chk JSONB;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', uname,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', cid,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

GRANT EXECUTE ON FUNCTION saas_assert_company_active(INTEGER) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION saas_assert_employee_limit(INTEGER) TO authenticated, service_role;

-- END: 024_production_guards.sql

-- ============================================================
-- BEGIN: 025_server_attendance_time.sql
-- ============================================================

-- ============================================================
-- KYNO 025 — Server-authoritative attendance punch (device portal)
-- Additive — يحافظ على الوضع القديم عند p_punch_type IS NULL
-- ============================================================

CREATE OR REPLACE FUNCTION basma_server_now_baghdad()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  SELECT timezone('Asia/Baghdad', now());
$$;

CREATE OR REPLACE FUNCTION basma_date_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
  SELECT (timezone('Asia/Baghdad', now()))::date;
$$;

CREATE OR REPLACE FUNCTION basma_format_time_ampm(ts TIMESTAMPTZ)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(ts AT TIME ZONE 'Asia/Baghdad', 'HH12:MI AM');
$$;

CREATE OR REPLACE FUNCTION basma_time_text_to_minutes(t TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT := upper(trim(COALESCE(t, '')));
  m INTEGER := 0;
  h INTEGER := 0;
  ap TEXT;
BEGIN
  IF s = '' OR s = '—' THEN RETURN 0; END IF;
  IF s ~ '^\d{1,2}:\d{2}\s*(AM|PM)$' THEN
    h := substring(s from '^(\d{1,2})')::integer;
    m := substring(s from ':(\d{2})')::integer;
    ap := substring(s from '(AM|PM)$');
    IF ap = 'PM' AND h <> 12 THEN h := h + 12; END IF;
    IF ap = 'AM' AND h = 12 THEN h := 0; END IF;
    RETURN h * 60 + m;
  END IF;
  IF s ~ '^\d{1,2}:\d{2}$' THEN
    h := split_part(s, ':', 1)::integer;
    m := split_part(s, ':', 2)::integer;
    RETURN h * 60 + m;
  END IF;
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION basma_db_time_to_minutes(t TIME)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN t IS NULL THEN 0 ELSE (EXTRACT(HOUR FROM t)::integer * 60 + EXTRACT(MINUTE FROM t)::integer) END;
$$;

CREATE OR REPLACE FUNCTION basma_minutes_to_hours_str(total_min INTEGER)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN total_min IS NULL OR total_min <= 0 THEN '0س 0د'
    ELSE ((total_min / 60)::text || 'س ' || (total_min % 60)::text || 'د')
  END;
$$;

CREATE OR REPLACE FUNCTION basma_arabic_date_label(d DATE)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  days TEXT[] := ARRAY['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
  months TEXT[] := ARRAY['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
BEGIN
  IF d IS NULL THEN RETURN ''; END IF;
  RETURN days[EXTRACT(DOW FROM d)::integer + 1] || ' ' || EXTRACT(DAY FROM d)::integer || ' ' || months[EXTRACT(MONTH FROM d)::integer];
END;
$$;

DROP FUNCTION IF EXISTS saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER
);

CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL,
  p_punch_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
  active_chk JSONB;
  punch TEXT := lower(NULLIF(trim(p_punch_type), ''));
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  srv_co TEXT;
  srv_late TEXT := '—';
  srv_status TEXT := 'طبيعي';
  srv_hours TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  use_hours TEXT;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  existing RECORD;
  att_row attendance%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF emp.remote_attend IS TRUE THEN
    dev_ok := TRUE;
  ELSIF fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id
        AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();
  srv_ci := basma_format_time_ampm(srv_ts);

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_ci := srv_ci;
    use_co := NULL;
    use_hours := NULL;
    use_ot := '—';

    IF emp.open_hours IS TRUE THEN
      use_late := '—';
      use_status := 'طبيعي';
    ELSE
      actual_min := basma_time_text_to_minutes(srv_ci);
      official_min := basma_db_time_to_minutes(emp.check_in);
      late_min := GREATEST(0, actual_min - official_min);
      late_threshold := 15;
      IF late_min > late_threshold THEN
        use_status := 'متأخر';
        use_late := late_min || 'د';
      ELSIF late_min > 0 THEN
        use_status := 'طبيعي';
        use_late := late_min || 'د';
      ELSE
        use_status := 'طبيعي';
        use_late := '—';
      END IF;
    END IF;

  ELSIF punch = 'check_out' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_co := basma_format_time_ampm(srv_ts);

    SELECT a.check_in, a.date_iso INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
    ELSE
      use_ci := srv_ci;
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      use_late := COALESCE(NULLIF(trim(p_late), ''), '—');
      use_ot := COALESCE(NULLIF(trim(p_overtime), ''), '—');
      use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
    END IF;

  ELSE
    -- Legacy: accept client-supplied values (admin sync / backward compat)
    IF p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
      IF NULLIF(trim(p_check_in), '') IS NULL
         AND NULLIF(trim(p_check_out), '') IS NULL
         AND NULLIF(trim(p_hours), '') IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    use_date_iso := p_date_iso::date;
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso);
    use_ci := NULLIF(trim(p_check_in), '');
    use_co := NULLIF(trim(p_check_out), '');
    use_hours := NULLIF(trim(p_hours), '');
    use_late := NULLIF(trim(p_late), '');
    use_ot := NULLIF(trim(p_overtime), '');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IS NULL
     AND NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    use_date_label,
    use_date_iso,
    use_ci,
    use_co,
    use_hours,
    use_late,
    use_ot,
    use_status,
    co_id
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id,
    updated_at = NOW()
  RETURNING * INTO att_row;

  att_id := att_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'attendance_id', att_id,
    'employee_id', p_employee_id,
    'check_in', COALESCE(att_row.check_in, '—'),
    'check_out', COALESCE(att_row.check_out, '—'),
    'date_iso', att_row.date_iso,
    'date_label', att_row.date_label,
    'hours', COALESCE(att_row.hours, '—'),
    'late', COALESCE(att_row.late, '—'),
    'overtime', COALESCE(att_row.overtime, '—'),
    'status', COALESCE(att_row.status, 'طبيعي'),
    'server_authoritative', punch IN ('check_in', 'check_out')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_by_device(
  INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT
) TO anon, authenticated;

-- END: 025_server_attendance_time.sql

-- ============================================================
-- BEGIN: 026_seed_credentials_hardening.sql
-- ============================================================

-- ============================================================
-- KYNO 026 — Seed credentials hardening (C6)
-- لا حذف مستخدمين — وسم + إرشادات تدوير
-- ============================================================

ALTER TABLE saas_users
  ADD COLUMN IF NOT EXISTS force_password_reset BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN saas_users.force_password_reset IS
  'true = يجب تغيير كلمة المرور عند أول دخول (مستخدمي seed القديم)';

-- وسم حسابات seed ذات كلمات مرور ضعيفة/legacy
UPDATE saas_users
SET force_password_reset = true
WHERE lower(username) IN ('superadmin', 'admin')
  AND (
    password_algo IS NULL
    OR password_algo = 'legacy_b64'
    OR password_hash = 'U3VwZXJBZG1pbjIwMjY='
    OR password_hash = 'MTIzNA=='
  );

-- إرجاع force_password_reset في login
CREATE OR REPLACE FUNCTION saas_verify_login(
  p_username TEXT,
  p_password TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
  uname TEXT := lower(trim(p_username));
  rate JSONB;
BEGIN
  IF uname IS NULL OR length(uname) < 2 OR p_password IS NULL THEN
    RETURN NULL;
  END IF;

  rate := saas_check_login_rate_limit(uname, p_ip);
  IF COALESCE((rate->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate->>'retry_after_sec')::integer, 900)
    );
  END IF;

  SELECT su.*, c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE lower(su.username) = uname AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM saas_record_login_attempt(uname, p_ip, false);
    RETURN NULL;
  END IF;

  legacy_hash := encode(convert_to(p_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR u.password_hash = '' THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
    IF extensions.crypt(p_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    PERFORM saas_record_login_attempt(uname, p_ip, false);
    RETURN NULL;
  END IF;

  PERFORM saas_record_login_attempt(uname, p_ip, true);
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
    'max_employees', COALESCE(u.max_employees, 0),
    'force_password_reset', COALESCE(u.force_password_reset, false)
  );
END;
$$;

DROP FUNCTION IF EXISTS saas_verify_login(TEXT, TEXT);
REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) TO anon, authenticated;

-- دالة مراقبة — لا تغيّر بيانات
CREATE OR REPLACE FUNCTION saas_count_legacy_seed_users()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer FROM saas_users
  WHERE lower(username) IN ('superadmin', 'admin')
    AND (
      password_algo IS NULL OR password_algo = 'legacy_b64'
      OR password_hash IN ('U3VwZXJBZG1pbjIwMjY=', 'MTIzNA==')
    );
$$;

REVOKE ALL ON FUNCTION saas_count_legacy_seed_users() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_count_legacy_seed_users() TO service_role;

-- END: 026_seed_credentials_hardening.sql

-- ============================================================
-- BEGIN: 027_production_final.sql
-- ============================================================

-- ============================================================
-- KYNO 027 — Production Final Hardening
-- Additive — no DROP POLICY — backward compatible legacy paths
-- ============================================================

-- ----------------------------------------------------------
-- 1) Generic API rate limiting (attendance + device link)
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_rate_attempts (
  id          BIGSERIAL PRIMARY KEY,
  scope       TEXT NOT NULL,
  rate_key    TEXT NOT NULL DEFAULT '',
  ip_address  TEXT NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_api_rate_scope_key_time
  ON api_rate_attempts (scope, rate_key, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_rate_scope_ip_time
  ON api_rate_attempts (scope, ip_address, created_at DESC)
  WHERE ip_address <> '';

CREATE OR REPLACE FUNCTION saas_check_api_rate_limit(
  p_scope TEXT,
  p_rate_key TEXT,
  p_ip TEXT DEFAULT NULL,
  p_max INTEGER DEFAULT 60,
  p_window_sec INTEGER DEFAULT 1800
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sc TEXT := lower(trim(COALESCE(p_scope, '')));
  rk TEXT := trim(COALESCE(p_rate_key, ''));
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  window_start TIMESTAMPTZ := NOW() - make_interval(secs => GREATEST(p_window_sec, 60));
  cnt_key INTEGER := 0;
  cnt_ip INTEGER := 0;
BEGIN
  IF sc = '' THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  IF rk <> '' THEN
    SELECT COUNT(*) INTO cnt_key
    FROM api_rate_attempts
    WHERE scope = sc AND rate_key = rk AND created_at >= window_start;
    IF cnt_key >= p_max THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'reason', 'key',
        'retry_after_sec', p_window_sec
      );
    END IF;
  END IF;

  IF ip IS NOT NULL THEN
    SELECT COUNT(*) INTO cnt_ip
    FROM api_rate_attempts
    WHERE scope = sc AND ip_address = ip AND created_at >= window_start;
    IF cnt_ip >= p_max THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'reason', 'ip',
        'retry_after_sec', p_window_sec
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

CREATE OR REPLACE FUNCTION saas_record_api_attempt(
  p_scope TEXT,
  p_rate_key TEXT DEFAULT '',
  p_ip TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO api_rate_attempts (scope, rate_key, ip_address)
  VALUES (
    lower(trim(COALESCE(p_scope, ''))),
    trim(COALESCE(p_rate_key, '')),
    COALESCE(NULLIF(trim(p_ip), ''), '')
  );
  DELETE FROM api_rate_attempts WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$;

REVOKE ALL ON TABLE api_rate_attempts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE api_rate_attempts TO service_role;
REVOKE ALL ON FUNCTION saas_check_api_rate_limit(TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_record_api_attempt(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_check_api_rate_limit(TEXT, TEXT, TEXT, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION saas_record_api_attempt(TEXT, TEXT, TEXT) TO service_role;

-- ----------------------------------------------------------
-- 2) force_password_reset — block login + self-reset RPC
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_force_reset_password(
  p_username TEXT,
  p_current_password TEXT,
  p_new_password TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
  uname TEXT := lower(trim(p_username));
  new_hash TEXT;
BEGIN
  IF uname IS NULL OR length(uname) < 2
     OR p_current_password IS NULL OR p_new_password IS NULL
     OR length(trim(p_new_password)) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT * INTO u FROM saas_users WHERE lower(username) = uname AND is_active = true LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  END IF;
  IF COALESCE(u.force_password_reset, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reset_not_required');
  END IF;

  legacy_hash := encode(convert_to(p_current_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR extensions.crypt(p_current_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_current_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  END IF;

  new_hash := saas_hash_password_bcrypt(trim(p_new_password));
  IF new_hash IS NULL OR new_hash = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
  END IF;

  UPDATE saas_users
  SET password_hash = new_hash,
      password_algo = 'bcrypt',
      force_password_reset = false
  WHERE id = u.id;

  RETURN jsonb_build_object('ok', true, 'username', u.username);
END;
$$;

REVOKE ALL ON FUNCTION saas_force_reset_password(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_force_reset_password(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION saas_verify_login(
  p_username TEXT,
  p_password TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  u RECORD;
  legacy_hash TEXT;
  uname TEXT := lower(trim(p_username));
  rate JSONB;
BEGIN
  IF uname IS NULL OR length(uname) < 2 OR p_password IS NULL THEN
    RETURN NULL;
  END IF;

  rate := saas_check_login_rate_limit(uname, p_ip);
  IF COALESCE((rate->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate->>'retry_after_sec')::integer, 900)
    );
  END IF;

  SELECT su.*, c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE lower(su.username) = uname AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM saas_record_login_attempt(uname, p_ip, false);
    RETURN NULL;
  END IF;

  legacy_hash := encode(convert_to(p_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR u.password_hash = '' THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
    IF extensions.crypt(p_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      PERFORM saas_record_login_attempt(uname, p_ip, false);
      RETURN NULL;
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    PERFORM saas_record_login_attempt(uname, p_ip, false);
    RETURN NULL;
  END IF;

  IF COALESCE(u.force_password_reset, false) IS TRUE THEN
    RETURN jsonb_build_object(
      'error', 'password_reset_required',
      'username', u.username,
      'id', u.id,
      'role', u.role
    );
  END IF;

  PERFORM saas_record_login_attempt(uname, p_ip, true);
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
    'max_employees', COALESCE(u.max_employees, 0),
    'force_password_reset', false
  );
END;
$$;

DROP FUNCTION IF EXISTS saas_verify_login(TEXT, TEXT);
REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------
-- 3) Attendance RPC — rate limit + server checkout OT/status
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL,
  p_punch_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
  active_chk JSONB;
  rate_chk JSONB;
  punch TEXT := lower(NULLIF(trim(p_punch_type), ''));
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  use_hours TEXT;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  official_co_min INTEGER;
  ot_min INTEGER;
  existing RECORD;
  att_row attendance%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF punch IN ('check_in', 'check_out') THEN
    rate_chk := saas_check_api_rate_limit(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'remote'),
      NULL,
      120,
      3600
    );
    IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'rate_limited',
        'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 3600)
      );
    END IF;
    PERFORM saas_record_api_attempt(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'remote'),
      NULL
    );
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF emp.remote_attend IS TRUE THEN
    dev_ok := TRUE;
  ELSIF fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();
  srv_ci := basma_format_time_ampm(srv_ts);

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_ci := srv_ci;
    use_co := NULL;
    use_hours := NULL;
    use_ot := '—';

    IF emp.open_hours IS TRUE THEN
      use_late := '—';
      use_status := 'طبيعي';
    ELSE
      actual_min := basma_time_text_to_minutes(srv_ci);
      official_min := basma_db_time_to_minutes(emp.check_in);
      late_min := GREATEST(0, actual_min - official_min);
      IF late_min > late_threshold THEN
        use_status := 'متأخر';
        use_late := late_min || 'د';
      ELSIF late_min > 0 THEN
        use_status := 'طبيعي';
        use_late := late_min || 'د';
      ELSE
        use_status := 'طبيعي';
        use_late := '—';
      END IF;
    END IF;

  ELSIF punch = 'check_out' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_co := basma_format_time_ampm(srv_ts);

    SELECT a.check_in, a.late, a.status INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
      use_late := COALESCE(NULLIF(trim(existing.late), ''), '—');
      use_status := COALESCE(NULLIF(trim(existing.status), ''), 'طبيعي');
    ELSE
      use_ci := srv_ci;
      use_late := '—';
      use_status := 'طبيعي';
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      official_co_min := basma_db_time_to_minutes(emp.check_out);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      ot_min := GREATEST(0, co_min - official_co_min);
      IF ot_min > 0 THEN
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN
          use_status := 'إضافي';
        END IF;
      ELSE
        use_ot := '—';
      END IF;
    END IF;

  ELSE
    IF p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
      IF NULLIF(trim(p_check_in), '') IS NULL
         AND NULLIF(trim(p_check_out), '') IS NULL
         AND NULLIF(trim(p_hours), '') IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    use_date_iso := p_date_iso::date;
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso);
    use_ci := NULLIF(trim(p_check_in), '');
    use_co := NULLIF(trim(p_check_out), '');
    use_hours := NULLIF(trim(p_hours), '');
    use_late := NULLIF(trim(p_late), '');
    use_ot := NULLIF(trim(p_overtime), '');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IS NULL
     AND NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    use_date_label,
    use_date_iso,
    use_ci,
    use_co,
    use_hours,
    use_late,
    use_ot,
    use_status,
    co_id
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id,
    updated_at = NOW()
  RETURNING * INTO att_row;

  att_id := att_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'attendance_id', att_id,
    'employee_id', p_employee_id,
    'check_in', COALESCE(att_row.check_in, '—'),
    'check_out', COALESCE(att_row.check_out, '—'),
    'date_iso', att_row.date_iso,
    'date_label', att_row.date_label,
    'hours', COALESCE(att_row.hours, '—'),
    'late', COALESCE(att_row.late, '—'),
    'overtime', COALESCE(att_row.overtime, '—'),
    'status', COALESCE(att_row.status, 'طبيعي'),
    'server_authoritative', punch IN ('check_in', 'check_out')
  );
END;
$$;

-- ----------------------------------------------------------
-- 4) Device linking — rate limit + subscription guard
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_link_device_by_token(
  p_token TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  now_ts TIMESTAMPTZ := NOW();
  tok TEXT := NULLIF(trim(p_token), '');
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  rate_chk JSONB;
  active_chk JSONB;
  co_id INTEGER;
BEGIN
  IF fp IS NULL OR length(fp) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  rate_chk := saas_check_api_rate_limit('device_link', fp, ip, 10, 900);
  IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 900)
    );
  END IF;
  PERFORM saas_record_api_attempt('device_link', fp, ip);

  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  co_id := d.emp_company_id;
  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> fp THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = fp,
    ip = COALESCE(ip, employee_devices.ip),
    device_info = COALESCE(p_device_info, device_info, '{}'::jsonb),
    linked_at = COALESCE(linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'fingerprint', fp,
    'ip', COALESCE(ip, d.ip, '')
  );
END;
$$;

-- ----------------------------------------------------------
-- 5) Attendance write guard (direct upsert path)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_guard_attendance_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  chk JSONB;
  cid INTEGER;
BEGIN
  cid := NEW.company_id;
  IF cid IS NULL OR cid <= 0 THEN
    SELECT e.company_id INTO cid FROM employees e WHERE e.id = NEW.employee_id LIMIT 1;
    IF cid IS NOT NULL THEN
      NEW.company_id := cid;
    END IF;
  END IF;

  IF NEW.company_id IS NULL OR NEW.company_id <= 0 THEN
    RAISE EXCEPTION 'company_id_required' USING ERRCODE = '23514';
  END IF;

  chk := saas_assert_company_active(NEW.company_id);
  IF COALESCE((chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'subscription_inactive:%', COALESCE(chk->>'error', 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS attendance_production_guard_insert ON attendance;
CREATE TRIGGER attendance_production_guard_insert
  BEFORE INSERT ON attendance
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_attendance_write();

DROP TRIGGER IF EXISTS attendance_production_guard_update ON attendance;
CREATE TRIGGER attendance_production_guard_update
  BEFORE UPDATE ON attendance
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_attendance_write();

-- Salary UPDATE guard
CREATE OR REPLACE FUNCTION trg_guard_salary_records_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  chk JSONB;
  cid INTEGER;
BEGIN
  cid := NEW.company_id;
  IF cid IS NULL OR cid <= 0 THEN
    SELECT e.company_id INTO cid FROM employees e WHERE e.id = NEW.employee_id LIMIT 1;
    IF cid IS NOT NULL THEN
      NEW.company_id := cid;
    END IF;
  END IF;

  IF NEW.company_id IS NULL OR NEW.company_id <= 0 THEN
    RAISE EXCEPTION 'company_id_required' USING ERRCODE = '23514';
  END IF;

  chk := saas_assert_company_active(NEW.company_id);
  IF COALESCE((chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'subscription_inactive:%', COALESCE(chk->>'error', 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS salary_records_production_guard_update ON salary_records;
CREATE TRIGGER salary_records_production_guard_update
  BEFORE UPDATE ON salary_records
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_salary_records_write();

-- ----------------------------------------------------------
-- 6) Database integrity constraints
-- ----------------------------------------------------------
UPDATE employees SET company_id = 1 WHERE company_id IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'employees_company_id_not_null'
  ) THEN
    ALTER TABLE employees ALTER COLUMN company_id SET NOT NULL;
  END IF;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'employees.company_id NOT NULL skipped: %', SQLERRM;
END $$;

-- departments: global UNIQUE(name) incompatible with multi-tenant.
-- employees.dept FK references departments(name) — must drop FK first.
ALTER TABLE employees DROP CONSTRAINT IF EXISTS employees_dept_fkey;

ALTER TABLE departments DROP CONSTRAINT IF EXISTS departments_name_key;

CREATE UNIQUE INDEX IF NOT EXISTS ux_departments_company_name
  ON departments (company_id, lower(trim(name)));

COMMENT ON INDEX ux_departments_company_name IS
  'Multi-tenant dept names — replaces global departments_name_key + employees_dept_fkey';

CREATE UNIQUE INDEX IF NOT EXISTS ux_salary_employee_month
  ON salary_records (employee_id, month_iso);

-- Baghdad today helper (optional read-only for clients)
CREATE OR REPLACE FUNCTION basma_today_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT basma_date_iso_baghdad();
$$;

REVOKE ALL ON FUNCTION basma_today_iso_baghdad() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION basma_today_iso_baghdad() TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;

-- END: 027_production_final.sql

-- ============================================================
-- BEGIN: 028_departments_unique_fix.sql
-- ============================================================

-- ============================================================
-- KYNO 028 — Fix departments composite unique (post-027 partial run)
-- Run this if 027 failed at: DROP CONSTRAINT departments_name_key
-- Safe to re-run (idempotent)
-- ============================================================

-- Step 1: remove legacy FK (depends on global UNIQUE on departments.name)
ALTER TABLE employees DROP CONSTRAINT IF EXISTS employees_dept_fkey;

-- Step 2: remove global unique — allows same dept name per company
ALTER TABLE departments DROP CONSTRAINT IF EXISTS departments_name_key;

-- Step 3: multi-tenant unique per company
CREATE UNIQUE INDEX IF NOT EXISTS ux_departments_company_name
  ON departments (company_id, lower(trim(name)));

COMMENT ON INDEX ux_departments_company_name IS
  'Multi-tenant dept names — replaces departments_name_key + employees_dept_fkey';

-- Step 4: salary unique (if 027 stopped before this)
CREATE UNIQUE INDEX IF NOT EXISTS ux_salary_employee_month
  ON salary_records (employee_id, month_iso);

-- Step 5: optional helpers (if 027 stopped before end)
CREATE OR REPLACE FUNCTION basma_today_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT basma_date_iso_baghdad();
$$;

REVOKE ALL ON FUNCTION basma_today_iso_baghdad() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION basma_today_iso_baghdad() TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;

-- END: 028_departments_unique_fix.sql

-- ============================================================
-- BEGIN: 029_rls_tenant_isolation_final.sql
-- ============================================================

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

-- END: 029_rls_tenant_isolation_final.sql

-- ============================================================
-- BEGIN: 030_enterprise_rls_cleanup.sql
-- ============================================================

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

-- END: 030_enterprise_rls_cleanup.sql

-- ============================================================
-- BEGIN: 031_enterprise_v3_core.sql
-- ============================================================

-- ============================================================
-- KYNO 031 — Enterprise Hardening v3 (Core RPC Layer)
-- Additive — لا تغيير RLS 029/030
-- Server-authoritative payroll, attendance admin, employees
-- ============================================================

-- ----------------------------------------------------------
-- 0) Fix audit RPC — no company_id = 1 fallback
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_insert_audit_log(
  p_action TEXT,
  p_category TEXT DEFAULT NULL,
  p_details TEXT DEFAULT NULL,
  p_target_name TEXT DEFAULT NULL,
  p_actor_id INTEGER DEFAULT NULL,
  p_actor_name TEXT DEFAULT NULL,
  p_actor_role TEXT DEFAULT NULL,
  p_meta JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  IF (cid IS NULL OR cid <= 0) AND auth_is_super_admin() THEN
    cid := NULLIF((p_meta->>'company_id')::INTEGER, 0);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta
  ) VALUES (
    cid,
    p_actor_id,
    NULLIF(trim(p_actor_name), ''),
    NULLIF(trim(p_actor_role), ''),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    COALESCE(p_meta, '{}'::jsonb)
  );

  RETURN jsonb_build_object('ok', true);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ----------------------------------------------------------
-- 1) Internal helpers
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_assert_tenant(p_row_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
BEGIN
  IF auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', true, 'super_admin', true);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  IF p_row_company_id IS NULL OR p_row_company_id <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
  END IF;
  RETURN jsonb_build_object('ok', true, 'company_id', cid);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_company_setting(p_company_id INTEGER, p_key TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.value
  FROM app_settings s
  WHERE s.key = ('company:' || p_company_id::text || ':' || p_key)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
BEGIN
  meta := jsonb_build_object(
    'company_id', p_company_id,
    'timestamp', to_jsonb(NOW()),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );
  PERFORM saas_insert_audit_log(
    p_action,
    p_category,
    p_details,
    p_target_name,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    meta
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_parse_late_minutes(p_late TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT := trim(COALESCE(p_late, ''));
  n INTEGER;
BEGIN
  IF s = '' OR s = '—' THEN RETURN 0; END IF;
  n := NULLIF(regexp_replace(s, '[^0-9]', '', 'g'), '')::INTEGER;
  RETURN COALESCE(n, 0);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_parse_ot_minutes(p_ot TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT := trim(COALESCE(p_ot, ''));
  h INTEGER := 0;
  m INTEGER := 0;
  hm TEXT[];
BEGIN
  IF s = '' OR s = '—' THEN RETURN 0; END IF;
  IF s ~ '(\d+)\s*س' THEN
    h := (regexp_match(s, '(\d+)\s*س'))[1]::INTEGER;
  END IF;
  IF s ~ '(\d+)\s*د' THEN
    m := (regexp_match(s, '(\d+)\s*د'))[1]::INTEGER;
  END IF;
  IF h = 0 AND m = 0 THEN
    m := NULLIF(regexp_replace(s, '[^0-9]', '', 'g'), '')::INTEGER;
    m := COALESCE(m, 0);
  END IF;
  RETURN h * 60 + m;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_period_bounds(
  p_month TEXT,
  p_salary_type TEXT DEFAULT 'monthly'
)
RETURNS TABLE(
  period_start DATE,
  period_end DATE,
  elapsed_days INTEGER,
  total_days INTEGER,
  month_iso TEXT,
  month_label TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  y INTEGER;
  mo INTEGER;
  half TEXT;
  today DATE := basma_date_iso_baghdad();
  ms TEXT[] := ARRAY['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
  mkey TEXT := COALESCE(NULLIF(trim(p_month), ''), to_char(today, 'YYYY-MM'));
  stype TEXT := COALESCE(NULLIF(trim(p_salary_type), ''), 'monthly');
BEGIN
  IF mkey ~ '-H[12]$' THEN
    y := split_part(split_part(mkey, '-H', 1), '-', 1)::INTEGER;
    mo := split_part(split_part(mkey, '-H', 1), '-', 2)::INTEGER;
    half := substring(mkey from '-H([12])$');
    IF half = '1' THEN
      period_start := make_date(y, mo, 1);
      period_end := make_date(y, mo, 15);
      total_days := 15;
    ELSE
      period_start := make_date(y, mo, 16);
      period_end := (date_trunc('month', make_date(y, mo, 1)) + INTERVAL '1 month - 1 day')::DATE;
      total_days := EXTRACT(DAY FROM period_end)::INTEGER - 15;
    END IF;
    month_iso := mkey;
    month_label := ms[mo] || ' ' || y::TEXT || ' (' || CASE WHEN half = '1' THEN 'النصف الأول' ELSE 'النصف الثاني' END || ')';
  ELSE
    y := split_part(mkey, '-', 1)::INTEGER;
    mo := split_part(mkey, '-', 2)::INTEGER;
    period_start := make_date(y, mo, 1);
    period_end := (date_trunc('month', period_start) + INTERVAL '1 month - 1 day')::DATE;
    total_days := EXTRACT(DAY FROM period_end)::INTEGER;
    month_iso := to_char(period_start, 'YYYY-MM');
    month_label := ms[mo] || ' ' || y::TEXT;
  END IF;

  IF today < period_start THEN
    elapsed_days := 0;
  ELSIF today > period_end THEN
    elapsed_days := total_days;
  ELSE
    elapsed_days := GREATEST(1, (today - period_start)::INTEGER + 1);
    IF stype = 'biweekly' AND mkey ~ '-H[12]$' THEN
      IF substring(mkey from '-H([12])$') = '1' THEN
        elapsed_days := LEAST(elapsed_days, 15);
      ELSE
        elapsed_days := LEAST(GREATEST(1, EXTRACT(DAY FROM today)::INTEGER - 15), total_days);
      END IF;
    END IF;
  END IF;

  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_finance_totals(
  p_company_id INTEGER,
  p_employee_id INTEGER,
  p_period_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  raw TEXT;
  arr JSONB;
  item JSONB;
  deductions INTEGER := 0;
  bonuses INTEGER := 0;
  loans INTEGER := 0;
  amt INTEGER;
  status TEXT;
  iperiod TEXT;
BEGIN
  raw := saas_v3_company_setting(p_company_id, 'finance_items');
  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0);
  END IF;
  BEGIN
    arr := raw::JSONB;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0);
  END;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0);
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(arr)
  LOOP
    IF COALESCE((item->>'empId')::INTEGER, (item->>'emp_id')::INTEGER, 0) <> p_employee_id THEN
      CONTINUE;
    END IF;
    status := COALESCE(item->>'status', '');
    IF status IN ('ملغي', 'مسدد') THEN CONTINUE; END IF;
    iperiod := COALESCE(item->>'period', '');
    amt := GREATEST(0, COALESCE((item->>'amount')::INTEGER, 0));
    IF COALESCE(item->>'type', '') = 'bonus' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        bonuses := bonuses + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'deduction' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        deductions := deductions + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'loan' THEN
      IF COALESCE(item->>'loanMode', item->>'loan_mode', '') = 'installments' THEN
        loans := loans + GREATEST(0, amt / GREATEST(1, COALESCE((item->>'installmentCount')::INTEGER, (item->>'installment_count')::INTEGER, 1)));
      ELSE
        loans := loans + amt;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('deductions', deductions, 'bonuses', bonuses, 'loans', loans);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  bounds RECORD;
  att RECORD;
  attend_days INTEGER := 0;
  recorded_absent INTEGER := 0;
  total_late_min INTEGER := 0;
  total_ot_min INTEGER := 0;
  expected_absent INTEGER := 0;
  absent_days INTEGER := 0;
  is_comm BOOLEAN;
  is_biw BOOLEAN;
  base_period_salary INTEGER;
  daily_rate INTEGER;
  base_salary INTEGER := 0;
  late_deduct_rate INTEGER;
  ot_hourly INTEGER;
  late_deduct INTEGER := 0;
  absent_deduct INTEGER := 0;
  ot_amount INTEGER := 0;
  bonus INTEGER := 0;
  fin JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT * INTO bounds FROM saas_v3_period_bounds(
    COALESCE(p_month, CASE WHEN emp.salary_type = 'biweekly' THEN
      to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
      CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
    ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END),
    COALESCE(emp.salary_type, 'monthly')
  );

  is_comm := COALESCE(emp.salary_type, 'monthly') = 'commission';
  is_biw := COALESCE(emp.salary_type, 'monthly') = 'biweekly';
  base_period_salary := CASE
    WHEN is_comm THEN 0
    WHEN is_biw THEN GREATEST(0, COALESCE(NULLIF(emp.salary_half, 0), emp.salary / 2))
    ELSE GREATEST(0, COALESCE(emp.salary, 0))
  END;
  daily_rate := CASE
    WHEN is_comm THEN 0
    WHEN COALESCE(emp.daily_rate, 0) > 0 THEN emp.daily_rate
    WHEN is_biw THEN GREATEST(0, base_period_salary / 15)
    ELSE GREATEST(0, base_period_salary / 30)
  END;

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= bounds.period_end
  LOOP
    IF att.check_in IS NOT NULL AND att.check_in <> '—' THEN
      attend_days := attend_days + 1;
      IF NOT is_comm AND emp.open_hours IS NOT TRUE THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        IF att.late IS NOT NULL AND att.late <> '—' THEN
          total_late_min := total_late_min + saas_v3_parse_late_minutes(att.late);
        END IF;
      END IF;
    ELSIF att.status = 'غياب' THEN
      recorded_absent := recorded_absent + 1;
    END IF;
  END LOOP;

  IF is_comm OR emp.open_hours IS TRUE THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(0, bounds.elapsed_days - attend_days - recorded_absent);
  END IF;
  absent_days := recorded_absent + expected_absent;

  IF is_comm THEN
    base_salary := 0;
  ELSE
    base_salary := base_period_salary;
  END IF;

  late_deduct_rate := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'late_deduct_rate'), '')::INTEGER, 700));
  ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));

  IF is_comm OR emp.open_hours IS TRUE THEN
    late_deduct := 0;
    absent_deduct := 0;
    ot_amount := 0;
  ELSE
    late_deduct := ROUND(total_late_min * late_deduct_rate);
    absent_deduct := ROUND(absent_days * daily_rate);
    ot_amount := ROUND((total_ot_min / 60.0) * ot_hourly);
  END IF;

  fin := saas_v3_finance_totals(emp.company_id, p_employee_id, bounds.month_iso);
  manual_deduct := COALESCE((fin->>'deductions')::INTEGER, 0);
  loan_deduct := COALESCE((fin->>'loans')::INTEGER, 0);
  bonus := GREATEST(0, COALESCE(emp.sal_bonus, 0)) + COALESCE((fin->>'bonuses')::INTEGER, 0);
  total_deduct := late_deduct + absent_deduct + manual_deduct + loan_deduct;

  IF is_comm THEN
    net_salary := bonus;
  ELSE
    net_salary := GREATEST(0, base_salary + ot_amount + bonus - total_deduct);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'month_iso', bounds.month_iso,
    'month_label', bounds.month_label,
    'base_salary', base_salary,
    'attend_days', attend_days,
    'absent_days', absent_days,
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'absent_deduct', absent_deduct,
    'manual_deduct', manual_deduct,
    'loan_deduct', loan_deduct,
    'overtime_amount', ot_amount,
    'bonus', bonus,
    'total_deduct', total_deduct,
    'net_salary', net_salary,
    'daily_rate', daily_rate,
    'period_days', bounds.total_days,
    'elapsed_days', bounds.elapsed_days
  );
END;
$$;

-- ----------------------------------------------------------
-- 2) Payroll RPCs
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_preview_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN saas_v3_compute_salary(p_employee_id, p_month);
END;
$$;

CREATE OR REPLACE FUNCTION saas_issue_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  calc JSONB;
  rec salary_records%ROWTYPE;
  att_id INTEGER;
BEGIN
  calc := saas_v3_compute_salary(p_employee_id, p_month);
  IF COALESCE((calc->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN calc;
  END IF;

  INSERT INTO salary_records (
    employee_id, company_id, month_iso, month_label,
    base_salary, attend_days, late_minutes, late_deduct,
    absent_days, overtime_amount, bonus, total_deduct, net_salary,
    status, issued_at
  ) VALUES (
    p_employee_id,
    (calc->>'company_id')::INTEGER,
    calc->>'month_iso',
    calc->>'month_label',
    (calc->>'base_salary')::INTEGER,
    (calc->>'attend_days')::INTEGER,
    (calc->>'late_minutes')::INTEGER,
    (calc->>'late_deduct')::INTEGER,
    (calc->>'absent_days')::INTEGER,
    (calc->>'overtime_amount')::INTEGER,
    (calc->>'bonus')::INTEGER,
    (calc->>'total_deduct')::INTEGER,
    (calc->>'net_salary')::INTEGER,
    'مُصدر',
    NOW()
  )
  ON CONFLICT (employee_id, month_iso) DO UPDATE SET
    month_label = EXCLUDED.month_label,
    base_salary = EXCLUDED.base_salary,
    attend_days = EXCLUDED.attend_days,
    late_minutes = EXCLUDED.late_minutes,
    late_deduct = EXCLUDED.late_deduct,
    absent_days = EXCLUDED.absent_days,
    overtime_amount = EXCLUDED.overtime_amount,
    bonus = EXCLUDED.bonus,
    total_deduct = EXCLUDED.total_deduct,
    net_salary = EXCLUDED.net_salary,
    status = 'مُصدر',
    issued_at = NOW()
  RETURNING * INTO rec;

  UPDATE employees SET
    days = (calc->>'attend_days')::INTEGER,
    late_min = (calc->>'late_minutes')::INTEGER,
    sal_status = 'مُصدر'
  WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'salary_issued', 'payroll',
    'Issued salary for employee ' || p_employee_id::TEXT || ' period ' || (calc->>'month_iso'),
    (SELECT name FROM employees WHERE id = p_employee_id LIMIT 1),
    (calc->>'company_id')::INTEGER,
    NULL,
    to_jsonb(rec)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(rec), 'calc', calc);
END;
$$;

CREATE OR REPLACE FUNCTION saas_recalculate_salary(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  month_key TEXT;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  month_key := CASE WHEN COALESCE(emp.salary_type, 'monthly') = 'biweekly' THEN
    to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
    CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
  ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END;

  IF EXISTS (
    SELECT 1 FROM salary_records sr
    WHERE sr.employee_id = p_employee_id AND sr.month_iso = month_key AND sr.status = 'مُصدر'
  ) THEN
    RETURN saas_issue_salary(p_employee_id, month_key);
  END IF;

  RETURN saas_preview_salary(p_employee_id, month_key);
END;
$$;

-- ----------------------------------------------------------
-- 3) Attendance RPCs
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_attendance_employee(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_punch_type TEXT,
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  punch TEXT := lower(trim(COALESCE(p_punch_type, '')));
BEGIN
  IF punch NOT IN ('check_in', 'check_out') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'punch_type_required');
  END IF;
  RETURN saas_upsert_attendance_by_device(
    p_employee_id,
    p_fingerprint,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    p_emp_name,
    p_dept,
    NULL, NULL,
    punch
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_attendance_admin(
  p_employee_id INTEGER,
  p_date_iso DATE,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  active_chk JSONB;
  before_row JSONB;
  after_row JSONB;
  att_id INTEGER;
  use_ci TEXT;
  use_co TEXT;
  use_late TEXT := '—';
  use_ot TEXT := '—';
  use_hours TEXT := '—';
  use_status TEXT := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  ci_min INTEGER;
  co_min INTEGER;
  official_ci INTEGER;
  official_co INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ot_min INTEGER;
  ot_hourly INTEGER;
  dlabel TEXT;
  existing RECORD;
BEGIN
  IF p_employee_id IS NULL OR p_date_iso IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  active_chk := saas_assert_company_active(emp.company_id);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  SELECT to_jsonb(a.*) INTO before_row
  FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;

  SELECT a.check_in, a.check_out, a.status, a.late INTO existing
  FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;

  use_ci := COALESCE(NULLIF(trim(p_check_in), ''), existing.check_in, '—');
  use_co := COALESCE(NULLIF(trim(p_check_out), ''), existing.check_out, '—');

  IF emp.open_hours IS TRUE THEN
    use_late := '—';
    use_ot := '—';
    use_hours := '—';
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  ELSIF use_ci <> '—' AND use_co <> '—' THEN
    ci_min := basma_time_text_to_minutes(use_ci);
    co_min := basma_time_text_to_minutes(use_co);
    official_ci := basma_db_time_to_minutes(emp.check_in);
    official_co := basma_db_time_to_minutes(emp.check_out);
    late_min := GREATEST(0, ci_min - official_ci);
    IF late_min > late_threshold THEN
      use_status := 'متأخر';
      use_late := late_min || 'د';
    ELSIF late_min > 0 THEN
      use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
      use_late := late_min || 'د';
    END IF;
    IF co_min >= ci_min THEN
      use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ot_min := GREATEST(0, co_min - official_co);
      IF ot_min > 0 THEN
        ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN use_status := 'إضافي'; END IF;
      END IF;
    END IF;
  END IF;

  dlabel := basma_arabic_date_label(p_date_iso);

  INSERT INTO attendance (
    employee_id, company_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status
  ) VALUES (
    p_employee_id, emp.company_id, emp.name, emp.dept, dlabel, p_date_iso,
    use_ci, use_co, use_hours, use_late, use_ot, use_status
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = EXCLUDED.check_in,
    check_out = EXCLUDED.check_out,
    hours = EXCLUDED.hours,
    late = EXCLUDED.late,
    overtime = EXCLUDED.overtime,
    status = EXCLUDED.status
  RETURNING id INTO att_id;

  SELECT to_jsonb(a.*) INTO after_row FROM attendance a WHERE a.id = att_id;

  PERFORM saas_v3_write_audit(
    'attendance_override', 'attendance',
    COALESCE(NULLIF(trim(p_reason), ''), 'Admin attendance upsert'),
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'attendance_id', att_id, 'data', after_row, 'server_authoritative', true);
END;
$$;

CREATE OR REPLACE FUNCTION saas_recalculate_attendance_day(
  p_employee_id INTEGER,
  p_date_iso DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  att RECORD;
BEGIN
  SELECT * INTO att FROM attendance a
  WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attendance_not_found');
  END IF;

  RETURN saas_upsert_attendance_admin(
    p_employee_id,
    p_date_iso,
    att.check_in,
    att.check_out,
    att.status,
    'recalculate_day'
  );
END;
$$;

-- ----------------------------------------------------------
-- 4) Employee RPCs
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id,
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      COALESCE((p_payload->>'salary')::INTEGER, 0),
      COALESCE(p_payload->>'salary_type', p_payload->>'salaryType', 'monthly'),
      COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0),
      COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0),
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = EXCLUDED.company_id,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      COALESCE((p_payload->>'salary')::INTEGER, 0),
      COALESCE(p_payload->>'salary_type', p_payload->>'salaryType', 'monthly'),
      COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0),
      COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0),
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    RETURNING * INTO row;
  END IF;

  after_row := to_jsonb(row);

  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee' ELSE 'Updated employee' END,
    row.name,
    row.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_employee(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);
  DELETE FROM employees WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'employee_deleted', 'employees',
    'Deleted employee ' || p_employee_id::TEXT,
    emp.name,
    emp.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_update_employee_role(
  p_employee_id INTEGER,
  p_role TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
  after_row JSONB;
  new_role TEXT := NULLIF(trim(p_role), '');
BEGIN
  IF new_role IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);
  UPDATE employees SET role = new_role, updated_at = NOW()
  WHERE id = p_employee_id
  RETURNING * INTO emp;

  after_row := to_jsonb(emp);

  PERFORM saas_v3_write_audit(
    'employee_role_changed', 'employees',
    'Role changed to ' || new_role,
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

-- ----------------------------------------------------------
-- 5) GRANTs
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_preview_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_preview_salary(INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_issue_salary(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_issue_salary(INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_recalculate_salary(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recalculate_salary(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_attendance_employee(INTEGER, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_employee(INTEGER, TEXT, TEXT, TEXT, TEXT) TO authenticated, anon;

REVOKE ALL ON FUNCTION saas_upsert_attendance_admin(INTEGER, DATE, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_attendance_admin(INTEGER, DATE, TEXT, TEXT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_recalculate_attendance_day(INTEGER, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recalculate_attendance_day(INTEGER, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_employee(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_update_employee_role(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_employee_role(INTEGER, TEXT) TO authenticated;

-- END: 031_enterprise_v3_core.sql

-- ============================================================
-- BEGIN: 032_enterprise_v3_reads_lock.sql
-- ============================================================

-- ============================================================
-- KYNO 032 — Enterprise v3 Read Layer + Write Lock (manual activate)
-- Additive — لا تغيير RLS 029/030
-- Run saas_v3_enable_write_lock() ONLY after KYNO_RPC_MODE fully enabled
-- ============================================================

-- ----------------------------------------------------------
-- 1) Tenant-scoped read RPCs (pagination)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_list_employees(
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total INTEGER;
BEGIN
  IF auth_is_super_admin() THEN
    SELECT COUNT(*) INTO total FROM employees;
    SELECT COALESCE(jsonb_agg(to_jsonb(e.*) ORDER BY e.id), '[]'::jsonb) INTO rows
    FROM (
      SELECT * FROM employees e ORDER BY e.id LIMIT lim OFFSET off
    ) e;
    RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
  END IF;

  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT COUNT(*) INTO total FROM employees e WHERE e.company_id = cid;
  SELECT COALESCE(jsonb_agg(to_jsonb(e.*) ORDER BY e.id), '[]'::jsonb) INTO rows
  FROM (
    SELECT * FROM employees e WHERE e.company_id = cid ORDER BY e.id LIMIT lim OFFSET off
  ) e;

  RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
END;
$$;

CREATE OR REPLACE FUNCTION saas_list_attendance(
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0,
  p_employee_id INTEGER DEFAULT NULL,
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total INTEGER;
BEGIN
  IF auth_is_super_admin() THEN
    SELECT COUNT(*) INTO total FROM attendance a
    WHERE (p_employee_id IS NULL OR a.employee_id = p_employee_id)
      AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
      AND (p_date_to IS NULL OR a.date_iso <= p_date_to);
    SELECT COALESCE(jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso DESC), '[]'::jsonb) INTO rows
    FROM (
      SELECT * FROM attendance a
      WHERE (p_employee_id IS NULL OR a.employee_id = p_employee_id)
        AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
        AND (p_date_to IS NULL OR a.date_iso <= p_date_to)
      ORDER BY a.date_iso DESC
      LIMIT lim OFFSET off
    ) a;
    RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
  END IF;

  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT COUNT(*) INTO total FROM attendance a
  WHERE a.company_id = cid
    AND (p_employee_id IS NULL OR a.employee_id = p_employee_id)
    AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
    AND (p_date_to IS NULL OR a.date_iso <= p_date_to);

  SELECT COALESCE(jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT * FROM attendance a
    WHERE a.company_id = cid
      AND (p_employee_id IS NULL OR a.employee_id = p_employee_id)
      AND (p_date_from IS NULL OR a.date_iso >= p_date_from)
      AND (p_date_to IS NULL OR a.date_iso <= p_date_to)
    ORDER BY a.date_iso DESC
    LIMIT lim OFFSET off
  ) a;

  RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
END;
$$;

CREATE OR REPLACE FUNCTION saas_list_salary_records(
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0,
  p_employee_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  rows JSONB;
  total INTEGER;
BEGIN
  IF auth_is_super_admin() THEN
    SELECT COUNT(*) INTO total FROM salary_records sr
    WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id);
    SELECT COALESCE(jsonb_agg(to_jsonb(sr.*) ORDER BY sr.month_iso DESC), '[]'::jsonb) INTO rows
    FROM (
      SELECT * FROM salary_records sr
      WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id)
      ORDER BY sr.month_iso DESC
      LIMIT lim OFFSET off
    ) sr;
    RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
  END IF;

  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT COUNT(*) INTO total
  FROM salary_records sr
  WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id)
    AND auth_effective_company_id(sr.company_id, sr.employee_id) = cid;

  SELECT COALESCE(jsonb_agg(to_jsonb(sr.*) ORDER BY sr.month_iso DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT * FROM salary_records sr
    WHERE (p_employee_id IS NULL OR sr.employee_id = p_employee_id)
      AND auth_effective_company_id(sr.company_id, sr.employee_id) = cid
    ORDER BY sr.month_iso DESC
    LIMIT lim OFFSET off
  ) sr;

  RETURN jsonb_build_object('ok', true, 'data', rows, 'total', total, 'limit', lim, 'offset', off);
END;
$$;

-- ----------------------------------------------------------
-- 2) Final write lock — super_admin only, run manually after v3 rollout
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_enable_write_lock()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  REVOKE INSERT, UPDATE, DELETE ON employees FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON attendance FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON salary_records FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON departments FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON notifications FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON employee_devices FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON companies FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON subscriptions FROM authenticated;
  REVOKE INSERT, UPDATE, DELETE ON app_settings FROM authenticated;

  RETURN jsonb_build_object('ok', true, 'message', 'write_lock_enabled');
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_disable_write_lock()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  GRANT INSERT, UPDATE, DELETE ON employees TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON attendance TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON salary_records TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON departments TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON notifications TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON employee_devices TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON companies TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON subscriptions TO authenticated;
  GRANT INSERT, UPDATE, DELETE ON app_settings TO authenticated;

  RETURN jsonb_build_object('ok', true, 'message', 'write_lock_disabled');
END;
$$;

-- ----------------------------------------------------------
-- 3) GRANTs
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_list_employees(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_employees(INTEGER, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_list_attendance(INTEGER, INTEGER, INTEGER, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_attendance(INTEGER, INTEGER, INTEGER, DATE, DATE) TO authenticated;

REVOKE ALL ON FUNCTION saas_list_salary_records(INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_list_salary_records(INTEGER, INTEGER, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_enable_write_lock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_enable_write_lock() TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_disable_write_lock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_disable_write_lock() TO authenticated;

-- END: 032_enterprise_v3_reads_lock.sql

-- ============================================================
-- BEGIN: 033_final_lockdown.sql
-- ============================================================

-- ============================================================
-- KYNO 033 — Final Production Lockdown
-- Requires 030 + 031 + 032 applied first
-- REVOKE direct writes — RPC (SECURITY DEFINER) only
-- Does NOT alter RLS 030 policies
-- ============================================================

-- ----------------------------------------------------------
-- 0) Fix legacy device token RPC — no company_id = 1
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_device_token(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tok TEXT := NULLIF(trim(p_token), '');
  tenant JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT company_id INTO cid FROM employees WHERE id = p_employee_id LIMIT 1;
  IF NOT FOUND OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login
  ) VALUES (
    p_employee_id, p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok, NOW(), cid, '', '', NULL, NULL, NULL
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = cid,
    fingerprint = CASE WHEN employee_devices.fingerprint IS NOT NULL AND employee_devices.fingerprint <> '' THEN employee_devices.fingerprint ELSE '' END,
    ip = CASE WHEN employee_devices.ip IS NOT NULL AND employee_devices.ip <> '' THEN employee_devices.ip ELSE '' END;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'slot', p_slot, 'token', tok);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ----------------------------------------------------------
-- 1) Supplemental write RPCs (lockdown coverage)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_employee_device(
  p_employee_id INTEGER,
  p_slot INTEGER,
  p_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
  after_row JSONB;
  dev_id INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT to_jsonb(d.*) INTO before_row
  FROM employee_devices d
  WHERE d.employee_id = p_employee_id AND d.slot = p_slot
  LIMIT 1;

  INSERT INTO employee_devices (
    employee_id, company_id, slot, label, ip, fingerprint, pin, token,
    token_created_at, token_used_at, device_info, linked_at, last_login
  ) VALUES (
    p_employee_id,
    emp.company_id,
    p_slot,
    COALESCE(p_payload->>'label', 'الهاتف ' || p_slot::text),
    COALESCE(p_payload->>'ip', ''),
    COALESCE(p_payload->>'fingerprint', ''),
    COALESCE(p_payload->>'pin', ''),
    NULLIF(p_payload->>'token', ''),
    NULLIF(p_payload->>'token_created_at', '')::timestamptz,
    NULLIF(p_payload->>'token_used_at', '')::timestamptz,
    COALESCE(p_payload->'device_info', '{}'::jsonb),
    NULLIF(p_payload->>'linked_at', '')::timestamptz,
    NULLIF(p_payload->>'last_login', '')::timestamptz
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    label = COALESCE(NULLIF(EXCLUDED.label, ''), employee_devices.label),
    ip = CASE
      WHEN EXCLUDED.ip IS NOT NULL AND EXCLUDED.ip <> '' THEN EXCLUDED.ip
      ELSE employee_devices.ip
    END,
    fingerprint = CASE
      WHEN EXCLUDED.fingerprint IS NOT NULL AND EXCLUDED.fingerprint <> '' THEN EXCLUDED.fingerprint
      ELSE employee_devices.fingerprint
    END,
    pin = COALESCE(NULLIF(EXCLUDED.pin, ''), employee_devices.pin),
    token = COALESCE(EXCLUDED.token, employee_devices.token),
    token_created_at = COALESCE(EXCLUDED.token_created_at, employee_devices.token_created_at),
    token_used_at = COALESCE(EXCLUDED.token_used_at, employee_devices.token_used_at),
    device_info = CASE
      WHEN EXCLUDED.device_info IS NOT NULL AND EXCLUDED.device_info <> '{}'::jsonb THEN EXCLUDED.device_info
      ELSE employee_devices.device_info
    END,
    linked_at = COALESCE(EXCLUDED.linked_at, employee_devices.linked_at),
    last_login = COALESCE(EXCLUDED.last_login, employee_devices.last_login),
    company_id = emp.company_id
  RETURNING id INTO dev_id;

  SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

  PERFORM saas_v3_write_audit(
    'employee_device_upsert', 'devices',
    'Device slot ' || p_slot::text || ' for employee ' || p_employee_id::text,
    emp.name,
    emp.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_attendance(
  p_employee_id INTEGER,
  p_date_iso DATE DEFAULT NULL,
  p_attendance_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  att RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  IF p_attendance_id IS NOT NULL THEN
    SELECT * INTO att FROM attendance a WHERE a.id = p_attendance_id LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_date_iso IS NOT NULL THEN
    SELECT * INTO att FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = p_date_iso
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attendance_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(att.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(att);
  DELETE FROM attendance WHERE id = att.id;

  PERFORM saas_v3_write_audit(
    'attendance_deleted', 'attendance',
    'Deleted attendance id ' || att.id::text,
    att.emp_name,
    att.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'attendance_id', att.id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_salary_record(
  p_employee_id INTEGER,
  p_month_iso TEXT DEFAULT NULL,
  p_period_prefix TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  deleted_count INTEGER := 0;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  IF p_month_iso IS NOT NULL AND trim(p_month_iso) <> '' THEN
    DELETE FROM salary_records
    WHERE employee_id = p_employee_id AND month_iso = trim(p_month_iso);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
  ELSIF p_period_prefix IS NOT NULL AND trim(p_period_prefix) <> '' THEN
    DELETE FROM salary_records
    WHERE employee_id = p_employee_id AND month_iso LIKE trim(p_period_prefix) || '%';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  PERFORM saas_v3_write_audit(
    'salary_record_deleted', 'payroll',
    'Deleted salary records count ' || deleted_count::text,
    emp.name,
    emp.company_id,
    NULL,
    jsonb_build_object('employee_id', p_employee_id, 'month_iso', p_month_iso, 'period_prefix', p_period_prefix)
  );

  RETURN jsonb_build_object('ok', true, 'deleted', deleted_count);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_tenant_settings(p_settings JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  k TEXT;
  v TEXT;
  db_key TEXT;
  cnt INTEGER := 0;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(p_settings)
  LOOP
    IF k IS NULL OR k = '' THEN CONTINUE; END IF;
    db_key := 'company:' || cid::text || ':' || k;
    INSERT INTO app_settings (key, value, updated_at)
    VALUES (db_key, v, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END LOOP;

  PERFORM saas_v3_write_audit(
    'settings_updated', 'settings',
    'Updated ' || cnt::text || ' tenant settings',
    'company:' || cid::text,
    cid,
    NULL,
    p_settings
  );

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

CREATE OR REPLACE FUNCTION saas_save_platform_globals(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cnt INTEGER := 0;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  IF p_payload ? 'support_whatsapp' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:support_whatsapp', trim(p_payload->>'support_whatsapp'), NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  IF p_payload ? 'support_whatsapp_team' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:support_whatsapp_team', trim(p_payload->>'support_whatsapp_team'), NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  IF p_payload ? 'announcements' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:platform_announcements', (p_payload->'announcements')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

-- Harden employee upsert — tenants cannot override company_id via payload
CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      COALESCE((p_payload->>'salary')::INTEGER, 0),
      COALESCE(p_payload->>'salary_type', p_payload->>'salaryType', 'monthly'),
      COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0),
      COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0),
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      COALESCE((p_payload->>'salary')::INTEGER, 0),
      COALESCE(p_payload->>'salary_type', p_payload->>'salaryType', 'monthly'),
      COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0),
      COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0),
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    RETURNING * INTO row;
  END IF;

  after_row := to_jsonb(row);

  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee' ELSE 'Updated employee' END,
    row.name,
    row.company_id,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

-- ----------------------------------------------------------
-- 2) RLS posture audit (run after lockdown)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_audit_rls_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  admin_all_count INTEGER;
  true_qual_count INTEGER;
  policy_counts JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO admin_all_count
  FROM pg_policies
  WHERE schemaname = 'public' AND policyname LIKE 'admin_all_%';

  SELECT COUNT(*) INTO true_qual_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND (
      qual::text ~ '(^|[^a-z_])true([^a-z_]|$)'
      OR with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)'
    );

  SELECT COALESCE(jsonb_object_agg(tablename, cnt), '{}'::jsonb) INTO policy_counts
  FROM (
    SELECT tablename, COUNT(*)::INTEGER AS cnt
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'admin_all_count', admin_all_count,
    'using_true_count', true_qual_count,
    'policy_counts', policy_counts,
    'enterprise_ready',
      admin_all_count = 0 AND true_qual_count = 0
  );
END;
$$;

-- ----------------------------------------------------------
-- 3) Drop risky views (admin_* only — keep v_* read views)
-- ----------------------------------------------------------
DO $$
DECLARE
  v RECORD;
BEGIN
  FOR v IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
      AND c.relname LIKE 'admin\_%' ESCAPE '\'
  LOOP
    EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', v.relname);
  END LOOP;
END $$;

-- ----------------------------------------------------------
-- 4) FINAL REVOKE — direct writes forbidden for anon + authenticated
-- SECURITY DEFINER RPCs (owner postgres) retain write access
-- ----------------------------------------------------------
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname NOT LIKE 'pg\_%' ESCAPE '\'
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM anon', r.tablename);
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM authenticated', r.tablename);
  END LOOP;
END $$;

-- Ensure SELECT remains for RLS-protected reads
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;

-- ----------------------------------------------------------
-- 5) GRANTs — new RPCs
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_upsert_employee_device(INTEGER, INTEGER, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee_device(INTEGER, INTEGER, JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_attendance(INTEGER, DATE, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_attendance(INTEGER, DATE, INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_delete_salary_record(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_salary_record(INTEGER, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_upsert_tenant_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_tenant_settings(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_save_platform_globals(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_save_platform_globals(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_v3_audit_rls_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_audit_rls_report() TO authenticated;

COMMENT ON FUNCTION saas_v3_audit_rls_report() IS
  'Post-lockdown RLS validation — admin_all_* must be 0, USING(true) must be 0';

-- END: 033_final_lockdown.sql

-- ============================================================
-- BEGIN: 034_super_admin_company_rpc.sql
-- ============================================================

-- ============================================================
-- KYNO 034 — Super Admin company/subscription RPCs (post-033 lockdown)
-- Required for platform admin panel after REVOKE direct writes
-- Does NOT change RLS 030 policies
-- ============================================================

CREATE OR REPLACE FUNCTION saas_super_upsert_company(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  before_row JSONB;
  after_row companies%ROWTYPE;
  new_code TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := NULLIF((p_payload->>'id')::INTEGER, 0);
  new_code := upper(trim(COALESCE(p_payload->>'company_code', p_payload->>'code', '')));

  IF cid IS NOT NULL THEN
    SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = cid LIMIT 1;
    IF before_row IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;

    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), company_name),
      company_code = CASE WHEN new_code <> '' THEN new_code ELSE company_code END,
      status = COALESCE(NULLIF(trim(p_payload->>'status'), ''), status),
      max_employees = COALESCE((p_payload->>'max_employees')::INTEGER, max_employees),
      notes = COALESCE(p_payload->>'notes', notes),
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO after_row;
  ELSE
    IF new_code = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_code_required');
    END IF;
    INSERT INTO companies (company_name, company_code, status, max_employees, notes)
    VALUES (
      COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), 'شركة جديدة'),
      new_code,
      COALESCE(NULLIF(trim(p_payload->>'status'), ''), 'pending'),
      COALESCE((p_payload->>'max_employees')::INTEGER, 50),
      COALESCE(p_payload->>'notes', '')
    )
    RETURNING * INTO after_row;
    before_row := NULL;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN cid IS NULL THEN 'company_created' ELSE 'company_updated' END,
    'companies',
    'Super admin company upsert id ' || after_row.id::text,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_code_duplicate');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_toggle_company_status(
  p_company_id INTEGER,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_row JSONB;
  after_row companies%ROWTYPE;
  st TEXT := NULLIF(trim(p_status), '');
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_company_id IS NULL OR st IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;
  IF st NOT IN ('active', 'suspended', 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = p_company_id LIMIT 1;
  IF before_row IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  UPDATE companies SET status = st, updated_at = NOW()
  WHERE id = p_company_id
  RETURNING * INTO after_row;

  PERFORM saas_v3_write_audit(
    'company_status_changed', 'companies',
    'Status -> ' || st,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_delete_company(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  comp RECORD;
  emp_ids INTEGER[];
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO comp FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  SELECT array_agg(e.id) INTO emp_ids FROM employees e WHERE e.company_id = p_company_id;

  DELETE FROM subscriptions WHERE company_id = p_company_id;
  DELETE FROM saas_users WHERE company_id = p_company_id;
  IF emp_ids IS NOT NULL THEN
    DELETE FROM employee_devices WHERE employee_id = ANY(emp_ids);
  END IF;
  DELETE FROM attendance WHERE company_id = p_company_id;
  DELETE FROM salary_records WHERE company_id = p_company_id;
  DELETE FROM employees WHERE company_id = p_company_id;
  DELETE FROM departments WHERE company_id = p_company_id;
  DELETE FROM notifications WHERE company_id = p_company_id;
  DELETE FROM companies WHERE id = p_company_id;

  PERFORM saas_v3_write_audit(
    'company_deleted', 'companies',
    'Deleted company ' || p_company_id::text,
    comp.company_name,
    p_company_id,
    to_jsonb(comp),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'company_id', p_company_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_renew_subscription(
  p_company_id INTEGER,
  p_duration_days INTEGER DEFAULT 30,
  p_amount INTEGER DEFAULT 0,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing RECORD;
  start_d DATE;
  end_d DATE;
  dur_days INTEGER := GREATEST(1, COALESCE(p_duration_days, 30));
  pay_amt INTEGER := GREATEST(0, COALESCE(p_amount, 0));
  dur_months INTEGER;
  note_text TEXT;
  actor TEXT;
  sub_id INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO existing FROM subscriptions
  WHERE company_id = p_company_id
  ORDER BY created_at DESC NULLS LAST, id DESC
  LIMIT 1;

  dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
  note_text := COALESCE(NULLIF(trim(p_notes), ''), 'تمديد ' || dur_days::text || ' يوم');
  actor := COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', 'system');

  IF existing.id IS NOT NULL AND existing.status = 'active' AND existing.end_date >= CURRENT_DATE THEN
    start_d := existing.start_date;
    end_d := existing.end_date + dur_days;
    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      status = 'active',
      duration_months = dur_months,
      amount = pay_amt,
      notes = note_text,
      activated_by = actor,
      updated_at = NOW()
    WHERE id = existing.id
    RETURNING id INTO sub_id;
  ELSIF existing.id IS NOT NULL THEN
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      status = 'active',
      duration_months = dur_months,
      amount = pay_amt,
      notes = note_text,
      activated_by = actor,
      updated_at = NOW()
    WHERE id = existing.id
    RETURNING id INTO sub_id;
  ELSE
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    INSERT INTO subscriptions (
      company_id, plan_name, start_date, end_date, status,
      duration_months, amount, notes, activated_by
    ) VALUES (
      p_company_id, 'PRO', start_d, end_d, 'active',
      dur_months, pay_amt, note_text, actor
    )
    RETURNING id INTO sub_id;
  END IF;

  UPDATE companies SET status = 'active', updated_at = NOW() WHERE id = p_company_id;

  PERFORM saas_v3_write_audit(
    'subscription_renewed', 'subscriptions',
    note_text,
    'company:' || p_company_id::text,
    p_company_id,
    CASE WHEN existing.id IS NOT NULL THEN to_jsonb(existing) ELSE NULL END,
    jsonb_build_object('subscription_id', sub_id, 'end_date', end_d)
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'end_date', end_d);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_delete_subscription(p_subscription_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub RECORD;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_subscription_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  DELETE FROM subscriptions WHERE id = p_subscription_id;

  PERFORM saas_v3_write_audit(
    'subscription_deleted', 'subscriptions',
    'Deleted subscription ' || p_subscription_id::text,
    'company:' || sub.company_id::text,
    sub.company_id,
    to_jsonb(sub),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'deleted', 1);
END;
$$;

CREATE OR REPLACE FUNCTION saas_mark_subscription_expired(p_subscription_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub RECORD;
BEGIN
  IF p_subscription_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF auth_is_super_admin() THEN
    NULL;
  ELSIF auth_company_id() IS NOT NULL AND sub.company_id = auth_company_id() THEN
    NULL;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
  END IF;

  IF sub.status = 'expired' THEN
    RETURN jsonb_build_object('ok', true, 'already_expired', true);
  END IF;

  UPDATE subscriptions SET status = 'expired', updated_at = NOW() WHERE id = p_subscription_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_upsert_company(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_upsert_company(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_super_toggle_company_status(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_toggle_company_status(INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_super_delete_company(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_delete_company(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_super_delete_subscription(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_delete_subscription(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_mark_subscription_expired(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_subscription_expired(INTEGER) TO authenticated;

-- Super admin may create initial company_admin before subscription exists
CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
  active_chk JSONB;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT auth_is_super_admin() THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'subscription_inactive',
        'detail', COALESCE(active_chk->>'error', 'unknown')
      );
    END IF;
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', uname,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', cid,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

-- END: 034_super_admin_company_rpc.sql

-- ============================================================
-- BEGIN: 035_super_admin_team.sql
-- ============================================================

-- ============================================================
-- KYNO 035 — Super Admin team, granular permissions, sender names
-- Run after 034 on production
-- ============================================================

-- ── Default permission set (all true for legacy accounts) ──
CREATE OR REPLACE FUNCTION saas_super_admin_default_perms()
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'job_title', '',
    'companies_view', true,
    'companies_create', true,
    'companies_edit', true,
    'companies_delete', true,
    'companies_suspend', true,
    'subscriptions_renew', true,
    'subscriptions_delete', true,
    'users_manage', true,
    'platform_whatsapp', true,
    'platform_announce', true,
    'platform_announce_manage', true,
    'team_manage', true,
    'stats_view', true
  );
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_effective_perms(p_user_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  uid INTEGER := COALESCE(p_user_id, auth_saas_user_id());
  stored JSONB;
  defaults JSONB := saas_super_admin_default_perms();
  merged JSONB;
  k TEXT;
BEGIN
  IF uid IS NULL OR uid <= 0 THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT u.permissions->'super_admin' INTO stored
  FROM saas_users u
  WHERE u.id = uid AND u.role = 'super_admin' AND u.is_active = true
  LIMIT 1;

  IF NOT FOUND OR stored IS NULL OR stored = 'null'::jsonb OR stored = '{}'::jsonb THEN
    RETURN defaults;
  END IF;

  merged := defaults;
  FOR k IN SELECT jsonb_object_keys(stored)
  LOOP
    merged := merged || jsonb_build_object(k, stored->k);
  END LOOP;
  RETURN merged;
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_can(p_perm TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  perms JSONB;
  raw TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN FALSE;
  END IF;
  IF p_perm IS NULL OR trim(p_perm) = '' THEN
    RETURN FALSE;
  END IF;

  perms := saas_super_admin_effective_perms(auth_saas_user_id());
  raw := perms->>p_perm;
  IF raw IS NULL THEN
    RETURN TRUE;
  END IF;
  RETURN lower(trim(raw)) NOT IN ('false', '0', 'no');
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_sender_meta(p_user_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  uid INTEGER := COALESCE(p_user_id, auth_saas_user_id());
  u RECORD;
  perms JSONB;
  jt TEXT;
BEGIN
  SELECT id, username, display_name, permissions INTO u
  FROM saas_users
  WHERE id = uid AND role = 'super_admin'
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('senderId', NULL, 'senderName', 'الإدارة', 'senderJobTitle', '');
  END IF;
  perms := saas_super_admin_effective_perms(u.id);
  jt := COALESCE(NULLIF(trim(perms->>'job_title'), ''), '');
  RETURN jsonb_build_object(
    'senderId', u.id,
    'senderName', COALESCE(NULLIF(trim(u.display_name), ''), u.username, 'الإدارة'),
    'senderJobTitle', jt
  );
END;
$$;

-- ── Team CRUD ──
CREATE OR REPLACE FUNCTION saas_list_super_admins()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  rows JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', u.id,
      'username', u.username,
      'display_name', COALESCE(u.display_name, ''),
      'email', COALESCE(u.email, ''),
      'is_active', u.is_active,
      'last_login', u.last_login,
      'created_at', u.created_at,
      'permissions', saas_super_admin_effective_perms(u.id),
      'is_self', u.id = auth_saas_user_id()
    ) ORDER BY u.id
  ), '[]'::jsonb) INTO rows
  FROM saas_users u
  WHERE u.role = 'super_admin';

  RETURN jsonb_build_object('ok', true, 'data', rows);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER;
  actor_id INTEGER;
  uname TEXT;
  hash TEXT;
  perms JSONB;
  perm_block JSONB;
  row_out RECORD;
  is_new BOOLEAN := false;
  k TEXT;
  defaults JSONB := saas_super_admin_default_perms();
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  actor_id := auth_saas_user_id();
  uid := NULLIF((p_payload->>'id')::INTEGER, 0);

  uname := lower(trim(COALESCE(p_payload->>'username', '')));
  IF length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_required');
  END IF;

  IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname AND (uid IS NULL OR id <> uid)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  END IF;

  perm_block := defaults;
  IF p_payload ? 'permissions' AND jsonb_typeof(p_payload->'permissions') = 'object' THEN
    FOR k IN SELECT jsonb_object_keys(p_payload->'permissions')
    LOOP
      IF k = 'job_title' THEN
        perm_block := perm_block || jsonb_build_object('job_title', p_payload->'permissions'->>'job_title');
      ELSIF defaults ? k THEN
        perm_block := perm_block || jsonb_build_object(k, (p_payload->'permissions'->>k)::boolean);
      END IF;
    END LOOP;
  END IF;
  IF p_payload ? 'job_title' THEN
    perm_block := perm_block || jsonb_build_object('job_title', trim(p_payload->>'job_title'));
  END IF;

  perms := jsonb_build_object('super_admin', perm_block);

  IF uid IS NULL THEN
    IF p_payload->>'password' IS NULL OR length(trim(p_payload->>'password')) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;
    hash := saas_hash_password_bcrypt(trim(p_payload->>'password'));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;
    is_new := true;
    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, company_id, permissions, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_payload->>'display_name'), ''), uname),
      NULLIF(trim(p_payload->>'email'), ''),
      hash, 'bcrypt',
      'super_admin', NULL, perms,
      COALESCE((p_payload->>'is_active')::boolean, true)
    )
    RETURNING * INTO row_out;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM saas_users WHERE id = uid AND role = 'super_admin') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_payload->>'display_name'), ''), display_name, uname),
      email = CASE WHEN p_payload ? 'email' THEN NULLIF(trim(p_payload->>'email'), '') ELSE email END,
      permissions = perms,
      is_active = COALESCE((p_payload->>'is_active')::boolean, is_active),
      updated_at = NOW()
    WHERE id = uid AND role = 'super_admin'
    RETURNING * INTO row_out;

    IF p_payload->>'password' IS NOT NULL AND length(trim(p_payload->>'password')) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_payload->>'password'));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'super_admin_created' ELSE 'super_admin_updated' END,
    'saas_users',
    'Super admin ' || row_out.username,
    COALESCE(row_out.display_name, row_out.username),
    row_out.id,
    NULL,
    jsonb_build_object('username', row_out.username, 'permissions', perm_block)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'id', row_out.id,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'is_active', row_out.is_active,
      'permissions', perm_block
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_super_admin(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  actor_id INTEGER;
  target RECORD;
  remaining INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_user_id IS NULL OR p_user_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();
  IF actor_id = p_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_delete_self');
  END IF;

  SELECT * INTO target FROM saas_users WHERE id = p_user_id AND role = 'super_admin' LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  SELECT COUNT(*) INTO remaining FROM saas_users WHERE role = 'super_admin' AND is_active = true;
  IF remaining <= 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_super_admin');
  END IF;

  DELETE FROM saas_users WHERE id = p_user_id AND role = 'super_admin';

  PERFORM saas_v3_write_audit(
    'super_admin_deleted', 'saas_users',
    'Deleted super admin id ' || p_user_id::text,
    COALESCE(target.display_name, target.username),
    p_user_id,
    to_jsonb(target),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'id', p_user_id);
END;
$$;

-- ── Self-service account (display name + job title) ──
DROP FUNCTION IF EXISTS saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION saas_update_saas_account(
  p_user_id INTEGER,
  p_username TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_password TEXT DEFAULT NULL,
  p_display_name TEXT DEFAULT NULL,
  p_job_title TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  actor_id INTEGER;
  uname TEXT;
  hash TEXT;
  row_out RECORD;
  perms JSONB;
  block JSONB;
BEGIN
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  actor_id := auth_saas_user_id();

  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF actor_id IS NOT NULL AND actor_id <> uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_only');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users WHERE id = uid AND role = 'super_admin' AND is_active = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  uname := lower(trim(COALESCE(p_username, '')));
  IF uname IS NOT NULL AND length(uname) >= 3 THEN
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname AND id <> uid) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;
  ELSE
    uname := NULL;
  END IF;

  SELECT permissions INTO perms FROM saas_users WHERE id = uid;
  block := saas_super_admin_effective_perms(uid);
  IF p_job_title IS NOT NULL THEN
    block := block || jsonb_build_object('job_title', trim(p_job_title));
    perms := COALESCE(perms, '{}'::jsonb) || jsonb_build_object('super_admin', block);
  END IF;

  UPDATE saas_users SET
    username = COALESCE(uname, username),
    display_name = CASE
      WHEN p_display_name IS NOT NULL THEN COALESCE(NULLIF(trim(p_display_name), ''), display_name, username)
      ELSE display_name
    END,
    email = CASE WHEN p_email IS NOT NULL THEN NULLIF(trim(p_email), '') ELSE email END,
    permissions = CASE WHEN p_job_title IS NOT NULL THEN perms ELSE permissions END,
    updated_at = NOW()
  WHERE id = uid AND role = 'super_admin'
  RETURNING * INTO row_out;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;
    UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', row_out.id,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'job_title', saas_super_admin_effective_perms(uid)->>'job_title'
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ── Platform globals with permission checks + sender stamping ──
CREATE OR REPLACE FUNCTION saas_save_platform_globals(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cnt INTEGER := 0;
  old_ann JSONB := '[]'::jsonb;
  new_ann JSONB;
  merged JSONB := '[]'::jsonb;
  elem JSONB;
  old_ids TEXT[];
  sender JSONB;
  i INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  IF p_payload ? 'support_whatsapp' OR p_payload ? 'support_whatsapp_team' THEN
    IF NOT saas_super_admin_can('platform_whatsapp') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  END IF;

  IF p_payload ? 'announcements' THEN
    IF NOT saas_super_admin_can('platform_announce') AND NOT saas_super_admin_can('platform_announce_manage') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;

    SELECT COALESCE(value::jsonb, '[]'::jsonb) INTO old_ann
    FROM app_settings WHERE key = 'global:platform_announcements' LIMIT 1;
    IF old_ann IS NULL OR jsonb_typeof(old_ann) <> 'array' THEN
      old_ann := '[]'::jsonb;
    END IF;

    SELECT array_agg(x->>'id') INTO old_ids
    FROM jsonb_array_elements(old_ann) x
    WHERE x->>'id' IS NOT NULL;

    new_ann := p_payload->'announcements';
    IF new_ann IS NULL OR jsonb_typeof(new_ann) <> 'array' THEN
      new_ann := '[]'::jsonb;
    END IF;

    sender := saas_super_admin_sender_meta();

    FOR i IN 0 .. jsonb_array_length(new_ann) - 1 LOOP
      elem := new_ann->i;
      IF elem->>'id' IS NOT NULL AND old_ids IS NOT NULL AND elem->>'id' = ANY(old_ids) THEN
        merged := merged || jsonb_build_array(elem);
      ELSE
        merged := merged || jsonb_build_array(
          elem || jsonb_build_object(
            'senderId', sender->'senderId',
            'senderName', sender->>'senderName',
            'senderJobTitle', sender->>'senderJobTitle'
          )
        );
      END IF;
    END LOOP;

    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:platform_announcements', merged::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  IF p_payload ? 'support_whatsapp' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:support_whatsapp', trim(p_payload->>'support_whatsapp'), NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  IF p_payload ? 'support_whatsapp_team' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('global:support_whatsapp_team', trim(p_payload->>'support_whatsapp_team'), NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

-- ── Patch super-admin company RPCs with permission checks ──
CREATE OR REPLACE FUNCTION saas_super_upsert_company(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  before_row JSONB;
  after_row companies%ROWTYPE;
  new_code TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := NULLIF((p_payload->>'id')::INTEGER, 0);
  IF cid IS NULL THEN
    IF NOT saas_super_admin_can('companies_create') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  ELSE
    IF NOT saas_super_admin_can('companies_edit') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  END IF;

  new_code := upper(trim(COALESCE(p_payload->>'company_code', p_payload->>'code', '')));

  IF cid IS NOT NULL THEN
    SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = cid LIMIT 1;
    IF before_row IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;

    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), company_name),
      company_code = CASE WHEN new_code <> '' THEN new_code ELSE company_code END,
      status = COALESCE(NULLIF(trim(p_payload->>'status'), ''), status),
      max_employees = COALESCE((p_payload->>'max_employees')::INTEGER, max_employees),
      notes = COALESCE(p_payload->>'notes', notes),
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO after_row;
  ELSE
    IF new_code = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_code_required');
    END IF;
    INSERT INTO companies (company_name, company_code, status, max_employees, notes)
    VALUES (
      COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), 'شركة جديدة'),
      new_code,
      COALESCE(NULLIF(trim(p_payload->>'status'), ''), 'pending'),
      COALESCE((p_payload->>'max_employees')::INTEGER, 50),
      COALESCE(p_payload->>'notes', '')
    )
    RETURNING * INTO after_row;
    before_row := NULL;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN cid IS NULL THEN 'company_created' ELSE 'company_updated' END,
    'companies',
    'Super admin company upsert id ' || after_row.id::text,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_code_duplicate');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_toggle_company_status(
  p_company_id INTEGER,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_row JSONB;
  after_row companies%ROWTYPE;
  st TEXT := NULLIF(trim(p_status), '');
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('companies_suspend') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL OR st IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;
  IF st NOT IN ('active', 'suspended', 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = p_company_id LIMIT 1;
  IF before_row IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  UPDATE companies SET status = st, updated_at = NOW()
  WHERE id = p_company_id
  RETURNING * INTO after_row;

  PERFORM saas_v3_write_audit(
    'company_status_changed', 'companies',
    'Status -> ' || st,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row)
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_delete_company(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  comp RECORD;
  emp_ids INTEGER[];
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('companies_delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO comp FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  SELECT array_agg(e.id) INTO emp_ids FROM employees e WHERE e.company_id = p_company_id;

  DELETE FROM subscriptions WHERE company_id = p_company_id;
  DELETE FROM saas_users WHERE company_id = p_company_id;
  IF emp_ids IS NOT NULL THEN
    DELETE FROM employee_devices WHERE employee_id = ANY(emp_ids);
  END IF;
  DELETE FROM attendance WHERE company_id = p_company_id;
  DELETE FROM salary_records WHERE company_id = p_company_id;
  DELETE FROM employees WHERE company_id = p_company_id;
  DELETE FROM departments WHERE company_id = p_company_id;
  DELETE FROM notifications WHERE company_id = p_company_id;
  DELETE FROM companies WHERE id = p_company_id;

  PERFORM saas_v3_write_audit(
    'company_deleted', 'companies',
    'Deleted company ' || p_company_id::text,
    comp.company_name,
    p_company_id,
    to_jsonb(comp),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'company_id', p_company_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_renew_subscription(
  p_company_id INTEGER,
  p_duration_days INTEGER DEFAULT 30,
  p_amount INTEGER DEFAULT 0,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing RECORD;
  start_d DATE;
  end_d DATE;
  dur_days INTEGER := GREATEST(1, COALESCE(p_duration_days, 30));
  pay_amt INTEGER := GREATEST(0, COALESCE(p_amount, 0));
  dur_months INTEGER;
  note_text TEXT;
  actor TEXT;
  sub_id INTEGER;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_renew') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO existing FROM subscriptions
  WHERE company_id = p_company_id
  ORDER BY created_at DESC NULLS LAST, id DESC
  LIMIT 1;

  dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
  note_text := COALESCE(NULLIF(trim(p_notes), ''), 'تمديد ' || dur_days::text || ' يوم');
  actor := COALESCE(
    (saas_super_admin_sender_meta()->>'senderName'),
    auth.jwt() -> 'app_metadata' ->> 'display_name',
    auth.jwt() ->> 'email',
    'system'
  );

  IF existing.id IS NOT NULL AND existing.status = 'active' AND existing.end_date >= CURRENT_DATE THEN
    start_d := existing.start_date;
    end_d := existing.end_date + dur_days;
    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      status = 'active',
      duration_months = dur_months,
      amount = pay_amt,
      notes = note_text,
      activated_by = actor,
      updated_at = NOW()
    WHERE id = existing.id
    RETURNING id INTO sub_id;
  ELSIF existing.id IS NOT NULL THEN
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      status = 'active',
      duration_months = dur_months,
      amount = pay_amt,
      notes = note_text,
      activated_by = actor,
      updated_at = NOW()
    WHERE id = existing.id
    RETURNING id INTO sub_id;
  ELSE
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    INSERT INTO subscriptions (
      company_id, plan_name, start_date, end_date, status,
      duration_months, amount, notes, activated_by
    ) VALUES (
      p_company_id, 'PRO', start_d, end_d, 'active',
      dur_months, pay_amt, note_text, actor
    )
    RETURNING id INTO sub_id;
  END IF;

  UPDATE companies SET status = 'active', updated_at = NOW() WHERE id = p_company_id;

  PERFORM saas_v3_write_audit(
    'subscription_renewed', 'subscriptions',
    note_text,
    'company:' || p_company_id::text,
    p_company_id,
    CASE WHEN existing.id IS NOT NULL THEN to_jsonb(existing) ELSE NULL END,
    jsonb_build_object('subscription_id', sub_id, 'end_date', end_d)
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'end_date', end_d);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_delete_subscription(p_subscription_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub RECORD;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_delete') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_subscription_id IS NULL OR p_subscription_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  DELETE FROM subscriptions WHERE id = p_subscription_id;

  PERFORM saas_v3_write_audit(
    'subscription_deleted', 'subscriptions',
    'Deleted subscription ' || p_subscription_id::text,
    'company:' || sub.company_id::text,
    sub.company_id,
    to_jsonb(sub),
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'deleted', 1);
END;
$$;

-- ── Company user management permission for super admins ──
CREATE OR REPLACE FUNCTION auth_can_manage_tenant_users(p_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  actor_id INTEGER;
  actor_role TEXT;
  actor_cid INTEGER;
  actor_perms JSONB;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN FALSE;
  END IF;

  IF auth_is_super_admin() THEN
    RETURN saas_super_admin_can('users_manage');
  END IF;

  actor_id := auth_saas_user_id();
  IF actor_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT role, company_id, COALESCE(permissions, '{}'::jsonb)
  INTO actor_role, actor_cid, actor_perms
  FROM saas_users
  WHERE id = actor_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF actor_cid IS NULL OR actor_cid <> p_company_id THEN
    RETURN FALSE;
  END IF;

  IF actor_role IN ('company_admin', 'super_admin') THEN
    RETURN TRUE;
  END IF;

  IF actor_role = 'company_user'
     AND COALESCE((actor_perms ->> 'users_permissions')::boolean, false) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

-- ── Grants ──
REVOKE ALL ON FUNCTION saas_super_admin_default_perms() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_effective_perms(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_can(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_sender_meta(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_list_super_admins() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_delete_super_admin(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_list_super_admins() TO authenticated;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION saas_delete_super_admin(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION saas_update_saas_account(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- END: 035_super_admin_team.sql

-- ============================================================
-- BEGIN: 036_super_admin_view_only.sql
-- ============================================================

-- ============================================================
-- KYNO 036 — Super Admin view-only mode + page view permissions
-- Run after 035
-- ============================================================

CREATE OR REPLACE FUNCTION saas_super_admin_default_perms()
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'job_title', '',
    'view_only', false,
    'companies_view', true,
    'companies_create', true,
    'companies_edit', true,
    'companies_delete', true,
    'companies_suspend', true,
    'subscriptions_view', true,
    'subscriptions_renew', true,
    'subscriptions_delete', true,
    'users_view', true,
    'users_manage', true,
    'platform_view', true,
    'platform_whatsapp', true,
    'platform_announce', true,
    'platform_announce_manage', true,
    'team_manage', true,
    'stats_view', true
  );
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_is_write_perm(p_perm TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(p_perm, '') IN (
    'companies_create', 'companies_edit', 'companies_delete', 'companies_suspend',
    'subscriptions_renew', 'subscriptions_delete',
    'users_manage',
    'platform_whatsapp', 'platform_announce', 'platform_announce_manage',
    'team_manage'
  );
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_can(p_perm TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  perms JSONB;
  raw TEXT;
  view_only BOOLEAN;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN FALSE;
  END IF;
  IF p_perm IS NULL OR trim(p_perm) = '' THEN
    RETURN FALSE;
  END IF;

  perms := saas_super_admin_effective_perms(auth_saas_user_id());
  view_only := COALESCE((perms->>'view_only')::boolean, false);

  IF view_only AND saas_super_admin_is_write_perm(p_perm) THEN
    RETURN FALSE;
  END IF;

  raw := perms->>p_perm;
  IF raw IS NULL THEN
    RETURN NOT saas_super_admin_is_write_perm(p_perm);
  END IF;
  RETURN lower(trim(raw)) NOT IN ('false', '0', 'no');
END;
$$;

-- Enforce view_only on save (server-side)
CREATE OR REPLACE FUNCTION saas_upsert_super_admin(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER;
  actor_id INTEGER;
  uname TEXT;
  hash TEXT;
  perms JSONB;
  perm_block JSONB;
  row_out RECORD;
  is_new BOOLEAN := false;
  k TEXT;
  defaults JSONB := saas_super_admin_default_perms();
  write_key TEXT;
  write_keys TEXT[] := ARRAY[
    'companies_create', 'companies_edit', 'companies_delete', 'companies_suspend',
    'subscriptions_renew', 'subscriptions_delete',
    'users_manage',
    'platform_whatsapp', 'platform_announce', 'platform_announce_manage',
    'team_manage'
  ];
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF NOT saas_super_admin_can('team_manage') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  actor_id := auth_saas_user_id();
  uid := NULLIF((p_payload->>'id')::INTEGER, 0);

  uname := lower(trim(COALESCE(p_payload->>'username', '')));
  IF length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_required');
  END IF;

  IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname AND (uid IS NULL OR id <> uid)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  END IF;

  perm_block := defaults;
  IF p_payload ? 'permissions' AND jsonb_typeof(p_payload->'permissions') = 'object' THEN
    FOR k IN SELECT jsonb_object_keys(p_payload->'permissions')
    LOOP
      IF k = 'job_title' THEN
        perm_block := perm_block || jsonb_build_object('job_title', p_payload->'permissions'->>'job_title');
      ELSIF defaults ? k THEN
        perm_block := perm_block || jsonb_build_object(k, (p_payload->'permissions'->>k)::boolean);
      END IF;
    END LOOP;
  END IF;
  IF p_payload ? 'job_title' THEN
    perm_block := perm_block || jsonb_build_object('job_title', trim(p_payload->>'job_title'));
  END IF;

  IF COALESCE((perm_block->>'view_only')::boolean, false) THEN
    FOREACH write_key IN ARRAY write_keys LOOP
      perm_block := perm_block || jsonb_build_object(write_key, false);
    END LOOP;
  END IF;

  perms := jsonb_build_object('super_admin', perm_block);

  IF uid IS NULL THEN
    IF p_payload->>'password' IS NULL OR length(trim(p_payload->>'password')) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;
    hash := saas_hash_password_bcrypt(trim(p_payload->>'password'));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;
    is_new := true;
    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, company_id, permissions, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_payload->>'display_name'), ''), uname),
      NULLIF(trim(p_payload->>'email'), ''),
      hash, 'bcrypt',
      'super_admin', NULL, perms,
      COALESCE((p_payload->>'is_active')::boolean, true)
    )
    RETURNING * INTO row_out;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM saas_users WHERE id = uid AND role = 'super_admin') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_payload->>'display_name'), ''), display_name, uname),
      email = CASE WHEN p_payload ? 'email' THEN NULLIF(trim(p_payload->>'email'), '') ELSE email END,
      permissions = perms,
      is_active = COALESCE((p_payload->>'is_active')::boolean, is_active),
      updated_at = NOW()
    WHERE id = uid AND role = 'super_admin'
    RETURNING * INTO row_out;

    IF p_payload->>'password' IS NOT NULL AND length(trim(p_payload->>'password')) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_payload->>'password'));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'super_admin_created' ELSE 'super_admin_updated' END,
    'saas_users',
    'Super admin ' || row_out.username,
    COALESCE(row_out.display_name, row_out.username),
    row_out.id,
    NULL,
    jsonb_build_object('username', row_out.username, 'permissions', perm_block)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'id', row_out.id,
      'username', row_out.username,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'is_active', row_out.is_active,
      'permissions', perm_block
    )
  );
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
WHEN others THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_super_admin(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin(JSONB) TO authenticated;

-- END: 036_super_admin_view_only.sql

-- ============================================================
-- BEGIN: 037_auth_login_service_grants.sql
-- ============================================================

-- ============================================================
-- KYNO 037 — service_role EXECUTE on auth RPCs (Edge Functions)
-- Run if auth-login returns 401/500 after migration 027+
-- ============================================================

GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) TO service_role;

-- END: 037_auth_login_service_grants.sql

-- ============================================================
-- BEGIN: 038_company_user_password_fix.sql
-- ============================================================

-- ============================================================
-- KYNO 038 — Company user password verify + repair RPC
-- Fixes login failures when password_algo/hash mismatch after create
-- ============================================================

-- Backfill inconsistent rows (bcrypt hash vs legacy algo label)
UPDATE saas_users
SET password_algo = 'bcrypt'
WHERE password_hash LIKE '$2%'
  AND COALESCE(password_algo, 'legacy_b64') <> 'bcrypt';

UPDATE saas_users
SET password_algo = 'legacy_b64'
WHERE password_hash IS NOT NULL
  AND password_hash NOT LIKE '$2%'
  AND password_algo = 'bcrypt';

CREATE OR REPLACE FUNCTION saas_rehash_company_user_password(
  p_user_id INTEGER,
  p_company_id INTEGER,
  p_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  cid INTEGER := p_company_id;
  hash TEXT;
  stored TEXT;
BEGIN
  IF uid IS NULL OR uid <= 0 OR cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_required');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM saas_users
    WHERE id = uid AND company_id = cid AND role <> 'super_admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  hash := saas_hash_password_bcrypt(trim(p_password));
  IF hash IS NULL OR hash = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
  END IF;

  UPDATE saas_users
  SET password_hash = hash, password_algo = 'bcrypt'
  WHERE id = uid AND company_id = cid;

  SELECT password_hash INTO stored FROM saas_users WHERE id = uid LIMIT 1;
  IF stored IS NULL OR extensions.crypt(trim(p_password), stored) IS DISTINCT FROM stored THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
  END IF;

  RETURN jsonb_build_object('ok', true, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION saas_rehash_company_user_password(INTEGER, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_rehash_company_user_password(INTEGER, INTEGER, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  stored_hash TEXT;
  perms JSONB := COALESCE(p_permissions, '{}'::jsonb);
  row_out RECORD;
  active_chk JSONB;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT auth_is_super_admin() THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'subscription_inactive',
        'detail', COALESCE(active_chk->>'error', 'unknown')
      );
    END IF;
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
    SELECT password_hash INTO stored_hash FROM saas_users WHERE id = uid LIMIT 1;
    IF stored_hash IS NULL OR stored_hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
    END IF;
    IF extensions.crypt(trim(p_password), stored_hash) IS DISTINCT FROM stored_hash THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
      IF extensions.crypt(trim(p_password), hash) IS DISTINCT FROM hash THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', uname,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', cid,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

-- END: 038_company_user_password_fix.sql

-- ============================================================
-- BEGIN: 039_permissions_preserve_employee_devices.sql
-- ============================================================

-- ============================================================
-- KYNO 039 — Preserve permissions on partial user update + device cleanup
-- ============================================================

CREATE OR REPLACE FUNCTION auth_can_manage_tenant_users(p_company_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  actor_id INTEGER;
  actor_role TEXT;
  actor_cid INTEGER;
  actor_perms JSONB;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN FALSE;
  END IF;

  IF auth_is_super_admin() THEN
    RETURN saas_super_admin_can('users_manage');
  END IF;

  actor_id := auth_saas_user_id();
  IF actor_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT role, company_id, COALESCE(permissions, '{}'::jsonb)
  INTO actor_role, actor_cid, actor_perms
  FROM saas_users
  WHERE id = actor_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF actor_cid IS NULL OR actor_cid <> p_company_id THEN
    RETURN FALSE;
  END IF;

  IF actor_role IN ('company_admin', 'super_admin') THEN
    RETURN TRUE;
  END IF;

  IF actor_role = 'company_user' THEN
    IF COALESCE((actor_perms ->> 'users_permissions')::boolean, false) THEN
      RETURN TRUE;
    END IF;
    IF COALESCE((actor_perms ->> 'users_permissions_view')::boolean, false)
       OR COALESCE((actor_perms ->> 'users_permissions_add')::boolean, false)
       OR COALESCE((actor_perms ->> 'users_permissions_edit')::boolean, false)
       OR COALESCE((actor_perms ->> 'users_permissions_delete')::boolean, false) THEN
      RETURN TRUE;
    END IF;
  END IF;

  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_company_user(
  p_company_id INTEGER,
  p_username TEXT,
  p_display_name TEXT DEFAULT '',
  p_email TEXT DEFAULT NULL,
  p_role TEXT DEFAULT 'company_user',
  p_password TEXT DEFAULT NULL,
  p_permissions JSONB DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_user_id INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  uname TEXT := lower(trim(p_username));
  uid INTEGER := p_user_id;
  role_in TEXT := COALESCE(NULLIF(trim(p_role), ''), 'company_user');
  hash TEXT;
  stored_hash TEXT;
  perms JSONB;
  row_out RECORD;
  active_chk JSONB;
BEGIN
  IF cid IS NULL OR cid <= 0 OR uname IS NULL OR length(uname) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  IF role_in NOT IN ('company_user', 'company_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  IF NOT auth_can_manage_tenant_users(cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  IF NOT auth_is_super_admin() THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'subscription_inactive',
        'detail', COALESCE(active_chk->>'error', 'unknown')
      );
    END IF;
  END IF;

  IF uid IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM saas_users
      WHERE id = uid AND company_id = cid AND role <> 'super_admin'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
    END IF;

    perms := CASE
      WHEN p_permissions IS NULL THEN (
        SELECT COALESCE(permissions, '{}'::jsonb) FROM saas_users WHERE id = uid LIMIT 1
      )
      ELSE COALESCE(p_permissions, '{}'::jsonb)
    END;

    UPDATE saas_users SET
      username = uname,
      display_name = COALESCE(NULLIF(trim(p_display_name), ''), display_name, ''),
      email = NULLIF(trim(p_email), ''),
      role = role_in,
      permissions = perms,
      is_active = COALESCE(p_is_active, true)
    WHERE id = uid AND company_id = cid
    RETURNING * INTO row_out;

    IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM saas_users WHERE lower(username) = uname) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
    END IF;

    IF p_password IS NULL OR length(trim(p_password)) < 6 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_required');
    END IF;

    hash := saas_hash_password_bcrypt(trim(p_password));
    IF hash IS NULL OR hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
    END IF;

    perms := COALESCE(p_permissions, '{}'::jsonb);

    INSERT INTO saas_users (
      username, display_name, email, password_hash, password_algo,
      role, permissions, company_id, is_active
    ) VALUES (
      uname,
      COALESCE(NULLIF(trim(p_display_name), ''), uname),
      NULLIF(trim(p_email), ''),
      hash, 'bcrypt',
      role_in, perms, cid, COALESCE(p_is_active, true)
    )
    RETURNING * INTO row_out;
    uid := row_out.id;
  END IF;

  IF p_password IS NOT NULL AND length(trim(p_password)) >= 6 THEN
    SELECT password_hash INTO stored_hash FROM saas_users WHERE id = uid LIMIT 1;
    IF stored_hash IS NULL OR stored_hash = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
    END IF;
    IF extensions.crypt(trim(p_password), stored_hash) IS DISTINCT FROM stored_hash THEN
      hash := saas_hash_password_bcrypt(trim(p_password));
      IF hash IS NULL OR hash = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
      END IF;
      UPDATE saas_users SET password_hash = hash, password_algo = 'bcrypt' WHERE id = uid;
      IF extensions.crypt(trim(p_password), hash) IS DISTINCT FROM hash THEN
        RETURN jsonb_build_object('ok', false, 'error', 'password_verify_failed');
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', uid,
      'username', uname,
      'display_name', COALESCE(row_out.display_name, ''),
      'email', COALESCE(row_out.email, ''),
      'role', row_out.role,
      'permissions', COALESCE(row_out.permissions, '{}'::jsonb),
      'company_id', cid,
      'is_active', COALESCE(row_out.is_active, true)
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_delete_employee(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);

  DELETE FROM employee_devices WHERE employee_id = p_employee_id;
  DELETE FROM employees WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'employee_deleted', 'employees',
    'Deleted employee ' || p_employee_id::TEXT,
    emp.name,
    emp.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_company_user(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN, INTEGER) TO authenticated;

-- END: 039_permissions_preserve_employee_devices.sql

-- ============================================================
-- BEGIN: 040_session_profile_grants.sql
-- ============================================================

-- ============================================================
-- KYNO 040 — Session profile refresh for authenticated users
-- Fixes stale permissions after logout/login when restoreSession fails
-- ============================================================

CREATE OR REPLACE FUNCTION saas_get_user_profile(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  u RECORD;
  actor_id INTEGER;
  actor_role TEXT;
  actor_cid INTEGER;
BEGIN
  IF uid IS NULL OR uid <= 0 THEN
    RETURN NULL;
  END IF;

  actor_id := auth_saas_user_id();

  IF auth_is_super_admin() THEN
    NULL;
  ELSIF actor_id IS NOT NULL AND actor_id = uid THEN
    NULL;
  ELSE
    SELECT role, company_id INTO actor_role, actor_cid
    FROM saas_users
    WHERE id = actor_id AND is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    IF actor_role = 'company_admin' THEN
      IF NOT EXISTS (
        SELECT 1 FROM saas_users target
        WHERE target.id = uid AND target.company_id = actor_cid
      ) THEN
        RETURN NULL;
      END IF;
    ELSIF actor_role = 'company_user' THEN
      IF NOT auth_can_manage_tenant_users((
        SELECT company_id FROM saas_users WHERE id = uid LIMIT 1
      )) THEN
        RETURN NULL;
      END IF;
    ELSE
      RETURN NULL;
    END IF;
  END IF;

  SELECT su.id, su.username, su.display_name, su.email, su.role, su.permissions, su.company_id,
         c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE su.id = uid AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

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

REVOKE ALL ON FUNCTION saas_get_user_profile(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) TO authenticated, service_role;

-- END: 040_session_profile_grants.sql

-- ============================================================
-- BEGIN: 041_employee_delete_attendance.sql
-- ============================================================

-- ============================================================
-- KYNO 041 — Full employee delete (attendance + devices)
-- Prevents ghost data when re-adding employee with same id
-- ============================================================

CREATE OR REPLACE FUNCTION saas_delete_employee(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);

  DELETE FROM attendance WHERE employee_id = p_employee_id;
  DELETE FROM employee_devices WHERE employee_id = p_employee_id;
  DELETE FROM employees WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'employee_deleted', 'employees',
    'Deleted employee ' || p_employee_id::TEXT,
    emp.name,
    emp.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id);
END;
$$;

REVOKE ALL ON FUNCTION saas_delete_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_employee(INTEGER) TO authenticated;

-- END: 041_employee_delete_attendance.sql

-- ============================================================
-- BEGIN: 042_employee_salary_reset_on_upsert.sql
-- ============================================================

-- ============================================================
-- KYNO 042 — Reset stale salary fields on employee upsert
-- Fixes 500000 -> 499999 when re-adding employee (old biweekly half)
-- Run after 041
-- ============================================================

CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  st := COALESCE(NULLIF(trim(p_payload->>'salary_type'), ''), NULLIF(trim(p_payload->>'salaryType'), ''), 'monthly');
  sal := GREATEST(0, COALESCE((p_payload->>'salary')::INTEGER, 0));
  IF st = 'biweekly' THEN
    sal_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));
    IF sal_half = 0 AND sal > 0 THEN
      sal_half := sal / 2;
    END IF;
    IF sal_half > 0 THEN
      sal := sal_half * 2;
    END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN
      dr := GREATEST(0, sal_half / 15);
    END IF;
  ELSIF st = 'commission' THEN
    sal := 0;
    sal_half := 0;
    dr := 0;
  ELSE
    st := 'monthly';
    sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN
      dr := GREATEST(0, sal / 30);
    END IF;
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, (p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    RETURNING * INTO row;
    emp_id := row.id;
  END IF;

  after_row := to_jsonb(row);
  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,
    row.name,
    cid,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;

-- END: 042_employee_salary_reset_on_upsert.sql

-- ============================================================
-- BEGIN: 043_employee_client_profile_rpc.sql
-- ============================================================

-- ============================================================
-- KYNO 043 — Employee client profile (remote_attend / open_hours)
-- Allows employee phones (anon) to fetch authoritative flags from DB
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) TO anon, authenticated;

-- Include flags in QR resolve (phone registration path)
CREATE OR REPLACE FUNCTION saas_resolve_qr_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  sl SMALLINT := p_slot;
BEGIN
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, emp.id AS emp_id, emp.name AS emp_name, emp.dept, emp.company_id,
           emp.open_hours, emp.remote_attend, emp.check_in, emp.check_out
    INTO d
    FROM employee_devices ed
    JOIN employees emp ON emp.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'ok', true, 'source', 'token',
        'employee_id', d.emp_id, 'emp_name', d.emp_name, 'dept', d.dept,
        'company_id', d.company_id, 'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token, 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text,
        'open_hours', d.open_hours IS TRUE,
        'remote_attend', d.remote_attend IS TRUE,
        'check_in', d.check_in,
        'check_out', d.check_out
      );
    END IF;
  END IF;

  IF p_employee_id IS NOT NULL AND sl IS NOT NULL THEN
    SELECT id, name, dept, company_id, open_hours, remote_attend, check_in, check_out INTO e
    FROM employees WHERE id = p_employee_id LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
    END IF;

    SELECT ed.* INTO d
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id AND ed.slot = sl
    LIMIT 1;

    IF FOUND THEN
      IF tok IS NOT NULL AND length(tok) >= 10 AND (d.token IS NULL OR d.token <> tok) THEN
        UPDATE employee_devices SET
          token = tok,
          token_created_at = COALESCE(token_created_at, NOW()),
          fingerprint = '', ip = '',
          linked_at = NULL, token_used_at = NULL, last_login = NULL
        WHERE id = d.id;
        d.token := tok;
        d.fingerprint := '';
      END IF;

      RETURN jsonb_build_object(
        'ok', true, 'source', 'employee_slot',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', COALESCE(d.label, 'الهاتف ' || sl::text),
        'token', COALESCE(d.token, tok), 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
        'open_hours', e.open_hours IS TRUE,
        'remote_attend', e.remote_attend IS TRUE,
        'check_in', e.check_in,
        'check_out', e.check_out
      );
    END IF;

    IF tok IS NOT NULL AND length(tok) >= 10 THEN
      INSERT INTO employee_devices (
        employee_id, slot, label, token, token_created_at, company_id,
        fingerprint, ip, device_info
      ) VALUES (
        p_employee_id, sl, 'الهاتف ' || sl::text, tok, NOW(), COALESCE(e.company_id, 1),
        '', '', '{}'::jsonb
      )
      ON CONFLICT (employee_id, slot) DO UPDATE SET
        token = EXCLUDED.token,
        fingerprint = '', ip = '';

      RETURN jsonb_build_object(
        'ok', true, 'source', 'auto_created',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', 'الهاتف ' || sl::text,
        'token', tok, 'pin', NULL,
        'fingerprint', '', 'ip', '',
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
        'open_hours', e.open_hours IS TRUE,
        'remote_attend', e.remote_attend IS TRUE,
        'check_in', e.check_in,
        'check_out', e.check_out
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', true, 'source', 'employee_only',
      'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
      'company_id', e.company_id, 'slot', sl,
      'label', 'الهاتف ' || sl::text,
      'token', tok, 'pin', NULL,
      'fingerprint', '', 'ip', '',
      'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
      'open_hours', e.open_hours IS TRUE,
      'remote_attend', e.remote_attend IS TRUE,
      'check_in', e.check_in,
      'check_out', e.check_out
    );
  END IF;

  IF tok IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'token_not_found');
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_qr');
END;
$$;

REVOKE ALL ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

-- END: 043_employee_client_profile_rpc.sql

-- ============================================================
-- BEGIN: 044_employee_attendance_fetch_rpc.sql
-- ============================================================

-- ============================================================
-- KYNO 044 — Employee attendance fetch (anon/device authorized)
-- Keeps employee phone in sync after admin deletes attendance rows
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'employee_id', a.employee_id,
        'emp_name', a.emp_name,
        'dept', a.dept,
        'date_label', a.date_label,
        'date_iso', a.date_iso,
        'check_in', a.check_in,
        'check_out', a.check_out,
        'hours', a.hours,
        'late', a.late,
        'overtime', a.overtime,
        'status', a.status,
        'company_id', a.company_id
      )
      ORDER BY a.date_iso DESC
    ),
    '[]'::jsonb
  )
  INTO rows
  FROM (
    SELECT *
    FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC
    LIMIT lim
  ) a;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'records', rows
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_attendance(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

-- END: 044_employee_attendance_fetch_rpc.sql

-- ============================================================
-- BEGIN: 045_employee_notifications_fetch_rpc.sql
-- ============================================================

-- ============================================================
-- KYNO 045 — Employee finance notifications fetch (device authorized)
-- Syncs bonus/loan/deduction alerts to employee phone without admin JWT
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  filtered JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  settings_key := 'company:' || emp.company_id::TEXT || ':employee_notifications';

  SELECT value INTO raw_val
  FROM app_settings
  WHERE key = settings_key
  LIMIT 1;

  IF raw_val IS NULL OR btrim(raw_val) = '' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'employee_id', p_employee_id,
      'company_id', emp.company_id,
      'notifications', '[]'::jsonb
    );
  END IF;

  BEGIN
    arr := raw_val::jsonb;
    IF jsonb_typeof(arr) = 'string' THEN
      arr := (arr #>> '{}')::jsonb;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    arr := '[]'::jsonb;
  END;

  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' THEN
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(
    jsonb_agg(elem ORDER BY (elem->>'ts') DESC NULLS LAST),
    '[]'::jsonb
  )
  INTO filtered
  FROM (
    SELECT elem
    FROM jsonb_array_elements(arr) elem
    WHERE COALESCE((elem->>'empId')::INTEGER, (elem->>'emp_id')::INTEGER, 0) = p_employee_id
      AND (
        elem->>'companyId' IS NULL
        OR (elem->>'companyId')::INTEGER = emp.company_id
      )
    LIMIT lim
  ) sub;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'notifications', COALESCE(filtered, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

-- END: 045_employee_notifications_fetch_rpc.sql

-- ============================================================
-- BEGIN: 046_employee_salary_avatar_rpc.sql
-- ============================================================

-- ============================================================
-- KYNO 046 — Employee salary history fetch + avatar update (device authorized)
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_salary_records(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', sr.id,
        'employee_id', sr.employee_id,
        'company_id', sr.company_id,
        'month_iso', sr.month_iso,
        'month_label', sr.month_label,
        'base_salary', sr.base_salary,
        'attend_days', sr.attend_days,
        'late_minutes', sr.late_minutes,
        'late_deduct', sr.late_deduct,
        'absent_days', sr.absent_days,
        'overtime_amount', sr.overtime_amount,
        'bonus', sr.bonus,
        'total_deduct', sr.total_deduct,
        'net_salary', sr.net_salary,
        'status', sr.status,
        'issued_at', sr.issued_at
      )
      ORDER BY sr.month_iso DESC
    ),
    '[]'::jsonb
  )
  INTO rows
  FROM (
    SELECT *
    FROM salary_records s
    WHERE s.employee_id = p_employee_id
    ORDER BY s.month_iso DESC
    LIMIT lim
  ) sr;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'records', COALESCE(rows, '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_update_employee_avatar(
  p_employee_id INTEGER,
  p_avatar_url TEXT,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  url TEXT := NULLIF(trim(p_avatar_url), '');
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF url IS NULL OR length(url) < 24 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar');
  END IF;

  IF length(url) > 700000 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'avatar_too_large');
  END IF;

  IF url NOT LIKE 'data:image/%' AND url NOT LIKE 'http%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar_format');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  UPDATE employees
  SET avatar_url = url
  WHERE id = p_employee_id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'avatar_url', url
  );
END;
$$;

-- Include avatar in client profile fetch
CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_update_employee_avatar(INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_employee_avatar(INTEGER, TEXT, TEXT, TEXT) TO anon, authenticated;

-- END: 046_employee_salary_avatar_rpc.sql

-- ============================================================
-- BEGIN: 047_employee_salary_exact_monthly.sql
-- ============================================================

-- ============================================================
-- KYNO 047 — Exact monthly salary on upsert (no stale half drift)
-- Fixes 500000 -> 499999 when re-adding employees
-- ============================================================

CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
  payload_half INTEGER;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  st := COALESCE(NULLIF(trim(p_payload->>'salary_type'), ''), NULLIF(trim(p_payload->>'salaryType'), ''), 'monthly');
  sal := GREATEST(0, COALESCE((p_payload->>'salary')::INTEGER, 0));
  payload_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));

  IF st = 'biweekly' THEN
    sal_half := payload_half;
    IF sal_half = 0 AND sal > 0 THEN
      sal_half := sal / 2;
    END IF;
    IF sal_half > 0 THEN
      IF sal = 0 OR abs(sal - (sal_half * 2)) <= 1 THEN
        sal := sal_half * 2;
      ELSE
        sal_half := sal / 2;
        sal := sal_half * 2;
      END IF;
    END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN
      dr := GREATEST(0, sal_half / 15);
    END IF;
  ELSIF st = 'commission' THEN
    sal := 0;
    sal_half := 0;
    dr := 0;
  ELSE
    st := 'monthly';
    sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN
      dr := GREATEST(0, sal / 30);
    END IF;
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, (p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    RETURNING * INTO row;
    emp_id := row.id;
  END IF;

  after_row := to_jsonb(row);
  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,
    row.name,
    cid,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;

-- END: 047_employee_salary_exact_monthly.sql

-- ============================================================
-- BEGIN: 048_employee_gps_profile_login.sql
-- ============================================================

-- ============================================================
-- KYNO 048 — Employee client profile includes company GPS + login fix
-- Allows employee phones (device-authorized) to fetch GPS settings for check-in
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF emp.company_id IS NOT NULL THEN
    gps_prefix := 'company:' || emp.company_id::text || ':';
    SELECT value INTO v_lat FROM app_settings WHERE key = gps_prefix || 'gps_lat' LIMIT 1;
    SELECT value INTO v_lng FROM app_settings WHERE key = gps_prefix || 'gps_lng' LIMIT 1;
    SELECT value INTO v_range FROM app_settings WHERE key = gps_prefix || 'gps_range' LIMIT 1;
    SELECT value INTO v_name FROM app_settings WHERE key = gps_prefix || 'gps_name' LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url,
    'gps_lat', NULLIF(trim(v_lat), ''),
    'gps_lng', NULLIF(trim(v_lng), ''),
    'gps_range', NULLIF(trim(v_range), ''),
    'gps_name', NULLIF(trim(v_name), '')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) TO anon, authenticated;

-- END: 048_employee_gps_profile_login.sql

-- ============================================================
-- BEGIN: 049_biweekly_salary_no_rounding.sql
-- ============================================================

-- ============================================================
-- KYNO 049 — Fix biweekly salary rounding down (500000 → 499999)
-- Removes the <=1 alignment that rounds odd salaries down by 1
-- Run after 048
-- ============================================================

CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
  payload_half INTEGER;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  st := COALESCE(NULLIF(trim(p_payload->>'salary_type'), ''), NULLIF(trim(p_payload->>'salaryType'), ''), 'monthly');
  sal := GREATEST(0, COALESCE((p_payload->>'salary')::INTEGER, 0));
  payload_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));

  IF st = 'biweekly' THEN
    sal_half := payload_half;
    IF sal_half = 0 AND sal > 0 THEN
      sal_half := sal / 2;
    END IF;
    -- Do NOT modify sal to sal_half*2 — keep the user-entered salary exactly
    -- Only derive sal from sal_half if sal was not provided
    IF sal = 0 AND sal_half > 0 THEN
      sal := sal_half * 2;
    END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN
      dr := GREATEST(0, sal_half / 15);
    END IF;
  ELSIF st = 'commission' THEN
    sal := 0;
    sal_half := 0;
    dr := 0;
  ELSE
    st := 'monthly';
    sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN
      dr := GREATEST(0, sal / 30);
    END IF;
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, (p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    RETURNING * INTO row;
    emp_id := row.id;
  END IF;

  after_row := to_jsonb(row);
  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,
    row.name,
    cid,
    before_row,
    after_row
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_employee(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_employee(JSONB) TO authenticated;

-- END: 049_biweekly_salary_no_rounding.sql

-- ============================================================
-- BEGIN: 050_leaves_notifications.sql
-- ============================================================

-- ============================================================
-- KYNO 050 — Leaves & Notifications System
-- إضافة جداول الإجازات وإشعارات الموظفين والمسؤول
-- ============================================================

-- ─── جدول الإجازات ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS leaves (
  id           BIGSERIAL PRIMARY KEY,
  leave_ref    TEXT UNIQUE DEFAULT NULL,
  employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id   INTEGER NOT NULL REFERENCES companies(id),
  leave_type   TEXT NOT NULL
               CHECK (leave_type IN ('paid_open','unpaid_open','paid_single','unpaid_single','absence_mult')),
  from_date    DATE NOT NULL,
  to_date      DATE DEFAULT NULL,
  multiplier   INTEGER DEFAULT 1 CHECK (multiplier >= 1),
  note         TEXT DEFAULT '',
  added_at     TIMESTAMPTZ DEFAULT NOW(),
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_leaves_company   ON leaves(company_id);
CREATE INDEX IF NOT EXISTS idx_leaves_employee  ON leaves(employee_id);
CREATE INDEX IF NOT EXISTS idx_leaves_from_date ON leaves(from_date);

-- ─── جدول إشعارات الموظفين ────────────────────────────────
CREATE TABLE IF NOT EXISTS employee_notifications (
  id           BIGSERIAL PRIMARY KEY,
  notif_ref    TEXT UNIQUE DEFAULT NULL,
  employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id   INTEGER NOT NULL REFERENCES companies(id),
  notif_type   TEXT DEFAULT 'info',
  title        TEXT NOT NULL,
  body         TEXT DEFAULT '',
  is_read      BOOLEAN DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_emp_notif_emp    ON employee_notifications(employee_id);
CREATE INDEX IF NOT EXISTS idx_emp_notif_co     ON employee_notifications(company_id);

-- ─── جدول إشعارات المسؤول ─────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_notifications (
  id           BIGSERIAL PRIMARY KEY,
  company_id   INTEGER NOT NULL REFERENCES companies(id),
  notif_type   TEXT DEFAULT 'info',
  title        TEXT NOT NULL,
  body         TEXT DEFAULT '',
  is_read      BOOLEAN DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_notif_co   ON admin_notifications(company_id);

-- ─── RLS ──────────────────────────────────────────────────
ALTER TABLE leaves                ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leaves_company_policy            ON leaves;
DROP POLICY IF EXISTS emp_notif_company_policy         ON employee_notifications;
DROP POLICY IF EXISTS admin_notif_company_policy       ON admin_notifications;

CREATE POLICY leaves_company_policy ON leaves
  USING (company_id = auth_company_id() OR auth_is_super_admin());

CREATE POLICY emp_notif_company_policy ON employee_notifications
  USING (company_id = auth_company_id() OR auth_is_super_admin());

CREATE POLICY admin_notif_company_policy ON admin_notifications
  USING (company_id = auth_company_id() OR auth_is_super_admin());

-- ─── RPC: upsert leave ────────────────────────────────────
CREATE OR REPLACE FUNCTION saas_upsert_leave(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid      INTEGER;
  emp_row  employees%ROWTYPE;
  emp_id   INTEGER;
  leave_id BIGINT;
  ltype    TEXT;
  fdate    DATE;
  tdate    DATE;
  mult     INTEGER;
  ref_val  TEXT;
  row_out  leaves%ROWTYPE;
BEGIN
  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER,0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  emp_id  := NULLIF((p_payload->>'emp_id')::INTEGER, 0);
  ltype   := COALESCE(NULLIF(trim(p_payload->>'leave_type'),''),'paid_single');
  fdate   := (p_payload->>'from_date')::DATE;
  tdate   := NULLIF(p_payload->>'to_date','')::DATE;
  mult    := GREATEST(1, COALESCE((p_payload->>'multiplier')::INTEGER,1));
  ref_val := NULLIF(trim(p_payload->>'leave_ref'),'');
  leave_id:= NULLIF((p_payload->>'id')::BIGINT, 0);

  IF emp_id IS NULL OR fdate IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','missing_fields');
  END IF;

  SELECT * INTO emp_row FROM employees WHERE id=emp_id AND company_id=cid LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','employee_not_found');
  END IF;

  IF leave_id IS NOT NULL THEN
    UPDATE leaves SET
      leave_type  = ltype,
      from_date   = fdate,
      to_date     = tdate,
      multiplier  = mult,
      note        = COALESCE(p_payload->>'note',''),
      updated_at  = NOW()
    WHERE id=leave_id AND company_id=cid
    RETURNING * INTO row_out;
  ELSE
    INSERT INTO leaves(leave_ref, employee_id, company_id, leave_type, from_date, to_date, multiplier, note)
    VALUES(ref_val, emp_id, cid, ltype, fdate, tdate, mult, COALESCE(p_payload->>'note',''))
    ON CONFLICT(leave_ref) DO UPDATE SET
      leave_type = EXCLUDED.leave_type,
      from_date  = EXCLUDED.from_date,
      to_date    = EXCLUDED.to_date,
      multiplier = EXCLUDED.multiplier,
      note       = EXCLUDED.note,
      updated_at = NOW()
    RETURNING * INTO row_out;
  END IF;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(row_out));
END;
$$;

-- ─── RPC: delete leave ────────────────────────────────────
CREATE OR REPLACE FUNCTION saas_delete_leave(p_leave_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;
  DELETE FROM leaves WHERE id=p_leave_id AND (company_id=cid OR auth_is_super_admin());
  RETURN jsonb_build_object('ok',true);
END;
$$;

-- ─── RPC: get leaves ──────────────────────────────────────
CREATE OR REPLACE FUNCTION saas_get_leaves(p_employee_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  rows JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  SELECT jsonb_agg(to_jsonb(l) ORDER BY l.from_date DESC) INTO rows
  FROM leaves l
  WHERE l.company_id = cid
    AND (p_employee_id IS NULL OR l.employee_id = p_employee_id);

  RETURN jsonb_build_object('ok',true,'data', COALESCE(rows,'[]'::jsonb));
END;
$$;

-- ─── RPC: upsert employee notification ───────────────────
CREATE OR REPLACE FUNCTION saas_add_employee_notification(
  p_employee_id INTEGER,
  p_title       TEXT,
  p_body        TEXT DEFAULT '',
  p_type        TEXT DEFAULT 'info',
  p_ref         TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  row_out employee_notifications%ROWTYPE;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  IF p_ref IS NOT NULL THEN
    INSERT INTO employee_notifications(notif_ref, employee_id, company_id, notif_type, title, body)
    VALUES(p_ref, p_employee_id, cid, p_type, p_title, COALESCE(p_body,''))
    ON CONFLICT(notif_ref) DO UPDATE SET
      title = EXCLUDED.title,
      body  = EXCLUDED.body
    RETURNING * INTO row_out;
  ELSE
    INSERT INTO employee_notifications(employee_id, company_id, notif_type, title, body)
    VALUES(p_employee_id, cid, p_type, p_title, COALESCE(p_body,''))
    RETURNING * INTO row_out;
  END IF;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(row_out));
END;
$$;

-- ─── RPC: get employee notifications ─────────────────────
CREATE OR REPLACE FUNCTION saas_get_employee_notifications(p_employee_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  cid  INTEGER;
  rows JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  SELECT jsonb_agg(to_jsonb(n) ORDER BY n.created_at DESC) INTO rows
  FROM employee_notifications n
  WHERE n.company_id = cid
    AND (p_employee_id IS NULL OR n.employee_id = p_employee_id)
  LIMIT 200;

  RETURN jsonb_build_object('ok',true,'data', COALESCE(rows,'[]'::jsonb));
END;
$$;

-- ─── RPC: mark employee notification read ────────────────
CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(p_notif_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  UPDATE employee_notifications SET is_read=true
  WHERE id=p_notif_id AND company_id=cid;
  RETURN jsonb_build_object('ok',true);
END;
$$;

-- ─── RPC: add admin notification ─────────────────────────
CREATE OR REPLACE FUNCTION saas_add_admin_notification(
  p_title TEXT,
  p_body  TEXT DEFAULT '',
  p_type  TEXT DEFAULT 'info'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  row_out admin_notifications%ROWTYPE;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  INSERT INTO admin_notifications(company_id, notif_type, title, body)
  VALUES(cid, p_type, p_title, COALESCE(p_body,''))
  RETURNING * INTO row_out;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(row_out));
END;
$$;

-- ─── Grants ───────────────────────────────────────────────
REVOKE ALL ON FUNCTION saas_upsert_leave(JSONB)                                    FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_delete_leave(BIGINT)                                   FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_leaves(INTEGER)                                    FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_add_employee_notification(INTEGER,TEXT,TEXT,TEXT,TEXT)  FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_employee_notifications(INTEGER)                    FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT)                     FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_add_admin_notification(TEXT,TEXT,TEXT)                 FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_upsert_leave(JSONB)                                    TO authenticated;
GRANT EXECUTE ON FUNCTION saas_delete_leave(BIGINT)                                   TO authenticated;
GRANT EXECUTE ON FUNCTION saas_get_leaves(INTEGER)                                    TO authenticated;
GRANT EXECUTE ON FUNCTION saas_add_employee_notification(INTEGER,TEXT,TEXT,TEXT,TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION saas_get_employee_notifications(INTEGER)                    TO authenticated;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT)                     TO authenticated;
GRANT EXECUTE ON FUNCTION saas_add_admin_notification(TEXT,TEXT,TEXT)                 TO authenticated;

-- END: 050_leaves_notifications.sql

-- ============================================================
-- BEGIN: 051_employee_leave_notifications_fetch.sql
-- ============================================================

-- ============================================================
-- KYNO 051 — Include leave notifications in device-auth fetch
-- Merges employee_notifications table into saas_fetch_employee_notifications
-- ============================================================

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  filtered JSONB;
  merged JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  settings_key := 'company:' || emp.company_id::TEXT || ':employee_notifications';

  SELECT value INTO raw_val
  FROM app_settings
  WHERE key = settings_key
  LIMIT 1;

  arr := '[]'::jsonb;
  IF raw_val IS NOT NULL AND btrim(raw_val) <> '' THEN
    BEGIN
      arr := raw_val::jsonb;
      IF jsonb_typeof(arr) = 'string' THEN
        arr := (arr #>> '{}')::jsonb;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      arr := '[]'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(arr) IS DISTINCT FROM 'array' THEN
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(
    jsonb_agg(elem ORDER BY COALESCE((elem->>'ts')::BIGINT, 0) DESC NULLS LAST),
    '[]'::jsonb
  )
  INTO filtered
  FROM (
    SELECT elem
    FROM jsonb_array_elements(arr) elem
    WHERE COALESCE((elem->>'empId')::INTEGER, (elem->>'emp_id')::INTEGER, 0) = p_employee_id
      AND (
        elem->>'companyId' IS NULL
        OR (elem->>'companyId')::INTEGER = emp.company_id
      )
  ) sub;

  SELECT COALESCE(
    jsonb_agg(elem ORDER BY COALESCE((elem->>'ts')::BIGINT, 0) DESC NULLS LAST),
    '[]'::jsonb
  )
  INTO merged
  FROM (
    SELECT elem
    FROM (
      SELECT elem
      FROM jsonb_array_elements(COALESCE(filtered, '[]'::jsonb)) elem
      UNION ALL
      SELECT jsonb_build_object(
        'id', COALESCE(n.notif_ref, 'sbn_' || n.id::TEXT),
        'empId', n.employee_id,
        'type', n.notif_type,
        'title', n.title,
        'body', COALESCE(n.body, ''),
        'unread', CASE WHEN n.is_read THEN FALSE ELSE TRUE END,
        'read', n.is_read,
        'ts', (EXTRACT(EPOCH FROM n.created_at) * 1000)::BIGINT,
        '_remoteId', n.id,
        'companyId', n.company_id
      ) AS elem
      FROM employee_notifications n
      WHERE n.employee_id = p_employee_id
        AND n.company_id = emp.company_id
    ) combined
    ORDER BY COALESCE((elem->>'ts')::BIGINT, 0) DESC NULLS LAST
    LIMIT lim
  ) limited_rows;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'notifications', COALESCE(merged, '[]'::jsonb)
  );
END;
$$;

-- Allow marking read by table id OR notif_ref
DROP FUNCTION IF EXISTS saas_mark_emp_notification_read(BIGINT);

CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id
      AND (cid IS NULL OR cid <= 0 OR company_id = cid);
    RETURN jsonb_build_object('ok', true);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref)
      AND (cid IS NULL OR cid <= 0 OR company_id = cid);
    RETURN jsonb_build_object('ok', true);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) TO authenticated, anon;

-- END: 051_employee_leave_notifications_fetch.sql

-- ============================================================
-- BEGIN: 052_fix_baghdad_attendance_time.sql
-- ============================================================

-- ============================================================
-- KYNO 052 — Fix Baghdad timezone for attendance punch times
-- Supabase runs in UTC; old timezone() cast caused wrong wall clock
-- ============================================================

CREATE OR REPLACE FUNCTION basma_server_now_baghdad()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  SELECT now();
$$;

CREATE OR REPLACE FUNCTION basma_date_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
  SELECT (now() AT TIME ZONE 'Asia/Baghdad')::date;
$$;

CREATE OR REPLACE FUNCTION basma_format_time_ampm(ts TIMESTAMPTZ)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(ts AT TIME ZONE 'Asia/Baghdad', 'HH12:MI AM');
$$;

-- END: 052_fix_baghdad_attendance_time.sql

-- ============================================================
-- BEGIN: 053_overtime_excluded_from_net_salary.sql
-- ============================================================

-- ============================================================
-- KYNO 053 — الإضافي يُعرض منفصلاً ولا يُضاف إلى الراتب الصافي
-- ============================================================

CREATE OR REPLACE FUNCTION saas_v3_compute_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  bounds RECORD;
  att RECORD;
  attend_days INTEGER := 0;
  recorded_absent INTEGER := 0;
  total_late_min INTEGER := 0;
  total_ot_min INTEGER := 0;
  expected_absent INTEGER := 0;
  absent_days INTEGER := 0;
  is_comm BOOLEAN;
  is_biw BOOLEAN;
  base_period_salary INTEGER;
  daily_rate INTEGER;
  base_salary INTEGER := 0;
  late_deduct_rate INTEGER;
  ot_hourly INTEGER;
  late_deduct INTEGER := 0;
  absent_deduct INTEGER := 0;
  ot_amount INTEGER := 0;
  bonus INTEGER := 0;
  fin JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT * INTO bounds FROM saas_v3_period_bounds(
    COALESCE(p_month, CASE WHEN emp.salary_type = 'biweekly' THEN
      to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
      CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
    ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END),
    COALESCE(emp.salary_type, 'monthly')
  );

  is_comm := COALESCE(emp.salary_type, 'monthly') = 'commission';
  is_biw := COALESCE(emp.salary_type, 'monthly') = 'biweekly';
  base_period_salary := CASE
    WHEN is_comm THEN 0
    WHEN is_biw THEN GREATEST(0, COALESCE(NULLIF(emp.salary_half, 0), emp.salary / 2))
    ELSE GREATEST(0, COALESCE(emp.salary, 0))
  END;
  daily_rate := CASE
    WHEN is_comm THEN 0
    WHEN COALESCE(emp.daily_rate, 0) > 0 THEN emp.daily_rate
    WHEN is_biw THEN GREATEST(0, base_period_salary / 15)
    ELSE GREATEST(0, base_period_salary / 30)
  END;

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= bounds.period_end
  LOOP
    IF att.check_in IS NOT NULL AND att.check_in <> '—' THEN
      attend_days := attend_days + 1;
      IF NOT is_comm AND emp.open_hours IS NOT TRUE THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        IF att.late IS NOT NULL AND att.late <> '—' THEN
          total_late_min := total_late_min + saas_v3_parse_late_minutes(att.late);
        END IF;
      END IF;
    ELSIF att.status = 'غياب' THEN
      recorded_absent := recorded_absent + 1;
    END IF;
  END LOOP;

  IF is_comm OR emp.open_hours IS TRUE THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(0, bounds.elapsed_days - attend_days - recorded_absent);
  END IF;
  absent_days := recorded_absent + expected_absent;

  IF is_comm THEN
    base_salary := 0;
  ELSE
    base_salary := base_period_salary;
  END IF;

  late_deduct_rate := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'late_deduct_rate'), '')::INTEGER, 700));
  ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));

  IF is_comm OR emp.open_hours IS TRUE THEN
    late_deduct := 0;
    absent_deduct := 0;
    ot_amount := 0;
  ELSE
    late_deduct := ROUND(total_late_min * late_deduct_rate);
    absent_deduct := ROUND(absent_days * daily_rate);
    ot_amount := ROUND((total_ot_min / 60.0) * ot_hourly);
  END IF;

  fin := saas_v3_finance_totals(emp.company_id, p_employee_id, bounds.month_iso);
  manual_deduct := COALESCE((fin->>'deductions')::INTEGER, 0);
  loan_deduct := COALESCE((fin->>'loans')::INTEGER, 0);
  bonus := GREATEST(0, COALESCE(emp.sal_bonus, 0)) + COALESCE((fin->>'bonuses')::INTEGER, 0);
  total_deduct := late_deduct + absent_deduct + manual_deduct + loan_deduct;

  IF is_comm THEN
    net_salary := bonus;
  ELSE
    -- overtime_amount يُحفظ للعرض فقط — لا يُضاف إلى net_salary
    net_salary := GREATEST(0, base_salary + bonus - total_deduct);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'month_iso', bounds.month_iso,
    'month_label', bounds.month_label,
    'base_salary', base_salary,
    'attend_days', attend_days,
    'absent_days', absent_days,
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'absent_deduct', absent_deduct,
    'manual_deduct', manual_deduct,
    'loan_deduct', loan_deduct,
    'overtime_amount', ot_amount,
    'bonus', bonus,
    'total_deduct', total_deduct,
    'net_salary', net_salary,
    'daily_rate', daily_rate,
    'period_days', bounds.total_days,
    'elapsed_days', bounds.elapsed_days
  );
END;
$$;

-- END: 053_overtime_excluded_from_net_salary.sql

-- ============================================================
-- BEGIN: 054_realtime_leaves.sql
-- ============================================================

-- ============================================================
-- KYNO 054 — Realtime على جدول الإجازات للمزامنة الفورية
-- ============================================================

ALTER TABLE IF EXISTS public.leaves REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.leaves;
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END;
  END IF;
END $$;

-- END: 054_realtime_leaves.sql

-- ============================================================
-- BEGIN: 055_standard_month_days_setting.sql
-- ============================================================

-- ============================================================
-- KYNO 055 — إعداد «أيام الشهر المعتمدة» (month_days)
-- يُستخدم في المعدل اليومي، الغياب، فترات الراتب، ونصف الشهر
-- ============================================================

CREATE OR REPLACE FUNCTION saas_v3_standard_month_days(p_company_id INTEGER)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
  SELECT LEAST(31, GREATEST(20, COALESCE(
    NULLIF(saas_v3_company_setting(p_company_id, 'month_days'), '')::INTEGER,
    30
  )));
$$;

CREATE OR REPLACE FUNCTION saas_v3_biweekly_split_days(p_company_id INTEGER)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(1, saas_v3_standard_month_days(p_company_id) / 2);
$$;

CREATE OR REPLACE FUNCTION saas_v3_period_bounds(
  p_month TEXT,
  p_salary_type TEXT DEFAULT 'monthly',
  p_company_id INTEGER DEFAULT NULL
)
RETURNS TABLE(
  period_start DATE,
  period_end DATE,
  elapsed_days INTEGER,
  total_days INTEGER,
  month_iso TEXT,
  month_label TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  y INTEGER;
  mo INTEGER;
  half TEXT;
  today DATE := basma_date_iso_baghdad();
  ms TEXT[] := ARRAY['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
  mkey TEXT := COALESCE(NULLIF(trim(p_month), ''), to_char(today, 'YYYY-MM'));
  stype TEXT := COALESCE(NULLIF(trim(p_salary_type), ''), 'monthly');
  month_days_val INTEGER := saas_v3_standard_month_days(p_company_id);
  biw_split INTEGER := saas_v3_biweekly_split_days(p_company_id);
  cal_end DATE;
  cal_end_day INTEGER;
BEGIN
  IF mkey ~ '-H[12]$' THEN
    y := split_part(split_part(mkey, '-H', 1), '-', 1)::INTEGER;
    mo := split_part(split_part(mkey, '-H', 1), '-', 2)::INTEGER;
    half := substring(mkey from '-H([12])$');
    cal_end := (date_trunc('month', make_date(y, mo, 1)) + INTERVAL '1 month - 1 day')::DATE;
    cal_end_day := EXTRACT(DAY FROM cal_end)::INTEGER;
    IF half = '1' THEN
      period_start := make_date(y, mo, 1);
      period_end := make_date(y, mo, LEAST(biw_split, cal_end_day));
      total_days := biw_split;
    ELSE
      period_start := make_date(y, mo, LEAST(biw_split + 1, cal_end_day));
      period_end := cal_end;
      total_days := GREATEST(1, month_days_val - biw_split);
    END IF;
    month_iso := mkey;
    month_label := ms[mo] || ' ' || y::TEXT || ' (' || CASE WHEN half = '1' THEN 'النصف الأول' ELSE 'النصف الثاني' END || ')';
  ELSE
    y := split_part(mkey, '-', 1)::INTEGER;
    mo := split_part(mkey, '-', 2)::INTEGER;
    period_start := make_date(y, mo, 1);
    period_end := (date_trunc('month', period_start) + INTERVAL '1 month - 1 day')::DATE;
    total_days := month_days_val;
    month_iso := to_char(period_start, 'YYYY-MM');
    month_label := ms[mo] || ' ' || y::TEXT;
  END IF;

  IF today < period_start THEN
    elapsed_days := 0;
  ELSIF today > period_end THEN
    elapsed_days := total_days;
  ELSE
    elapsed_days := GREATEST(1, (today - period_start)::INTEGER + 1);
    IF stype = 'biweekly' AND mkey ~ '-H[12]$' THEN
      IF substring(mkey from '-H([12])$') = '1' THEN
        elapsed_days := LEAST(elapsed_days, biw_split);
      ELSE
        elapsed_days := LEAST(GREATEST(1, EXTRACT(DAY FROM today)::INTEGER - biw_split), total_days);
      END IF;
    ELSIF stype = 'monthly' THEN
      elapsed_days := LEAST(elapsed_days, month_days_val);
    END IF;
  END IF;

  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  bounds RECORD;
  att RECORD;
  attend_days INTEGER := 0;
  recorded_absent INTEGER := 0;
  total_late_min INTEGER := 0;
  total_ot_min INTEGER := 0;
  expected_absent INTEGER := 0;
  absent_days INTEGER := 0;
  is_comm BOOLEAN;
  is_biw BOOLEAN;
  base_period_salary INTEGER;
  daily_rate INTEGER;
  base_salary INTEGER := 0;
  late_deduct_rate INTEGER;
  ot_hourly INTEGER;
  late_deduct INTEGER := 0;
  absent_deduct INTEGER := 0;
  ot_amount INTEGER := 0;
  bonus INTEGER := 0;
  fin JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
  month_days_val INTEGER;
  biw_days INTEGER;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  month_days_val := saas_v3_standard_month_days(emp.company_id);
  biw_days := saas_v3_biweekly_split_days(emp.company_id);

  SELECT * INTO bounds FROM saas_v3_period_bounds(
    COALESCE(p_month, CASE WHEN emp.salary_type = 'biweekly' THEN
      to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
      CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= biw_days THEN '-H1' ELSE '-H2' END
    ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END),
    COALESCE(emp.salary_type, 'monthly'),
    emp.company_id
  );

  is_comm := COALESCE(emp.salary_type, 'monthly') = 'commission';
  is_biw := COALESCE(emp.salary_type, 'monthly') = 'biweekly';
  base_period_salary := CASE
    WHEN is_comm THEN 0
    WHEN is_biw THEN GREATEST(0, COALESCE(NULLIF(emp.salary_half, 0), emp.salary / 2))
    ELSE GREATEST(0, COALESCE(emp.salary, 0))
  END;
  daily_rate := CASE
    WHEN is_comm THEN 0
    WHEN COALESCE(emp.daily_rate, 0) > 0 THEN emp.daily_rate
    WHEN is_biw THEN GREATEST(0, base_period_salary / biw_days)
    ELSE GREATEST(0, base_period_salary / month_days_val)
  END;

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= bounds.period_end
  LOOP
    IF att.check_in IS NOT NULL AND att.check_in <> '—' THEN
      attend_days := attend_days + 1;
      IF NOT is_comm AND emp.open_hours IS NOT TRUE THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        IF att.late IS NOT NULL AND att.late <> '—' THEN
          total_late_min := total_late_min + saas_v3_parse_late_minutes(att.late);
        END IF;
      END IF;
    ELSIF att.status = 'غياب' THEN
      recorded_absent := recorded_absent + 1;
    END IF;
  END LOOP;

  IF is_comm OR emp.open_hours IS TRUE THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(0, bounds.elapsed_days - attend_days - recorded_absent);
  END IF;
  absent_days := recorded_absent + expected_absent;

  IF is_comm THEN
    base_salary := 0;
  ELSE
    base_salary := base_period_salary;
  END IF;

  late_deduct_rate := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'late_deduct_rate'), '')::INTEGER, 700));
  ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));

  IF is_comm OR emp.open_hours IS TRUE THEN
    late_deduct := 0;
    absent_deduct := 0;
    ot_amount := 0;
  ELSE
    late_deduct := ROUND(total_late_min * late_deduct_rate);
    absent_deduct := ROUND(absent_days * daily_rate);
    ot_amount := ROUND((total_ot_min / 60.0) * ot_hourly);
  END IF;

  fin := saas_v3_finance_totals(emp.company_id, p_employee_id, bounds.month_iso);
  manual_deduct := COALESCE((fin->>'deductions')::INTEGER, 0);
  loan_deduct := COALESCE((fin->>'loans')::INTEGER, 0);
  bonus := GREATEST(0, COALESCE(emp.sal_bonus, 0)) + COALESCE((fin->>'bonuses')::INTEGER, 0);
  total_deduct := late_deduct + absent_deduct + manual_deduct + loan_deduct;

  IF is_comm THEN
    net_salary := bonus;
  ELSE
    net_salary := GREATEST(0, base_salary + bonus - total_deduct);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'month_iso', bounds.month_iso,
    'month_label', bounds.month_label,
    'base_salary', base_salary,
    'attend_days', attend_days,
    'absent_days', absent_days,
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'absent_deduct', absent_deduct,
    'manual_deduct', manual_deduct,
    'loan_deduct', loan_deduct,
    'overtime_amount', ot_amount,
    'bonus', bonus,
    'total_deduct', total_deduct,
    'net_salary', net_salary,
    'daily_rate', daily_rate,
    'period_days', bounds.total_days,
    'elapsed_days', bounds.elapsed_days
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
  payload_half INTEGER;
  month_days_val INTEGER;
  biw_days INTEGER;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  month_days_val := saas_v3_standard_month_days(cid);
  biw_days := saas_v3_biweekly_split_days(cid);

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  st := COALESCE(NULLIF(trim(p_payload->>'salary_type'), ''), NULLIF(trim(p_payload->>'salaryType'), ''), 'monthly');
  sal := GREATEST(0, COALESCE((p_payload->>'salary')::INTEGER, 0));
  payload_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));

  IF st = 'biweekly' THEN
    sal_half := payload_half;
    IF sal_half = 0 AND sal > 0 THEN
      sal_half := sal / 2;
    END IF;
    IF sal = 0 AND sal_half > 0 THEN
      sal := sal_half * 2;
    END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN
      dr := GREATEST(0, sal_half / biw_days);
    END IF;
  ELSIF st = 'commission' THEN
    sal := 0;
    sal_half := 0;
    dr := 0;
  ELSE
    st := 'monthly';
    sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN
      dr := GREATEST(0, sal / month_days_val);
    END IF;
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, (p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', '')
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),

      NULLIF(p_payload->>'avatar_url', '')

    )

    RETURNING * INTO row;

    emp_id := row.id;

  END IF;



  after_row := to_jsonb(row);

  PERFORM saas_v3_write_audit(

    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,

    'employees',

    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,

    row.name,

    cid,

    before_row,

    after_row

  );



  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);

END;

$$;

-- END: 055_standard_month_days_setting.sql

-- ============================================================
-- BEGIN: 056_phase1_critical_production.sql
-- ============================================================

-- ============================================================
-- KYNO 056 — Phase 1 Critical Production Fixes
-- Payroll (leaves + loans + OT flag), Audit, RLS, Subscription, Export
-- ============================================================

-- 1) Employee overtime inclusion flag
ALTER TABLE employees
  ADD COLUMN IF NOT EXISTS include_overtime_in_salary BOOLEAN NOT NULL DEFAULT FALSE;

-- ----------------------------------------------------------
-- 2) Leave deductions (matches client leave types)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_leave_days_in_period(
  p_from DATE,
  p_to DATE,
  p_period_start DATE,
  p_period_end DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  eff_from DATE;
  eff_to DATE;
BEGIN
  IF p_from IS NULL THEN RETURN 1; END IF;
  eff_from := GREATEST(p_from, p_period_start);
  eff_to := LEAST(COALESCE(p_to, p_from), p_period_end);
  IF eff_to < eff_from THEN RETURN 0; END IF;
  RETURN GREATEST(1, (eff_to - eff_from) + 1);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_leave_deductions(
  p_employee_id INTEGER,
  p_company_id INTEGER,
  p_period_start DATE,
  p_period_end DATE,
  p_daily_rate INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lv RECORD;
  leave_deduct INTEGER := 0;
  leave_days INTEGER := 0;
  items JSONB := '[]'::JSONB;
  days_count INTEGER;
  deduct_amt INTEGER;
  mult INTEGER;
  lbl TEXT;
BEGIN
  IF p_daily_rate IS NULL OR p_daily_rate <= 0 THEN
    RETURN jsonb_build_object('leave_deduct', 0, 'leave_days', 0, 'leave_items', '[]'::jsonb);
  END IF;

  FOR lv IN
    SELECT l.*
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = p_company_id
      AND l.from_date <= p_period_end
      AND COALESCE(l.to_date, l.from_date) >= p_period_start
  LOOP
    days_count := saas_v3_leave_days_in_period(lv.from_date, lv.to_date, p_period_start, p_period_end);
    deduct_amt := 0;
    lbl := COALESCE(lv.leave_type, 'paid_single');

    IF lbl = 'unpaid_open' THEN
      deduct_amt := ROUND(days_count * p_daily_rate);
      leave_days := leave_days + days_count;
    ELSIF lbl = 'unpaid_single' THEN
      deduct_amt := p_daily_rate;
      leave_days := leave_days + 1;
    ELSIF lbl = 'absence_mult' THEN
      mult := GREATEST(1, COALESCE(lv.multiplier, 1));
      deduct_amt := ROUND(mult * p_daily_rate);
      leave_days := leave_days + 1;
      lbl := lbl || ' (×' || mult::TEXT || ')';
    ELSE
      -- paid_open, paid_single — annual/sick paid: no deduction
      CONTINUE;
    END IF;

    IF deduct_amt > 0 THEN
      leave_deduct := leave_deduct + deduct_amt;
      items := items || jsonb_build_array(jsonb_build_object(
        'label', lbl,
        'days', days_count,
        'deduct', deduct_amt,
        'leave_type', lv.leave_type
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'leave_deduct', leave_deduct,
    'leave_days', leave_days,
    'leave_items', items
  );
END;
$$;

-- ----------------------------------------------------------
-- 3) Loan installment (matches client currentLoanInstallmentAmount)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_loan_current_installment(p_item JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  amt INTEGER;
  cnt INTEGER;
  paid INTEGER;
  normal INTEGER;
  paid_amount INTEGER;
  remaining INTEGER;
  mode TEXT;
BEGIN
  IF p_item IS NULL OR COALESCE(p_item->>'type', '') <> 'loan' THEN RETURN 0; END IF;
  amt := GREATEST(0, COALESCE((p_item->>'amount')::INTEGER, 0));
  mode := COALESCE(p_item->>'loanMode', p_item->>'loan_mode', '');
  IF mode <> 'installments' THEN RETURN amt; END IF;

  cnt := GREATEST(1, COALESCE((p_item->>'installmentCount')::INTEGER, (p_item->>'installment_count')::INTEGER, 1));
  paid := GREATEST(0, COALESCE((p_item->>'paidInstallments')::INTEGER, (p_item->>'paid_installments')::INTEGER, 0));
  IF paid >= cnt THEN RETURN 0; END IF;

  normal := GREATEST(0, COALESCE((p_item->>'installmentAmount')::INTEGER, (p_item->>'installment_amount')::INTEGER, 0));
  IF normal = 0 THEN normal := GREATEST(0, amt / cnt); END IF;

  paid_amount := normal * paid;
  remaining := GREATEST(0, amt - paid_amount);
  IF paid = cnt - 1 THEN RETURN remaining; END IF;
  RETURN LEAST(normal, remaining);
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_loan_remaining_balance(p_item JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  amt INTEGER;
  cnt INTEGER;
  paid INTEGER;
  normal INTEGER;
BEGIN
  IF p_item IS NULL OR COALESCE(p_item->>'type', '') <> 'loan' THEN RETURN 0; END IF;
  amt := GREATEST(0, COALESCE((p_item->>'amount')::INTEGER, 0));
  IF COALESCE(p_item->>'loanMode', p_item->>'loan_mode', '') <> 'installments' THEN
    IF COALESCE(p_item->>'status', '') IN ('مسدد', 'ملغي') THEN RETURN 0; END IF;
    RETURN amt;
  END IF;
  cnt := GREATEST(1, COALESCE((p_item->>'installmentCount')::INTEGER, (p_item->>'installment_count')::INTEGER, 1));
  paid := GREATEST(0, COALESCE((p_item->>'paidInstallments')::INTEGER, (p_item->>'paid_installments')::INTEGER, 0));
  normal := GREATEST(0, COALESCE((p_item->>'installmentAmount')::INTEGER, (p_item->>'installment_amount')::INTEGER, 0));
  IF normal = 0 THEN normal := GREATEST(0, amt / cnt); END IF;
  RETURN GREATEST(0, amt - (normal * paid));
END;
$$;

-- ----------------------------------------------------------
-- 4) Finance totals — unified loan logic + detail payload
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_finance_totals(
  p_company_id INTEGER,
  p_employee_id INTEGER,
  p_period_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  raw TEXT;
  arr JSONB;
  item JSONB;
  deductions INTEGER := 0;
  bonuses INTEGER := 0;
  loans INTEGER := 0;
  amt INTEGER;
  status TEXT;
  iperiod TEXT;
  inst INTEGER;
  loan_items JSONB := '[]'::jsonb;
BEGIN
  raw := saas_v3_company_setting(p_company_id, 'finance_items');
  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;
  BEGIN
    arr := raw::JSONB;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(arr)
  LOOP
    IF COALESCE((item->>'empId')::INTEGER, (item->>'emp_id')::INTEGER, 0) <> p_employee_id THEN
      CONTINUE;
    END IF;
    status := COALESCE(item->>'status', '');
    IF status IN ('ملغي', 'مسدد') THEN CONTINUE; END IF;
    iperiod := COALESCE(item->>'period', '');
    amt := GREATEST(0, COALESCE((item->>'amount')::INTEGER, 0));

    IF COALESCE(item->>'type', '') = 'bonus' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        bonuses := bonuses + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'deduction' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        deductions := deductions + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'loan' THEN
      inst := saas_v3_loan_current_installment(item);
      IF inst > 0 THEN
        loans := loans + inst;
        loan_items := loan_items || jsonb_build_array(jsonb_build_object(
          'id', item->>'id',
          'amount', amt,
          'installment_count', COALESCE((item->>'installmentCount')::INTEGER, (item->>'installment_count')::INTEGER, 1),
          'paid_installments', COALESCE((item->>'paidInstallments')::INTEGER, (item->>'paid_installments')::INTEGER, 0),
          'current_installment', inst,
          'remaining_balance', saas_v3_loan_remaining_balance(item),
          'loan_mode', COALESCE(item->>'loanMode', item->>'loan_mode', 'lump'),
          'status', status
        ));
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'deductions', deductions,
    'bonuses', bonuses,
    'loans', loans,
    'loan_items', loan_items
  );
END;
$$;

-- ----------------------------------------------------------
-- 5) Subscription enforcement inside tenant assert
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_assert_tenant(p_row_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER := auth_company_id();
  active_chk JSONB;
BEGIN
  IF auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', true, 'super_admin', true);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  IF p_row_company_id IS NULL OR p_row_company_id <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', COALESCE(active_chk->>'error', 'subscription_inactive'),
      'detail', active_chk
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'company_id', cid);
END;
$$;

-- ----------------------------------------------------------
-- 6) Enhanced audit writer
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL,
  p_entity_type TEXT DEFAULT NULL,
  p_entity_id TEXT DEFAULT NULL,
  p_ip_address TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
  cid INTEGER;
BEGIN
  cid := p_company_id;
  IF (cid IS NULL OR cid <= 0) THEN
    cid := auth_company_id();
  END IF;

  meta := jsonb_build_object(
    'company_id', cid,
    'timestamp', to_jsonb(NOW()),
    'entity_type', NULLIF(trim(p_entity_type), ''),
    'entity_id', NULLIF(trim(p_entity_id), ''),
    'old_value', COALESCE(p_before, 'null'::jsonb),
    'new_value', COALESCE(p_after, 'null'::jsonb),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta,
    ip_address, user_agent
  ) VALUES (
    cid,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    meta,
    NULLIF(trim(p_ip_address), ''),
    NULLIF(trim(p_user_agent), '')
  );
EXCEPTION
  WHEN others THEN
    NULL;
END;
$$;

CREATE OR REPLACE FUNCTION saas_record_client_audit(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  action TEXT;
  active_chk JSONB;
BEGIN
  cid := auth_company_id();
  IF (cid IS NULL OR cid <= 0) AND auth_is_super_admin() THEN
    cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT auth_is_super_admin() THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(active_chk->>'error', 'subscription_inactive'));
    END IF;
  END IF;

  action := COALESCE(NULLIF(trim(p_payload->>'action'), ''), 'client_event');
  PERFORM saas_v3_write_audit(
    action,
    COALESCE(NULLIF(trim(p_payload->>'category'), ''), 'client'),
    COALESCE(p_payload->>'details', action),
    COALESCE(p_payload->>'target_name', ''),
    cid,
    p_payload->'old_value',
    p_payload->'new_value',
    p_payload->>'entity_type',
    p_payload->>'entity_id',
    p_payload->>'ip_address',
    p_payload->>'user_agent'
  );
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ----------------------------------------------------------
-- 7) Authoritative payroll compute
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_compute_salary(
  p_employee_id INTEGER,
  p_month TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  bounds RECORD;
  att RECORD;
  attend_days INTEGER := 0;
  recorded_absent INTEGER := 0;
  total_late_min INTEGER := 0;
  total_ot_min INTEGER := 0;
  expected_absent INTEGER := 0;
  absent_days INTEGER := 0;
  is_comm BOOLEAN;
  is_biw BOOLEAN;
  base_period_salary INTEGER;
  daily_rate INTEGER;
  base_salary INTEGER := 0;
  late_deduct_rate INTEGER;
  ot_hourly INTEGER;
  late_deduct INTEGER := 0;
  absent_deduct INTEGER := 0;
  ot_amount INTEGER := 0;
  bonus INTEGER := 0;
  fin JSONB;
  leave_info JSONB;
  manual_deduct INTEGER := 0;
  loan_deduct INTEGER := 0;
  leave_deduct INTEGER := 0;
  total_deduct INTEGER := 0;
  net_salary INTEGER := 0;
  tenant JSONB;
  month_days_val INTEGER;
  biw_days INTEGER;
  include_ot BOOLEAN := FALSE;
BEGIN
  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  include_ot := COALESCE(emp.include_overtime_in_salary, false);
  month_days_val := saas_v3_standard_month_days(emp.company_id);
  biw_days := saas_v3_biweekly_split_days(emp.company_id);

  SELECT * INTO bounds FROM saas_v3_period_bounds(
    COALESCE(p_month, CASE WHEN emp.salary_type = 'biweekly' THEN
      to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
      CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= biw_days THEN '-H1' ELSE '-H2' END
    ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END),
    COALESCE(emp.salary_type, 'monthly'),
    emp.company_id
  );

  is_comm := COALESCE(emp.salary_type, 'monthly') = 'commission';
  is_biw := COALESCE(emp.salary_type, 'monthly') = 'biweekly';
  base_period_salary := CASE
    WHEN is_comm THEN 0
    WHEN is_biw THEN GREATEST(0, COALESCE(NULLIF(emp.salary_half, 0), emp.salary / 2))
    ELSE GREATEST(0, COALESCE(emp.salary, 0))
  END;
  daily_rate := CASE
    WHEN is_comm THEN 0
    WHEN COALESCE(emp.daily_rate, 0) > 0 THEN emp.daily_rate
    WHEN is_biw THEN GREATEST(0, base_period_salary / biw_days)
    ELSE GREATEST(0, base_period_salary / month_days_val)
  END;

  FOR att IN
    SELECT a.*
    FROM attendance a
    WHERE a.employee_id = p_employee_id
      AND a.date_iso >= bounds.period_start
      AND a.date_iso <= bounds.period_end
  LOOP
    IF att.check_in IS NOT NULL AND att.check_in <> '—' THEN
      attend_days := attend_days + 1;
      IF NOT is_comm AND emp.open_hours IS NOT TRUE THEN
        total_ot_min := total_ot_min + saas_v3_parse_ot_minutes(att.overtime);
        IF att.late IS NOT NULL AND att.late <> '—' THEN
          total_late_min := total_late_min + saas_v3_parse_late_minutes(att.late);
        END IF;
      END IF;
    ELSIF att.status = 'غياب' THEN
      recorded_absent := recorded_absent + 1;
    END IF;
  END LOOP;

  IF is_comm OR emp.open_hours IS TRUE THEN
    expected_absent := 0;
  ELSE
    expected_absent := GREATEST(0, bounds.elapsed_days - attend_days - recorded_absent);
  END IF;
  absent_days := recorded_absent + expected_absent;

  IF is_comm THEN
    base_salary := 0;
  ELSE
    base_salary := base_period_salary;
  END IF;

  late_deduct_rate := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'late_deduct_rate'), '')::INTEGER, 700));
  ot_hourly := GREATEST(0, COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'overtime_hourly_rate'), '')::INTEGER, 30000));

  IF is_comm OR emp.open_hours IS TRUE THEN
    late_deduct := 0;
    absent_deduct := 0;
    ot_amount := 0;
  ELSE
    late_deduct := ROUND(total_late_min * late_deduct_rate);
    absent_deduct := ROUND(absent_days * daily_rate);
    ot_amount := ROUND((total_ot_min / 60.0) * ot_hourly);
  END IF;

  leave_info := saas_v3_compute_leave_deductions(
    p_employee_id, emp.company_id, bounds.period_start, bounds.period_end, daily_rate
  );
  leave_deduct := COALESCE((leave_info->>'leave_deduct')::INTEGER, 0);

  fin := saas_v3_finance_totals(emp.company_id, p_employee_id, bounds.month_iso);
  manual_deduct := COALESCE((fin->>'deductions')::INTEGER, 0);
  loan_deduct := COALESCE((fin->>'loans')::INTEGER, 0);
  bonus := GREATEST(0, COALESCE(emp.sal_bonus, 0)) + COALESCE((fin->>'bonuses')::INTEGER, 0);
  total_deduct := late_deduct + absent_deduct + leave_deduct + manual_deduct + loan_deduct;

  IF is_comm THEN
    net_salary := bonus + CASE WHEN include_ot THEN ot_amount ELSE 0 END;
  ELSE
    net_salary := GREATEST(0, base_salary + bonus - total_deduct + CASE WHEN include_ot THEN ot_amount ELSE 0 END);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'company_id', emp.company_id,
    'month_iso', bounds.month_iso,
    'month_label', bounds.month_label,
    'base_salary', base_salary,
    'attend_days', attend_days,
    'absent_days', absent_days,
    'late_minutes', total_late_min,
    'overtime_minutes', total_ot_min,
    'late_deduct', late_deduct,
    'absent_deduct', absent_deduct,
    'leave_deduct', leave_deduct,
    'leave_days', COALESCE((leave_info->>'leave_days')::INTEGER, 0),
    'leave_items', COALESCE(leave_info->'leave_items', '[]'::jsonb),
    'manual_deduct', manual_deduct,
    'loan_deduct', loan_deduct,
    'loan_items', COALESCE(fin->'loan_items', '[]'::jsonb),
    'overtime_amount', ot_amount,
    'overtime_in_net', include_ot,
    'include_overtime_in_salary', include_ot,
    'bonus', bonus,
    'total_deduct', total_deduct,
    'net_salary', net_salary,
    'daily_rate', daily_rate,
    'period_days', bounds.total_days,
    'elapsed_days', bounds.elapsed_days
  );
END;
$$;

-- ----------------------------------------------------------
-- 8) Employee upsert — include_overtime_in_salary
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_employee(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  active_chk JSONB;
  lim_chk JSONB;
  emp_id INTEGER;
  before_row JSONB;
  after_row JSONB;
  is_new BOOLEAN := false;
  row employees%ROWTYPE;
  st TEXT;
  sal INTEGER;
  sal_half INTEGER;
  dr INTEGER;
  payload_half INTEGER;
  month_days_val INTEGER;
  biw_days INTEGER;
  include_ot BOOLEAN := FALSE;
BEGIN
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  month_days_val := saas_v3_standard_month_days(cid);
  biw_days := saas_v3_biweekly_split_days(cid);
  include_ot := COALESCE(
    (p_payload->>'include_overtime_in_salary')::BOOLEAN,
    (p_payload->>'includeOvertimeInSalary')::BOOLEAN,
    false
  );

  emp_id := NULLIF((p_payload->>'id')::INTEGER, 0);

  IF emp_id IS NOT NULL THEN
    SELECT to_jsonb(e.*) INTO before_row FROM employees e WHERE e.id = emp_id LIMIT 1;
    IF before_row IS NULL THEN
      is_new := true;
    ELSE
      IF NOT auth_is_super_admin() AND (before_row->>'company_id')::INTEGER <> cid THEN
        RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
      END IF;
      tenant := saas_v3_assert_tenant((before_row->>'company_id')::INTEGER);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
    END IF;
  ELSE
    is_new := true;
  END IF;

  IF is_new THEN
    lim_chk := saas_assert_employee_limit(cid);
    IF COALESCE((lim_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(lim_chk->>'error', 'employee_limit_reached'));
    END IF;
  END IF;

  active_chk := saas_assert_company_active(cid);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  st := COALESCE(NULLIF(trim(p_payload->>'salary_type'), ''), NULLIF(trim(p_payload->>'salaryType'), ''), 'monthly');
  sal := GREATEST(0, COALESCE((p_payload->>'salary')::INTEGER, 0));
  payload_half := GREATEST(0, COALESCE((p_payload->>'salary_half')::INTEGER, (p_payload->>'salaryHalf')::INTEGER, 0));

  IF st = 'biweekly' THEN
    sal_half := payload_half;
    IF sal_half = 0 AND sal > 0 THEN sal_half := sal / 2; END IF;
    IF sal = 0 AND sal_half > 0 THEN sal := sal_half * 2; END IF;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal_half > 0 THEN dr := GREATEST(0, sal_half / biw_days); END IF;
  ELSIF st = 'commission' THEN
    sal := 0; sal_half := 0; dr := 0;
  ELSE
    st := 'monthly'; sal_half := 0;
    dr := GREATEST(0, COALESCE((p_payload->>'daily_rate')::INTEGER, (p_payload->>'dailyRate')::INTEGER, 0));
    IF dr = 0 AND sal > 0 THEN dr := GREATEST(0, sal / month_days_val); END IF;
  END IF;

  IF emp_id IS NOT NULL THEN
    INSERT INTO employees (
      id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
    ) VALUES (
      emp_id, cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', ''),
      include_ot
    )
    ON CONFLICT (id) DO UPDATE SET
      company_id = cid,
      name = EXCLUDED.name,
      dept = EXCLUDED.dept,
      role = EXCLUDED.role,
      phone = EXCLUDED.phone,
      salary = EXCLUDED.salary,
      salary_type = EXCLUDED.salary_type,
      salary_half = EXCLUDED.salary_half,
      daily_rate = EXCLUDED.daily_rate,
      days = EXCLUDED.days,
      late_min = EXCLUDED.late_min,
      check_in = EXCLUDED.check_in,
      check_out = EXCLUDED.check_out,
      open_hours = EXCLUDED.open_hours,
      remote_attend = EXCLUDED.remote_attend,
      sal_status = EXCLUDED.sal_status,
      sal_bonus = EXCLUDED.sal_bonus,
      sal_deleted_period = EXCLUDED.sal_deleted_period,
      avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
      include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
      updated_at = NOW()
    RETURNING * INTO row;
  ELSE
    INSERT INTO employees (
      company_id, name, dept, role, phone, salary, salary_type, salary_half,
      daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
      sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
    ) VALUES (
      cid,
      COALESCE(p_payload->>'name', ''),
      COALESCE(p_payload->>'dept', ''),
      COALESCE(p_payload->>'role', ''),
      COALESCE(p_payload->>'phone', '—'),
      sal, st, sal_half, dr,
      COALESCE((p_payload->>'days')::INTEGER, 0),
      COALESCE((p_payload->>'late_min')::INTEGER, (p_payload->>'lateMin')::INTEGER, 0),
      COALESCE(p_payload->>'check_in', p_payload->>'checkIn', '08:00')::TIME,
      COALESCE(p_payload->>'check_out', p_payload->>'checkOut', '17:00')::TIME,
      COALESCE((p_payload->>'open_hours')::BOOLEAN, (p_payload->>'openHours')::BOOLEAN, false),
      COALESCE((p_payload->>'remote_attend')::BOOLEAN, (p_payload->>'remoteAttend')::BOOLEAN, false),
      COALESCE(p_payload->>'sal_status', p_payload->>'salStatus', 'معلق'),
      COALESCE((p_payload->>'sal_bonus')::INTEGER, (p_payload->>'salBonus')::INTEGER, 0),
      COALESCE(p_payload->>'sal_deleted_period', p_payload->>'salDeletedPeriod', ''),
      NULLIF(p_payload->>'avatar_url', ''),
      include_ot
    )
    RETURNING * INTO row;
    emp_id := row.id;
  END IF;

  after_row := to_jsonb(row);
  PERFORM saas_v3_write_audit(
    CASE WHEN is_new THEN 'employee_created' ELSE 'employee_updated' END,
    'employees',
    CASE WHEN is_new THEN 'Created employee ' || emp_id::TEXT ELSE 'Updated employee ' || emp_id::TEXT END,
    row.name,
    cid,
    before_row,
    after_row,
    'employees',
    emp_id::TEXT,
    p_payload->>'ip_address',
    p_payload->>'user_agent'
  );

  RETURN jsonb_build_object('ok', true, 'data', after_row, 'is_new', is_new);
END;
$$;

-- ----------------------------------------------------------
-- 9) Company export / import (JSON via RPC — no Storage bucket)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_export_company_data()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  payload JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  payload := jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'exported_at', NOW(),
    'version', '056',
    'employees', COALESCE((SELECT jsonb_agg(to_jsonb(e.*) ORDER BY e.id) FROM employees e WHERE e.company_id = cid), '[]'::jsonb),
    'attendance', COALESCE((SELECT jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso) FROM attendance a WHERE a.company_id = cid), '[]'::jsonb),
    'salary_records', COALESCE((SELECT jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso) FROM salary_records s WHERE s.company_id = cid), '[]'::jsonb),
    'leaves', COALESCE((SELECT jsonb_agg(to_jsonb(l.*) ORDER BY l.from_date) FROM leaves l WHERE l.company_id = cid), '[]'::jsonb),
    'departments', COALESCE((SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.name) FROM departments d WHERE d.company_id = cid), '[]'::jsonb),
    'settings', COALESCE((
      SELECT jsonb_object_agg(
        replace(s.key, 'company:' || cid::text || ':', ''),
        s.value
      )
      FROM app_settings s
      WHERE s.key LIKE ('company:' || cid::text || ':%')
    ), '{}'::jsonb)
  );

  PERFORM saas_v3_write_audit('company_export', 'backup', 'Exported company data', 'company:' || cid::TEXT, cid, NULL, jsonb_build_object('exported_at', NOW()), 'company', cid::TEXT, NULL, NULL);
  RETURN payload;
END;
$$;

-- Import merges settings + finance only; employees/attendance require existing RPCs (safety)
CREATE OR REPLACE FUNCTION saas_import_company_settings(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  file_cid INTEGER;
  settings JSONB;
  k TEXT;
  v TEXT;
  cnt INTEGER := 0;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch');
  END IF;

  settings := p_payload->'settings';
  IF settings IS NULL OR jsonb_typeof(settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
  LOOP
    IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':' || k, v, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END LOOP;

  PERFORM saas_v3_write_audit('company_import', 'backup', 'Imported company settings (' || cnt::TEXT || ' keys)', 'company:' || cid::TEXT, cid, NULL, settings, 'company', cid::TEXT, NULL, NULL);
  RETURN jsonb_build_object('ok', true, 'imported_keys', cnt);
END;
$$;

-- ----------------------------------------------------------
-- 10) RLS alignment — leaves + notifications (030 model)
-- ----------------------------------------------------------
ALTER TABLE leaves ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leaves_company_policy ON leaves;
DROP POLICY IF EXISTS emp_notif_company_policy ON employee_notifications;
DROP POLICY IF EXISTS admin_notif_company_policy ON admin_notifications;

DROP POLICY IF EXISTS deny_anon_leaves ON leaves;
DROP POLICY IF EXISTS leaves_tenant_only ON leaves;
DROP POLICY IF EXISTS leaves_super_admin ON leaves;

CREATE POLICY deny_anon_leaves ON leaves
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY leaves_tenant_only ON leaves
  FOR ALL TO authenticated
  USING (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id())
  WITH CHECK (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id());

CREATE POLICY leaves_super_admin ON leaves
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

DROP POLICY IF EXISTS deny_anon_employee_notifications ON employee_notifications;
DROP POLICY IF EXISTS emp_notif_tenant_only ON employee_notifications;
DROP POLICY IF EXISTS emp_notif_super_admin ON employee_notifications;

CREATE POLICY deny_anon_employee_notifications ON employee_notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY emp_notif_tenant_only ON employee_notifications
  FOR ALL TO authenticated
  USING (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id())
  WITH CHECK (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id());

CREATE POLICY emp_notif_super_admin ON employee_notifications
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

DROP POLICY IF EXISTS deny_anon_admin_notifications ON admin_notifications;
DROP POLICY IF EXISTS admin_notif_tenant_only ON admin_notifications;
DROP POLICY IF EXISTS admin_notif_super_admin ON admin_notifications;

CREATE POLICY deny_anon_admin_notifications ON admin_notifications
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY admin_notif_tenant_only ON admin_notifications
  FOR ALL TO authenticated
  USING (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id())
  WITH CHECK (auth_company_id() IS NOT NULL AND company_id IS NOT NULL AND company_id = auth_company_id());

CREATE POLICY admin_notif_super_admin ON admin_notifications
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

-- ----------------------------------------------------------
-- 11) Grants
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_record_client_audit(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_record_client_audit(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_export_company_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_export_company_data() TO authenticated;

REVOKE ALL ON FUNCTION saas_import_company_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_settings(JSONB) TO authenticated;

-- END: 056_phase1_critical_production.sql

-- ============================================================
-- BEGIN: 057_phase2_production_hardening.sql
-- ============================================================

-- ============================================================
-- KYNO 057 — Phase 2: Production Hardening & Commercial Launch
-- Plans, security health report, full backup import, employee portal locks,
-- settings versioning audit, enhanced super-admin audit
-- ============================================================

-- ----------------------------------------------------------
-- 1) Subscription plans (Starter / Business / Enterprise)
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS subscription_plans (
  plan_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  max_employees INTEGER NOT NULL DEFAULT 25,
  max_storage_mb INTEGER NOT NULL DEFAULT 512,
  reports_level TEXT NOT NULL DEFAULT 'basic',
  features JSONB NOT NULL DEFAULT '{}'::jsonb,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO subscription_plans (plan_id, display_name, max_employees, max_storage_mb, reports_level, features, sort_order)
VALUES
  ('starter', 'Starter', 25, 512, 'basic',
    '{"employees":true,"attendance":true,"salaries":true,"leaves":true,"finance":true,"reports_basic":true,"reports_advanced":false,"export_pdf":true,"export_excel":false,"notifications":true,"multi_user":false,"api_access":false}'::jsonb, 1),
  ('business', 'Business', 100, 2048, 'standard',
    '{"employees":true,"attendance":true,"salaries":true,"leaves":true,"finance":true,"reports_basic":true,"reports_advanced":true,"export_pdf":true,"export_excel":true,"notifications":true,"multi_user":true,"api_access":false}'::jsonb, 2),
  ('enterprise', 'Enterprise', 500, 10240, 'full',
    '{"employees":true,"attendance":true,"salaries":true,"leaves":true,"finance":true,"reports_basic":true,"reports_advanced":true,"export_pdf":true,"export_excel":true,"notifications":true,"multi_user":true,"api_access":true}'::jsonb, 3)
ON CONFLICT (plan_id) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  max_employees = EXCLUDED.max_employees,
  max_storage_mb = EXCLUDED.max_storage_mb,
  reports_level = EXCLUDED.reports_level,
  features = EXCLUDED.features,
  sort_order = EXCLUDED.sort_order,
  updated_at = NOW();

ALTER TABLE companies ADD COLUMN IF NOT EXISTS plan_tier TEXT DEFAULT 'starter';

UPDATE companies SET plan_tier = 'starter' WHERE plan_tier IS NULL OR trim(plan_tier) = '';

-- Resolve effective plan limits for a company
CREATE OR REPLACE FUNCTION saas_get_plan_limits(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  comp RECORD;
  plan subscription_plans%ROWTYPE;
  tier TEXT;
  eff_max INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO comp FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  tier := lower(trim(COALESCE(comp.plan_tier, 'starter')));
  SELECT * INTO plan FROM subscription_plans WHERE plan_id = tier AND is_active = TRUE LIMIT 1;
  IF NOT FOUND THEN
    SELECT * INTO plan FROM subscription_plans WHERE plan_id = 'starter' LIMIT 1;
  END IF;

  eff_max := CASE
    WHEN comp.max_employees IS NOT NULL AND comp.max_employees > 0 THEN comp.max_employees
    ELSE COALESCE(plan.max_employees, 25)
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', p_company_id,
    'plan_tier', tier,
    'plan_name', plan.display_name,
    'max_employees', eff_max,
    'max_storage_mb', plan.max_storage_mb,
    'reports_level', plan.reports_level,
    'features', plan.features
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_assert_plan_feature(p_company_id INTEGER, p_feature TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lim JSONB;
  feat TEXT := lower(trim(COALESCE(p_feature, '')));
  enabled BOOLEAN;
BEGIN
  IF auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', true, 'super_admin', true);
  END IF;

  lim := saas_get_plan_limits(p_company_id);
  IF COALESCE((lim->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN lim;
  END IF;

  IF feat = '' THEN
    RETURN jsonb_build_object('ok', true, 'limits', lim);
  END IF;

  enabled := COALESCE((lim->'features'->>feat)::BOOLEAN, false);
  IF NOT enabled THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'plan_feature_denied',
      'feature', feat,
      'plan_tier', lim->>'plan_tier'
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'feature', feat, 'limits', lim);
END;
$$;

-- Employee limit uses plan when companies.max_employees is unset
CREATE OR REPLACE FUNCTION saas_assert_employee_limit(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lim INTEGER := 0;
  cnt INTEGER := 0;
  plan_lim JSONB;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  plan_lim := saas_get_plan_limits(p_company_id);
  lim := COALESCE((plan_lim->>'max_employees')::INTEGER, 0);

  IF lim IS NULL OR lim <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'unlimited', true);
  END IF;

  SELECT COUNT(*) INTO cnt FROM employees WHERE company_id = p_company_id;

  IF cnt >= lim THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'employee_limit_reached',
      'limit', lim,
      'count', cnt,
      'plan_tier', plan_lim->>'plan_tier'
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'limit', lim, 'count', cnt, 'plan_tier', plan_lim->>'plan_tier');
END;
$$;

-- ----------------------------------------------------------
-- 2) Employee portal — subscription gate on fetch RPCs
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_employee_portal_subscription_ok(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN saas_assert_company_active(p_company_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id, 'employee_id', a.employee_id, 'emp_name', a.emp_name,
        'dept', a.dept, 'date_label', a.date_label, 'date_iso', a.date_iso,
        'check_in', a.check_in, 'check_out', a.check_out, 'hours', a.hours,
        'late', a.late, 'overtime', a.overtime, 'status', a.status, 'company_id', a.company_id
      ) ORDER BY a.date_iso DESC
    ), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC LIMIT lim
  ) a;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

CREATE OR REPLACE FUNCTION saas_fetch_employee_salary_records(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso DESC), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM salary_records sr
    WHERE sr.employee_id = p_employee_id
    ORDER BY sr.month_iso DESC LIMIT lim
  ) s;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  filtered JSONB;
  merged JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  settings_key := 'company:' || emp.company_id::text || ':employeeNotifications';
  SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  IF raw_val IS NOT NULL AND raw_val <> '' THEN
    BEGIN arr := raw_val::jsonb; EXCEPTION WHEN others THEN arr := '[]'::jsonb; END;
  ELSE arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(x ORDER BY (x->>'createdAt') DESC NULLS LAST), '[]'::jsonb)
  INTO filtered
  FROM jsonb_array_elements(COALESCE(arr, '[]'::jsonb)) x
  WHERE (x->>'empId')::text = p_employee_id::text
     OR (x->>'emp_id')::text = p_employee_id::text
  LIMIT lim;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', n.id, 'employee_id', n.employee_id, 'title', n.title,
        'body', n.body, 'type', n.type, 'is_read', n.is_read,
        'created_at', n.created_at, 'company_id', n.company_id, '_source', 'table'
      ) ORDER BY n.created_at DESC
    ), '[]'::jsonb
  ) INTO merged
  FROM (
    SELECT * FROM employee_notifications en
    WHERE en.employee_id = p_employee_id AND en.company_id = emp.company_id
    ORDER BY en.created_at DESC LIMIT lim
  ) n;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'settings_notifications', COALESCE(filtered, '[]'::jsonb),
    'table_notifications', COALESCE(merged, '[]'::jsonb)
  );
END;
$$;

-- ----------------------------------------------------------
-- 3) Settings versioning — old_value / new_value in audit
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_tenant_settings(p_settings JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  k TEXT;
  v TEXT;
  db_key TEXT;
  cnt INTEGER := 0;
  old_snapshot JSONB := '{}'::jsonb;
  new_snapshot JSONB := '{}'::jsonb;
  old_val TEXT;
  audit_keys TEXT[] := ARRAY[
    'companyName', 'lateDeductPerMin', 'absentDeduct', 'overtimeRate',
    'biweeklySplitDay', 'standardMonthDays', 'finance_items', 'leaveSettings',
    'departments_json', 'jobs_json', 'gpsLat', 'gpsLng', 'gpsRange'
  ];
  is_audit_key BOOLEAN;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(p_settings)
  LOOP
    IF k IS NULL OR k = '' THEN CONTINUE; END IF;
    db_key := 'company:' || cid::text || ':' || k;
    SELECT s.value INTO old_val FROM app_settings s WHERE s.key = db_key LIMIT 1;
    IF old_val IS NOT NULL THEN
      old_snapshot := old_snapshot || jsonb_build_object(k, old_val);
    END IF;
    new_snapshot := new_snapshot || jsonb_build_object(k, v);
    INSERT INTO app_settings (key, value, updated_at)
    VALUES (db_key, v, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END LOOP;

  PERFORM saas_v3_write_audit(
    'settings_updated', 'settings',
    'Updated ' || cnt::text || ' tenant settings (versioned)',
    'company:' || cid::text,
    cid,
    old_snapshot,
    new_snapshot,
    'company_settings',
    cid::TEXT,
    NULL,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

-- ----------------------------------------------------------
-- 4) Super Admin — plan tier + max_employees audit on company upsert
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_super_upsert_company(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  before_row JSONB;
  after_row companies%ROWTYPE;
  new_code TEXT;
  new_tier TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF p_payload IS NULL OR p_payload = 'null'::jsonb THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := NULLIF((p_payload->>'id')::INTEGER, 0);
  IF cid IS NULL THEN
    IF NOT saas_super_admin_can('companies_create') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  ELSE
    IF NOT saas_super_admin_can('companies_edit') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
  END IF;

  new_code := upper(trim(COALESCE(p_payload->>'company_code', p_payload->>'code', '')));
  new_tier := lower(trim(COALESCE(p_payload->>'plan_tier', p_payload->>'plan', '')));

  IF cid IS NOT NULL THEN
    SELECT to_jsonb(c.*) INTO before_row FROM companies c WHERE c.id = cid LIMIT 1;
    IF before_row IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;

    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), company_name),
      company_code = CASE WHEN new_code <> '' THEN new_code ELSE company_code END,
      status = COALESCE(NULLIF(trim(p_payload->>'status'), ''), status),
      max_employees = COALESCE((p_payload->>'max_employees')::INTEGER, max_employees),
      plan_tier = CASE WHEN new_tier <> '' AND new_tier IN ('starter', 'business', 'enterprise') THEN new_tier ELSE plan_tier END,
      notes = COALESCE(p_payload->>'notes', notes),
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO after_row;
  ELSE
    IF new_code = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_code_required');
    END IF;
    INSERT INTO companies (company_name, company_code, status, max_employees, plan_tier, notes)
    VALUES (
      COALESCE(NULLIF(trim(p_payload->>'company_name'), ''), NULLIF(trim(p_payload->>'name'), ''), 'شركة جديدة'),
      new_code,
      COALESCE(NULLIF(trim(p_payload->>'status'), ''), 'pending'),
      COALESCE((p_payload->>'max_employees')::INTEGER, 25),
      CASE WHEN new_tier IN ('starter', 'business', 'enterprise') THEN new_tier ELSE 'starter' END,
      COALESCE(p_payload->>'notes', '')
    )
    RETURNING * INTO after_row;
    before_row := NULL;
  END IF;

  PERFORM saas_v3_write_audit(
    CASE WHEN cid IS NULL THEN 'company_created' ELSE 'company_updated' END,
    'companies',
    CASE WHEN cid IS NULL THEN 'Created company' ELSE 'Updated company limits/plan' END,
    after_row.company_name,
    after_row.id,
    before_row,
    to_jsonb(after_row),
    'companies',
    after_row.id::TEXT,
    NULL,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(after_row));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_code_duplicate');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_renew_subscription(
  p_company_id INTEGER,
  p_duration_days INTEGER DEFAULT 30,
  p_amount INTEGER DEFAULT 0,
  p_notes TEXT DEFAULT NULL,
  p_plan_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing RECORD;
  before_sub JSONB;
  after_sub JSONB;
  start_d DATE;
  end_d DATE;
  dur_days INTEGER := GREATEST(1, COALESCE(p_duration_days, 30));
  pay_amt INTEGER := GREATEST(0, COALESCE(p_amount, 0));
  dur_months INTEGER;
  note_text TEXT;
  actor TEXT;
  sub_id INTEGER;
  plan_nm TEXT := NULLIF(trim(p_plan_name), '');
  comp_before JSONB;
  comp_after companies%ROWTYPE;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_renew') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO existing FROM subscriptions
  WHERE company_id = p_company_id
  ORDER BY created_at DESC NULLS LAST, id DESC LIMIT 1;

  before_sub := CASE WHEN existing.id IS NOT NULL THEN to_jsonb(existing) ELSE NULL END;

  dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
  note_text := COALESCE(NULLIF(trim(p_notes), ''), 'تمديد ' || dur_days::text || ' يوم');
  actor := COALESCE(
    (saas_super_admin_sender_meta()->>'senderName'),
    auth.jwt() -> 'app_metadata' ->> 'display_name',
    auth.jwt() ->> 'email',
    'system'
  );

  IF existing.id IS NOT NULL AND existing.status = 'active' AND existing.end_date >= CURRENT_DATE THEN
    start_d := existing.start_date;
    end_d := existing.end_date + dur_days;
    UPDATE subscriptions SET
      start_date = start_d, end_date = end_d, status = 'active',
      duration_months = dur_months, amount = pay_amt, notes = note_text,
      plan_name = COALESCE(plan_nm, plan_name),
      activated_by = actor, updated_at = NOW()
    WHERE id = existing.id RETURNING id INTO sub_id;
  ELSIF existing.id IS NOT NULL THEN
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    UPDATE subscriptions SET
      start_date = start_d, end_date = end_d, status = 'active',
      duration_months = dur_months, amount = pay_amt, notes = note_text,
      plan_name = COALESCE(plan_nm, plan_name),
      activated_by = actor, updated_at = NOW()
    WHERE id = existing.id RETURNING id INTO sub_id;
  ELSE
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    INSERT INTO subscriptions (
      company_id, plan_name, start_date, end_date, status,
      duration_months, amount, notes, activated_by
    ) VALUES (
      p_company_id, COALESCE(plan_nm, 'starter'), start_d, end_d, 'active',
      dur_months, pay_amt, note_text, actor
    ) RETURNING id INTO sub_id;
  END IF;

  SELECT to_jsonb(s.*) INTO after_sub FROM subscriptions s WHERE s.id = sub_id LIMIT 1;

  IF plan_nm IS NOT NULL AND lower(plan_nm) IN ('starter', 'business', 'enterprise') THEN
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = p_company_id LIMIT 1;
    UPDATE companies SET plan_tier = lower(plan_nm), updated_at = NOW()
    WHERE id = p_company_id RETURNING * INTO comp_after;
    PERFORM saas_v3_write_audit(
      'plan_tier_changed', 'subscriptions',
      'Plan tier -> ' || lower(plan_nm),
      comp_after.company_name, p_company_id,
      comp_before, to_jsonb(comp_after),
      'companies', p_company_id::TEXT, NULL, NULL
    );
  END IF;

  PERFORM saas_v3_write_audit(
    'subscription_renewed', 'subscriptions',
    'Renewed subscription ' || dur_days::text || ' days',
    COALESCE(after_sub->>'plan_name', 'subscription'),
    p_company_id,
    before_sub, after_sub,
    'subscriptions', sub_id::TEXT, NULL, NULL
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'data', after_sub);
END;
$$;

-- ----------------------------------------------------------
-- 5) Full company export (includes finance settings)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_export_company_data()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  payload JSONB;
  finance_raw TEXT;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT value INTO finance_raw FROM app_settings
  WHERE key = 'company:' || cid::text || ':finance_items' LIMIT 1;

  payload := jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'exported_at', NOW(),
    'version', '057',
    'plan_limits', saas_get_plan_limits(cid),
    'employees', COALESCE((SELECT jsonb_agg(to_jsonb(e.*) ORDER BY e.id) FROM employees e WHERE e.company_id = cid), '[]'::jsonb),
    'attendance', COALESCE((SELECT jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso) FROM attendance a WHERE a.company_id = cid), '[]'::jsonb),
    'salary_records', COALESCE((SELECT jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso) FROM salary_records s WHERE s.company_id = cid), '[]'::jsonb),
    'leaves', COALESCE((SELECT jsonb_agg(to_jsonb(l.*) ORDER BY l.from_date) FROM leaves l WHERE l.company_id = cid), '[]'::jsonb),
    'departments', COALESCE((SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.name) FROM departments d WHERE d.company_id = cid), '[]'::jsonb),
    'finance_items', COALESCE(finance_raw::jsonb, '[]'::jsonb),
    'settings', COALESCE((
      SELECT jsonb_object_agg(
        replace(s.key, 'company:' || cid::text || ':', ''),
        s.value
      )
      FROM app_settings s
      WHERE s.key LIKE ('company:' || cid::text || ':%')
        AND s.key <> ('company:' || cid::text || ':finance_items')
    ), '{}'::jsonb)
  );

  PERFORM saas_v3_write_audit('company_export', 'backup', 'Full company export', 'company:' || cid::TEXT, cid,
    NULL, jsonb_build_object('exported_at', NOW(), 'version', '057'), 'company', cid::TEXT, NULL, NULL);
  RETURN payload;
END;
$$;

-- ----------------------------------------------------------
-- 6) Full company import with company_id verification
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_import_company_full(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  file_cid INTEGER;
  settings JSONB;
  k TEXT;
  v TEXT;
  cnt_settings INTEGER := 0;
  cnt_emp INTEGER := 0;
  cnt_att INTEGER := 0;
  cnt_sal INTEGER := 0;
  cnt_lev INTEGER := 0;
  cnt_dept INTEGER := 0;
  emp JSONB;
  att JSONB;
  sal JSONB;
  lev JSONB;
  dept JSONB;
  eid INTEGER;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;
  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch', 'expected', cid, 'got', file_cid);
  END IF;

  -- Settings
  settings := p_payload->'settings';
  IF settings IS NOT NULL AND jsonb_typeof(settings) = 'object' THEN
    FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
    LOOP
      IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
      INSERT INTO app_settings (key, value, updated_at)
      VALUES ('company:' || cid::text || ':' || k, v, NOW())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
      cnt_settings := cnt_settings + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'finance_items' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':finance_items', (p_payload->'finance_items')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt_settings := cnt_settings + 1;
  END IF;

  -- Departments
  IF p_payload ? 'departments' AND jsonb_typeof(p_payload->'departments') = 'array' THEN
    FOR dept IN SELECT * FROM jsonb_array_elements(p_payload->'departments')
    LOOP
      INSERT INTO departments (company_id, name, created_at, updated_at)
      VALUES (cid, COALESCE(dept->>'name', dept->>'dept', 'قسم'), NOW(), NOW())
      ON CONFLICT DO NOTHING;
      cnt_dept := cnt_dept + 1;
    END LOOP;
  END IF;

  -- Employees (upsert by id within tenant)
  IF p_payload ? 'employees' AND jsonb_typeof(p_payload->'employees') = 'array' THEN
    FOR emp IN SELECT * FROM jsonb_array_elements(p_payload->'employees')
    LOOP
      eid := NULLIF((emp->>'id')::INTEGER, 0);
      IF eid IS NULL THEN CONTINUE; END IF;
      INSERT INTO employees (
        id, company_id, name, dept, role, phone, salary, salary_type,
        daily_rate, check_in, check_out, remote_attend, open_hours,
        include_overtime_in_salary, updated_at
      ) VALUES (
        eid, cid,
        COALESCE(emp->>'name', ''),
        COALESCE(emp->>'dept', ''),
        COALESCE(emp->>'role', ''),
        COALESCE(emp->>'phone', '—'),
        COALESCE((emp->>'salary')::INTEGER, 0),
        COALESCE(emp->>'salary_type', emp->>'salaryType', 'monthly'),
        COALESCE((emp->>'daily_rate')::INTEGER, (emp->>'dailyRate')::INTEGER, 0),
        COALESCE(emp->>'check_in', emp->>'checkIn', '08:00'),
        COALESCE(emp->>'check_out', emp->>'checkOut', '17:00'),
        COALESCE((emp->>'remote_attend')::BOOLEAN, (emp->>'remoteAttend')::BOOLEAN, false),
        COALESCE((emp->>'open_hours')::BOOLEAN, (emp->>'openHours')::BOOLEAN, false),
        COALESCE((emp->>'include_overtime_in_salary')::BOOLEAN, (emp->>'includeOvertimeInSalary')::BOOLEAN, false),
        NOW()
      )
      ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, dept = EXCLUDED.dept, role = EXCLUDED.role,
        phone = EXCLUDED.phone, salary = EXCLUDED.salary, salary_type = EXCLUDED.salary_type,
        daily_rate = EXCLUDED.daily_rate, check_in = EXCLUDED.check_in, check_out = EXCLUDED.check_out,
        remote_attend = EXCLUDED.remote_attend, open_hours = EXCLUDED.open_hours,
        include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
        company_id = cid,
        updated_at = NOW()
      WHERE employees.company_id = cid;
      cnt_emp := cnt_emp + 1;
    END LOOP;
  END IF;

  -- Attendance
  IF p_payload ? 'attendance' AND jsonb_typeof(p_payload->'attendance') = 'array' THEN
    FOR att IN SELECT * FROM jsonb_array_elements(p_payload->'attendance')
    LOOP
      IF (att->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO attendance (
        employee_id, company_id, emp_name, dept, date_label, date_iso,
        check_in, check_out, hours, late, overtime, status, updated_at
      ) VALUES (
        (att->>'employee_id')::INTEGER, cid,
        COALESCE(att->>'emp_name', att->>'emp', ''),
        COALESCE(att->>'dept', ''),
        COALESCE(att->>'date_label', att->>'date', ''),
        COALESCE(att->>'date_iso', att->>'dateIso', CURRENT_DATE::text),
        COALESCE(att->>'check_in', att->>'ci', '—'),
        COALESCE(att->>'check_out', att->>'co', '—'),
        COALESCE(att->>'hours', att->>'hrs', '—'),
        COALESCE(att->>'late', '—'),
        COALESCE(att->>'overtime', att->>'ot', '—'),
        COALESCE(att->>'status', 'طبيعي'),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_att := cnt_att + 1;
    END LOOP;
  END IF;

  -- Salary records
  IF p_payload ? 'salary_records' AND jsonb_typeof(p_payload->'salary_records') = 'array' THEN
    FOR sal IN SELECT * FROM jsonb_array_elements(p_payload->'salary_records')
    LOOP
      IF (sal->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO salary_records (
        employee_id, company_id, month_iso, month_label, base_salary,
        overtime, deductions, net_salary, status, updated_at
      ) VALUES (
        (sal->>'employee_id')::INTEGER, cid,
        COALESCE(sal->>'month_iso', sal->>'monthIso', ''),
        COALESCE(sal->>'month_label', sal->>'month', ''),
        COALESCE((sal->>'base_salary')::INTEGER, (sal->>'base')::INTEGER, 0),
        COALESCE((sal->>'overtime')::INTEGER, (sal->>'ot')::INTEGER, 0),
        COALESCE((sal->>'deductions')::INTEGER, (sal->>'deduct')::INTEGER, 0),
        COALESCE((sal->>'net_salary')::INTEGER, (sal->>'net')::INTEGER, 0),
        COALESCE(sal->>'status', 'معلق'),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_sal := cnt_sal + 1;
    END LOOP;
  END IF;

  -- Leaves
  IF p_payload ? 'leaves' AND jsonb_typeof(p_payload->'leaves') = 'array' THEN
    FOR lev IN SELECT * FROM jsonb_array_elements(p_payload->'leaves')
    LOOP
      IF (lev->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO leaves (
        employee_id, company_id, leave_type, from_date, to_date,
        days, status, reason, updated_at
      ) VALUES (
        (lev->>'employee_id')::INTEGER, cid,
        COALESCE(lev->>'leave_type', lev->>'type', 'annual'),
        COALESCE((lev->>'from_date')::DATE, (lev->>'fromDate')::DATE, CURRENT_DATE),
        COALESCE((lev->>'to_date')::DATE, (lev->>'toDate')::DATE, CURRENT_DATE),
        COALESCE((lev->>'days')::INTEGER, 1),
        COALESCE(lev->>'status', 'pending'),
        COALESCE(lev->>'reason', ''),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_lev := cnt_lev + 1;
    END LOOP;
  END IF;

  PERFORM saas_v3_write_audit(
    'company_import_full', 'backup',
    'Full import: settings=' || cnt_settings::text || ' emp=' || cnt_emp::text,
    'company:' || cid::TEXT, cid,
    NULL,
    jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept
    ),
    'company', cid::TEXT, NULL, NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'imported', jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept
    )
  );
END;
$$;

-- ----------------------------------------------------------
-- 7) Security Health Report (one-click audit)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_upsert_attendance_by_device',
      'saas_upsert_attendance_employee', 'saas_link_device_by_token',
      'saas_security_health_report', 'saas_v3_audit_rls_report',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt'
    )
    AND pg_get_functiondef(p.oid) !~* 'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active';

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'enterprise_ready',
      jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
  );
END;
$$;

-- ----------------------------------------------------------
-- 8) Grants
-- ----------------------------------------------------------
REVOKE ALL ON TABLE subscription_plans FROM PUBLIC, anon;
GRANT SELECT ON TABLE subscription_plans TO authenticated;

REVOKE ALL ON FUNCTION saas_get_plan_limits(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_plan_limits(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_assert_plan_feature(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_assert_plan_feature(INTEGER, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_import_company_full(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_full(JSONB) TO authenticated;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_security_health_report() IS
  'Phase 2 one-click security posture report for super admins';
COMMENT ON FUNCTION saas_import_company_full(JSONB) IS
  'Full tenant restore with mandatory company_id verification';

-- END: 057_phase2_production_hardening.sql

-- ============================================================
-- BEGIN: 058_phase3_high_risk_remediation.sql
-- ============================================================

-- ============================================================
-- KYNO 058 — Phase 3 High Risk RPC Remediation
-- Hardens QR/device RPCs + internal v3 helpers (tenant gates)
-- ============================================================

-- ----------------------------------------------------------
-- 1) Internal v3 helpers — tenant assert + revoke public execute
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_v3_company_setting(p_company_id INTEGER, p_key TEXT)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tenant JSONB;
BEGIN
  tenant := saas_v3_assert_tenant(p_company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN NULL;
  END IF;

  RETURN (
    SELECT s.value
    FROM app_settings s
    WHERE s.key = ('company:' || p_company_id::text || ':' || p_key)
    LIMIT 1
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_compute_leave_deductions(
  p_employee_id INTEGER,
  p_company_id INTEGER,
  p_period_start DATE,
  p_period_end DATE,
  p_daily_rate INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tenant JSONB;
  lv RECORD;
  leave_deduct INTEGER := 0;
  leave_days INTEGER := 0;
  items JSONB := '[]'::JSONB;
  days_count INTEGER;
  deduct_amt INTEGER;
  mult INTEGER;
  lbl TEXT;
BEGIN
  tenant := saas_v3_assert_tenant(p_company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  IF p_daily_rate IS NULL OR p_daily_rate <= 0 THEN
    RETURN jsonb_build_object('leave_deduct', 0, 'leave_days', 0, 'leave_items', '[]'::jsonb);
  END IF;

  FOR lv IN
    SELECT l.*
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = p_company_id
      AND l.from_date <= p_period_end
      AND COALESCE(l.to_date, l.from_date) >= p_period_start
  LOOP
    days_count := saas_v3_leave_days_in_period(lv.from_date, lv.to_date, p_period_start, p_period_end);
    deduct_amt := 0;
    lbl := COALESCE(lv.leave_type, 'paid_single');

    IF lbl = 'unpaid_open' THEN
      deduct_amt := ROUND(days_count * p_daily_rate);
      leave_days := leave_days + days_count;
    ELSIF lbl = 'unpaid_single' THEN
      deduct_amt := p_daily_rate;
      leave_days := leave_days + 1;
    ELSIF lbl = 'absence_mult' THEN
      mult := GREATEST(1, COALESCE(lv.multiplier, 1));
      deduct_amt := ROUND(mult * p_daily_rate);
      leave_days := leave_days + 1;
      lbl := lbl || ' (×' || mult::TEXT || ')';
    ELSE
      CONTINUE;
    END IF;

    IF deduct_amt > 0 THEN
      leave_deduct := leave_deduct + deduct_amt;
      items := items || jsonb_build_array(jsonb_build_object(
        'label', lbl,
        'days', days_count,
        'deduct', deduct_amt,
        'leave_type', lv.leave_type
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'leave_deduct', leave_deduct,
    'leave_days', leave_days,
    'leave_items', items
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_finance_totals(
  p_company_id INTEGER,
  p_employee_id INTEGER,
  p_period_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tenant JSONB;
  raw TEXT;
  arr JSONB;
  item JSONB;
  deductions INTEGER := 0;
  bonuses INTEGER := 0;
  loans INTEGER := 0;
  amt INTEGER;
  status TEXT;
  iperiod TEXT;
  inst INTEGER;
  loan_items JSONB := '[]'::jsonb;
BEGIN
  tenant := saas_v3_assert_tenant(p_company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  raw := saas_v3_company_setting(p_company_id, 'finance_items');
  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;
  BEGIN
    arr := raw::JSONB;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN jsonb_build_object('deductions', 0, 'bonuses', 0, 'loans', 0, 'loan_items', '[]'::jsonb);
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(arr)
  LOOP
    IF COALESCE((item->>'empId')::INTEGER, (item->>'emp_id')::INTEGER, 0) <> p_employee_id THEN
      CONTINUE;
    END IF;
    status := COALESCE(item->>'status', '');
    IF status IN ('ملغي', 'مسدد') THEN CONTINUE; END IF;
    iperiod := COALESCE(item->>'period', '');
    amt := GREATEST(0, COALESCE((item->>'amount')::INTEGER, 0));

    IF COALESCE(item->>'type', '') = 'bonus' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        bonuses := bonuses + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'deduction' THEN
      IF iperiod = '' OR iperiod = p_period_key OR left(iperiod, 7) = left(p_period_key, 7) THEN
        deductions := deductions + amt;
      END IF;
    ELSIF COALESCE(item->>'type', '') = 'loan' THEN
      inst := saas_v3_loan_current_installment(item);
      IF inst > 0 THEN
        loans := loans + inst;
        loan_items := loan_items || jsonb_build_array(jsonb_build_object(
          'id', item->>'id',
          'amount', amt,
          'installment_count', COALESCE((item->>'installmentCount')::INTEGER, (item->>'installment_count')::INTEGER, 1),
          'paid_installments', COALESCE((item->>'paidInstallments')::INTEGER, (item->>'paid_installments')::INTEGER, 0),
          'current_installment', inst,
          'remaining_balance', saas_v3_loan_remaining_balance(item),
          'loan_mode', COALESCE(item->>'loanMode', item->>'loan_mode', 'lump'),
          'status', status
        ));
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'deductions', deductions,
    'bonuses', bonuses,
    'loans', loans,
    'loan_items', loan_items
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL,
  p_entity_type TEXT DEFAULT NULL,
  p_entity_id TEXT DEFAULT NULL,
  p_ip_address TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
  cid INTEGER;
  tenant JSONB;
BEGIN
  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF(p_company_id, 0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  meta := jsonb_build_object(
    'company_id', cid,
    'timestamp', to_jsonb(NOW()),
    'entity_type', NULLIF(trim(p_entity_type), ''),
    'entity_id', NULLIF(trim(p_entity_id), ''),
    'old_value', COALESCE(p_before, 'null'::jsonb),
    'new_value', COALESCE(p_after, 'null'::jsonb),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta,
    ip_address, user_agent
  ) VALUES (
    cid,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    meta,
    NULLIF(trim(p_ip_address), ''),
    NULLIF(trim(p_user_agent), '')
  );
EXCEPTION
  WHEN others THEN
    NULL;
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_company_setting(INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION saas_v3_compute_leave_deductions(INTEGER, INTEGER, DATE, DATE, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION saas_v3_finance_totals(INTEGER, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------
-- 2) Admin QR publish — tenant assert from employee row
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_publish_employee_qr(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_token TEXT,
  p_label TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  prev RECORD;
  tenant JSONB;
  active_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_slot IS NULL OR tok IS NULL OR length(tok) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT id, name, dept, company_id INTO e
  FROM employees WHERE id = p_employee_id LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(e.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  active_chk := saas_assert_company_active(e.company_id);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', active_chk->>'error');
  END IF;

  SELECT token, fingerprint, ip, linked_at, token_used_at, last_login
  INTO prev
  FROM employee_devices
  WHERE employee_id = p_employee_id AND slot = p_slot
  LIMIT 1;

  INSERT INTO employee_devices (
    employee_id, slot, label, token, token_created_at, company_id,
    fingerprint, ip, linked_at, token_used_at, last_login, device_info
  ) VALUES (
    p_employee_id, p_slot,
    COALESCE(NULLIF(trim(p_label), ''), 'الهاتف ' || p_slot::text),
    tok, NOW(), e.company_id,
    '', '', NULL, NULL, NULL, '{}'::jsonb
  )
  ON CONFLICT (employee_id, slot) DO UPDATE SET
    token = EXCLUDED.token,
    token_created_at = COALESCE(employee_devices.token_created_at, NOW()),
    label = COALESCE(EXCLUDED.label, employee_devices.label),
    company_id = e.company_id,
    fingerprint = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN ''
      ELSE COALESCE(employee_devices.fingerprint, '')
    END,
    ip = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN ''
      ELSE COALESCE(employee_devices.ip, '')
    END,
    linked_at = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.linked_at
    END,
    token_used_at = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.token_used_at
    END,
    last_login = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN NULL
      ELSE employee_devices.last_login
    END,
    device_info = CASE
      WHEN employee_devices.token IS DISTINCT FROM EXCLUDED.token THEN '{}'::jsonb
      ELSE COALESCE(employee_devices.device_info, '{}'::jsonb)
    END;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'slot', p_slot,
    'token', tok,
    'company_id', e.company_id,
    'preserved_link', COALESCE(prev.fingerprint, '') <> '' AND prev.token = tok
  );
END;
$$;

-- ----------------------------------------------------------
-- 3) QR resolve — token credential for anon; tenant assert for admin
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_resolve_qr_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d RECORD;
  e RECORD;
  tok TEXT := NULLIF(trim(p_token), '');
  sl SMALLINT := p_slot;
  tenant JSONB;
  active_chk JSONB;
  is_admin BOOLEAN := FALSE;
BEGIN
  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, emp.id AS emp_id, emp.name AS emp_name, emp.dept, emp.company_id,
           emp.open_hours, emp.remote_attend, emp.check_in, emp.check_out
    INTO d
    FROM employee_devices ed
    JOIN employees emp ON emp.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;

    IF FOUND THEN
      active_chk := saas_assert_company_active(d.company_id);
      IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
      END IF;

      RETURN jsonb_build_object(
        'ok', true, 'source', 'token',
        'employee_id', d.emp_id, 'emp_name', d.emp_name, 'dept', d.dept,
        'company_id', d.company_id, 'slot', d.slot,
        'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
        'token', d.token, 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || d.emp_id::text || '-D' || d.slot::text,
        'open_hours', d.open_hours IS TRUE,
        'remote_attend', d.remote_attend IS TRUE,
        'check_in', d.check_in,
        'check_out', d.check_out
      );
    END IF;
  END IF;

  IF p_employee_id IS NOT NULL AND sl IS NOT NULL THEN
    SELECT id, name, dept, company_id, open_hours, remote_attend, check_in, check_out INTO e
    FROM employees WHERE id = p_employee_id LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
    END IF;

    IF auth_company_id() IS NOT NULL OR auth_is_super_admin() THEN
      tenant := saas_v3_assert_tenant(e.company_id);
      IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
        RETURN tenant;
      END IF;
      is_admin := TRUE;
    END IF;

    active_chk := saas_assert_company_active(e.company_id);
    IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
    END IF;

    SELECT ed.* INTO d
    FROM employee_devices ed
    WHERE ed.employee_id = p_employee_id AND ed.slot = sl
    LIMIT 1;

    IF is_admin THEN
      IF FOUND AND tok IS NOT NULL AND length(tok) >= 10 AND (d.token IS NULL OR d.token <> tok) THEN
        UPDATE employee_devices SET
          token = tok,
          token_created_at = COALESCE(token_created_at, NOW()),
          fingerprint = '', ip = '',
          linked_at = NULL, token_used_at = NULL, last_login = NULL
        WHERE id = d.id;
        d.token := tok;
        d.fingerprint := '';
      END IF;

      IF NOT FOUND AND tok IS NOT NULL AND length(tok) >= 10 THEN
        INSERT INTO employee_devices (
          employee_id, slot, label, token, token_created_at, company_id,
          fingerprint, ip, device_info
        ) VALUES (
          p_employee_id, sl, 'الهاتف ' || sl::text, tok, NOW(), e.company_id,
          '', '', '{}'::jsonb
        )
        ON CONFLICT (employee_id, slot) DO UPDATE SET
          token = EXCLUDED.token,
          fingerprint = '', ip = '';

        SELECT ed.* INTO d
        FROM employee_devices ed
        WHERE ed.employee_id = p_employee_id AND ed.slot = sl
        LIMIT 1;
      END IF;

      IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'device_not_registered');
      END IF;

      RETURN jsonb_build_object(
        'ok', true, 'source', 'admin',
        'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
        'company_id', e.company_id, 'slot', sl,
        'label', COALESCE(d.label, 'الهاتف ' || sl::text),
        'token', COALESCE(d.token, tok), 'pin', d.pin,
        'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
        'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
        'open_hours', e.open_hours IS TRUE,
        'remote_attend', e.remote_attend IS TRUE,
        'check_in', e.check_in,
        'check_out', e.check_out
      );
    END IF;

    IF tok IS NULL OR length(tok) < 10 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'token_required');
    END IF;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'device_not_registered');
    END IF;

    IF d.token IS NULL OR d.token <> tok THEN
      RETURN jsonb_build_object('ok', false, 'error', 'token_mismatch');
    END IF;

    RETURN jsonb_build_object(
      'ok', true, 'source', 'employee_slot',
      'employee_id', e.id, 'emp_name', e.name, 'dept', e.dept,
      'company_id', e.company_id, 'slot', sl,
      'label', COALESCE(d.label, 'الهاتف ' || sl::text),
      'token', d.token, 'pin', d.pin,
      'fingerprint', COALESCE(d.fingerprint, ''), 'ip', COALESCE(d.ip, ''),
      'barcode', 'ATT-' || e.id::text || '-D' || sl::text,
      'open_hours', e.open_hours IS TRUE,
      'remote_attend', e.remote_attend IS TRUE,
      'check_in', e.check_in,
      'check_out', e.check_out
    );
  END IF;

  IF tok IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'token_not_found');
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_qr');
END;
$$;

CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r JSONB;
BEGIN
  r := saas_resolve_qr_registration(p_token, p_employee_id, p_slot);
  IF r IS NULL OR (r->>'ok')::boolean IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  RETURN r - 'ok' - 'source' - 'error';
END;
$$;

-- ----------------------------------------------------------
-- 4) Employee avatar — device token OR tenant admin session
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_update_employee_avatar(
  p_employee_id INTEGER,
  p_avatar_url TEXT,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  url TEXT := NULLIF(trim(p_avatar_url), '');
  tenant JSONB;
  active_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF url IS NULL OR length(url) < 24 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar');
  END IF;

  IF length(url) > 700000 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'avatar_too_large');
  END IF;

  IF url NOT LIKE 'data:image/%' AND url NOT LIKE 'http%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar_format');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  active_chk := saas_assert_company_active(emp.company_id);
  IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  IF auth_company_id() IS NOT NULL OR auth_is_super_admin() THEN
    tenant := saas_v3_assert_tenant(emp.company_id);
    IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN tenant;
    END IF;
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  UPDATE employees
  SET avatar_url = url
  WHERE id = p_employee_id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'avatar_url', url
  );
END;
$$;

-- ----------------------------------------------------------
-- 5) Grants (public RPCs unchanged)
-- ----------------------------------------------------------
REVOKE ALL ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_update_employee_avatar(INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_employee_avatar(INTEGER, TEXT, TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------
-- 6) Security health report — Phase 3 allowlist + delegated checks
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_upsert_attendance_by_device',
      'saas_upsert_attendance_employee', 'saas_link_device_by_token',
      'saas_security_health_report', 'saas_v3_audit_rls_report',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt',
      'saas_hash_password_bcrypt', 'saas_create_session', 'saas_verify_session',
      'saas_revoke_session', 'saas_count_legacy_seed_users',
      'saas_super_admin_default_perms', 'saas_super_admin_effective_perms',
      'saas_super_admin_can', 'saas_super_admin_sender_meta',
      'saas_v3_company_setting', 'saas_v3_compute_leave_deductions',
      'saas_v3_finance_totals', 'saas_v3_write_audit'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
    );

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'enterprise_ready',
      jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_publish_employee_qr(INTEGER, SMALLINT, TEXT, TEXT) IS
  'Phase 3 — tenant-asserted QR publish; company derived from employee row';
COMMENT ON FUNCTION saas_resolve_qr_registration(TEXT, INTEGER, SMALLINT) IS
  'Phase 3 — token credential for anon; admin path requires saas_v3_assert_tenant';
COMMENT ON FUNCTION saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB, TEXT, TEXT, TEXT, TEXT) IS
  'Phase 3 — internal audit writer; company from auth_company_id() + assert_tenant';

-- END: 058_phase3_high_risk_remediation.sql

-- ============================================================
-- BEGIN: 059_final_closure_audit.sql
-- ============================================================

-- ============================================================
-- KYNO 059 — Final closure: recalculate_salary + lookup wrapper
-- ============================================================

-- ----------------------------------------------------------
-- 1) Payroll recalculate — explicit tenant gate before delegate
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_recalculate_salary(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  month_key TEXT;
  tenant JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  month_key := CASE WHEN COALESCE(emp.salary_type, 'monthly') = 'biweekly' THEN
    to_char(basma_date_iso_baghdad(), 'YYYY-MM') ||
    CASE WHEN EXTRACT(DAY FROM basma_date_iso_baghdad()) <= 15 THEN '-H1' ELSE '-H2' END
  ELSE to_char(basma_date_iso_baghdad(), 'YYYY-MM') END;

  IF EXISTS (
    SELECT 1 FROM salary_records sr
    WHERE sr.employee_id = p_employee_id AND sr.month_iso = month_key AND sr.status = 'مُصدر'
  ) THEN
    RETURN saas_issue_salary(p_employee_id, month_key);
  END IF;

  RETURN saas_preview_salary(p_employee_id, month_key);
END;
$$;

REVOKE ALL ON FUNCTION saas_recalculate_salary(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recalculate_salary(INTEGER) TO authenticated;

-- ----------------------------------------------------------
-- 2) Lookup wrapper — delegates to hardened resolve (058)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_lookup_device_registration(
  p_token TEXT DEFAULT NULL,
  p_employee_id INTEGER DEFAULT NULL,
  p_slot SMALLINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r JSONB;
  _session_cid INTEGER := auth_company_id();
BEGIN
  r := saas_resolve_qr_registration(p_token, p_employee_id, p_slot);
  IF r IS NULL OR COALESCE((r->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  RETURN r - 'ok' - 'source' - 'error';
END;
$$;

REVOKE ALL ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) TO anon, authenticated;

-- ----------------------------------------------------------
-- 3) Health report — recognize delegated tenant validators
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_upsert_attendance_by_device',
      'saas_upsert_attendance_employee', 'saas_link_device_by_token',
      'saas_security_health_report', 'saas_v3_audit_rls_report',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt',
      'saas_hash_password_bcrypt', 'saas_create_session', 'saas_verify_session',
      'saas_revoke_session', 'saas_count_legacy_seed_users',
      'saas_super_admin_default_perms', 'saas_super_admin_effective_perms',
      'saas_super_admin_can', 'saas_super_admin_sender_meta',
      'saas_v3_company_setting', 'saas_v3_compute_leave_deductions',
      'saas_v3_finance_totals', 'saas_v3_write_audit'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
      || '|saas_resolve_qr_registration|saas_issue_salary|saas_preview_salary'
    );

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'enterprise_ready',
      jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_recalculate_salary(INTEGER) IS
  'Phase 3 closure — saas_v3_assert_tenant before issue/preview delegate';
COMMENT ON FUNCTION saas_lookup_device_registration(TEXT, INTEGER, SMALLINT) IS
  'Phase 3 closure — thin wrapper over saas_resolve_qr_registration';

-- END: 059_final_closure_audit.sql

-- ============================================================
-- BEGIN: 060_enterprise_commercial_launch.sql
-- ============================================================

-- ============================================================
-- KYNO 060 — Enterprise Commercial Launch (monitoring + SA backup)
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

-- ----------------------------------------------------------
-- 1) Super Admin audit feed (last N operations)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_super_list_audit_logs(p_limit INTEGER DEFAULT 100)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  rows JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COALESCE(jsonb_agg(sub.row_obj ORDER BY sub.created_at DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', a.id,
        'company_id', a.company_id,
        'actor_id', a.actor_id,
        'actor_name', COALESCE(a.actor_name, ''),
        'actor_role', COALESCE(a.actor_role, ''),
        'action', a.action,
        'category', COALESCE(a.category, ''),
        'details', COALESCE(a.details, ''),
        'target_name', COALESCE(a.target_name, ''),
        'created_at', a.created_at,
        'meta', COALESCE(a.meta, '{}'::jsonb)
      ) AS row_obj,
      a.created_at
    FROM audit_logs a
    ORDER BY a.created_at DESC
    LIMIT lim
  ) sub;

  RETURN jsonb_build_object('ok', true, 'logs', rows, 'count', jsonb_array_length(rows));
END;
$$;

-- ----------------------------------------------------------
-- 2) Super Admin cross-tenant export (Backup Center)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_super_export_company(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  cid INTEGER := p_company_id;
  finance_raw TEXT;
  payload JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('companies_view') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.id = cid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;

  SELECT value INTO finance_raw FROM app_settings
  WHERE key = 'company:' || cid::text || ':finance_items' LIMIT 1;

  payload := jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'exported_at', NOW(),
    'version', '060',
    'plan_limits', saas_get_plan_limits(cid),
    'employees', COALESCE((SELECT jsonb_agg(to_jsonb(e.*) ORDER BY e.id) FROM employees e WHERE e.company_id = cid), '[]'::jsonb),
    'attendance', COALESCE((SELECT jsonb_agg(to_jsonb(a.*) ORDER BY a.date_iso) FROM attendance a WHERE a.company_id = cid), '[]'::jsonb),
    'salary_records', COALESCE((SELECT jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso) FROM salary_records s WHERE s.company_id = cid), '[]'::jsonb),
    'leaves', COALESCE((SELECT jsonb_agg(to_jsonb(l.*) ORDER BY l.from_date) FROM leaves l WHERE l.company_id = cid), '[]'::jsonb),
    'departments', COALESCE((SELECT jsonb_agg(to_jsonb(d.*) ORDER BY d.name) FROM departments d WHERE d.company_id = cid), '[]'::jsonb),
    'finance_items', COALESCE(finance_raw::jsonb, '[]'::jsonb),
    'settings', COALESCE((
      SELECT jsonb_object_agg(
        replace(s.key, 'company:' || cid::text || ':', ''),
        s.value
      )
      FROM app_settings s
      WHERE s.key LIKE ('company:' || cid::text || ':%')
        AND s.key <> ('company:' || cid::text || ':finance_items')
    ), '{}'::jsonb)
  );

  PERFORM saas_v3_write_audit(
    'super_company_export', 'backup',
    'Super admin exported company ' || cid::TEXT,
    'company:' || cid::TEXT, cid,
    NULL, jsonb_build_object('exported_at', NOW(), 'version', '060'),
    'company', cid::TEXT, NULL, NULL
  );

  RETURN payload;
END;
$$;

-- ----------------------------------------------------------
-- 3) Platform monitoring snapshot (System Monitoring page)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_system_monitoring_snapshot()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  sec JSONB;
  rls JSONB;
  companies_total INTEGER;
  companies_active INTEGER;
  companies_suspended INTEGER;
  companies_expired INTEGER;
  users_total INTEGER;
  employees_total INTEGER;
  recent_logins JSONB;
  audit_sample JSONB;
  backup_stats JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  sec := saas_security_health_report();
  rls := saas_v3_audit_rls_report();

  SELECT COUNT(*) INTO companies_total FROM companies;
  SELECT COUNT(*) INTO companies_active FROM companies WHERE status = 'active';
  SELECT COUNT(*) INTO companies_suspended FROM companies WHERE status = 'suspended';
  SELECT COUNT(*) INTO companies_expired
  FROM companies c
  WHERE c.status = 'expired'
     OR NOT EXISTS (
       SELECT 1 FROM subscriptions s
       WHERE s.company_id = c.id AND s.status = 'active' AND s.end_date >= CURRENT_DATE
     );

  SELECT COUNT(*) INTO users_total FROM saas_users WHERE role <> 'super_admin';
  SELECT COUNT(*) INTO employees_total FROM employees;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', COALESCE(u.display_name, ''),
    'role', u.role, 'company_id', u.company_id, 'last_login', u.last_login
  ) ORDER BY u.last_login DESC NULLS LAST), '[]'::jsonb) INTO recent_logins
  FROM (
    SELECT * FROM saas_users
    WHERE last_login IS NOT NULL
    ORDER BY last_login DESC
    LIMIT 20
  ) u;

  audit_sample := saas_super_list_audit_logs(100);

  SELECT jsonb_build_object(
    'employees', (SELECT COUNT(*) FROM employees),
    'attendance', (SELECT COUNT(*) FROM attendance),
    'salary_records', (SELECT COUNT(*) FROM salary_records),
    'leaves', (SELECT COUNT(*) FROM leaves),
    'audit_logs', (SELECT COUNT(*) FROM audit_logs)
  ) INTO backup_stats;

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'system_version', COALESCE(
      (SELECT value FROM app_settings WHERE key = 'platform:system_version' LIMIT 1),
      '1.0.0'
    ),
    'security', sec,
    'rls', rls,
    'companies', jsonb_build_object(
      'total', companies_total,
      'active', companies_active,
      'suspended', companies_suspended,
      'expired', companies_expired
    ),
    'users', jsonb_build_object(
      'total', users_total,
      'employees', employees_total,
      'recent_logins', recent_logins
    ),
    'audit', audit_sample,
    'backup_stats', backup_stats,
    'system_health', jsonb_build_object(
      'database', jsonb_build_object('ok', true, 'label', 'PostgreSQL / Supabase'),
      'auth', jsonb_build_object('ok', true, 'label', 'Supabase Auth + Edge Sessions'),
      'storage', jsonb_build_object('ok', true, 'label', 'Supabase Storage'),
      'supabase', jsonb_build_object('ok', COALESCE((sec->>'ok')::boolean, false), 'label', 'Supabase RPC + RLS')
    )
  );
END;
$$;

-- Store canonical system version in platform globals if missing
INSERT INTO app_settings (key, value)
VALUES ('platform:system_version', '1.0.0')
ON CONFLICT (key) DO NOTHING;

REVOKE ALL ON FUNCTION saas_super_list_audit_logs(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_list_audit_logs(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_super_export_company(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_export_company(INTEGER) TO authenticated;

REVOKE ALL ON FUNCTION saas_system_monitoring_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_system_monitoring_snapshot() TO authenticated;

COMMENT ON FUNCTION saas_system_monitoring_snapshot() IS
  'Enterprise System Monitoring — security, companies, users, audit, health';
COMMENT ON FUNCTION saas_super_export_company(INTEGER) IS
  'Super Admin Backup Center — cross-tenant export without RLS change';

-- END: 060_enterprise_commercial_launch.sql

-- ============================================================
-- BEGIN: 061_fix_monitoring_audit_agg.sql
-- ============================================================

-- ============================================================
-- KYNO 061 — Fix monitoring snapshot (audit logs jsonb_agg)
-- Root cause: jsonb_agg(x ORDER BY x.created_at) — x is JSONB, not a row
-- PostgREST surfaces this as HTTP 404 with 42P01
-- ============================================================

CREATE OR REPLACE FUNCTION saas_super_list_audit_logs(p_limit INTEGER DEFAULT 100)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  rows JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COALESCE(jsonb_agg(sub.row_obj ORDER BY sub.created_at DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', a.id,
        'company_id', a.company_id,
        'actor_id', a.actor_id,
        'actor_name', COALESCE(a.actor_name, ''),
        'actor_role', COALESCE(a.actor_role, ''),
        'action', a.action,
        'category', COALESCE(a.category, ''),
        'details', COALESCE(a.details, ''),
        'target_name', COALESCE(a.target_name, ''),
        'created_at', a.created_at,
        'meta', COALESCE(a.meta, '{}'::jsonb)
      ) AS row_obj,
      a.created_at
    FROM audit_logs a
    ORDER BY a.created_at DESC
    LIMIT lim
  ) sub;

  RETURN jsonb_build_object('ok', true, 'logs', rows, 'count', jsonb_array_length(rows));
END;
$$;

REVOKE ALL ON FUNCTION saas_super_list_audit_logs(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_list_audit_logs(INTEGER) TO authenticated;

-- END: 061_fix_monitoring_audit_agg.sql

-- ============================================================
-- BEGIN: 062_super_admin_backup_import.sql
-- ============================================================

-- ============================================================
-- KYNO 062 — Super Admin Backup Center import fix
-- saas_import_company_full used auth_company_id() only → no_company_context for super_admin
-- Super admin: company_id from backup payload (export from saas_super_export_company)
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

CREATE OR REPLACE FUNCTION saas_import_company_full(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  file_cid INTEGER;
  settings JSONB;
  k TEXT;
  v TEXT;
  cnt_settings INTEGER := 0;
  cnt_emp INTEGER := 0;
  cnt_att INTEGER := 0;
  cnt_sal INTEGER := 0;
  cnt_lev INTEGER := 0;
  cnt_dept INTEGER := 0;
  emp JSONB;
  att JSONB;
  sal JSONB;
  lev JSONB;
  dept JSONB;
  eid INTEGER;
  is_super BOOLEAN := false;
  audit_action TEXT := 'company_import_full';
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  is_super := auth_is_super_admin();

  IF cid IS NULL OR cid <= 0 THEN
    IF is_super THEN
      IF NOT saas_super_admin_can('companies_view') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
      END IF;
      cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
      IF cid IS NULL OR cid <= 0 THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', 'invalid_company',
          'detail', 'company_id required in backup JSON for super admin import'
        );
      END IF;
      IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.id = cid) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
      END IF;
      audit_action := 'super_company_import';
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
    END IF;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch', 'expected', cid, 'got', file_cid);
  END IF;

  settings := p_payload->'settings';
  IF settings IS NOT NULL AND jsonb_typeof(settings) = 'object' THEN
    FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
    LOOP
      IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
      INSERT INTO app_settings (key, value, updated_at)
      VALUES ('company:' || cid::text || ':' || k, v, NOW())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
      cnt_settings := cnt_settings + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'finance_items' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':finance_items', (p_payload->'finance_items')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt_settings := cnt_settings + 1;
  END IF;

  IF p_payload ? 'departments' AND jsonb_typeof(p_payload->'departments') = 'array' THEN
    FOR dept IN SELECT * FROM jsonb_array_elements(p_payload->'departments')
    LOOP
      INSERT INTO departments (company_id, name, created_at, updated_at)
      VALUES (cid, COALESCE(dept->>'name', dept->>'dept', 'قسم'), NOW(), NOW())
      ON CONFLICT DO NOTHING;
      cnt_dept := cnt_dept + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'employees' AND jsonb_typeof(p_payload->'employees') = 'array' THEN
    FOR emp IN SELECT * FROM jsonb_array_elements(p_payload->'employees')
    LOOP
      eid := NULLIF((emp->>'id')::INTEGER, 0);
      IF eid IS NULL THEN CONTINUE; END IF;
      INSERT INTO employees (
        id, company_id, name, dept, role, phone, salary, salary_type,
        daily_rate, check_in, check_out, remote_attend, open_hours,
        include_overtime_in_salary, updated_at
      ) VALUES (
        eid, cid,
        COALESCE(emp->>'name', ''),
        COALESCE(emp->>'dept', ''),
        COALESCE(emp->>'role', ''),
        COALESCE(emp->>'phone', '—'),
        COALESCE((emp->>'salary')::INTEGER, 0),
        COALESCE(emp->>'salary_type', emp->>'salaryType', 'monthly'),
        COALESCE((emp->>'daily_rate')::INTEGER, (emp->>'dailyRate')::INTEGER, 0),
        COALESCE(emp->>'check_in', emp->>'checkIn', '08:00'),
        COALESCE(emp->>'check_out', emp->>'checkOut', '17:00'),
        COALESCE((emp->>'remote_attend')::BOOLEAN, (emp->>'remoteAttend')::BOOLEAN, false),
        COALESCE((emp->>'open_hours')::BOOLEAN, (emp->>'openHours')::BOOLEAN, false),
        COALESCE((emp->>'include_overtime_in_salary')::BOOLEAN, (emp->>'includeOvertimeInSalary')::BOOLEAN, false),
        NOW()
      )
      ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, dept = EXCLUDED.dept, role = EXCLUDED.role,
        phone = EXCLUDED.phone, salary = EXCLUDED.salary, salary_type = EXCLUDED.salary_type,
        daily_rate = EXCLUDED.daily_rate, check_in = EXCLUDED.check_in, check_out = EXCLUDED.check_out,
        remote_attend = EXCLUDED.remote_attend, open_hours = EXCLUDED.open_hours,
        include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
        company_id = cid,
        updated_at = NOW()
      WHERE employees.company_id = cid;
      cnt_emp := cnt_emp + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'attendance' AND jsonb_typeof(p_payload->'attendance') = 'array' THEN
    FOR att IN SELECT * FROM jsonb_array_elements(p_payload->'attendance')
    LOOP
      IF (att->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO attendance (
        employee_id, company_id, emp_name, dept, date_label, date_iso,
        check_in, check_out, hours, late, overtime, status, updated_at
      ) VALUES (
        (att->>'employee_id')::INTEGER, cid,
        COALESCE(att->>'emp_name', att->>'emp', ''),
        COALESCE(att->>'dept', ''),
        COALESCE(att->>'date_label', att->>'date', ''),
        COALESCE(att->>'date_iso', att->>'dateIso', CURRENT_DATE::text),
        COALESCE(att->>'check_in', att->>'ci', '—'),
        COALESCE(att->>'check_out', att->>'co', '—'),
        COALESCE(att->>'hours', att->>'hrs', '—'),
        COALESCE(att->>'late', '—'),
        COALESCE(att->>'overtime', att->>'ot', '—'),
        COALESCE(att->>'status', 'طبيعي'),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_att := cnt_att + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'salary_records' AND jsonb_typeof(p_payload->'salary_records') = 'array' THEN
    FOR sal IN SELECT * FROM jsonb_array_elements(p_payload->'salary_records')
    LOOP
      IF (sal->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO salary_records (
        employee_id, company_id, month_iso, month_label, base_salary,
        overtime, deductions, net_salary, status, updated_at
      ) VALUES (
        (sal->>'employee_id')::INTEGER, cid,
        COALESCE(sal->>'month_iso', sal->>'monthIso', ''),
        COALESCE(sal->>'month_label', sal->>'month', ''),
        COALESCE((sal->>'base_salary')::INTEGER, (sal->>'base')::INTEGER, 0),
        COALESCE((sal->>'overtime')::INTEGER, (sal->>'ot')::INTEGER, 0),
        COALESCE((sal->>'deductions')::INTEGER, (sal->>'deduct')::INTEGER, 0),
        COALESCE((sal->>'net_salary')::INTEGER, (sal->>'net')::INTEGER, 0),
        COALESCE(sal->>'status', 'معلق'),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_sal := cnt_sal + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'leaves' AND jsonb_typeof(p_payload->'leaves') = 'array' THEN
    FOR lev IN SELECT * FROM jsonb_array_elements(p_payload->'leaves')
    LOOP
      IF (lev->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO leaves (
        employee_id, company_id, leave_type, from_date, to_date,
        days, status, reason, updated_at
      ) VALUES (
        (lev->>'employee_id')::INTEGER, cid,
        COALESCE(lev->>'leave_type', lev->>'type', 'annual'),
        COALESCE((lev->>'from_date')::DATE, (lev->>'fromDate')::DATE, CURRENT_DATE),
        COALESCE((lev->>'to_date')::DATE, (lev->>'toDate')::DATE, CURRENT_DATE),
        COALESCE((lev->>'days')::INTEGER, 1),
        COALESCE(lev->>'status', 'pending'),
        COALESCE(lev->>'reason', ''),
        NOW()
      )
      ON CONFLICT DO NOTHING;
      cnt_lev := cnt_lev + 1;
    END LOOP;
  END IF;

  PERFORM saas_v3_write_audit(
    audit_action, 'backup',
    'Full import: settings=' || cnt_settings::text || ' emp=' || cnt_emp::text,
    'company:' || cid::TEXT, cid,
    NULL,
    jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept,
      'super_admin', is_super AND audit_action = 'super_company_import'
    ),
    'company', cid::TEXT, NULL, NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'imported', jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_import_company_full(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_full(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_import_company_full(JSONB) IS
  'Full company import — tenant admin uses JWT company_id; super admin uses payload.company_id';

-- END: 062_super_admin_backup_import.sql

-- ============================================================
-- BEGIN: 063_employee_delete_salary_records.sql
-- ============================================================

-- ============================================================
-- KYNO 063 — Full employee delete (salary_records + related rows)
-- Fixes 400 on saas_delete_employee when salary_records exist
-- ============================================================

CREATE OR REPLACE FUNCTION saas_delete_employee(p_employee_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  before_row := to_jsonb(emp);

  DELETE FROM salary_records
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM attendance
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM leaves
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM employee_notifications
  WHERE employee_id = p_employee_id
    AND company_id = emp.company_id;

  DELETE FROM employee_devices
  WHERE employee_id = p_employee_id;

  DELETE FROM employees WHERE id = p_employee_id;

  PERFORM saas_v3_write_audit(
    'employee_deleted', 'employees',
    'Deleted employee ' || p_employee_id::TEXT,
    emp.name,
    emp.company_id,
    before_row,
    NULL
  );

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id);
EXCEPTION
  WHEN foreign_key_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_has_dependencies');
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_delete_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_delete_employee(INTEGER) TO authenticated;

-- END: 063_employee_delete_salary_records.sql

-- ============================================================
-- BEGIN: 064_fix_import_company_full_schema.sql
-- ============================================================

-- ============================================================
-- KYNO 064 — Fix saas_import_company_full column mismatches
-- departments: no created_at/updated_at
-- attendance: no updated_at
-- salary_records / leaves: align with live schema + export JSON
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

CREATE OR REPLACE FUNCTION saas_import_company_full(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  file_cid INTEGER;
  settings JSONB;
  k TEXT;
  v TEXT;
  cnt_settings INTEGER := 0;
  cnt_emp INTEGER := 0;
  cnt_att INTEGER := 0;
  cnt_sal INTEGER := 0;
  cnt_lev INTEGER := 0;
  cnt_dept INTEGER := 0;
  emp JSONB;
  att JSONB;
  sal JSONB;
  lev JSONB;
  dept JSONB;
  eid INTEGER;
  dept_name TEXT;
  is_super BOOLEAN := false;
  audit_action TEXT := 'company_import_full';
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  is_super := auth_is_super_admin();

  IF cid IS NULL OR cid <= 0 THEN
    IF is_super THEN
      IF NOT saas_super_admin_can('companies_view') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
      END IF;
      cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
      IF cid IS NULL OR cid <= 0 THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', 'invalid_company',
          'detail', 'company_id required in backup JSON for super admin import'
        );
      END IF;
      IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.id = cid) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
      END IF;
      audit_action := 'super_company_import';
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
    END IF;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch', 'expected', cid, 'got', file_cid);
  END IF;

  settings := p_payload->'settings';
  IF settings IS NOT NULL AND jsonb_typeof(settings) = 'object' THEN
    FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
    LOOP
      IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
      INSERT INTO app_settings (key, value, updated_at)
      VALUES ('company:' || cid::text || ':' || k, v, NOW())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
      cnt_settings := cnt_settings + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'finance_items' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':finance_items', (p_payload->'finance_items')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt_settings := cnt_settings + 1;
  END IF;

  IF p_payload ? 'departments' AND jsonb_typeof(p_payload->'departments') = 'array' THEN
    FOR dept IN SELECT * FROM jsonb_array_elements(p_payload->'departments')
    LOOP
      dept_name := NULLIF(trim(COALESCE(dept->>'name', dept->>'dept', '')), '');
      IF dept_name IS NULL THEN CONTINUE; END IF;
      INSERT INTO departments (company_id, name)
      VALUES (cid, dept_name)
      ON CONFLICT DO NOTHING;
      cnt_dept := cnt_dept + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'employees' AND jsonb_typeof(p_payload->'employees') = 'array' THEN
    FOR emp IN SELECT * FROM jsonb_array_elements(p_payload->'employees')
    LOOP
      eid := NULLIF((emp->>'id')::INTEGER, 0);
      IF eid IS NULL THEN CONTINUE; END IF;
      INSERT INTO employees (
        id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
        daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
        sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
      ) VALUES (
        eid, cid,
        COALESCE(emp->>'name', ''),
        COALESCE(emp->>'dept', ''),
        COALESCE(emp->>'role', ''),
        COALESCE(emp->>'phone', '—'),
        COALESCE((emp->>'salary')::INTEGER, 0),
        COALESCE(emp->>'salary_type', emp->>'salaryType', 'monthly'),
        COALESCE((emp->>'salary_half')::INTEGER, (emp->>'salaryHalf')::INTEGER, 0),
        COALESCE((emp->>'daily_rate')::INTEGER, (emp->>'dailyRate')::INTEGER, 0),
        COALESCE((emp->>'days')::INTEGER, 0),
        COALESCE((emp->>'late_min')::INTEGER, (emp->>'lateMin')::INTEGER, 0),
        COALESCE(emp->>'check_in', emp->>'checkIn', '08:00')::TIME,
        COALESCE(emp->>'check_out', emp->>'checkOut', '17:00')::TIME,
        COALESCE((emp->>'open_hours')::BOOLEAN, (emp->>'openHours')::BOOLEAN, false),
        COALESCE((emp->>'remote_attend')::BOOLEAN, (emp->>'remoteAttend')::BOOLEAN, false),
        COALESCE(emp->>'sal_status', emp->>'salStatus', 'معلق'),
        COALESCE((emp->>'sal_bonus')::INTEGER, (emp->>'salBonus')::INTEGER, 0),
        COALESCE(emp->>'sal_deleted_period', emp->>'salDeletedPeriod', ''),
        NULLIF(emp->>'avatar_url', ''),
        COALESCE((emp->>'include_overtime_in_salary')::BOOLEAN, (emp->>'includeOvertimeInSalary')::BOOLEAN, false)
      )
      ON CONFLICT (id) DO UPDATE SET
        company_id = cid,
        name = EXCLUDED.name,
        dept = EXCLUDED.dept,
        role = EXCLUDED.role,
        phone = EXCLUDED.phone,
        salary = EXCLUDED.salary,
        salary_type = EXCLUDED.salary_type,
        salary_half = EXCLUDED.salary_half,
        daily_rate = EXCLUDED.daily_rate,
        days = EXCLUDED.days,
        late_min = EXCLUDED.late_min,
        check_in = EXCLUDED.check_in,
        check_out = EXCLUDED.check_out,
        open_hours = EXCLUDED.open_hours,
        remote_attend = EXCLUDED.remote_attend,
        sal_status = EXCLUDED.sal_status,
        sal_bonus = EXCLUDED.sal_bonus,
        sal_deleted_period = EXCLUDED.sal_deleted_period,
        avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
        include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
        updated_at = NOW()
      WHERE employees.company_id = cid;
      cnt_emp := cnt_emp + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'attendance' AND jsonb_typeof(p_payload->'attendance') = 'array' THEN
    FOR att IN SELECT * FROM jsonb_array_elements(p_payload->'attendance')
    LOOP
      IF (att->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO attendance (
        employee_id, company_id, emp_name, dept, date_label, date_iso,
        check_in, check_out, hours, late, overtime, status
      ) VALUES (
        (att->>'employee_id')::INTEGER, cid,
        COALESCE(att->>'emp_name', att->>'emp', ''),
        COALESCE(att->>'dept', ''),
        COALESCE(att->>'date_label', att->>'date', ''),
        COALESCE(
          NULLIF(trim(COALESCE(att->>'date_iso', att->>'dateIso', '')), '')::DATE,
          CURRENT_DATE
        ),
        COALESCE(att->>'check_in', att->>'ci', '—'),
        COALESCE(att->>'check_out', att->>'co', '—'),
        COALESCE(att->>'hours', att->>'hrs', '—'),
        COALESCE(att->>'late', '—'),
        COALESCE(att->>'overtime', att->>'ot', '—'),
        COALESCE(att->>'status', 'طبيعي')
      )
      ON CONFLICT (employee_id, date_iso) DO UPDATE SET
        emp_name = EXCLUDED.emp_name,
        dept = EXCLUDED.dept,
        date_label = EXCLUDED.date_label,
        check_in = EXCLUDED.check_in,
        check_out = EXCLUDED.check_out,
        hours = EXCLUDED.hours,
        late = EXCLUDED.late,
        overtime = EXCLUDED.overtime,
        status = EXCLUDED.status,
        company_id = cid;
      cnt_att := cnt_att + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'salary_records' AND jsonb_typeof(p_payload->'salary_records') = 'array' THEN
    FOR sal IN SELECT * FROM jsonb_array_elements(p_payload->'salary_records')
    LOOP
      IF (sal->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO salary_records (
        employee_id, company_id, month_iso, month_label,
        base_salary, attend_days, late_minutes, late_deduct,
        absent_days, overtime_amount, bonus, total_deduct, net_salary,
        status, issued_at
      ) VALUES (
        (sal->>'employee_id')::INTEGER, cid,
        COALESCE(sal->>'month_iso', sal->>'monthIso', ''),
        COALESCE(sal->>'month_label', sal->>'month', ''),
        COALESCE((sal->>'base_salary')::INTEGER, (sal->>'base')::INTEGER, 0),
        COALESCE((sal->>'attend_days')::INTEGER, 0),
        COALESCE((sal->>'late_minutes')::INTEGER, 0),
        COALESCE((sal->>'late_deduct')::INTEGER, 0),
        COALESCE((sal->>'absent_days')::INTEGER, 0),
        COALESCE((sal->>'overtime_amount')::INTEGER, (sal->>'overtime')::INTEGER, (sal->>'ot')::INTEGER, 0),
        COALESCE((sal->>'bonus')::INTEGER, 0),
        COALESCE((sal->>'total_deduct')::INTEGER, (sal->>'deductions')::INTEGER, (sal->>'deduct')::INTEGER, 0),
        COALESCE((sal->>'net_salary')::INTEGER, (sal->>'net')::INTEGER, 0),
        COALESCE(sal->>'status', 'معلق'),
        COALESCE((sal->>'issued_at')::TIMESTAMPTZ, NOW())
      )
      ON CONFLICT (employee_id, month_iso) DO UPDATE SET
        month_label = EXCLUDED.month_label,
        base_salary = EXCLUDED.base_salary,
        attend_days = EXCLUDED.attend_days,
        late_minutes = EXCLUDED.late_minutes,
        late_deduct = EXCLUDED.late_deduct,
        absent_days = EXCLUDED.absent_days,
        overtime_amount = EXCLUDED.overtime_amount,
        bonus = EXCLUDED.bonus,
        total_deduct = EXCLUDED.total_deduct,
        net_salary = EXCLUDED.net_salary,
        status = EXCLUDED.status,
        issued_at = COALESCE(EXCLUDED.issued_at, salary_records.issued_at),
        company_id = cid;
      cnt_sal := cnt_sal + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'leaves' AND jsonb_typeof(p_payload->'leaves') = 'array' THEN
    FOR lev IN SELECT * FROM jsonb_array_elements(p_payload->'leaves')
    LOOP
      IF COALESCE((lev->>'employee_id')::INTEGER, (lev->>'emp_id')::INTEGER) IS NULL THEN CONTINUE; END IF;
      INSERT INTO leaves (
        leave_ref, employee_id, company_id, leave_type, from_date, to_date, multiplier, note
      ) VALUES (
        NULLIF(trim(lev->>'leave_ref'), ''),
        COALESCE((lev->>'employee_id')::INTEGER, (lev->>'emp_id')::INTEGER),
        cid,
        COALESCE(NULLIF(trim(lev->>'leave_type'), ''), NULLIF(trim(lev->>'type'), ''), 'paid_single'),
        COALESCE((lev->>'from_date')::DATE, (lev->>'fromDate')::DATE, CURRENT_DATE),
        NULLIF(trim(COALESCE(lev->>'to_date', lev->>'toDate', '')), '')::DATE,
        GREATEST(1, COALESCE((lev->>'multiplier')::INTEGER, 1)),
        COALESCE(lev->>'note', lev->>'reason', '')
      )
      ON CONFLICT (leave_ref) DO UPDATE SET
        employee_id = EXCLUDED.employee_id,
        company_id = cid,
        leave_type = EXCLUDED.leave_type,
        from_date = EXCLUDED.from_date,
        to_date = EXCLUDED.to_date,
        multiplier = EXCLUDED.multiplier,
        note = EXCLUDED.note,
        updated_at = NOW()
      WHERE leaves.leave_ref IS NOT NULL;
      cnt_lev := cnt_lev + 1;
    END LOOP;
  END IF;

  PERFORM saas_v3_write_audit(
    audit_action, 'backup',
    'Full import: settings=' || cnt_settings::text || ' emp=' || cnt_emp::text,
    'company:' || cid::TEXT, cid,
    NULL,
    jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept,
      'super_admin', is_super AND audit_action = 'super_company_import'
    ),
    'company', cid::TEXT, NULL, NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'imported', jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept
    )
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_import_company_full(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_full(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_import_company_full(JSONB) IS
  'Full company import — schema-aligned with export (064); super admin uses payload.company_id';

-- END: 064_fix_import_company_full_schema.sql

-- ============================================================
-- BEGIN: 065_fix_audit_function_overload.sql
-- ============================================================

-- ============================================================
-- KYNO 065 — Fix saas_v3_write_audit overload ambiguity (42725)
-- Legacy 7-arg function from 031 coexists with 11-arg 056/058.
-- Calls with 7 args match BOTH → "function ... is not unique"
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

DROP FUNCTION IF EXISTS saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB);

CREATE OR REPLACE FUNCTION saas_v3_write_audit(
  p_action TEXT,
  p_category TEXT,
  p_details TEXT,
  p_target_name TEXT,
  p_company_id INTEGER,
  p_before JSONB DEFAULT NULL,
  p_after JSONB DEFAULT NULL,
  p_entity_type TEXT DEFAULT NULL,
  p_entity_id TEXT DEFAULT NULL,
  p_ip_address TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta JSONB;
  cid INTEGER;
  tenant JSONB;
BEGIN
  cid := NULLIF(p_company_id, 0);
  IF cid IS NULL OR cid <= 0 THEN
    cid := auth_company_id();
  END IF;
  IF auth_is_super_admin() AND (cid IS NULL OR cid <= 0) THEN
    cid := NULLIF(p_company_id, 0);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  meta := jsonb_build_object(
    'company_id', cid,
    'timestamp', to_jsonb(NOW()),
    'entity_type', NULLIF(trim(p_entity_type), ''),
    'entity_id', NULLIF(trim(p_entity_id), ''),
    'old_value', COALESCE(p_before, 'null'::jsonb),
    'new_value', COALESCE(p_after, 'null'::jsonb),
    'before', COALESCE(p_before, 'null'::jsonb),
    'after', COALESCE(p_after, 'null'::jsonb)
  );

  INSERT INTO audit_logs (
    company_id, actor_id, actor_name, actor_role,
    action, category, details, target_name, meta,
    ip_address, user_agent
  ) VALUES (
    cid,
    NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER,
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'display_name', auth.jwt() ->> 'email', ''),
    COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', auth_app_role()),
    COALESCE(NULLIF(trim(p_action), ''), 'unknown'),
    NULLIF(trim(p_category), ''),
    NULLIF(trim(p_details), ''),
    NULLIF(trim(p_target_name), ''),
    meta,
    NULLIF(trim(p_ip_address), ''),
    NULLIF(trim(p_user_agent), '')
  );
EXCEPTION
  WHEN others THEN
    NULL;
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION saas_v3_write_audit(TEXT, TEXT, TEXT, TEXT, INTEGER, JSONB, JSONB, TEXT, TEXT, TEXT, TEXT) IS
  'Single canonical audit writer — legacy 7-arg overload removed in 065';

-- END: 065_fix_audit_function_overload.sql

-- ============================================================
-- BEGIN: 066_super_admin_prefs.sql
-- ============================================================

-- ============================================================
-- KYNO 066 — Super Admin user prefs (theme, activity log reads)
-- Fixes no_company_context when super admin saves notifications
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

CREATE OR REPLACE FUNCTION saas_super_admin_user_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF((auth.jwt() -> 'app_metadata' ->> 'saas_user_id'), '')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_prefs_key(p_user_id INTEGER)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'global:sa_user:' || p_user_id::TEXT || ':prefs';
$$;

CREATE OR REPLACE FUNCTION saas_get_super_admin_prefs()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  raw TEXT;
  prefs JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = saas_super_admin_prefs_key(uid)
  LIMIT 1;

  prefs := COALESCE(NULLIF(trim(raw), '')::jsonb, '{}'::jsonb);
  IF jsonb_typeof(prefs) <> 'object' THEN
    prefs := '{}'::jsonb;
  END IF;

  RETURN jsonb_build_object('ok', true, 'prefs', prefs, 'user_id', uid);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin_prefs(p_prefs JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  db_key TEXT;
  existing JSONB := '{}'::jsonb;
  merged JSONB;
  raw TEXT;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  IF p_prefs IS NULL OR jsonb_typeof(p_prefs) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_prefs');
  END IF;

  db_key := saas_super_admin_prefs_key(uid);

  SELECT s.value INTO raw FROM app_settings s WHERE s.key = db_key LIMIT 1;
  IF raw IS NOT NULL AND trim(raw) <> '' THEN
    BEGIN
      existing := raw::jsonb;
    EXCEPTION WHEN others THEN
      existing := '{}'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(existing) <> 'object' THEN
    existing := '{}'::jsonb;
  END IF;

  merged := existing || p_prefs;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES (db_key, merged::text, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

  RETURN jsonb_build_object('ok', true, 'prefs', merged, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_admin_user_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_prefs_key(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_super_admin_prefs() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin_prefs(JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_get_super_admin_prefs() TO authenticated;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin_prefs(JSONB) TO authenticated;

-- END: 066_super_admin_prefs.sql

-- ============================================================
-- BEGIN: 067_fix_import_attendance_date_iso.sql
-- ============================================================

-- ============================================================
-- KYNO 067 — Fix saas_import_company_full attendance date_iso cast
-- date_iso column is DATE; 064 inserted TEXT (CURRENT_DATE::text)
-- Does NOT alter payroll math or RLS policies.
-- ============================================================

CREATE OR REPLACE FUNCTION saas_import_company_full(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  tenant JSONB;
  file_cid INTEGER;
  settings JSONB;
  k TEXT;
  v TEXT;
  cnt_settings INTEGER := 0;
  cnt_emp INTEGER := 0;
  cnt_att INTEGER := 0;
  cnt_sal INTEGER := 0;
  cnt_lev INTEGER := 0;
  cnt_dept INTEGER := 0;
  emp JSONB;
  att JSONB;
  sal JSONB;
  lev JSONB;
  dept JSONB;
  eid INTEGER;
  dept_name TEXT;
  is_super BOOLEAN := false;
  audit_action TEXT := 'company_import_full';
  att_date DATE;
  leave_from DATE;
  leave_to DATE;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payload');
  END IF;

  cid := auth_company_id();
  is_super := auth_is_super_admin();

  IF cid IS NULL OR cid <= 0 THEN
    IF is_super THEN
      IF NOT saas_super_admin_can('companies_view') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
      END IF;
      cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
      IF cid IS NULL OR cid <= 0 THEN
        RETURN jsonb_build_object(
          'ok', false,
          'error', 'invalid_company',
          'detail', 'company_id required in backup JSON for super admin import'
        );
      END IF;
      IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.id = cid) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
      END IF;
      audit_action := 'super_company_import';
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
    END IF;
  END IF;

  tenant := saas_v3_assert_tenant(cid);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  file_cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  IF file_cid IS NOT NULL AND file_cid <> cid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_id_mismatch', 'expected', cid, 'got', file_cid);
  END IF;

  settings := p_payload->'settings';
  IF settings IS NOT NULL AND jsonb_typeof(settings) = 'object' THEN
    FOR k, v IN SELECT key, value FROM jsonb_each_text(settings)
    LOOP
      IF k IS NULL OR k = '' OR k LIKE 'global:%' THEN CONTINUE; END IF;
      INSERT INTO app_settings (key, value, updated_at)
      VALUES ('company:' || cid::text || ':' || k, v, NOW())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
      cnt_settings := cnt_settings + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'finance_items' THEN
    INSERT INTO app_settings (key, value, updated_at)
    VALUES ('company:' || cid::text || ':finance_items', (p_payload->'finance_items')::text, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt_settings := cnt_settings + 1;
  END IF;

  IF p_payload ? 'departments' AND jsonb_typeof(p_payload->'departments') = 'array' THEN
    FOR dept IN SELECT * FROM jsonb_array_elements(p_payload->'departments')
    LOOP
      dept_name := NULLIF(trim(COALESCE(dept->>'name', dept->>'dept', '')), '');
      IF dept_name IS NULL THEN CONTINUE; END IF;
      INSERT INTO departments (company_id, name)
      VALUES (cid, dept_name)
      ON CONFLICT DO NOTHING;
      cnt_dept := cnt_dept + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'employees' AND jsonb_typeof(p_payload->'employees') = 'array' THEN
    FOR emp IN SELECT * FROM jsonb_array_elements(p_payload->'employees')
    LOOP
      eid := NULLIF((emp->>'id')::INTEGER, 0);
      IF eid IS NULL THEN CONTINUE; END IF;
      INSERT INTO employees (
        id, company_id, name, dept, role, phone, salary, salary_type, salary_half,
        daily_rate, days, late_min, check_in, check_out, open_hours, remote_attend,
        sal_status, sal_bonus, sal_deleted_period, avatar_url, include_overtime_in_salary
      ) VALUES (
        eid, cid,
        COALESCE(emp->>'name', ''),
        COALESCE(emp->>'dept', ''),
        COALESCE(emp->>'role', ''),
        COALESCE(emp->>'phone', '—'),
        COALESCE((emp->>'salary')::INTEGER, 0),
        COALESCE(emp->>'salary_type', emp->>'salaryType', 'monthly'),
        COALESCE((emp->>'salary_half')::INTEGER, (emp->>'salaryHalf')::INTEGER, 0),
        COALESCE((emp->>'daily_rate')::INTEGER, (emp->>'dailyRate')::INTEGER, 0),
        COALESCE((emp->>'days')::INTEGER, 0),
        COALESCE((emp->>'late_min')::INTEGER, (emp->>'lateMin')::INTEGER, 0),
        COALESCE(emp->>'check_in', emp->>'checkIn', '08:00')::TIME,
        COALESCE(emp->>'check_out', emp->>'checkOut', '17:00')::TIME,
        COALESCE((emp->>'open_hours')::BOOLEAN, (emp->>'openHours')::BOOLEAN, false),
        COALESCE((emp->>'remote_attend')::BOOLEAN, (emp->>'remoteAttend')::BOOLEAN, false),
        COALESCE(emp->>'sal_status', emp->>'salStatus', 'معلق'),
        COALESCE((emp->>'sal_bonus')::INTEGER, (emp->>'salBonus')::INTEGER, 0),
        COALESCE(emp->>'sal_deleted_period', emp->>'salDeletedPeriod', ''),
        NULLIF(emp->>'avatar_url', ''),
        COALESCE((emp->>'include_overtime_in_salary')::BOOLEAN, (emp->>'includeOvertimeInSalary')::BOOLEAN, false)
      )
      ON CONFLICT (id) DO UPDATE SET
        company_id = cid,
        name = EXCLUDED.name,
        dept = EXCLUDED.dept,
        role = EXCLUDED.role,
        phone = EXCLUDED.phone,
        salary = EXCLUDED.salary,
        salary_type = EXCLUDED.salary_type,
        salary_half = EXCLUDED.salary_half,
        daily_rate = EXCLUDED.daily_rate,
        days = EXCLUDED.days,
        late_min = EXCLUDED.late_min,
        check_in = EXCLUDED.check_in,
        check_out = EXCLUDED.check_out,
        open_hours = EXCLUDED.open_hours,
        remote_attend = EXCLUDED.remote_attend,
        sal_status = EXCLUDED.sal_status,
        sal_bonus = EXCLUDED.sal_bonus,
        sal_deleted_period = EXCLUDED.sal_deleted_period,
        avatar_url = COALESCE(EXCLUDED.avatar_url, employees.avatar_url),
        include_overtime_in_salary = EXCLUDED.include_overtime_in_salary,
        updated_at = NOW()
      WHERE employees.company_id = cid;
      cnt_emp := cnt_emp + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'attendance' AND jsonb_typeof(p_payload->'attendance') = 'array' THEN
    FOR att IN SELECT * FROM jsonb_array_elements(p_payload->'attendance')
    LOOP
      IF (att->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      att_date := CURRENT_DATE;
      BEGIN
        att_date := COALESCE(
          NULLIF(trim(COALESCE(att->>'date_iso', att->>'dateIso', '')), '')::DATE,
          CURRENT_DATE
        );
      EXCEPTION WHEN others THEN
        att_date := CURRENT_DATE;
      END;
      INSERT INTO attendance (
        employee_id, company_id, emp_name, dept, date_label, date_iso,
        check_in, check_out, hours, late, overtime, status
      ) VALUES (
        (att->>'employee_id')::INTEGER, cid,
        COALESCE(att->>'emp_name', att->>'emp', ''),
        COALESCE(att->>'dept', ''),
        COALESCE(att->>'date_label', att->>'date', ''),
        att_date,
        COALESCE(att->>'check_in', att->>'ci', '—'),
        COALESCE(att->>'check_out', att->>'co', '—'),
        COALESCE(att->>'hours', att->>'hrs', '—'),
        COALESCE(att->>'late', '—'),
        COALESCE(att->>'overtime', att->>'ot', '—'),
        COALESCE(att->>'status', 'طبيعي')
      )
      ON CONFLICT (employee_id, date_iso) DO UPDATE SET
        emp_name = EXCLUDED.emp_name,
        dept = EXCLUDED.dept,
        date_label = EXCLUDED.date_label,
        check_in = EXCLUDED.check_in,
        check_out = EXCLUDED.check_out,
        hours = EXCLUDED.hours,
        late = EXCLUDED.late,
        overtime = EXCLUDED.overtime,
        status = EXCLUDED.status,
        company_id = cid;
      cnt_att := cnt_att + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'salary_records' AND jsonb_typeof(p_payload->'salary_records') = 'array' THEN
    FOR sal IN SELECT * FROM jsonb_array_elements(p_payload->'salary_records')
    LOOP
      IF (sal->>'employee_id')::INTEGER IS NULL THEN CONTINUE; END IF;
      INSERT INTO salary_records (
        employee_id, company_id, month_iso, month_label,
        base_salary, attend_days, late_minutes, late_deduct,
        absent_days, overtime_amount, bonus, total_deduct, net_salary,
        status, issued_at
      ) VALUES (
        (sal->>'employee_id')::INTEGER, cid,
        COALESCE(sal->>'month_iso', sal->>'monthIso', ''),
        COALESCE(sal->>'month_label', sal->>'month', ''),
        COALESCE((sal->>'base_salary')::INTEGER, (sal->>'base')::INTEGER, 0),
        COALESCE((sal->>'attend_days')::INTEGER, 0),
        COALESCE((sal->>'late_minutes')::INTEGER, 0),
        COALESCE((sal->>'late_deduct')::INTEGER, 0),
        COALESCE((sal->>'absent_days')::INTEGER, 0),
        COALESCE((sal->>'overtime_amount')::INTEGER, (sal->>'overtime')::INTEGER, (sal->>'ot')::INTEGER, 0),
        COALESCE((sal->>'bonus')::INTEGER, 0),
        COALESCE((sal->>'total_deduct')::INTEGER, (sal->>'deductions')::INTEGER, (sal->>'deduct')::INTEGER, 0),
        COALESCE((sal->>'net_salary')::INTEGER, (sal->>'net')::INTEGER, 0),
        COALESCE(sal->>'status', 'معلق'),
        COALESCE((sal->>'issued_at')::TIMESTAMPTZ, NOW())
      )
      ON CONFLICT (employee_id, month_iso) DO UPDATE SET
        month_label = EXCLUDED.month_label,
        base_salary = EXCLUDED.base_salary,
        attend_days = EXCLUDED.attend_days,
        late_minutes = EXCLUDED.late_minutes,
        late_deduct = EXCLUDED.late_deduct,
        absent_days = EXCLUDED.absent_days,
        overtime_amount = EXCLUDED.overtime_amount,
        bonus = EXCLUDED.bonus,
        total_deduct = EXCLUDED.total_deduct,
        net_salary = EXCLUDED.net_salary,
        status = EXCLUDED.status,
        issued_at = COALESCE(EXCLUDED.issued_at, salary_records.issued_at),
        company_id = cid;
      cnt_sal := cnt_sal + 1;
    END LOOP;
  END IF;

  IF p_payload ? 'leaves' AND jsonb_typeof(p_payload->'leaves') = 'array' THEN
    FOR lev IN SELECT * FROM jsonb_array_elements(p_payload->'leaves')
    LOOP
      IF COALESCE((lev->>'employee_id')::INTEGER, (lev->>'emp_id')::INTEGER) IS NULL THEN CONTINUE; END IF;
      leave_from := CURRENT_DATE;
      leave_to := NULL;
      BEGIN
        leave_from := COALESCE(
          NULLIF(trim(COALESCE(lev->>'from_date', lev->>'fromDate', '')), '')::DATE,
          CURRENT_DATE
        );
      EXCEPTION WHEN others THEN
        leave_from := CURRENT_DATE;
      END;
      BEGIN
        leave_to := NULLIF(trim(COALESCE(lev->>'to_date', lev->>'toDate', '')), '')::DATE;
      EXCEPTION WHEN others THEN
        leave_to := NULL;
      END;
      INSERT INTO leaves (
        leave_ref, employee_id, company_id, leave_type, from_date, to_date, multiplier, note
      ) VALUES (
        NULLIF(trim(lev->>'leave_ref'), ''),
        COALESCE((lev->>'employee_id')::INTEGER, (lev->>'emp_id')::INTEGER),
        cid,
        COALESCE(NULLIF(trim(lev->>'leave_type'), ''), NULLIF(trim(lev->>'type'), ''), 'paid_single'),
        leave_from,
        leave_to,
        GREATEST(1, COALESCE((lev->>'multiplier')::INTEGER, 1)),
        COALESCE(lev->>'note', lev->>'reason', '')
      )
      ON CONFLICT (leave_ref) DO UPDATE SET
        employee_id = EXCLUDED.employee_id,
        company_id = cid,
        leave_type = EXCLUDED.leave_type,
        from_date = EXCLUDED.from_date,
        to_date = EXCLUDED.to_date,
        multiplier = EXCLUDED.multiplier,
        note = EXCLUDED.note,
        updated_at = NOW()
      WHERE leaves.leave_ref IS NOT NULL;
      cnt_lev := cnt_lev + 1;
    END LOOP;
  END IF;

  PERFORM saas_v3_write_audit(
    audit_action, 'backup',
    'Full import: settings=' || cnt_settings::text || ' emp=' || cnt_emp::text,
    'company:' || cid::TEXT, cid,
    NULL,
    jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept,
      'super_admin', is_super AND audit_action = 'super_company_import'
    ),
    'company', cid::TEXT, NULL, NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'imported', jsonb_build_object(
      'settings', cnt_settings, 'employees', cnt_emp, 'attendance', cnt_att,
      'salary_records', cnt_sal, 'leaves', cnt_lev, 'departments', cnt_dept
    )
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_import_company_full(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_import_company_full(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_import_company_full(JSONB) IS
  'Full company import — 067 fixes attendance date_iso DATE cast; super admin uses payload.company_id';

-- END: 067_fix_import_attendance_date_iso.sql

-- ============================================================
-- BEGIN: 068_fix_subscription_status_renew.sql
-- ============================================================

-- 068: Subscription status RPC for employee portal (anon) + harden renew audit writes

CREATE OR REPLACE FUNCTION saas_get_company_subscription_status(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
  days_left INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('valid', true, 'status', 'active', 'message', '', 'daysLeft', 0);
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'الشركة غير موجودة', 'daysLeft', 0);
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'daysLeft', 0
    );
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'pending',
      'message', 'لا يوجد اشتراك نشط',
      'daysLeft', 0
    );
  END IF;

  days_left := (sub.end_date - CURRENT_DATE);

  IF sub.status = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', 0
    );
  END IF;

  IF sub.status = 'pending' OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  IF sub.status = 'expired' AND sub.end_date >= CURRENT_DATE THEN
    UPDATE subscriptions SET status = 'active', updated_at = NOW()
    WHERE company_id = p_company_id
      AND id = (
        SELECT s2.id FROM subscriptions s2
        WHERE s2.company_id = p_company_id
        ORDER BY s2.created_at DESC NULLS LAST, s2.id DESC
        LIMIT 1
      )
      AND status = 'expired';
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'status', 'active',
    'end_date', sub.end_date,
    'daysLeft', GREATEST(days_left, 0),
    'warning', days_left <= 10,
    'message', CASE
      WHEN days_left <= 10 THEN 'ينتهي الاشتراك خلال ' || GREATEST(days_left, 0)::text || ' يوم'
      ELSE ''
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO anon, authenticated, service_role;

-- Harden renew: audit failure must not roll back a successful subscription update
DROP FUNCTION IF EXISTS saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT);

CREATE OR REPLACE FUNCTION saas_super_renew_subscription(
  p_company_id INTEGER,
  p_duration_days INTEGER DEFAULT 30,
  p_amount INTEGER DEFAULT 0,
  p_notes TEXT DEFAULT NULL,
  p_plan_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing RECORD;
  before_sub JSONB;
  after_sub JSONB;
  start_d DATE;
  end_d DATE;
  dur_days INTEGER := GREATEST(1, COALESCE(p_duration_days, 30));
  pay_amt INTEGER := GREATEST(0, COALESCE(p_amount, 0));
  dur_months INTEGER;
  note_text TEXT;
  actor TEXT;
  sub_id INTEGER;
  plan_nm TEXT := NULLIF(trim(p_plan_name), '');
  comp_before JSONB;
  comp_after companies%ROWTYPE;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_renew') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO existing FROM subscriptions
  WHERE company_id = p_company_id
  ORDER BY created_at DESC NULLS LAST, id DESC LIMIT 1;

  before_sub := CASE WHEN existing.id IS NOT NULL THEN to_jsonb(existing) ELSE NULL END;

  dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
  note_text := COALESCE(NULLIF(trim(p_notes), ''), 'تمديد ' || dur_days::text || ' يوم');
  actor := COALESCE(
    (saas_super_admin_sender_meta()->>'senderName'),
    auth.jwt() -> 'app_metadata' ->> 'display_name',
    auth.jwt() ->> 'email',
    'system'
  );

  IF existing.id IS NOT NULL AND existing.end_date >= CURRENT_DATE THEN
    start_d := COALESCE(existing.start_date, CURRENT_DATE);
    end_d := existing.end_date + dur_days;
    UPDATE subscriptions SET
      start_date = start_d, end_date = end_d, status = 'active',
      duration_months = dur_months, amount = pay_amt, notes = note_text,
      plan_name = COALESCE(plan_nm, plan_name),
      activated_by = actor, updated_at = NOW()
    WHERE id = existing.id RETURNING id INTO sub_id;
  ELSIF existing.id IS NOT NULL THEN
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    UPDATE subscriptions SET
      start_date = start_d, end_date = end_d, status = 'active',
      duration_months = dur_months, amount = pay_amt, notes = note_text,
      plan_name = COALESCE(plan_nm, plan_name),
      activated_by = actor, updated_at = NOW()
    WHERE id = existing.id RETURNING id INTO sub_id;
  ELSE
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    INSERT INTO subscriptions (
      company_id, plan_name, start_date, end_date, status,
      duration_months, amount, notes, activated_by
    ) VALUES (
      p_company_id, COALESCE(plan_nm, 'starter'), start_d, end_d, 'active',
      dur_months, pay_amt, note_text, actor
    ) RETURNING id INTO sub_id;
  END IF;

  UPDATE companies SET status = 'active', updated_at = NOW()
  WHERE id = p_company_id AND status IS DISTINCT FROM 'active';

  SELECT to_jsonb(s.*) INTO after_sub FROM subscriptions s WHERE s.id = sub_id LIMIT 1;

  IF plan_nm IS NOT NULL AND lower(plan_nm) IN ('starter', 'business', 'enterprise') THEN
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = p_company_id LIMIT 1;
    UPDATE companies SET plan_tier = lower(plan_nm), updated_at = NOW()
    WHERE id = p_company_id RETURNING * INTO comp_after;
    BEGIN
      PERFORM saas_v3_write_audit(
        'plan_tier_changed', 'subscriptions',
        'Plan tier -> ' || lower(plan_nm),
        comp_after.company_name, p_company_id,
        comp_before, to_jsonb(comp_after),
        'companies', p_company_id::TEXT, NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  BEGIN
    PERFORM saas_v3_write_audit(
      'subscription_renewed', 'subscriptions',
      'Renewed subscription ' || dur_days::text || ' days',
      COALESCE(after_sub->>'plan_name', 'subscription'),
      p_company_id,
      before_sub, after_sub,
      'subscriptions', sub_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'data', after_sub);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) TO authenticated, service_role;

COMMENT ON FUNCTION saas_get_company_subscription_status(INTEGER) IS
  'Server-side subscription validity for client UI (inclusive end_date; safe for anon employee portal)';

-- Align server attendance gate with inclusive end_date + repair stale expired flags
CREATE OR REPLACE FUNCTION saas_assert_company_active(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_suspended');
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
  END IF;

  IF sub.status IN ('suspended', 'pending') OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'status', sub.status
    );
  END IF;

  IF sub.status = 'expired' AND sub.end_date >= CURRENT_DATE THEN
    UPDATE subscriptions SET status = 'active', updated_at = NOW()
    WHERE company_id = p_company_id
      AND id = (
        SELECT s2.id FROM subscriptions s2
        WHERE s2.company_id = p_company_id
        ORDER BY s2.created_at DESC NULLS LAST, s2.id DESC
        LIMIT 1
      )
      AND status = 'expired';
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION saas_assert_company_active(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_assert_company_active(INTEGER) TO authenticated, service_role;

-- END: 068_fix_subscription_status_renew.sql

-- ============================================================
-- BEGIN: 069_logout_cloud_sync.sql
-- ============================================================

-- 069: Allow logout cloud sync (audit + notification log) even when subscription gate would block writes

CREATE OR REPLACE FUNCTION saas_record_client_audit(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  action TEXT;
  active_chk JSONB;
BEGIN
  cid := auth_company_id();
  IF (cid IS NULL OR cid <= 0) AND auth_is_super_admin() THEN
    cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  END IF;

  action := COALESCE(NULLIF(trim(p_payload->>'action'), ''), 'client_event');

  IF cid IS NULL OR cid <= 0 THEN
    IF auth_is_super_admin() AND action IN ('logout', 'login') THEN
      RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'super_admin_no_company');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT auth_is_super_admin() AND action NOT IN ('logout', 'login') THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(active_chk->>'error', 'subscription_inactive'));
    END IF;
  END IF;

  BEGIN
    PERFORM saas_v3_write_audit(
      action,
      COALESCE(NULLIF(trim(p_payload->>'category'), ''), 'client'),
      COALESCE(p_payload->>'details', action),
      COALESCE(p_payload->>'target_name', ''),
      cid,
      p_payload->'old_value',
      p_payload->'new_value',
      p_payload->>'entity_type',
      p_payload->>'entity_id',
      p_payload->>'ip_address',
      p_payload->>'user_agent'
    );
  EXCEPTION WHEN OTHERS THEN
    IF action IN ('logout', 'login') THEN
      RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'audit_write_failed');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION saas_record_client_audit(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_record_client_audit(JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION saas_upsert_tenant_settings(p_settings JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  k TEXT;
  v TEXT;
  db_key TEXT;
  cnt INTEGER := 0;
  old_snapshot JSONB := '{}'::jsonb;
  new_snapshot JSONB := '{}'::jsonb;
  old_val TEXT;
  audit_keys TEXT[] := ARRAY[
    'companyName', 'lateDeductPerMin', 'absentDeduct', 'overtimeRate',
    'biweeklySplitDay', 'standardMonthDays', 'finance_items', 'leaveSettings',
    'departments_json', 'jobs_json', 'gpsLat', 'gpsLng', 'gpsRange'
  ];
  is_audit_key BOOLEAN;
  log_only BOOLEAN := TRUE;
  key_rec RECORD;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR key_rec IN SELECT key FROM jsonb_each(p_settings)
  LOOP
    IF key_rec.key NOT IN ('activity_log', 'employee_notifications') THEN
      log_only := FALSE;
      EXIT;
    END IF;
  END LOOP;

  IF NOT log_only THEN
    IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
    END IF;
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(p_settings)
  LOOP
    IF k IS NULL OR k = '' THEN CONTINUE; END IF;
    db_key := 'company:' || cid::text || ':' || k;
    SELECT s.value INTO old_val FROM app_settings s WHERE s.key = db_key LIMIT 1;
    IF old_val IS NOT NULL THEN
      old_snapshot := old_snapshot || jsonb_build_object(k, old_val);
    END IF;
    new_snapshot := new_snapshot || jsonb_build_object(k, v);
    INSERT INTO app_settings (key, value, updated_at)
    VALUES (db_key, v, NOW())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
    cnt := cnt + 1;
  END LOOP;

  IF NOT log_only THEN
    BEGIN
      PERFORM saas_v3_write_audit(
        'settings_updated', 'settings',
        'Updated ' || cnt::text || ' tenant settings (versioned)',
        'company:' || cid::text,
        cid,
        old_snapshot, new_snapshot,
        'app_settings', cid::TEXT, NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_tenant_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_tenant_settings(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_record_client_audit(JSONB) IS
  'Client audit writer — logout/login always allowed; super admin without tenant returns ok skipped';

-- END: 069_logout_cloud_sync.sql

-- ============================================================
-- BEGIN: 070_fix_renew_subscription_overload.sql
-- ============================================================

-- 070: Fix PGRST203 — drop legacy 4-arg saas_super_renew_subscription overload
-- PostgREST cannot choose between (int,int,int,text) and (int,int,int,text,text) when p_plan_name is omitted.

DROP FUNCTION IF EXISTS saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT);

CREATE OR REPLACE FUNCTION saas_super_renew_subscription(
  p_company_id INTEGER,
  p_duration_days INTEGER DEFAULT 30,
  p_amount INTEGER DEFAULT 0,
  p_notes TEXT DEFAULT NULL,
  p_plan_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing RECORD;
  before_sub JSONB;
  after_sub JSONB;
  start_d DATE;
  end_d DATE;
  dur_days INTEGER := GREATEST(1, COALESCE(p_duration_days, 30));
  pay_amt INTEGER := GREATEST(0, COALESCE(p_amount, 0));
  dur_months INTEGER;
  note_text TEXT;
  actor TEXT;
  sub_id INTEGER;
  plan_nm TEXT := NULLIF(trim(p_plan_name), '');
  comp_before JSONB;
  comp_after companies%ROWTYPE;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT saas_super_admin_can('subscriptions_renew') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT * INTO existing FROM subscriptions
  WHERE company_id = p_company_id
  ORDER BY created_at DESC NULLS LAST, id DESC LIMIT 1;

  before_sub := CASE WHEN existing.id IS NOT NULL THEN to_jsonb(existing) ELSE NULL END;

  dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
  note_text := COALESCE(NULLIF(trim(p_notes), ''), 'تمديد ' || dur_days::text || ' يوم');
  actor := COALESCE(
    (saas_super_admin_sender_meta()->>'senderName'),
    auth.jwt() -> 'app_metadata' ->> 'display_name',
    auth.jwt() ->> 'email',
    'system'
  );

  IF existing.id IS NOT NULL AND existing.end_date >= CURRENT_DATE THEN
    start_d := COALESCE(existing.start_date, CURRENT_DATE);
    end_d := existing.end_date + dur_days;
    UPDATE subscriptions SET
      start_date = start_d, end_date = end_d, status = 'active',
      duration_months = dur_months, amount = pay_amt, notes = note_text,
      plan_name = COALESCE(plan_nm, plan_name),
      activated_by = actor, updated_at = NOW()
    WHERE id = existing.id RETURNING id INTO sub_id;
  ELSIF existing.id IS NOT NULL THEN
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    UPDATE subscriptions SET
      start_date = start_d, end_date = end_d, status = 'active',
      duration_months = dur_months, amount = pay_amt, notes = note_text,
      plan_name = COALESCE(plan_nm, plan_name),
      activated_by = actor, updated_at = NOW()
    WHERE id = existing.id RETURNING id INTO sub_id;
  ELSE
    start_d := CURRENT_DATE;
    end_d := CURRENT_DATE + dur_days;
    INSERT INTO subscriptions (
      company_id, plan_name, start_date, end_date, status,
      duration_months, amount, notes, activated_by
    ) VALUES (
      p_company_id, COALESCE(plan_nm, 'starter'), start_d, end_d, 'active',
      dur_months, pay_amt, note_text, actor
    ) RETURNING id INTO sub_id;
  END IF;

  UPDATE companies SET status = 'active', updated_at = NOW()
  WHERE id = p_company_id AND status IS DISTINCT FROM 'active';

  SELECT to_jsonb(s.*) INTO after_sub FROM subscriptions s WHERE s.id = sub_id LIMIT 1;

  IF plan_nm IS NOT NULL AND lower(plan_nm) IN ('starter', 'business', 'enterprise') THEN
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = p_company_id LIMIT 1;
    UPDATE companies SET plan_tier = lower(plan_nm), updated_at = NOW()
    WHERE id = p_company_id RETURNING * INTO comp_after;
    BEGIN
      PERFORM saas_v3_write_audit(
        'plan_tier_changed', 'subscriptions',
        'Plan tier -> ' || lower(plan_nm),
        comp_after.company_name, p_company_id,
        comp_before, to_jsonb(comp_after),
        'companies', p_company_id::TEXT, NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  BEGIN
    PERFORM saas_v3_write_audit(
      'subscription_renewed', 'subscriptions',
      'Renewed subscription ' || dur_days::text || ' days',
      COALESCE(after_sub->>'plan_name', 'subscription'),
      p_company_id,
      before_sub, after_sub,
      'subscriptions', sub_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'data', after_sub);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) TO authenticated, service_role;

COMMENT ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) IS
  'Single canonical renew RPC (5 args) — legacy 4-arg overload removed for PostgREST';

-- END: 070_fix_renew_subscription_overload.sql

-- ============================================================
-- BEGIN: 071_super_admin_prefs_timeout.sql
-- ============================================================

-- 071: Fix super admin prefs timeout — cap activity_log, fast merge, trim bloated rows

CREATE OR REPLACE FUNCTION saas_super_admin_trim_activity_log(p_log JSONB, p_max INTEGER DEFAULT 120)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  arr JSONB;
  max_n INTEGER := GREATEST(20, LEAST(COALESCE(p_max, 120), 200));
BEGIN
  IF p_log IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  arr := p_log;
  IF jsonb_typeof(arr) = 'string' THEN
    BEGIN
      arr := (p_log #>> '{}')::jsonb;
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_array_length(arr) <= max_n THEN
    RETURN arr;
  END IF;
  RETURN (
    SELECT COALESCE(jsonb_agg(x ORDER BY ord), '[]'::jsonb)
    FROM (
      SELECT x, ord
      FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord)
      WHERE ord <= max_n
    ) s
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_parse_activity_log(p_val JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  raw TEXT;
BEGIN
  IF p_val IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_val) = 'array' THEN
    RETURN saas_super_admin_trim_activity_log(p_val, 120);
  END IF;
  IF jsonb_typeof(p_val) = 'string' THEN
    raw := p_val #>> '{}';
    IF raw IS NULL OR trim(raw) = '' THEN
      RETURN '[]'::jsonb;
    END IF;
    BEGIN
      RETURN saas_super_admin_trim_activity_log(raw::jsonb, 120);
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  RETURN '[]'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin_prefs(p_prefs JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  db_key TEXT;
  existing JSONB := '{}'::jsonb;
  merged JSONB;
  raw TEXT;
  existing_log JSONB := '[]'::jsonb;
  incoming_log JSONB := '[]'::jsonb;
  merged_log JSONB := '[]'::jsonb;
  keep_keys JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  IF p_prefs IS NULL OR jsonb_typeof(p_prefs) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_prefs');
  END IF;

  db_key := saas_super_admin_prefs_key(uid);

  SELECT s.value INTO raw FROM app_settings s WHERE s.key = db_key LIMIT 1;

  IF raw IS NOT NULL AND length(raw) > 800000 THEN
    BEGIN
      existing := raw::jsonb;
    EXCEPTION WHEN others THEN
      existing := '{}'::jsonb;
    END;
    keep_keys := jsonb_strip_nulls(jsonb_build_object(
      'theme', existing->'theme',
      'ui_theme', existing->'ui_theme'
    ));
    existing := COALESCE(keep_keys, '{}'::jsonb);
  ELSIF raw IS NOT NULL AND trim(raw) <> '' THEN
    BEGIN
      existing := raw::jsonb;
    EXCEPTION WHEN others THEN
      existing := '{}'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(existing) <> 'object' THEN
    existing := '{}'::jsonb;
  END IF;

  merged := existing || p_prefs;

  IF p_prefs ? 'activity_log' THEN
    existing_log := saas_super_admin_parse_activity_log(existing->'activity_log');
    incoming_log := saas_super_admin_parse_activity_log(p_prefs->'activity_log');
    IF jsonb_array_length(incoming_log) > 0 THEN
      merged_log := saas_super_admin_trim_activity_log(incoming_log, 120);
    ELSE
      merged_log := existing_log;
    END IF;
    merged := merged - 'activity_log' || jsonb_build_object('activity_log', merged_log);
  ELSIF existing ? 'activity_log' THEN
    merged := merged - 'activity_log' || jsonb_build_object(
      'activity_log', saas_super_admin_parse_activity_log(existing->'activity_log')
    );
  END IF;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES (db_key, merged::text, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', uid,
    'activity_count', jsonb_array_length(COALESCE(merged->'activity_log', '[]'::jsonb))
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_admin_trim_activity_log(JSONB, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_parse_activity_log(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin_prefs(JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_upsert_super_admin_prefs(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_upsert_super_admin_prefs(JSONB) IS
  'Super admin prefs — activity_log capped at 120 entries; auto-trims bloated legacy rows';

CREATE OR REPLACE FUNCTION saas_get_super_admin_prefs()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  raw TEXT;
  prefs JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = saas_super_admin_prefs_key(uid)
  LIMIT 1;

  prefs := COALESCE(NULLIF(trim(raw), '')::jsonb, '{}'::jsonb);
  IF jsonb_typeof(prefs) <> 'object' THEN
    prefs := '{}'::jsonb;
  END IF;

  IF prefs ? 'activity_log' THEN
    prefs := prefs || jsonb_build_object(
      'activity_log', saas_super_admin_parse_activity_log(prefs->'activity_log')
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'prefs', prefs, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION saas_get_super_admin_prefs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_super_admin_prefs() TO authenticated;

-- END: 071_super_admin_prefs_timeout.sql

-- ============================================================
-- BEGIN: 072_stabilize_settings_notifications_employee_ui.sql
-- ============================================================

-- 072: Stabilize app_settings / super-admin prefs / RLS / hot indexes
-- Fixes repeated 57014 timeouts and closes global:sa_user prefs leakage.

-- ----------------------------------------------------------
-- 1) Hot indexes (safe / idempotent)
-- ----------------------------------------------------------
CREATE INDEX IF NOT EXISTS app_settings_key_like_idx
  ON app_settings (key text_pattern_ops);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'subscriptions'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'subscriptions' AND column_name = 'company_id'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'subscriptions' AND column_name = 'created_at'
    ) THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS subscriptions_company_latest_idx ON subscriptions (company_id, created_at DESC, id DESC)';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'attendance'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'attendance' AND column_name = 'employee_id'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'attendance' AND column_name = 'date_iso'
    ) THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS attendance_employee_date_idx ON attendance (employee_id, date_iso DESC)';
    END IF;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'salary_records'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'salary_records' AND column_name = 'paid_at'
    ) THEN
      ALTER TABLE salary_records ADD COLUMN paid_at TIMESTAMPTZ;
    END IF;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'employee_notifications'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'employee_notifications' AND column_name = 'employee_id'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'employee_notifications' AND column_name = 'created_at'
    ) THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS employee_notifications_emp_created_idx ON employee_notifications (employee_id, created_at DESC)';
    END IF;
  END IF;
END $$;

-- ----------------------------------------------------------
-- 2) Tight app_settings RLS
-- ----------------------------------------------------------
DROP POLICY IF EXISTS "settings_read" ON app_settings;
DROP POLICY IF EXISTS "settings_write" ON app_settings;
DROP POLICY IF EXISTS "settings_update" ON app_settings;
DROP POLICY IF EXISTS "settings_deny_anon" ON app_settings;
DROP POLICY IF EXISTS "settings_select_tenant" ON app_settings;
DROP POLICY IF EXISTS "settings_write_tenant" ON app_settings;
DROP POLICY IF EXISTS "settings_update_tenant" ON app_settings;
DROP POLICY IF EXISTS "tenant_settings_only" ON app_settings;
DROP POLICY IF EXISTS "super_admin_access_settings" ON app_settings;
DROP POLICY IF EXISTS deny_anon_app_settings ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_only ON app_settings;
DROP POLICY IF EXISTS app_settings_super_admin ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_select ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_insert ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_update ON app_settings;
DROP POLICY IF EXISTS app_settings_tenant_delete ON app_settings;

CREATE POLICY deny_anon_app_settings ON app_settings
  FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE POLICY app_settings_tenant_select ON app_settings
  FOR SELECT TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND (
        key LIKE ('company:' || auth_company_id()::text || ':%')
        OR key IN (
          'global:support_whatsapp',
          'global:support_whatsapp_team',
          'global:platform_announcements',
          'platform:system_version'
        )
      )
    )
  );

CREATE POLICY app_settings_tenant_insert ON app_settings
  FOR INSERT TO authenticated
  WITH CHECK (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  );

CREATE POLICY app_settings_tenant_update ON app_settings
  FOR UPDATE TO authenticated
  USING (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  )
  WITH CHECK (
    auth_is_super_admin()
    OR (
      auth_company_id() IS NOT NULL
      AND key LIKE ('company:' || auth_company_id()::text || ':%')
    )
  );

CREATE POLICY app_settings_tenant_delete ON app_settings
  FOR DELETE TO authenticated
  USING (auth_is_super_admin());

-- ----------------------------------------------------------
-- 3) Super admin prefs: parse safely, cap activity_log, avoid huge-row timeouts
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_super_admin_extract_theme_from_raw(p_raw TEXT)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  m TEXT[];
  theme TEXT;
BEGIN
  IF p_raw IS NULL OR p_raw = '' THEN
    RETURN '{}'::jsonb;
  END IF;
  m := regexp_match(p_raw, '"ui_theme"\s*:\s*"([^"]+)"');
  IF m IS NOT NULL THEN
    theme := m[1];
    IF theme IN ('light', 'dark') THEN
      RETURN jsonb_build_object('ui_theme', theme);
    END IF;
  END IF;
  m := regexp_match(p_raw, '"theme"\s*:\s*"([^"]+)"');
  IF m IS NOT NULL THEN
    theme := m[1];
    IF theme IN ('light', 'dark') THEN
      RETURN jsonb_build_object('theme', theme);
    END IF;
  END IF;
  RETURN '{}'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_trim_activity_log(p_log JSONB, p_max INTEGER DEFAULT 120)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  arr JSONB;
  max_n INTEGER := GREATEST(20, LEAST(COALESCE(p_max, 120), 200));
BEGIN
  IF p_log IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  arr := p_log;
  IF jsonb_typeof(arr) = 'string' THEN
    BEGIN
      arr := (p_log #>> '{}')::jsonb;
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN (
    SELECT COALESCE(jsonb_agg(x ORDER BY keep_ord), '[]'::jsonb)
    FROM (
      SELECT x, keep_ord
      FROM (
        SELECT DISTINCT ON (COALESCE(x->>'id', ord::text))
          x,
          ord AS keep_ord
        FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord)
        ORDER BY COALESCE(x->>'id', ord::text), ord
      ) dedup
      ORDER BY keep_ord
      LIMIT max_n
    ) limited
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_parse_activity_log(p_val JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  raw TEXT;
BEGIN
  IF p_val IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_val) = 'array' THEN
    RETURN saas_super_admin_trim_activity_log(p_val, 120);
  END IF;
  IF jsonb_typeof(p_val) = 'string' THEN
    raw := p_val #>> '{}';
    IF raw IS NULL OR trim(raw) = '' OR length(raw) > 800000 THEN
      RETURN '[]'::jsonb;
    END IF;
    BEGIN
      RETURN saas_super_admin_trim_activity_log(raw::jsonb, 120);
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  RETURN '[]'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION saas_get_super_admin_prefs()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  raw TEXT;
  prefs JSONB := '{}'::jsonb;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = saas_super_admin_prefs_key(uid)
  LIMIT 1;

  IF raw IS NULL OR trim(raw) = '' THEN
    RETURN jsonb_build_object('ok', true, 'prefs', '{}'::jsonb, 'user_id', uid);
  END IF;

  IF length(raw) > 800000 THEN
    prefs := saas_super_admin_extract_theme_from_raw(raw);
    RETURN jsonb_build_object('ok', true, 'prefs', prefs || jsonb_build_object('activity_log', '[]'::jsonb), 'user_id', uid, 'trim_required', true);
  END IF;

  BEGIN
    prefs := raw::jsonb;
  EXCEPTION WHEN others THEN
    prefs := '{}'::jsonb;
  END;

  IF jsonb_typeof(prefs) <> 'object' THEN
    prefs := '{}'::jsonb;
  END IF;

  IF prefs ? 'activity_log' THEN
    prefs := prefs - 'activity_log' || jsonb_build_object(
      'activity_log', saas_super_admin_parse_activity_log(prefs->'activity_log')
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'prefs', prefs, 'user_id', uid);
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin_prefs(p_prefs JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  db_key TEXT;
  raw TEXT;
  existing JSONB := '{}'::jsonb;
  incoming JSONB;
  merged JSONB;
  existing_log JSONB := '[]'::jsonb;
  incoming_log JSONB := '[]'::jsonb;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  IF p_prefs IS NULL OR jsonb_typeof(p_prefs) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_prefs');
  END IF;

  incoming := p_prefs;
  db_key := saas_super_admin_prefs_key(uid);

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = db_key
  LIMIT 1;

  IF raw IS NOT NULL AND trim(raw) <> '' THEN
    IF length(raw) > 800000 THEN
      existing := saas_super_admin_extract_theme_from_raw(raw);
    ELSE
      BEGIN
        existing := raw::jsonb;
      EXCEPTION WHEN others THEN
        existing := '{}'::jsonb;
      END;
    END IF;
  END IF;

  IF jsonb_typeof(existing) <> 'object' THEN
    existing := '{}'::jsonb;
  END IF;

  existing_log := saas_super_admin_parse_activity_log(existing->'activity_log');
  incoming_log := saas_super_admin_parse_activity_log(incoming->'activity_log');

  merged := existing || incoming;
  IF incoming ? 'activity_log' OR existing ? 'activity_log' THEN
    merged := merged - 'activity_log' || jsonb_build_object(
      'activity_log',
      saas_super_admin_trim_activity_log(incoming_log || existing_log, 120)
    );
  END IF;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES (db_key, merged::text, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

  RETURN jsonb_build_object(
    'ok', true,
    'prefs', merged,
    'user_id', uid,
    'activity_count', jsonb_array_length(COALESCE(merged->'activity_log', '[]'::jsonb))
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- Replace bloated legacy super-admin prefs without parsing them.
UPDATE app_settings
SET value = saas_super_admin_extract_theme_from_raw(value)::text,
    updated_at = NOW()
WHERE key LIKE 'global:sa_user:%:prefs'
  AND length(COALESCE(value, '')) > 800000;

REVOKE ALL ON FUNCTION saas_super_admin_extract_theme_from_raw(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_trim_activity_log(JSONB, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_parse_activity_log(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_super_admin_prefs() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin_prefs(JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_get_super_admin_prefs() TO authenticated;
GRANT EXECUTE ON FUNCTION saas_upsert_super_admin_prefs(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_get_super_admin_prefs() IS
  'Safe super-admin prefs reader; avoids parsing bloated legacy JSON rows';
COMMENT ON FUNCTION saas_upsert_super_admin_prefs(JSONB) IS
  'Safe super-admin prefs writer; caps activity_log and preserves newest entries';

-- ----------------------------------------------------------
-- 4) Employee phone profile: return job / phone / salary fields
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
  v_finance TEXT;
  finance_arr JSONB := '[]'::jsonb;
  emp_finance JSONB := '[]'::jsonb;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF emp.company_id IS NOT NULL THEN
    gps_prefix := 'company:' || emp.company_id::text || ':';
    SELECT value INTO v_lat FROM app_settings WHERE key = gps_prefix || 'gps_lat' LIMIT 1;
    SELECT value INTO v_lng FROM app_settings WHERE key = gps_prefix || 'gps_lng' LIMIT 1;
    SELECT value INTO v_range FROM app_settings WHERE key = gps_prefix || 'gps_range' LIMIT 1;
    SELECT value INTO v_name FROM app_settings WHERE key = gps_prefix || 'gps_name' LIMIT 1;
    SELECT value INTO v_finance FROM app_settings WHERE key = gps_prefix || 'finance_items' LIMIT 1;
  END IF;

  IF v_finance IS NOT NULL AND v_finance <> '' THEN
    BEGIN
      finance_arr := v_finance::jsonb;
    EXCEPTION WHEN others THEN
      finance_arr := '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(COALESCE(finance_arr, '[]'::jsonb)) <> 'array' THEN
    finance_arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO emp_finance
  FROM jsonb_array_elements(COALESCE(finance_arr, '[]'::jsonb)) item
  WHERE (item->>'empId')::text = emp.id::text
     OR (item->>'emp_id')::text = emp.id::text
     OR (item->>'employee_id')::text = emp.id::text;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'role', emp.role,
    'phone', emp.phone,
    'salary', emp.salary,
    'salary_type', emp.salary_type,
    'salary_half', emp.salary_half,
    'daily_rate', emp.daily_rate,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url,
    'finance_items', emp_finance,
    'gps_lat', NULLIF(trim(v_lat), ''),
    'gps_lng', NULLIF(trim(v_lng), ''),
    'gps_range', NULLIF(trim(v_range), ''),
    'gps_name', NULLIF(trim(v_name), '')
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_client_profile(INTEGER, TEXT, TEXT) IS
  'Device-authorized employee profile with job, department, phone, salary and GPS settings';

CREATE OR REPLACE FUNCTION saas_fetch_employee_leaves(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  rows JSONB;
  lim INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 120), 300));
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF emp.remote_attend IS TRUE THEN
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.from_date DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT *
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = emp.company_id
    ORDER BY l.from_date DESC, l.id DESC
    LIMIT lim
  ) x;

  RETURN jsonb_build_object('ok', true, 'data', rows);
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_leaves(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_leaves(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_leaves(INTEGER, TEXT, TEXT, INTEGER) IS
  'Device-authorized employee leave/absence list for the phone portal';

CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  table_rows JSONB := '[]'::jsonb;
  settings_rows JSONB := '[]'::jsonb;
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  settings_key := 'company:' || emp.company_id::text || ':employee_notifications';
  SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  IF raw_val IS NULL THEN
    settings_key := 'company:' || emp.company_id::text || ':employeeNotifications';
    SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  END IF;

  IF raw_val IS NOT NULL AND raw_val <> '' THEN
    BEGIN
      arr := raw_val::jsonb;
    EXCEPTION WHEN others THEN
      arr := '[]'::jsonb;
    END;
  ELSE
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO settings_rows
  FROM (
    SELECT x
    FROM jsonb_array_elements(COALESCE(arr, '[]'::jsonb)) x
    WHERE (x->>'empId')::text = p_employee_id::text
       OR (x->>'emp_id')::text = p_employee_id::text
    ORDER BY COALESCE(x->>'ts', x->>'createdAt', x->>'created_at') DESC NULLS LAST
    LIMIT lim
  ) s;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', COALESCE(n.notif_ref, n.id::text),
        '_remote_id', n.id,
        'emp_id', n.employee_id,
        'employee_id', n.employee_id,
        'title', n.title,
        'body', n.body,
        'type', n.notif_type,
        'finance_type', n.notif_type,
        'is_read', n.is_read,
        'created_at', n.created_at,
        'company_id', n.company_id,
        '_source', 'table'
      ) ORDER BY n.created_at DESC
    ), '[]'::jsonb
  ) INTO table_rows
  FROM (
    SELECT * FROM employee_notifications en
    WHERE en.employee_id = p_employee_id AND en.company_id = emp.company_id
    ORDER BY en.created_at DESC LIMIT lim
  ) n;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'notifications', table_rows || settings_rows,
    'table_notifications', table_rows,
    'settings_notifications', settings_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_notifications(INTEGER, TEXT, TEXT, INTEGER) IS
  'Device-authorized merged employee notifications for the phone portal';

CREATE OR REPLACE FUNCTION saas_fetch_employee_salary_records(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
  sub_chk JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  IF emp.remote_attend IS TRUE THEN authorized := TRUE; END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso DESC), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM salary_records sr
    WHERE sr.employee_id = p_employee_id
      AND sr.company_id = emp.company_id
      AND sr.status = 'مدفوع'
    ORDER BY sr.month_iso DESC
    LIMIT lim
  ) s;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

REVOKE ALL ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) TO anon, authenticated;

COMMENT ON FUNCTION saas_fetch_employee_salary_records(INTEGER, TEXT, TEXT, INTEGER) IS
  'Device-authorized paid salary history for the employee phone portal';

CREATE OR REPLACE FUNCTION saas_mark_salary_record_paid(
  p_employee_id INTEGER,
  p_month TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  emp RECORD;
  rec salary_records%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR NULLIF(trim(COALESCE(p_month, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT * INTO emp FROM employees e
  WHERE e.id = p_employee_id AND e.company_id = cid
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  UPDATE salary_records
  SET status = 'مدفوع',
      paid_at = COALESCE(paid_at, NOW()),
      issued_at = COALESCE(issued_at, NOW())
  WHERE employee_id = p_employee_id
    AND company_id = cid
    AND month_iso = p_month
  RETURNING * INTO rec;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'salary_record_not_found');
  END IF;

  UPDATE employees
  SET sal_status = 'مدفوع'
  WHERE id = p_employee_id AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(rec));
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_salary_record_paid(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_salary_record_paid(INTEGER, TEXT) TO authenticated;

COMMENT ON FUNCTION saas_mark_salary_record_paid(INTEGER, TEXT) IS
  'Marks an issued salary record as paid so it appears in employee salary history';

DROP FUNCTION IF EXISTS saas_update_salary_record_status(INTEGER, TEXT, TEXT);
DROP FUNCTION IF EXISTS saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION saas_update_salary_record_status(
  p_employee_id INTEGER,
  p_month TEXT,
  p_status TEXT,
  p_paid_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  emp RECORD;
  rec salary_records%ROWTYPE;
  st TEXT := NULLIF(trim(COALESCE(p_status, '')), '');
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR NULLIF(trim(COALESCE(p_month, '')), '') IS NULL OR st IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF st NOT IN ('معلق', 'مُصدر', 'مدفوع') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT * INTO emp FROM employees e
  WHERE e.id = p_employee_id AND e.company_id = cid
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
  END IF;

  UPDATE salary_records
  SET status = st,
      paid_at = CASE WHEN st = 'مدفوع' THEN COALESCE(p_paid_at, paid_at, NOW()) ELSE NULL END,
      issued_at = COALESCE(issued_at, NOW())
  WHERE employee_id = p_employee_id
    AND company_id = cid
    AND month_iso = p_month
  RETURNING * INTO rec;

  UPDATE employees
  SET sal_status = st
  WHERE id = p_employee_id AND company_id = cid;

  RETURN jsonb_build_object('ok', true, 'data', COALESCE(to_jsonb(rec), jsonb_build_object(
    'employee_id', p_employee_id,
    'company_id', cid,
    'month_iso', p_month,
    'status', st
  )));
END;
$$;

REVOKE ALL ON FUNCTION saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;

COMMENT ON FUNCTION saas_update_salary_record_status(INTEGER, TEXT, TEXT, TIMESTAMPTZ) IS
  'Updates salary record and employee salary status for pending/issued/paid transitions';

-- END: 072_stabilize_settings_notifications_employee_ui.sql

-- ============================================================
-- BEGIN: 073_super_admin_edit_subscription.sql
-- ============================================================

-- 073: Super admin — edit subscription (company name, max employees, duration)

CREATE OR REPLACE FUNCTION saas_super_edit_subscription(
  p_subscription_id INTEGER,
  p_company_name TEXT DEFAULT NULL,
  p_max_employees INTEGER DEFAULT NULL,
  p_duration_days INTEGER DEFAULT NULL,
  p_amount INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub subscriptions%ROWTYPE;
  cid INTEGER;
  dur_days INTEGER;
  start_d DATE;
  end_d DATE;
  dur_months INTEGER;
  pay_amt INTEGER;
  comp_before JSONB;
  comp_after companies%ROWTYPE;
  sub_before JSONB;
  sub_after JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT (
    saas_super_admin_can('subscriptions_edit')
    OR saas_super_admin_can('subscriptions_renew')
    OR saas_super_admin_can('companies_edit')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_subscription_id IS NULL OR p_subscription_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_subscription');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF sub.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_not_found');
  END IF;

  cid := sub.company_id;
  sub_before := to_jsonb(sub);

  IF p_company_name IS NOT NULL OR p_max_employees IS NOT NULL THEN
    IF NOT saas_super_admin_can('companies_edit')
       AND NOT saas_super_admin_can('subscriptions_edit')
       AND NOT saas_super_admin_can('subscriptions_renew') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = cid LIMIT 1;
    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_company_name), ''), company_name),
      max_employees = CASE
        WHEN p_max_employees IS NOT NULL AND p_max_employees > 0 THEN p_max_employees
        ELSE max_employees
      END,
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO comp_after;
    IF comp_after.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;
  END IF;

  IF p_duration_days IS NOT NULL OR p_amount IS NOT NULL THEN
    dur_days := GREATEST(1, COALESCE(p_duration_days, GREATEST(1, (sub.end_date - CURRENT_DATE))));
    start_d := CURRENT_DATE;
    end_d := start_d + dur_days;
    dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
    pay_amt := CASE
      WHEN p_amount IS NOT NULL THEN GREATEST(0, p_amount)
      ELSE COALESCE(sub.amount, 0)
    END;

    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      duration_months = dur_months,
      amount = pay_amt,
      status = CASE WHEN end_d >= CURRENT_DATE THEN 'active' ELSE 'expired' END,
      updated_at = NOW()
    WHERE id = p_subscription_id
    RETURNING * INTO sub;
  END IF;

  SELECT to_jsonb(s.*) INTO sub_after FROM subscriptions s WHERE s.id = p_subscription_id LIMIT 1;

  BEGIN
    PERFORM saas_v3_write_audit(
      'subscription_edited', 'subscriptions',
      'Edited subscription #' || p_subscription_id::text || ' for company ' || cid::text,
      'subscription:' || p_subscription_id::text,
      cid,
      sub_before, sub_after,
      'subscriptions', p_subscription_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'subscription_id', p_subscription_id,
    'company_id', cid,
    'data', sub_after
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) TO authenticated, service_role;

COMMENT ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) IS
  'Super admin — edit subscription duration/amount and company name/max_employees';

-- END: 073_super_admin_edit_subscription.sql

-- ============================================================
-- BEGIN: 074_fix_edit_subscription_duration_from_today.sql
-- ============================================================

-- 074: Fix edit subscription — duration counts from today (not original start_date)

CREATE OR REPLACE FUNCTION saas_super_edit_subscription(
  p_subscription_id INTEGER,
  p_company_name TEXT DEFAULT NULL,
  p_max_employees INTEGER DEFAULT NULL,
  p_duration_days INTEGER DEFAULT NULL,
  p_amount INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub subscriptions%ROWTYPE;
  cid INTEGER;
  dur_days INTEGER;
  start_d DATE;
  end_d DATE;
  dur_months INTEGER;
  pay_amt INTEGER;
  comp_before JSONB;
  comp_after companies%ROWTYPE;
  sub_before JSONB;
  sub_after JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT (
    saas_super_admin_can('subscriptions_edit')
    OR saas_super_admin_can('subscriptions_renew')
    OR saas_super_admin_can('companies_edit')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_subscription_id IS NULL OR p_subscription_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_subscription');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF sub.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_not_found');
  END IF;

  cid := sub.company_id;
  sub_before := to_jsonb(sub);

  IF p_company_name IS NOT NULL OR p_max_employees IS NOT NULL THEN
    IF NOT saas_super_admin_can('companies_edit')
       AND NOT saas_super_admin_can('subscriptions_edit')
       AND NOT saas_super_admin_can('subscriptions_renew') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = cid LIMIT 1;
    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_company_name), ''), company_name),
      max_employees = CASE
        WHEN p_max_employees IS NOT NULL AND p_max_employees > 0 THEN p_max_employees
        ELSE max_employees
      END,
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO comp_after;
    IF comp_after.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;
  END IF;

  IF p_duration_days IS NOT NULL OR p_amount IS NOT NULL THEN
    dur_days := GREATEST(1, COALESCE(p_duration_days, GREATEST(1, (sub.end_date - CURRENT_DATE))));
    -- المدة الجديدة تُحسب من اليوم حتى يرى المستخدم نفس عدد الأيام التي أدخلها السوبر أدمن
    start_d := CURRENT_DATE;
    end_d := start_d + dur_days;
    dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
    pay_amt := CASE
      WHEN p_amount IS NOT NULL THEN GREATEST(0, p_amount)
      ELSE COALESCE(sub.amount, 0)
    END;

    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      duration_months = dur_months,
      amount = pay_amt,
      status = CASE WHEN end_d >= CURRENT_DATE THEN 'active' ELSE 'expired' END,
      updated_at = NOW()
    WHERE id = p_subscription_id
    RETURNING * INTO sub;

    UPDATE companies SET status = 'active', updated_at = NOW()
    WHERE id = cid AND status IS DISTINCT FROM 'active';
  END IF;

  SELECT to_jsonb(s.*) INTO sub_after FROM subscriptions s WHERE s.id = p_subscription_id LIMIT 1;

  BEGIN
    PERFORM saas_v3_write_audit(
      'subscription_edited', 'subscriptions',
      'Edited subscription #' || p_subscription_id::text || ' for company ' || cid::text,
      'subscription:' || p_subscription_id::text,
      cid,
      sub_before, sub_after,
      'subscriptions', p_subscription_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'subscription_id', p_subscription_id,
    'company_id', cid,
    'data', sub_after
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) TO authenticated, service_role;

COMMENT ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) IS
  'Super admin — edit subscription; p_duration_days = days from today until end_date';

-- END: 074_fix_edit_subscription_duration_from_today.sql

-- ============================================================
-- BEGIN: 075_admin_employee_device_manage.sql
-- ============================================================

-- 075: Admin — edit/clear employee device fingerprint (cloud, not browser-only)

CREATE OR REPLACE FUNCTION saas_admin_manage_employee_device(
  p_employee_id INTEGER,
  p_slot SMALLINT,
  p_fingerprint TEXT DEFAULT NULL,
  p_clear_link BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  tenant JSONB;
  before_row JSONB;
  after_row JSONB;
  dev_id INTEGER;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 OR p_slot IS NULL OR p_slot NOT IN (1, 2) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  tenant := saas_v3_assert_tenant(emp.company_id);
  IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN tenant;
  END IF;

  SELECT to_jsonb(d.*) INTO before_row
  FROM employee_devices d
  WHERE d.employee_id = p_employee_id AND d.slot = p_slot
  LIMIT 1;

  IF before_row IS NULL THEN
    INSERT INTO employee_devices (
      employee_id, company_id, slot, label, ip, fingerprint, pin, device_info
    ) VALUES (
      p_employee_id,
      emp.company_id,
      p_slot,
      'الهاتف ' || p_slot::text,
      '',
      CASE WHEN COALESCE(p_clear_link, false) THEN '' ELSE COALESCE(fp, '') END,
      '',
      '{}'::jsonb
    )
    RETURNING id INTO dev_id;

    SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

    RETURN jsonb_build_object('ok', true, 'data', after_row, 'created', true);
  END IF;

  IF COALESCE(p_clear_link, false) THEN
    UPDATE employee_devices SET
      fingerprint = '',
      ip = '',
      linked_at = NULL,
      token_used_at = NULL,
      last_login = NULL,
      device_info = '{}'::jsonb
    WHERE employee_id = p_employee_id AND slot = p_slot
    RETURNING id INTO dev_id;
  ELSIF fp IS NOT NULL THEN
    UPDATE employee_devices SET
      fingerprint = fp
    WHERE employee_id = p_employee_id AND slot = p_slot
    RETURNING id INTO dev_id;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'nothing_to_update');
  END IF;

  SELECT to_jsonb(d.*) INTO after_row FROM employee_devices d WHERE d.id = dev_id;

  BEGIN
    PERFORM saas_v3_write_audit(
      CASE WHEN COALESCE(p_clear_link, false) THEN 'employee_device_cleared' ELSE 'employee_device_updated' END,
      'devices',
      CASE WHEN COALESCE(p_clear_link, false)
        THEN 'Cleared device slot ' || p_slot::text || ' for employee ' || p_employee_id::text
        ELSE 'Updated fingerprint slot ' || p_slot::text || ' for employee ' || p_employee_id::text
      END,
      emp.name,
      emp.company_id,
      before_row,
      after_row,
      'employee_devices', dev_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'data', after_row);
END;
$$;

REVOKE ALL ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) TO authenticated, service_role;

COMMENT ON FUNCTION saas_admin_manage_employee_device(INTEGER, SMALLINT, TEXT, BOOLEAN) IS
  'Company admin — update or clear employee device fingerprint (keeps QR token for re-scan)';

-- END: 075_admin_employee_device_manage.sql

-- ============================================================
-- BEGIN: 076_super_admin_password_hardening.sql
-- ============================================================

-- ============================================================
-- KYNO 076 — Super Admin password rotation + force logout
-- Safe ops: no plaintext passwords in this file.
-- Rotate via: tools/rotate-super-admin-password.ps1
--   env: KYNO_SUPER_ADMIN_PASSWORD, KYNO_SUPABASE_SERVICE_ROLE_KEY
-- ============================================================

-- ---------- 1) Revoke all saas_sessions for one user ----------
CREATE OR REPLACE FUNCTION saas_revoke_all_sessions_for_user(p_user_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n INTEGER := 0;
BEGIN
  IF p_user_id IS NULL OR p_user_id < 1 THEN
    RETURN 0;
  END IF;
  UPDATE saas_sessions
  SET revoked_at = NOW()
  WHERE user_id = p_user_id
    AND revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ---------- 2) Revoke all super_admin saas_sessions ----------
CREATE OR REPLACE FUNCTION saas_revoke_all_super_admin_sessions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n INTEGER := 0;
BEGIN
  UPDATE saas_sessions s
  SET revoked_at = NOW()
  FROM saas_users u
  WHERE s.user_id = u.id
    AND u.role = 'super_admin'
    AND u.is_active IS TRUE
    AND s.revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ---------- 3) Internal GoTrue email (for admin logout scripts) ----------
CREATE OR REPLACE FUNCTION saas_user_auth_email(p_user_id INTEGER)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  u RECORD;
  safe_user TEXT;
BEGIN
  IF p_user_id IS NULL OR p_user_id < 1 THEN
    RETURN NULL;
  END IF;
  SELECT id, username, email INTO u
  FROM saas_users
  WHERE id = p_user_id AND is_active IS TRUE
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF u.email IS NOT NULL AND trim(u.email) <> '' AND position('@' IN u.email) > 0 THEN
    RETURN lower(trim(u.email));
  END IF;
  safe_user := regexp_replace(COALESCE(u.username, 'user'), '[^a-zA-Z0-9._-]', '_', 'g');
  RETURN format('saas_%s_%s@kyno.internal', u.id, safe_user);
END;
$$;

-- ---------- 4) Rotate password + invalidate saas_sessions (service_role only) ----------
CREATE OR REPLACE FUNCTION saas_rotate_user_password(
  p_username TEXT,
  p_new_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  uid INTEGER;
  urole TEXT;
  hash TEXT;
  revoked INTEGER := 0;
  pwd TEXT;
BEGIN
  pwd := trim(COALESCE(p_new_password, ''));
  IF p_username IS NULL OR length(trim(p_username)) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_username');
  END IF;
  IF length(pwd) < 12 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_too_short', 'min_length', 12);
  END IF;

  SELECT id, role INTO uid, urole
  FROM saas_users
  WHERE lower(username) = lower(trim(p_username))
    AND is_active IS TRUE
  LIMIT 1;

  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  hash := saas_hash_password_bcrypt(pwd);
  IF hash IS NULL OR hash = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
  END IF;

  UPDATE saas_users
  SET password_hash = hash,
      password_algo = 'bcrypt',
      force_password_reset = false,
      updated_at = NOW()
  WHERE id = uid;

  revoked := saas_revoke_all_sessions_for_user(uid);

  DELETE FROM login_attempts
  WHERE lower(username) = lower(trim(p_username));

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', uid,
    'username', trim(p_username),
    'role', urole,
    'sessions_revoked', revoked,
    'auth_email', saas_user_auth_email(uid),
    'force_relogin', true
  );
END;
$$;

-- ---------- 5) Legacy seed detection without embedded weak-hash literals ----------
CREATE OR REPLACE FUNCTION saas_count_legacy_seed_users()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*)::integer FROM saas_users
  WHERE lower(username) IN ('superadmin', 'admin')
    AND (
      password_algo IS NULL
      OR password_algo IN ('legacy_b64', 'sha256')
    );
$$;

-- Re-flag legacy accounts for mandatory rotation (idempotent)
UPDATE saas_users
SET force_password_reset = true
WHERE (password_algo IS NULL OR password_algo IN ('legacy_b64', 'sha256'))
  AND force_password_reset IS NOT TRUE;

-- ---------- Grants (service_role / Edge Functions only) ----------
REVOKE ALL ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_revoke_all_super_admin_sessions() FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_user_auth_email(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION saas_revoke_all_super_admin_sessions() TO service_role;
GRANT EXECUTE ON FUNCTION saas_user_auth_email(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION saas_rotate_user_password(TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION saas_rotate_user_password(TEXT, TEXT) IS
  'Rotate saas_users password (bcrypt), revoke saas_sessions, clear login_attempts. service_role only. Pair with GoTrue admin logout for full JWT invalidation.';

COMMENT ON FUNCTION saas_revoke_all_super_admin_sessions() IS
  'Force logout: revoke all active saas_sessions for super_admin users.';

-- END: 076_super_admin_password_hardening.sql

-- ============================================================
-- BEGIN: 077_critical_security_remediation.sql
-- ============================================================

-- ============================================================
-- KYNO 077 — Critical + High security remediation
-- C1 notifications | H1 subscription_plans RLS | H2 read-only subscription RPC
-- H3 employee portal device auth (no remote_attend IDOR) | anon SELECT lockdown
-- ============================================================

-- ---------- Shared employee portal authorization (H3) ----------
CREATE OR REPLACE FUNCTION saas_v3_employee_portal_authorize(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  sub_chk JSONB;
  cid INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  cid := auth_company_id();
  IF cid IS NOT NULL AND cid > 0 THEN
    IF emp.company_id IS DISTINCT FROM cid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
    END IF;
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 16 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'company_id', emp.company_id,
    'remote_attend', emp.remote_attend IS TRUE
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- C1: Admin notification mark read (authenticated tenant only) ----------
CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    IF auth_is_super_admin() THEN
      IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
        UPDATE employee_notifications SET is_read = TRUE
        WHERE id = p_notif_id;
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
        UPDATE employee_notifications SET is_read = TRUE
        WHERE notif_ref = btrim(p_notif_ref);
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref) AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) TO authenticated, service_role;

-- ---------- C1: Employee portal mark read (device proof required) ----------
CREATE OR REPLACE FUNCTION saas_mark_employee_portal_notification_read(
  p_employee_id INTEGER,
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  cid := (auth_result->>'company_id')::INTEGER;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id
      AND company_id = cid
      AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref)
      AND company_id = cid
      AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- H1: subscription_plans RLS (global catalog — no company_id column) ----------
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_plans_deny_anon ON subscription_plans;
CREATE POLICY subscription_plans_deny_anon ON subscription_plans
  FOR ALL TO anon
  USING (false)
  WITH CHECK (false);

DROP POLICY IF EXISTS subscription_plans_authenticated_read ON subscription_plans;
CREATE POLICY subscription_plans_authenticated_read ON subscription_plans
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS subscription_plans_super_admin ON subscription_plans;
CREATE POLICY subscription_plans_super_admin ON subscription_plans
  FOR ALL TO authenticated
  USING (auth_is_super_admin())
  WITH CHECK (auth_is_super_admin());

REVOKE ALL ON TABLE subscription_plans FROM anon;
GRANT SELECT ON TABLE subscription_plans TO authenticated;

-- ---------- H2: subscription status read-only (no anon mutation) ----------
CREATE OR REPLACE FUNCTION saas_get_company_subscription_status(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
  days_left INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('valid', true, 'status', 'active', 'message', '', 'daysLeft', 0);
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'الشركة غير موجودة', 'daysLeft', 0);
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'daysLeft', 0
    );
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'pending',
      'message', 'لا يوجد اشتراك نشط',
      'daysLeft', 0
    );
  END IF;

  days_left := (sub.end_date - CURRENT_DATE);

  IF sub.status = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', 0
    );
  END IF;

  IF sub.status = 'pending' OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  IF sub.status = 'expired' AND sub.end_date >= CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'status', 'active',
    'end_date', sub.end_date,
    'daysLeft', GREATEST(days_left, 0),
    'warning', days_left <= 10,
    'message', CASE
      WHEN days_left <= 10 THEN 'ينتهي الاشتراك خلال ' || GREATEST(days_left, 0)::text || ' يوم'
      ELSE ''
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO anon, authenticated, service_role;

-- ---------- H3: attendance punch — device required (no remote_attend bypass) ----------
CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL,
  p_punch_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
  active_chk JSONB;
  rate_chk JSONB;
  punch TEXT := lower(NULLIF(trim(p_punch_type), ''));
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  use_hours TEXT;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  official_co_min INTEGER;
  ot_min INTEGER;
  existing RECORD;
  att_row attendance%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF punch IN ('check_in', 'check_out') THEN
    rate_chk := saas_check_api_rate_limit(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'nodevice'),
      NULL,
      120,
      3600
    );
    IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'rate_limited',
        'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 3600)
      );
    END IF;
    PERFORM saas_record_api_attempt(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'nodevice'),
      NULL
    );
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();
  srv_ci := basma_format_time_ampm(srv_ts);

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_ci := srv_ci;
    use_co := NULL;
    use_hours := NULL;
    use_ot := '—';

    IF emp.open_hours IS TRUE THEN
      use_late := '—';
      use_status := 'طبيعي';
    ELSE
      actual_min := basma_time_text_to_minutes(srv_ci);
      official_min := basma_db_time_to_minutes(emp.check_in);
      late_min := GREATEST(0, actual_min - official_min);
      IF late_min > late_threshold THEN
        use_status := 'متأخر';
        use_late := late_min || 'د';
      ELSIF late_min > 0 THEN
        use_status := 'طبيعي';
        use_late := late_min || 'د';
      ELSE
        use_status := 'طبيعي';
        use_late := '—';
      END IF;
    END IF;

  ELSIF punch = 'check_out' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_co := basma_format_time_ampm(srv_ts);

    SELECT a.check_in, a.late, a.status INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
      use_late := COALESCE(NULLIF(trim(existing.late), ''), '—');
      use_status := COALESCE(NULLIF(trim(existing.status), ''), 'طبيعي');
    ELSE
      use_ci := srv_ci;
      use_late := '—';
      use_status := 'طبيعي';
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      official_co_min := basma_db_time_to_minutes(emp.check_out);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      ot_min := GREATEST(0, co_min - official_co_min);
      IF ot_min > 0 THEN
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN
          use_status := 'إضافي';
        END IF;
      ELSE
        use_ot := '—';
      END IF;
    END IF;

  ELSE
    IF p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
      IF NULLIF(trim(p_check_in), '') IS NULL
         AND NULLIF(trim(p_check_out), '') IS NULL
         AND NULLIF(trim(p_hours), '') IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    use_date_iso := p_date_iso::date;
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso);
    use_ci := NULLIF(trim(p_check_in), '');
    use_co := NULLIF(trim(p_check_out), '');
    use_hours := NULLIF(trim(p_hours), '');
    use_late := NULLIF(trim(p_late), '');
    use_ot := NULLIF(trim(p_overtime), '');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IS NULL
     AND NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    use_date_label,
    use_date_iso,
    use_ci,
    use_co,
    use_hours,
    use_late,
    use_ot,
    use_status,
    co_id
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id,
    updated_at = NOW()
  RETURNING * INTO att_row;

  att_id := att_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'attendance_id', att_id,
    'employee_id', p_employee_id,
    'check_in', COALESCE(att_row.check_in, '—'),
    'check_out', COALESCE(att_row.check_out, '—'),
    'date_iso', att_row.date_iso,
    'date_label', att_row.date_label,
    'hours', COALESCE(att_row.hours, '—'),
    'late', COALESCE(att_row.late, '—'),
    'overtime', COALESCE(att_row.overtime, '—'),
    'status', COALESCE(att_row.status, 'طبيعي'),
    'server_authoritative', punch IN ('check_in', 'check_out')
  );
END;
$$;

-- ---------- H3: Re-wrap employee fetch RPCs (072 bodies + shared authorize) ----------
-- saas_fetch_employee_attendance
CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id, 'employee_id', a.employee_id, 'emp_name', a.emp_name,
        'dept', a.dept, 'date_label', a.date_label, 'date_iso', a.date_iso,
        'check_in', a.check_in, 'check_out', a.check_out, 'hours', a.hours,
        'late', a.late, 'overtime', a.overtime, 'status', a.status, 'company_id', a.company_id
      ) ORDER BY a.date_iso DESC
    ), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC LIMIT lim
  ) a;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

-- saas_fetch_employee_client_profile (072 fields)
CREATE OR REPLACE FUNCTION saas_fetch_employee_client_profile(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  gps_prefix TEXT;
  v_lat TEXT;
  v_lng TEXT;
  v_range TEXT;
  v_name TEXT;
  v_finance TEXT;
  finance_arr JSONB := '[]'::jsonb;
  emp_finance JSONB := '[]'::jsonb;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

  IF emp.company_id IS NOT NULL THEN
    gps_prefix := 'company:' || emp.company_id::text || ':';
    SELECT value INTO v_lat FROM app_settings WHERE key = gps_prefix || 'gps_lat' LIMIT 1;
    SELECT value INTO v_lng FROM app_settings WHERE key = gps_prefix || 'gps_lng' LIMIT 1;
    SELECT value INTO v_range FROM app_settings WHERE key = gps_prefix || 'gps_range' LIMIT 1;
    SELECT value INTO v_name FROM app_settings WHERE key = gps_prefix || 'gps_name' LIMIT 1;
    SELECT value INTO v_finance FROM app_settings WHERE key = gps_prefix || 'finance_items' LIMIT 1;
  END IF;

  IF v_finance IS NOT NULL AND v_finance <> '' THEN
    BEGIN
      finance_arr := v_finance::jsonb;
    EXCEPTION WHEN others THEN
      finance_arr := '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(COALESCE(finance_arr, '[]'::jsonb)) <> 'array' THEN
    finance_arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO emp_finance
  FROM jsonb_array_elements(COALESCE(finance_arr, '[]'::jsonb)) item
  WHERE (item->>'empId')::text = emp.id::text
     OR (item->>'emp_id')::text = emp.id::text
     OR (item->>'employee_id')::text = emp.id::text;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'emp_name', emp.name,
    'dept', emp.dept,
    'role', emp.role,
    'phone', emp.phone,
    'salary', emp.salary,
    'salary_type', emp.salary_type,
    'salary_half', emp.salary_half,
    'daily_rate', emp.daily_rate,
    'company_id', emp.company_id,
    'check_in', emp.check_in,
    'check_out', emp.check_out,
    'open_hours', emp.open_hours IS TRUE,
    'remote_attend', emp.remote_attend IS TRUE,
    'avatar_url', emp.avatar_url,
    'finance_items', emp_finance,
    'gps_lat', NULLIF(trim(v_lat), ''),
    'gps_lng', NULLIF(trim(v_lng), ''),
    'gps_range', NULLIF(trim(v_range), ''),
    'gps_name', NULLIF(trim(v_name), '')
  );
END;
$$;

-- saas_fetch_employee_leaves
CREATE OR REPLACE FUNCTION saas_fetch_employee_leaves(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  lim INTEGER := GREATEST(1, LEAST(COALESCE(p_limit, 120), 300));
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.from_date DESC), '[]'::jsonb) INTO rows
  FROM (
    SELECT *
    FROM leaves l
    WHERE l.employee_id = p_employee_id
      AND l.company_id = emp.company_id
    ORDER BY l.from_date DESC, l.id DESC
    LIMIT lim
  ) x;

  RETURN jsonb_build_object('ok', true, 'data', rows);
END;
$$;

-- saas_fetch_employee_notifications (072 merge + authorize)
CREATE OR REPLACE FUNCTION saas_fetch_employee_notifications(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 80
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
  table_rows JSONB := '[]'::jsonb;
  settings_rows JSONB := '[]'::jsonb;
  settings_key TEXT;
  raw_val TEXT;
  arr JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

  settings_key := 'company:' || emp.company_id::text || ':employee_notifications';
  SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  IF raw_val IS NULL THEN
    settings_key := 'company:' || emp.company_id::text || ':employeeNotifications';
    SELECT value INTO raw_val FROM app_settings WHERE key = settings_key LIMIT 1;
  END IF;

  IF raw_val IS NOT NULL AND raw_val <> '' THEN
    BEGIN
      arr := raw_val::jsonb;
    EXCEPTION WHEN others THEN
      arr := '[]'::jsonb;
    END;
  ELSE
    arr := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO settings_rows
  FROM (
    SELECT x
    FROM jsonb_array_elements(COALESCE(arr, '[]'::jsonb)) x
    WHERE (x->>'empId')::text = p_employee_id::text
       OR (x->>'emp_id')::text = p_employee_id::text
    ORDER BY COALESCE(x->>'ts', x->>'createdAt', x->>'created_at') DESC NULLS LAST
    LIMIT lim
  ) s;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', COALESCE(n.notif_ref, n.id::text),
        '_remote_id', n.id,
        'emp_id', n.employee_id,
        'employee_id', n.employee_id,
        'title', n.title,
        'body', n.body,
        'type', n.notif_type,
        'finance_type', n.notif_type,
        'is_read', n.is_read,
        'created_at', n.created_at,
        'company_id', n.company_id,
        '_source', 'table'
      ) ORDER BY n.created_at DESC
    ), '[]'::jsonb
  ) INTO table_rows
  FROM (
    SELECT * FROM employee_notifications en
    WHERE en.employee_id = p_employee_id AND en.company_id = emp.company_id
    ORDER BY en.created_at DESC LIMIT lim
  ) n;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', p_employee_id,
    'notifications', table_rows || settings_rows,
    'table_notifications', table_rows,
    'settings_notifications', settings_rows
  );
END;
$$;

-- saas_fetch_employee_salary_records
CREATE OR REPLACE FUNCTION saas_fetch_employee_salary_records(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(s.*) ORDER BY s.month_iso DESC), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM salary_records sr
    WHERE sr.employee_id = p_employee_id
      AND sr.company_id = emp.company_id
      AND sr.status = 'مدفوع'
    ORDER BY sr.month_iso DESC
    LIMIT lim
  ) s;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

-- saas_update_employee_avatar — device proof required for anon path
CREATE OR REPLACE FUNCTION saas_update_employee_avatar(
  p_employee_id INTEGER,
  p_avatar_url TEXT,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  emp RECORD;
  url TEXT := NULLIF(trim(p_avatar_url), '');
  tenant JSONB;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;
  IF url IS NULL OR length(url) < 24 OR length(url) > 700000 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar');
  END IF;
  IF url NOT LIKE 'data:image/%' AND url NOT LIKE 'http%' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_avatar_format');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  IF auth_company_id() IS NOT NULL OR auth_is_super_admin() THEN
    tenant := saas_v3_assert_tenant(emp.company_id);
    IF COALESCE((tenant->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN tenant;
    END IF;
    UPDATE employees SET avatar_url = url WHERE id = p_employee_id;
    RETURN jsonb_build_object('ok', true);
  END IF;

  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  UPDATE employees SET avatar_url = url WHERE id = p_employee_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ---------- Medium: revoke blanket anon SELECT ----------
REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM anon;

-- Re-grant public platform read tables if any (none should need anon table SELECT — RPC only)

COMMENT ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) IS
  'Tenant-authenticated mark read only. anon revoked (077).';
COMMENT ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) IS
  'Employee phone portal mark read — requires device fingerprint/token (077).';
COMMENT ON FUNCTION saas_get_company_subscription_status(INTEGER) IS
  'Read-only subscription probe. No anon grant; no side-effect UPDATE (077).';

-- END: 077_critical_security_remediation.sql

-- ============================================================
-- BEGIN: 078_emergency_rpc_lockdown.sql
-- ============================================================

-- ============================================================
-- KYNO 078 — Emergency RPC grant lockdown + critical function fixes
-- Apply when 077 is not yet on production. Idempotent REVOKE/GRANT.
-- Run: tools/apply-migration-078.ps1
-- Verify: tools/verify-full-security-audit.ps1
-- ============================================================

-- ---------- 0) Helper: employee portal auth (H3) ----------
CREATE OR REPLACE FUNCTION saas_v3_employee_portal_authorize(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  tok TEXT := NULLIF(trim(p_token), '');
  authorized BOOLEAN := FALSE;
  sub_chk JSONB;
  cid INTEGER;
BEGIN
  IF p_employee_id IS NULL OR p_employee_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT * INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  cid := auth_company_id();
  IF cid IS NOT NULL AND cid > 0 THEN
    IF emp.company_id IS DISTINCT FROM cid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'tenant_mismatch');
    END IF;
    authorized := TRUE;
  END IF;

  IF NOT authorized AND fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO authorized;
  END IF;

  IF NOT authorized AND tok IS NOT NULL AND length(tok) >= 16 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.token = tok
    ) INTO authorized;
  END IF;

  IF NOT authorized THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(emp.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive', 'detail', sub_chk);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', emp.id,
    'company_id', emp.company_id
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_v3_employee_portal_authorize(INTEGER, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- C1: drop ambiguous overload (PostgREST 300) ----------
DROP FUNCTION IF EXISTS saas_mark_emp_notification_read(BIGINT);

-- ---------- C1: Admin mark read — authenticated tenant only ----------
CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    IF auth_is_super_admin() THEN
      IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
        UPDATE employee_notifications SET is_read = TRUE WHERE id = p_notif_id;
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
        UPDATE employee_notifications SET is_read = TRUE WHERE notif_ref = btrim(p_notif_ref);
        GET DIAGNOSTICS updated_count = ROW_COUNT;
        RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref) AND company_id = cid;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT, TEXT) TO authenticated, service_role;

-- Portal mark read (device proof)
CREATE OR REPLACE FUNCTION saas_mark_employee_portal_notification_read(
  p_employee_id INTEGER,
  p_notif_id BIGINT DEFAULT NULL,
  p_notif_ref TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  cid INTEGER;
  updated_count INTEGER := 0;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;
  cid := (auth_result->>'company_id')::INTEGER;

  IF p_notif_id IS NOT NULL AND p_notif_id > 0 THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE id = p_notif_id AND company_id = cid AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  IF p_notif_ref IS NOT NULL AND btrim(p_notif_ref) <> '' THEN
    UPDATE employee_notifications SET is_read = TRUE
    WHERE notif_ref = btrim(p_notif_ref) AND company_id = cid AND employee_id = p_employee_id;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN jsonb_build_object('ok', updated_count > 0, 'updated', updated_count);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
END;
$$;

REVOKE ALL ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_mark_employee_portal_notification_read(INTEGER, BIGINT, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;

-- ---------- CRITICAL: lock saas_rotate_user_password to service_role ONLY ----------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'saas_rotate_user_password'
  ) THEN
    REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM PUBLIC;
    REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM anon;
    REVOKE ALL ON FUNCTION saas_rotate_user_password(TEXT, TEXT) FROM authenticated;
    GRANT EXECUTE ON FUNCTION saas_rotate_user_password(TEXT, TEXT) TO service_role;
  END IF;
END $$;

-- Lock session revoke helpers
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'saas_revoke_all_sessions_for_user') THEN
    REVOKE ALL ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION saas_revoke_all_sessions_for_user(INTEGER) TO service_role;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'saas_revoke_all_super_admin_sessions') THEN
    REVOKE ALL ON FUNCTION saas_revoke_all_super_admin_sessions() FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION saas_revoke_all_super_admin_sessions() TO service_role;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'saas_user_auth_email') THEN
    REVOKE ALL ON FUNCTION saas_user_auth_email(INTEGER) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION saas_user_auth_email(INTEGER) TO service_role;
  END IF;
END $$;

-- ---------- H3: attendance fetch — device required ----------
CREATE OR REPLACE FUNCTION saas_fetch_employee_attendance(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL,
  p_token TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 120
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  auth_result JSONB;
  lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 120), 1), 300);
  rows JSONB;
BEGIN
  auth_result := saas_v3_employee_portal_authorize(p_employee_id, p_fingerprint, p_token);
  IF COALESCE((auth_result->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN auth_result;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id, 'employee_id', a.employee_id, 'emp_name', a.emp_name,
        'dept', a.dept, 'date_label', a.date_label, 'date_iso', a.date_iso,
        'check_in', a.check_in, 'check_out', a.check_out, 'hours', a.hours,
        'late', a.late, 'overtime', a.overtime, 'status', a.status, 'company_id', a.company_id
      ) ORDER BY a.date_iso DESC
    ), '[]'::jsonb
  ) INTO rows
  FROM (
    SELECT * FROM attendance att
    WHERE att.employee_id = p_employee_id
    ORDER BY att.date_iso DESC LIMIT lim
  ) a;

  RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'records', rows);
END;
$$;

-- ---------- H1: subscription_plans RLS ----------
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_plans_deny_anon ON subscription_plans;
CREATE POLICY subscription_plans_deny_anon ON subscription_plans
  FOR ALL TO anon USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS subscription_plans_authenticated_read ON subscription_plans;
CREATE POLICY subscription_plans_authenticated_read ON subscription_plans
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS subscription_plans_super_admin ON subscription_plans;
CREATE POLICY subscription_plans_super_admin ON subscription_plans
  FOR ALL TO authenticated
  USING (auth_is_super_admin()) WITH CHECK (auth_is_super_admin());

REVOKE ALL ON TABLE subscription_plans FROM anon;
GRANT SELECT ON TABLE subscription_plans TO authenticated;

-- ---------- H2: subscription status read-only ----------
CREATE OR REPLACE FUNCTION saas_get_company_subscription_status(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
  days_left INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('valid', true, 'status', 'active', 'message', '', 'daysLeft', 0);
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'الشركة غير موجودة', 'daysLeft', 0);
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object('valid', false, 'status', 'suspended', 'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.', 'daysLeft', 0);
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'لا يوجد اشتراك نشط', 'daysLeft', 0);
  END IF;

  days_left := (sub.end_date - CURRENT_DATE);

  IF sub.status = 'suspended' OR sub.status = 'pending' OR sub.end_date < CURRENT_DATE
     OR (sub.status = 'expired' AND sub.end_date >= CURRENT_DATE) THEN
    RETURN jsonb_build_object(
      'valid', false,
      'status', CASE WHEN sub.status = 'suspended' THEN 'suspended' ELSE 'expired' END,
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  RETURN jsonb_build_object(
    'valid', true, 'status', 'active', 'end_date', sub.end_date,
    'daysLeft', GREATEST(days_left, 0),
    'warning', days_left <= 10,
    'message', CASE WHEN days_left <= 10 THEN 'ينتهي الاشتراك خلال ' || GREATEST(days_left, 0)::text || ' يوم' ELSE '' END
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO anon, authenticated, service_role;

REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM anon;

-- ---------- Audit RPC (super_admin) — live grants/policies report ----------
CREATE OR REPLACE FUNCTION saas_security_grants_audit()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rls_rows JSONB;
  anon_grants JSONB;
  rpc_grants JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', c.relname,
    'rls_enabled', c.relrowsecurity,
    'rls_forced', c.relforcerowsecurity
  ) ORDER BY c.relname), '[]'::jsonb) INTO rls_rows
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND c.relname IN (
      'subscription_plans','employee_notifications','attendance','employees',
      'salary_records','companies','subscriptions','saas_users','departments','leaves'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', table_name,
    'privilege', privilege_type
  ) ORDER BY table_name, privilege_type), '[]'::jsonb) INTO anon_grants
  FROM information_schema.role_table_grants
  WHERE grantee = 'anon' AND table_schema = 'public';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname,
    'grantee', grantee.rolname
  ) ORDER BY p.proname, grantee.rolname), '[]'::jsonb) INTO rpc_grants
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'saas_mark_emp_notification_read',
      'saas_mark_employee_portal_notification_read',
      'saas_rotate_user_password',
      'saas_fetch_employee_attendance',
      'saas_v3_employee_portal_authorize',
      'saas_get_company_subscription_status'
    );

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'rls_tables', rls_rows,
    'anon_table_grants', anon_grants,
    'critical_rpc_grants', rpc_grants,
    'policies', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'table', tablename, 'policy', policyname, 'roles', roles, 'cmd', cmd
      ) ORDER BY tablename, policyname), '[]'::jsonb)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename IN ('subscription_plans','employee_notifications','attendance','employees')
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_grants_audit() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_security_grants_audit() TO authenticated, service_role;

COMMENT ON FUNCTION saas_security_grants_audit() IS '078: Live RLS/grants/policies audit for super_admin verification.';

-- END: 078_emergency_rpc_lockdown.sql

-- ============================================================
-- BEGIN: 079_auth_session_revocation.sql
-- ============================================================

-- KYNO 079 — Instant JWT invalidation on logout (revoked_at vs JWT iat)

CREATE TABLE IF NOT EXISTS saas_user_auth_revoked_at (
  user_id     INTEGER PRIMARY KEY REFERENCES saas_users(id) ON DELETE CASCADE,
  revoked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE saas_user_auth_revoked_at ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS saas_user_auth_revoked_at_deny ON saas_user_auth_revoked_at;
CREATE POLICY saas_user_auth_revoked_at_deny ON saas_user_auth_revoked_at
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION auth_jwt_saas_user_id_raw()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT NULLIF(COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'saas_user_id',
    auth.jwt() ->> 'saas_user_id'
  ), '')::INTEGER;
$$;

CREATE OR REPLACE FUNCTION auth_session_is_revoked()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM saas_user_auth_revoked_at r
    WHERE r.user_id = auth_jwt_saas_user_id_raw()
      AND auth_jwt_saas_user_id_raw() IS NOT NULL
      AND to_timestamp(COALESCE(NULLIF(auth.jwt() ->> 'iat', '')::DOUBLE PRECISION, 0)) < r.revoked_at
  );
$$;

CREATE OR REPLACE FUNCTION auth_saas_user_id()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT CASE WHEN auth_session_is_revoked() THEN NULL::INTEGER
    ELSE auth_jwt_saas_user_id_raw() END;
$$;

CREATE OR REPLACE FUNCTION auth_app_role()
RETURNS TEXT
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT CASE WHEN auth_session_is_revoked() THEN ''
    ELSE COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'role',
      auth.jwt() ->> 'role', ''
    ) END;
$$;

CREATE OR REPLACE FUNCTION auth_is_super_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT auth_app_role() = 'super_admin' AND NOT auth_session_is_revoked();
$$;

CREATE OR REPLACE FUNCTION auth_company_id()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT CASE WHEN auth_session_is_revoked() THEN NULL::INTEGER
    ELSE NULLIF(COALESCE(
      auth.jwt() -> 'app_metadata' ->> 'company_id',
      auth.jwt() ->> 'company_id'
    ), '')::INTEGER END;
$$;

CREATE OR REPLACE FUNCTION saas_revoke_auth_sessions_for_user(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_user_id IS NULL OR p_user_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;
  INSERT INTO saas_user_auth_revoked_at (user_id, revoked_at)
  VALUES (p_user_id, NOW())
  ON CONFLICT (user_id) DO UPDATE SET revoked_at = EXCLUDED.revoked_at;
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'saas_revoke_all_sessions_for_user'
  ) THEN
    PERFORM saas_revoke_all_sessions_for_user(p_user_id);
  END IF;
  RETURN jsonb_build_object('ok', true, 'user_id', p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION saas_logout_self()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE uid INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;
  uid := auth_jwt_saas_user_id_raw();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_saas_user');
  END IF;
  INSERT INTO saas_user_auth_revoked_at (user_id, revoked_at)
  VALUES (uid, NOW())
  ON CONFLICT (user_id) DO UPDATE SET revoked_at = EXCLUDED.revoked_at;
  RETURN jsonb_build_object('ok', true, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION auth_jwt_saas_user_id_raw() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auth_jwt_saas_user_id_raw() TO authenticated, service_role;

REVOKE ALL ON FUNCTION auth_session_is_revoked() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auth_session_is_revoked() TO authenticated, service_role;

REVOKE ALL ON FUNCTION saas_revoke_auth_sessions_for_user(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_revoke_auth_sessions_for_user(INTEGER) TO service_role;

REVOKE ALL ON FUNCTION saas_logout_self() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_logout_self() TO authenticated, service_role;

-- END: 079_auth_session_revocation.sql

-- ============================================================
-- BEGIN: 080_production_security_final.sql
-- ============================================================

-- KYNO 080 — Production security final lock

-- Subscription status: authenticated only (no anon enumeration)
REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO authenticated, service_role;

-- saas_get_user_profile: reject revoked JWT immediately
CREATE OR REPLACE FUNCTION saas_get_user_profile(p_user_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  uid INTEGER := p_user_id;
  u RECORD;
  actor_id INTEGER;
  actor_role TEXT;
  actor_cid INTEGER;
BEGIN
  IF auth_session_is_revoked() THEN
    RETURN NULL;
  END IF;

  IF uid IS NULL OR uid <= 0 THEN RETURN NULL; END IF;

  actor_id := auth_saas_user_id();

  IF auth_is_super_admin() THEN
    NULL;
  ELSIF actor_id IS NOT NULL AND actor_id = uid THEN
    NULL;
  ELSE
    SELECT role, company_id INTO actor_role, actor_cid
    FROM saas_users WHERE id = actor_id AND is_active = true LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF actor_role = 'company_admin' THEN
      IF NOT EXISTS (
        SELECT 1 FROM saas_users target
        WHERE target.id = uid AND target.company_id = actor_cid
      ) THEN RETURN NULL; END IF;
    ELSIF actor_role = 'company_user' THEN
      IF NOT auth_can_manage_tenant_users((
        SELECT company_id FROM saas_users WHERE id = uid LIMIT 1
      )) THEN RETURN NULL; END IF;
    ELSE RETURN NULL;
    END IF;
  END IF;

  SELECT su.id, su.username, su.display_name, su.email, su.role, su.permissions, su.company_id,
         c.company_name, c.company_code, c.status AS company_status, c.max_employees
  INTO u
  FROM saas_users su
  LEFT JOIN companies c ON c.id = su.company_id
  WHERE su.id = uid AND su.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', COALESCE(u.display_name, ''),
    'email', COALESCE(u.email, ''), 'role', u.role,
    'permissions', COALESCE(u.permissions, '{}'::jsonb),
    'company_id', u.company_id, 'company_name', u.company_name,
    'company_code', u.company_code, 'company_status', u.company_status,
    'max_employees', COALESCE(u.max_employees, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_user_profile(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_user_profile(INTEGER) TO authenticated, service_role;

-- Block anon direct table access (idempotent)
REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM anon;

-- END: 080_production_security_final.sql

-- ============================================================
-- BEGIN: 081_super_admin_login_no_rate_limit.sql
-- ============================================================

-- KYNO 081 — Super admin exempt from login rate limit (username + IP window)

CREATE OR REPLACE FUNCTION saas_check_login_rate_limit(
  p_username TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uname TEXT := lower(trim(COALESCE(p_username, '')));
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  window_start TIMESTAMPTZ := NOW() - INTERVAL '15 minutes';
  fail_user INTEGER := 0;
  fail_ip INTEGER := 0;
  max_fail INTEGER := 5;
BEGIN
  IF uname = '' THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  -- Super admin: no brute-force lockout (ops / recovery access)
  IF EXISTS (
    SELECT 1 FROM saas_users su
    WHERE lower(su.username) = uname
      AND su.role = 'super_admin'
      AND su.is_active IS TRUE
  ) THEN
    RETURN jsonb_build_object('allowed', true, 'exempt', 'super_admin');
  END IF;

  SELECT COUNT(*) INTO fail_user
  FROM login_attempts
  WHERE lower(username) = uname
    AND success = false
    AND created_at >= window_start;

  IF fail_user >= max_fail THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'error', 'rate_limited',
      'retry_after_sec', 900,
      'reason', 'username'
    );
  END IF;

  IF ip IS NOT NULL THEN
    SELECT COUNT(*) INTO fail_ip
    FROM login_attempts
    WHERE ip_address = ip
      AND success = false
      AND created_at >= window_start;

    IF fail_ip >= max_fail THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'retry_after_sec', 900,
        'reason', 'ip'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

-- Clear existing lockouts for active super admins (immediate relief)
DELETE FROM login_attempts
WHERE lower(username) IN (
  SELECT lower(username) FROM saas_users
  WHERE role = 'super_admin' AND is_active IS TRUE
);

REVOKE ALL ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) IS
  'Login brute-force window. Super admin usernames are always allowed.';

-- END: 081_super_admin_login_no_rate_limit.sql

-- ============================================================
-- BEGIN: 082_security_health_report_closure.sql
-- ============================================================

-- ============================================================
-- 082 — إغلاق تقرير الصحة الأمنية (Enterprise Ready)
-- 1) subscription_plans: استبدال USING(true) بشرط JWT
-- 2) تحديث saas_security_health_report — whitelist + portal authorize
-- ============================================================

-- ---------- subscription_plans: قراءة للمصادقين فقط (بدون USING(true) literal) ----------
DROP POLICY IF EXISTS subscription_plans_authenticated_read ON subscription_plans;
CREATE POLICY subscription_plans_authenticated_read ON subscription_plans
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);

-- ---------- Health report — recognize portal auth + session helpers ----------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_fetch_employee_leaves',
      'saas_upsert_attendance_by_device', 'saas_upsert_attendance_employee',
      'saas_link_device_by_token', 'saas_mark_employee_portal_notification_read',
      'saas_get_company_subscription_status', 'saas_logout_self',
      'saas_revoke_all_sessions_for_user', 'saas_revoke_all_super_admin_sessions',
      'saas_revoke_auth_sessions_for_user', 'saas_rotate_user_password',
      'saas_super_admin_user_id', 'saas_user_auth_email',
      'saas_security_health_report', 'saas_v3_audit_rls_report',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt',
      'saas_hash_password_bcrypt', 'saas_create_session', 'saas_verify_session',
      'saas_revoke_session', 'saas_count_legacy_seed_users',
      'saas_super_admin_default_perms', 'saas_super_admin_effective_perms',
      'saas_super_admin_can', 'saas_super_admin_sender_meta',
      'saas_v3_company_setting', 'saas_v3_compute_leave_deductions',
      'saas_v3_finance_totals', 'saas_v3_write_audit'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
      || '|saas_resolve_qr_registration|saas_issue_salary|saas_preview_salary'
      || '|saas_v3_employee_portal_authorize|auth_jwt_saas_user_id_raw|auth\.uid\(\)'
    );

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'enterprise_ready',
      jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) = 0
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_security_health_report() IS
  '082 — enterprise_ready includes RPC audit; whitelists portal/session helpers';

-- END: 082_security_health_report_closure.sql

-- ============================================================
-- BEGIN: 083_comprehensive_security_report_ar.sql
-- ============================================================

-- ============================================================
-- 083 — تقرير أمني شامل (عربي + verdict + فحص اختراق/هجمات)
-- يوسّع saas_security_health_report من 082
-- ============================================================

DROP POLICY IF EXISTS subscription_plans_authenticated_read ON subscription_plans;
CREATE POLICY subscription_plans_authenticated_read ON subscription_plans
  FOR SELECT TO authenticated
  USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
  anon_grants JSONB;
  critical_rpc_anon JSONB;
  critical_rls JSONB;
  findings JSONB := '[]'::jsonb;
  fail_logins_24h INTEGER := 0;
  fail_logins_15m INTEGER := 0;
  top_attack_ips JSONB := '[]'::jsonb;
  audit_deletes_24h INTEGER := 0;
  audit_perm_24h INTEGER := 0;
  audit_super_24h INTEGER := 0;
  super_admin_count INTEGER := 0;
  active_companies INTEGER := 0;
  suspended_companies INTEGER := 0;
  score INTEGER := 100;
  verdict TEXT := 'safe';
  verdict_ar TEXT;
  verdict_summary_ar TEXT;
  attack_suspected BOOLEAN := false;
  has_critical BOOLEAN := false;
  has_high BOOLEAN := false;
  enterprise_ready BOOLEAN;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  -- ---------- بنية RLS / policies / RPCs ----------
  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_fetch_employee_leaves',
      'saas_upsert_attendance_by_device', 'saas_upsert_attendance_employee',
      'saas_link_device_by_token', 'saas_mark_employee_portal_notification_read',
      'saas_get_company_subscription_status', 'saas_logout_self',
      'saas_revoke_all_sessions_for_user', 'saas_revoke_all_super_admin_sessions',
      'saas_revoke_auth_sessions_for_user', 'saas_rotate_user_password',
      'saas_super_admin_user_id', 'saas_user_auth_email',
      'saas_security_health_report', 'saas_v3_audit_rls_report', 'saas_security_grants_audit',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt',
      'saas_hash_password_bcrypt', 'saas_create_session', 'saas_verify_session',
      'saas_revoke_session', 'saas_count_legacy_seed_users',
      'saas_super_admin_default_perms', 'saas_super_admin_effective_perms',
      'saas_super_admin_can', 'saas_super_admin_sender_meta',
      'saas_v3_company_setting', 'saas_v3_compute_leave_deductions',
      'saas_v3_finance_totals', 'saas_v3_write_audit'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
      || '|saas_resolve_qr_registration|saas_issue_salary|saas_preview_salary'
      || '|saas_v3_employee_portal_authorize|auth_jwt_saas_user_id_raw|auth\.uid\(\)'
    );

  -- ---------- صلاحيات anon على جداول حساسة ----------
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', table_name, 'privilege', privilege_type
  ) ORDER BY table_name, privilege_type), '[]'::jsonb) INTO anon_grants
  FROM information_schema.role_table_grants
  WHERE grantee = 'anon' AND table_schema = 'public'
    AND table_name IN (
      'employees', 'attendance', 'salary_records', 'companies', 'subscriptions',
      'saas_users', 'app_settings', 'audit_logs', 'departments', 'leaves',
      'employee_notifications', 'login_attempts', 'saas_sessions'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname, 'grantee', grantee.rolname
  ) ORDER BY p.proname), '[]'::jsonb) INTO critical_rpc_anon
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND grantee.rolname = 'anon'
    AND p.proname IN (
      'saas_rotate_user_password', 'saas_super_upsert_company', 'saas_super_delete_company',
      'saas_fetch_employee_attendance', 'saas_fetch_employee_salary_records',
      'saas_revoke_all_sessions_for_user', 'saas_user_auth_email'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', c.relname, 'rls_enabled', c.relrowsecurity
  ) ORDER BY c.relname), '[]'::jsonb) INTO critical_rls
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND c.relname IN (
      'employees', 'attendance', 'salary_records', 'companies', 'subscriptions',
      'saas_users', 'app_settings', 'audit_logs', 'departments', 'leaves'
    )
    AND c.relrowsecurity IS NOT TRUE;

  -- ---------- هجمات تسجيل الدخول ----------
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'login_attempts') THEN
    SELECT COUNT(*) INTO fail_logins_24h
    FROM login_attempts
    WHERE success = false AND created_at >= NOW() - INTERVAL '24 hours';

    SELECT COUNT(*) INTO fail_logins_15m
    FROM login_attempts
    WHERE success = false AND created_at >= NOW() - INTERVAL '15 minutes';

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'ip', sub.ip_address, 'attempts', sub.cnt
    ) ORDER BY sub.cnt DESC), '[]'::jsonb) INTO top_attack_ips
    FROM (
      SELECT ip_address, COUNT(*) AS cnt
      FROM login_attempts
      WHERE success = false
        AND created_at >= NOW() - INTERVAL '24 hours'
        AND COALESCE(ip_address, '') <> ''
      GROUP BY ip_address
      ORDER BY cnt DESC
      LIMIT 5
    ) sub;
  END IF;

  -- ---------- سجل التدقيق المشبوه ----------
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'audit_logs') THEN
    SELECT COUNT(*) INTO audit_deletes_24h
    FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (
        action ILIKE '%delete%' OR action ILIKE '%حذف%'
        OR details ILIKE '%delete%' OR details ILIKE '%حذف%'
      );

    SELECT COUNT(*) INTO audit_perm_24h
    FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (
        action ILIKE '%perm%' OR action ILIKE '%permission%'
        OR details ILIKE '%perm%' OR details ILIKE '%صلاح%'
        OR category ILIKE '%perm%'
      );

    SELECT COUNT(*) INTO audit_super_24h
    FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (
        actor_role = 'super_admin'
        OR details ILIKE '%super_admin%'
        OR action ILIKE '%super%'
      );
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'saas_users') THEN
    SELECT COUNT(*) INTO super_admin_count
    FROM saas_users
    WHERE role = 'super_admin' AND is_active IS TRUE;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'companies') THEN
    SELECT COUNT(*) INTO active_companies FROM companies WHERE status = 'active';
    SELECT COUNT(*) INTO suspended_companies FROM companies WHERE status = 'suspended';
  END IF;

  enterprise_ready :=
    jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(anon_grants, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(critical_rpc_anon, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(critical_rls, '[]'::jsonb)) = 0;

  -- ---------- بناء findings بالعربي ----------
  IF jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) > 0 THEN
    has_critical := true;
    score := score - 35;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'tables_no_rls',
      'severity', 'critical',
      'status', 'fail',
      'title_ar', 'جداول عامة بدون عزل RLS',
      'detail_ar', 'يوجد ' || jsonb_array_length(tables_no_rls)::text || ' جدول/جداول يمكن الوصول إليها بدون Row Level Security — خطر تسرب بيانات بين الشركات.',
      'recommendation_ar', 'فعّل RLS فوراً على كل جداول public الحساسة وطبّق سياسات tenant.',
      'count', jsonb_array_length(tables_no_rls),
      'items', tables_no_rls
    ));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'tables_no_rls', 'severity', 'info', 'status', 'pass',
      'title_ar', 'عزل الجداول (RLS)', 'detail_ar', 'جميع الجداول العامة محمية بـ RLS.',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb
    ));
  END IF;

  IF jsonb_array_length(COALESCE(critical_rls, '[]'::jsonb)) > 0 THEN
    has_critical := true;
    score := score - 30;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'critical_tables_rls_off',
      'severity', 'critical',
      'status', 'fail',
      'title_ar', 'جداول حرجة بدون RLS',
      'detail_ar', 'جداول أساسية (موظفون، حضور، رواتب، شركات...) بدون تفعيل RLS.',
      'recommendation_ar', 'راجع migration الأمان وفعّل RLS على الجداول الحرجة.',
      'count', jsonb_array_length(critical_rls),
      'items', critical_rls
    ));
  END IF;

  IF jsonb_array_length(COALESCE(anon_grants, '[]'::jsonb)) > 0 THEN
    has_critical := true;
    score := score - 40;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'anon_table_grants',
      'severity', 'critical',
      'status', 'fail',
      'title_ar', 'صلاحيات anon على جداول حساسة',
      'detail_ar', 'دور anon لديه صلاحيات مباشرة على جداول — قد يسمح بقراءة/كتابة بدون تسجيل دخول.',
      'recommendation_ar', 'أزل كل GRANT من anon على الجداول الحساسة (REVOKE ALL ... FROM anon).',
      'count', jsonb_array_length(anon_grants),
      'items', anon_grants
    ));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'anon_table_grants', 'severity', 'info', 'status', 'pass',
      'title_ar', 'حماية anon', 'detail_ar', 'لا توجد صلاحيات anon على الجداول الحساسة.',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb
    ));
  END IF;

  IF jsonb_array_length(COALESCE(critical_rpc_anon, '[]'::jsonb)) > 0 THEN
    has_critical := true;
    score := score - 45;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'critical_rpc_anon',
      'severity', 'critical',
      'status', 'fail',
      'title_ar', 'دوال خطرة مفتوحة لـ anon',
      'detail_ar', 'RPCs حساسة (تغيير كلمة مرور، حذف شركة، إلخ) متاحة لدور anon — ثغرة حرجة.',
      'recommendation_ar', 'قيّد هذه الدوال على authenticated أو service_role فقط.',
      'count', jsonb_array_length(critical_rpc_anon),
      'items', critical_rpc_anon
    ));
  END IF;

  IF jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) > 0
     OR jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) > 0 THEN
    has_high := true;
    score := score - 20;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'policies_literal_true',
      'severity', 'high',
      'status', 'fail',
      'title_ar', 'سياسات RLS مفتوحة (true)',
      'detail_ar', 'توجد policies تستخدم USING(true) أو WITH CHECK(true) — تتجاوز العزل الدقيق.',
      'recommendation_ar', 'استبدل true بشروط auth.uid() أو auth_company_id() أو auth_is_super_admin().',
      'count', jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb))
        + jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)),
      'items', COALESCE(policies_using_true, '[]'::jsonb) || COALESCE(policies_check_true, '[]'::jsonb)
    ));
  END IF;

  IF jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) > 0 THEN
    has_high := true;
    score := score - 12;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'rpcs_no_tenant',
      'severity', 'high',
      'status', 'warn',
      'title_ar', 'دوال RPC بدون تحقق tenant',
      'detail_ar', 'دوال SECURITY DEFINER لا تحتوي على تحقق company/tenant في الكود — راجعها يدوياً.',
      'recommendation_ar', 'أضف saas_v3_assert_tenant أو auth_company_id() أو whitelist في التقرير إن كانت مقصودة.',
      'count', jsonb_array_length(rpcs_no_tenant),
      'items', rpcs_no_tenant
    ));
  END IF;

  IF fail_logins_15m >= 30 OR fail_logins_24h >= 150 THEN
    attack_suspected := true;
    has_critical := true;
    score := score - 25;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force_attack',
      'severity', 'critical',
      'status', 'fail',
      'title_ar', 'هجوم تخمين كلمات المرور',
      'detail_ar', 'محاولات دخول فاشلة مكثفة: ' || fail_logins_15m::text || ' خلال 15 دقيقة، '
        || fail_logins_24h::text || ' خلال 24 ساعة — قد يكون هجوم brute-force.',
      'recommendation_ar', 'فعّل حظر IP، راجع login_attempts، غيّر كلمات مرور الحسابات المستهدفة، راقب السجلات.',
      'count', fail_logins_24h,
      'items', top_attack_ips
    ));
  ELSIF fail_logins_24h >= 40 THEN
    has_high := true;
    score := score - 10;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force_elevated',
      'severity', 'high',
      'status', 'warn',
      'title_ar', 'محاولات دخول فاشلة مرتفعة',
      'detail_ar', fail_logins_24h::text || ' محاولة فاشلة خلال 24 ساعة.',
      'recommendation_ar', 'راقب الحسابات المستهدفة وتأكد من rate limit.',
      'count', fail_logins_24h,
      'items', top_attack_ips
    ));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force', 'severity', 'info', 'status', 'pass',
      'title_ar', 'محاولات الدخول', 'detail_ar', 'لا يوجد هجوم brute-force واضح ('
        || fail_logins_24h::text || ' فاشلة / 24 س).',
      'recommendation_ar', '—', 'count', fail_logins_24h, 'items', top_attack_ips
    ));
  END IF;

  IF audit_deletes_24h >= 25 THEN
    attack_suspected := true;
    has_high := true;
    score := score - 15;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'mass_deletes',
      'severity', 'high',
      'status', 'warn',
      'title_ar', 'حذف جماعي مشبوه',
      'detail_ar', audit_deletes_24h::text || ' عملية حذف في audit_logs خلال 24 ساعة — قد يدل على نشاط غير طبيعي.',
      'recommendation_ar', 'راجع سجل التدقيق وتأكد من أن الحذف من حسابات مصرّح بها.',
      'count', audit_deletes_24h,
      'items', '[]'::jsonb
    ));
  END IF;

  IF audit_perm_24h >= 5 THEN
    has_high := true;
    score := score - 8;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'permission_changes',
      'severity', 'medium',
      'status', 'warn',
      'title_ar', 'تغييرات صلاحيات حديثة',
      'detail_ar', audit_perm_24h::text || ' تعديل صلاحيات خلال 24 ساعة.',
      'recommendation_ar', 'تأكد أن التغييرات من مدير النظام المعتمد.',
      'count', audit_perm_24h,
      'items', '[]'::jsonb
    ));
  END IF;

  IF super_admin_count > 8 THEN
    score := score - 5;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'many_super_admins',
      'severity', 'medium',
      'status', 'warn',
      'title_ar', 'عدد كبير من Super Admin',
      'detail_ar', super_admin_count::text || ' حساب سوبر أدمن نشط — كل حساب إضافي يزيد سطح الهجوم.',
      'recommendation_ar', 'قلّل الحسابات إلى الحد الأدنى وفعّل view_only حيث يلزم.',
      'count', super_admin_count,
      'items', '[]'::jsonb
    ));
  END IF;

  IF suspended_companies > 0 AND active_companies > 0 THEN
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'company_status',
      'severity', 'info',
      'status', 'pass',
      'title_ar', 'حالة الشركات',
      'detail_ar', active_companies::text || ' نشطة، ' || suspended_companies::text || ' موقوفة.',
      'recommendation_ar', '—',
      'count', active_companies + suspended_companies,
      'items', '[]'::jsonb
    ));
  END IF;

  score := GREATEST(0, LEAST(100, score));

  IF attack_suspected AND (has_critical OR fail_logins_24h >= 100) THEN
    verdict := 'attack_suspected';
    verdict_ar := '⚠️ نشاط مشبوه — احتمال هجوم أو محاولة اختراق';
    verdict_summary_ar := 'رُصدت علامات هجوم (محاولات دخول مكثفة أو نشاط حذف/صلاحيات غير طبيعي). '
      || 'لا يُؤكّد هذا الاختراق تلقائياً لكن يتطلب مراجعة فورية للسجلات وحسابات السوبر أدمن.';
  ELSIF has_critical OR score < 45 THEN
    verdict := 'critical';
    verdict_ar := '🔴 خطر أمني حرج — النظام معرّض';
    verdict_summary_ar := 'ثغرات أو misconfiguration حرجة (RLS، anon، RPCs). '
      || 'يُحتمل تسرب بيانات أو تجاوز صلاحيات — عالج فوراً قبل الإنتاج.';
  ELSIF has_high OR score < 75 OR NOT enterprise_ready THEN
    verdict := 'warning';
    verdict_ar := '🟡 تحذير — مخاطر يجب معالجتها';
    verdict_summary_ar := 'لا دليل مباشر على اختراق، لكن توجد نقاط ضعف يجب إصلاحها لرفع مستوى الأمان.';
  ELSE
    verdict := 'safe';
    verdict_ar := '🟢 آمن — لم يُكتشَف اختراق أو ثغرات حرجة';
    verdict_summary_ar := 'فحص RLS، الصلاحيات، RPCs، ومحاولات الدخول لم يظهر خطر حرج. '
      || 'استمر بالمراقبة الدورية.';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'verdict', verdict,
    'verdict_ar', verdict_ar,
    'verdict_summary_ar', verdict_summary_ar,
    'security_score', score,
    'attack_suspected', attack_suspected,
    'compromised_confirmed', false,
    'findings', findings,
    'metrics', jsonb_build_object(
      'failed_logins_24h', fail_logins_24h,
      'failed_logins_15m', fail_logins_15m,
      'audit_deletes_24h', audit_deletes_24h,
      'audit_permission_changes_24h', audit_perm_24h,
      'audit_super_admin_actions_24h', audit_super_24h,
      'super_admin_active_count', super_admin_count,
      'active_companies', active_companies,
      'suspended_companies', suspended_companies
    ),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'anon_table_grants', anon_grants,
    'critical_rpc_anon_grants', critical_rpc_anon,
    'critical_tables_rls_off', critical_rls,
    'top_attack_ips', top_attack_ips,
    'enterprise_ready', enterprise_ready
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_security_health_report() IS
  '083 — تقرير أمني شامل: verdict عربي، score، findings، فحص هجمات وanon/RLS';

-- END: 083_comprehensive_security_report_ar.sql

-- ============================================================
-- BEGIN: 084_security_report_anon_fix.sql
-- ============================================================

-- ============================================================
-- 084 — إصلاح تقرير الأمان: إيجابيات خاطئة + قفل anon الحقيقي
-- ============================================================

-- ---------- إزالة صلاحيات anon غير الضرورية (بيانات + super RPCs) ----------
REVOKE ALL ON TABLE employees, attendance, salary_records, companies, subscriptions,
  saas_users, app_settings, audit_logs, departments, leaves, employee_notifications,
  login_attempts, saas_sessions
FROM anon;

REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM anon;

DO $$
DECLARE
  fn RECORD;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'saas_super_upsert_company',
        'saas_super_delete_company',
        'saas_super_toggle_company_status',
        'saas_super_renew_subscription',
        'saas_super_delete_subscription',
        'saas_rotate_user_password',
        'saas_revoke_all_sessions_for_user',
        'saas_revoke_all_super_admin_sessions',
        'saas_revoke_auth_sessions_for_user',
        'saas_user_auth_email',
        'saas_save_platform_globals'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn.sig);
  END LOOP;
END $$;

-- إعادة منح super RPCs للمصادقين فقط
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_super_upsert_company') THEN
    REVOKE ALL ON FUNCTION saas_super_upsert_company(JSONB) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION saas_super_upsert_company(JSONB) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_super_delete_company') THEN
    REVOKE ALL ON FUNCTION saas_super_delete_company(INTEGER) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION saas_super_delete_company(INTEGER) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'saas_super_toggle_company_status') THEN
    REVOKE ALL ON FUNCTION saas_super_toggle_company_status(INTEGER, TEXT) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION saas_super_toggle_company_status(INTEGER, TEXT) TO authenticated;
  END IF;
END $$;

-- ---------- تقرير محسّن — يفحص SELECT/INSERT/UPDATE/DELETE فقط ----------
CREATE OR REPLACE FUNCTION saas_security_health_report()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  tbl_count INTEGER;
  rls_on_count INTEGER;
  policy_count INTEGER;
  rpc_count INTEGER;
  trigger_count INTEGER;
  tables_no_rls JSONB;
  policies_using_true JSONB;
  policies_check_true JSONB;
  definer_rpcs JSONB;
  rpcs_no_tenant JSONB;
  anon_data_grants JSONB;
  dangerous_rpc_anon JSONB;
  employee_portal_rpc_anon JSONB;
  critical_rls JSONB;
  findings JSONB := '[]'::jsonb;
  fail_logins_24h INTEGER := 0;
  fail_logins_15m INTEGER := 0;
  top_attack_ips JSONB := '[]'::jsonb;
  audit_deletes_24h INTEGER := 0;
  audit_perm_24h INTEGER := 0;
  audit_super_24h INTEGER := 0;
  super_admin_count INTEGER := 0;
  active_companies INTEGER := 0;
  suspended_companies INTEGER := 0;
  score INTEGER := 100;
  verdict TEXT := 'safe';
  verdict_ar TEXT;
  verdict_summary_ar TEXT;
  attack_suspected BOOLEAN := false;
  has_critical BOOLEAN := false;
  has_high BOOLEAN := false;
  enterprise_ready BOOLEAN;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  SELECT COUNT(*) INTO tbl_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT COUNT(*) INTO rls_on_count
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = TRUE;

  SELECT COUNT(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public';
  SELECT COUNT(*) INTO rpc_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f';

  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT COALESCE(jsonb_agg(c.relname ORDER BY c.relname), '[]'::jsonb) INTO tables_no_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = FALSE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'qual', qual::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_using_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND qual IS NOT NULL
    AND qual::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', tablename, 'policy', policyname, 'cmd', cmd, 'with_check', with_check::text
  ) ORDER BY tablename, policyname), '[]'::jsonb) INTO policies_check_true
  FROM pg_policies
  WHERE schemaname = 'public'
    AND with_check IS NOT NULL
    AND with_check::text ~ '(^|[^a-z_])true([^a-z_]|$)';

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO definer_rpcs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = TRUE;

  SELECT COALESCE(jsonb_agg(p.proname ORDER BY p.proname), '[]'::jsonb) INTO rpcs_no_tenant
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosecdef = TRUE
    AND p.proname LIKE 'saas_%'
    AND p.proname NOT IN (
      'saas_verify_login', 'saas_force_reset_password', 'saas_fetch_employee_attendance',
      'saas_fetch_employee_salary_records', 'saas_fetch_employee_notifications',
      'saas_fetch_employee_client_profile', 'saas_fetch_employee_leaves',
      'saas_upsert_attendance_by_device', 'saas_upsert_attendance_employee',
      'saas_link_device_by_token', 'saas_mark_employee_portal_notification_read',
      'saas_get_company_subscription_status', 'saas_logout_self',
      'saas_revoke_all_sessions_for_user', 'saas_revoke_all_super_admin_sessions',
      'saas_revoke_auth_sessions_for_user', 'saas_rotate_user_password',
      'saas_super_admin_user_id', 'saas_user_auth_email',
      'saas_security_health_report', 'saas_v3_audit_rls_report', 'saas_security_grants_audit',
      'saas_save_platform_globals', 'saas_super_upsert_company',
      'saas_super_toggle_company_status', 'saas_super_delete_company',
      'saas_super_renew_subscription', 'saas_super_delete_subscription',
      'saas_mark_subscription_expired', 'saas_get_plan_limits',
      'saas_assert_plan_feature', 'saas_assert_company_active',
      'saas_assert_employee_limit', 'saas_v3_employee_portal_subscription_ok',
      'saas_check_api_rate_limit', 'saas_record_api_attempt',
      'saas_check_login_rate_limit', 'saas_record_login_attempt',
      'saas_hash_password_bcrypt', 'saas_create_session', 'saas_verify_session',
      'saas_revoke_session', 'saas_count_legacy_seed_users',
      'saas_super_admin_default_perms', 'saas_super_admin_effective_perms',
      'saas_super_admin_can', 'saas_super_admin_sender_meta',
      'saas_v3_company_setting', 'saas_v3_compute_leave_deductions',
      'saas_v3_finance_totals', 'saas_v3_write_audit', 'saas_v3_employee_portal_authorize'
    )
    AND pg_get_functiondef(p.oid) !~* (
      'auth_company_id|auth_is_super_admin|saas_v3_assert_tenant|saas_assert_company_active'
      || '|auth_can_manage_tenant_users|saas_v3_compute_salary|saas_upsert_attendance_admin'
      || '|saas_resolve_qr_registration|saas_issue_salary|saas_preview_salary'
      || '|saas_v3_employee_portal_authorize|auth_jwt_saas_user_id_raw|auth\.uid\(\)'
    );

  -- صلاحيات بيانات anon فقط (SELECT/INSERT/UPDATE/DELETE) — REFERENCES/TRIGGER ليست ثغرة
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', table_name, 'privilege', privilege_type
  ) ORDER BY table_name, privilege_type), '[]'::jsonb) INTO anon_data_grants
  FROM information_schema.role_table_grants
  WHERE grantee = 'anon' AND table_schema = 'public'
    AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    AND table_name IN (
      'employees', 'attendance', 'salary_records', 'companies', 'subscriptions',
      'saas_users', 'app_settings', 'audit_logs', 'departments', 'leaves',
      'employee_notifications', 'login_attempts', 'saas_sessions'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname, 'grantee', grantee.rolname
  ) ORDER BY p.proname), '[]'::jsonb) INTO dangerous_rpc_anon
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND grantee.rolname IN ('anon', 'public')
    AND p.proname IN (
      'saas_rotate_user_password', 'saas_super_upsert_company', 'saas_super_delete_company',
      'saas_super_toggle_company_status', 'saas_super_renew_subscription',
      'saas_super_delete_subscription', 'saas_save_platform_globals',
      'saas_revoke_all_sessions_for_user', 'saas_user_auth_email'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'function', p.proname, 'grantee', grantee.rolname
  ) ORDER BY p.proname), '[]'::jsonb) INTO employee_portal_rpc_anon
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
  JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND grantee.rolname = 'anon'
    AND p.proname IN (
      'saas_fetch_employee_attendance', 'saas_fetch_employee_salary_records',
      'saas_fetch_employee_notifications', 'saas_fetch_employee_leaves',
      'saas_fetch_employee_client_profile', 'saas_mark_employee_portal_notification_read',
      'saas_v3_employee_portal_authorize', 'saas_verify_login',
      'saas_get_company_subscription_status', 'saas_link_device_by_token',
      'saas_resolve_qr_registration', 'saas_lookup_device_registration'
    );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'table', c.relname, 'rls_enabled', c.relrowsecurity
  ) ORDER BY c.relname), '[]'::jsonb) INTO critical_rls
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND c.relname IN (
      'employees', 'attendance', 'salary_records', 'companies', 'subscriptions',
      'saas_users', 'app_settings', 'audit_logs', 'departments', 'leaves'
    )
    AND c.relrowsecurity IS NOT TRUE;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'login_attempts') THEN
    SELECT COUNT(*) INTO fail_logins_24h
    FROM login_attempts WHERE success = false AND created_at >= NOW() - INTERVAL '24 hours';
    SELECT COUNT(*) INTO fail_logins_15m
    FROM login_attempts WHERE success = false AND created_at >= NOW() - INTERVAL '15 minutes';
    SELECT COALESCE(jsonb_agg(jsonb_build_object('ip', sub.ip_address, 'attempts', sub.cnt) ORDER BY sub.cnt DESC), '[]'::jsonb)
    INTO top_attack_ips
    FROM (
      SELECT ip_address, COUNT(*) AS cnt FROM login_attempts
      WHERE success = false AND created_at >= NOW() - INTERVAL '24 hours' AND COALESCE(ip_address, '') <> ''
      GROUP BY ip_address ORDER BY cnt DESC LIMIT 5
    ) sub;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'audit_logs') THEN
    SELECT COUNT(*) INTO audit_deletes_24h FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (action ILIKE '%delete%' OR action ILIKE '%حذف%' OR details ILIKE '%delete%' OR details ILIKE '%حذف%');
    SELECT COUNT(*) INTO audit_perm_24h FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (action ILIKE '%perm%' OR details ILIKE '%perm%' OR details ILIKE '%صلاح%');
    SELECT COUNT(*) INTO audit_super_24h FROM audit_logs
    WHERE created_at >= NOW() - INTERVAL '24 hours'
      AND (actor_role = 'super_admin' OR details ILIKE '%super_admin%');
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'saas_users') THEN
    SELECT COUNT(*) INTO super_admin_count FROM saas_users WHERE role = 'super_admin' AND is_active IS TRUE;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'companies') THEN
    SELECT COUNT(*) INTO active_companies FROM companies WHERE status = 'active';
    SELECT COUNT(*) INTO suspended_companies FROM companies WHERE status = 'suspended';
  END IF;

  enterprise_ready :=
    jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(anon_data_grants, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(dangerous_rpc_anon, '[]'::jsonb)) = 0
    AND jsonb_array_length(COALESCE(critical_rls, '[]'::jsonb)) = 0;

  -- findings
  IF jsonb_array_length(COALESCE(tables_no_rls, '[]'::jsonb)) > 0 THEN
    has_critical := true; score := score - 35;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'tables_no_rls', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'جداول عامة بدون عزل RLS',
      'detail_ar', 'يوجد ' || jsonb_array_length(tables_no_rls)::text || ' جدول/جداول بدون RLS — خطر تسرب بيانات بين الشركات.',
      'recommendation_ar', 'فعّل RLS فوراً على كل الجداول الحساسة.',
      'count', jsonb_array_length(tables_no_rls), 'items', tables_no_rls));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'tables_no_rls', 'severity', 'info', 'status', 'pass',
      'title_ar', 'عزل الجداول (RLS)', 'detail_ar', 'جميع الجداول العامة محمية بـ RLS.',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb));
  END IF;

  IF jsonb_array_length(COALESCE(anon_data_grants, '[]'::jsonb)) > 0 THEN
    has_critical := true; score := score - 40;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'anon_data_grants', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'صلاحيات anon لقراءة/كتابة البيانات',
      'detail_ar', 'دور anon يملك SELECT/INSERT/UPDATE/DELETE على جداول حساسة — ثغرة حقيقية.',
      'recommendation_ar', 'نفّذ: REVOKE ALL ON TABLE ... FROM anon; وREVOKE SELECT ON ALL TABLES FROM anon;',
      'count', jsonb_array_length(anon_data_grants), 'items', anon_data_grants));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'anon_data_grants', 'severity', 'info', 'status', 'pass',
      'title_ar', 'حماية anon على الجداول',
      'detail_ar', 'لا توجد صلاحيات SELECT/INSERT/UPDATE/DELETE لـ anon على الجداول الحساسة. (REFERENCES/TRIGGER لا تُعد ثغرة)',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb));
  END IF;

  IF jsonb_array_length(COALESCE(dangerous_rpc_anon, '[]'::jsonb)) > 0 THEN
    has_critical := true; score := score - 45;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'dangerous_rpc_anon', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'دوال Super Admin / حساسة مفتوحة لـ anon',
      'detail_ar', 'RPCs إدارية متاحة لـ anon أو PUBLIC — يجب تقييدها على authenticated فقط.',
      'recommendation_ar', 'طبّق migration 084 أو REVOKE EXECUTE FROM anon, PUBLIC على هذه الدوال.',
      'count', jsonb_array_length(dangerous_rpc_anon), 'items', dangerous_rpc_anon));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'dangerous_rpc_anon', 'severity', 'info', 'status', 'pass',
      'title_ar', 'دوال Super Admin محمية',
      'detail_ar', 'لا توجد RPCs إدارية خطرة متاحة لـ anon.',
      'recommendation_ar', '—', 'count', 0, 'items', '[]'::jsonb));
  END IF;

  IF jsonb_array_length(COALESCE(employee_portal_rpc_anon, '[]'::jsonb)) > 0 THEN
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'employee_portal_anon_rpc', 'severity', 'info', 'status', 'pass',
      'title_ar', 'بوابة الموظف (anon RPCs — مقصود)',
      'detail_ar', jsonb_array_length(employee_portal_rpc_anon)::text
        || ' دالة anon لبوابة الموظف — محمية داخلياً بـ saas_v3_employee_portal_authorize وبصمة الجهاز.',
      'recommendation_ar', 'لا إجراء — هذا التصميم مقصود. تأكد فقط من RLS على الجداول.',
      'count', jsonb_array_length(employee_portal_rpc_anon), 'items', employee_portal_rpc_anon));
  END IF;

  IF jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb)) > 0
     OR jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)) > 0 THEN
    has_high := true; score := score - 15;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'policies_literal_true', 'severity', 'high', 'status', 'warn',
      'title_ar', 'سياسات RLS مفتوحة (true)',
      'detail_ar', 'توجد policies تستخدم USING(true) أو WITH CHECK(true).',
      'recommendation_ar', 'استبدل true بشروط auth.uid() أو auth_company_id().',
      'count', jsonb_array_length(COALESCE(policies_using_true, '[]'::jsonb))
        + jsonb_array_length(COALESCE(policies_check_true, '[]'::jsonb)),
      'items', COALESCE(policies_using_true, '[]'::jsonb) || COALESCE(policies_check_true, '[]'::jsonb)));
  END IF;

  IF jsonb_array_length(COALESCE(rpcs_no_tenant, '[]'::jsonb)) > 0 THEN
    has_high := true; score := score - 8;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'rpcs_no_tenant', 'severity', 'medium', 'status', 'warn',
      'title_ar', 'RPCs للمراجعة اليدوية',
      'detail_ar', jsonb_array_length(rpcs_no_tenant)::text || ' دالة بدون تحقق tenant ظاهر في الكود — راجعها.',
      'recommendation_ar', 'تأكد أن كل RPC يتحقق من الشركة أو يكون في whitelist.',
      'count', jsonb_array_length(rpcs_no_tenant), 'items', rpcs_no_tenant));
  END IF;

  IF fail_logins_15m >= 30 OR fail_logins_24h >= 150 THEN
    attack_suspected := true; has_critical := true; score := score - 25;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force_attack', 'severity', 'critical', 'status', 'fail',
      'title_ar', 'هجوم تخمين كلمات المرور',
      'detail_ar', fail_logins_15m::text || ' فاشلة / 15د، ' || fail_logins_24h::text || ' / 24س.',
      'recommendation_ar', 'راجع login_attempts وحظر IPs المشبوهة.',
      'count', fail_logins_24h, 'items', top_attack_ips));
  ELSIF fail_logins_24h >= 40 THEN
    has_high := true; score := score - 10;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force_elevated', 'severity', 'high', 'status', 'warn',
      'title_ar', 'محاولات دخول فاشلة مرتفعة',
      'detail_ar', fail_logins_24h::text || ' محاولة فاشلة / 24 ساعة.',
      'recommendation_ar', 'راقب الحسابات المستهدفة.',
      'count', fail_logins_24h, 'items', top_attack_ips));
  ELSE
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'brute_force', 'severity', 'info', 'status', 'pass',
      'title_ar', 'محاولات الدخول', 'detail_ar', 'لا هجوم واضح (' || fail_logins_24h::text || ' فاشلة / 24س).',
      'recommendation_ar', '—', 'count', fail_logins_24h, 'items', top_attack_ips));
  END IF;

  IF audit_deletes_24h >= 25 THEN
    attack_suspected := true; has_high := true; score := score - 12;
    findings := findings || jsonb_build_array(jsonb_build_object(
      'id', 'mass_deletes', 'severity', 'high', 'status', 'warn',
      'title_ar', 'حذف جماعي مشبوه',
      'detail_ar', audit_deletes_24h::text || ' عملية حذف / 24 ساعة.',
      'recommendation_ar', 'راجع audit_logs.',
      'count', audit_deletes_24h, 'items', '[]'::jsonb));
  END IF;

  score := GREATEST(0, LEAST(100, score));

  IF attack_suspected AND (has_critical OR fail_logins_24h >= 100) THEN
    verdict := 'attack_suspected';
    verdict_ar := '⚠️ نشاط مشبوه — احتمال هجوم';
    verdict_summary_ar := 'رُصدت محاولات دخول أو نشاط غير طبيعي. راجع السجلات فوراً.';
  ELSIF has_critical OR score < 50 THEN
    verdict := 'critical';
    verdict_ar := '🔴 خطر أمني حرج';
    verdict_summary_ar := 'ثغرات حقيقية في RLS أو صلاحيات anon أو RPCs إدارية — عالج فوراً.';
  ELSIF has_high OR score < 80 OR NOT enterprise_ready THEN
    verdict := 'warning';
    verdict_ar := '🟡 تحذير — مراجعة مطلوبة';
    verdict_summary_ar := 'لا دليل على اختراق، لكن توجد نقاط تحتاج مراجعة.';
  ELSE
    verdict := 'safe';
    verdict_ar := '🟢 آمن — لم يُكتشَف اختراق';
    verdict_summary_ar := 'RLS، anon، RPCs، ومحاولات الدخول ضمن المستوى المقبول.';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'generated_at', NOW(),
    'verdict', verdict,
    'verdict_ar', verdict_ar,
    'verdict_summary_ar', verdict_summary_ar,
    'security_score', score,
    'attack_suspected', attack_suspected,
    'compromised_confirmed', false,
    'findings', findings,
    'metrics', jsonb_build_object(
      'failed_logins_24h', fail_logins_24h,
      'failed_logins_15m', fail_logins_15m,
      'audit_deletes_24h', audit_deletes_24h,
      'audit_permission_changes_24h', audit_perm_24h,
      'audit_super_admin_actions_24h', audit_super_24h,
      'super_admin_active_count', super_admin_count,
      'active_companies', active_companies,
      'suspended_companies', suspended_companies
    ),
    'table_count', tbl_count,
    'tables_rls_enabled', rls_on_count,
    'policy_count', policy_count,
    'rpc_count', rpc_count,
    'trigger_count', trigger_count,
    'tables_without_rls', tables_no_rls,
    'policies_using_true', policies_using_true,
    'policies_with_check_true', policies_check_true,
    'security_definer_rpcs', definer_rpcs,
    'rpcs_without_tenant_validation', rpcs_no_tenant,
    'anon_table_grants', anon_data_grants,
    'anon_data_grants', anon_data_grants,
    'critical_rpc_anon_grants', dangerous_rpc_anon,
    'dangerous_rpc_anon_grants', dangerous_rpc_anon,
    'employee_portal_anon_rpcs', employee_portal_rpc_anon,
    'critical_tables_rls_off', critical_rls,
    'top_attack_ips', top_attack_ips,
    'enterprise_ready', enterprise_ready
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_security_health_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_security_health_report() TO authenticated;

COMMENT ON FUNCTION saas_security_health_report() IS
  '084 — فحص دقيق: anon data grants فقط، whitelist بوابة الموظف، قفل super RPCs';

-- END: 084_security_report_anon_fix.sql
