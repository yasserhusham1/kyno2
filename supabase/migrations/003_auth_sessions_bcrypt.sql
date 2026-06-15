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
