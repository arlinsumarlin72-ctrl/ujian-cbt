/* Isi dua nilai ini dari Supabase: Project Settings > API
   - SUPABASE_URL      : "Project URL", contoh https://abcdefgh.supabase.co
   - SUPABASE_ANON_KEY : kunci "anon public" (atau "publishable"). Aman dipublikasikan:
                         semua tabel terkunci dan hanya bisa diakses lewat fungsi di schema.sql.
   JANGAN pernah menaruh kunci "service_role" / "secret" di sini. */
window.APP_CONFIG = {
  SUPABASE_URL: '',
  SUPABASE_ANON_KEY: ''
};
