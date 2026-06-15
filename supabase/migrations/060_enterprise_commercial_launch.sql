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
