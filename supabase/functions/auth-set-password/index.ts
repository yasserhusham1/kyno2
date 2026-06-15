// Deploy: supabase functions deploy auth-set-password
/// <reference path="../env.d.ts" />
import { COOKIE_NAME, corsHeaders, readCookie, sha256Hex, jsonResponse } from './_shared/session.ts';
import { createServiceClient } from './_shared/supabase.ts';
import { parseSaasUser } from './_shared/types.ts';

function canChangePassword(
  actor: { id: number; role: string; company_id: number | null },
  targetId: number,
  targetCompanyId: number | null
): boolean {
  if (actor.role === 'super_admin') return true;
  if (actor.id === targetId) return true;
  if (actor.role === 'company_admin' && actor.company_id != null && actor.company_id === targetCompanyId) {
    return true;
  }
  return false;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }

  if (req.method !== 'POST') {
    return jsonResponse(req, { error: 'method_not_allowed' }, 405);
  }

  try {
    const rawToken = readCookie(req, COOKIE_NAME);
    if (!rawToken) {
      return jsonResponse(req, { error: 'unauthorized' }, 401);
    }

    let body: { user_id?: number | string; new_password?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse(req, { error: 'invalid_json' }, 400);
    }

    const targetId = parseInt(String(body.user_id ?? ''), 10);
    const newPassword = String(body.new_password ?? '');
    if (!targetId || newPassword.length < 6) {
      return jsonResponse(req, { error: 'invalid_input' }, 400);
    }

    const supabase = createServiceClient();
    const tokenHash = await sha256Hex(rawToken);

    const { data: rawActor, error: sessErr } = await supabase.rpc('saas_verify_session', {
      p_token_hash: tokenHash,
    });

    if (sessErr) {
      console.error('saas_verify_session:', sessErr.message);
      return jsonResponse(req, { error: 'unauthorized' }, 401);
    }

    const actor = parseSaasUser(rawActor);
    if (!actor) {
      return jsonResponse(req, { error: 'unauthorized' }, 401);
    }

    const { data: targetRow, error: targetErr } = await supabase
      .from('saas_users')
      .select('id, company_id')
      .eq('id', targetId)
      .maybeSingle();

    if (targetErr || !targetRow) {
      return jsonResponse(req, { error: 'invalid_user' }, 400);
    }

    const targetCompanyId =
      targetRow.company_id == null ? null : parseInt(String(targetRow.company_id), 10) || null;

    if (!canChangePassword(actor, targetId, targetCompanyId)) {
      return jsonResponse(req, { error: 'forbidden' }, 403);
    }

    const { data: hash, error: hashErr } = await supabase.rpc('saas_hash_password_bcrypt', {
      p_password: newPassword,
    });

    if (hashErr || !hash || typeof hash !== 'string') {
      console.error('saas_hash_password_bcrypt:', hashErr?.message);
      return jsonResponse(req, { error: 'hash_failed' }, 500);
    }

    const { error: updateErr } = await supabase
      .from('saas_users')
      .update({ password_hash: hash, password_algo: 'bcrypt' })
      .eq('id', targetId);

    if (updateErr) {
      console.error('password update:', updateErr.message);
      return jsonResponse(req, { error: updateErr.message }, 500);
    }

    return jsonResponse(req, { ok: true });
  } catch (e) {
    console.error('auth-set-password:', e);
    return jsonResponse(req, { error: String(e) }, 500);
  }
});
