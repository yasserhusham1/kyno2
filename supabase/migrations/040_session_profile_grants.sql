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
