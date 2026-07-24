-- 119 — جلب finance_items عبر RPC (SECURITY DEFINER) لتجنب فشل القراءة من الواجهة

CREATE OR REPLACE FUNCTION saas_get_tenant_finance_items()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  raw TEXT;
  items JSONB := '[]'::jsonb;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_company_context');
  END IF;

  SELECT s.value INTO raw
  FROM app_settings s
  WHERE s.key = ('company:' || cid::text || ':finance_items')
  LIMIT 1;

  IF raw IS NOT NULL AND trim(raw) <> '' THEN
    BEGIN
      items := raw::jsonb;
    EXCEPTION WHEN others THEN
      items := '[]'::jsonb;
    END;
  END IF;

  IF jsonb_typeof(items) <> 'array' THEN
    items := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'company_id', cid,
    'count', jsonb_array_length(items),
    'items', items
  );
END;
$$;

REVOKE ALL ON FUNCTION saas_get_tenant_finance_items() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_get_tenant_finance_items() TO authenticated;
