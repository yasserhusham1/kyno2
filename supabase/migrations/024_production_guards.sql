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
