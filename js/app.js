/* Ruang Ujian: halaman peserta (masuk, sesi, ujian, hasil, peringkat, profil). */
(function () {
  'use strict';

  var root = document.getElementById('app');
  var S = { me: null, exam: null, result: null, onlyWrong: false };
  var H = {};          // penangan klik/submit/change, berdasarkan nama
  var cleanups = [];   // fungsi pembersih saat pindah halaman

  var AVATARS = ['#0E6A73', '#2F6DA8', '#7A4E9C', '#A5551C', '#B13A5F', '#5E7A1F', '#4A5A66', '#8A6A00'];
  var FB_LABEL = { each: 'Kunci tampil per nomor', '10': 'Kunci tampil tiap 10 soal', '20': 'Kunci tampil tiap 20 soal', end: 'Kunci tampil di akhir' };
  function fbLabel(m) { return FB_LABEL[m] || (/^\d+$/.test(m || '') ? 'Kunci tampil tiap ' + (+m) + ' soal' : ''); }

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
  function pct(a, b) { return b ? Math.round((a / b) * 100) : 0; }
  function initial(name) { return esc(String(name || '?').trim().charAt(0).toUpperCase()); }
  function avatar(name, color, cls) {
    return '<span class="avatar ' + (cls || '') + '" style="background:' + esc(color || '#0E6A73') + '" aria-hidden="true">' + initial(name) + '</span>';
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
    var links = [['home', '#/home', 'Sesi'], ['peringkat', '#/peringkat', 'Peringkat'], ['profil', '#/profil', 'Profil']];
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
      var list = await Api.call('app_sessions');
      if (!ok()) return;
      var open = list.filter(function (s) { return s.status === 'open' || s.started; });
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
    if (s.done) action = '<a class="btn btn-primary" href="#/hasil/' + s.id + '">Lihat hasil</a>';
    else if (s.started) action = '<a class="btn btn-primary" href="#/ujian/' + s.id + '">Lanjutkan</a>';
    else if (s.status === 'open') action = '<a class="btn btn-primary" href="#/ujian/' + s.id + '">Mulai</a>';
    else action = '<button class="btn" type="button" disabled>Ditutup</button>';
    var badge = s.done ? '<span class="badge b-ok">Selesai: ' + s.score + ' / ' + s.total + '</span>'
      : s.started ? '<span class="badge b-warn">Sedang dikerjakan</span>'
      : s.status === 'open' ? '<span class="badge b-info">Terbuka</span>' : '<span class="badge b-bad">Ditutup</span>';
    return '<div class="session"><div><h3>' + esc(s.title) + '</h3><div class="meta"><span>' + s.total + ' soal</span><span>' +
      (s.timer_minutes ? s.timer_minutes + ' menit' : 'Tanpa timer') + '</span><span>' + esc(fbLabel(s.feedback_mode)) +
      '</span><span>' + s.finished + ' peserta selesai</span></div></div><div class="row row-c">' + badge + action + '</div></div>';
  }

  /* ---------- ujian ---------- */
  function cur() { return S.exam.qs[S.exam.idx]; }

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
      idx: 0, startedAt: Date.now() - (d.elapsed || 0) * 1000, dirty: false, chain: Promise.resolve(),
      saveT: null, panel: false, submitting: false, saveState: ''
    };
    E.endAt = d.session.timer_minutes ? E.startedAt + d.session.timer_minutes * 60000 : null;
    var first = E.qs.findIndex(function (q) { return !E.answers[q.id]; });
    E.idx = first < 0 ? 0 : first;

    if (E.session.feedback_mode !== 'end') {
      var answered = E.qs.filter(function (q) { return E.answers[q.id]; }).map(function (q) { return q.id; });
      if (answered.length) {
        try { Object.assign(E.keys, await Api.call('app_reveal', { p_session: id, p_qids: answered })); } catch (e) { /* abaikan */ }
      }
    }
    if (!ok() || S.exam !== E) return;
    renderExam();
    var tick = setInterval(tickTimer, 1000);
    onCleanup(function () { clearInterval(tick); clearTimeout(E.saveT); document.removeEventListener('keydown', onExamKey); });
    document.addEventListener('keydown', onExamKey);
    tickTimer();
  }

  function tickTimer() {
    var E = S.exam; if (!E) return;
    var el = document.getElementById('timer'); if (!el) return;
    if (E.endAt) {
      var left = (E.endAt - Date.now()) / 1000;
      el.textContent = 'Sisa waktu ' + clock(left);
      el.className = 'timer' + (left <= 300 ? ' low' : '');
      if (left <= 0 && !E.submitting) {
        toast('Waktu habis. Jawabanmu dikumpulkan otomatis.');
        doSubmit(true);
      }
    } else {
      el.textContent = 'Berjalan ' + clock((Date.now() - E.startedAt) / 1000);
    }
  }

  function blockInfo(E, idx) {
    var m = E.session.feedback_mode;
    if (!/^\d+$/.test(m || '')) return null;
    var n = +m, total = E.qs.length, s = Math.floor(idx / n) * n, e = Math.min(s + n, total) - 1;
    var left = 0;
    for (var i = s; i <= e; i++) if (!E.answers[E.qs[i].id]) left++;
    return { start: s, end: e, left: left };
  }

  function renderExam() {
    var E = S.exam; if (!E) return;
    var q = cur(), total = E.qs.length;
    var answeredN = E.qs.filter(function (x) { return E.answers[x.id]; }).length;
    var key = E.keys[q.id], sel = E.answers[q.id];
    var letters = ['A', 'B', 'C', 'D', 'E'];
    var img = safeImg(q.image);

    var opts = q.options.map(function (t, i) {
      var L = letters[i], cls = '', tag = '';
      if (key) {
        if (L === key) { cls = 'key'; tag = sel === key ? 'Kunci (jawabanmu)' : 'Kunci'; }
        else if (L === sel) { cls = 'wrong'; tag = 'Jawabanmu'; }
      } else if (L === sel) cls = 'sel';
      return '<button type="button" class="opt ' + cls + '" data-act="pick" data-v="' + L + '" data-l="' + L + '"' + (key || E.submitting ? ' disabled' : '') +
        ' aria-pressed="' + (L === sel) + '"><span class="l">' + L + '</span><span class="t">' + esc(t) + '</span>' +
        (tag ? '<span class="tag">' + tag + '</span>' : '') + '</button>';
    }).join('');

    var status = '';
    if (key) status = sel === key ? '<span class="badge b-ok">Benar</span>' : '<span class="badge b-bad">Salah</span>';
    var bi = blockInfo(E, E.idx), blockMsg = '';
    if (bi && !key) {
      blockMsg = '<div class="notice">Kunci blok soal ' + (bi.start + 1) + ' sampai ' + (bi.end + 1) + ' tampil setelah semuanya dijawab' +
        (bi.left ? ' (' + bi.left + ' soal lagi).' : '.') + '</div>';
    }

    var nav = E.qs.map(function (x, i) {
      var c = 'nav-n';
      if (E.answers[x.id]) c += ' ans';
      if (E.flags[x.id]) c += ' flag';
      if (i === E.idx) c += ' cur';
      if (E.keys[x.id]) c += E.keys[x.id] === E.answers[x.id] ? ' right' : ' miss';
      return '<button type="button" class="' + c + '" data-act="goto" data-v="' + i + '" aria-label="Soal ' + (i + 1) +
        (E.answers[x.id] ? ', sudah dijawab' : ', belum dijawab') + (E.flags[x.id] ? ', ragu-ragu' : '') + (i === E.idx ? ', soal saat ini' : '') + '">' + (i + 1) + '</button>';
    }).join('');

    var flagged = !!E.flags[q.id];
    root.innerHTML =
      '<div class="exam-head"><div class="col" style="gap:0"><span class="small bold muted">Sesi</span><span class="bold" style="font-size:18px">' + esc(E.session.title) + '</span></div>' +
      '<div class="row row-c" style="gap:14px"><span class="bold">Soal ' + (E.idx + 1) + ' dari ' + total + '</span>' +
      '<span id="timer" class="timer">--:--</span>' +
      '<span class="small muted" id="savestate" role="status">' + esc(E.saveState) + '</span>' +
      '<button class="btn btn-primary" type="button" data-act="exam-submit"' + (E.submitting ? ' disabled' : '') + '>Kumpulkan</button></div></div>' +
      '<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="' + total + '" aria-valuenow="' + answeredN + '"><i style="width:' + pct(answeredN, total) + '%"></i></div>' +
      '<div class="exam-body"><div class="exam-main"><div class="qcard">' +
      '<div class="row row-c"><span class="chip">Asal soal: ' + esc(q.bank) + '</span><span class="small bold muted">Soal ' + (E.idx + 1) + '</span>' + status + '</div>' +
      '<p class="stem">' + esc(q.stem) + '</p>' + (img ? '<img class="qimg" src="' + img + '" alt="Gambar pada soal">' : '') +
      '<div class="opts" role="group" aria-label="Pilihan jawaban">' + opts + '</div>' + blockMsg + '</div>' +
      '<div class="nav-actions exam-foot"><button class="btn" type="button" data-act="prev"' + (E.idx === 0 ? ' disabled' : '') + '>Sebelumnya</button>' +
      '<button class="btn btn-warn' + (flagged ? ' on' : '') + '" type="button" data-act="flag" aria-pressed="' + flagged + '">' + (flagged ? 'Hapus tanda ragu-ragu' : 'Tandai ragu-ragu') + '</button>' +
      '<button class="btn only-mobile" type="button" data-act="panel">Daftar soal</button>' +
      '<button class="btn btn-primary" type="button" data-act="next"' + (E.idx === total - 1 ? ' disabled' : '') + '>Selanjutnya</button></div></div>' +
      '<aside class="exam-side' + (E.panel ? '' : ' closed') + '" aria-label="Navigasi soal"><span class="bold" style="font-size:16px">Navigasi soal</span>' +
      '<div class="nav-grid">' + nav + '</div>' +
      '<div class="legend"><span><i style="background:var(--primary)"></i>Sudah dijawab</span>' +
      '<span><i style="background:var(--warn-bg);border:2px dashed var(--warn-line)"></i>Ragu-ragu</span>' +
      '<span><i style="background:#fff;border:1px solid var(--field)"></i>Belum dijawab</span>' +
      '<span><i style="background:#fff;border:3px solid var(--ink)"></i>Soal saat ini</span>' +
      (E.session.feedback_mode !== 'end' ? '<span><i style="background:#fff;border:1px solid var(--field);box-shadow:inset 0 -4px 0 #1C7C4D"></i>Garis hijau: benar</span><span><i style="background:#fff;border:1px solid var(--field);box-shadow:inset 0 -4px 0 #B3261E"></i>Garis merah: salah</span>' : '') +
      '</div><p class="small muted">' + esc(fbLabel(E.session.feedback_mode)) + '. Jawaban tersimpan otomatis.</p></aside></div>';
    tickTimer();
  }

  function onExamKey(e) {
    var E = S.exam; if (!E || e.ctrlKey || e.metaKey || e.altKey) return;
    var tg = e.target && e.target.tagName;
    if (tg === 'INPUT' || tg === 'TEXTAREA' || tg === 'SELECT') return;
    if (document.querySelector('.overlay')) return;
    var k = e.key;
    if (k === 'ArrowRight') { H.next(); e.preventDefault(); }
    else if (k === 'ArrowLeft') { H.prev(); e.preventDefault(); }
    else if (/^[a-eA-E]$/.test(k)) { pickLetter(k.toUpperCase()); }
    else if (/^[1-5]$/.test(k)) { pickLetter('ABCDE'.charAt(+k - 1)); }
  }

  function focusOpt(L) { var b = root.querySelector('.opt[data-l="' + L + '"]'); if (b) b.focus(); }

  function pickLetter(L) {
    var E = S.exam; if (!E || E.submitting) return;
    var q = cur();
    if (E.keys[q.id]) return;
    if (q.options.length <= 'ABCDE'.indexOf(L)) return;
    if (E.answers[q.id] === L) delete E.answers[q.id]; else E.answers[q.id] = L;
    renderExam(); focusOpt(L);
    queueSave();
    maybeReveal();
  }
  H.pick = function (el) { pickLetter(el.dataset.v); };
  H.goto = function (el) { S.exam.idx = +el.dataset.v; S.exam.panel = false; renderExam(); window.scrollTo(0, 0); };
  H.next = function () { var E = S.exam; if (E && E.idx < E.qs.length - 1) { E.idx++; renderExam(); window.scrollTo(0, 0); } };
  H.prev = function () { var E = S.exam; if (E && E.idx > 0) { E.idx--; renderExam(); window.scrollTo(0, 0); } };
  H.panel = function () { S.exam.panel = !S.exam.panel; renderExam(); };
  H.flag = function () {
    var E = S.exam, q = cur();
    if (E.flags[q.id]) delete E.flags[q.id]; else E.flags[q.id] = true;
    renderExam(); queueSave();
  };

  function setSaveState(t) {
    var E = S.exam; if (!E) return;
    E.saveState = t;
    var el = document.getElementById('savestate'); if (el) el.textContent = t;
  }
  function queueSave() {
    var E = S.exam; if (!E) return;
    E.dirty = true;
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
      } catch (err) {
        E.dirty = true;
        if (err.code === '28000') { toast('Sesi login berakhir. Masuk lagi untuk melanjutkan.', true); return; }
        setSaveState('Gagal menyimpan, mencoba lagi...');
        clearTimeout(E.saveT);
        E.saveT = setTimeout(flushSave, 5000);
      }
    });
    return E.chain;
  }

  async function maybeReveal() {
    var E = S.exam; if (!E) return;
    var m = E.session.feedback_mode;
    if (m === 'end') return;
    var q = cur(), ids = [];
    if (m === 'each') {
      if (E.answers[q.id] && !E.keys[q.id]) ids = [q.id];
    } else {
      var bi = blockInfo(E, E.idx);
      if (bi && bi.left === 0) {
        for (var i = bi.start; i <= bi.end; i++) if (!E.keys[E.qs[i].id]) ids.push(E.qs[i].id);
      }
    }
    if (!ids.length) return;
    await flushSave();
    try {
      var k = await Api.call('app_reveal', { p_session: E.id, p_qids: ids });
      if (S.exam !== E) return;
      Object.assign(E.keys, k);
      renderExam();
      if (m !== 'each' && Object.keys(k).length) toast('Kunci blok soal ditampilkan.');
    } catch (err) { toast(err.message, true); }
  }

  H['exam-submit'] = async function () {
    var E = S.exam; if (!E || E.submitting) return;
    var un = E.qs.filter(function (q) { return !E.answers[q.id]; }).length;
    var fl = E.qs.filter(function (q) { return E.flags[q.id]; }).length;
    var parts = [];
    if (un) parts.push(un + ' soal belum dijawab');
    if (fl) parts.push(fl + ' soal ditandai ragu-ragu');
    var ok = await confirmDialog('Kumpulkan jawaban?', (parts.length ? parts.join(', ') + '. ' : 'Semua soal sudah dijawab. ') + 'Setelah dikumpulkan, jawaban tidak bisa diubah.', 'Kumpulkan', false);
    if (ok) doSubmit(false);
  };

  async function doSubmit(auto) {
    var E = S.exam; if (!E || E.submitting) return;
    E.submitting = true;
    renderExam();
    try {
      await flushSave();
      await Api.call('app_submit', { p_session: E.id, p_answers: E.answers, p_flags: E.flags });
      var id = E.id;
      S.exam = null;
      go('#/hasil/' + id);
    } catch (err) {
      E.submitting = false;
      renderExam();
      toast(err.message, true);
      if (auto) setTimeout(function () { if (S.exam === E) doSubmit(true); }, 5000);
    }
  }

  /* ---------- hasil ---------- */
  async function resultView(id) {
    shell('home');
    var ok = fresh();
    await guard(async function () {
      var res = await Api.call('app_result', { p_session: id });
      if (!ok()) return;
      S.result = res;
      S.result.id = id;
      S.onlyWrong = false;
      renderResult();
    });
  }
  function statusBadge(r) {
    if (r.ok === true) return '<span class="badge b-ok">Benar</span>';
    if (r.ok === false) return '<span class="badge b-bad">Salah</span>';
    return '<span class="badge b-warn">Tidak dijawab</span>';
  }
  function renderResult() {
    var r = S.result;
    var rows = r.rows.filter(function (x) { return !S.onlyWrong || x.ok !== true; });
    setMain(
      '<div class="row row-c between"><div class="col" style="gap:4px"><span class="page-sub">' + esc(r.title) + '</span><h1 class="page-title">Hasil akhir</h1></div>' +
      '<a class="btn btn-primary" href="#/peringkat/' + r.id + '">Lihat peringkat</a></div>' +
      '<div class="row"><div class="stat"><span class="page-sub">Skor</span><b style="color:var(--primary-dark)">' + r.score + ' / ' + r.total + '</b><span class="small muted">' + pct(r.score, r.total) + ' persen benar</span></div>' +
      '<div class="stat"><span class="page-sub">Waktu</span><b>' + clock(r.time_taken) + '</b><span class="small muted">menit:detik</span></div>' +
      '<div class="stat"><span class="page-sub">Peringkat sesi ini</span><b>' + r.rank + ' dari ' + r.participants + '</b><span class="small muted">urut skor, lalu waktu tercepat</span></div></div>' +
      '<div class="row"><div class="card grow" style="flex:999 1 600px"><div class="row row-c between"><h2 class="bold" style="font-size:18px">Rincian per nomor</h2>' +
      '<label class="row row-c small bold" style="gap:8px;cursor:pointer"><input type="checkbox" data-change="only-wrong"' + (S.onlyWrong ? ' checked' : '') + ' style="width:18px;height:18px;accent-color:var(--primary)">Hanya yang salah / kosong</label></div>' +
      '<div class="scroll-x"><table class="table"><thead><tr><th>No</th><th>Asal soal</th><th>Jawabanmu</th><th>Kunci</th><th>Status</th></tr></thead><tbody>' +
      (rows.length ? rows.map(function (x) {
        return '<tr><td class="bold">' + x.no + (x.flag ? ' <span class="small muted" title="Ditandai ragu-ragu">(?)</span>' : '') + '</td><td>' + esc(x.bank) + '</td><td class="bold">' + esc(x.mine) + '</td><td class="bold">' + esc(x.key || '-') + '</td><td>' + statusBadge(x) + '</td></tr>';
      }).join('') : '<tr><td colspan="5" class="muted">Tidak ada baris.</td></tr>') +
      '</tbody></table></div><p class="small muted">Tidak ada pembahasan: hanya kunci jawaban dan status.</p></div>' +
      '<div class="card grow" style="flex:1 1 320px;max-width:420px"><h2 class="bold" style="font-size:18px">Rekap per file</h2>' +
      r.banks.map(function (b) {
        return '<div class="col" style="gap:6px"><div class="row between small" style="gap:12px"><span class="bold">' + esc(b.bank) + '</span><span class="bold">' + b.correct + ' dari ' + b.total + ' (' + pct(b.correct, b.total) + '%)</span></div>' +
          '<div class="bar"><i style="width:' + pct(b.correct, b.total) + '%"></i></div></div>';
      }).join('') + '<p class="small muted">File dengan persentase paling rendah adalah bidang yang perlu diulang.</p></div></div>');
  }
  H['only-wrong'] = function (el) { S.onlyWrong = el.checked; renderResult(); };

  /* ---------- peringkat ---------- */
  async function rankView(which) {
    shell('peringkat');
    var ok = fresh();
    await guard(async function () {
      var sessions = await Api.call('app_sessions');
      if (!ok()) return;
      var withData = sessions.filter(function (s) { return s.finished > 0; });
      var sel = which || (withData.length ? withData[0].id : 'semua');
      var board = await Api.call('app_leaderboard', sel === 'semua' ? {} : { p_session: sel });
      if (!ok()) return;
      var all = sel === 'semua';
      var opts = '<option value="semua"' + (all ? ' selected' : '') + '>Semua sesi (akumulasi)</option>' + withData.map(function (s) {
        return '<option value="' + s.id + '"' + (s.id === sel ? ' selected' : '') + '>' + esc(s.title) + '</option>';
      }).join('');
      var cur = sessions.filter(function (s) { return s.id === sel; })[0];
      setMain('<div class="row row-c between"><h1 class="page-title">Peringkat</h1><div class="field" style="min-width:260px"><label for="rk">Tampilkan</label><select id="rk" class="input" data-change="rank-pick">' + opts + '</select></div></div>' +
        '<div class="card"><h2 class="bold" style="font-size:18px">' + (all ? 'Peringkat akumulasi semua sesi' : 'Peringkat: ' + esc(cur ? cur.title : '')) + '</h2>' +
        (board.length ? '<div class="scroll-x"><table class="table"><thead><tr><th>Urutan</th><th>Peserta</th><th>Skor</th>' + (all ? '<th>Akurasi</th><th>Sesi</th>' : '') + '<th>Waktu</th></tr></thead><tbody>' +
          board.map(function (b) {
            return '<tr class="' + (b.me ? 'me' : '') + '"><td class="bold">' + b.rank + '</td><td><span class="row row-c" style="gap:10px;flex-wrap:nowrap">' + avatar(b.name, b.avatar_color) + '<span class="bold">' + esc(b.name) + '</span>' + (b.me ? '<span class="chip">Kamu</span>' : '') + '</span></td>' +
              '<td class="bold">' + b.score + ' / ' + b.total + '</td>' + (all ? '<td>' + pct(b.score, b.total) + '%</td><td>' + b.sessions + '</td>' : '') + '<td>' + clock(b.time_taken) + '</td></tr>';
          }).join('') + '</tbody></table></div>' : '<p class="muted">Belum ada yang menyelesaikan sesi ini.</p>') +
        '<p class="small muted">Diurutkan menurut skor tertinggi; bila sama, waktu tercepat berada di atas.</p></div>');
    });
  }
  H['rank-pick'] = function (el) { go('#/peringkat/' + el.value); };

  /* ---------- profil ---------- */
  async function profileView() {
    shell('profil');
    var ok = fresh();
    await guard(async function () {
      var d = await Api.call('app_history');
      if (!ok()) return;
      var me = S.me;
      var hist = d.history, banks = d.banks;
      var sumS = 0, sumT = 0;
      hist.forEach(function (h) { sumS += h.score; sumT += h.total; });
      var ranked = banks.filter(function (b) { return b.total >= 3; });
      if (!ranked.length) ranked = banks;
      ranked = ranked.slice().sort(function (a, b) { return pct(b.correct, b.total) - pct(a.correct, a.total); });
      var best = ranked[0], worst = ranked.length > 1 ? ranked[ranked.length - 1] : null;
      var last = hist.slice(-12);
      var first = hist.length ? pct(hist[0].score, hist[0].total) : 0, lastP = hist.length ? pct(hist[hist.length - 1].score, hist[hist.length - 1].total) : 0;
      setMain('<h1 class="page-title">Profil</h1><div class="row"><div class="col grow" style="max-width:480px">' +
        '<div class="card"><div class="row row-c" style="gap:16px;flex-wrap:nowrap">' + avatar(me.name, me.avatar_color, 'avatar-lg') +
        '<div class="col" style="gap:2px"><span class="bold" style="font-size:20px">' + esc(me.name) + '</span><span class="small muted">' + (me.role === 'admin' ? 'Admin' : 'Peserta') + '</span></div></div>' +
        '<div class="col" style="gap:8px"><span class="small bold">Warna avatar</span><div class="swatches">' + AVATARS.map(function (c) {
          return '<button type="button" class="swatch' + (c === me.avatar_color ? ' on' : '') + '" style="background:' + c + '" data-act="avatar" data-v="' + c + '" aria-label="Pilih warna ' + c + '" aria-pressed="' + (c === me.avatar_color) + '"></button>';
        }).join('') + '</div></div>' +
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
        '<h3 class="bold" style="font-size:16px;margin-top:8px">Akurasi per file</h3>' + (banks.length ? banks.map(function (b) {
          return '<div class="col" style="gap:6px"><div class="row between small" style="gap:12px"><span class="bold">' + esc(b.bank) + '</span><span class="bold">' + b.correct + ' dari ' + b.total + ' (' + pct(b.correct, b.total) + '%)</span></div><div class="bar"><i style="width:' + pct(b.correct, b.total) + '%"></i></div></div>';
        }).join('') : '<p class="muted small">Belum ada data.</p>') + '</div></div>');
    });
  }
  H.avatar = async function (el) {
    try { S.me = await Api.call('app_set_avatar', { p_color: el.dataset.v }); profileView(); }
    catch (e) { toast(e.message, true); }
  };

  /* ---------- router ---------- */
  function parseHash() {
    var p = location.hash.replace(/^#\/?/, '').split('/');
    return { name: p[0] || '', a: p[1] || '', b: p[2] || '' };
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
