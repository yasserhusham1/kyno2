/**
 * Netlify Function — proxy /sb/* → Supabase
 * Requires: netlify deploy --prod --dir=dist  (NOT drag-drop dist only)
 */
const SUPABASE_ORIGIN = (
  process.env.BASMA_SUPABASE_URL ||
  process.env.SUPABASE_URL ||
  'https://qalcnvygyjltmlauvzlk.supabase.co'
).replace(/\/$/, '');

const FN_PREFIX = '/.netlify/functions/supabase-proxy';

const SKIP_REQ = new Set([
  'host', 'connection', 'content-length', 'accept-encoding',
  'x-forwarded-for', 'x-forwarded-proto', 'x-nf-request-id',
  'x-nf-account-id', 'x-nf-site-id', 'x-nf-client-connection-ip',
]);

const SKIP_RES = new Set([
  'transfer-encoding', 'content-encoding', 'content-length', 'connection',
]);

function cors(event, extra) {
  const origin = event.headers.origin || event.headers.Origin || '*';
  const h = {
    'Access-Control-Allow-Origin': origin && origin !== 'null' ? origin : '*',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Headers':
      'authorization, x-client-info, apikey, content-type, x-supabase-api-version, cookie',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    Vary: 'Origin',
  };
  if (extra) Object.assign(h, extra);
  return h;
}

function upstreamPath(event) {
  var p = event.path || event.rawPath || '/';
  if (p.indexOf(FN_PREFIX) === 0) {
    p = p.slice(FN_PREFIX.length) || '/';
  }
  if (p.indexOf('/sb/') === 0) {
    p = p.slice(3) || '/';
  } else if (p === '/sb') {
    p = '/';
  }
  if (p === '/' || p === '') {
    var raw = event.rawUrl || '';
    var idx = raw.indexOf('/sb/');
    if (idx >= 0) {
      try {
        var u = new URL(raw);
        p = u.pathname.replace(/^\/sb/, '') || '/';
        if (u.search) event._parsedQuery = u.search;
      } catch (e) { /* ignore */ }
    }
  }
  if (p.charAt(0) !== '/') p = '/' + p;
  return p;
}

exports.handler = async function (event) {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: cors(event), body: '' };
  }

  var path = upstreamPath(event);
  var qs = event._parsedQuery || (event.rawQuery ? '?' + event.rawQuery : '');
  var target = SUPABASE_ORIGIN + path + qs;

  var headers = { 'accept-encoding': 'identity' };
  Object.keys(event.headers || {}).forEach(function (k) {
    if (!SKIP_REQ.has(k.toLowerCase())) headers[k] = event.headers[k];
  });

  var init = {
    method: event.httpMethod,
    headers: headers,
    redirect: 'manual',
  };

  if (event.body && event.httpMethod !== 'GET' && event.httpMethod !== 'HEAD') {
    init.body = event.isBase64Encoded ? Buffer.from(event.body, 'base64') : event.body;
  }

  try {
    var res = await fetch(target, init);
    var out = cors(event);
    res.headers.forEach(function (value, key) {
      if (SKIP_RES.has(key.toLowerCase())) return;
      out[key] = value;
    });

    var body = await res.text();

    return {
      statusCode: res.status,
      headers: out,
      body: body,
    };
  } catch (err) {
    return {
      statusCode: 502,
      headers: cors(event, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({
        error: 'proxy_failed',
        message: String(err && err.message ? err.message : err),
      }),
    };
  }
};

/** Route /sb/* directly to this function (no _redirects needed) */
exports.config = {
  path: '/sb/*',
};
