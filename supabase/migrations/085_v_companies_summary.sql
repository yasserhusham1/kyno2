-- 085 — Super Admin companies summary view
DROP VIEW IF EXISTS public.v_companies_summary;

CREATE OR REPLACE VIEW public.v_companies_summary
WITH (security_invoker = true)
AS
SELECT
  c.id,
  c.company_name,
  c.company_code,
  c.status,
  c.max_employees,
  c.plan_tier,
  c.notes,
  c.created_at,
  c.updated_at,
  COALESCE(emp.cnt, 0)::INTEGER AS employee_count,
  COALESCE(sub.status, 'pending') AS subscription_status,
  sub.plan_name,
  sub.end_date AS subscription_end_date
FROM companies c
LEFT JOIN LATERAL (
  SELECT COUNT(*)::INTEGER AS cnt
  FROM employees e
  WHERE e.company_id = c.id
) emp ON TRUE
LEFT JOIN LATERAL (
  SELECT s.status, s.plan_name, s.end_date
  FROM subscriptions s
  WHERE s.company_id = c.id
  ORDER BY s.created_at DESC NULLS LAST
  LIMIT 1
) sub ON TRUE;

GRANT SELECT ON public.v_companies_summary TO authenticated;

NOTIFY pgrst, 'reload schema';
