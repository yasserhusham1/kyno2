// Deploy: supabase functions deploy auth-session
/// <reference path="../env.d.ts" />
import { COOKIE_NAME, corsHeaders, readCookie, sha256Hex, jsonResponse } from './_shared/session.ts';
import { createServiceClient } from './_shared/supabase.ts';
import { parseSaasUser } from './_shared/types.ts';
import { issueTokensForSaasUser } from './_shared/auth-jwt.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }

  if (req.method !== 'GET' && req.method !== 'POST') {
    return jsonResponse(req, { error: 'method_not_allowed' }, 405);
  }

  try {
    const rawToken = readCookie(req, COOKIE_NAME);
    if (!rawToken) {
      return jsonResponse(req, { user: null });
    }

    const supabase = createServiceClient();
    const tokenHash = await sha256Hex(rawToken);

    const { data: rawUser, error } = await supabase.rpc('saas_verify_session', {
      p_token_hash: tokenHash,
    });

    if (error) {
      console.error('saas_verify_session:', error.message);
      return jsonResponse(req, { user: null });
    }

    const user = parseSaasUser(rawUser);
    if (!user) return jsonResponse(req, { user: null });

    let tokens;
    try {
      tokens = await issueTokensForSaasUser(supabase, user);
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
    console.error('auth-session:', e);
    return jsonResponse(req, { error: String(e) }, 500);
  }
});
