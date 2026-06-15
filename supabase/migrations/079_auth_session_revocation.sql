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
