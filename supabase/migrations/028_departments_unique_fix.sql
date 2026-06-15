-- ============================================================
-- KYNO 028 — Fix departments composite unique (post-027 partial run)
-- Run this if 027 failed at: DROP CONSTRAINT departments_name_key
-- Safe to re-run (idempotent)
-- ============================================================

-- Step 1: remove legacy FK (depends on global UNIQUE on departments.name)
ALTER TABLE employees DROP CONSTRAINT IF EXISTS employees_dept_fkey;

-- Step 2: remove global unique — allows same dept name per company
ALTER TABLE departments DROP CONSTRAINT IF EXISTS departments_name_key;

-- Step 3: multi-tenant unique per company
CREATE UNIQUE INDEX IF NOT EXISTS ux_departments_company_name
  ON departments (company_id, lower(trim(name)));

COMMENT ON INDEX ux_departments_company_name IS
  'Multi-tenant dept names — replaces departments_name_key + employees_dept_fkey';

-- Step 4: salary unique (if 027 stopped before this)
CREATE UNIQUE INDEX IF NOT EXISTS ux_salary_employee_month
  ON salary_records (employee_id, month_iso);

-- Step 5: optional helpers (if 027 stopped before end)
CREATE OR REPLACE FUNCTION basma_today_iso_baghdad()
RETURNS DATE
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT basma_date_iso_baghdad();
$$;

REVOKE ALL ON FUNCTION basma_today_iso_baghdad() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION basma_today_iso_baghdad() TO anon, authenticated;

REVOKE ALL ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_link_device_by_token(TEXT, TEXT, TEXT, JSONB, INTEGER, SMALLINT) TO anon, authenticated;
