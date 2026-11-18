/* Pembungkus pemanggil fungsi (RPC) Supabase lewat fetch biasa. */
(function () {
  'use strict';
  var cfg = window.APP_CONFIG || {};
  var KEY = 'cbt_token';

  function getToken() { try { return localStorage.getItem(KEY); } catch (e) { return window.__cbtTok || null; } }
  function setToken(t) {
    try { if (t) localStorage.setItem(KEY, t); else localStorage.removeItem(KEY); } catch (e) { window.__cbtTok = t || null; }
  }

  async function rpc(fn, args) {
    if (!cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY) {
      throw new Error('Website belum dikonfigurasi: isi js/config.js dengan URL dan anon key Supabase.');
    }
    var headers = { 'Content-Type': 'application/json', apikey: cfg.SUPABASE_ANON_KEY };
    if (String(cfg.SUPABASE_ANON_KEY).indexOf('eyJ') === 0) headers.Authorization = 'Bearer ' + cfg.SUPABASE_ANON_KEY;
    var res;
    try {
      res = await fetch(cfg.SUPABASE_URL.replace(/\/+$/, '') + '/rest/v1/rpc/' + fn, {
        method: 'POST', headers: headers, body: JSON.stringify(args || {})
      });
    } catch (e) {
      var ne = new Error('Tidak bisa terhubung ke server. Periksa koneksi internet.');
      ne.network = true;
      throw ne;
    }
    var text = await res.text();
    var data = null;
    try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
    if (!res.ok) {
      var msg = (data && data.message) ? data.message : 'Terjadi kesalahan (' + res.status + ').';
      if (data && data.code === 'PGRST202') msg = 'Fungsi database belum terpasang. Jalankan supabase/schema.sql.';
      var err = new Error(msg);
      err.code = data && data.code;
      err.status = res.status;
      throw err;
    }
    return data;
  }

  /* Panggilan dengan token login otomatis */
  function call(fn, args) {
    var a = Object.assign({ p_token: getToken() }, args || {});
    return rpc(fn, a);
  }

  window.Api = { rpc: rpc, call: call, getToken: getToken, setToken: setToken };
})();
