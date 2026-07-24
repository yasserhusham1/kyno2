/**
 * auth-logout — نسخة Dashboard (مدمجة بالكامل، بدون imports خارجية)
 * الصق هذا الملف كاملاً في Supabase → Edge Functions → auth-logout
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

// ─── session helpers ────────────────────────────────────────────────────────

const COOKIE_NAME = 'basma_session';

function parseAllowedOrigins(): string[] {
  const raw = Deno.env.get('BASMA_ALLOWED_ORIGINS') ?? '';
  const fromEnv = raw.split(',').map((s) => s.trim()).filter(Boolean);
  const defaults = [
    'http://localhost:3000', 'http://localhost:5500',
    'http://127.0.0.1:5500', 'http://localhost:8080',
    'http://127.0.0.1:8080', 'https://usac1.netlify.app',
    'https://usac2.netlify.app', 'https://kyno-flax.vercel.app',
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
  } catch { return false; }
  return false;
}

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin');
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-api-version',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Max-Age': '86400',
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

function jsonResponse(req: Request, body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json', ...extraHeaders },
  });
}

async function sha256Hex(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, '0')).join('');
}

function clearCookieHeader(secure: boolean, crossSite = false): string {
  const parts = [`${COOKIE_NAME}=`, 'Path=/', 'HttpOnly', crossSite ? 'SameSite=None' : 'SameSite=Lax', 'Max-Age=0'];
  if (secure || crossSite) parts.push('Secure');
  return parts.join('; ');
}

function readCookie(req: Request, name: string): string | null {
  const raw = req.headers.get('cookie') || '';
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = raw.match(new RegExp('(?:^|;\\s*)' + escaped + '=([^;]*)'));
  if (!match) return null;
  try { return decodeURIComponent(match[1]); } catch { return match[1]; }
}

function isSecureDeployment(): boolean {
  return (Deno.env.get('SUPABASE_URL') ?? '').startsWith('https://');
}

function requestIsCrossSite(req: Request): boolean {
  const origin = req.headers.get('Origin');
  if (!origin || origin === 'null') return false;
  try {
    const base = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');
    if (!base) return false;
    return new URL(origin).origin !== new URL(base).origin;
  } catch { return false; }
}

function createServiceClient() {
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!url || !key) throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

// ─── handlers ───────────────────────────────────────────────────────────────

type LogoutBody = { saas_user_id?: number; refresh_token?: string };

async function gotrueGlobalLogout(refreshToken: string): Promise<void> {
  const base = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!base || !anon || !refreshToken) return;
  try {
    const res = await fetch(`${base}/auth/v1/logout?scope=global`, {
      method: 'POST',
      headers: { apikey: anon, Authorization: `Bearer ${anon}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refreshToken }),
    });
    if (!res.ok) console.warn('gotrue logout:', res.status, (await res.text()).slice(0, 200));
  } catch (e) { console.warn('gotrue logout failed:', e); }
}

async function adminLogoutBySaasUserId(saasUserId: number): Promise<void> {
  try {
    const supabase = createServiceClient();
    const { error: revokeErr } = await supabase.rpc('saas_revoke_auth_sessions_for_user', { p_user_id: saasUserId });
    if (revokeErr) {
      console.warn('saas_revoke_auth_sessions_for_user:', revokeErr.message);
      try { await supabase.rpc('saas_revoke_all_sessions_for_user', { p_user_id: saasUserId }); } catch (e) { console.warn(e); }
    }
    const { data: authEmail, error: emailErr } = await supabase.rpc('saas_user_auth_email', { p_user_id: saasUserId });
    if (emailErr || !authEmail) { console.warn('saas_user_auth_email:', emailErr?.message ?? 'no email'); return; }
    const email = String(authEmail).trim().toLowerCase();
    const { data: existing, error: getErr } = await supabase.auth.admin.getUserByEmail(email);
    if (getErr || !existing?.user?.id) { console.warn('GoTrue user not found for', email, getErr?.message); return; }
    const { error: logoutErr } = await supabase.auth.admin.signOut(existing.user.id, 'global');
    if (logoutErr) console.warn('admin signOut:', logoutErr.message);
  } catch (e) { console.warn('adminLogoutBySaasUserId:', e); }
}

async function revokeSessionCookie(req: Request): Promise<void> {
  const rawToken = readCookie(req, COOKIE_NAME);
  if (!rawToken) return;
  try {
    const supabase = createServiceClient();
    const tokenHash = await sha256Hex(rawToken);
    const { error } = await supabase.rpc('saas_revoke_session', { p_token_hash: tokenHash });
    if (error) console.warn('saas_revoke_session:', error.message);
  } catch (e) { console.warn('revokeSessionCookie:', e); }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  if (req.method !== 'POST' && req.method !== 'GET') return jsonResponse(req, { error: 'method_not_allowed' }, 405);

  let body: LogoutBody = {};
  if (req.method === 'POST') {
    try { body = (await req.json()) as LogoutBody; } catch { body = {}; }
  }

  await revokeSessionCookie(req);

  const saasUserId = typeof body.saas_user_id === 'number'
    ? body.saas_user_id : parseInt(String(body.saas_user_id ?? ''), 10);
  if (Number.isFinite(saasUserId) && saasUserId > 0) await adminLogoutBySaasUserId(saasUserId);
  if (body.refresh_token && String(body.refresh_token).length > 10) await gotrueGlobalLogout(String(body.refresh_token));

  return jsonResponse(req, { ok: true, revoked: true }, 200, {
    'Set-Cookie': clearCookieHeader(isSecureDeployment(), requestIsCrossSite(req)),
  });
});
