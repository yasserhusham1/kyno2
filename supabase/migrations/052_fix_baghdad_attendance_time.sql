-- ============================================================
-- KYNO 052 — Fix Baghdad timezone for attendance punch times
-- Supabase runs in UTC; old timezone() cast caused wrong wall clock
-- ============================================================

CREATE OR REPLACE FUNCTION basma_server_now_baghdad()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
  SELECT now();
$$;

CREATE OR REPLACE FUNCTION basma_date_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
  SELECT (now() AT TIME ZONE 'Asia/Baghdad')::date;
$$;

CREATE OR REPLACE FUNCTION basma_format_time_ampm(ts TIMESTAMPTZ)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(ts AT TIME ZONE 'Asia/Baghdad', 'HH12:MI AM');
$$;
