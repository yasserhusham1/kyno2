-- 121 — استرجاع finance_items من employee_notifications إذا حُذفت بالخطأ

CREATE OR REPLACE FUNCTION saas_recover_finance_items_from_notifications(p_force BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  notif_raw TEXT;
  notif_arr JSONB := '[]'::jsonb;
  finance_raw TEXT;
  finance_existing JSONB := '[]'::jsonb;
  elem JSONB;
  out_map JSONB := '{}'::jsonb;
  item_id TEXT;
  ftype TEXT;
  faction TEXT;
  built JSONB;
  out_items JSONB := '[]'::jsonb;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT s.value INTO finance_raw
  FROM app_settings s
  WHERE s.key = ('company:' || cid::text || ':finance_items')
  LIMIT 1;

  IF finance_raw IS NOT NULL AND trim(finance_raw) <> '' AND finance_raw <> '[]' THEN
    BEGIN
      finance_existing := finance_raw::jsonb;
    EXCEPTION WHEN others THEN
      finance_existing := '[]'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(finance_existing) = 'array' AND jsonb_array_length(finance_existing) > 0 AND COALESCE(p_force, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', true,
      'recovered', false,
      'count', jsonb_array_length(finance_existing),
      'items', finance_existing
    );
  END IF;

  SELECT s.value INTO notif_raw
  FROM app_settings s
  WHERE s.key = ('company:' || cid::text || ':employee_notifications')
  LIMIT 1;

  IF notif_raw IS NULL OR trim(notif_raw) = '' THEN
    RETURN jsonb_build_object('ok', true, 'recovered', false, 'count', 0, 'items', '[]'::jsonb);
  END IF;

  BEGIN
    notif_arr := notif_raw::jsonb;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_notifications_json');
  END;

  IF jsonb_typeof(notif_arr) <> 'array' THEN
    RETURN jsonb_build_object('ok', true, 'recovered', false, 'count', 0, 'items', '[]'::jsonb);
  END IF;

  FOR elem IN
    SELECT value FROM jsonb_array_elements(notif_arr) AS t(value)
    ORDER BY COALESCE(value->>'ts', value->>'createdAt', value->>'created_at', '') ASC
  LOOP
    ftype := lower(trim(COALESCE(elem->>'financeType', elem->>'finance_type', elem->>'type', '')));
    IF ftype NOT IN ('deduction', 'bonus', 'loan', 'خصم', 'مكافأة', 'مكافآت', 'سلفة', 'سلف') THEN
      CONTINUE;
    END IF;

    IF ftype IN ('خصم') THEN ftype := 'deduction';
    ELSIF ftype IN ('مكافأة', 'مكافآت') THEN ftype := 'bonus';
    ELSIF ftype IN ('سلفة', 'سلف') THEN ftype := 'loan';
    END IF;

    faction := lower(trim(COALESCE(elem->>'action', 'add')));
    item_id := trim(COALESCE(elem->>'financeItemId', elem->>'finance_item_id', elem->>'id', ''));
    IF item_id = '' THEN
      CONTINUE;
    END IF;

    IF faction = 'delete' THEN
      out_map := out_map - item_id;
      CONTINUE;
    END IF;

    IF faction NOT IN ('add', 'edit', 'applied') THEN
      CONTINUE;
    END IF;

    built := jsonb_build_object(
      'id', item_id,
      'empId', COALESCE((elem->>'empId')::integer, (elem->>'employee_id')::integer, 0),
      'type', ftype,
      'amount', COALESCE(NULLIF(trim(elem->>'amount'), '')::numeric, 0),
      'originalAmount', COALESCE(NULLIF(trim(elem->>'amount'), '')::numeric, 0),
      'note', COALESCE(elem->>'note', ''),
      'status', 'نشط',
      'loanMode', 'direct',
      'installmentCount', 1,
      'paidInstallments', 0,
      'installmentAmount', 0,
      'createdAt', COALESCE(elem->>'ts', elem->>'createdAt', elem->>'created_at', NOW()::text),
      'updatedAt', COALESCE(elem->>'ts', elem->>'createdAt', elem->>'created_at', NOW()::text),
      'date', left(COALESCE(elem->>'ts', elem->>'createdAt', elem->>'created_at', NOW()::text), 10),
      'period', to_char(COALESCE((elem->>'ts')::timestamptz, (elem->>'createdAt')::timestamptz, NOW()), 'YYYY-MM'),
      '_recoveredFromNotifications', true
    );
    out_map := jsonb_set(out_map, ARRAY[item_id], built, true);
  END LOOP;

  SELECT COALESCE(jsonb_agg(e.value ORDER BY e.value->>'createdAt' DESC), '[]'::jsonb)
  INTO out_items
  FROM jsonb_each(out_map) AS e(key, value);

  IF jsonb_array_length(out_items) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'recovered', false, 'count', 0, 'items', '[]'::jsonb);
  END IF;

  INSERT INTO app_settings (key, value, updated_at)
  VALUES ('company:' || cid::text || ':finance_items', out_items::text, NOW())
  ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value,
    updated_at = NOW();

  RETURN jsonb_build_object(
    'ok', true,
    'recovered', true,
    'count', jsonb_array_length(out_items),
    'items', out_items
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_recover_finance_items_from_notifications(BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_recover_finance_items_from_notifications(BOOLEAN) TO authenticated;

NOTIFY pgrst, 'reload schema';
