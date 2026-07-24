/**
 * auth-session — نسخة Dashboard (مدمجة بالكامل، بدون imports خارجية)
 * الصق هذا الملف كاملاً في Supabase → Edge Functions → auth-session
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

// ─── session helpers ─────────────────────────────────────────────────────────

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

function readCookie(req: Request, name: string): string | null {
  const raw = req.headers.get('cookie') || '';
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = raw.match(new RegExp('(?:^|;\\s*)' + escaped + '=([^;]*)'));
  if (!match) return null;
  try { return decodeURIComponent(match[1]); } catch { return match[1]; }
}

// ─── supabase client ─────────────────────────────────────────────────────────

function createServiceClient() {
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!url || !key) throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

function createAnonClient() {
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!url || !anon) throw new Error('Missing SUPABASE_URL or SUPABASE_ANON_KEY');
  return createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
}

// ─── types ───────────────────────────────────────────────────────────────────

interface SaasUserProfile {
  id: number; username: string; display_name: string; email: string; role: string;
  permissions: Record<string, unknown>; company_id: number | null;
  company_name: string | null; company_code: string | null;
  company_status: string | null; max_employees: number;
}

function parseSaasUser(data: unknown): SaasUserProfile | null {
  if (data == null || typeof data !== 'object') return null;
  const o = data as Record<string, unknown>;
  const id = typeof o.id === 'number' ? o.id : parseInt(String(o.id ?? ''), 10);
  if (!Number.isFinite(id) || id < 1) return null;
  if (!o.username || typeof o.username !== 'string') return null;
  return {
    id, username: o.username,
    display_name: o.display_name != null ? String(o.display_name) : '',
    email: o.email != null ? String(o.email) : '',
    role: o.role != null ? String(o.role) : '',
    permissions: o.permissions && typeof o.permissions === 'object' && !Array.isArray(o.permissions)
      ? (o.permissions as Record<string, unknown>) : {},
    company_id: o.company_id == null ? null : typeof o.company_id === 'number'
      ? o.company_id : parseInt(String(o.company_id), 10) || null,
    company_name: o.company_name != null ? String(o.company_name) : null,
    company_code: o.company_code != null ? String(o.company_code) : null,
    company_status: o.company_status != null ? String(o.company_status) : null,
    max_employees: parseInt(String(o.max_employees ?? 0), 10) || 0,
  };
}

// ─── auth-jwt helpers ────────────────────────────────────────────────────────

function internalAuthEmail(user: SaasUserProfile): string {
  if (user.email && user.email.includes('@')) return user.email.trim().toLowerCase();
  const safeUser = String(user.username || 'user').replace(/[^a-zA-Z0-9._-]/g, '_');
  return `saas_${user.id}_${safeUser}@users.kyno.auth`;
}

function buildAppMetadata(user: SaasUserProfile): Record<string, unknown> {
  const meta: Record<string, unknown> = { role: user.role, saas_user_id: user.id };
  if (user.company_id != null) meta.company_id = user.company_id;
  return meta;
}

async function ensureAuthUser(admin: ReturnType<typeof createServiceClient>, user: SaasUserProfile): Promise<string> {
  const email = internalAuthEmail(user);
  const appMeta = buildAppMetadata(user);
  const { data: existing, error: getErr } = await admin.auth.admin.getUserByEmail(email);
  if (!getErr && existing?.user?.id) {
    await admin.auth.admin.updateUserById(existing.user.id, { app_metadata: appMeta });
    return existing.user.id;
  }
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email, email_confirm: true, app_metadata: appMeta,
    user_metadata: { username: user.username, display_name: user.display_name },
    password: crypto.randomUUID() + 'Aa1!',
  });
  if (!createErr && created?.user?.id) return created.user.id;
  const { data: retry } = await admin.auth.admin.getUserByEmail(email);
  if (retry?.user?.id) {
    await admin.auth.admin.updateUserById(retry.user.id, { app_metadata: appMeta });
    return retry.user.id;
  }
  throw createErr ?? new Error('auth_user_sync_failed');
}

async function issueTokensForSaasUser(
  admin: ReturnType<typeof createServiceClient>,
  user: SaasUserProfile,
): Promise<{ access_token: string; refresh_token: string; expires_in: number }> {
  const appMeta = buildAppMetadata(user);
  const authUserId = await ensureAuthUser(admin, user);
  const oneTimePassword = crypto.randomUUID() + 'Aa1!' + crypto.randomUUID().slice(0, 8);
  const { error: pwdErr } = await admin.auth.admin.updateUserById(authUserId, {
    app_metadata: appMeta, password: oneTimePassword, email_confirm: true,
  });
  if (pwdErr) throw pwdErr;
  const anonClient = createAnonClient();
  const { data, error } = await anonClient.auth.signInWithPassword({
    email: internalAuthEmail(user), password: oneTimePassword,
  });
  if (error || !data.session?.access_token) throw error ?? new Error('gotrue_sign_in_failed');
  return {
    access_token: data.session.access_token,
    refresh_token: data.session.refresh_token,
    expires_in: data.session.expires_in ?? 3600,
  };
}

// ─── main handler ────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  if (req.method !== 'GET' && req.method !== 'POST') return jsonResponse(req, { error: 'method_not_allowed' }, 405);

  try {
    const rawToken = readCookie(req, COOKIE_NAME);
    if (!rawToken) return jsonResponse(req, { user: null });

    const supabase = createServiceClient();
    const tokenHash = await sha256Hex(rawToken);
    const { data: rawUser, error } = await supabase.rpc('saas_verify_session', { p_token_hash: tokenHash });
    if (error) { console.error('saas_verify_session:', error.message); return jsonResponse(req, { user: null }); }

    const user = parseSaasUser(rawUser);
    if (!user) return jsonResponse(req, { user: null });

    let tokens;
    try { tokens = await issueTokensForSaasUser(supabase, user); }
    catch (jwtErr) { console.error('issueTokensForSaasUser:', jwtErr); return jsonResponse(req, { user: null }); }

    return jsonResponse(req, {
      user, access_token: tokens.access_token,
      refresh_token: tokens.refresh_token, expires_in: tokens.expires_in,
    });
  } catch (e) {
    console.error('auth-session:', e);
    return jsonResponse(req, { error: String(e) }, 500);
  }
});
