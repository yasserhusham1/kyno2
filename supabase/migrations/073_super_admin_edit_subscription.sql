-- 073: Super admin — edit subscription (company name, max employees, duration)

CREATE OR REPLACE FUNCTION saas_super_edit_subscription(
  p_subscription_id INTEGER,
  p_company_name TEXT DEFAULT NULL,
  p_max_employees INTEGER DEFAULT NULL,
  p_duration_days INTEGER DEFAULT NULL,
  p_amount INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sub subscriptions%ROWTYPE;
  cid INTEGER;
  dur_days INTEGER;
  start_d DATE;
  end_d DATE;
  dur_months INTEGER;
  pay_amt INTEGER;
  comp_before JSONB;
  comp_after companies%ROWTYPE;
  sub_before JSONB;
  sub_after JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;
  IF NOT (
    saas_super_admin_can('subscriptions_edit')
    OR saas_super_admin_can('subscriptions_renew')
    OR saas_super_admin_can('companies_edit')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
  END IF;
  IF p_subscription_id IS NULL OR p_subscription_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_subscription');
  END IF;

  SELECT * INTO sub FROM subscriptions WHERE id = p_subscription_id LIMIT 1;
  IF sub.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'subscription_not_found');
  END IF;

  cid := sub.company_id;
  sub_before := to_jsonb(sub);

  IF p_company_name IS NOT NULL OR p_max_employees IS NOT NULL THEN
    IF NOT saas_super_admin_can('companies_edit')
       AND NOT saas_super_admin_can('subscriptions_edit')
       AND NOT saas_super_admin_can('subscriptions_renew') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'permission_denied');
    END IF;
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = cid LIMIT 1;
    UPDATE companies SET
      company_name = COALESCE(NULLIF(trim(p_company_name), ''), company_name),
      max_employees = CASE
        WHEN p_max_employees IS NOT NULL AND p_max_employees > 0 THEN p_max_employees
        ELSE max_employees
      END,
      updated_at = NOW()
    WHERE id = cid
    RETURNING * INTO comp_after;
    IF comp_after.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
    END IF;
  END IF;

  IF p_duration_days IS NOT NULL OR p_amount IS NOT NULL THEN
    dur_days := GREATEST(1, COALESCE(p_duration_days, GREATEST(1, (sub.end_date - CURRENT_DATE))));
    start_d := CURRENT_DATE;
    end_d := start_d + dur_days;
    dur_months := GREATEST(1, CEIL(dur_days / 30.0)::INTEGER);
    pay_amt := CASE
      WHEN p_amount IS NOT NULL THEN GREATEST(0, p_amount)
      ELSE COALESCE(sub.amount, 0)
    END;

    UPDATE subscriptions SET
      start_date = start_d,
      end_date = end_d,
      duration_months = dur_months,
      amount = pay_amt,
      status = CASE WHEN end_d >= CURRENT_DATE THEN 'active' ELSE 'expired' END,
      updated_at = NOW()
    WHERE id = p_subscription_id
    RETURNING * INTO sub;
  END IF;

  SELECT to_jsonb(s.*) INTO sub_after FROM subscriptions s WHERE s.id = p_subscription_id LIMIT 1;

  BEGIN
    PERFORM saas_v3_write_audit(
      'subscription_edited', 'subscriptions',
      'Edited subscription #' || p_subscription_id::text || ' for company ' || cid::text,
      'subscription:' || p_subscription_id::text,
      cid,
      sub_before, sub_after,
      'subscriptions', p_subscription_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'subscription_id', p_subscription_id,
    'company_id', cid,
    'data', sub_after
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) TO authenticated, service_role;

COMMENT ON FUNCTION saas_super_edit_subscription(INTEGER, TEXT, INTEGER, INTEGER, INTEGER) IS
  'Super admin — edit subscription duration/amount and company name/max_employees';
