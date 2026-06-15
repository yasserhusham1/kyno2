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
