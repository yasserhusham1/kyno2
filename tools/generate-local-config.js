#!/usr/bin/env node
/**
 * Netlify build step — writes config/local.config.js from environment variables.
 * Set in Netlify: BASMA_SUPABASE_URL, BASMA_SUPABASE_ANON_KEY, BASMA_APP_ENV=production
 */
'use strict';

var fs = require('fs');
var path = require('path');

var url = (process.env.BASMA_SUPABASE_URL || process.env.SUPABASE_URL || '').trim();
var key = (process.env.BASMA_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY || '').trim();
var appEnv = (process.env.BASMA_APP_ENV || 'production').trim();
var isProd = appEnv === 'production';

if (!url || !key) {
  console.warn('[generate-local-config] WARN: set BASMA_SUPABASE_URL and BASMA_SUPABASE_ANON_KEY in Netlify env');
}

var cfg = {
  supabaseUrl: url,
  supabaseAnonKey: key,
  appEnv: appEnv,
  authUseCookies: process.env.BASMA_AUTH_USE_COOKIES !== 'false',
  kynoRpcMode: process.env.BASMA_KYNO_RPC_MODE === 'true' ? true : (process.env.BASMA_KYNO_RPC_MODE === 'false' ? false : isProd),
  kynoFinalLockdown: process.env.BASMA_KYNO_FINAL_LOCKDOWN === 'false' ? false : isProd,
  sentryDsn: (process.env.BASMA_SENTRY_DSN || '').trim(),
  pageSize: Math.max(20, parseInt(process.env.BASMA_PAGE_SIZE || '100', 10) || 100)
};

var outPath = path.join(__dirname, '..', 'config', 'local.config.js');
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(
  outPath,
  '/** Auto-generated at build — do not commit */\nwindow.__BASMA_LOCAL_CONFIG__ = '
    + JSON.stringify(cfg, null, 2) + ';\n',
  'utf8'
);

console.log('[generate-local-config] wrote', outPath, '(appEnv=' + appEnv + ')');
