-- 087: Resolve linked employee by device fingerprint (anon portal) + subscription pending fix

CREATE OR REPLACE FUNCTION saas_resolve_employee_by_fingerprint(p_fingerprint TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  fp TEXT := NULLIF(trim(p_fingerprint), '');
  d RECORD;
  sub_chk JSONB;
BEGIN
  IF fp IS NULL OR length(fp) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_fingerprint');
  END IF;

  SELECT ed.employee_id, ed.slot, ed.label, e.name AS emp_name, e.dept, e.company_id, e.remote_attend
  INTO d
  FROM employee_devices ed
  JOIN employees e ON e.id = ed.employee_id
  WHERE ed.fingerprint = fp
  ORDER BY ed.last_login DESC NULLS LAST, ed.linked_at DESC NULLS LAST, ed.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_found');
  END IF;

  sub_chk := saas_v3_employee_portal_subscription_ok(d.company_id);
  IF COALESCE((sub_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'company_id', d.company_id,
      'detail', sub_chk
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'employee_id', d.employee_id,
    'slot', d.slot,
    'emp_name', d.emp_name,
    'dept', d.dept,
    'company_id', d.company_id,
    'label', COALESCE(d.label, 'الهاتف ' || d.slot::text),
    'remote_attend', COALESCE(d.remote_attend, false)
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_resolve_employee_by_fingerprint(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_resolve_employee_by_fingerprint(TEXT) TO anon, authenticated, service_role;

-- Treat pending/expired rows with a future end_date as active (common after manual renew)
CREATE OR REPLACE FUNCTION saas_get_company_subscription_status(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
  days_left INTEGER;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('valid', true, 'status', 'active', 'message', '', 'daysLeft', 0);
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'status', 'pending', 'message', 'الشركة غير موجودة', 'daysLeft', 0);
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'daysLeft', 0
    );
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'pending',
      'message', 'لا يوجد اشتراك نشط',
      'daysLeft', 0
    );
  END IF;

  days_left := (sub.end_date - CURRENT_DATE);

  IF sub.status = 'suspended' THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'suspended',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', 0
    );
  END IF;

  IF sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  IF sub.status IN ('pending', 'expired') AND sub.end_date >= CURRENT_DATE THEN
    UPDATE subscriptions SET status = 'active', updated_at = NOW()
    WHERE company_id = p_company_id
      AND id = (
        SELECT s2.id FROM subscriptions s2
        WHERE s2.company_id = p_company_id
        ORDER BY s2.created_at DESC NULLS LAST, s2.id DESC
        LIMIT 1
      );
    sub.status := 'active';
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'status', 'active',
    'end_date', sub.end_date,
    'daysLeft', GREATEST(days_left, 0),
    'warning', days_left <= 10,
    'message', CASE
      WHEN days_left <= 10 THEN 'ينتهي الاشتراك خلال ' || GREATEST(days_left, 0)::text || ' يوم'
      ELSE ''
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_company_subscription_status(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_company_subscription_status(INTEGER) TO anon, authenticated, service_role;

COMMENT ON FUNCTION saas_resolve_employee_by_fingerprint(TEXT) IS
  'Employee phone: resolve linked device by fingerprint without cached employee id';
