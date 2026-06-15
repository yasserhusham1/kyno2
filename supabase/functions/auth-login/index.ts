/**
 * auth-login — بدون import (للصق في لوحة Supabase)
 * التوكنات من GoTrue (توقيع رسمي) — لا توقيع JWT يدوي
 * Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY (مضاف تلقائياً غالباً)
 */

const COOKIE_NAME = 'basma_session';
const SESSION_DAYS = 7;

function parseAllowedOrigins(): string[] {
  const raw = Deno.env.get('BASMA_ALLOWED_ORIGINS') ?? '';
  const fromEnv = raw.split(',').map((s) => s.trim()).filter(Boolean);
  const defaults = [
    'http://localhost:3000',
    'http://localhost:5500',
    'http://127.0.0.1:5500',
    'http://localhost:8080',
    'http://127.0.0.1:8080',
    'https://usac1.netlify.app',
    'https://usac2.netlify.app',
    'https://kyno-flax.vercel.app',
  ];
  return [...new Set([...fromEnv, ...defaults])];
}

function isOriginAllowed(origin: string): boolean {
  if (!origin || origin === 'null') return false;
  if (parseAllowedOrigins().includes(origin)) return true;
  try {
    const host = new URL(origin).hostname;
    if (host === 'localhost' || host === '127.0.0.1') return true;
    if (host.endsWith('.netlify.app')) return true;
    if (host.endsWith('.vercel.app')) return true;
  } catch {
    return false;
  }
  return false;
}

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin');
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-api-version',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  };
  if (origin && origin !== 'null' && isOriginAllowed(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Credentials'] = 'true';
    headers['Vary'] = 'Origin';
  } else if (!origin || origin === 'null') {
    headers['Access-Control-Allow-Origin'] = '*';
  }
  return headers;
}

function requestIsCrossSite(req: Request): boolean {
  const origin = req.headers.get('Origin');
  if (!origin || origin === 'null') return false;
  try {
    const base = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');
    if (!base) return false;
    return new URL(origin).origin !== new URL(base).origin;
  } catch {
    return false;
  }
}

function jsonResponse(
  req: Request,
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json', ...extraHeaders },
  });
}

function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256Hex(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, '0')).join('');
}

function cookieHeader(token: string, maxAgeSec: number, secure: boolean, crossSite = false): string {
  const encoded = encodeURIComponent(token);
  const parts = [
    `${COOKIE_NAME}=${encoded}`,
    'Path=/',
    'HttpOnly',
    crossSite ? 'SameSite=None' : 'SameSite=Lax',
    `Max-Age=${maxAgeSec}`,
  ];
  if (secure || crossSite) parts.push('Secure');
  return parts.join('; ');
}

function isSecureDeployment(): boolean {
  return (Deno.env.get('SUPABASE_URL') ?? '').startsWith('https://');
}

function clearCookieHeader(secure: boolean, crossSite = false): string {
  const parts = [
    `${COOKIE_NAME}=`,
    'Path=/',
    'HttpOnly',
    crossSite ? 'SameSite=None' : 'SameSite=Lax',
    'Max-Age=0',
  ];
  if (secure || crossSite) parts.push('Secure');
  return parts.join('; ');
}

function readCookie(req: Request, name: string): string | null {
  const raw = req.headers.get('cookie') || '';
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = raw.match(new RegExp('(?:^|;\\s*)' + escaped + '=([^;]*)'));
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return match[1];
  }
}

// ========== HTTP helpers ==========
function requireEnv(name: string): string {
  const v = (Deno.env.get(name) ?? '').trim();
  if (!v) throw new Error('missing_env:' + name);
  return v;
}

function serviceHeaders(): Record<string, string> {
  const key = requireEnv('SUPABASE_SERVICE_ROLE_KEY');
  return {
    apikey: key,
    Authorization: 'Bearer ' + key,
    'Content-Type': 'application/json',
  };
}

async function rpc<T>(name: string, params: Record<string, unknown>, useAnon = false): Promise<T> {
  const base = requireEnv('SUPABASE_URL').replace(/\/$/, '');
  const key = useAnon ? requireEnv('SUPABASE_ANON_KEY') : requireEnv('SUPABASE_SERVICE_ROLE_KEY');
  const res = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: 'Bearer ' + key,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(params),
  });
  const text = await res.text();
  let data: unknown = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  if (!res.ok) {
    const msg = typeof data === 'object' && data && 'message' in data
      ? String((data as { message: string }).message)
      : text || res.statusText;
    throw new Error(`${name}:${msg}`);
  }
  return data as T;
}

async function authAdminFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const base = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');
  const headers = { ...serviceHeaders(), ...(init.headers as Record<string, string> || {}) };
  return fetch(`${base}/auth/v1/admin${path}`, { ...init, headers });
}

// ========== Types & Parsers ==========
interface SaasUserProfile {
  id: number;
  username: string;
  display_name: string;
  email: string;
  role: string;
  permissions: Record<string, unknown>;
  company_id: number | null;
  company_name: string | null;
  company_code: string | null;
  company_status: string | null;
  max_employees: number;
  force_password_reset?: boolean;
}

function parseSaasUser(data: unknown): SaasUserProfile | null {
  if (data == null || typeof data !== 'object') return null;
  const o = data as Record<string, unknown>;
  const id = typeof o.id === 'number' ? o.id : parseInt(String(o.id ?? ''), 10);
  if (!Number.isFinite(id) || id < 1) return null;
  if (!o.username || typeof o.username !== 'string') return null;
  return {
    id,
    username: o.username,
    display_name: o.display_name != null ? String(o.display_name) : '',
    email: o.email != null ? String(o.email) : '',
    role: o.role != null ? String(o.role) : '',
    permissions: o.permissions && typeof o.permissions === 'object' && !Array.isArray(o.permissions) ? (o.permissions as Record<string, unknown>) : {},
    company_id: o.company_id == null ? null : typeof o.company_id === 'number' ? o.company_id : parseInt(String(o.company_id), 10) || null,
    company_name: o.company_name != null ? String(o.company_name) : null,
    company_code: o.company_code != null ? String(o.company_code) : null,
    company_status: o.company_status != null ? String(o.company_status) : null,
    max_employees: parseInt(String(o.max_employees ?? 0), 10) || 0,
    force_password_reset: o.force_password_reset === true,
  };
}

function internalAuthEmail(user: SaasUserProfile): string {
  if (user.email && user.email.includes('@')) return user.email.trim().toLowerCase();
  const safeUser = String(user.username || 'user').replace(/[^a-zA-Z0-9._-]/g, '_');
  return `saas_${user.id}_${safeUser}@kyno.internal`;
}

function buildAppMetadata(user: SaasUserProfile): Record<string, unknown> {
  const meta: Record<string, unknown> = { role: user.role, saas_user_id: user.id };
  if (user.company_id != null) meta.company_id = user.company_id;
  return meta;
}

async function getAuthUserIdByEmail(email: string): Promise<string | null> {
  const lower = email.toLowerCase();
  try {
    const byEmail = await authAdminFetch(`/users?email=${encodeURIComponent(email)}`, { method: 'GET' });
    const j1 = await byEmail.json().catch(() => null);
    if (byEmail.ok && j1 && typeof j1 === 'object') {
      if ('id' in j1) return String((j1 as { id: string }).id);
      if ('users' in j1) {
        const users = (j1 as { users: Array<{ id: string; email?: string }> }).users;
        const hit = users?.find((u) => (u.email || '').toLowerCase() === lower);
        if (hit?.id) return hit.id;
      }
    }
  } catch (e) {
    console.warn('getAuthUserIdByEmail:', e);
  }
  return null;
}

async function ensureAuthUser(user: SaasUserProfile): Promise<string> {
  const email = internalAuthEmail(user);
  const appMeta = buildAppMetadata(user);
  let authUserId = await getAuthUserIdByEmail(email);
  if (authUserId) {
    await authAdminFetch(`/users/${authUserId}`, { method: 'PUT', body: JSON.stringify({ app_metadata: appMeta }) });
    return authUserId;
  }
  const createRes = await authAdminFetch('/users', {
    method: 'POST',
    body: JSON.stringify({
      email,
      email_confirm: true,
      app_metadata: appMeta,
      user_metadata: { username: user.username, display_name: user.display_name },
      password: crypto.randomUUID() + 'Aa1!',
    }),
  });
  const created = await createRes.json().catch(() => null);
  if (!createRes.ok) {
    console.error('admin create user:', createRes.status, created);
  }
  if (createRes.ok && created && typeof created === 'object' && 'id' in created) {
    return String((created as { id: string }).id);
  }
  authUserId = await getAuthUserIdByEmail(email);
  if (authUserId) {
    await authAdminFetch(`/users/${authUserId}`, { method: 'PUT', body: JSON.stringify({ app_metadata: appMeta }) });
    return authUserId;
  }
  throw new Error('auth_user_sync_failed');
}

/** توكنات موقّعة من GoTrue (متوافقة مع setSession في المتصفح) */
async function issueTokensForSaasUser(user: SaasUserProfile) {
  const email = internalAuthEmail(user);
  const appMeta = buildAppMetadata(user);
  const authUserId = await ensureAuthUser(user);

  const oneTimePassword = crypto.randomUUID() + 'Aa1!' + crypto.randomUUID().slice(0, 8);
  const pwdRes = await authAdminFetch(`/users/${authUserId}`, {
    method: 'PUT',
    body: JSON.stringify({ app_metadata: appMeta, password: oneTimePassword }),
  });
  if (!pwdRes.ok) {
    const errText = await pwdRes.text();
    console.error('auth password update:', pwdRes.status, errText);
    throw new Error('password_update_failed');
  }

  const base = requireEnv('SUPABASE_URL').replace(/\/$/, '');
  const anon = requireEnv('SUPABASE_ANON_KEY');

  const form = new URLSearchParams();
  form.set('grant_type', 'password');
  form.set('email', email);
  form.set('password', oneTimePassword);

  let tokenRes = await fetch(`${base}/auth/v1/token`, {
    method: 'POST',
    headers: {
      apikey: anon,
      Authorization: 'Bearer ' + anon,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: form.toString(),
  });

  let tokenJson = await tokenRes.json().catch(() => null) as Record<string, unknown> | null;

  if (!tokenRes.ok || !tokenJson?.access_token) {
    tokenRes = await fetch(`${base}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: {
        apikey: anon,
        Authorization: 'Bearer ' + anon,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ email, password: oneTimePassword }),
    });
    tokenJson = await tokenRes.json().catch(() => null) as Record<string, unknown> | null;
  }

  if (!tokenRes.ok || !tokenJson || typeof tokenJson.access_token !== 'string') {
    const errMsg = tokenJson && typeof tokenJson === 'object' && 'error_description' in tokenJson
      ? String(tokenJson.error_description)
      : tokenJson && typeof tokenJson === 'object' && 'msg' in tokenJson
        ? String(tokenJson.msg)
        : 'unknown';
    console.error('gotrue token:', tokenRes.status, tokenJson);
    throw new Error('gotrue_token_failed:' + errMsg);
  }

  return {
    access_token: tokenJson.access_token as string,
    refresh_token: (typeof tokenJson.refresh_token === 'string' ? tokenJson.refresh_token : tokenJson.access_token) as string,
    expires_in: typeof tokenJson.expires_in === 'number' ? tokenJson.expires_in : 3600,
  };
}

async function gotrueGlobalLogout(refreshToken: string): Promise<void> {
  const base = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!base || !anon || !refreshToken) return;
  try {
    const res = await fetch(`${base}/auth/v1/logout?scope=global`, {
      method: 'POST',
      headers: {
        apikey: anon,
        Authorization: 'Bearer ' + anon,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
    });
    if (!res.ok) {
      const txt = await res.text();
      console.warn('gotrue logout:', res.status, txt.slice(0, 200));
    }
  } catch (e) {
    console.warn('gotrue logout failed:', e);
  }
}

async function handleSessionRestore(req: Request): Promise<Response> {
  try {
    const rawToken = readCookie(req, COOKIE_NAME);
    if (!rawToken) {
      return jsonResponse(req, { user: null, ok: true });
    }
    const tokenHash = await sha256Hex(rawToken);
    let rawUser: unknown;
    try {
      rawUser = await rpc('saas_verify_session', { p_token_hash: tokenHash });
    } catch (e) {
      console.error('saas_verify_session:', e);
      return jsonResponse(req, { user: null });
    }
    const user = parseSaasUser(rawUser);
    if (!user) return jsonResponse(req, { user: null });
    let tokens;
    try {
      tokens = await issueTokensForSaasUser(user);
    } catch (jwtErr) {
      console.error('issueTokensForSaasUser:', jwtErr);
      return jsonResponse(req, { user: null });
    }
    return jsonResponse(req, {
      user,
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      expires_in: tokens.expires_in,
    });
  } catch (e) {
    console.error('session-restore:', e);
    return jsonResponse(req, { user: null });
  }
}

async function handleLogout(
  req: Request,
  body: { saas_user_id?: number; refresh_token?: string },
): Promise<Response> {
  const rawToken = readCookie(req, COOKIE_NAME);
  if (rawToken) {
    try {
      const tokenHash = await sha256Hex(rawToken);
      await rpc('saas_revoke_session', { p_token_hash: tokenHash });
    } catch (e) {
      console.warn('saas_revoke_session:', e);
    }
  }
  const saasUserId = typeof body.saas_user_id === 'number'
    ? body.saas_user_id
    : parseInt(String(body.saas_user_id ?? ''), 10);
  if (Number.isFinite(saasUserId) && saasUserId > 0) {
    try {
      await rpc('saas_revoke_auth_sessions_for_user', { p_user_id: saasUserId });
    } catch (e) {
      try {
        await rpc('saas_revoke_all_sessions_for_user', { p_user_id: saasUserId });
      } catch (_) { /* ignore */ }
    }
  }
  if (body.refresh_token && String(body.refresh_token).length > 10) {
    await gotrueGlobalLogout(String(body.refresh_token));
  }
  const secure = isSecureDeployment();
  const crossSite = requestIsCrossSite(req);
  return jsonResponse(req, { ok: true, revoked: true }, 200, {
    'Set-Cookie': clearCookieHeader(secure, crossSite),
  });
}

// ========== Handler ==========
console.log('auth-login: module ready', {
  has_url: !!(Deno.env.get('SUPABASE_URL') || '').trim(),
  has_anon: !!(Deno.env.get('SUPABASE_ANON_KEY') || '').trim(),
  has_service: !!(Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '').trim(),
});

Deno.serve(async (req) => {
  console.log('auth-login:', req.method, req.headers.get('Origin') || 'no-origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  if (req.method === 'GET') {
    return handleSessionRestore(req);
  }
  if (req.method !== 'POST') return jsonResponse(req, { error: 'method_not_allowed' }, 405);

  try {
    let body: {
      username?: string;
      password?: string;
      action?: string;
      saas_user_id?: number;
      refresh_token?: string;
    };
    try { body = await req.json(); } catch { return jsonResponse(req, { error: 'invalid_json' }, 400); }
    if (body.action === 'logout') {
      return handleLogout(req, body);
    }
    const username = String(body.username ?? '').trim().toLowerCase();
    const password = String(body.password ?? '');
    if (!username || !password) return jsonResponse(req, { error: 'missing_credentials' }, 400);

    const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || '';

    let rawUser: unknown;
    try {
      // saas_verify_login is granted to anon — service_role may lack EXECUTE after REVOKE PUBLIC
      rawUser = await rpc<unknown>('saas_verify_login', {
        p_username: username,
        p_password: password,
        p_ip: ip,
      }, true);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('saas_verify_login rpc failed:', msg);
      if (/permission denied|42501/i.test(msg)) {
        return jsonResponse(req, { error: 'rpc_permission_denied', detail: msg.slice(0, 200) }, 500);
      }
      return jsonResponse(req, { error: 'auth_db_error', detail: msg.slice(0, 200) }, 500);
    }

    if (rawUser && typeof rawUser === 'object' && (rawUser as Record<string, unknown>).error === 'rate_limited') {
      const retry = (rawUser as Record<string, unknown>).retry_after_sec;
      return jsonResponse(req, {
        error: 'rate_limited',
        retry_after_sec: typeof retry === 'number' ? retry : 900,
      }, 429);
    }

    if (rawUser && typeof rawUser === 'object' && (rawUser as Record<string, unknown>).error === 'password_reset_required') {
      const o = rawUser as Record<string, unknown>;
      return jsonResponse(req, {
        error: 'password_reset_required',
        username: typeof o.username === 'string' ? o.username : username,
      }, 403);
    }

    const user = parseSaasUser(rawUser);
    if (!user) return jsonResponse(req, { error: 'invalid_credentials' }, 401);

    const rawToken = randomToken();
    const tokenHash = await sha256Hex(rawToken);
    const expiresAt = new Date(Date.now() + SESSION_DAYS * 24 * 60 * 60 * 1000).toISOString();
    const ua = req.headers.get('user-agent') || '';

    try {
      await rpc('saas_create_session', {
        p_user_id: user.id,
        p_token_hash: tokenHash,
        p_expires_at: expiresAt,
        p_user_agent: ua,
        p_ip_address: ip,
      });
    } catch (sessErr) {
      console.warn('saas_create_session skipped (JWT login continues):', sessErr);
    }

    let tokens;
    try {
      tokens = await issueTokensForSaasUser(user);
    } catch (jwtErr) {
      const msg = jwtErr instanceof Error ? jwtErr.message : String(jwtErr);
      console.error('issueTokensForSaasUser:', msg);
      const code = msg.includes('missing_env:')
        ? 'missing_env'
        : msg.startsWith('gotrue_token_failed')
          ? 'gotrue_token_failed'
          : msg.includes('password_update_failed')
            ? 'password_update_failed'
            : msg.includes('auth_user_sync_failed')
              ? 'auth_user_sync_failed'
              : 'token_issue_failed';
      return jsonResponse(req, { error: code, detail: msg.slice(0, 200) }, 500);
    }
    const secure = isSecureDeployment();
    const crossSite = requestIsCrossSite(req);

    return jsonResponse(req, { user, session: true, access_token: tokens.access_token, refresh_token: tokens.refresh_token, expires_in: tokens.expires_in }, 200, { 'Set-Cookie': cookieHeader(rawToken, SESSION_DAYS * 86400, secure, crossSite) });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('auth-login unhandled:', msg);
    if (msg.startsWith('missing_env:')) {
      return jsonResponse(req, { error: 'missing_env', detail: msg }, 500);
    }
    return jsonResponse(req, { error: 'internal_error', detail: msg.slice(0, 200) }, 500);
  }
});