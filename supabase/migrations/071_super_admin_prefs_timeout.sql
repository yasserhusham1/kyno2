-- 071: Fix super admin prefs timeout — cap activity_log, fast merge, trim bloated rows

CREATE OR REPLACE FUNCTION saas_super_admin_trim_activity_log(p_log JSONB, p_max INTEGER DEFAULT 120)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  arr JSONB;
  max_n INTEGER := GREATEST(20, LEAST(COALESCE(p_max, 120), 200));
BEGIN
  IF p_log IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  arr := p_log;
  IF jsonb_typeof(arr) = 'string' THEN
    BEGIN
      arr := (p_log #>> '{}')::jsonb;
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  IF jsonb_typeof(arr) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_array_length(arr) <= max_n THEN
    RETURN arr;
  END IF;
  RETURN (
    SELECT COALESCE(jsonb_agg(x ORDER BY ord), '[]'::jsonb)
    FROM (
      SELECT x, ord
      FROM jsonb_array_elements(arr) WITH ORDINALITY AS t(x, ord)
      WHERE ord <= max_n
    ) s
  );
END;
$$;

CREATE OR REPLACE FUNCTION saas_super_admin_parse_activity_log(p_val JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  raw TEXT;
BEGIN
  IF p_val IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_val) = 'array' THEN
    RETURN saas_super_admin_trim_activity_log(p_val, 120);
  END IF;
  IF jsonb_typeof(p_val) = 'string' THEN
    raw := p_val #>> '{}';
    IF raw IS NULL OR trim(raw) = '' THEN
      RETURN '[]'::jsonb;
    END IF;
    BEGIN
      RETURN saas_super_admin_trim_activity_log(raw::jsonb, 120);
    EXCEPTION WHEN others THEN
      RETURN '[]'::jsonb;
    END;
  END IF;
  RETURN '[]'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION saas_upsert_super_admin_prefs(p_prefs JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  db_key TEXT;
  existing JSONB := '{}'::jsonb;
  merged JSONB;
  raw TEXT;
  existing_log JSONB := '[]'::jsonb;
  incoming_log JSONB := '[]'::jsonb;
  merged_log JSONB := '[]'::jsonb;
  keep_keys JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  IF p_prefs IS NULL OR jsonb_typeof(p_prefs) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_prefs');
  END IF;

  db_key := saas_super_admin_prefs_key(uid);

  SELECT s.value INTO raw FROM app_settings s WHERE s.key = db_key LIMIT 1;

  IF raw IS NOT NULL AND length(raw) > 800000 THEN
    BEGIN
      existing := raw::jsonb;
    EXCEPTION WHEN others THEN
      existing := '{}'::jsonb;
    END;
    keep_keys := jsonb_strip_nulls(jsonb_build_object(
      'theme', existing->'theme',
      'ui_theme', existing->'ui_theme'
    ));
    existing := COALESCE(keep_keys, '{}'::jsonb);
  ELSIF raw IS NOT NULL AND trim(raw) <> '' THEN
    BEGIN
      existing := raw::jsonb;
    EXCEPTION WHEN others THEN
      existing := '{}'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(existing) <> 'object' THEN
    existing := '{}'::jsonb;
  END IF;

  merged := existing || p_prefs;

  IF p_prefs ? 'activity_log' THEN
    existing_log := saas_super_admin_parse_activity_log(existing->'activity_log');
    incoming_log := saas_super_admin_parse_activity_log(p_prefs->'activity_log');
    IF jsonb_array_length(incoming_log) > 0 THEN
      merged_log := saas_super_admin_trim_activity_log(incoming_log, 120);
    ELSE
      merged_log := existing_log;
    END IF;
    merged := merged - 'activity_log' || jsonb_build_object('activity_log', merged_log);
  ELSIF existing ? 'activity_log' THEN
    merged := merged - 'activity_log' || jsonb_build_object(
      'activity_log', saas_super_admin_parse_activity_log(existing->'activity_log')
    );
  END IF;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES (db_key, merged::text, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', uid,
    'activity_count', jsonb_array_length(COALESCE(merged->'activity_log', '[]'::jsonb))
  );
EXCEPTION
  WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION saas_super_admin_trim_activity_log(JSONB, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_super_admin_parse_activity_log(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_upsert_super_admin_prefs(JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_upsert_super_admin_prefs(JSONB) TO authenticated;

COMMENT ON FUNCTION saas_upsert_super_admin_prefs(JSONB) IS
  'Super admin prefs — activity_log capped at 120 entries; auto-trims bloated legacy rows';

CREATE OR REPLACE FUNCTION saas_get_super_admin_prefs()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid INTEGER;
  raw TEXT;
  prefs JSONB;
BEGIN
  IF NOT auth_is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin_only');
  END IF;

  uid := saas_super_admin_user_id();
  IF uid IS NULL OR uid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_user');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = saas_super_admin_prefs_key(uid)
  LIMIT 1;

  prefs := COALESCE(NULLIF(trim(raw), '')::jsonb, '{}'::jsonb);
  IF jsonb_typeof(prefs) <> 'object' THEN
    prefs := '{}'::jsonb;
  END IF;

  IF prefs ? 'activity_log' THEN
    prefs := prefs || jsonb_build_object(
      'activity_log', saas_super_admin_parse_activity_log(prefs->'activity_log')
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'prefs', prefs, 'user_id', uid);
END;
$$;

REVOKE ALL ON FUNCTION saas_get_super_admin_prefs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_super_admin_prefs() TO authenticated;
