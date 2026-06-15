-- 069: Allow logout cloud sync (audit + notification log) even when subscription gate would block writes

CREATE OR REPLACE FUNCTION saas_record_client_audit(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  action TEXT;
  active_chk JSONB;
BEGIN
  cid := auth_company_id();
  IF (cid IS NULL OR cid <= 0) AND auth_is_super_admin() THEN
    cid := NULLIF((p_payload->>'company_id')::INTEGER, 0);
  END IF;

  action := COALESCE(NULLIF(trim(p_payload->>'action'), ''), 'client_event');

  IF cid IS NULL OR cid <= 0 THEN
    IF auth_is_super_admin() AND action IN ('logout', 'login') THEN
      RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'super_admin_no_company');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF NOT auth_is_super_admin() AND action NOT IN ('logout', 'login') THEN
    active_chk := saas_assert_company_active(cid);
    IF COALESCE((active_chk->>'ok')::BOOLEAN, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'error', COALESCE(active_chk->>'error', 'subscription_inactive'));
    END IF;
  END IF;

  BEGIN
    PERFORM saas_v3_write_audit(
      action,
      COALESCE(NULLIF(trim(p_payload->>'category'), ''), 'client'),
      COALESCE(p_payload->>'details', action),
      COALESCE(p_payload->>'target_name', ''),
      cid,
      p_payload->'old_value',
      p_payload->'new_value',
      p_payload->>'entity_type',
      p_payload->>'entity_id',
      p_payload->>'ip_address',
      p_payload->>'user_agent'
    );
  EXCEPTION WHEN OTHERS THEN
    IF action IN ('logout', 'login') THEN
      RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'audit_write_failed');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION saas_record_client_audit(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_record_client_audit(JSONB) TO authenticated;

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
  log_only BOOLEAN := TRUE;
  key_rec RECORD;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_settings');
  END IF;

  FOR key_rec IN SELECT key FROM jsonb_each(p_settings)
  LOOP
    IF key_rec.key NOT IN ('activity_log', 'employee_notifications') THEN
      log_only := FALSE;
      EXIT;
    END IF;
  END LOOP;

  IF NOT log_only THEN
    IF NOT COALESCE((saas_assert_company_active(cid)->>'ok')::BOOLEAN, false) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'subscription_inactive');
    END IF;
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

  IF NOT log_only THEN
    BEGIN
      PERFORM saas_v3_write_audit(
        'settings_updated', 'settings',
        'Updated ' || cnt::text || ' tenant settings (versioned)',
        'company:' || cid::text,
        cid,
        old_snapshot, new_snapshot,
        'app_settings', cid::TEXT, NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', cnt);
END;
$$;

REVOKE ALL ON FUNCTION saas_upsert_tenant_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_upsert_tenant_settings(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_record_client_audit(JSONB) IS
  'Client audit writer — logout/login always allowed; super admin without tenant returns ok skipped';
