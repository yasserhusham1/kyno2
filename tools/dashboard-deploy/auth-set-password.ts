/**
 * auth-set-password — نسخة Dashboard (مدمجة بالكامل، بدون imports خارجية)
 * الصق هذا الملف كاملاً في Supabase → Edge Functions → auth-set-password
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

// ─── main handler ────────────────────────────────────────────────────────────

function canChangePassword(
  actor: { id: number; role: string; company_id: number | null },
  targetId: number, targetCompanyId: number | null
): boolean {
  if (actor.role === 'super_admin') return true;
  if (actor.id === targetId) return true;
  if (actor.role === 'company_admin' && actor.company_id != null && actor.company_id === targetCompanyId) return true;
  return false;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  if (req.method !== 'POST') return jsonResponse(req, { error: 'method_not_allowed' }, 405);

  try {
    const rawToken = readCookie(req, COOKIE_NAME);
    if (!rawToken) return jsonResponse(req, { error: 'unauthorized' }, 401);

    let body: { user_id?: number | string; new_password?: string };
    try { body = await req.json(); }
    catch { return jsonResponse(req, { error: 'invalid_json' }, 400); }

    const targetId = parseInt(String(body.user_id ?? ''), 10);
    const newPassword = String(body.new_password ?? '');
    if (!targetId || newPassword.length < 6) return jsonResponse(req, { error: 'invalid_input' }, 400);

    const supabase = createServiceClient();
    const tokenHash = await sha256Hex(rawToken);
    const { data: rawActor, error: sessErr } = await supabase.rpc('saas_verify_session', { p_token_hash: tokenHash });
    if (sessErr) { console.error('saas_verify_session:', sessErr.message); return jsonResponse(req, { error: 'unauthorized' }, 401); }

    const actor = parseSaasUser(rawActor);
    if (!actor) return jsonResponse(req, { error: 'unauthorized' }, 401);

    const { data: targetRow, error: targetErr } = await supabase
      .from('saas_users').select('id, company_id').eq('id', targetId).maybeSingle();
    if (targetErr || !targetRow) return jsonResponse(req, { error: 'invalid_user' }, 400);

    const targetCompanyId = targetRow.company_id == null ? null : parseInt(String(targetRow.company_id), 10) || null;
    if (!canChangePassword(actor, targetId, targetCompanyId)) return jsonResponse(req, { error: 'forbidden' }, 403);

    const { data: hash, error: hashErr } = await supabase.rpc('saas_hash_password_bcrypt', { p_password: newPassword });
    if (hashErr || !hash || typeof hash !== 'string') {
      console.error('saas_hash_password_bcrypt:', hashErr?.message);
      return jsonResponse(req, { error: 'hash_failed' }, 500);
    }

    const { error: updateErr } = await supabase.from('saas_users')
      .update({ password_hash: hash, password_algo: 'bcrypt' }).eq('id', targetId);
    if (updateErr) { console.error('password update:', updateErr.message); return jsonResponse(req, { error: updateErr.message }, 500); }

    return jsonResponse(req, { ok: true });
  } catch (e) {
    console.error('auth-set-password:', e);
    return jsonResponse(req, { error: String(e) }, 500);
  }
});
