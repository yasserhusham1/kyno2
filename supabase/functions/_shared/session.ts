/** Shared session helpers for Edge Functions */
export const COOKIE_NAME = 'basma_session';
export const SESSION_DAYS = 7;

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
  const list = parseAllowedOrigins();
  if (list.includes(origin)) return true;
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

/** CORS: مع credentials يجب echo للـ Origin المسموح — لا wildcard * */
export function corsHeaders(req: Request): Record<string, string> {
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

export function requestIsCrossSite(req: Request): boolean {
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

export function jsonResponse(
  req: Request,
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {}
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(req),
      'Content-Type': 'application/json',
      ...extraHeaders,
    },
  });
}

export function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

export async function sha256Hex(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, '0')).join('');
}

export function cookieHeader(token: string, maxAgeSec: number, secure: boolean, crossSite = false): string {
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

export function clearCookieHeader(secure: boolean, crossSite = false): string {
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

export function readCookie(req: Request, name: string): string | null {
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

export function isSecureDeployment(): boolean {
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  return url.startsWith('https://');
}
