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
