/**
 * Sync Supabase Auth user + issue GoTrue tokens (valid for browser setSession).
 */
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';
import type { SaasUserProfile } from './types.ts';

export function internalAuthEmail(user: SaasUserProfile): string {
  if (user.email && user.email.includes('@')) return user.email.trim().toLowerCase();
  const safeUser = String(user.username || 'user').replace(/[^a-zA-Z0-9._-]/g, '_');
  return `saas_${user.id}_${safeUser}@users.kyno.auth`;
}

function buildAppMetadata(user: SaasUserProfile): Record<string, unknown> {
  const meta: Record<string, unknown> = {
    role: user.role,
    saas_user_id: user.id,
  };
  if (user.company_id != null) meta.company_id = user.company_id;
  return meta;
}

export async function ensureAuthUser(
  admin: SupabaseClient,
  user: SaasUserProfile,
): Promise<string> {
  const email = internalAuthEmail(user);
  const appMeta = buildAppMetadata(user);

  const { data: existing, error: getErr } = await admin.auth.admin.getUserByEmail(email);
  if (!getErr && existing?.user?.id) {
    await admin.auth.admin.updateUserById(existing.user.id, { app_metadata: appMeta });
    return existing.user.id;
  }

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    app_metadata: appMeta,
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

function createAnonAuthClient(): SupabaseClient {
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!url || !anon) throw new Error('Missing SUPABASE_URL or SUPABASE_ANON_KEY');
  return createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Tokens signed by GoTrue — compatible with supabase-js setSession */
export async function issueTokensForSaasUser(
  admin: SupabaseClient,
  user: SaasUserProfile,
): Promise<{ access_token: string; refresh_token: string; expires_in: number }> {
  const email = internalAuthEmail(user);
  const appMeta = buildAppMetadata(user);
  const authUserId = await ensureAuthUser(admin, user);

  const oneTimePassword = crypto.randomUUID() + 'Aa1!' + crypto.randomUUID().slice(0, 8);
  const { error: pwdErr } = await admin.auth.admin.updateUserById(authUserId, {
    app_metadata: appMeta,
    password: oneTimePassword,
    email_confirm: true,
  });
  if (pwdErr) throw pwdErr;

  const anonClient = createAnonAuthClient();
  const { data, error } = await anonClient.auth.signInWithPassword({
    email,
    password: oneTimePassword,
  });
  if (error || !data.session?.access_token) {
    throw error ?? new Error('gotrue_sign_in_failed');
  }

  return {
    access_token: data.session.access_token,
    refresh_token: data.session.refresh_token,
    expires_in: data.session.expires_in ?? 3600,
  };
}
