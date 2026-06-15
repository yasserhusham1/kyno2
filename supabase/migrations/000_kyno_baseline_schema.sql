-- ============================================================
-- KYNO 000 — Baseline schema (قاعدة فارغة جديدة)
-- شغّل هذا أولاً قبل 001..084
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ─── companies ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS companies (
  id              SERIAL PRIMARY KEY,
  company_name    TEXT NOT NULL DEFAULT '',
  company_code    TEXT NOT NULL UNIQUE,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('active', 'suspended', 'pending')),
  max_employees   INTEGER NOT NULL DEFAULT 50,
  plan_tier       TEXT DEFAULT 'starter',
  notes           TEXT DEFAULT '',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── saas_users ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS saas_users (
  id                    SERIAL PRIMARY KEY,
  username              TEXT NOT NULL UNIQUE,
  display_name          TEXT DEFAULT '',
  email                 TEXT,
  password_hash         TEXT,
  password_algo         TEXT DEFAULT 'legacy_b64',
  role                  TEXT NOT NULL DEFAULT 'company_user'
                        CHECK (role IN ('super_admin', 'company_admin', 'company_user')),
  permissions           JSONB NOT NULL DEFAULT '{}'::jsonb,
  company_id            INTEGER REFERENCES companies(id) ON DELETE SET NULL,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  force_password_reset  BOOLEAN NOT NULL DEFAULT FALSE,
  last_login            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_saas_users_company ON saas_users(company_id);
CREATE INDEX IF NOT EXISTS idx_saas_users_role ON saas_users(role);

-- ─── employees ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS employees (
  id                          SERIAL PRIMARY KEY,
  company_id                  INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name                        TEXT NOT NULL DEFAULT '',
  dept                        TEXT DEFAULT '',
  role                        TEXT DEFAULT '',
  phone                       TEXT DEFAULT '—',
  salary                      INTEGER NOT NULL DEFAULT 0,
  salary_type                 TEXT NOT NULL DEFAULT 'monthly',
  salary_half                 INTEGER NOT NULL DEFAULT 0,
  daily_rate                  INTEGER NOT NULL DEFAULT 0,
  days                        INTEGER NOT NULL DEFAULT 0,
  late_min                    INTEGER NOT NULL DEFAULT 0,
  check_in                    TIME DEFAULT '08:00',
  check_out                   TIME DEFAULT '17:00',
  open_hours                  BOOLEAN NOT NULL DEFAULT FALSE,
  remote_attend               BOOLEAN NOT NULL DEFAULT FALSE,
  include_overtime_in_salary  BOOLEAN NOT NULL DEFAULT FALSE,
  sal_status                  TEXT DEFAULT 'معلق',
  sal_bonus                   INTEGER NOT NULL DEFAULT 0,
  sal_deleted_period          TEXT DEFAULT '',
  avatar_url                  TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_employees_company ON employees(company_id);
CREATE INDEX IF NOT EXISTS idx_employees_created ON employees(created_at DESC);

-- ─── departments ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS departments (
  id          SERIAL PRIMARY KEY,
  company_id  INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_departments_company_name
  ON departments (company_id, lower(trim(name)));

-- ─── attendance ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS attendance (
  id           SERIAL PRIMARY KEY,
  employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id   INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  emp_name     TEXT DEFAULT '',
  dept         TEXT DEFAULT '',
  date_label   TEXT DEFAULT '',
  date_iso     DATE NOT NULL,
  check_in     TEXT DEFAULT '—',
  check_out    TEXT DEFAULT '—',
  hours        TEXT DEFAULT '—',
  late         TEXT DEFAULT '—',
  overtime     TEXT DEFAULT '—',
  status       TEXT DEFAULT 'طبيعي',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (employee_id, date_iso)
);

CREATE INDEX IF NOT EXISTS idx_attendance_emp_date ON attendance(employee_id, date_iso DESC);
CREATE INDEX IF NOT EXISTS idx_attendance_company ON attendance(company_id);
CREATE INDEX IF NOT EXISTS idx_attendance_status ON attendance(status);

-- ─── employee_devices ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS employee_devices (
  id               SERIAL PRIMARY KEY,
  employee_id      INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id       INTEGER REFERENCES companies(id) ON DELETE CASCADE,
  slot             SMALLINT NOT NULL,
  label            TEXT DEFAULT '',
  ip               TEXT DEFAULT '',
  fingerprint      TEXT DEFAULT '',
  pin              TEXT DEFAULT '',
  token            TEXT,
  token_created_at TIMESTAMPTZ,
  token_used_at    TIMESTAMPTZ,
  device_info      JSONB DEFAULT '{}'::jsonb,
  linked_at        TIMESTAMPTZ,
  last_login       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (employee_id, slot)
);

CREATE INDEX IF NOT EXISTS idx_employee_devices_emp ON employee_devices(employee_id);

-- ─── salary_records ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS salary_records (
  id               SERIAL PRIMARY KEY,
  employee_id      INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  company_id       INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  month_iso        TEXT NOT NULL,
  month_label      TEXT DEFAULT '',
  base_salary      INTEGER NOT NULL DEFAULT 0,
  attend_days      INTEGER NOT NULL DEFAULT 0,
  late_minutes     INTEGER NOT NULL DEFAULT 0,
  late_deduct      INTEGER NOT NULL DEFAULT 0,
  absent_days      INTEGER NOT NULL DEFAULT 0,
  overtime_amount  INTEGER NOT NULL DEFAULT 0,
  bonus            INTEGER NOT NULL DEFAULT 0,
  total_deduct     INTEGER NOT NULL DEFAULT 0,
  net_salary       INTEGER NOT NULL DEFAULT 0,
  status           TEXT DEFAULT 'معلق',
  issued_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (employee_id, month_iso)
);

CREATE INDEX IF NOT EXISTS idx_salary_emp_month ON salary_records(employee_id, month_iso);

-- ─── subscriptions ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  id               SERIAL PRIMARY KEY,
  company_id       INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  plan_name        TEXT DEFAULT 'PRO',
  start_date       DATE,
  end_date         DATE,
  status           TEXT NOT NULL DEFAULT 'pending',
  duration_months  INTEGER DEFAULT 1,
  amount           NUMERIC(12,2) DEFAULT 0,
  notes            TEXT DEFAULT '',
  activated_by     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_company ON subscriptions(company_id);

-- ─── app_settings ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS app_settings (
  id          SERIAL PRIMARY KEY,
  key         TEXT NOT NULL UNIQUE,
  value       TEXT DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── notifications (legacy admin feed) ─────────────────────
CREATE TABLE IF NOT EXISTS notifications (
  id          SERIAL PRIMARY KEY,
  company_id  INTEGER REFERENCES companies(id) ON DELETE CASCADE,
  title       TEXT DEFAULT '',
  body        TEXT DEFAULT '',
  notif_type  TEXT DEFAULT 'info',
  unread      BOOLEAN DEFAULT TRUE,
  meta        JSONB DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_company ON notifications(company_id);

COMMENT ON SCHEMA public IS 'KYNO baseline — run migrations 001..084 after this file';
