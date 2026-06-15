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
