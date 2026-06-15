/**
 * Supabase defaults — anon key is public (RLS protects data).
 * Overridden by config/local.config.js locally or Netlify env at build.
 */
window.__BASMA_SUPABASE_DEFAULTS__ = {
  supabaseUrl: 'https://qalcnvygyjtlmlauvzlk.supabase.co',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFhbGNudnlneWpsdG1sYXV2emxrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODExOTA0MDksImV4cCI6MjA5Njc2NjQwOX0.fNhXZtWWvUn5qd5qzAFqhKN8mqCIVWDhGod69_jFfeI',
  appEnv: 'production'
};
