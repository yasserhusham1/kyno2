-- 103 — فحص مباشر للعطلة الرسمية من موقع الموظف
-- تستخدمه الواجهة قبل الحضور/الانصراف حتى تظهر رسالة التعطيل فوراً.

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
  fp TEXT := NULLIF(trim(COALESCE(p_fingerprint, '')), '');
  dev_ok BOOLEAN := FALSE;
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

  IF fp IS NOT NULL AND length(fp) >= 8 THEN
    SELECT EXISTS (
      SELECT 1
      FROM employee_devices ed
      WHERE ed.employee_id = p_employee_id
        AND ed.fingerprint = fp
    ) INTO dev_ok;
  END IF;

  IF NOT dev_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'device_not_authorized');
  END IF;

  raw := COALESCE(NULLIF(saas_v3_company_setting(emp.company_id, 'official_closures_json'), ''), '[]');

  FOR item IN SELECT * FROM jsonb_array_elements(raw::jsonb) LOOP
    c_start := COALESCE(NULLIF(item->>'startDate', '')::DATE, NULLIF(item->>'start', '')::DATE, NULLIF(item->>'from', '')::DATE);
    c_end := COALESCE(NULLIF(item->>'endDate', '')::DATE, NULLIF(item->>'end', '')::DATE, NULLIF(item->>'to', '')::DATE);
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
      c_pay := CASE WHEN lower(COALESCE(item->>'payType', item->>'type', 'paid')) = 'unpaid' THEN 'unpaid' ELSE 'paid' END;
      days_count := GREATEST(1, (c_end - c_start) + 1);
      RETURN jsonb_build_object(
        'ok', true,
        'active', true,
        'closure', jsonb_build_object(
          'id', COALESCE(item->>'id', 'active_official_closure'),
          'title', COALESCE(NULLIF(item->>'title', ''), NULLIF(item->>'name', ''), 'تعطيل رسمي'),
          'startDate', c_start,
          'endDate', c_end,
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
