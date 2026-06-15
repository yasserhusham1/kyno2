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
