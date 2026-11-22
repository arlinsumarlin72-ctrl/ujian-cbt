/* Ruang Ujian: halaman peserta (masuk, sesi, ujian, hasil, peringkat, profil). */
(function () {
  'use strict';

  var root = document.getElementById('app');
  var S = { me: null, exam: null, result: null };
  var H = {};          // penangan klik/submit/change, berdasarkan nama
  var cleanups = [];   // fungsi pembersih saat pindah halaman

  var EMOJIS = ['😀', '😎', '🤓', '🧠', '🩺', '💉', '🫀', '🦷', '🐱', '🦊', '🌟', '🔥'];
  var AVATARS = ['#0E6A73', '#2F6DA8', '#7A4E9C', '#A5551C', '#B13A5F', '#5E7A1F', '#4A5A66', '#8A6A00'];
  var FB_LABEL = { each: 'Kunci tampil per nomor', '10': 'Kunci tampil tiap 10 soal', '20': 'Kunci tampil tiap 20 soal', end: 'Kunci tampil di akhir' };
  function fbLabel(m) { if (FB_LABEL[m]) return FB_LABEL[m]; var x = /^([0-9]+)(s?)$/.exec(m || ''); return x ? 'Kunci tampil tiap ' + (+x[1]) + ' soal, ' + (x[2] ? 'dibuka satu per satu' : 'sekaligus') : ''; }

  /* ---------- utilitas ---------- */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function clock(sec) {
    sec = Math.max(0, Math.round(sec || 0));
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return h ? h + ':' + pad(m) + ':' + pad(s) : pad(m) + ':' + pad(s);
  }
  function modeInfo(m) {
    m = m || '';
    if (m === 'each') return { kind: 'each' };
    var x = /^([0-9]+)(s?)$/.exec(m);
    if (x) return { kind: 'block', n: +x[1], step: !!x[2] };
    return { kind: 'end' };
  }
  var audioCtx = null;
  function beep() {
    try {
      var C = window.AudioContext || window.webkitAudioContext; if (!C) return;
      audioCtx = audioCtx || new C();
      if (audioCtx.state === 'suspended') audioCtx.resume();
      var o = audioCtx.createOscillator(), g = audioCtx.createGain(), t = audioCtx.currentTime;
      o.type = 'sine'; o.frequency.setValueAtTime(880, t); o.frequency.setValueAtTime(1175, t + 0.2);
      g.gain.setValueAtTime(0.18, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.55);
      o.connect(g); g.connect(audioCtx.destination); o.start(t); o.stop(t + 0.6);
      if (navigator.vibrate) navigator.vibrate([120, 60, 120]);
    } catch (e) { /* abaikan */ }
  }
  function pct(a, b) { return b ? Math.round((a / b) * 100) : 0; }
  function initial(name) { return esc(String(name || '?').trim().charAt(0).toUpperCase()); }
  function avParts(v) {
    var s = String(v || ''), i = s.indexOf('|');
    return { color: /^#[0-9A-Fa-f]{6}$/.test(i < 0 ? s : s.slice(0, i)) ? (i < 0 ? s : s.slice(0, i)) : '#0E6A73', extra: i < 0 ? '' : s.slice(i + 1) };
  }
  function avatar(name, color, cls) {
    var p = avParts(color), inner;
    if (/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(p.extra)) inner = '<img src="' + p.extra + '" alt="" style="width:100%;height:100%;border-radius:999px;object-fit:cover;display:block">';
    else if (p.extra) inner = '<span style="font-size:1.25em;line-height:1">' + esc(p.extra) + '</span>';
    else inner = initial(name);
    return '<span class="avatar ' + (cls || '') + '" style="background:' + esc(p.color) + ';overflow:hidden" aria-hidden="true">' + inner + '</span>';
  }
  function safeImg(src) { return typeof src === 'string' && /^data:image\/(png|jpe?g|gif|webp);base64,/.test(src) ? src : null; }
  function fresh() { var n = S.rt; return function () { return S.rt === n; }; }
  function go(h) { if (location.hash === h) route(); else location.hash = h; }
  function onCleanup(fn) { cleanups.push(fn); }
  function runCleanups() { var c = cleanups; cleanups = []; c.forEach(function (f) { try { f(); } catch (e) { /* abaikan */ } }); }

  function toast(msg, isErr) {
    var box = document.getElementById('toasts');
    if (!box) return;
    var t = document.createElement('div');
    t.className = 'toast' + (isErr ? ' err' : '');
    t.textContent = msg;
    box.appendChild(t);
    setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, isErr ? 6000 : 3500);
  }

  /* ---------- dialog ---------- */
  function dialog(opts) {
    return new Promise(function (resolve) {
      var ov = document.createElement('div');
      ov.className = 'overlay';
      ov.innerHTML = '<div class="modal" role="dialog" aria-modal="true" aria-labelledby="mdt"><h3 id="mdt">' + esc(opts.title) + '</h3>' +
        (opts.text ? '<p class="muted">' + esc(opts.text) + '</p>' : '') + (opts.html || '') +
        '<div class="acts"></div></div>';
      var acts = ov.querySelector('.acts');
      var prev = document.activeElement;
      function close(v) {
        document.removeEventListener('keydown', onKey, true);
        if (ov.parentNode) ov.parentNode.removeChild(ov);
        if (prev && prev.focus) { try { prev.focus(); } catch (e) { /* abaikan */ } }
        resolve(v);
      }
      function onKey(e) { if (e.key === 'Escape') { e.stopPropagation(); close(null); } }
      opts.buttons.forEach(function (b) {
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn ' + (b.cls || '');
        btn.textContent = b.label;
        btn.addEventListener('click', function () {
          if (b.value === 'ok' && opts.input) {
            var inp = ov.querySelector('input');
            close(inp ? inp.value : '');
          } else close(b.value);
        });
        acts.appendChild(btn);
      });
      ov.addEventListener('mousedown', function (e) { if (e.target === ov) close(null); });
      document.addEventListener('keydown', onKey, true);
      document.body.appendChild(ov);
      var f = ov.querySelector('input') || ov.querySelector('.btn-primary, .btn-danger') || ov.querySelector('button');
      if (f) f.focus();
    });
  }
  function confirmDialog(title, text, okLabel, danger) {
    return dialog({ title: title, text: text, buttons: [
      { label: 'Batal', value: false }, { label: okLabel || 'Ya', value: true, cls: danger ? 'btn-danger' : 'btn-primary' }
    ] }).then(function (v) { return v === true; });
  }
  function promptDialog(title, label, type, placeholder) {
    return dialog({
      title: title, input: true,
      html: '<div class="field"><label for="pd">' + esc(label) + '</label><input id="pd" class="input" type="' + (type || 'text') + '" placeholder="' + esc(placeholder || '') + '" autocomplete="off"></div>',
      buttons: [{ label: 'Batal', value: null }, { label: 'Simpan', value: 'ok', cls: 'btn-primary' }]
    });
  }

  /* ---------- kerangka halaman ---------- */
  var LOGO = '<i><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12l4 4 10-10"/></svg></i>';

  function shell(active) {
    var me = S.me || {};
    var links = [['home', '#/home', 'Sesi'], ['latihan', '#/latihan', 'Latihan'], ['peringkat', '#/peringkat', 'Peringkat'], ['profil', '#/profil', 'Profil']];
    if (me.role === 'admin') links.push(['admin', '#/admin/sesi', 'Admin']);
    root.innerHTML = '<header class="topbar"><a class="brand" href="#/home">' + LOGO + 'Ruang Ujian</a>' +
      '<nav class="nav" aria-label="Menu utama">' + links.map(function (l) {
        return '<a href="' + l[1] + '"' + (l[0] === active ? ' class="on" aria-current="page"' : '') + '>' + l[2] + '</a>';
      }).join('') + '</nav>' +
      '<div class="userbox">' + avatar(me.name, me.avatar_color) + '<span>' + esc(me.name) + '</span>' +
      '<button class="btn btn-sm" type="button" data-act="logout">Keluar</button></div></header>' +
      '<main id="main" class="wrap"><div class="loading">Memuat...</div></main>';
  }
  function setMain(html) { var m = document.getElementById('main'); if (m) m.innerHTML = html; }

  function errorCard(err, retryHash) {
    var msg = err && err.message ? err.message : 'Terjadi kesalahan.';
    return '<div class="card"><h2 class="bold">Ada masalah</h2><p>' + esc(msg) + '</p>' +
      '<div><button class="btn btn-primary" type="button" data-act="reload">Coba lagi</button></div></div>';
  }

  async function guard(fn) {
    try { await fn(); }
    catch (e) {
      if (e && e.code === '28000') { Api.setToken(null); S.me = null; toast('Sesi login berakhir. Silakan masuk lagi.', true); return loginView(); }
      if (document.getElementById('main')) setMain(errorCard(e));
      else root.innerHTML = '<main class="wrap">' + errorCard(e) + '</main>';
    }
  }

  /* ---------- masuk / daftar ---------- */
  function loginView(mode) {
    mode = mode || 'masuk';
    var reg = mode === 'daftar';
    root.innerHTML = '<div class="login">' +
      '<section class="login-hero"><div class="brand" style="color:#fff">' + LOGO + 'Ruang Ujian</div>' +
      '<div class="col" style="gap:20px"><h1>Latihan soal bersama, satu set untuk semua.</h1>' +
      '<p>Kerjakan sesi yang dibuat admin, lihat peringkat, dan pantau perkembangan nilaimu dari waktu ke waktu.</p></div>' +
      '<p class="small" style="color:#BFE3E6">Tanpa pembahasan: hanya kunci jawaban dan status benar/salah.</p></section>' +
      '<section class="login-form"><form class="login-card" data-submit="auth" data-mode="' + mode + '">' +
      '<div class="seg" role="tablist"><button type="button" role="tab" class="' + (reg ? '' : 'on') + '" data-act="login-tab" data-v="masuk">Masuk</button>' +
      '<button type="button" role="tab" class="' + (reg ? 'on' : '') + '" data-act="login-tab" data-v="daftar">Daftar baru</button></div>' +
      '<div class="field"><label for="nm">Nama</label><input id="nm" name="name" class="input" autocomplete="username" maxlength="40" required></div>' +
      '<div class="field"><label for="pn">PIN (4-6 angka)</label><input id="pn" name="pin" class="input" type="password" inputmode="numeric" pattern="[0-9]{4,6}" maxlength="6" autocomplete="' + (reg ? 'new-password' : 'current-password') + '" required></div>' +
      '<p id="auth-err" class="small" style="color:var(--bad);font-weight:600" role="alert"></p>' +
      '<button class="btn btn-primary" style="height:50px" type="submit">' + (reg ? 'Daftar dan masuk' : 'Masuk') + '</button>' +
      '<p class="small muted">' + (reg ? 'Pakai nama yang mudah dikenali teman-temanmu. PIN dipakai untuk masuk lagi di perangkat lain.' : 'Lupa PIN? Minta admin untuk mengatur ulang.') + '</p>' +
      '</form></section></div>';
  }

  H['login-tab'] = function (el) { loginView(el.dataset.v); };
  H.auth = async function (form) {
    var name = form.elements.name.value, pin = form.elements.pin.value;
    var errBox = document.getElementById('auth-err');
    var btn = form.querySelector('button[type=submit]');
    errBox.textContent = '';
    btn.disabled = true;
    try {
      var d = await Api.rpc(form.dataset.mode === 'daftar' ? 'app_register' : 'app_login', { p_name: name, p_pin: pin });
      Api.setToken(d.token);
      S.me = d.profile;
      go('#/home');
      if (location.hash === '' || location.hash === '#') route();
    } catch (e) {
      errBox.textContent = e.message;
      btn.disabled = false;
    }
  };
  H.logout = function () { Api.setToken(null); S.me = null; S.exam = null; go('#/login'); };
  H.reload = function () { route(); };

  /* ---------- beranda: daftar sesi ---------- */
  async function homeView() {
    shell('home');
    var ok = fresh();
    await guard(async function () {
      var list = (await Api.call('app_sessions')).filter(function (s) { return s.kind !== 'latihan'; });
      if (!ok()) return;
      var html = '<div class="col" style="gap:4px"><h1 class="page-title">Sesi ujian</h1><p class="page-sub">Pilih sesi yang dibuat admin. Soalnya sama untuk semua peserta.</p></div>';
      if (!list.length) {
        html += '<div class="card"><p class="bold">Belum ada sesi.</p><p class="muted">Admin belum membuat sesi ujian. Cek lagi nanti.</p></div>';
      } else {
        html += '<div class="col">' + list.map(sessionCard).join('') + '</div>';
      }
      setMain(html);
    });
  }
  function sessionCard(s) {
    var action;
    var strictAttr = function (isNew) { return s.ketat ? ' data-act="start-exam" data-v="' + s.id + '"' + (isNew ? ' data-new="1"' : '') : ''; };
    if (s.done) action = '<a class="btn btn-primary" href="#/hasil/' + s.id + '">Lihat hasil</a>';
    else if (s.started) action = '<a class="btn btn-primary" href="#/ujian/' + s.id + '"' + strictAttr(false) + '>Lanjutkan</a>';
    else if (s.status === 'open') action = '<a class="btn btn-primary" href="#/ujian/' + s.id + '"' + strictAttr(true) + '>Mulai</a>';
    else action = '<button class="btn" type="button" disabled>Ditutup</button>';
    var badge = s.done ? '<span class="badge b-ok">Selesai: ' + s.score + ' / ' + s.total + '</span>'
      : s.started ? '<span class="badge b-warn">Sedang dikerjakan</span>'
      : s.status === 'open' ? '<span class="badge b-info">Terbuka</span>' : '<span class="badge b-bad">Ditutup</span>';
    return '<div class="session"><div><h3>' + esc(s.title) + '</h3><div class="meta"><span>' + s.total + ' soal</span><span>' +
      (s.timer_minutes ? s.timer_minutes + ' menit' + (/^[0-9]+s?$/.test(s.feedback_mode || '') ? ' per bagian' : '') : 'Tanpa timer') + '</span><span>' + esc(fbLabel(s.feedback_mode)) + '</span>' +
      (s.lock_mode === 'locked' ? '<span>Bagian dibuka admin satu per satu</span>' : '') + (s.allow_pause ? '<span>Boleh jeda</span>' : '') +
      (s.ketat ? '<span class="badge b-warn">Mode ketat</span>' : '') +
      '<span>' + s.finished + ' peserta selesai</span></div></div><div class="row row-c">' + badge + action + '</div></div>';
  }

  /* ---------- ujian ---------- */
  var FLAG_SVG = '<svg class="flag-ic" viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M5 21V3.5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" fill="none"/><path class="flag-fill" d="M5 4h13l-3 4.5 3 4.5H5z" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/></svg>';
  var LOCK_SVG = '<svg viewBox="0 0 24 24" width="40" height="40" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="10" width="16" height="11" rx="2.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>';
  var MARK_SVG = '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 11l-5 5 3 3 5-5"/><path d="M14 6l4 4-7 7-4-4z"/><path d="M4 20h7"/></svg>';

  /* penyimpanan lokal per sesi (coretan, stabilo, cadangan jawaban) */
  function lsGet(k, sid, def) { try { var v = localStorage.getItem('cbt_' + k + '_' + sid); return v ? JSON.parse(v) : def; } catch (e) { return def; } }
  function lsSet(k, sid, v) { try { localStorage.setItem('cbt_' + k + '_' + sid, JSON.stringify(v)); } catch (e) { /* abaikan */ } }
  function lsDel(k, sid) { try { localStorage.removeItem('cbt_' + k + '_' + sid); } catch (e) { /* abaikan */ } }

  function cur() { return S.exam.qs[S.exam.idx]; }
  function fsEl() { return document.fullscreenElement || document.webkitFullscreenElement || null; }
  function fsSupported() { var d = document.documentElement; return !!(d.requestFullscreen || d.webkitRequestFullscreen); }
  function requestFs() {
    var d = document.documentElement;
    try { var p = (d.requestFullscreen || d.webkitRequestFullscreen || function () {}).call(d); if (p && p.catch) p.catch(function () {}); } catch (e) { /* abaikan */ }
  }
  function exitFs() {
    try { var p = (document.exitFullscreen || document.webkitExitFullscreen || function () {}).call(document); if (p && p.catch) p.catch(function () {}); } catch (e) { /* abaikan */ }
  }
  function frozenClock(E) { return E.discussing || E.paused; }
  function elapsedNow(E) { return frozenClock(E) ? E.elapsed0 : E.elapsed0 + (Date.now() - E.t0) / 1000; }
  function noop() {}

  async function examView(id) {
    root.innerHTML = '<div class="loading">Menyiapkan soal...</div>';
    var ok = fresh();
    var d;
    try { d = await Api.call('app_start', { p_session: id }); }
    catch (e) {
      if (e.code === '28000') { Api.setToken(null); S.me = null; return loginView(); }
      shell('home'); setMain(errorCard(e)); return;
    }
    if (!ok()) return;
    if (d.submitted) return go('#/hasil/' + id);
    var E = S.exam = {
      id: id, session: d.session, qs: d.questions, answers: d.answers || {}, flags: d.flags || {}, keys: {},
      idx: 0, dirty: false, chain: Promise.resolve(), saveT: null, panel: false, submitting: false, saveState: '',
      locked: d.locked || 0, notified: -1, revealed: d.revealed || [], viol: d.viol || 0,
      elapsed0: d.elapsed || 0, t0: Date.now(), discussing: !!d.session.discussing, paused: !!d.paused, navFilter: '',
      away: null, fsSeen: false, vchain: Promise.resolve(),
      times: d.times || {}, tdirty: false, notes: d.notes || {}, noteOpen: {}, peers: {}, warned: {},
      blk: d.blk, blk_start: d.blk_start, bp: d.bp || null, flow: null, flowAt: 0,
      ui: { nav: uiGet('nav', true), adm: uiGet('adm', true), dk: uiGet('dk', true) },
      spot: d.spot || null, dplan: d.dplan || null, dsince0: d.dsince || 0, dt0: Date.now(), follow: true,
      rc: null, rcAt: 0, rcPick: null, rcBusy: false, dbeep: false, xplan: '',
      elim: lsGet('elim', id, {}), hl: lsGet('hl', id, {}), hlOn: false, saveFail: false, offline: false
    };
    var first = E.qs.findIndex(function (q) { return !q.locked && !E.answers[q.id]; });
    E.idx = first < 0 ? 0 : first;
    if (E.session.timer_minutes && modeInfo(E.session.feedback_mode).kind !== 'block') {
      var left0 = E.session.timer_minutes * 60 - E.elapsed0;
      [600, 300, 60].forEach(function (t) { if (left0 <= t) E.warned[t] = true; });
    }
    if (S.me && S.me.role === 'admin' && E.session.kind !== 'latihan') {
      try { E.flow = await Api.call('adm_flow_state', { p_session: id }); E.flowAt = Date.now(); } catch (e) { /* abaikan */ }
      if (!ok() || S.exam !== E) return;
    }

    var rid = revealIds(E);
    if (rid.length) {
      try { Object.assign(E.keys, await Api.call('app_reveal', { p_session: id, p_qids: rid })); } catch (e) { /* abaikan */ }
    }
    if (!ok() || S.exam !== E) return;
    restoreBackup(E);
    renderExam();
    var tick = setInterval(function () { tickTimer(true); }, 1000);
    var poll = setInterval(pollRev, 4000);
    onCleanup(function () { clearInterval(tick); clearInterval(poll); clearTimeout(E.saveT); document.removeEventListener('keydown', onExamKey); });
    document.addEventListener('keydown', onExamKey);
    installExtras(E);
    if (E.session.ketat) installStrict(E);
    peersFor(E);
    loadRecap(E, null);
    tickTimer();
  }

  /* jawaban yang sempat tidak terkirim (mis. koneksi putus lalu halaman dimuat ulang) dipulihkan dari perangkat */
  function restoreBackup(E) {
    var bk = lsGet('bk', E.id, null);
    if (!bk || !bk.t || Date.now() - bk.t > 12 * 3600 * 1000 || E.discussing || E.paused) return;
    var n = 0;
    E.qs.forEach(function (q, i) {
      if (q.locked || i < E.locked) return;
      if (bk.a && bk.a[q.id] && !E.answers[q.id]) { E.answers[q.id] = bk.a[q.id]; n++; }
      if (bk.f && bk.f[q.id] && !E.flags[q.id]) { E.flags[q.id] = true; n++; }
    });
    if (n) { toast('Jawaban yang belum sempat tersimpan dipulihkan dari perangkat ini.'); queueSave(); }
  }
  function setBanner(E) {
    var el = document.getElementById('savebanner'); if (!el) return;
    var msg = E.offline ? 'Tidak ada koneksi internet. Jawabanmu disimpan di perangkat dan dikirim otomatis saat tersambung. Jangan tutup halaman ini.'
      : (E.saveFail ? 'Jawabanmu belum tersimpan ke server. Mencoba lagi otomatis. Jangan tutup halaman ini.' : '');
    el.textContent = msg; el.classList.toggle('hidden', !msg);
  }
  function flushTimes(E) {
    if (!E || !E.tdirty || E.submitting) return Promise.resolve();
    E.tdirty = false;
    return Api.call('app_times', { p_session: E.id, p_times: E.times }).catch(function () { E.tdirty = true; });
  }
  function installExtras(E) {
    function onOff() { E.offline = true; setBanner(E); }
    function onOn() { E.offline = false; setBanner(E); if (E.dirty || E.saveFail) flushSave(); flushTimes(E); }
    function onUnload(e) { if (S.exam === E && (E.dirty || E.saveFail)) { e.preventDefault(); e.returnValue = ''; return ''; } }
    function onHide() { if (document.hidden) flushTimes(E); }
    window.addEventListener('offline', onOff);
    window.addEventListener('online', onOn);
    window.addEventListener('beforeunload', onUnload);
    window.addEventListener('pagehide', onHide);
    document.addEventListener('visibilitychange', onHide);
    var ti = setInterval(function () { flushTimes(E); }, 20000);
    onCleanup(function () {
      clearInterval(ti);
      window.removeEventListener('offline', onOff);
      window.removeEventListener('online', onOn);
      window.removeEventListener('beforeunload', onUnload);
      window.removeEventListener('pagehide', onHide);
      document.removeEventListener('visibilitychange', onHide);
    });
    if (typeof navigator !== 'undefined' && navigator.onLine === false) onOff();
  }

  function revealIds(E) {
    var mi = modeInfo(E.session.feedback_mode);
    if (mi.kind === 'each') return E.qs.filter(function (q) { return !q.locked && E.answers[q.id]; }).map(function (q) { return q.id; });
    if (mi.kind === 'block' && !mi.step) return E.qs.slice(0, E.locked).map(function (q) { return q.id; });
    if (mi.kind === 'block' && mi.step) return (E.revealed || []).slice();
    return [];
  }

  /* persentase teman yang benar (hanya untuk soal yang kuncinya sudah terbuka) */
  function peersFor(E) {
    if (!E) return;
    var q = E.qs[E.idx];
    if (!q || q.locked || !E.keys[q.id]) return;
    var p = E.peers[q.id];
    if (p && Date.now() - p.at < 20000) return;
    E.peers[q.id] = Object.assign({ n: 0, ok: 0, d: {} }, p || {}, { at: Date.now() });
    Api.call('app_peers', { p_session: E.id, p_qids: [q.id] }).then(function (res) {
      if (S.exam !== E) return;
      var v = res && res[q.id]; if (!v) return;
      var changed = !p || p.n !== v.n || p.ok !== v.ok || p.e !== v.e;
      E.peers[q.id] = Object.assign({ at: Date.now() }, v);
      if (changed && E.qs[E.idx] && E.qs[E.idx].id === q.id && !(document.activeElement && document.activeElement.tagName === 'TEXTAREA')) renderExam();
    }).catch(noop);
  }

  H['fin-block'] = async function () {
    var E = S.exam; if (!E || E.finBusy || E.submitting || E.locked >= E.qs.length) return;
    var nb = blockInfo(E, E.locked); if (!nb) return;
    var txt = (nb.left ? 'Masih ada ' + nb.left + ' soal yang belum dijawab di blok ini, dan soal itu dihitung salah. ' : 'Semua soal di blok ini sudah dijawab. ') +
      'Setelah diselesaikan, jawaban blok ini terkunci dan tidak bisa diubah. ' + (nb.step ? 'Jawaban benar bisa dibuka satu per satu.' : 'Kunci jawaban langsung ditampilkan.') +
      (E.session.lock_mode === 'locked' ? ' Bagian berikutnya baru terbuka setelah admin membukanya.' : '');
    var ok = await confirmDialog('Yakin selesaikan blok soal ' + (nb.start + 1) + ' sampai ' + (nb.end + 1) + '?', txt, 'Ya, selesaikan', false);
    if (!ok || S.exam !== E) return;
    E.finBusy = true; renderExam();
    try {
      clearTimeout(E.saveT); E.dirty = false;
      var r = await Api.call('app_finalize', { p_session: E.id, p_answers: E.answers, p_flags: E.flags, p_upto: nb.end + 1 });
      E.locked = r.locked; E.blk = r.blk; E.blk_start = r.blk_start;
      flushTimes(E);
      E.notified = nb.start;
      E.finBusy = false;
      await refreshExam(null);
      toast('Blok ' + (nb.start + 1) + ' sampai ' + (nb.end + 1) + ' diselesaikan.');
    } catch (err) { toast(err.message, true); }
    E.finBusy = false;
    if (S.exam === E) { renderExam(); peersFor(E); }
  };
  H['show-key'] = async function () {
    var E = S.exam; if (!E) return;
    var q = cur();
    if (E.keys[q.id] || E.idx >= E.locked) return;
    try {
      Object.assign(E.keys, await Api.call('app_reveal', { p_session: E.id, p_qids: [q.id] }));
      if (E.revealed.indexOf(q.id) < 0) E.revealed.push(q.id);
      if (S.exam === E) { renderExam(); peersFor(E); }
    } catch (err) { toast(err.message, true); }
  };

  /* Sinkronisasi berkala: soal diganti admin, diskusi, jeda, bagian dibuka, dikumpulkan admin */
  async function pollRev() {
    var E = S.exam; if (!E || E.submitting || E.swapBusy) return;
    var d;
    try { d = await Api.call('app_rev', { p_session: E.id }); } catch (e) { return; }
    if (S.exam !== E || !d) return;
    if (d.submitted) { toast('Jawabanmu sudah dikumpulkan oleh admin.'); var sid = E.id; S.exam = null; go('#/hasil/' + sid); return; }
    if (d.elapsed != null) { E.elapsed0 = d.elapsed; E.t0 = Date.now(); }
    var changed = false, spotNew = false;
    E.dplan = d.dplan || null; E.dsince0 = d.dsince || 0; E.dt0 = Date.now();
    if (d.spot && (!E.spot || d.spot.seq !== E.spot.seq)) { E.spot = d.spot; spotNew = true; }
    else if (!d.spot && E.spot) { E.spot = null; changed = true; }
    if (d.bp !== undefined) E.bp = d.bp;
    if (d.blk !== undefined) { if (d.blk !== E.blk) changed = true; E.blk = d.blk; E.blk_start = d.blk_start; }
    if (d.locked != null && d.locked > E.locked) {
      // waktu bagian habis: server sudah menyelesaikan bagian itu
      await refreshExam('Waktu bagian habis. Jawabanmu dikunci dan kunci jawaban dibuka.', true);
      if (S.exam === E && E.locked >= E.qs.length && E.session.timer_minutes && modeInfo(E.session.feedback_mode).kind === 'block') doSubmit(true);
      return;
    }
    if (S.me && S.me.role === 'admin' && E.session.kind !== 'latihan') {
      try { E.flow = await Api.call('adm_flow_state', { p_session: E.id }); E.flowAt = Date.now(); } catch (e) { /* abaikan */ }
      if (S.exam !== E) return;
    }
    if (!!d.discussing !== E.discussing) {
      E.discussing = !!d.discussing; changed = true; E.dbeep = false;
      beep();
      if (E.discussing) { E.away = null; toast('Diskusi dimulai. Waktu dihentikan sementara.'); await flushSave(); }
      else toast('Diskusi selesai. Waktu berjalan lagi.');
      if (S.exam !== E) return;
    }
    if (!!d.paused !== E.paused) { E.paused = !!d.paused; changed = true; }
    if (d.lock_mode === 'locked' && d.unlocked_n !== E.session.unlocked_n) { await refreshExam('Bagian berikutnya sudah dibuka admin.', true); return; }
    if (d.rev !== E.session.rev) { await refreshExam(d.notice || 'Ada soal yang diganti oleh admin.'); return; }
    if (changed || spotNew) {
      if (spotNew) onSpot(E); else { renderExam(); awayCheck(); }
      loadRecap(E, E.rcPick);
    } else {
      updateBars(E);
      if (E.ui.dk && dkAvailable(E) && Date.now() - E.rcAt > 7000) loadRecap(E, E.rcPick);
    }
    peersFor(E);
  }
  async function refreshExam(notice, soft) {
    var E = S.exam; if (!E) return;
    if (E.dirty) await flushSave();
    var d;
    try { d = await Api.call('app_start', { p_session: E.id }); } catch (e) { return; }
    if (S.exam !== E || !d) return;
    if (d.submitted) { var sid2 = E.id; S.exam = null; go('#/hasil/' + sid2); return; }
    clearTimeout(E.saveT); E.dirty = false;
    E.session = d.session; E.discussing = !!d.session.discussing; E.paused = !!d.paused;
    E.elapsed0 = d.elapsed || 0; E.t0 = Date.now(); E.viol = d.viol || E.viol;
    E.blk = d.blk; E.blk_start = d.blk_start; E.bp = d.bp || null;
    E.spot = d.spot || null; E.dplan = d.dplan || null; E.dsince0 = d.dsince || 0; E.dt0 = Date.now();
    E.qs = d.questions; E.answers = d.answers || {}; E.flags = d.flags || {}; E.keys = {}; E.locked = d.locked || 0; E.revealed = d.revealed || [];
    E.notes = Object.assign({}, d.notes || {}, E.notes); E.peers = {};
    if (E.idx > E.qs.length - 1) E.idx = E.qs.length - 1;
    var rid = revealIds(E);
    if (rid.length) {
      try { Object.assign(E.keys, await Api.call('app_reveal', { p_session: E.id, p_qids: rid })); } catch (e) { /* abaikan */ }
    }
    if (S.exam !== E) return;
    renderExam();
    peersFor(E);
    loadRecap(E, E.rcPick);
    if (notice && soft) { beep(); toast(notice); }
    else if (notice) dialog({ title: 'Soal diganti', text: notice, buttons: [{ label: 'Mengerti', value: true, cls: 'btn-primary' }] });
  }
  H.swap = async function () {
    var E = S.exam; if (!E || !S.me || S.me.role !== 'admin' || E.swapBusy) return;
    var q = cur();
    var ok = await confirmDialog('Ganti soal ini?', 'Soal nomor ' + (E.idx + 1) + ' akan diganti soal baru dari bank yang sama untuk SEMUA peserta. Jawaban peserta pada soal ini dihapus dan mereka mendapat pemberitahuan.', 'Ganti', true);
    if (!ok) return;
    E.swapBusy = true;
    try { await Api.call('adm_swap_question', { p_session: E.id, p_qid: q.id }); await refreshExam(null); toast('Soal diganti.'); }
    catch (e) { toast(e.message, true); }
    E.swapBusy = false;
  };

  /* Jeda mandiri (hanya sesi yang mengizinkan) */
  H.pause = async function () {
    var E = S.exam; if (!E || E.submitting || E.paused || E.discussing) return;
    await flushSave(); await flushTimes(E);
    try {
      await Api.call('app_pause', { p_session: E.id, p_action: 'start' });
      E.elapsed0 = elapsedNow(E); E.t0 = Date.now(); E.paused = true; E.away = null;
      renderExam();
    } catch (e) { toast(e.message, true); }
  };
  H.resume = async function () {
    var E = S.exam; if (!E || !E.paused) return;
    try {
      await Api.call('app_pause', { p_session: E.id, p_action: 'end' });
      E.paused = false; E.t0 = Date.now();
      renderExam(); awayCheck();
    } catch (e) { toast(e.message, true); }
  };

  function tickTimer(count) {
    var E = S.exam; if (!E) return;
    // waktu per soal: hanya saat soal dikerjakan (bukan saat meninjau kunci), jendela terlihat, dan jam berjalan
    if (count === true && !frozenClock(E) && !document.hidden && !E.submitting) {
      var q0 = E.qs[E.idx];
      if (q0 && !q0.locked && E.idx >= E.locked && !E.keys[q0.id]) { E.times[q0.id] = (E.times[q0.id] || 0) + 1; E.tdirty = true; }
    }
    updDclock(E);
    var xc = document.getElementById('xclock');
    if (xc && E.flow && E.flow.discussing) xc.textContent = clock((E.flow.since || 0) + (Date.now() - E.flowAt) / 1000);
    var el = document.getElementById('timer'); if (!el) return;
    var used = elapsedNow(E), tm = E.session.timer_minutes, fz = frozenClock(E);
    if (tm && modeInfo(E.session.feedback_mode).kind === 'block') {
      // timer berlaku untuk tiap bagian: jam bagian dimulai saat bagian terbuka dan tidak berjalan saat diskusi/jeda
      var tot = E.qs.length, bsec = tm * 60;
      if (E.blk == null) { el.textContent = E.locked >= tot ? 'Semua bagian selesai' : 'Menunggu bagian berikutnya'; el.className = 'timer' + (fz ? ' paused' : ''); return; }
      if (E.blk_start == null) { el.textContent = 'Menunggu bagian ' + E.blk + ' dibuka'; el.className = 'timer paused'; return; }
      var bl = E.blk_start + bsec - used;
      el.textContent = (fz ? 'Dijeda ' : 'Bagian ' + E.blk + ' · sisa ') + clock(bl);
      el.className = 'timer' + (fz ? ' paused' : (bl <= Math.min(300, bsec * 0.25) ? ' low' : (bl <= Math.min(600, bsec * 0.5) ? ' warn' : '')));
      if (!fz && !E.submitting) [600, 300, 60].forEach(function (t) {
        var wk = E.blk + ':' + t;
        if (t < bsec * 0.9 && bl <= t && bl > 0 && !E.warned[wk]) { E.warned[wk] = true; beep(); toast('Sisa waktu bagian ' + E.blk + ': ' + (t / 60) + ' menit.', t <= 60); }
      });
      if (bl <= 0 && !fz && !E.submitting && !E.blkBusy) {
        E.blkBusy = true; setTimeout(function () { E.blkBusy = false; }, 3000);
        pollRev();
      }
      return;
    }
    if (tm) {
      var left = tm * 60 - used;
      el.textContent = (fz ? 'Dijeda ' : 'Sisa waktu ') + clock(left);
      el.className = 'timer' + (fz ? ' paused' : (left <= 300 ? ' low' : (left <= 600 ? ' warn' : '')));
      if (!fz && !E.submitting) [600, 300, 60].forEach(function (t) {
        if (left <= t && left > 0 && !E.warned[t]) { E.warned[t] = true; beep(); toast('Sisa waktu ' + (t / 60) + ' menit.', t <= 60); }
      });
      if (left <= 0 && !fz && !E.submitting) {
        toast('Waktu habis. Jawabanmu dikumpulkan otomatis.');
        doSubmit(true);
      }
    } else {
      el.textContent = (fz ? 'Dijeda ' : 'Berjalan ') + clock(used);
      el.className = 'timer' + (fz ? ' paused' : '');
    }
  }

  function blockInfo(E, idx) {
    var mi = modeInfo(E.session.feedback_mode);
    if (mi.kind !== 'block') return null;
    var n = mi.n, total = E.qs.length, s0 = Math.floor(idx / n) * n, e0 = Math.min(s0 + n, total) - 1, left = 0;
    for (var i = s0; i <= e0; i++) if (!E.answers[E.qs[i].id]) left++;
    return { start: s0, end: e0, size: e0 - s0 + 1, left: left, locked: E.locked > e0, step: mi.step };
  }

  /* Panel nomor: kecil-kecil supaya 100+ soal terlihat; tiga penghitung besar (Dijawab, Bendera, Belum) bisa jadi penyaring */
  function navHtml(E) {
    var mi = modeInfo(E.session.feedback_mode), n = mi.kind === 'block' ? mi.n : 0, total = E.qs.length;
    var nAns = 0, nFlag = 0, nUn = 0, hasKeys = false, hasLock = false, f = E.navFilter;
    E.qs.forEach(function (x) {
      if (x.locked) { hasLock = true; return; }
      if (E.answers[x.id]) nAns++; else nUn++;
      if (E.flags[x.id]) nFlag++;
      if (E.keys[x.id]) hasKeys = true;
    });
    function stat(k, cls, num, label, icon) {
      return '<button type="button" class="stat3 ' + cls + (f === k ? ' on' : '') + '" data-act="nav-filter" data-v="' + k + '" aria-pressed="' + (f === k) + '">' +
        '<b>' + num + '</b><span>' + icon + label + '</span></button>';
    }
    function cell(i) {
      var x = E.qs[i], c = 'nav-n', a = E.answers[x.id], fl = E.flags[x.id], lab, kk;
      if (x.locked) { c += ' lk' + (f ? ' dim' : ''); lab = 'terkunci'; }
      else {
        if (a) c += ' ans';
        if (fl) c += ' flag';
        kk = E.keys[x.id];
        if (kk) c += kk === a ? ' right' : ' miss';
        if (f && !((f === 'ans' && a) || (f === 'flag' && fl) || (f === 'un' && !a))) c += ' dim';
        lab = (a ? 'sudah dijawab' : 'belum dijawab') + (fl ? ', ditandai bendera' : '') + (kk ? (kk === a ? ', benar' : ', salah') : '');
      }
      if (E.spot && E.spot.no === i + 1) c += ' spot';
      if (i === E.idx) c += ' cur';
      return '<button type="button" class="' + c + '" data-act="goto" data-v="' + i + '" aria-label="Soal ' + (i + 1) + ', ' + lab + (i === E.idx ? ', soal saat ini' : '') + '">' + (i + 1) + '</button>';
    }
    var body = '';
    if (n) {
      for (var s0 = 0; s0 < total; s0 += n) {
        var e0 = Math.min(s0 + n, total), got = 0, cells = '', lk = !!E.qs[s0].locked;
        for (var i = s0; i < e0; i++) { cells += cell(i); if (E.answers[E.qs[i].id]) got++; }
        body += '<div class="nav-grp"><div class="nav-gh"><span class="bold">Bagian ' + (s0 / n + 1) + ' <span class="muted">(' + (s0 + 1) + '-' + e0 + ')</span></span><span class="small ' + (e0 <= E.locked ? 'ok-t' : 'muted') + '">' +
          (lk ? 'Terkunci' : (e0 <= E.locked ? 'Selesai' : got + ' dari ' + (e0 - s0))) + '</span></div><div class="nav-grid">' + cells + '</div></div>';
      }
    } else {
      var all = ''; for (var j = 0; j < total; j++) all += cell(j);
      body = '<div class="nav-grid">' + all + '</div>';
    }
    var legend = '<div class="legend"><span><i class="nav-n ans sm">1</i>Dijawab</span><span><i class="nav-n sm">2</i>Belum dijawab</span>' +
      '<span><i class="nav-n flag sm">3</i>Belum, ada bendera</span><span><i class="nav-n ans flag sm">4</i>Dijawab, ada bendera</span>' +
      (hasKeys ? '<span><i class="nav-n right sm">5</i>Benar</span><span><i class="nav-n miss sm">6</i>Salah</span>' : '') +
      (hasLock ? '<span><i class="nav-n lk sm">7</i>Terkunci</span>' : '') + '</div>';
    return '<div class="nav-stats" role="group" aria-label="Ringkasan jawaban">' +
      stat('ans', 's-ans', nAns, 'Dijawab', '') + stat('flag', 's-flag', nFlag, 'Bendera', '<svg viewBox="0 0 24 24" width="13" height="13" aria-hidden="true"><path d="M5 21V3.5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" fill="none"/><path d="M5 4h13l-3 4.5 3 4.5H5z" fill="currentColor"/></svg> ') +
      stat('un', 's-un', nUn, 'Belum', '') + '</div>' +
      (f ? '<p class="small muted" style="margin-top:-6px">Nomor lain diredupkan. Klik lagi untuk menampilkan semua.</p>' : '') +
      '<div class="nav-body">' + body + '</div>' + legend;
  }

  function lockCard(E, q) {
    var mi = modeInfo(E.session.feedback_mode), n = mi.kind === 'block' ? mi.n : 0;
    var part = n ? Math.floor(E.idx / n) + 1 : null;
    return '<div class="lockcard">' + LOCK_SVG + '<h3>' + (part ? 'Bagian ' + part : 'Soal ini') + ' masih terkunci</h3>' +
      '<p class="muted">Bagian ini terbuka setelah bagian sebelumnya selesai' + (E.session.lock_mode === 'locked' ? ' dan admin membukanya (biasanya setelah diskusi)' : '') + '. Layar ini otomatis terbuka, tidak perlu memuat ulang.</p>' +
      (E.discussing ? '<p class="bold" style="color:var(--primary-dark)">Diskusi sedang berlangsung. Waktu dihentikan.</p>' : '') + '</div>';
  }

  function gateHtml(E) {
    if (!E.session.ketat || E.discussing || E.submitting || !fsSupported() || fsEl()) return '';
    return '<div class="overlay gate" role="dialog" aria-modal="true"><div class="modal"><h3>Mode ketat: masuk layar penuh</h3>' +
      '<p class="muted">Sesi ini memakai mode ketat. Ujian dikerjakan dalam layar penuh. Pindah tab, pindah aplikasi, atau keluar layar penuh akan tercatat dan bisa dilihat admin.</p>' +
      '<div class="acts"><button class="btn btn-primary" type="button" data-act="enter-fs">Masuk layar penuh</button></div></div></div>';
  }
  H['enter-fs'] = function () { requestFs(); };

  /* Status bagian untuk semua peserta + kendali diskusi untuk admin yang ikut mengerjakan */
  function partInner(E) {
    var mi = modeInfo(E.session.feedback_mode);
    if (mi.kind !== 'block' || E.session.kind === 'latihan') return '';
    var n = mi.n, total = E.qs.length, parts = Math.ceil(total / n), curP = Math.min(parts, Math.floor(E.locked / n) + 1);
    var firstQ = E.qs[Math.floor(E.locked / n) * n];
    var txt;
    if (E.locked >= total) txt = '<b>Semua bagian selesai.</b> Tekan Kumpulkan.';
    else if (firstQ && firstQ.locked) txt = '<b>Bagian ' + (curP - 1) + ' selesai.</b> Menunggu admin memulai diskusi dan membuka bagian ' + curP + '.';
    else txt = '<b>Bagian ' + curP + ' dari ' + parts + '</b> (soal ' + ((curP - 1) * n + 1) + '-' + Math.min(curP * n, total) + ')';
    if (E.bp && E.bp.all > 1) txt += ' · Yang sudah menyelesaikan bagian ' + E.bp.blk + ': <b>' + E.bp.done + ' dari ' + E.bp.all + '</b> peserta';
    return txt;
  }
  /* ---------- preferensi tampilan (disembunyikan/ditampilkan, diingat di perangkat) ---------- */
  function uiGet(k, def) { try { var o = JSON.parse(localStorage.getItem('cbt_ui') || '{}'); return o[k] == null ? def : o[k]; } catch (e) { return def; } }
  function uiSet(k, v) { try { var o = JSON.parse(localStorage.getItem('cbt_ui') || '{}'); o[k] = v; localStorage.setItem('cbt_ui', JSON.stringify(o)); } catch (e) { /* abaikan */ } }
  function isAdm() { return !!(S.me && S.me.role === 'admin'); }

  function adminBarInner(E) {
    var f = E.flow;
    if (!f) return '<span class="small">Memuat kendali admin...</span>';
    if (!E.ui.adm) {
      return '<span class="bold">Kendali admin</span>' + (f.discussing ? '<span class="small">Diskusi <b id="xclock">' + clock((f.since || 0) + (Date.now() - E.flowAt) / 1000) + '</b></span>' : '') +
        '<button class="btn btn-sm" type="button" data-act="adm-toggle">Tampilkan</button>';
    }
    var n = f.block, locked = f.lock_mode === 'locked' && n, hasNext = locked && f.unlocked_n < f.total;
    var nextNo = locked ? Math.floor(f.unlocked_n / n) + 1 : 0, a = f.unlocked_n + 1, b = Math.min(f.total, f.unlocked_n + (n || 0)), btns = '';
    if (!f.discussing) {
      btns += '<select id="xplan" class="input" style="height:34px;width:auto;padding:0 8px" data-change="xplan-pick" aria-label="Target durasi diskusi">' +
        [['', 'Tanpa batas'], ['300', '5 menit'], ['600', '10 menit'], ['900', '15 menit'], ['1200', '20 menit']].map(function (o) { return '<option value="' + o[0] + '"' + (E.xplan === o[0] ? ' selected' : '') + '>' + o[1] + '</option>'; }).join('') + '</select>' +
        '<button class="btn btn-sm btn-primary" type="button" data-act="xflow" data-a="start">Mulai diskusi</button>';
      if (hasNext) btns += '<button class="btn btn-sm" type="button" data-act="xflow" data-a="unlock">Buka bagian ' + nextNo + ' (soal ' + a + '-' + b + ') tanpa diskusi</button>';
    } else {
      btns += '<button class="btn btn-sm' + (hasNext ? '' : ' btn-primary') + '" type="button" data-act="xflow" data-a="end" data-u="0">Selesai diskusi</button>';
      if (hasNext) btns += '<button class="btn btn-sm btn-primary" type="button" data-act="xflow" data-a="end" data-u="1">Selesai diskusi dan buka bagian ' + nextNo + ' (soal ' + a + '-' + b + ')</button>';
    }
    return '<span class="bold">Kendali admin</span><span class="small">' + (f.discussing ? 'Diskusi berlangsung <b id="xclock">' + clock((f.since || 0) + (Date.now() - E.flowAt) / 1000) + '</b>' + (f.plan ? ' (target ' + clock(f.plan) + ')' : '') + ', waktu semua peserta berhenti' : 'Tidak sedang diskusi') +
      (locked ? ' · bagian terbuka: ' + Math.min(Math.ceil(f.unlocked_n / n), Math.ceil(f.total / n)) + ' dari ' + Math.ceil(f.total / n) : '') + '</span>' + btns +
      '<a class="btn btn-sm" href="#/admin/sesi">Panel peserta</a><button class="btn btn-sm" type="button" data-act="adm-toggle" title="Sembunyikan bilah ini">Sembunyikan</button>';
  }
  function updateBars(E) {
    var p = document.getElementById('partbar'); if (p) { var t = partInner(E); p.innerHTML = t; p.classList.toggle('hidden', !t); }
    var a = document.getElementById('adminbar');
    if (a) {
      var ae = document.activeElement;
      if (!(ae && ae.id === 'xplan')) { a.innerHTML = adminBarInner(E); a.classList.toggle('min', !E.ui.adm); }
    }
  }
  H['adm-toggle'] = function () { var E = S.exam; E.ui.adm = !E.ui.adm; uiSet('adm', E.ui.adm); updateBars(E); };
  H['nav-toggle'] = function () { var E = S.exam; E.ui.nav = !E.ui.nav; uiSet('nav', E.ui.nav); renderExam(); };
  H['xplan-pick'] = function (el) { if (S.exam) S.exam.xplan = el.value; };
  H.xflow = async function (el) {
    var E = S.exam; if (!E || !isAdm()) return;
    var act = el.dataset.a, u = el.dataset.u === '1';
    if (act === 'unlock') {
      var ok = await confirmDialog('Buka bagian berikutnya?', 'Semua peserta langsung bisa mengerjakan bagian berikutnya tanpa diskusi.', 'Buka', false);
      if (!ok) return;
    }
    el.disabled = true;
    try {
      await Api.call('adm_flow', { p_session: E.id, p_action: act, p_unlock: u, p_secs: act === 'start' && E.xplan ? parseInt(E.xplan, 10) : null });
      toast(act === 'start' ? 'Diskusi dimulai. Waktu semua peserta berhenti.' : act === 'end' ? (u ? 'Diskusi selesai dan bagian berikutnya dibuka.' : 'Diskusi selesai. Waktu berjalan lagi.') : 'Bagian berikutnya dibuka.');
      E.flow = await Api.call('adm_flow_state', { p_session: E.id }); E.flowAt = Date.now();
      await pollRev();
      if (S.exam === E) updateBars(E);
    } catch (e) { toast(e.message, true); el.disabled = false; }
  };

  /* ---------- bantuan diskusi: urutan bahas, "mau dibahas", sorotan admin, penjelas, pembahasan kelompok ---------- */
  function dkAvailable(E) {
    return E.session.kind !== 'latihan' && modeInfo(E.session.feedback_mode).kind === 'block' && !!(E.locked > 0 || E.discussing || E.spot);
  }
  function dsinceNow(E) { return (E.dsince0 || 0) + (Date.now() - E.dt0) / 1000; }
  function dclockText(E) {
    if (!E.discussing) return '';
    var since = dsinceNow(E);
    if (E.dplan) return since <= E.dplan ? 'sisa ' + clock(E.dplan - since) + ' dari target ' + clock(E.dplan) : 'lewat ' + clock(since - E.dplan) + ' dari target ' + clock(E.dplan);
    return 'berjalan ' + clock(since);
  }
  function updDclock(E) {
    var el = document.getElementById('dclock'); if (!el || !E.discussing) return;
    el.textContent = dclockText(E);
    if (E.dplan) {
      var over = dsinceNow(E) > E.dplan;
      el.classList.toggle('over', over);
      if (over && !E.dbeep) { E.dbeep = true; beep(); toast('Waktu diskusi yang direncanakan sudah habis.'); }
    }
  }
  function loadRecap(E, blk) {
    if (!E || E.rcBusy || !dkAvailable(E)) return Promise.resolve();
    E.rcBusy = true;
    return Api.call('app_block_recap', { p_session: E.id, p_block: blk || null }).then(function (r) {
      E.rcBusy = false;
      if (S.exam !== E) return;
      E.rc = r; E.rcAt = Date.now();
      updateDk(E);
    }).catch(function () { E.rcBusy = false; E.rcAt = Date.now(); });
  }
  function updateDk(E) {
    var el = document.getElementById('dkwrap'); if (!el) return;
    var ae = document.activeElement;
    if (ae && el.contains(ae) && (ae.tagName === 'SELECT' || ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT')) return;
    el.innerHTML = dkHtml(E);
  }
  function onSpot(E) {
    var sp = E.spot; if (!sp) return;
    beep();
    var i = sp.no - 1, q = E.qs[i], open = !!(q && !q.locked && (i < E.locked || E.keys[q.id]));
    toast('Admin membahas soal ' + sp.no + (sp.explainer ? '. Giliran menjelaskan: ' + sp.explainer + '.' : '.'));
    if (E.follow && open) { E.idx = i; E.panel = false; renderExam(); window.scrollTo(0, 0); peersFor(E); }
    else renderExam();
  }
  function dkHtml(E) {
    if (!dkAvailable(E)) return '';
    var adm = isAdm(), sp = E.spot;
    if (!E.ui.dk) return '<div class="dk dk-min"><button class="btn btn-sm" type="button" data-act="dk-toggle">Bantuan diskusi' + ((E.discussing || sp) ? ' <span class="pulse" aria-label="sedang aktif"></span>' : '') + '</button></div>';
    var rc = E.rc, rows = '', hot = 0;
    if (rc && rc.qs && rc.qs.length) {
      var list = rc.qs.slice().sort(function (a, b) {
        var pa = a.show && a.n ? pct(a.ok, a.n) : 101, pb = b.show && b.n ? pct(b.ok, b.n) : 101;
        return (pa - (a.hands || 0) * 12) - (pb - (b.hands || 0) * 12) || a.no - b.no;
      });
      rows = list.map(function (q) {
        var p = q.show && q.n ? pct(q.ok, q.n) : null, isSp = sp && sp.no === q.no;
        var mine = q.mine ? (q.show ? (q.mine === q.key ? '<span class="ok-t">benar (' + q.mine + ')</span>' : '<span class="bad-t">salah (' + q.mine + ', kunci ' + esc(q.key || '-') + ')</span>') : esc(q.mine)) : 'kosong';
        var tag = (p !== null && q.n >= 2 && p < 60 && hot < 3) ? (hot++, ' <span class="badge b-bad">Bahas dulu</span>') : '';
        return '<div class="dkrow' + (isSp ? ' sp' : '') + '"><button type="button" class="rk" data-act="dk-go" data-v="' + q.no + '" title="Buka soal ' + q.no + '">' + q.no + '</button>' +
          '<div class="grow col" style="gap:3px"><div class="small"><b>' + esc(q.sy) + '</b> · ' + esc(q.ty) + tag + (isSp ? ' <span class="badge b-spot">Sedang dibahas</span>' : '') + (q.expl ? ' <span class="badge b-info">Ada pembahasan</span>' : '') + '</div>' +
          (p === null ? '<span class="small muted">Kunci belum dibuka (mode satu per satu)</span>' : '<div class="bar ' + lvl(p) + '"><i style="width:' + p + '%"></i></div><div class="small muted">' + q.ok + ' dari ' + q.n + ' benar (' + p + '%) · jawabanmu ' + mine + '</div>') + '</div>' +
          '<button type="button" class="handbtn' + (q.my_hand ? ' on' : '') + '" data-act="dk-hand" data-v="' + q.no + '" aria-pressed="' + !!q.my_hand + '" title="Minta soal ini dibahas">✋' + (q.hands ? ' ' + q.hands : '') + '</button>' +
          (adm ? '<span class="col" style="gap:4px"><button class="btn btn-sm" type="button" data-act="dk-spot" data-v="' + q.no + '">Sorot</button><button class="btn btn-sm" type="button" data-act="dk-spot" data-v="' + q.no + '" data-pick="1">Penjelas</button></span>' : '') + '</div>';
      }).join('');
    }
    var sel = '';
    if (rc && rc.blocks > 1) { sel = '<select class="input" data-change="dk-block" aria-label="Pilih bagian" style="height:34px;width:auto;padding:0 8px">'; for (var i = 1; i <= rc.blocks; i++) sel += '<option value="' + i + '"' + (i === rc.block ? ' selected' : '') + '>Bagian ' + i + '</option>'; sel += '</select>'; }
    var spotLine = sp ? '<div class="spotline">📣 Sedang dibahas: <b>soal ' + sp.no + '</b>' + (sp.explainer ? ' · Giliran menjelaskan: <b>' + esc(sp.explainer) + '</b>' : '') +
      ' <button class="btn btn-sm" type="button" data-act="dk-go" data-v="' + sp.no + '">Ke soal ' + sp.no + '</button>' + (adm ? ' <button class="btn btn-sm" type="button" data-act="dk-unspot">Hentikan sorotan</button>' : '') + '</div>' : '';
    return '<div class="dk"><div class="row row-c between" style="gap:8px"><span class="bold">Bantuan diskusi' + (rc && rc.block ? ' · Bagian ' + rc.block : '') + '</span>' +
      '<span class="row row-c" style="gap:10px">' + sel + '<label class="small row row-c" style="gap:6px;flex-wrap:nowrap;cursor:pointer"><input type="checkbox" data-change="dk-follow"' + (E.follow ? ' checked' : '') + '>Ikuti sorotan admin</label>' +
      '<button class="btn btn-sm" type="button" data-act="dk-toggle">Sembunyikan</button></span></div>' + spotLine +
      (rc ? (rows ? '<span class="small muted">' + rc.final + ' dari ' + rc.all + ' peserta sudah menyelesaikan bagian ini. Diurutkan dari yang paling banyak salah. Tekan ✋ untuk meminta soal dibahas.</span><div class="dklist">' + rows + '</div>' : '<span class="small muted">Belum ada soal yang bisa dibahas. Selesaikan satu bagian dulu.</span>') : '<span class="small muted">Memuat...</span>') + '</div>';
  }
  H['dk-toggle'] = function () { var E = S.exam; E.ui.dk = !E.ui.dk; uiSet('dk', E.ui.dk); if (E.ui.dk) loadRecap(E, E.rcPick); updateDk(E); };
  H['dk-follow'] = function (el) { if (S.exam) S.exam.follow = el.checked; };
  H['dk-block'] = function (el) { var E = S.exam; E.rcPick = +el.value; loadRecap(E, E.rcPick); };
  H['dk-go'] = function (el) {
    var E = S.exam, i = +el.dataset.v - 1, q = E.qs[i];
    if (!q || q.locked) { toast('Soal ini belum bisa dibuka. Selesaikan bagiannya dulu.', true); return; }
    E.idx = i; E.panel = false; renderExam(); window.scrollTo(0, 0); peersFor(E);
  };
  H['dk-hand'] = async function (el) {
    var E = S.exam, no = +el.dataset.v, q = E.qs[no - 1]; if (!q || q.locked) return;
    var row = E.rc && E.rc.qs ? E.rc.qs.filter(function (r) { return r.no === no; })[0] : null, on = !(row && row.my_hand);
    try {
      var r = await Api.call('app_hand', { p_session: E.id, p_qid: q.id, p_on: on });
      if (row) { row.my_hand = on; row.hands = r.hands; }
      updateDk(E);
      var cur = E.qs[E.idx]; if (cur && cur.id === q.id) renderExam();
    } catch (e) { toast(e.message, true); }
  };
  H['dk-spot'] = async function (el) {
    var E = S.exam; if (!E || !isAdm()) return;
    el.disabled = true;
    try {
      var r = await Api.call('adm_flow', { p_session: E.id, p_action: 'spot', p_no: +el.dataset.v, p_pick: el.dataset.pick === '1' });
      toast('Soal ' + el.dataset.v + ' disorot' + (el.dataset.pick === '1' ? (r.explainer ? '. Penjelas: ' + r.explainer + '.' : '. Belum ada teman yang menjawab benar.') : '.'));
      await pollRev();
    } catch (e) { toast(e.message, true); }
    el.disabled = false;
  };
  H['dk-unspot'] = async function () {
    var E = S.exam; if (!E || !isAdm()) return;
    try { await Api.call('adm_flow', { p_session: E.id, p_action: 'unspot' }); await pollRev(); } catch (e) { toast(e.message, true); }
  };
  H['expl-save'] = async function (el) {
    var E = S.exam; if (!E || !isAdm()) return;
    var ta = document.getElementById('explta'); if (!ta) return;
    try {
      await Api.call('adm_set_expl', { p_qid: el.dataset.v, p_body: ta.value });
      var pe = E.peers[el.dataset.v] || (E.peers[el.dataset.v] = { n: 0, ok: 0, d: {}, at: Date.now() });
      pe.e = ta.value.trim() || null; E.rcAt = 0;
      toast(pe.e ? 'Pembahasan kelompok disimpan.' : 'Pembahasan dihapus.');
      renderExam(); loadRecap(E, E.rcPick);
    } catch (e) { toast(e.message, true); }
  };

  function headHtml(E, total) {
    return '<div class="exam-head"><div class="col" style="gap:0"><span class="small bold muted">' + (E.session.kind === 'latihan' ? 'Latihan pribadi' : 'Sesi') + '</span><span class="bold" style="font-size:18px">' + esc(E.session.title) + '</span></div>' +
      '<div class="row row-c" style="gap:14px"><span class="bold">Soal ' + (E.idx + 1) + ' dari ' + total + '</span>' +
      (E.session.ketat ? '<span class="badge b-warn" id="violbadge" title="Mode ketat: keluar halaman dicatat">Mode ketat' + (E.viol ? ' · ' + E.viol + ' pelanggaran' : '') + '</span>' : '') +
      '<span id="timer" class="timer">--:--</span>' +
      '<span class="small muted" id="savestate" role="status">' + esc(E.saveState) + '</span>' +
      (E.session.allow_pause && !E.discussing && !E.paused ? '<button class="btn btn-sm" type="button" data-act="pause" title="Hentikan waktu sebentar. Soal disembunyikan selama jeda.">Jeda</button>' : '') +
      '<button class="btn btn-primary" type="button" data-act="exam-submit"' + (E.submitting ? ' disabled' : '') + '>Kumpulkan</button></div></div>' +
      '<div id="savebanner" class="alert-bar hidden" role="alert"></div>' +
      (E.paused ? '' : '<div id="partbar" class="part-bar' + (partInner(E) ? '' : ' hidden') + '" role="status">' + partInner(E) + '</div>' +
        (S.me && S.me.role === 'admin' && E.session.kind !== 'latihan' ? '<div id="adminbar" class="admin-bar">' + adminBarInner(E) + '</div>' : ''));
  }

  function stemHtml(E, q) {
    var hl = E.hl[q.id] || [], i = 0;
    return esc(q.stem).replace(/(\S+)/g, function (m) {
      var k = i++;
      return '<span class="w' + (hl.indexOf(k) >= 0 ? ' hi' : '') + '" data-act="hl" data-v="' + k + '">' + m + '</span>';
    });
  }

  function renderExam() {
    var E = S.exam; if (!E) return;
    var total = E.qs.length;
    if (E.paused) {
      root.innerHTML = headHtml(E, total) + '<div class="exam-body"><div class="exam-main"><div class="qcard pausecard"><h2 class="bold" style="font-size:22px">Sesi dijeda</h2>' +
        '<p class="muted">Waktu berhenti dan soal disembunyikan. Tekan Lanjutkan kalau sudah siap.</p>' +
        '<div><button class="btn btn-primary" style="height:50px" type="button" data-act="resume">Lanjutkan mengerjakan</button></div></div></div></div>';
      setBanner(E); tickTimer();
      return;
    }
    var q = cur(), lockedQ = !!q.locked, disc = E.discussing;
    var side0 = root.querySelector('.exam-side'), sideTop = side0 ? side0.scrollTop : 0;
    var answeredN = 0;
    E.qs.forEach(function (x) { if (!x.locked && E.answers[x.id]) answeredN++; });
    var key = E.keys[q.id], sel = E.answers[q.id];
    var letters = ['A', 'B', 'C', 'D', 'E'];
    var img = lockedQ ? null : safeImg(q.image);
    var frozen = !!(key || E.submitting || E.idx < E.locked || disc);
    var pe = (!lockedQ && key && E.session.kind !== 'latihan') ? E.peers[q.id] : null;
    if (pe && !(pe.n >= 2)) pe = null;
    var elim = E.elim[q.id] || {};

    var opts = lockedQ ? '' : q.options.map(function (t, i) {
      var L = letters[i], cls = '', tag = '';
      if (key) {
        if (L === key) { cls = 'key'; tag = sel === key ? 'Kunci (jawabanmu)' : 'Kunci'; }
        else if (L === sel) { cls = 'wrong'; tag = 'Jawabanmu'; }
      } else if (L === sel) cls = 'sel';
      var btn = '<button type="button" class="opt ' + cls + '" data-act="pick" data-v="' + L + '" data-l="' + L + '"' + (frozen ? ' disabled' : '') +
        ' aria-pressed="' + (L === sel) + '"><span class="l">' + L + '</span><span class="t">' + esc(t) + '</span>' +
        (pe ? '<span class="pc" title="Peserta yang memilih ' + L + '">' + pct((pe.d || {})[L] || 0, pe.n) + '%</span>' : '') +
        (tag ? '<span class="tag">' + tag + '</span>' : '') + '</button>';
      var eb = key ? '' : '<button type="button" class="elimbtn' + (elim[L] ? ' on' : '') + '" data-act="elim" data-v="' + L + '" aria-pressed="' + !!elim[L] + '" title="' + (elim[L] ? 'Batalkan coretan' : 'Coret pilihan ini') + '" aria-label="' + (elim[L] ? 'Batalkan coretan pilihan ' : 'Coret pilihan ') + L + '"' + (E.submitting ? ' disabled' : '') + '>' + (elim[L] ? '↺' : '✕') + '</button>';
      return '<div class="optrow' + (elim[L] && !key ? ' elim' : '') + '">' + btn + eb + '</div>';
    }).join('');

    var status = '';
    if (key) status = sel === key ? '<span class="badge b-ok">Benar</span>' : '<span class="badge b-bad">Salah</span>';
    var peerChip = pe ? '<span class="chip chip-peer" title="Dari peserta yang sudah menyelesaikan soal ini">' + pct(pe.ok, pe.n) + '% peserta benar · ' + pe.ok + ' dari ' + pe.n + '</span>' : '';
    var spotTag = (E.spot && E.spot.no === E.idx + 1) ? '<span class="badge b-spot">📣 Sedang dibahas' + (E.spot.explainer ? ' · penjelas: ' + esc(E.spot.explainer) : '') + '</span>' : '';
    var hrow = (!lockedQ && key && E.rc && E.rc.qs) ? E.rc.qs.filter(function (r) { return r.no === E.idx + 1; })[0] : null;
    var handBtn = hrow ? '<button type="button" class="handbtn' + (hrow.my_hand ? ' on' : '') + '" data-act="dk-hand" data-v="' + (E.idx + 1) + '" aria-pressed="' + !!hrow.my_hand + '" title="Minta soal ini dibahas">✋' + (hrow.hands ? ' ' + hrow.hands : '') + '</button>' : '';
    var exTxt = (!lockedQ && key) ? ((E.peers[q.id] || {}).e || '') : '';
    var exBox = (!lockedQ && key) ? ((exTxt ? '<div class="expl"><b>Pembahasan kelompok</b><p>' + esc(exTxt) + '</p></div>' : '') +
      (isAdm() ? '<details class="notebox"><summary>' + (exTxt ? 'Ubah' : 'Tulis') + ' pembahasan kelompok (admin)</summary><textarea class="input" rows="3" maxlength="3000" id="explta" placeholder="Pembahasan singkat. Tampil ke semua peserta setelah kunci terbuka dan di Tinjau." aria-label="Pembahasan kelompok">' + esc(exTxt) + '</textarea>' +
        '<div class="row" style="gap:8px;margin-top:6px"><button class="btn btn-sm btn-primary" type="button" data-act="expl-save" data-v="' + q.id + '">Simpan pembahasan</button></div></details>' : '')) : '';
    var bi = blockInfo(E, E.idx), blockMsg = '', finBar = '';
    if (bi && !key && !lockedQ) {
      if (E.idx < E.locked) blockMsg = '<div class="notice">Blok ini sudah diselesaikan. <button class="btn btn-sm btn-primary" type="button" data-act="show-key">Lihat jawaban nomor ' + (E.idx + 1) + '</button></div>';
      else blockMsg = '<div class="notice">Kunci blok soal ' + (bi.start + 1) + ' sampai ' + (bi.end + 1) + ' tampil setelah blok diselesaikan.</div>';
    }
    if (bi && E.locked < total) {
      var nb = blockInfo(E, E.locked);
      if (E.qs[nb.start] && E.qs[nb.start].locked) {
        finBar = '<div class="notice">Bagian ' + (Math.floor(nb.start / modeInfo(E.session.feedback_mode).n) + 1) + ' (soal ' + (nb.start + 1) + ' sampai ' + (nb.end + 1) + ') belum dibuka. Menunggu admin, biasanya setelah diskusi.</div>';
      } else {
        finBar = '<div class="notice" style="display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap"><span>Blok soal ' + (nb.start + 1) + ' sampai ' + (nb.end + 1) + ': <b>' + (nb.size - nb.left) + ' dari ' + nb.size + '</b> terjawab' + (nb.left === 0 ? '. Siap diselesaikan.' : '.') + '</span>' +
          '<button class="btn btn-sm' + (nb.left === 0 ? ' btn-primary' : '') + '" type="button" data-act="fin-block"' + (E.finBusy ? ' disabled' : '') + '>Selesaikan blok ' + (nb.start + 1) + ' sampai ' + (nb.end + 1) + '</button></div>';
      }
    } else if (bi && E.locked >= total) {
      finBar = '<div class="notice">Semua blok sudah diselesaikan. Tekan Kumpulkan untuk mengakhiri sesi.</div>';
    }

    var flagged = !!E.flags[q.id], flagOff = lockedQ || E.submitting || E.idx < E.locked;
    var flagBtn = '<button type="button" class="flagbtn' + (flagged ? ' on' : '') + '" data-act="flag" aria-pressed="' + flagged + '" title="' + (flagged ? 'Hapus bendera (tombol F)' : 'Beri bendera merah (tombol F)') +
      '" aria-label="' + (flagged ? 'Hapus bendera dari soal ini' : 'Beri bendera pada soal ini') + '"' + (flagOff ? ' disabled' : '') + '>' + FLAG_SVG + '</button>';
    var hlBtn = '<button type="button" class="flagbtn hlbtn' + (E.hlOn ? ' on' : '') + '" data-act="hl-mode" aria-pressed="' + E.hlOn + '" title="Stabilo: aktifkan, lalu ketuk kata di soal untuk menyorot" aria-label="Stabilo teks soal">' + MARK_SVG + '</button>';

    var noteTxt = E.notes[q.id] || '';
    var noteOpen = E.noteOpen[q.id] != null ? E.noteOpen[q.id] : !!noteTxt;
    var noteHtml = lockedQ ? '' : '<details class="notebox"' + (noteOpen ? ' open' : '') + '><summary data-act="note-toggle">Catatan saya' + (noteTxt ? ' <span class="dot-on" aria-label="ada catatan"></span>' : '') + '</summary>' +
      '<textarea class="input" rows="3" maxlength="2000" placeholder="Catatan untuk soal ini (hanya kamu yang melihat)" aria-label="Catatan pribadi" data-input="note-input" data-change="note-flush" data-v="' + q.id + '">' + esc(noteTxt) + '</textarea>' +
      '<span class="small muted">Tersimpan otomatis. Soal bercatatan bisa dilatih ulang di menu Latihan.</span></details>';

    var qHtml = lockedQ ? lockCard(E, q) :
      '<div class="row row-c qhead"><span class="chip">Asal file: ' + esc(q.file || q.bank) + '</span><span class="qno">Soal ' + (E.idx + 1) + '</span>' + flagBtn + hlBtn + handBtn + status + peerChip + spotTag + '</div>' +
      '<p class="stem' + (E.hlOn ? ' hlmode' : '') + '">' + stemHtml(E, q) + '</p>' + (img ? '<img class="qimg zoomable" data-act="zoom" src="' + img + '" alt="Gambar pada soal (ketuk untuk memperbesar)">' : '') +
      '<div class="opts" role="group" aria-label="Pilihan jawaban">' + opts + '</div>' + blockMsg + finBar + exBox + noteHtml;
    if (lockedQ && finBar.indexOf('belum dibuka') < 0) qHtml += finBar;

    root.innerHTML = headHtml(E, total) +
      (disc ? '<div class="discuss-bar" role="status"><b>Diskusi sedang berlangsung</b> <span id="dclock" class="dclock">' + dclockText(E) + '</span>. Waktu dihentikan sementara dan jawaban tidak bisa diubah. Soal dan kunci yang sudah terbuka tetap bisa dilihat.</div>' : '') +
      '<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="' + total + '" aria-valuenow="' + answeredN + '"><i style="width:' + pct(answeredN, total) + '%"></i></div>' +
      '<div class="exam-body"><div class="exam-main"><div id="dkwrap">' + dkHtml(E) + '</div><div class="qcard">' + qHtml + '</div>' +
      '<div class="nav-actions exam-foot"><button class="btn" type="button" data-act="prev"' + (E.idx === 0 ? ' disabled' : '') + '>Sebelumnya</button>' +
      (S.me && S.me.role === 'admin' && !lockedQ && E.session.kind !== 'latihan' ? '<button class="btn btn-danger" type="button" data-act="swap">Ganti soal ini</button>' : '') +
      '<button class="btn only-mobile" type="button" data-act="panel">Daftar soal</button>' +
      '<button class="btn btn-primary" type="button" data-act="next"' + (E.idx === total - 1 ? ' disabled' : '') + '>Selanjutnya</button></div></div>' +
      (E.ui.nav
        ? '<aside class="exam-side' + (E.panel ? '' : ' closed') + '" aria-label="Navigasi soal"><div class="row row-c between" style="gap:8px"><span class="bold" style="font-size:16px">Navigasi soal</span><button class="btn btn-sm" type="button" data-act="nav-toggle" title="Sembunyikan daftar nomor">Sembunyikan</button></div>' +
          navHtml(E) + '<p class="small muted">' + esc(fbLabel(E.session.feedback_mode)) + '. Jawaban tersimpan otomatis.</p></aside>'
        : '<aside class="exam-side min' + (E.panel ? '' : ' closed') + '" aria-label="Navigasi soal"><button class="btn btn-sm" type="button" data-act="nav-toggle">Tampilkan daftar soal</button><span class="small muted">' + E.qs.filter(function (x) { return !x.locked && E.answers[x.id]; }).length + ' dari ' + total + ' terjawab</span></aside>') +
      '</div>' + gateHtml(E);
    var side = root.querySelector('.exam-side');
    if (side) {
      side.scrollTop = sideTop;
      var c = side.querySelector('.nav-n.cur');
      if (c && (c.offsetTop < side.scrollTop + 150 || c.offsetTop > side.scrollTop + side.clientHeight - 60)) side.scrollTop = Math.max(0, c.offsetTop - side.clientHeight / 2);
    }
    setBanner(E);
    tickTimer();
  }

  function onExamKey(e) {
    var E = S.exam; if (!E || e.ctrlKey || e.metaKey || e.altKey) return;
    var tg = e.target && e.target.tagName;
    if (tg === 'INPUT' || tg === 'TEXTAREA' || tg === 'SELECT') return;
    if (document.querySelector('.overlay') || document.querySelector('.zoomov') || E.paused) return;
    var k = e.key;
    if (k === 'ArrowRight') { H.next(); e.preventDefault(); }
    else if (k === 'ArrowLeft') { H.prev(); e.preventDefault(); }
    else if (k === 'f' || k === 'F') { H.flag(); }
    else if (/^[a-eA-E]$/.test(k)) { pickLetter(k.toUpperCase()); }
    else if (/^[1-5]$/.test(k)) { pickLetter('ABCDE'.charAt(+k - 1)); }
  }

  function focusOpt(L) { var b = root.querySelector('.opt[data-l="' + L + '"]'); if (b) b.focus(); }

  function pickLetter(L) {
    var E = S.exam; if (!E || E.submitting) return;
    var q = cur();
    if (q.locked || E.keys[q.id] || E.idx < E.locked) return;
    if (E.discussing) { toast('Sedang diskusi. Jawaban tidak bisa diubah sampai diskusi selesai.'); return; }
    if (q.options.length <= 'ABCDE'.indexOf(L)) return;
    if (E.answers[q.id] === L) delete E.answers[q.id]; else E.answers[q.id] = L;
    renderExam(); focusOpt(L);
    queueSave();
    maybeReveal();
  }
  H.pick = function (el) { pickLetter(el.dataset.v); };
  H.goto = function (el) { S.exam.idx = +el.dataset.v; S.exam.panel = false; renderExam(); window.scrollTo(0, 0); peersFor(S.exam); };
  H.next = function () { var E = S.exam; if (E && E.idx < E.qs.length - 1) { E.idx++; renderExam(); window.scrollTo(0, 0); peersFor(E); } };
  H.prev = function () { var E = S.exam; if (E && E.idx > 0) { E.idx--; renderExam(); window.scrollTo(0, 0); peersFor(E); } };
  H.panel = function () { var E = S.exam; E.panel = !E.panel; if (E.panel && !E.ui.nav) { E.ui.nav = true; uiSet('nav', true); } renderExam(); };
  H['nav-filter'] = function (el) { var E = S.exam; E.navFilter = E.navFilter === el.dataset.v ? '' : el.dataset.v; renderExam(); };
  H.flag = function () {
    var E = S.exam; if (!E || E.submitting || E.paused) return;
    var q = cur();
    if (q.locked || E.idx < E.locked) return;
    if (E.flags[q.id]) delete E.flags[q.id]; else E.flags[q.id] = true;
    renderExam(); queueSave();
  };
  H.elim = function (el) {
    var E = S.exam, q = cur(); if (!E || q.locked) return;
    var m = E.elim[q.id] || (E.elim[q.id] = {}), L = el.dataset.v;
    if (m[L]) delete m[L]; else m[L] = true;
    lsSet('elim', E.id, E.elim);
    renderExam();
  };
  H['hl-mode'] = function () { var E = S.exam; E.hlOn = !E.hlOn; renderExam(); };
  H.hl = function (el) {
    var E = S.exam; if (!E || !E.hlOn) return;
    var q = cur(), a = E.hl[q.id] || (E.hl[q.id] = []), i = +el.dataset.v, k = a.indexOf(i);
    if (k < 0) a.push(i); else a.splice(k, 1);
    lsSet('hl', E.id, E.hl);
    renderExam();
  };
  H['note-toggle'] = function (el) {
    var E = S.exam, q = cur(); if (!E) return;
    var d = el.parentNode; E.noteOpen[q.id] = !(d && d.open);
  };
  function saveNote(E, id) {
    clearTimeout(E.noteT);
    return Api.call('app_note_set', { p_qid: id, p_body: E.notes[id] || '' }).catch(function (e) { toast('Catatan belum tersimpan: ' + e.message, true); });
  }
  H['note-input'] = function (el) {
    var E = S.exam; if (!E) return;
    var id = el.dataset.v; E.notes[id] = el.value; E.noteOpen[id] = true;
    clearTimeout(E.noteT); E.noteT = setTimeout(function () { saveNote(E, id); }, 900);
  };
  H['note-flush'] = function (el) { var E = S.exam; if (!E) return; var id = el.dataset.v; E.notes[id] = el.value; saveNote(E, id); };
  H.zoom = function (el) { openZoom(el.getAttribute('src')); };
  function openZoom(src) {
    var ov = document.createElement('div');
    ov.className = 'zoomov';
    ov.innerHTML = '<img alt="Gambar diperbesar"><button type="button" class="btn zoomx" aria-label="Tutup">Tutup</button>';
    ov.querySelector('img').src = src;
    function onKey(e) { if (e.key === 'Escape') close(); }
    function close() { document.removeEventListener('keydown', onKey, true); if (ov.parentNode) ov.parentNode.removeChild(ov); }
    ov.addEventListener('click', function (e) { if (e.target.tagName === 'IMG') ov.classList.toggle('full'); else close(); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(ov);
  }

  function setSaveState(t) {
    var E = S.exam; if (!E) return;
    E.saveState = t;
    var el = document.getElementById('savestate'); if (el) el.textContent = t;
  }
  function queueSave() {
    var E = S.exam; if (!E) return;
    E.dirty = true;
    lsSet('bk', E.id, { t: Date.now(), a: E.answers, f: E.flags });
    setSaveState('Menyimpan...');
    clearTimeout(E.saveT);
    E.saveT = setTimeout(flushSave, 600);
  }
  function flushSave() {
    var E = S.exam; if (!E) return Promise.resolve();
    clearTimeout(E.saveT);
    E.chain = E.chain.then(async function () {
      if (!E.dirty || S.exam !== E) return;
      E.dirty = false;
      try {
        await Api.call('app_save', { p_session: E.id, p_answers: E.answers, p_flags: E.flags });
        setSaveState('Tersimpan');
        if (E.saveFail) { E.saveFail = false; setBanner(E); }
      } catch (err) {
        E.dirty = true;
        if (err.code === '28000') { toast('Sesi login berakhir. Masuk lagi untuk melanjutkan.', true); return; }
        setSaveState('Gagal menyimpan, mencoba lagi...');
        E.saveFail = true; setBanner(E);
        clearTimeout(E.saveT);
        E.saveT = setTimeout(flushSave, 5000);
      }
    });
    return E.chain;
  }

  async function maybeReveal() {
    var E = S.exam; if (!E) return;
    var mi = modeInfo(E.session.feedback_mode);
    if (mi.kind === 'end') return;
    if (mi.kind === 'each') {
      var q = cur();
      if (E.answers[q.id] && !E.keys[q.id]) {
        await flushSave();
        try {
          var k = await Api.call('app_reveal', { p_session: E.id, p_qids: [q.id] });
          if (S.exam !== E) return;
          Object.assign(E.keys, k);
          renderExam();
          peersFor(E);
        } catch (err) { toast(err.message, true); }
      }
      return;
    }
    var bi = blockInfo(E, E.idx);
    if (bi && !bi.locked && bi.left === 0 && E.notified !== bi.start) {
      E.notified = bi.start;
      beep();
      toast('Soal ' + (bi.start + 1) + ' sampai ' + (bi.end + 1) + ' sudah terjawab semua. Tekan "Selesaikan blok" kalau sudah yakin.');
      try { if (document.hidden && window.Notification && Notification.permission === 'granted') new Notification('Ruang Ujian', { body: 'Blok soal ' + (bi.start + 1) + ' sampai ' + (bi.end + 1) + ' sudah terjawab semua.' }); } catch (e2) { /* abaikan */ }
    }
  }

  H['exam-submit'] = async function () {
    var E = S.exam; if (!E || E.submitting) return;
    var un = E.qs.filter(function (q) { return !E.answers[q.id]; }).length;
    var fl = E.qs.filter(function (q) { return E.flags[q.id]; }).length;
    var lk = E.qs.filter(function (q) { return q.locked; }).length;
    var parts = [];
    if (lk) parts.push(lk + ' soal belum dibuka admin');
    if (un - lk > 0) parts.push((un - lk) + ' soal belum dijawab');
    if (fl) parts.push(fl + ' soal diberi bendera');
    var ok = await confirmDialog('Kumpulkan jawaban?', (parts.length ? parts.join(', ') + '. ' : 'Semua soal sudah dijawab. ') + 'Setelah dikumpulkan, jawaban tidak bisa diubah.', 'Kumpulkan', false);
    if (ok) doSubmit(false);
  };

  async function doSubmit(auto) {
    var E = S.exam; if (!E || E.submitting) return;
    E.submitting = true;
    renderExam();
    try {
      await flushSave();
      await flushTimes(E);
      await Api.call('app_submit', { p_session: E.id, p_answers: E.answers, p_flags: E.flags });
      var id = E.id;
      lsDel('bk', id);
      S.exam = null;
      go('#/hasil/' + id);
    } catch (err) {
      E.submitting = false;
      renderExam();
      toast(err.message, true);
      if (auto) setTimeout(function () { if (S.exam === E) doSubmit(true); }, 5000);
    }
  }

  /* ---------- mode ketat: deteksi keluar halaman ujian ---------- */
  function logViol(E, kind, secs, update) {
    E.vchain = E.vchain.then(function () {
      return Api.call('app_violation', { p_session: E.id, p_kind: kind, p_secs: secs, p_update: update });
    }).catch(noop);
  }
  function awayCheck() {
    var E = S.exam; if (!E || !E.session.ketat || E.submitting) return;
    if (fsEl()) E.fsSeen = true;
    var out = document.hidden || !document.hasFocus() || (E.fsSeen && fsSupported() && !fsEl());
    if (out && !E.away) {
      var kind = document.hidden ? 'tab' : (!document.hasFocus() ? 'blur' : 'fullscreen');
      E.away = { t: Date.now(), kind: kind, counted: !E.discussing };
      if (E.away.counted) { E.viol++; logViol(E, kind, 0, false); var vb = document.getElementById('violbadge'); if (vb) vb.textContent = 'Mode ketat · ' + E.viol + ' pelanggaran'; }
    } else if (!out && E.away) {
      var a = E.away; E.away = null;
      var secs = Math.round((Date.now() - a.t) / 1000);
      if (a.counted) {
        logViol(E, a.kind, secs, true);
        var msg = 'Kamu meninggalkan halaman ujian selama ' + (secs >= 60 ? Math.floor(secs / 60) + ' menit ' + (secs % 60) + ' detik' : secs + ' detik') + '. Kejadian ini tercatat dan terlihat oleh admin.';
        if (document.querySelector('.overlay')) toast(msg, true);
        else dialog({ title: 'Mode ketat: terdeteksi keluar halaman', text: msg, buttons: [{ label: 'Kembali ke ujian', value: true, cls: 'btn-primary' }] });
      }
    }
  }
  function installStrict(E) {
    function later() { setTimeout(awayCheck, 150); }
    function onFs() { if (fsEl()) E.fsSeen = true; if (S.exam === E) { renderExam(); later(); } }
    function block(e) { if (S.exam === E) e.preventDefault(); }
    window.addEventListener('blur', later);
    window.addEventListener('focus', later);
    document.addEventListener('visibilitychange', awayCheck);
    document.addEventListener('fullscreenchange', onFs);
    document.addEventListener('webkitfullscreenchange', onFs);
    ['contextmenu', 'copy', 'cut', 'dragstart'].forEach(function (ev) { document.addEventListener(ev, block); });
    root.classList.add('strict');
    onCleanup(function () {
      window.removeEventListener('blur', later);
      window.removeEventListener('focus', later);
      document.removeEventListener('visibilitychange', awayCheck);
      document.removeEventListener('fullscreenchange', onFs);
      document.removeEventListener('webkitfullscreenchange', onFs);
      ['contextmenu', 'copy', 'cut', 'dragstart'].forEach(function (ev) { document.removeEventListener(ev, block); });
      root.classList.remove('strict');
      if (fsEl()) exitFs();
    });
  }
  H['start-exam'] = async function (el) {
    var id = el.dataset.v;
    if (el.dataset.new === '1') {
      var ok = await confirmDialog('Mulai sesi dengan mode ketat?', 'Ujian berjalan dalam layar penuh. Pindah tab, pindah aplikasi, atau keluar layar penuh akan tercatat dan terlihat oleh admin. Selama diskusi pencatatan dihentikan.', 'Mulai', false);
      if (!ok) return;
    }
    requestFs();
    go('#/ujian/' + id);
  };

  /* ---------- latihan pribadi: ulang soal salah / bendera / catatan / soal baru ---------- */
  var DR = { kind: 'mix', sys: '', count: 20 };
  async function drillView() {
    shell('latihan');
    var ok = fresh();
    await guard(async function () {
      var r = await Promise.all([Api.call('app_drill_stats'), Api.call('app_notes')]);
      if (!ok()) return;
      S.dr = { st: r[0], notes: r[1] };
      renderDrill();
    });
  }
  function renderDrill() {
    var st = S.dr.st, notes = S.dr.notes;
    var kinds = [['mix', 'Campuran: salah + bendera + catatan', st.mix], ['wrong', 'Terakhir salah atau kosong', st.wrong], ['flag', 'Terakhir diberi bendera', st.flag],
      ['note', 'Soal bercatatan', st.note], ['fresh', 'Belum pernah dikerjakan', st.fresh]];
    var pool = kinds.filter(function (k) { return k[0] === DR.kind; })[0][2];
    var mp = pct(st.mastered, st.ever_wrong);
    var tile = function (n, label, hint) { return '<div class="stat" style="padding:16px"><span class="small muted">' + label + '</span><strong style="font-size:28px;font-weight:800">' + n + '</strong><span class="small muted">' + hint + '</span></div>'; };
    var sysOpts = '<option value="">Semua sistem</option>' + (st.systems || []).map(function (x) { return '<option value="' + esc(x) + '"' + (DR.sys === x ? ' selected' : '') + '>' + esc(x) + '</option>'; }).join('');
    var drills = (st.drills || []).map(function (d) {
      var act = d.done ? '<a class="btn btn-sm" href="#/hasil/' + d.id + '">Hasil</a><a class="btn btn-sm" href="#/tinjau/' + d.id + '">Tinjau</a>'
        : '<a class="btn btn-sm btn-primary" href="#/ujian/' + d.id + '">' + (d.started ? 'Lanjutkan' : 'Mulai') + '</a>';
      return '<div class="row row-c between" style="gap:10px;border-top:1px solid var(--line-2);padding-top:10px"><span class="col" style="gap:0"><span class="bold">' + esc(d.title) + '</span><span class="small muted">' + d.total + ' soal' + (d.done ? ' · skor ' + d.score + ' dari ' + d.total : '') + '</span></span>' +
        '<span class="row row-c" style="gap:8px">' + act + '<button class="btn btn-sm btn-danger" type="button" data-act="drill-del" data-v="' + d.id + '" aria-label="Hapus latihan">Hapus</button></span></div>';
    }).join('');
    var noteList = notes.map(function (n) {
      return '<div class="col" style="gap:6px;border-top:1px solid var(--line-2);padding-top:10px"><div class="row row-c" style="gap:8px"><span class="chip">' + esc(n.system) + '</span><span class="chip chip-alt">' + esc(n.qtype) + '</span>' +
        '<span class="small muted">' + esc(new Date(n.at).toLocaleDateString('id-ID')) + '</span><button class="btn btn-sm" type="button" style="margin-left:auto" data-act="note-del" data-v="' + n.qid + '">Hapus catatan</button></div>' +
        '<p class="small muted" style="margin:0">' + esc(n.stem) + (n.stem.length >= 240 ? '...' : '') + '</p><p class="notetxt">' + esc(n.body) + '</p></div>';
    }).join('');
    setMain('<div class="col" style="gap:4px"><h1 class="page-title">Latihan</h1><p class="page-sub">Ulangi soal yang pernah salah, bendera, bercatatan, atau soal yang belum pernah kamu kerjakan. Kunci tampil per nomor, tanpa timer, tidak masuk peringkat.</p></div>' +
      '<div class="card"><div class="row between row-c" style="gap:10px"><h2 class="bold" style="font-size:18px">Perkembangan menguasai soal salah</h2><span class="bold">' + st.mastered + ' dari ' + st.ever_wrong + ' (' + mp + '%)</span></div>' +
      '<div class="bar ' + lvl(mp) + '"><i style="width:' + mp + '%"></i></div><p class="small muted">Soal dianggap dikuasai kalau pernah salah, tetapi jawaban terakhirnya benar. Soal yang masih salah tetap muncul di latihan.</p></div>' +
      '<div class="row">' + tile(st.wrong, 'Perlu diulang', 'terakhir salah atau kosong') + tile(st.flag, 'Ber-bendera', 'terakhir diberi bendera') + tile(st.note, 'Bercatatan', 'soal dengan catatanmu') + tile(st.fresh, 'Belum pernah', 'soal yang belum kamu kerjakan') + '</div>' +
      '<div class="card"><h2 class="bold" style="font-size:18px">Buat latihan</h2><div class="row" style="gap:12px">' +
      '<div class="field grow" style="flex:2 1 260px"><label for="dk">Sumber soal</label><select id="dk" class="input" data-change="drill-pick" data-k="kind">' + kinds.map(function (k) { return '<option value="' + k[0] + '"' + (DR.kind === k[0] ? ' selected' : '') + '>' + k[1] + ' (' + k[2] + ')</option>'; }).join('') + '</select></div>' +
      '<div class="field grow" style="flex:1 1 200px"><label for="ds">Sistem</label><select id="ds" class="input" data-change="drill-pick" data-k="sys">' + sysOpts + '</select></div>' +
      '<div class="field" style="flex:0 1 120px"><label for="dn">Jumlah soal</label><input id="dn" class="input" type="number" min="5" max="100" value="' + DR.count + '" data-change="drill-pick" data-k="count"></div></div>' +
      '<div class="row row-c" style="gap:12px"><button class="btn btn-primary" style="height:50px" type="button" data-act="drill-make"' + (pool ? '' : ' disabled') + '>Mulai latihan</button>' +
      (pool ? '<span class="small muted">Soal yang paling sering salah didahulukan, lalu diacak.</span>' : '<span class="small muted">Belum ada soal untuk pilihan ini.</span>') + '</div></div>' +
      (drills ? '<div class="card"><h2 class="bold" style="font-size:18px">Latihanku</h2>' + drills + '</div>' : '') +
      '<div class="card"><h2 class="bold" style="font-size:18px">Catatan saya (' + notes.length + ')</h2>' + (noteList || '<p class="muted small">Belum ada catatan. Tulis catatan di bawah soal saat mengerjakan atau meninjau.</p>') + '</div>');
  }
  H['drill-pick'] = function (el) {
    var k = el.dataset.k;
    if (k === 'count') DR.count = Math.min(100, Math.max(5, parseInt(el.value, 10) || 20)); else DR[k] = el.value;
    renderDrill();
  };
  H['drill-make'] = async function (el) {
    el.disabled = true;
    try {
      var r = await Api.call('app_drill_create', { p_kind: DR.kind, p_count: DR.count, p_sys: DR.sys || null });
      toast(r.total + ' soal latihan siap.');
      go('#/ujian/' + r.id);
    } catch (e) { toast(e.message, true); el.disabled = false; }
  };
  H['drill-sesi'] = async function (el) {
    el.disabled = true;
    try {
      var r = await Api.call('app_drill_create', { p_kind: 'sesi', p_count: 100, p_session: el.dataset.v });
      toast(r.total + ' soal salah/bendera dari sesi ini siap dilatih.');
      go('#/ujian/' + r.id);
    } catch (e) { toast(e.message, true); el.disabled = false; }
  };
  H['drill-del'] = async function (el) {
    var ok = await confirmDialog('Hapus latihan ini?', 'Latihan dan hasilnya dihapus. Soalnya tetap ada di bank.', 'Hapus', true);
    if (!ok) return;
    try { await Api.call('app_drill_delete', { p_session: el.dataset.v }); drillView(); } catch (e) { toast(e.message, true); }
  };
  H['note-del'] = async function (el) {
    var ok = await confirmDialog('Hapus catatan?', 'Catatan untuk soal ini dihapus permanen.', 'Hapus', true);
    if (!ok) return;
    try { await Api.call('app_note_set', { p_qid: el.dataset.v, p_body: '' }); drillView(); } catch (e) { toast(e.message, true); }
  };

  /* ---------- hasil ---------- */
  /* Teks untuk admin yang melihat hasil peserta lain: "kamu" diganti nama peserta */
  function P(s, who) {
    if (!who) return s;
    var n = esc(who);
    return s.replace(/\b[Kk]amu\b/g, n).replace(/\b(Jawaban|jawaban|Pilihan|pilihan|nilai|Insting|insting|Akurasi|akurasi|mengerjakan)mu\b/g, function (m, w) { return w + ' ' + n; });
  }
  async function resultView(id, pid) {
    shell(pid ? 'admin' : 'home');
    var ok = fresh();
    await guard(async function () {
      var res = pid ? await Api.call('adm_result', { p_session: id, p_profile: pid }) : await Api.call('app_result', { p_session: id });
      if (!ok()) return;
      S.result = res;
      S.result.id = id;
      S.result.pid = pid || null;
      S.result.base = pid ? '#/tinjaupeserta/' + id + '/' + pid : '#/tinjau/' + id;
      renderResult();
    });
  }
  function lvl(p) { return p < 50 ? 'lo' : (p < 70 ? 'mid' : 'hi'); }
  function barRow(label, sub, c, t) {
    var p = pct(c, t);
    return '<div class="col" style="gap:6px"><div class="row between small" style="gap:12px"><span class="bold">' + label + '</span><span class="bold">' + c + ' dari ' + t + ' (' + p + '%)</span></div>' +
      '<div class="bar ' + lvl(p) + '"><i style="width:' + p + '%"></i></div>' + (sub ? '<div class="small muted">' + sub + '</div>' : '') + '</div>';
  }
  function dur(sec) {
    sec = Math.max(0, Math.round(sec || 0));
    var m = Math.floor(sec / 60), s = sec % 60;
    return m ? m + ' menit' + (s ? ' ' + s + ' detik' : '') : s + ' detik';
  }
  function reviewLink(base, sy, ty) { return base + '/' + encodeURIComponent(sy + '||' + ty); }

  function renderResult() {
    var r = S.result, total = r.total, rows = r.rows || [], id = r.id, base = r.base, drillKind = r.kind === 'latihan';
    var blank = rows.filter(function (x) { return x.mine === '-'; }).length;
    var correct = r.score, wrong = Math.max(0, total - correct - blank);
    var flagTot = 0, flagOk = 0;
    r.banks.forEach(function (b) { flagTot += b.flag || 0; flagOk += b.flag_ok || 0; });

    function ranked(list, key) {
      var reliable = list.filter(function (b) { return b.total >= 3; });
      var pool = (reliable.length >= 2 ? reliable : list).slice().sort(function (a, b) { return pct(a.correct, a.total) - pct(b.correct, b.total) || b.total - a.total; });
      return { all: list.slice().sort(function (a, b) { return pct(a.correct, a.total) - pct(b.correct, b.total); }), worst: pool[0], best: pool.length > 1 ? pool[pool.length - 1] : null };
    }
    var sysR = ranked(r.banks), typR = ranked(r.types || []);
    function listHtml(rk, nameKey) {
      return rk.all.map(function (b) {
        var tag = '';
        if (rk.best && rk.worst && rk.worst !== rk.best) {
          if (b === rk.worst) tag = ' <span class="badge b-bad">Perlu diulang</span>';
          else if (b === rk.best) tag = ' <span class="badge b-ok">Terkuat</span>';
        }
        return barRow(esc(b[nameKey]) + tag, 'Benar ' + b.correct + ' · Salah ' + (b.wrong || 0) + ' · Kosong ' + (b.blank || 0) + (b.avg != null ? ' · Rata-rata peserta ' + b.avg + '%' : ''), b.correct, b.total);
      }).join('');
    }

    /* Prioritas belajar: kombinasi sistem x jenis dengan soal salah/kosong terbanyak */
    var cells = (r.cells || []).map(function (c) { return { sy: c.sy, ty: c.ty, correct: c.correct, total: c.total, lost: c.total - c.correct }; });
    var prio = cells.filter(function (c) { return c.lost > 0; }).sort(function (a, b) { return b.lost - a.lost || pct(a.correct, a.total) - pct(b.correct, b.total) || b.total - a.total; }).slice(0, 5);
    var prioHtml = prio.length ? prio.map(function (c, i) {
      return '<a class="prio" href="' + reviewLink(base, c.sy, c.ty) + '"><span class="rk">' + (i + 1) + '</span><span class="grow"><b>' + esc(c.sy) + '</b> · ' + esc(c.ty) +
        '<span class="small muted" style="display:block">' + c.lost + ' dari ' + c.total + ' soal salah atau kosong</span></span><span class="go">Tinjau</span></a>';
    }).join('') : '<p class="bold" style="color:var(--ok)">Tidak ada soal yang salah. Mantap.</p>';

    /* Peta sistem x jenis soal */
    var sysNames = [], tyTotals = {};
    cells.forEach(function (c) { if (sysNames.indexOf(c.sy) < 0) sysNames.push(c.sy); tyTotals[c.ty] = (tyTotals[c.ty] || 0) + c.total; });
    var tyNames = Object.keys(tyTotals).sort(function (a, b) { return tyTotals[b] - tyTotals[a]; });
    var mapHtml = '';
    if (sysNames.length && tyNames.length) {
      mapHtml = '<div class="scroll-x"><table class="hm"><thead><tr><th></th>' + tyNames.map(function (t) { return '<th>' + esc(t) + '</th>'; }).join('') + '</tr></thead><tbody>' +
        sysNames.map(function (s) {
          return '<tr><th scope="row">' + esc(s) + '</th>' + tyNames.map(function (t) {
            var c = cells.filter(function (x) { return x.sy === s && x.ty === t; })[0];
            if (!c || !c.total) return '<td class="hm0">·</td>';
            return '<td class="hm-' + lvl(pct(c.correct, c.total)) + '"><a href="' + reviewLink(base, s, t) + '" title="' + esc(s + ' · ' + t) + ': ' + c.correct + ' dari ' + c.total + ' benar">' + c.correct + '/' + c.total + '</a></td>';
          }).join('') + '</tr>';
        }).join('') + '</tbody></table></div><p class="small muted">Merah di bawah 50 persen, kuning 50 sampai 69, hijau 70 ke atas. Klik kotak untuk meninjau soalnya.</p>';
    }

    /* Bagian demi bagian */
    var bs = r.block && r.block > 1 ? r.block : (total >= 60 ? 20 : 10), parts = [];
    for (var i = 0; i < rows.length; i += bs) {
      var seg = rows.slice(i, i + bs);
      parts.push({ a: i + 1, b: i + seg.length, c: seg.filter(function (x) { return x.ok === true; }).length, n: seg.length });
    }
    var partHtml = parts.map(function (t, k) { return barRow('Bagian ' + (k + 1) + ' <span class="muted">(no. ' + t.a + '-' + t.b + ')</span>', '', t.c, t.n); }).join('');

    /* Kecenderungan huruf jawaban */
    var L = ['A', 'B', 'C', 'D', 'E'], mineN = { A: 0, B: 0, C: 0, D: 0, E: 0 }, keyN = { A: 0, B: 0, C: 0, D: 0, E: 0 }, ansN = 0;
    rows.forEach(function (x) { if (keyN[x.key] != null) keyN[x.key]++; if (mineN[x.mine] != null) { mineN[x.mine]++; ansN++; } });
    var letterHtml = '', biasNote = '';
    if (ansN >= 15) {
      letterHtml = '<div class="ltr">' + L.map(function (l) {
        var m = pct(mineN[l], ansN), k = pct(keyN[l], total);
        return '<div class="ltr-c"><div class="ltr-bars"><i class="mine" style="height:' + Math.max(3, m * 0.9) + 'px" title="Kamu: ' + m + '%"></i><i class="key" style="height:' + Math.max(3, k * 0.9) + 'px" title="Kunci: ' + k + '%"></i></div><b>' + l + '</b><span class="small muted">' + m + '% / ' + k + '%</span></div>';
      }).join('') + '</div><p class="small muted"><span class="dot mine"></span>pilihanmu <span class="dot key"></span>kunci sebenarnya</p>';
      var top = L.slice().sort(function (a, b) { return mineN[b] - mineN[a]; })[0];
      if (pct(mineN[top], ansN) - pct(keyN[top], total) >= 12) biasNote = 'Kamu paling sering memilih <b>' + top + '</b> (' + pct(mineN[top], ansN) + '% jawabanmu), padahal kunci ' + top + ' hanya ' + pct(keyN[top], total) + '%. Kalau ragu, jangan otomatis memilih ' + top + '.';
    }

    /* Soal tersulit (butuh minimal 2 peserta selesai) */
    var hardHtml = (r.hard && r.hard.length) ? r.hard.map(function (h) {
      return '<a class="prio" href="' + base + '/' + encodeURIComponent('no:' + h.no) + '"><span class="rk">' + h.no + '</span><span class="grow"><b>' + esc(h.sy) + '</b> · ' + esc(h.ty) +
        '<span class="small muted" style="display:block">Hanya ' + h.pct + '% peserta benar (dari ' + h.n + ') · kamu ' + (h.mine_ok ? 'benar' : 'salah') + '</span></span><span class="go">Buka</span></a>';
    }).join('') : '<p class="muted small">Muncul setelah minimal 2 peserta mengumpulkan sesi ini.</p>';

    /* Kecepatan dan ketepatan (dari waktu per soal) */
    var tm = r.time || {}, timeHtml = '';
    if (tm.has && tm.n >= 5) {
      var slowHtml = (tm.slow || []).map(function (h) {
        return '<a class="prio" href="' + base + '/' + encodeURIComponent('no:' + h.no) + '"><span class="rk">' + h.no + '</span><span class="grow"><b>' + esc(h.sy) + '</b> · ' + esc(h.ty) +
          '<span class="small muted" style="display:block">' + dur(h.secs) + ' · ' + (h.ok ? 'kamu benar' : 'kamu salah') + '</span></span><span class="go">Buka</span></a>';
      }).join('');
      var sysT = (tm.by_sys || []).map(function (x) { return '<div class="row between small" style="gap:10px"><span>' + esc(x.name) + '</span><span class="bold">' + x.avg + ' detik per soal</span></div>'; }).join('');
      timeHtml = '<div class="card"><h2 class="bold" style="font-size:18px">Kecepatan dan ketepatan</h2><div class="row" style="gap:12px">' +
        '<div class="stat" style="padding:14px;background:var(--bg);border:0"><span class="small muted">Rata-rata per soal</span><strong style="font-size:24px">' + tm.avg + ' dtk</strong></div>' +
        '<div class="stat" style="padding:14px;background:var(--bg);border:0"><span class="small muted">Soal yang benar</span><strong style="font-size:24px">' + (tm.avg_ok != null ? tm.avg_ok + ' dtk' : '-') + '</strong></div>' +
        '<div class="stat" style="padding:14px;background:var(--bg);border:0"><span class="small muted">Soal yang salah</span><strong style="font-size:24px">' + (tm.avg_bad != null ? tm.avg_bad + ' dtk' : '-') + '</strong></div></div>' +
        '<h3 class="bold" style="font-size:15px;margin-top:4px">Paling lama dikerjakan</h3>' + slowHtml + (sysT ? '<h3 class="bold" style="font-size:15px;margin-top:4px">Rata-rata waktu per sistem</h3>' + sysT : '') +
        '<p class="small muted">Waktu hanya dihitung saat soal dikerjakan: tidak termasuk diskusi, jeda, atau saat meninjau kunci.</p></div>';
    }

    /* Pola jawaban */
    var notes = [];
    if (blank) notes.push('<b>' + blank + ' soal tidak dijawab</b> dan dihitung salah.');
    if (flagTot) {
      var fp = pct(flagOk, flagTot), sp = pct(correct, total);
      notes.push('Dari <b>' + flagTot + ' soal yang kamu beri bendera</b>, ' + flagOk + ' benar (' + fp + '%). ' + (fp >= sp ? 'Instingmu cukup baik: ragu-ragu tetapi sering benar.' : 'Soal yang kamu ragukan lebih sering salah, jadi itu petunjuk materi yang belum kuat.'));
    } else notes.push('Kamu tidak memberi bendera pada soal mana pun.');
    if (parts.length > 1) {
      var p0 = pct(parts[0].c, parts[0].n), pl = pct(parts[parts.length - 1].c, parts[parts.length - 1].n);
      if (p0 - pl >= 20) notes.push('Akurasi turun di bagian akhir (' + p0 + '% lalu ' + pl + '%). Bisa jadi kelelahan atau terburu-buru, ini dugaan dari pola nilaimu.');
      else if (pl - p0 >= 20) notes.push('Akurasimu naik di bagian akhir (' + p0 + '% lalu ' + pl + '%).');
    }
    if (sysR.worst && r.banks.length > 1) notes.push('Sistem yang paling perlu diulang: <b>' + esc(sysR.worst.bank) + '</b> (' + pct(sysR.worst.correct, sysR.worst.total) + '%).');
    if (typR.worst && (r.types || []).length > 1) notes.push('Jenis soal terlemah: <b>' + esc(typR.worst.type) + '</b> (' + pct(typR.worst.correct, typR.worst.total) + '%)' + (typR.best && typR.best !== typR.worst ? ', terkuat: <b>' + esc(typR.best.type) + '</b> (' + pct(typR.best.correct, typR.best.total) + '%).' : '.'));
    if (tm.has && tm.n >= 5) {
      if (tm.avg_ok != null && tm.avg_bad != null && tm.avg_bad >= tm.avg_ok * 1.3 && tm.avg_bad - tm.avg_ok >= 10) notes.push('Soal yang kamu jawab salah rata-rata memakan waktu lebih lama (' + tm.avg_bad + ' dtk dibanding ' + tm.avg_ok + ' dtk). Itu tanda materinya memang membingungkan, bukan soal yang dijawab sembarangan.');
      if (tm.fast_wrong >= 3) notes.push('<b>' + tm.fast_wrong + ' soal salah dijawab kurang dari 10 detik.</b> Kemungkinan terburu-buru atau menebak, coba baca ulang pilihan sebelum memilih.');
    }
    if (biasNote) notes.push(biasNote);
    if (r.discuss_secs > 0) notes.push('Waktu diskusi <b>' + dur(r.discuss_secs) + '</b> tidak dihitung dalam waktu mengerjakanmu.');
    if (r.ketat) notes.push(r.viol ? 'Mode ketat: terdeteksi <b>' + r.viol + ' kali</b> keluar dari halaman ujian.' : 'Mode ketat: tidak ada keluar halaman yang terdeteksi.');

    setMain(P(
      '<div class="row row-c between"><div class="col" style="gap:4px"><span class="page-sub">' + esc(r.title) + '</span><h1 class="page-title">Hasil akhir' + (r.person ? ': ' + esc(r.person) : '') + '</h1></div>' +
      '<div class="row" style="gap:8px">' + (r.pid ? '<a class="btn" href="#/admin/sesi">Kembali ke admin</a>' : '<button class="btn" type="button" data-act="drill-sesi" data-v="' + id + '"' + (correct >= total ? ' disabled' : '') + '>Latih soal yang salah</button>') + '<a class="btn" href="' + base + '">Tinjau semua soal</a>' + (drillKind ? '<a class="btn btn-primary" href="#/latihan">Kembali ke Latihan</a>' : '<a class="btn btn-primary" href="#/peringkat/' + id + '">Lihat peringkat</a>') + '</div></div>' +
      '<div class="row"><div class="stat"><span class="page-sub">Skor</span><b style="color:var(--primary-dark)">' + correct + ' / ' + total + '</b><span class="small muted">' + pct(correct, total) + ' persen benar</span></div>' +
      '<div class="stat"><span class="page-sub">Waktu mengerjakan</span><b>' + clock(r.time_taken) + '</b><span class="small muted">menit:detik · rata-rata ' + Math.round((r.time_taken || 0) / Math.max(1, total)) + ' detik per soal</span></div>' +
      (drillKind ? '' : '<div class="stat"><span class="page-sub">Peringkat sesi ini</span><b>' + r.rank + ' dari ' + r.participants + '</b><span class="small muted">urut skor, lalu waktu tercepat</span></div>') +
      '<div class="stat"><span class="page-sub">Benar · Salah · Kosong</span><div class="stack" role="img" aria-label="Benar ' + correct + ', salah ' + wrong + ', kosong ' + blank + '"><i class="s-ok" style="flex:' + correct + '"></i><i class="s-bad" style="flex:' + wrong + '"></i><i class="s-blank" style="flex:' + blank + '"></i></div>' +
      '<span class="small"><strong style="color:var(--ok)">' + correct + '</strong> benar · <strong style="color:var(--bad)">' + wrong + '</strong> salah · <strong>' + blank + '</strong> kosong</span></div></div>' +
      '<div class="row"><div class="col grow" style="flex:999 1 560px;gap:16px">' +
      '<div class="card"><h2 class="bold" style="font-size:18px">Prioritas belajar</h2><p class="small muted" style="margin-top:-8px">Gabungan sistem dan jenis soal dengan kesalahan terbanyak. Mulai dari yang teratas.</p>' + prioHtml + '</div>' +
      (mapHtml ? '<div class="card"><h2 class="bold" style="font-size:18px">Peta kekuatan: sistem × jenis soal</h2>' + mapHtml + '</div>' : '') +
      (parts.length > 1 ? '<div class="card"><h2 class="bold" style="font-size:18px">Bagian demi bagian</h2>' + partHtml + '<p class="small muted">Per ' + bs + ' nomor, untuk melihat apakah akurasi bertahan sampai akhir.</p></div>' : '') +
      timeHtml +
      (drillKind ? '' : '<div class="card"><h2 class="bold" style="font-size:18px">Soal tersulit di sesi ini</h2><p class="small muted" style="margin-top:-8px">Cocok untuk bahan diskusi bersama.</p>' + hardHtml + '</div>') + '</div>' +
      '<div class="col grow" style="flex:1 1 340px;max-width:460px;gap:16px">' +
      '<div class="card"><h2 class="bold" style="font-size:18px">Analisis per sistem</h2>' + listHtml(sysR, 'bank') + '<p class="small muted">Dihitung per sistem organ, bukan per file soal.</p></div>' +
      '<div class="card"><h2 class="bold" style="font-size:18px">Analisis per jenis soal</h2>' + ((r.types || []).length ? listHtml(typR, 'type') : '<p class="muted small">Belum ada data jenis soal.</p>') + '<p class="small muted">Jenis soal ditebak dari kalimat tanyanya (diagnosis, tatalaksana, dosis obat, patofisiologi, dan seterusnya).</p></div>' +
      '<div class="card"><h2 class="bold" style="font-size:18px">Pola jawabanmu</h2>' + notes.map(function (n) { return '<p style="margin:0">' + n + '</p>'; }).join('') + '</div>' +
      (letterHtml ? '<div class="card"><h2 class="bold" style="font-size:18px">Kecenderungan huruf jawaban</h2>' + letterHtml + '</div>' : '') +
      '</div></div>', r.person));
  }

  /* ---------- tinjau soal ---------- */
  async function reviewView(id, param, pid) {
    shell(pid ? 'admin' : 'home');
    var ok = fresh();
    await guard(async function () {
      var res = pid ? await Api.call('adm_review', { p_session: id, p_profile: pid }) : await Api.call('app_review', { p_session: id });
      if (!ok()) return;
      var peers = {}, notes = {};
      if (!pid) {
        try { (await Api.call('app_notes')).forEach(function (n) { notes[n.qid] = n.body; }); } catch (e) { /* abaikan */ }
        try { peers = await Api.call('app_peers', { p_session: id, p_qids: res.questions.map(function (q) { return q.id; }) }) || {}; } catch (e) { /* abaikan */ }
      }
      if (!ok()) return;
      S.rv = { id: id, pid: pid || null, person: res.person || null, title: res.title, qs: res.questions, filter: 'all', system: 'all', type: 'all', only: null, peers: peers, notes: notes };
      var p = ''; try { p = decodeURIComponent(param || ''); } catch (e) { p = ''; }
      if (/^no:\d+$/.test(p)) S.rv.only = +p.slice(3);
      else if (p.indexOf('||') > 0) { var a = p.split('||'); S.rv.system = a[0]; S.rv.type = a[1]; }
      renderReview();
    });
  }
  function rvStatus(q) { return q.mine == null ? 'blank' : (q.mine === q.key ? 'ok' : 'bad'); }
  function renderReview() {
    var v = S.rv, letters = ['A', 'B', 'C', 'D', 'E'], systems = [], types = [];
    v.qs.forEach(function (q) { if (systems.indexOf(q.system) < 0) systems.push(q.system); if (types.indexOf(q.qtype) < 0) types.push(q.qtype); });
    var cnt = { all: v.qs.length, bad: 0, blank: 0, ok: 0, flag: 0 };
    v.qs.forEach(function (q) { cnt[rvStatus(q)]++; if (q.flag) cnt.flag++; });
    var list = v.qs.filter(function (q) {
      if (v.only != null) return q.no === v.only;
      if (v.system !== 'all' && q.system !== v.system) return false;
      if (v.type !== 'all' && q.qtype !== v.type) return false;
      if (v.filter === 'flag') return q.flag;
      if (v.filter !== 'all') return rvStatus(q) === v.filter;
      return true;
    });
    var chips = [['all', 'Semua'], ['bad', 'Salah'], ['blank', 'Kosong'], ['ok', 'Benar'], ['flag', 'Bendera']].map(function (f) {
      return '<button type="button" class="btn btn-sm' + (v.filter === f[0] && v.only == null ? ' btn-primary' : '') + '" data-act="rv-filter" data-v="' + f[0] + '">' + f[1] + ' (' + cnt[f[0]] + ')</button>';
    }).join('');
    function sel(name, label, arr, cur) {
      return arr.length > 1 ? '<select class="input" data-change="' + name + '" aria-label="' + label + '" style="max-width:240px;height:36px"><option value="all">' + label + '</option>' + arr.map(function (x) {
        return '<option value="' + esc(x) + '"' + (cur === x ? ' selected' : '') + '>' + esc(x) + '</option>';
      }).join('') + '</select>' : '';
    }
    var jump = v.qs.map(function (q) {
      var s = rvStatus(q);
      return '<button type="button" class="nav-n sm' + (s === 'ok' ? ' right' : (s === 'bad' ? ' miss' : '')) + (q.flag ? ' flag' : '') + '" data-act="rv-jump" data-v="' + q.no + '" aria-label="Soal ' + q.no + ', ' + (s === 'ok' ? 'benar' : s === 'bad' ? 'salah' : 'kosong') + '">' + q.no + '</button>';
    }).join('');
    var cards = list.map(function (q) {
      var img = safeImg(q.image), s = rvStatus(q);
      var st = s === 'blank' ? '<span class="badge b-warn">Tidak dijawab</span>' : (s === 'ok' ? '<span class="badge b-ok">Benar</span>' : '<span class="badge b-bad">Salah</span>');
      var pe = v.peers && v.peers[q.id]; if (pe && !(pe.n >= 2)) pe = null;
      var opts = q.options.map(function (t, i) {
        var L = letters[i], cls = '', tag = '';
        if (L === q.key) { cls = 'key'; tag = q.mine === q.key ? 'Kunci (jawabanmu)' : 'Kunci'; }
        else if (L === q.mine) { cls = 'wrong'; tag = 'Jawabanmu'; }
        return '<button type="button" class="opt ' + cls + '" disabled><span class="l">' + L + '</span><span class="t">' + esc(t) + '</span>' + (pe ? '<span class="pc">' + pct((pe.d || {})[L] || 0, pe.n) + '%</span>' : '') + (tag ? '<span class="tag">' + tag + '</span>' : '') + '</button>';
      }).join('');
      var peerChip = pe ? '<span class="chip chip-peer">' + pct(pe.ok, pe.n) + '% peserta benar · ' + pe.ok + ' dari ' + pe.n + '</span>' : '';
      var exBox = (q.expl ? '<div class="expl"><b>Pembahasan kelompok</b><p>' + esc(q.expl) + '</p></div>' : '') +
        (S.me && S.me.role === 'admin' ? '<details class="notebox"><summary>' + (q.expl ? 'Ubah' : 'Tulis') + ' pembahasan kelompok (admin)</summary><textarea class="input" rows="3" maxlength="3000" id="rvx' + q.no + '" aria-label="Pembahasan kelompok">' + esc(q.expl || '') + '</textarea>' +
          '<div class="row" style="gap:8px;margin-top:6px"><button class="btn btn-sm btn-primary" type="button" data-act="rv-expl-save" data-v="' + q.id + '" data-n="' + q.no + '">Simpan pembahasan</button></div></details>' : '');
      var nt = v.notes && v.notes[q.id];
      var noteBox = v.pid ? '' : '<details class="notebox"' + (nt ? ' open' : '') + '><summary>Catatan saya' + (nt ? ' <span class="dot-on"></span>' : '') + '</summary><textarea class="input" rows="3" maxlength="2000" placeholder="Catatan untuk soal ini (hanya kamu yang melihat)" aria-label="Catatan pribadi" data-input="rv-note" data-change="rv-note-flush" data-v="' + q.id + '">' + esc(nt || '') + '</textarea></details>';
      return '<div class="qcard" id="rq' + q.no + '" style="margin-bottom:14px"><div class="row row-c qhead"><span class="qno">Soal ' + q.no + '</span>' + (q.flag ? '<span class="flagmark" title="Kamu beri bendera">' + FLAG_SVG + '</span>' : '') + st +
        '<span class="chip">Asal file: ' + esc(q.file) + '</span><span class="chip chip-alt">' + esc(q.system) + '</span><span class="chip chip-alt">' + esc(q.qtype) + '</span>' + peerChip + '</div>' +
        '<p class="stem">' + esc(q.stem) + '</p>' + (img ? '<img class="qimg zoomable" data-act="zoom" src="' + img + '" alt="Gambar pada soal (ketuk untuk memperbesar)">' : '') + '<div class="opts">' + opts + '</div>' + exBox + noteBox + '</div>';
    }).join('');
    setMain(P('<div class="row row-c between"><div class="col" style="gap:4px"><span class="page-sub">' + esc(v.title) + '</span><h1 class="page-title">Tinjau semua soal' + (v.person ? ': ' + esc(v.person) : '') + '</h1></div>' +
      '<a class="btn" href="' + (v.pid ? '#/hasilpeserta/' + v.id + '/' + v.pid : '#/hasil/' + v.id) + '">Kembali ke hasil</a></div>' +
      '<div class="card"><div class="jump">' + jump + '</div><p class="small muted">Hijau benar, merah salah, putih kosong, bendera merah berarti kamu menandainya. Klik nomor untuk melompat.</p></div>' +
      '<div class="row row-c" style="gap:8px">' + chips + sel('rv-sys', 'Semua sistem', systems, v.system) + sel('rv-type', 'Semua jenis soal', types, v.type) +
      '<span class="small muted">' + list.length + ' dari ' + v.qs.length + ' soal</span>' + (v.only != null ? '<button type="button" class="btn btn-sm" data-act="rv-filter" data-v="all">Tampilkan semua</button>' : '') + '</div>' +
      (cards || '<p class="muted">Tidak ada soal untuk filter ini.</p>') + '<p class="small muted">Tidak ada pembahasan: hanya soal, kunci, dan jawabanmu.</p>', v.person));
  }
  H['rv-expl-save'] = async function (el) {
    var v = S.rv, ta = document.getElementById('rvx' + el.dataset.n); if (!v || !ta) return;
    try {
      await Api.call('adm_set_expl', { p_qid: el.dataset.v, p_body: ta.value });
      v.qs.forEach(function (q) { if (q.id === el.dataset.v) q.expl = ta.value.trim() || null; });
      toast('Pembahasan kelompok disimpan.');
      renderReview();
    } catch (e) { toast(e.message, true); }
  };
  H['rv-note'] = function (el) {
    var v = S.rv; if (!v) return;
    var id = el.dataset.v; v.notes[id] = el.value; clearTimeout(v.noteT);
    v.noteT = setTimeout(function () { Api.call('app_note_set', { p_qid: id, p_body: v.notes[id] || '' }).catch(function (e) { toast(e.message, true); }); }, 900);
  };
  H['rv-note-flush'] = function (el) {
    var v = S.rv; if (!v) return;
    v.notes[el.dataset.v] = el.value; clearTimeout(v.noteT);
    Api.call('app_note_set', { p_qid: el.dataset.v, p_body: el.value }).catch(function (e) { toast(e.message, true); });
  };
  H['rv-filter'] = function (el) { S.rv.filter = el.dataset.v; S.rv.only = null; renderReview(); };
  H['rv-sys'] = function (el) { S.rv.system = el.value; S.rv.only = null; renderReview(); };
  H['rv-type'] = function (el) { S.rv.type = el.value; S.rv.only = null; renderReview(); };
  H['rv-jump'] = function (el) {
    var no = +el.dataset.v, v = S.rv;
    if (v.only != null || v.filter !== 'all' || v.system !== 'all' || v.type !== 'all') { v.only = null; v.filter = 'all'; v.system = 'all'; v.type = 'all'; renderReview(); }
    var t = document.getElementById('rq' + no); if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  /* ---------- peringkat ---------- */
  async function rankView(which) {
    shell('peringkat');
    var ok = fresh();
    await guard(async function () {
      try { which = which ? decodeURIComponent(which) : ''; } catch (e) { which = ''; }
      var sessions = (await Api.call('app_sessions')).filter(function (s) { return s.kind !== 'latihan'; });
      if (!ok()) return;
      var withData = sessions.filter(function (s) { return s.finished > 0; });
      var acc = /^(ak|sy|ty):/.test(which);
      var sel = which || (withData.length ? withData[0].id : 'semua');
      var by = acc && which !== 'ak:all' ? which : null;
      var rb = await Api.call('app_rank_by', { p_by: by });
      var board = acc ? null : await Api.call('app_leaderboard', sel === 'semua' ? {} : { p_session: sel });
      if (!ok()) return;
      var all = sel === 'semua';
      var opts = '<optgroup label="Peringkat per sesi (skor)"><option value="semua"' + (sel === 'semua' ? ' selected' : '') + '>Semua sesi (akumulasi)</option>' + withData.map(function (s) {
        return '<option value="' + s.id + '"' + (s.id === sel ? ' selected' : '') + '>' + esc(s.title) + '</option>';
      }).join('') + '</optgroup>' +
        '<optgroup label="Akurasi"><option value="ak:all"' + (which === 'ak:all' ? ' selected' : '') + '>Akurasi keseluruhan</option></optgroup>' +
        '<optgroup label="Akurasi per sistem">' + (rb.systems || []).map(function (x) { return '<option value="sy:' + esc(x) + '"' + (which === 'sy:' + x ? ' selected' : '') + '>' + esc(x) + '</option>'; }).join('') + '</optgroup>' +
        '<optgroup label="Akurasi per jenis soal">' + (rb.types || []).map(function (x) { return '<option value="ty:' + esc(x) + '"' + (which === 'ty:' + x ? ' selected' : '') + '>' + esc(x) + '</option>'; }).join('') + '</optgroup>';
      var cur = sessions.filter(function (s) { return s.id === sel; })[0];
      var head = '<div class="row row-c between"><h1 class="page-title">Peringkat</h1><div class="field" style="min-width:280px"><label for="rk">Tampilkan</label><select id="rk" class="input" data-change="rank-pick">' + opts + '</select></div></div>';
      if (acc) {
        var title = which === 'ak:all' ? 'Akurasi keseluruhan' : 'Akurasi: ' + esc(which.slice(3));
        setMain(head + '<div class="card"><h2 class="bold" style="font-size:18px">' + title + '</h2>' +
          (rb.rows.length ? '<div class="scroll-x"><table class="table"><thead><tr><th>Urutan</th><th>Peserta</th><th>Akurasi</th><th>Benar</th></tr></thead><tbody>' +
            rb.rows.map(function (b) {
              var p = pct(b.correct, b.total);
              return '<tr class="' + (b.me ? 'me' : '') + '"><td class="bold">' + b.rank + '</td><td><span class="row row-c" style="gap:10px;flex-wrap:nowrap">' + avatar(b.name, b.avatar_color) + '<span class="bold">' + esc(b.name) + '</span>' + (b.me ? '<span class="chip">Kamu</span>' : '') + '</span></td>' +
                '<td style="min-width:160px"><div class="bold">' + p + '%</div><div class="bar ' + lvl(p) + '"><i style="width:' + p + '%"></i></div></td><td>' + b.correct + ' dari ' + b.total + '</td></tr>';
            }).join('') + '</tbody></table></div>' : '<p class="muted">Belum ada peserta dengan minimal 5 soal untuk pilihan ini.</p>') +
          '<p class="small muted">Dihitung dari semua sesi umum yang sudah dikumpulkan (latihan pribadi tidak ikut). Peserta dengan kurang dari 5 soal tidak ditampilkan.</p></div>');
        return;
      }
      setMain(head +
        '<div class="card"><h2 class="bold" style="font-size:18px">' + (all ? 'Peringkat akumulasi semua sesi' : 'Peringkat: ' + esc(cur ? cur.title : '')) + '</h2>' +
        (board.length ? '<div class="scroll-x"><table class="table"><thead><tr><th>Urutan</th><th>Peserta</th><th>Skor</th>' + (all ? '<th>Akurasi</th><th>Sesi</th>' : '') + '<th>Waktu</th></tr></thead><tbody>' +
          board.map(function (b) {
            return '<tr class="' + (b.me ? 'me' : '') + '"><td class="bold">' + b.rank + '</td><td><span class="row row-c" style="gap:10px;flex-wrap:nowrap">' + avatar(b.name, b.avatar_color) + '<span class="bold">' + esc(b.name) + '</span>' + (b.me ? '<span class="chip">Kamu</span>' : '') + '</span></td>' +
              '<td class="bold">' + b.score + ' / ' + b.total + '</td>' + (all ? '<td>' + pct(b.score, b.total) + '%</td><td>' + b.sessions + '</td>' : '') + '<td>' + clock(b.time_taken) + '</td></tr>';
          }).join('') + '</tbody></table></div>' : '<p class="muted">Belum ada yang menyelesaikan sesi ini.</p>') +
        '<p class="small muted">Diurutkan menurut skor tertinggi; bila sama, waktu tercepat berada di atas.</p></div>');
    });
  }
  H['rank-pick'] = function (el) { go('#/peringkat/' + encodeURIComponent(el.value)); };

  /* ---------- profil ---------- */
  /* grafik mini perkembangan akurasi dari sesi ke sesi */
  function spark(pts) {
    var v = pts.slice(-10).map(function (p) { return pct(p.c, p.n); });
    if (v.length < 2) return '<span class="small muted">butuh 2 sesi</span>';
    var w = 120, h = 30, st = w / (v.length - 1);
    var y = function (p) { return (h - 3 - (h - 6) * p / 100).toFixed(1); };
    var path = v.map(function (p, i) { return (i ? 'L' : 'M') + (i * st).toFixed(1) + ' ' + y(p); }).join(' ');
    return '<svg class="spark" viewBox="0 0 ' + w + ' ' + h + '" width="' + w + '" height="' + h + '" role="img" aria-label="Grafik akurasi per sesi"><path d="' + path + '" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/><circle cx="' + ((v.length - 1) * st).toFixed(1) + '" cy="' + y(v[v.length - 1]) + '" r="3" fill="currentColor"/></svg>';
  }
  function trendOf(pts) {
    if (pts.length < 2) return null;
    var k = Math.min(3, Math.floor(pts.length / 2)), a = pts.slice(0, k), b = pts.slice(-k);
    var f = function (arr) { var c = 0, n = 0; arr.forEach(function (p) { c += p.c; n += p.n; }); return pct(c, n); };
    return f(b) - f(a);
  }
  function progressRows(list) {
    return list.map(function (g) {
      var last = g.pts[g.pts.length - 1], tr = trendOf(g.pts);
      var tag = tr == null ? '' : (tr > 0 ? '<span class="trend up">naik ' + tr + ' poin</span>' : (tr < 0 ? '<span class="trend down">turun ' + Math.abs(tr) + ' poin</span>' : '<span class="trend">stabil</span>'));
      return '<div class="prog"><span class="grow bold small">' + esc(g.name) + '</span>' + spark(g.pts) + '<span class="bold" style="min-width:42px;text-align:right">' + pct(last.c, last.n) + '%</span>' + tag + '</div>';
    }).join('');
  }
  function streakOf(days) {
    var set = {}; (days || []).forEach(function (d) { set[d] = true; });
    var t = new Date(Date.now() + 8 * 3600 * 1000), n = 0;
    var iso = function (d) { return d.toISOString().slice(0, 10); };
    if (!set[iso(t)]) t = new Date(t.getTime() - 86400000);
    while (set[iso(t)]) { n++; t = new Date(t.getTime() - 86400000); }
    return n;
  }
  async function profileView() {
    shell('profil');
    var ok = fresh();
    await guard(async function () {
      var pr = await Promise.all([Api.call('app_history'), Api.call('app_progress'), Api.call('app_drill_stats')]);
      var d = pr[0], prog = pr[1], dst = pr[2];
      if (!ok()) return;
      var me = S.me;
      var hist = d.history, banks = d.banks, types = d.types || [];
      var sumS = 0, sumT = 0;
      hist.forEach(function (h) { sumS += h.score; sumT += h.total; });
      var ranked = banks.filter(function (b) { return b.total >= 3; });
      if (!ranked.length) ranked = banks;
      ranked = ranked.slice().sort(function (a, b) { return pct(b.correct, b.total) - pct(a.correct, a.total); });
      var best = ranked[0], worst = ranked.length > 1 ? ranked[ranked.length - 1] : null;
      var last = hist.slice(-12);
      var first = hist.length ? pct(hist[0].score, hist[0].total) : 0, lastP = hist.length ? pct(hist[hist.length - 1].score, hist[hist.length - 1].total) : 0;
      var streak = streakOf(prog.days);
      var progHtml = '<div class="card"><h2 class="bold" style="font-size:18px">Perkembangan dari sesi ke sesi</h2>' +
        '<div class="row" style="gap:12px"><div class="stat" style="padding:14px;background:var(--bg);border:0"><span class="small muted">Hari belajar beruntun</span><strong style="font-size:26px">' + streak + '</strong></div>' +
        '<div class="stat" style="padding:14px;background:var(--bg);border:0"><span class="small muted">Total hari belajar</span><strong style="font-size:26px">' + (prog.days || []).length + '</strong></div>' +
        '<div class="stat" style="padding:14px;background:var(--bg);border:0"><span class="small muted">Soal salah yang dikuasai</span><strong style="font-size:26px">' + dst.mastered + ' / ' + dst.ever_wrong + '</strong></div></div>' +
        '<h3 class="bold" style="font-size:15px">Per sistem</h3>' + (prog.sys.length ? progressRows(prog.sys) : '<p class="muted small">Belum ada data.</p>') +
        '<h3 class="bold" style="font-size:15px;margin-top:6px">Per jenis soal</h3>' + (prog.types.length ? progressRows(prog.types) : '<p class="muted small">Belum ada data.</p>') +
        '<p class="small muted">Satu titik = satu sesi umum. Perubahan dihitung dari rata-rata sesi awal dibanding sesi terbaru. Latihan pribadi tidak ikut.</p></div>';
      setMain('<h1 class="page-title">Profil</h1><div class="row"><div class="col grow" style="max-width:480px">' +
        '<div class="card"><div class="row row-c" style="gap:16px;flex-wrap:nowrap">' + avatar(me.name, me.avatar_color, 'avatar-lg') +
        '<div class="col" style="gap:2px"><span class="bold" style="font-size:20px">' + esc(me.name) + '</span><span class="small muted">' + (me.role === 'admin' ? 'Admin' : 'Peserta') + '</span></div></div>' +
        '<div class="col" style="gap:8px"><span class="small bold">Warna avatar</span><div class="swatches">' + AVATARS.map(function (c) {
          return '<button type="button" class="swatch' + (c === avParts(me.avatar_color).color ? ' on' : '') + '" style="background:' + c + '" data-act="avatar" data-v="' + c + '" aria-label="Pilih warna ' + c + '" aria-pressed="' + (c === avParts(me.avatar_color).color) + '"></button>';
        }).join('') + '</div></div>' +
        '<div class="col" style="gap:8px"><span class="small bold">Foto atau emoji</span><div class="row" style="gap:6px">' + EMOJIS.map(function (m) {
          return '<button type="button" class="btn btn-sm" style="font-size:20px;padding:4px 10px" data-act="avatar-emoji" data-v="' + m + '" aria-label="Pakai emoji ' + m + '">' + m + '</button>';
        }).join('') + '</div><div class="row" style="gap:8px"><label class="btn btn-sm" style="cursor:pointer">Unggah foto<input type="file" accept="image/*" data-change="avatar-photo" style="display:none"></label>' +
        (avParts(me.avatar_color).extra ? '<button type="button" class="btn btn-sm" data-act="avatar-clear">Kembali ke huruf</button>' : '') + '</div></div>' +
        '<form class="col" style="gap:8px" data-submit="rename"><span class="small bold">Ganti nama</span><div class="row" style="gap:8px;flex-wrap:nowrap"><input class="input" name="nama" maxlength="40" value="' + esc(me.name) + '" aria-label="Nama baru"><button class="btn btn-sm btn-primary" type="submit">Simpan</button></div></form>' +
        '<form class="col" style="gap:8px" data-submit="repin"><span class="small bold">Ganti PIN</span><input class="input" name="lama" type="password" inputmode="numeric" maxlength="6" placeholder="PIN lama" autocomplete="current-password"><input class="input" name="baru" type="password" inputmode="numeric" maxlength="6" placeholder="PIN baru (4 sampai 6 angka)" autocomplete="new-password"><button class="btn btn-sm btn-primary" type="submit">Ganti PIN</button></form>' +
        '<div class="row" style="gap:12px"><div class="stat" style="padding:16px;background:var(--bg);border:0"><span class="small muted">Sesi diikuti</span><b style="font-size:26px">' + hist.length + '</b></div>' +
        '<div class="stat" style="padding:16px;background:var(--bg);border:0"><span class="small muted">Akurasi rata-rata</span><b style="font-size:26px">' + pct(sumS, sumT) + '%</b></div></div>' +
        '<div class="row" style="gap:12px"><div class="stat" style="padding:16px;background:var(--bg);border:0"><span class="small muted">Bidang terkuat</span><span class="bold">' + (best ? esc(best.bank) + ' (' + pct(best.correct, best.total) + '%)' : '-') + '</span></div>' +
        '<div class="stat" style="padding:16px;background:var(--bg);border:0"><span class="small muted">Perlu diulang</span><span class="bold">' + (worst ? esc(worst.bank) + ' (' + pct(worst.correct, worst.total) + '%)' : '-') + '</span></div></div></div></div>' +
        '<div class="card grow" style="flex:999 1 420px"><h2 class="bold" style="font-size:18px">Riwayat skor</h2>' +
        (last.length ? '<div class="hist" role="img" aria-label="Grafik riwayat skor">' + last.map(function (h) {
          var p = pct(h.score, h.total);
          return '<div><span>' + p + '</span><i style="height:' + Math.max(4, p * 1.5) + 'px" title="' + esc(h.title) + '"></i></div>';
        }).join('') + '</div><div class="row between small muted"><span>Sesi paling awal ditampilkan</span><span>Terbaru</span></div>' +
        '<p class="small muted">Skor dalam persen per sesi. ' + (hist.length > 1 ? (lastP >= first ? 'Naik ' : 'Turun ') + Math.abs(lastP - first) + ' poin dibanding sesi pertama.' : 'Ikuti lebih banyak sesi untuk melihat perkembangan.') + '</p>' : '<p class="muted">Belum ada sesi yang selesai.</p>') +
        '<h3 class="bold" style="font-size:16px;margin-top:8px">Akurasi per sistem</h3>' + (banks.length ? banks.map(function (b) {
          return '<div class="col" style="gap:6px"><div class="row between small" style="gap:12px"><span class="bold">' + esc(b.bank) + '</span><span class="bold">' + b.correct + ' dari ' + b.total + ' (' + pct(b.correct, b.total) + '%)</span></div><div class="bar"><i style="width:' + pct(b.correct, b.total) + '%"></i></div></div>';
        }).join('') : '<p class="muted small">Belum ada data.</p>') +
        '<h3 class="bold" style="font-size:16px;margin-top:8px">Akurasi per jenis soal</h3>' + (types.length ? types.slice().sort(function (a, b) { return pct(a.correct, a.total) - pct(b.correct, b.total); }).map(function (b) {
          return barRow(esc(b.type), '', b.correct, b.total);
        }).join('') : '<p class="muted small">Belum ada data.</p>') + '</div></div>' + progHtml);
    });
  }
  async function setAvatar(color, extra) {
    try { S.me = await Api.call('app_set_avatar', { p_color: color + (extra ? '|' + extra : '') }); toast('Profil diperbarui.'); profileView(); }
    catch (e) { toast(e.message, true); }
  }
  H.avatar = function (el) { return setAvatar(el.dataset.v, avParts(S.me.avatar_color).extra); };
  H['avatar-emoji'] = function (el) { return setAvatar(avParts(S.me.avatar_color).color, el.dataset.v); };
  H['avatar-clear'] = function () { return setAvatar(avParts(S.me.avatar_color).color, ''); };
  H['avatar-photo'] = function (el) {
    var f = el.files && el.files[0]; if (!f) return;
    if (!/^image\//.test(f.type)) { toast('Pilih file gambar.', true); return; }
    var rd = new FileReader();
    rd.onload = function () {
      var img = new Image();
      img.onload = function () {
        var n = 112, c = document.createElement('canvas'); c.width = n; c.height = n;
        var side = Math.min(img.width, img.height), sx = (img.width - side) / 2, sy = (img.height - side) / 2;
        var g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, n, n); g.drawImage(img, sx, sy, side, side, 0, 0, n, n);
        var url = c.toDataURL('image/jpeg', 0.75);
        setAvatar(avParts(S.me.avatar_color).color, url);
      };
      img.onerror = function () { toast('Gambar tidak bisa dibaca.', true); };
      img.src = rd.result;
    };
    rd.readAsDataURL(f);
    el.value = '';
  };
  H.rename = async function (f, e) {
    if (e && e.preventDefault) e.preventDefault();
    try { S.me = await Api.call('app_update_name', { p_name: f.elements.nama.value }); toast('Nama diganti.'); profileView(); }
    catch (er) { toast(er.message, true); }
  };
  H.repin = async function (f, e) {
    if (e && e.preventDefault) e.preventDefault();
    try { await Api.call('app_change_pin', { p_old: f.elements.lama.value, p_new: f.elements.baru.value }); f.reset(); toast('PIN diganti. Pakai PIN baru saat masuk berikutnya.'); }
    catch (er) { toast(er.message, true); }
  };

  /* ---------- router ---------- */
  function parseHash() {
    var p = location.hash.replace(/^#\/?/, '').split('/');
    return { name: p[0] || '', a: p[1] || '', b: p[2] || '', c: p[3] || '' };
  }

  async function route() {
    S.rt = (S.rt || 0) + 1;
    runCleanups();
    S.exam = null;
    var r = parseHash();
    if (!Api.getToken()) return loginView();
    if (!S.me) {
      try { S.me = await Api.call('app_me'); }
      catch (e) {
        if (e.code === '28000') { Api.setToken(null); return loginView(); }
        root.innerHTML = '<main class="wrap">' + errorCard(e) + '</main>'; return;
      }
    }
    window.scrollTo(0, 0);
    switch (r.name) {
      case 'ujian': return examView(r.a);
      case 'hasil': return resultView(r.a);
      case 'latihan': return drillView();
      case 'tinjau': return reviewView(r.a, r.b);
      case 'hasilpeserta':
        if (S.me.role !== 'admin') return go('#/home');
        return resultView(r.a, r.b);
      case 'tinjaupeserta':
        if (S.me.role !== 'admin') return go('#/home');
        return reviewView(r.a, r.c, r.b);
      case 'peringkat': return rankView(r.a);
      case 'profil': return profileView();
      case 'admin':
        if (S.me.role !== 'admin') return go('#/home');
        return window.AdminUI ? window.AdminUI.view(r.a || 'sesi') : go('#/home');
      case 'login': return go('#/home');
      default: return homeView();
    }
  }

  function start() {
    root.addEventListener('click', function (e) {
      var el = e.target.closest('[data-act]');
      if (!el || el.disabled) return;
      var f = H[el.dataset.act];
      if (f) { if (el.tagName === 'A' || el.tagName === 'BUTTON') e.preventDefault(); f(el, e); }
    });
    root.addEventListener('submit', function (e) {
      var f = e.target.closest('form[data-submit]');
      if (!f) return;
      e.preventDefault();
      var h = H[f.dataset.submit];
      if (h) h(f, e);
    });
    root.addEventListener('input', function (e) {
      var el = e.target.closest('[data-input]');
      if (el && H[el.dataset.input]) H[el.dataset.input](el, e);
    });
    root.addEventListener('change', function (e) {
      var el = e.target.closest('[data-change]');
      if (el && H[el.dataset.change]) H[el.dataset.change](el, e);
    });
    window.addEventListener('hashchange', route);
    route();
  }

  window.App = {
    start: start, H: H, S: S, esc: esc, pad: pad, clock: clock, pct: pct, avatar: avatar, toast: toast, go: go,
    shell: shell, setMain: setMain, guard: guard, errorCard: errorCard, dialog: dialog, confirmDialog: confirmDialog,
    promptDialog: promptDialog, route: route, fresh: fresh, FB_LABEL: FB_LABEL, fbLabel: fbLabel, onCleanup: onCleanup
  };
})();
