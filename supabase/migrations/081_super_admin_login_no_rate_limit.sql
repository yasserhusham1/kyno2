-- KYNO 081 — Super admin exempt from login rate limit (username + IP window)

CREATE OR REPLACE FUNCTION saas_check_login_rate_limit(
  p_username TEXT,
  p_ip TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uname TEXT := lower(trim(COALESCE(p_username, '')));
  ip TEXT := NULLIF(trim(COALESCE(p_ip, '')), '');
  window_start TIMESTAMPTZ := NOW() - INTERVAL '15 minutes';
  fail_user INTEGER := 0;
  fail_ip INTEGER := 0;
  max_fail INTEGER := 5;
BEGIN
  IF uname = '' THEN
    RETURN jsonb_build_object('allowed', true);
  END IF;

  -- Super admin: no brute-force lockout (ops / recovery access)
  IF EXISTS (
    SELECT 1 FROM saas_users su
    WHERE lower(su.username) = uname
      AND su.role = 'super_admin'
      AND su.is_active IS TRUE
  ) THEN
    RETURN jsonb_build_object('allowed', true, 'exempt', 'super_admin');
  END IF;

  SELECT COUNT(*) INTO fail_user
  FROM login_attempts
  WHERE lower(username) = uname
    AND success = false
    AND created_at >= window_start;

  IF fail_user >= max_fail THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'error', 'rate_limited',
      'retry_after_sec', 900,
      'reason', 'username'
    );
  END IF;

  IF ip IS NOT NULL THEN
    SELECT COUNT(*) INTO fail_ip
    FROM login_attempts
    WHERE ip_address = ip
      AND success = false
      AND created_at >= window_start;

    IF fail_ip >= max_fail THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'error', 'rate_limited',
        'retry_after_sec', 900,
        'reason', 'ip'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

-- Clear existing lockouts for active super admins (immediate relief)
DELETE FROM login_attempts
WHERE lower(username) IN (
  SELECT lower(username) FROM saas_users
  WHERE role = 'super_admin' AND is_active IS TRUE
);

REVOKE ALL ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION saas_check_login_rate_limit(TEXT, TEXT) IS
  'Login brute-force window. Super admin usernames are always allowed.';
