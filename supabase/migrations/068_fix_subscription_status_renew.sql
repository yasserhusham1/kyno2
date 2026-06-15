-- 068: Subscription status RPC for employee portal (anon) + harden renew audit writes

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

  IF sub.status = 'pending' OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'valid', false, 'status', 'expired',
      'message', 'حساب الشركة موقوف. تواصل مع الدعم الفني.',
      'end_date', sub.end_date,
      'daysLeft', days_left
    );
  END IF;

  IF sub.status = 'expired' AND sub.end_date >= CURRENT_DATE THEN
    UPDATE subscriptions SET status = 'active', updated_at = NOW()
    WHERE company_id = p_company_id
      AND id = (
        SELECT s2.id FROM subscriptions s2
        WHERE s2.company_id = p_company_id
        ORDER BY s2.created_at DESC NULLS LAST, s2.id DESC
        LIMIT 1
      )
      AND status = 'expired';
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

-- Harden renew: audit failure must not roll back a successful subscription update
DROP FUNCTION IF EXISTS saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT);

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

  IF existing.id IS NOT NULL AND existing.end_date >= CURRENT_DATE THEN
    start_d := COALESCE(existing.start_date, CURRENT_DATE);
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

  UPDATE companies SET status = 'active', updated_at = NOW()
  WHERE id = p_company_id AND status IS DISTINCT FROM 'active';

  SELECT to_jsonb(s.*) INTO after_sub FROM subscriptions s WHERE s.id = sub_id LIMIT 1;

  IF plan_nm IS NOT NULL AND lower(plan_nm) IN ('starter', 'business', 'enterprise') THEN
    SELECT to_jsonb(c.*) INTO comp_before FROM companies c WHERE c.id = p_company_id LIMIT 1;
    UPDATE companies SET plan_tier = lower(plan_nm), updated_at = NOW()
    WHERE id = p_company_id RETURNING * INTO comp_after;
    BEGIN
      PERFORM saas_v3_write_audit(
        'plan_tier_changed', 'subscriptions',
        'Plan tier -> ' || lower(plan_nm),
        comp_after.company_name, p_company_id,
        comp_before, to_jsonb(comp_after),
        'companies', p_company_id::TEXT, NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  BEGIN
    PERFORM saas_v3_write_audit(
      'subscription_renewed', 'subscriptions',
      'Renewed subscription ' || dur_days::text || ' days',
      COALESCE(after_sub->>'plan_name', 'subscription'),
      p_company_id,
      before_sub, after_sub,
      'subscriptions', sub_id::TEXT, NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'subscription_id', sub_id, 'data', after_sub);
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_super_renew_subscription(INTEGER, INTEGER, INTEGER, TEXT, TEXT) TO authenticated, service_role;

COMMENT ON FUNCTION saas_get_company_subscription_status(INTEGER) IS
  'Server-side subscription validity for client UI (inclusive end_date; safe for anon employee portal)';

-- Align server attendance gate with inclusive end_date + repair stale expired flags
CREATE OR REPLACE FUNCTION saas_assert_company_active(p_company_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cstatus TEXT;
  sub RECORD;
BEGIN
  IF p_company_id IS NULL OR p_company_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_company');
  END IF;

  SELECT status INTO cstatus FROM companies WHERE id = p_company_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_not_found');
  END IF;
  IF cstatus = 'suspended' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'company_suspended');
  END IF;

  SELECT s.status, s.end_date INTO sub
  FROM subscriptions s
  WHERE s.company_id = p_company_id
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
  END IF;

  IF sub.status IN ('suspended', 'pending') OR sub.end_date < CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'subscription_inactive',
      'status', sub.status
    );
  END IF;

  IF sub.status = 'expired' AND sub.end_date >= CURRENT_DATE THEN
    UPDATE subscriptions SET status = 'active', updated_at = NOW()
    WHERE company_id = p_company_id
      AND id = (
        SELECT s2.id FROM subscriptions s2
        WHERE s2.company_id = p_company_id
        ORDER BY s2.created_at DESC NULLS LAST, s2.id DESC
        LIMIT 1
      )
      AND status = 'expired';
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION saas_assert_company_active(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_assert_company_active(INTEGER) TO authenticated, service_role;
