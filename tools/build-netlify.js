#!/usr/bin/env node
/**
 * Netlify build — minimal dist/ artifact (fast upload).
 * Env (optional): BASMA_SUPABASE_URL, BASMA_SUPABASE_ANON_KEY, BASMA_APP_ENV
 * Falls back to config/supabase.defaults.js when env not set.
 */
'use strict';

var fs = require('fs');
var path = require('path');

var root = path.join(__dirname, '..');
var dist = path.join(root, 'dist');

var url = (process.env.BASMA_SUPABASE_URL || process.env.SUPABASE_URL || '').trim();
var key = (process.env.BASMA_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY || '').trim();
var appEnv = (process.env.BASMA_APP_ENV || 'production').trim();
var isProd = appEnv === 'production';

function readDefaultsFromFile() {
  var p = path.join(root, 'config', 'supabase.defaults.js');
  if (!fs.existsSync(p)) return { supabaseUrl: '', supabaseAnonKey: '' };
  var src = fs.readFileSync(p, 'utf8');
  var mUrl = src.match(/supabaseUrl:\s*['"]([^'"]+)['"]/);
  var mKey = src.match(/supabaseAnonKey:\s*['"]([^'"]+)['"]/);
  return {
    supabaseUrl: mUrl ? mUrl[1] : '',
    supabaseAnonKey: mKey ? mKey[1] : ''
  };
}

var baked = readDefaultsFromFile();
if (!url) url = baked.supabaseUrl;
if (!key) key = baked.supabaseAnonKey;

if (!url || !key) {
  throw new Error('[build-netlify] Missing Supabase URL/anon key — set Netlify env or config/supabase.defaults.js');
}

function rmDir(dir) {
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function copyFile(src, dest) {
  ensureDir(path.dirname(dest));
  fs.copyFileSync(src, dest);
}

function copyDir(srcDir, destDir) {
  if (!fs.existsSync(srcDir)) return 0;
  var n = 0;
  fs.readdirSync(srcDir, { withFileTypes: true }).forEach(function (ent) {
    var s = path.join(srcDir, ent.name);
    var d = path.join(destDir, ent.name);
    if (ent.isDirectory()) n += copyDir(s, d);
    else {
      ensureDir(path.dirname(d));
      fs.copyFileSync(s, d);
      n += 1;
    }
  });
  return n;
}

function dirSize(dir) {
  if (!fs.existsSync(dir)) return 0;
  var total = 0;
  fs.readdirSync(dir, { withFileTypes: true }).forEach(function (ent) {
    var p = path.join(dir, ent.name);
    if (ent.isDirectory()) total += dirSize(p);
    else total += fs.statSync(p).size;
  });
  return total;
}

rmDir(dist);
ensureDir(dist);

var fileCount = 0;

['index.html', 'supabase_integration.js'].forEach(function (f) {
  var src = path.join(root, f);
  if (!fs.existsSync(src)) throw new Error('Missing required file: ' + f);
  copyFile(src, path.join(dist, f));
  fileCount += 1;
});

['css', 'js', 'assets', 'fonts'].forEach(function (d) {
  fileCount += copyDir(path.join(root, d), path.join(dist, d));
});

ensureDir(path.join(dist, 'config'));
['public.config.js', 'supabase.defaults.js'].forEach(function (f) {
  copyFile(path.join(root, 'config', f), path.join(dist, 'config', f));
  fileCount += 1;
});

var envOverrides = {};
if (process.env.BASMA_SUPABASE_URL || process.env.SUPABASE_URL) {
  envOverrides.supabaseUrl = url;
}
if (process.env.BASMA_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY) {
  envOverrides.supabaseAnonKey = key;
}
if (process.env.BASMA_APP_ENV) envOverrides.appEnv = appEnv;
if (process.env.BASMA_SENTRY_DSN) envOverrides.sentryDsn = process.env.BASMA_SENTRY_DSN.trim();
if (process.env.BASMA_AUTH_USE_COOKIES === 'false') envOverrides.authUseCookies = false;
if (process.env.BASMA_KYNO_RPC_MODE === 'true') envOverrides.kynoRpcMode = true;
if (process.env.BASMA_KYNO_RPC_MODE === 'false') envOverrides.kynoRpcMode = false;
if (process.env.BASMA_KYNO_FINAL_LOCKDOWN === 'false') envOverrides.kynoFinalLockdown = false;
if (process.env.BASMA_PAGE_SIZE) {
  envOverrides.pageSize = Math.max(20, parseInt(process.env.BASMA_PAGE_SIZE, 10) || 100);
}

fs.writeFileSync(
  path.join(dist, 'config', 'local.config.js'),
  '/** Optional overrides — defaults in supabase.defaults.js */\nwindow.__BASMA_LOCAL_CONFIG__ = '
    + JSON.stringify(envOverrides, null, 2) + ';\n',
  'utf8'
);
fileCount += 1;

fs.writeFileSync(
  path.join(dist, '_redirects'),
  '/sb/*  /.netlify/functions/supabase-proxy/:splat  200!\n',
  'utf8'
);
fileCount += 1;

var bytes = dirSize(dist);
console.log('[build-netlify] dist ready: ' + fileCount + ' files, '
  + (bytes / 1024).toFixed(1) + ' KB (supabase=' + url.slice(0, 32) + '...)');
