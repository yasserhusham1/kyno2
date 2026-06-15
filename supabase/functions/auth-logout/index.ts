// Deploy: supabase functions deploy auth-logout
/// <reference path="../env.d.ts" />
import {
  COOKIE_NAME,
  corsHeaders,
  readCookie,
  sha256Hex,
  clearCookieHeader,
  jsonResponse,
  isSecureDeployment,
  requestIsCrossSite,
} from './_shared/session.ts';
import { createServiceClient } from './_shared/supabase.ts';

type LogoutBody = {
  saas_user_id?: number;
  refresh_token?: string;
};

async function gotrueGlobalLogout(refreshToken: string): Promise<void> {
  const base = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!base || !anon || !refreshToken) return;
  try {
    const res = await fetch(`${base}/auth/v1/logout?scope=global`, {
      method: 'POST',
      headers: {
        apikey: anon,
        Authorization: `Bearer ${anon}`,
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

async function adminLogoutBySaasUserId(saasUserId: number): Promise<void> {
  try {
    const supabase = createServiceClient();
    const { error: revokeErr } = await supabase.rpc('saas_revoke_auth_sessions_for_user', {
      p_user_id: saasUserId,
    });
    if (revokeErr) {
      console.warn('saas_revoke_auth_sessions_for_user:', revokeErr.message);
      try {
        await supabase.rpc('saas_revoke_all_sessions_for_user', { p_user_id: saasUserId });
      } catch (e) {
        console.warn('saas_revoke_all_sessions_for_user:', e);
      }
    }

    const { data: authEmail, error: emailErr } = await supabase.rpc('saas_user_auth_email', {
      p_user_id: saasUserId,
    });
    if (emailErr || !authEmail) {
      console.warn('saas_user_auth_email:', emailErr?.message ?? 'no email');
      return;
    }

    const email = String(authEmail).trim().toLowerCase();
    const { data: existing, error: getErr } = await supabase.auth.admin.getUserByEmail(email);
    if (getErr || !existing?.user?.id) {
      console.warn('GoTrue user not found for', email, getErr?.message);
      return;
    }
    const { error: logoutErr } = await supabase.auth.admin.signOut(existing.user.id, 'global');
    if (logoutErr) console.warn('admin signOut:', logoutErr.message);
  } catch (e) {
    console.warn('adminLogoutBySaasUserId:', e);
  }
}

async function revokeSessionCookie(req: Request): Promise<void> {
  const rawToken = readCookie(req, COOKIE_NAME);
  if (!rawToken) return;
  try {
    const supabase = createServiceClient();
    const tokenHash = await sha256Hex(rawToken);
    const { error } = await supabase.rpc('saas_revoke_session', { p_token_hash: tokenHash });
    if (error) console.warn('saas_revoke_session:', error.message);
  } catch (e) {
    console.warn('revokeSessionCookie:', e);
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }

  if (req.method !== 'POST' && req.method !== 'GET') {
    return jsonResponse(req, { error: 'method_not_allowed' }, 405);
  }

  let body: LogoutBody = {};
  if (req.method === 'POST') {
    try {
      body = (await req.json()) as LogoutBody;
    } catch {
      body = {};
    }
  }

  await revokeSessionCookie(req);

  const saasUserId = typeof body.saas_user_id === 'number'
    ? body.saas_user_id
    : parseInt(String(body.saas_user_id ?? ''), 10);
  if (Number.isFinite(saasUserId) && saasUserId > 0) {
    await adminLogoutBySaasUserId(saasUserId);
  }

  if (body.refresh_token && String(body.refresh_token).length > 10) {
    await gotrueGlobalLogout(String(body.refresh_token));
  }

  const secure = isSecureDeployment();
  const crossSite = requestIsCrossSite(req);
  return jsonResponse(req, { ok: true, revoked: true }, 200, {
    'Set-Cookie': clearCookieHeader(secure, crossSite),
  });
});
