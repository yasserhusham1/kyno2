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
