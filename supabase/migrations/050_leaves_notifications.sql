-- ============================================================
-- KYNO 050 — Leaves & Notifications System
-- إضافة جداول الإجازات وإشعارات الموظفين والمسؤول
-- ============================================================

-- ─── جدول الإجازات ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS leaves (
  id           BIGSERIAL PRIMARY KEY,
  leave_ref    TEXT UNIQUE DEFAULT NULL,
  employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id   INTEGER NOT NULL REFERENCES companies(id),
  leave_type   TEXT NOT NULL
               CHECK (leave_type IN ('paid_open','unpaid_open','paid_single','unpaid_single','absence_mult')),
  from_date    DATE NOT NULL,
  to_date      DATE DEFAULT NULL,
  multiplier   INTEGER DEFAULT 1 CHECK (multiplier >= 1),
  note         TEXT DEFAULT '',
  added_at     TIMESTAMPTZ DEFAULT NOW(),
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_leaves_company   ON leaves(company_id);
CREATE INDEX IF NOT EXISTS idx_leaves_employee  ON leaves(employee_id);
CREATE INDEX IF NOT EXISTS idx_leaves_from_date ON leaves(from_date);

-- ─── جدول إشعارات الموظفين ────────────────────────────────
CREATE TABLE IF NOT EXISTS employee_notifications (
  id           BIGSERIAL PRIMARY KEY,
  notif_ref    TEXT UNIQUE DEFAULT NULL,
  employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id   INTEGER NOT NULL REFERENCES companies(id),
  notif_type   TEXT DEFAULT 'info',
  title        TEXT NOT NULL,
  body         TEXT DEFAULT '',
  is_read      BOOLEAN DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_emp_notif_emp    ON employee_notifications(employee_id);
CREATE INDEX IF NOT EXISTS idx_emp_notif_co     ON employee_notifications(company_id);

-- ─── جدول إشعارات المسؤول ─────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_notifications (
  id           BIGSERIAL PRIMARY KEY,
  company_id   INTEGER NOT NULL REFERENCES companies(id),
  notif_type   TEXT DEFAULT 'info',
  title        TEXT NOT NULL,
  body         TEXT DEFAULT '',
  is_read      BOOLEAN DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_notif_co   ON admin_notifications(company_id);

-- ─── RLS ──────────────────────────────────────────────────
ALTER TABLE leaves                ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_notifications   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leaves_company_policy            ON leaves;
DROP POLICY IF EXISTS emp_notif_company_policy         ON employee_notifications;
DROP POLICY IF EXISTS admin_notif_company_policy       ON admin_notifications;

CREATE POLICY leaves_company_policy ON leaves
  USING (company_id = auth_company_id() OR auth_is_super_admin());

CREATE POLICY emp_notif_company_policy ON employee_notifications
  USING (company_id = auth_company_id() OR auth_is_super_admin());

CREATE POLICY admin_notif_company_policy ON admin_notifications
  USING (company_id = auth_company_id() OR auth_is_super_admin());

-- ─── RPC: upsert leave ────────────────────────────────────
CREATE OR REPLACE FUNCTION saas_upsert_leave(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid      INTEGER;
  emp_row  employees%ROWTYPE;
  emp_id   INTEGER;
  leave_id BIGINT;
  ltype    TEXT;
  fdate    DATE;
  tdate    DATE;
  mult     INTEGER;
  ref_val  TEXT;
  row_out  leaves%ROWTYPE;
BEGIN
  cid := auth_company_id();
  IF auth_is_super_admin() THEN
    cid := COALESCE(NULLIF((p_payload->>'company_id')::INTEGER,0), cid);
  END IF;
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  emp_id  := NULLIF((p_payload->>'emp_id')::INTEGER, 0);
  ltype   := COALESCE(NULLIF(trim(p_payload->>'leave_type'),''),'paid_single');
  fdate   := (p_payload->>'from_date')::DATE;
  tdate   := NULLIF(p_payload->>'to_date','')::DATE;
  mult    := GREATEST(1, COALESCE((p_payload->>'multiplier')::INTEGER,1));
  ref_val := NULLIF(trim(p_payload->>'leave_ref'),'');
  leave_id:= NULLIF((p_payload->>'id')::BIGINT, 0);

  IF emp_id IS NULL OR fdate IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','missing_fields');
  END IF;

  SELECT * INTO emp_row FROM employees WHERE id=emp_id AND company_id=cid LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','employee_not_found');
  END IF;

  IF leave_id IS NOT NULL THEN
    UPDATE leaves SET
      leave_type  = ltype,
      from_date   = fdate,
      to_date     = tdate,
      multiplier  = mult,
      note        = COALESCE(p_payload->>'note',''),
      updated_at  = NOW()
    WHERE id=leave_id AND company_id=cid
    RETURNING * INTO row_out;
  ELSE
    INSERT INTO leaves(leave_ref, employee_id, company_id, leave_type, from_date, to_date, multiplier, note)
    VALUES(ref_val, emp_id, cid, ltype, fdate, tdate, mult, COALESCE(p_payload->>'note',''))
    ON CONFLICT(leave_ref) DO UPDATE SET
      leave_type = EXCLUDED.leave_type,
      from_date  = EXCLUDED.from_date,
      to_date    = EXCLUDED.to_date,
      multiplier = EXCLUDED.multiplier,
      note       = EXCLUDED.note,
      updated_at = NOW()
    RETURNING * INTO row_out;
  END IF;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(row_out));
END;
$$;

-- ─── RPC: delete leave ────────────────────────────────────
CREATE OR REPLACE FUNCTION saas_delete_leave(p_leave_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;
  DELETE FROM leaves WHERE id=p_leave_id AND (company_id=cid OR auth_is_super_admin());
  RETURN jsonb_build_object('ok',true);
END;
$$;

-- ─── RPC: get leaves ──────────────────────────────────────
CREATE OR REPLACE FUNCTION saas_get_leaves(p_employee_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  rows JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  SELECT jsonb_agg(to_jsonb(l) ORDER BY l.from_date DESC) INTO rows
  FROM leaves l
  WHERE l.company_id = cid
    AND (p_employee_id IS NULL OR l.employee_id = p_employee_id);

  RETURN jsonb_build_object('ok',true,'data', COALESCE(rows,'[]'::jsonb));
END;
$$;

-- ─── RPC: upsert employee notification ───────────────────
CREATE OR REPLACE FUNCTION saas_add_employee_notification(
  p_employee_id INTEGER,
  p_title       TEXT,
  p_body        TEXT DEFAULT '',
  p_type        TEXT DEFAULT 'info',
  p_ref         TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  row_out employee_notifications%ROWTYPE;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  IF p_ref IS NOT NULL THEN
    INSERT INTO employee_notifications(notif_ref, employee_id, company_id, notif_type, title, body)
    VALUES(p_ref, p_employee_id, cid, p_type, p_title, COALESCE(p_body,''))
    ON CONFLICT(notif_ref) DO UPDATE SET
      title = EXCLUDED.title,
      body  = EXCLUDED.body
    RETURNING * INTO row_out;
  ELSE
    INSERT INTO employee_notifications(employee_id, company_id, notif_type, title, body)
    VALUES(p_employee_id, cid, p_type, p_title, COALESCE(p_body,''))
    RETURNING * INTO row_out;
  END IF;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(row_out));
END;
$$;

-- ─── RPC: get employee notifications ─────────────────────
CREATE OR REPLACE FUNCTION saas_get_employee_notifications(p_employee_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  cid  INTEGER;
  rows JSONB;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  SELECT jsonb_agg(to_jsonb(n) ORDER BY n.created_at DESC) INTO rows
  FROM employee_notifications n
  WHERE n.company_id = cid
    AND (p_employee_id IS NULL OR n.employee_id = p_employee_id)
  LIMIT 200;

  RETURN jsonb_build_object('ok',true,'data', COALESCE(rows,'[]'::jsonb));
END;
$$;

-- ─── RPC: mark employee notification read ────────────────
CREATE OR REPLACE FUNCTION saas_mark_emp_notification_read(p_notif_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
BEGIN
  cid := auth_company_id();
  UPDATE employee_notifications SET is_read=true
  WHERE id=p_notif_id AND company_id=cid;
  RETURN jsonb_build_object('ok',true);
END;
$$;

-- ─── RPC: add admin notification ─────────────────────────
CREATE OR REPLACE FUNCTION saas_add_admin_notification(
  p_title TEXT,
  p_body  TEXT DEFAULT '',
  p_type  TEXT DEFAULT 'info'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid INTEGER;
  row_out admin_notifications%ROWTYPE;
BEGIN
  cid := auth_company_id();
  IF cid IS NULL OR cid <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_company_context');
  END IF;

  INSERT INTO admin_notifications(company_id, notif_type, title, body)
  VALUES(cid, p_type, p_title, COALESCE(p_body,''))
  RETURNING * INTO row_out;

  RETURN jsonb_build_object('ok',true,'data',to_jsonb(row_out));
END;
$$;

-- ─── Grants ───────────────────────────────────────────────
REVOKE ALL ON FUNCTION saas_upsert_leave(JSONB)                                    FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_delete_leave(BIGINT)                                   FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_leaves(INTEGER)                                    FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_add_employee_notification(INTEGER,TEXT,TEXT,TEXT,TEXT)  FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_get_employee_notifications(INTEGER)                    FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_mark_emp_notification_read(BIGINT)                     FROM PUBLIC;
REVOKE ALL ON FUNCTION saas_add_admin_notification(TEXT,TEXT,TEXT)                 FROM PUBLIC;

GRANT EXECUTE ON FUNCTION saas_upsert_leave(JSONB)                                    TO authenticated;
GRANT EXECUTE ON FUNCTION saas_delete_leave(BIGINT)                                   TO authenticated;
GRANT EXECUTE ON FUNCTION saas_get_leaves(INTEGER)                                    TO authenticated;
GRANT EXECUTE ON FUNCTION saas_add_employee_notification(INTEGER,TEXT,TEXT,TEXT,TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION saas_get_employee_notifications(INTEGER)                    TO authenticated;
GRANT EXECUTE ON FUNCTION saas_mark_emp_notification_read(BIGINT)                     TO authenticated;
GRANT EXECUTE ON FUNCTION saas_add_admin_notification(TEXT,TEXT,TEXT)                 TO authenticated;
