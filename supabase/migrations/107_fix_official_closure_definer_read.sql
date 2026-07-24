-- 107 — إصلاح قراءة official_closures_json للموظف (anon)
-- saas_v3_company_setting يستدعي saas_v3_assert_tenant الذي يتطلب JWT
-- فيُرجع NULL داخل RPCs الموظف → التعطيل لا يُطبَّق أبداً.

CREATE OR REPLACE FUNCTION public.saas_v3_company_setting_definer(
  p_company_id INTEGER,
  p_key TEXT
)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.value
  FROM app_settings s
  WHERE p_company_id IS NOT NULL
    AND p_key IS NOT NULL
    AND length(trim(p_key)) > 0
    AND s.key = ('company:' || p_company_id::text || ':' || p_key)
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.saas_v3_company_setting_definer(INTEGER, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION saas_v3_official_closure_days(
  p_company_id INTEGER,
  p_start DATE,
  p_end DATE,
  p_pay_type TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  raw TEXT;
  item JSONB;
  c_start DATE;
  c_end DATE;
  c_pay TEXT;
  d DATE;
  seen TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF p_company_id IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
    RETURN 0;
  END IF;

  raw := COALESCE(
    NULLIF(public.saas_v3_company_setting_definer(p_company_id, 'official_closures_json'), ''),
    '[]'
  );

  FOR item IN SELECT * FROM jsonb_array_elements(raw::jsonb) LOOP
    c_start := COALESCE(
      NULLIF(item->>'startDate', '')::DATE,
      NULLIF(item->>'start', '')::DATE,
      NULLIF(item->>'from', '')::DATE
    );
    c_end := COALESCE(
      NULLIF(item->>'endDate', '')::DATE,
      NULLIF(item->>'end', '')::DATE,
      NULLIF(item->>'to', '')::DATE
    );
    IF c_start IS NULL THEN
      CONTINUE;
    END IF;
    IF c_end IS NULL THEN
      c_end := c_start + GREATEST(1, COALESCE(NULLIF(item->>'days', '')::INTEGER, 1)) - 1;
    END IF;
    IF c_end < c_start THEN
      d := c_start; c_start := c_end; c_end := d;
    END IF;

    c_pay := CASE
      WHEN lower(COALESCE(item->>'payType', item->>'type', 'paid')) = 'unpaid' THEN 'unpaid'
      ELSE 'paid'
    END;
    IF p_pay_type IS NOT NULL AND c_pay <> lower(p_pay_type) THEN
      CONTINUE;
    END IF;

    d := GREATEST(c_start, p_start);
    WHILE d <= LEAST(c_end, p_end) LOOP
      IF NOT d::TEXT = ANY(seen) THEN
        seen := array_append(seen, d::TEXT);
      END IF;
      d := d + 1;
    END LOOP;
  END LOOP;

  RETURN COALESCE(array_length(seen, 1), 0);
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.saas_get_official_closures_json_for_employee(
  p_employee_id INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  raw TEXT;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.id, e.company_id INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND OR emp.company_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  raw := COALESCE(
    NULLIF(public.saas_v3_company_setting_definer(emp.company_id, 'official_closures_json'), ''),
    '[]'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', emp.company_id,
    'closures_json', raw
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'official_closure_read_failed');
END;
$$;

REVOKE ALL ON FUNCTION public.saas_get_official_closures_json_for_employee(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_get_official_closures_json_for_employee(INTEGER) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.saas_get_active_official_closure_for_employee(
  p_employee_id INTEGER,
  p_fingerprint TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  emp RECORD;
  raw TEXT;
  item JSONB;
  c_start DATE;
  c_end DATE;
  c_pay TEXT;
  today DATE := basma_date_iso_baghdad();
  tmp_date DATE;
  days_count INTEGER;
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  SELECT e.* INTO emp FROM employees e WHERE e.id = p_employee_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_not_found');
  END IF;

  raw := COALESCE(
    NULLIF(public.saas_v3_company_setting_definer(emp.company_id, 'official_closures_json'), ''),
    '[]'
  );

  FOR item IN SELECT * FROM jsonb_array_elements(raw::jsonb) LOOP
    c_start := COALESCE(
      NULLIF(item->>'startDate', '')::DATE,
      NULLIF(item->>'start', '')::DATE,
      NULLIF(item->>'from', '')::DATE
    );
    c_end := COALESCE(
      NULLIF(item->>'endDate', '')::DATE,
      NULLIF(item->>'end', '')::DATE,
      NULLIF(item->>'to', '')::DATE
    );
    IF c_start IS NULL THEN
      CONTINUE;
    END IF;
    IF c_end IS NULL THEN
      c_end := c_start + GREATEST(1, COALESCE(NULLIF(item->>'days', '')::INTEGER, 1)) - 1;
    END IF;
    IF c_end < c_start THEN
      tmp_date := c_start; c_start := c_end; c_end := tmp_date;
    END IF;

    IF today >= c_start AND today <= c_end THEN
      c_pay := CASE
        WHEN lower(COALESCE(item->>'payType', item->>'type', 'paid')) = 'unpaid' THEN 'unpaid'
        ELSE 'paid'
      END;
      days_count := GREATEST(1, (c_end - c_start) + 1);
      RETURN jsonb_build_object(
        'ok', true,
        'active', true,
        'closure', jsonb_build_object(
          'id', COALESCE(item->>'id', 'active_official_closure'),
          'title', COALESCE(NULLIF(item->>'title', ''), NULLIF(item->>'name', ''), 'تعطيل رسمي'),
          'startDate', to_char(c_start, 'YYYY-MM-DD'),
          'endDate', to_char(c_end, 'YYYY-MM-DD'),
          'days', days_count,
          'payType', c_pay
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'active', false);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'official_closure_check_failed');
END;
$$;

REVOKE ALL ON FUNCTION public.saas_get_active_official_closure_for_employee(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saas_get_active_official_closure_for_employee(INTEGER, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
