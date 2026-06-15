-- ============================================================
-- KYNO 027 — Production Final Hardening
-- Additive — no DROP POLICY — backward compatible legacy paths
-- ============================================================

-- ----------------------------------------------------------
-- 1) Generic API rate limiting (attendance + device link)
-- ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_rate_attempts (
  id          BIGSERIAL PRIMARY KEY,
  scope       TEXT NOT NULL,
  rate_key    TEXT NOT NULL DEFAULT '',
  ip_address  TEXT NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_api_rate_scope_key_time
  ON api_rate_attempts (scope, rate_key, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_rate_scope_ip_time
  ON api_rate_attempts (scope, ip_address, created_at DESC)
  WHERE ip_address <> '';

CREATE OR REPLACE FUNCTION saas_check_api_rate_limit(
  p_scope TEXT,
  p_rate_key TEXT,
  p_ip TEXT DEFAULT NULL,
  p_max INTEGER DEFAULT 60,
  p_window_sec INTEGER DEFAULT 1800
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sc TEXT := lower(trim(COALESCE(p_scope, '')));
  rk TEXT := trim(COALESCE(p_rate_key, ''));
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  window_start TIMESTAMPTZ := NOW() - make_interval(secs => GREATEST(p_window_sec, 60));
  cnt_key INTEGER := 0;
  cnt_ip INTEGER := 0;
BEGIN
  IF sc = '' THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  IF rk <> '' THEN
    SELECT COUNT(*) INTO cnt_key
    FROM api_rate_attempts
    WHERE scope = sc AND rate_key = rk AND created_at >= window_start;
    IF cnt_key >= p_max THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'reason', 'key',
        'retry_after_sec', p_window_sec
      );
    END IF;
  END IF;

  IF ip IS NOT NULL THEN
    SELECT COUNT(*) INTO cnt_ip
    FROM api_rate_attempts
    WHERE scope = sc AND ip_address = ip AND created_at >= window_start;
    IF cnt_ip >= p_max THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'reason', 'ip',
        'retry_after_sec', p_window_sec
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

CREATE OR REPLACE FUNCTION saas_record_api_attempt(
  p_scope TEXT,
  p_rate_key TEXT DEFAULT '',
  p_ip TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO api_rate_attempts (scope, rate_key, ip_address)
  VALUES (
    lower(trim(COALESCE(p_scope, ''))),
    trim(COALESCE(p_rate_key, '')),
    COALESCE(NULLIF(trim(p_ip), ''), '')
  );
  DELETE FROM api_rate_attempts WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$;

REVOKE ALL ON TABLE api_rate_attempts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE api_rate_attempts TO service_role;
REVOKE ALL ON FUNCTION saas_check_api_rate_limit(TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_record_api_attempt(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_check_api_rate_limit(TEXT, TEXT, TEXT, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION saas_record_api_attempt(TEXT, TEXT, TEXT) TO service_role;

-- ----------------------------------------------------------
-- 2) force_password_reset — block login + self-reset RPC
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_force_reset_password(
  p_username TEXT,
  p_current_password TEXT,
  p_new_password TEXT,
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
  new_hash TEXT;
BEGIN
  IF uname IS NULL OR length(uname) < 2
     OR p_current_password IS NULL OR p_new_password IS NULL
     OR length(trim(p_new_password)) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_args');
  END IF;

  SELECT * INTO u FROM saas_users WHERE lower(username) = uname AND is_active = true LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  END IF;
  IF COALESCE(u.force_password_reset, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reset_not_required');
  END IF;

  legacy_hash := encode(convert_to(p_current_password, 'UTF8'), 'base64');

  IF COALESCE(u.password_algo, 'legacy_b64') = 'bcrypt'
     OR (u.password_hash IS NOT NULL AND u.password_hash LIKE '$2%') THEN
    IF u.password_hash IS NULL OR extensions.crypt(p_current_password, u.password_hash) IS DISTINCT FROM u.password_hash THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
    END IF;
  ELSIF u.password_algo = 'sha256' THEN
    IF u.password_hash IS DISTINCT FROM encode(extensions.digest(p_current_password || ':' || u.id::text, 'sha256'), 'hex') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
    END IF;
  ELSIF u.password_hash IS DISTINCT FROM legacy_hash THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  END IF;

  new_hash := saas_hash_password_bcrypt(trim(p_new_password));
  IF new_hash IS NULL OR new_hash = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'password_hash_failed');
  END IF;

  UPDATE saas_users
  SET password_hash = new_hash,
      password_algo = 'bcrypt',
      force_password_reset = false
  WHERE id = u.id;

  RETURN jsonb_build_object('ok', true, 'username', u.username);
END;
$$;

REVOKE ALL ON FUNCTION saas_force_reset_password(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_force_reset_password(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

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

  IF COALESCE(u.force_password_reset, false) IS TRUE THEN
    RETURN jsonb_build_object(
      'error', 'password_reset_required',
      'username', u.username,
      'id', u.id,
      'role', u.role
    );
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
    'force_password_reset', false
  );
END;
$$;

DROP FUNCTION IF EXISTS saas_verify_login(TEXT, TEXT);
REVOKE ALL ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_verify_login(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ----------------------------------------------------------
-- 3) Attendance RPC — rate limit + server checkout OT/status
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_upsert_attendance_by_device(
  p_employee_id INTEGER,
  p_fingerprint TEXT,
  p_date_iso TEXT,
  p_date_label TEXT DEFAULT NULL,
  p_check_in TEXT DEFAULT NULL,
  p_check_out TEXT DEFAULT NULL,
  p_hours TEXT DEFAULT NULL,
  p_late TEXT DEFAULT NULL,
  p_overtime TEXT DEFAULT NULL,
  p_status TEXT DEFAULT 'طبيعي',
  p_emp_name TEXT DEFAULT NULL,
  p_dept TEXT DEFAULT NULL,
  p_days INTEGER DEFAULT NULL,
  p_late_min INTEGER DEFAULT NULL,
  p_punch_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  dev_ok BOOLEAN := FALSE;
  att_id INTEGER;
  co_id INTEGER;
  active_chk JSONB;
  rate_chk JSONB;
  punch TEXT := lower(NULLIF(trim(p_punch_type), ''));
  srv_ts TIMESTAMPTZ;
  srv_date DATE;
  srv_ci TEXT;
  use_ci TEXT;
  use_co TEXT;
  use_date_iso DATE;
  use_date_label TEXT;
  use_late TEXT;
  use_ot TEXT;
  use_status TEXT;
  use_hours TEXT;
  actual_min INTEGER;
  official_min INTEGER;
  late_min INTEGER;
  late_threshold INTEGER := 15;
  ci_min INTEGER;
  co_min INTEGER;
  official_co_min INTEGER;
  ot_min INTEGER;
  existing RECORD;
  att_row attendance%ROWTYPE;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  IF punch IN ('check_in', 'check_out') THEN
    rate_chk := saas_check_api_rate_limit(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'remote'),
      NULL,
      120,
      3600
    );
    IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'rate_limited',
        'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 3600)
      );
    END IF;
    PERFORM saas_record_api_attempt(
      'attendance_punch',
      p_employee_id::text || ':' || COALESCE(fp, 'remote'),
      NULL
    );
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  co_id := emp.company_id;

  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF emp.remote_attend IS TRUE THEN
    dev_ok := TRUE;
  ELSIF fp IS NOT NULL AND length(fp) >= 4 THEN
    SELECT EXISTS (
      SELECT 1 FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  IF p_days IS NOT NULL OR p_late_min IS NOT NULL THEN
    UPDATE employees SET
      days = COALESCE(p_days, days),
      late_min = COALESCE(p_late_min, late_min),
      updated_at = NOW()
    WHERE id = p_employee_id;
  END IF;

  srv_ts := basma_server_now_baghdad();
  srv_date := basma_date_iso_baghdad();
  srv_ci := basma_format_time_ampm(srv_ts);

  IF punch = 'check_in' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_ci := srv_ci;
    use_co := NULL;
    use_hours := NULL;
    use_ot := '—';

    IF emp.open_hours IS TRUE THEN
      use_late := '—';
      use_status := 'طبيعي';
    ELSE
      actual_min := basma_time_text_to_minutes(srv_ci);
      official_min := basma_db_time_to_minutes(emp.check_in);
      late_min := GREATEST(0, actual_min - official_min);
      IF late_min > late_threshold THEN
        use_status := 'متأخر';
        use_late := late_min || 'د';
      ELSIF late_min > 0 THEN
        use_status := 'طبيعي';
        use_late := late_min || 'د';
      ELSE
        use_status := 'طبيعي';
        use_late := '—';
      END IF;
    END IF;

  ELSIF punch = 'check_out' THEN
    use_date_iso := srv_date;
    use_date_label := basma_arabic_date_label(srv_date);
    use_co := basma_format_time_ampm(srv_ts);

    SELECT a.check_in, a.late, a.status INTO existing
    FROM attendance a
    WHERE a.employee_id = p_employee_id AND a.date_iso = srv_date
    LIMIT 1;

    IF existing.check_in IS NOT NULL AND existing.check_in <> '—' THEN
      use_ci := existing.check_in;
      use_late := COALESCE(NULLIF(trim(existing.late), ''), '—');
      use_status := COALESCE(NULLIF(trim(existing.status), ''), 'طبيعي');
    ELSE
      use_ci := srv_ci;
      use_late := '—';
      use_status := 'طبيعي';
    END IF;

    IF emp.open_hours IS TRUE THEN
      use_hours := '—';
      use_late := '—';
      use_ot := '—';
      use_status := 'طبيعي';
    ELSE
      ci_min := basma_time_text_to_minutes(use_ci);
      co_min := basma_time_text_to_minutes(use_co);
      official_co_min := basma_db_time_to_minutes(emp.check_out);
      IF co_min >= ci_min THEN
        use_hours := basma_minutes_to_hours_str(co_min - ci_min);
      ELSE
        use_hours := '0س 0د';
      END IF;
      ot_min := GREATEST(0, co_min - official_co_min);
      IF ot_min > 0 THEN
        use_ot := basma_minutes_to_hours_str(ot_min);
        IF use_status = 'طبيعي' THEN
          use_status := 'إضافي';
        END IF;
      ELSE
        use_ot := '—';
      END IF;
    END IF;

  ELSE
    IF p_date_iso IS NULL OR length(trim(p_date_iso)) < 8 THEN
      IF NULLIF(trim(p_check_in), '') IS NULL
         AND NULLIF(trim(p_check_out), '') IS NULL
         AND NULLIF(trim(p_hours), '') IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
      END IF;
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
    END IF;
    use_date_iso := p_date_iso::date;
    use_date_label := COALESCE(NULLIF(trim(p_date_label), ''), p_date_iso);
    use_ci := NULLIF(trim(p_check_in), '');
    use_co := NULLIF(trim(p_check_out), '');
    use_hours := NULLIF(trim(p_hours), '');
    use_late := NULLIF(trim(p_late), '');
    use_ot := NULLIF(trim(p_overtime), '');
    use_status := COALESCE(NULLIF(trim(p_status), ''), 'طبيعي');
  END IF;

  IF punch IS NULL
     AND NULLIF(trim(p_check_in), '') IS NULL
     AND NULLIF(trim(p_check_out), '') IS NULL
     AND NULLIF(trim(p_hours), '') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'employee_id', p_employee_id, 'stats_only', true);
  END IF;

  INSERT INTO attendance (
    employee_id, emp_name, dept, date_label, date_iso,
    check_in, check_out, hours, late, overtime, status, company_id
  ) VALUES (
    p_employee_id,
    COALESCE(NULLIF(trim(p_emp_name), ''), emp.name),
    COALESCE(NULLIF(trim(p_dept), ''), emp.dept),
    use_date_label,
    use_date_iso,
    use_ci,
    use_co,
    use_hours,
    use_late,
    use_ot,
    use_status,
    co_id
  )
  ON CONFLICT (employee_id, date_iso) DO UPDATE SET
    emp_name = EXCLUDED.emp_name,
    dept = EXCLUDED.dept,
    date_label = EXCLUDED.date_label,
    check_in = COALESCE(EXCLUDED.check_in, attendance.check_in),
    check_out = COALESCE(EXCLUDED.check_out, attendance.check_out),
    hours = COALESCE(EXCLUDED.hours, attendance.hours),
    late = COALESCE(EXCLUDED.late, attendance.late),
    overtime = COALESCE(EXCLUDED.overtime, attendance.overtime),
    status = COALESCE(EXCLUDED.status, attendance.status),
    company_id = EXCLUDED.company_id,
    updated_at = NOW()
  RETURNING * INTO att_row;

  att_id := att_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'attendance_id', att_id,
    'employee_id', p_employee_id,
    'check_in', COALESCE(att_row.check_in, '—'),
    'check_out', COALESCE(att_row.check_out, '—'),
    'date_iso', att_row.date_iso,
    'date_label', att_row.date_label,
    'hours', COALESCE(att_row.hours, '—'),
    'late', COALESCE(att_row.late, '—'),
    'overtime', COALESCE(att_row.overtime, '—'),
    'status', COALESCE(att_row.status, 'طبيعي'),
    'server_authoritative', punch IN ('check_in', 'check_out')
  );
END;
$$;

-- ----------------------------------------------------------
-- 4) Device linking — rate limit + subscription guard
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION saas_link_device_by_token(
  p_token TEXT DEFAULT NULL,
  p_fingerprint TEXT DEFAULT NULL,
  p_ip TEXT DEFAULT NULL,
  p_device_info JSONB DEFAULT '{}'::jsonb,
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
  now_ts TIMESTAMPTZ := NOW();
  tok TEXT := NULLIF(trim(p_token), '');
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  rate_chk JSONB;
  active_chk JSONB;
  co_id INTEGER;
BEGIN
  IF fp IS NULL OR length(fp) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  rate_chk := saas_check_api_rate_limit('device_link', fp, ip, 10, 900);
  IF COALESCE((rate_chk->>'allowed')::boolean, true) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'rate_limited',
      'retry_after_sec', COALESCE((rate_chk->>'retry_after_sec')::integer, 900)
    );
  END IF;
  PERFORM saas_record_api_attempt('device_link', fp, ip);

  IF tok IS NOT NULL AND length(tok) >= 10 THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.token = tok
    LIMIT 1;
  ELSIF p_employee_id IS NOT NULL AND p_slot IS NOT NULL THEN
    SELECT ed.*, e.name AS emp_name, e.company_id AS emp_company_id
    INTO d
    FROM employee_devices ed
    JOIN employees e ON e.id = ed.employee_id
    WHERE ed.employee_id = p_employee_id AND ed.slot = p_slot
    LIMIT 1;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  co_id := d.emp_company_id;
  active_chk := saas_assert_company_active(co_id);
  IF COALESCE((active_chk->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'detail', COALESCE(active_chk->>'error', 'unknown')
    );
  END IF;

  IF d.fingerprint IS NOT NULL AND d.fingerprint <> '' AND d.fingerprint <> fp THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_already_linked');
  END IF;

  UPDATE employee_devices
  SET
    fingerprint = fp,
    ip = COALESCE(ip, employee_devices.ip),
    device_info = COALESCE(p_device_info, device_info, '{}'::jsonb),
    linked_at = COALESCE(linked_at, now_ts),
    token_used_at = now_ts,
    last_login = now_ts
  WHERE id = d.id;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'fingerprint', fp,
    'ip', COALESCE(ip, d.ip, '')
  );
END;
$$;

-- ----------------------------------------------------------
-- 5) Attendance write guard (direct upsert path)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_guard_attendance_write()
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

DROP TRIGGER IF EXISTS attendance_production_guard_insert ON attendance;
CREATE TRIGGER attendance_production_guard_insert
  BEFORE INSERT ON attendance
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_attendance_write();

DROP TRIGGER IF EXISTS attendance_production_guard_update ON attendance;
CREATE TRIGGER attendance_production_guard_update
  BEFORE UPDATE ON attendance
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_attendance_write();

-- Salary UPDATE guard
CREATE OR REPLACE FUNCTION trg_guard_salary_records_write()
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

DROP TRIGGER IF EXISTS salary_records_production_guard_update ON salary_records;
CREATE TRIGGER salary_records_production_guard_update
  BEFORE UPDATE ON salary_records
  FOR EACH ROW
  EXECUTE FUNCTION trg_guard_salary_records_write();

-- ----------------------------------------------------------
-- 6) Database integrity constraints
-- ----------------------------------------------------------
UPDATE employees SET company_id = 1 WHERE company_id IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'employees_company_id_not_null'
  ) THEN
    ALTER TABLE employees ALTER COLUMN company_id SET NOT NULL;
  END IF;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'employees.company_id NOT NULL skipped: %', SQLERRM;
END $$;

-- departments: global UNIQUE(name) incompatible with multi-tenant.
-- employees.dept FK references departments(name) — must drop FK first.
ALTER TABLE employees DROP CONSTRAINT IF EXISTS employees_dept_fkey;

ALTER TABLE departments DROP CONSTRAINT IF EXISTS departments_name_key;

CREATE UNIQUE INDEX IF NOT EXISTS ux_departments_company_name
  ON departments (company_id, lower(trim(name)));

COMMENT ON INDEX ux_departments_company_name IS
  'Multi-tenant dept names — replaces global departments_name_key + employees_dept_fkey';

CREATE UNIQUE INDEX IF NOT EXISTS ux_salary_employee_month
  ON salary_records (employee_id, month_iso);

-- Baghdad today helper (optional read-only for clients)
CREATE OR REPLACE FUNCTION basma_today_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT basma_date_iso_baghdad();
$$;

REVOKE ALL ON FUNCTION basma_today_iso_baghdad() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION basma_today_iso_baghdad() TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;
