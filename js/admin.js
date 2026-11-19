/* Ruang Ujian: halaman admin (sesi, impor soal, peserta). */
(function () {
  'use strict';
  var A = window.App, H = A.H, esc = A.esc;
  var ST = { banks: [], sessions: [], people: [], im: null, openBank: null, qlist: [], saving: false };

  var LIBS = {
    mammoth: 'https://cdnjs.cloudflare.com/ajax/libs/mammoth/1.6.0/mammoth.browser.min.js',
    xlsx: 'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js',
    pdf: 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js'
  };
  var PDF_WORKER = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
  var loaded = {};
  function loadLib(name) {
    if (loaded[name]) return loaded[name];
    loaded[name] = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = LIBS[name];
      s.onload = resolve;
      s.onerror = function () { delete loaded[name]; reject(new Error('Gagal memuat pustaka pembaca file (' + name + '). Periksa koneksi internet.')); };
      document.head.appendChild(s);
    });
    return loaded[name];
  }

  function tabs(active) {
    var t = [['sesi', 'Sesi'], ['soal', 'Soal'], ['peserta', 'Peserta']];
    return '<div class="row row-c between"><h1 class="page-title">Panel admin</h1><div class="seg" role="tablist" style="min-width:280px">' + t.map(function (x) {
      return '<a role="tab" class="' + (x[0] === active ? 'on' : '') + '" href="#/admin/' + x[0] + '" style="flex:1 1 90px;text-align:center;padding:10px 0;border-radius:8px;text-decoration:none;font-weight:' + (x[0] === active ? 700 : 600) + ';font-size:14px;color:' + (x[0] === active ? 'var(--primary-dark)' : 'var(--muted)') + ';' + (x[0] === active ? 'background:#fff' : '') + '">' + x[1] + '</a>';
    }).join('') + '</div></div>';
  }

  async function view(tab) {
    A.shell('admin');
    var ok = A.fresh();
    await A.guard(async function () {
      if (tab === 'soal') return soalTab(ok);
      if (tab === 'peserta') return pesertaTab(ok);
      return sesiTab(ok);
    });
  }

  /* ================= SESI ================= */
  function onTab(t) { return function () { return location.hash.indexOf('#/admin/' + t) === 0 || (t === 'sesi' && location.hash === '#/admin'); }; }
  async function sesiTab(ok) {
    ok = ok || onTab('sesi');
    var r = await Promise.all([Api.call('adm_banks'), Api.call('adm_sessions')]);
    if (!ok()) return;
    ST.banks = r[0]; ST.sessions = r[1];
    renderSesi();
  }
  function renderSesi() {
    var avail = ST.banks.filter(function (b) { return b.active > 0; });
    var def = Math.min(50, avail.reduce(function (n, b) { return n + b.active; }, 0)) || 10;
    var html = tabs('sesi') + '<div class="row"><form class="card grow" style="flex:1 1 460px" data-submit="create-session">' +
      '<h2 class="bold" style="font-size:20px">Buat sesi baru</h2>' +
      '<div class="field"><label for="ns">Nama sesi</label><input id="ns" name="title" class="input" value="Sesi ' + (ST.sessions.length + 1) + '" maxlength="80" required></div>' +
      '<div class="col" style="gap:10px"><span class="label">Ambil soal dari file/bidang</span>' +
      (avail.length ? avail.map(function (b) {
        return '<label class="checkrow"><span class="row row-c" style="gap:12px;flex-wrap:nowrap"><input type="checkbox" name="bank" value="' + b.id + '" data-n="' + b.active + '" data-change="pool-calc" checked><span class="bold">' + esc(b.name) + '</span></span><span class="small muted">' + b.active + ' soal</span></label>';
      }).join('') : '<p class="muted">Belum ada soal. Impor dulu di tab Soal.</p>') + '<p class="small muted" id="poolinfo"></p></div>' +
      '<div class="row"><div class="field grow" style="flex:1 1 150px"><label for="jml">Jumlah soal</label><input id="jml" name="count" class="input" type="number" min="1" max="500" value="' + def + '" required></div>' +
      '<div class="field grow" style="flex:1 1 150px"><label for="tmr">Timer (menit, kosong = tanpa timer)</label><input id="tmr" name="timer" class="input" type="number" min="1" max="600" placeholder="tanpa timer"></div></div>' +
      '<div class="col" style="gap:8px"><span class="label">Kapan benar/salah dan kunci ditampilkan</span><div class="seg">' +
      [['each', 'Per nomor'], ['10', 'Per 10'], ['20', 'Per 20'], ['custom', 'Atur sendiri'], ['end', 'Di akhir']].map(function (f) {
        return '<label class="' + (f[0] === 'end' ? 'on' : '') + '"><input type="radio" name="fb" value="' + f[0] + '"' + (f[0] === 'end' ? ' checked' : '') + ' data-change="fb-pick">' + f[1] + '</label>';
      }).join('') + '</div>' +
      '<div class="field" id="fbn-wrap" style="display:none"><label for="fbn">Tampilkan kunci setiap berapa nomor?</label><input id="fbn" name="fbn" class="input" type="number" min="1" max="500" placeholder="contoh: 5" style="max-width:180px"></div></div>' +
      '<button class="btn btn-primary" style="height:50px" type="submit"' + (avail.length ? '' : ' disabled') + '>Buat sesi dan acak soal</button>' +
      '<p class="small muted">Soal diacak satu kali saat sesi dibuat, jadi semua peserta mendapat set yang sama.</p></form>' +
      '<div class="card grow" style="flex:1 1 460px"><h2 class="bold" style="font-size:20px">Daftar sesi</h2>' +
      (ST.sessions.length ? '<div class="scroll-x"><table class="table"><thead><tr><th>Sesi</th><th>Soal</th><th>Selesai</th><th>Status</th><th>Aksi</th></tr></thead><tbody>' +
        ST.sessions.map(function (s) {
          return '<tr><td><span class="bold">' + esc(s.title) + '</span><div class="small muted">' + (s.timer_minutes ? s.timer_minutes + ' menit' : 'tanpa timer') + ' · ' + esc(A.fbLabel(s.feedback_mode)) + '</div></td>' +
            '<td>' + s.total + '</td><td>' + s.finished + (s.ongoing ? ' <span class="small muted">(+' + s.ongoing + ' berjalan)</span>' : '') + '</td>' +
            '<td>' + (s.status === 'open' ? '<span class="badge b-info">Terbuka</span>' : '<span class="badge b-bad">Ditutup</span>') + '</td>' +
            '<td><div class="row" style="gap:8px"><button class="btn btn-sm" type="button" data-act="sess-toggle" data-v="' + s.id + '" data-s="' + s.status + '">' + (s.status === 'open' ? 'Tutup' : 'Buka') + '</button>' +
            '<a class="btn btn-sm" href="#/peringkat/' + s.id + '">Peringkat</a>' +
            '<button class="btn btn-sm btn-danger" type="button" data-act="sess-del" data-v="' + s.id + '" data-t="' + esc(s.title) + '">Hapus</button></div></td></tr>';
        }).join('') + '</tbody></table></div>' : '<p class="muted">Belum ada sesi.</p>') + '</div></div>';
    A.setMain(html);
    H['pool-calc']();
  }
  H['pool-calc'] = function () {
    var info = document.getElementById('poolinfo'); if (!info) return;
    var n = 0, k = 0;
    document.querySelectorAll('input[name=bank]').forEach(function (c) { if (c.checked) { n += +c.dataset.n; k++; } });
    info.textContent = k ? 'Tersedia ' + n + ' soal dari ' + k + ' file yang dipilih.' : 'Pilih minimal satu file/bidang.';
  };
  H['fb-pick'] = function (el) {
    el.closest('.seg').querySelectorAll('label').forEach(function (l) { l.classList.toggle('on', l.contains(el)); });
    var w = document.getElementById('fbn-wrap'); if (w) w.style.display = el.value === 'custom' ? '' : 'none';
  };
  H['create-session'] = async function (form) {
    var banks = Array.prototype.map.call(form.querySelectorAll('input[name=bank]:checked'), function (c) { return c.value; });
    var timer = form.elements.timer.value.trim();
    var btn = form.querySelector('button[type=submit]');
    var fb = form.elements.fb.value, cnt = parseInt(form.elements.count.value, 10);
    if (fb === 'custom') {
      var nn = parseInt(form.elements.fbn.value, 10);
      if (!nn || nn < 1 || nn > cnt) { A.toast('Isi angka 1 sampai ' + cnt + ' untuk "tiap berapa nomor".', true); return; }
      fb = String(nn);
    }
    btn.disabled = true;
    try {
      await Api.call('adm_create_session', {
        p_title: form.elements.title.value, p_bank_ids: banks, p_count: parseInt(form.elements.count.value, 10),
        p_timer: timer ? parseInt(timer, 10) : null, p_feedback: fb
      });
      A.toast('Sesi dibuat. Peserta bisa langsung mengerjakan.');
      sesiTab();
    } catch (e) { A.toast(e.message, true); btn.disabled = false; }
  };
  H['sess-toggle'] = async function (el) {
    try { await Api.call('adm_set_session_status', { p_session: el.dataset.v, p_status: el.dataset.s === 'open' ? 'closed' : 'open' }); sesiTab(); }
    catch (e) { A.toast(e.message, true); }
  };
  H['sess-del'] = async function (el) {
    var ok = await A.confirmDialog('Hapus sesi?', 'Sesi "' + el.dataset.t + '" beserta semua hasil peserta di dalamnya akan dihapus permanen.', 'Hapus', true);
    if (!ok) return;
    try { await Api.call('adm_delete_session', { p_session: el.dataset.v }); A.toast('Sesi dihapus.'); sesiTab(); }
    catch (e) { A.toast(e.message, true); }
  };

  /* ================= PESERTA ================= */
  async function pesertaTab(ok) {
    ok = ok || onTab('peserta');
    var people = await Api.call('adm_people');
    if (!ok()) return;
    ST.people = people;
    A.setMain(tabs('peserta') + '<div class="card"><h2 class="bold" style="font-size:20px">Peserta dan admin</h2><div class="scroll-x"><table class="table"><thead><tr><th>Nama</th><th>Peran</th><th>Sesi selesai</th><th>Aksi</th></tr></thead><tbody>' +
      ST.people.map(function (p) {
        return '<tr><td><span class="row row-c" style="gap:10px;flex-wrap:nowrap">' + A.avatar(p.name, p.avatar_color) + '<span class="bold">' + esc(p.name) + '</span></span></td>' +
          '<td>' + (p.role === 'admin' ? '<span class="badge b-info">Admin</span>' : 'Peserta') + '</td><td>' + p.done + '</td>' +
          '<td><div class="row" style="gap:8px"><button class="btn btn-sm" type="button" data-act="pin-reset" data-v="' + p.id + '" data-n="' + esc(p.name) + '">Atur ulang PIN</button>' +
          '<button class="btn btn-sm" type="button" data-act="role-toggle" data-v="' + p.id + '" data-r="' + p.role + '">' + (p.role === 'admin' ? 'Jadikan peserta' : 'Jadikan admin') + '</button></div></td></tr>';
      }).join('') + '</tbody></table></div></div>');
  }
  H['pin-reset'] = async function (el) {
    var pin = await A.promptDialog('Atur ulang PIN: ' + el.dataset.n, 'PIN baru (4-6 angka)', 'password');
    if (pin == null) return;
    try { await Api.call('adm_reset_pin', { p_profile: el.dataset.v, p_pin: pin }); A.toast('PIN diganti. Beri tahu pesertanya.'); }
    catch (e) { A.toast(e.message, true); }
  };
  H['role-toggle'] = async function (el) {
    try { await Api.call('adm_set_role', { p_profile: el.dataset.v, p_role: el.dataset.r === 'admin' ? 'peserta' : 'admin' }); pesertaTab(); }
    catch (e) { A.toast(e.message, true); }
  };

  /* ================= SOAL: bank & impor ================= */
  async function soalTab(ok) {
    ok = ok || onTab('soal');
    var banks = await Api.call('adm_banks');
    if (!ok()) return;
    ST.banks = banks;
    renderSoal();
  }

  function renderSoal() {
    A.setMain(tabs('soal') + '<div class="row"><div class="card grow" style="flex:999 1 560px" id="imp-card">' + importHtml() + '</div>' +
      '<div class="card grow" style="flex:1 1 360px;max-width:520px" id="bank-card">' + banksHtml() + '</div></div>');
  }
  function renderImport() { var c = document.getElementById('imp-card'); if (c) c.innerHTML = importHtml(); }

  function banksHtml() {
    return '<h2 class="bold" style="font-size:20px">Bank soal</h2>' + (ST.banks.length ? ST.banks.map(function (b) {
      var open = ST.openBank === b.id;
      return '<div class="col" style="gap:8px;border-bottom:1px solid var(--line-2);padding-bottom:12px"><div class="row row-c between" style="gap:8px"><div><span class="bold">' + esc(b.name) + '</span><div class="small muted">' + b.active + ' aktif dari ' + b.total + ' soal</div></div>' +
        '<div class="row" style="gap:6px;flex-wrap:nowrap"><button class="btn btn-sm" type="button" data-act="bank-open" data-v="' + b.id + '">' + (open ? 'Tutup' : 'Kelola') + '</button><button class="btn btn-sm" type="button" data-act="bank-del" data-v="' + b.id + '" data-t="' + esc(b.name) + '" data-n="' + b.total + '">Hapus bank</button></div></div>' +
        (open ? qlistHtml() : '') + '</div>';
    }).join('') : '<p class="muted">Belum ada soal. Unggah file di sebelah.</p>');
  }
  function qlistHtml() {
    if (!ST.qlist.length) return '<p class="muted small">Tidak ada soal.</p>';
    return '<div style="max-height:420px;overflow:auto">' + ST.qlist.map(function (q) {
      return '<div class="qrow' + (q.active ? '' : ' off') + '"><div class="row row-c between" style="gap:8px;flex-wrap:nowrap"><span class="bold">' + (q.num != null ? q.num + '. ' : '') + esc((q.stem || '').slice(0, 140)) + (q.stem && q.stem.length > 140 ? '...' : '') + '</span>' +
        '<button class="btn btn-sm" type="button" data-act="q-toggle" data-v="' + q.id + '" data-a="' + q.active + '">' + (q.active ? 'Nonaktifkan' : 'Aktifkan') + '</button></div>' +
        '<span class="qopts">Kunci: ' + esc(q.answer || '-') + ' · ' + q.options.length + ' pilihan' + (q.has_image ? ' · ada gambar' : '') + '</span></div>';
    }).join('') + '</div>';
  }
  H['bank-open'] = async function (el) {
    var id = el.dataset.v;
    if (ST.openBank === id) { ST.openBank = null; ST.qlist = []; }
    else {
      try { ST.qlist = await Api.call('adm_questions', { p_bank: id }); ST.openBank = id; }
      catch (e) { return A.toast(e.message, true); }
    }
    document.getElementById('bank-card').innerHTML = banksHtml();
  };
  H['bank-del'] = async function (el) {
    var ok = await A.confirmDialog('Hapus bank soal?', 'Bank "' + el.dataset.t + '" beserta ' + el.dataset.n + ' soal di dalamnya akan dihapus permanen. Sesi yang memakai bank ini akan kehilangan soal tersebut.', 'Hapus', true);
    if (!ok) return;
    try {
      await Api.call('adm_delete_bank', { p_bank: el.dataset.v });
      if (ST.openBank === el.dataset.v) { ST.openBank = null; ST.qlist = []; }
      ST.banks = await Api.call('adm_banks');
      document.getElementById('bank-card').innerHTML = banksHtml();
      A.toast('Bank dihapus.');
    } catch (e) { A.toast(e.message, true); }
  };
  H['q-toggle'] = async function (el) {
    try {
      await Api.call('adm_toggle_question', { p_qid: el.dataset.v, p_active: el.dataset.a !== 'true' });
      ST.banks = await Api.call('adm_banks');
      ST.qlist = await Api.call('adm_questions', { p_bank: ST.openBank });
      document.getElementById('bank-card').innerHTML = banksHtml();
    } catch (e) { A.toast(e.message, true); }
  };

  /* ---------- pembaca file ---------- */
  function rowsToText(rows) { return rows.map(function (r) { return r.join(' '); }).join('\n'); }

  function htmlToText(html) {
    var doc = new DOMParser().parseFromString(html, 'text/html');
    var lines = [], images = [], qn = 0;
    function inline(node) {
      var s = '';
      node.childNodes.forEach(function (c) {
        if (c.nodeType === 3) s += c.nodeValue;
        else if (c.nodeType === 1) {
          var t = c.tagName;
          if (t === 'IMG') { images.push(c.getAttribute('src') || ''); s += ' [[IMG:' + (images.length - 1) + ']] '; }
          else if (t === 'BR') s += '\n';
          else if (t === 'OL' || t === 'UL' || t === 'TABLE') { /* ditangani terpisah */ }
          else s += inline(c);
        }
      });
      return s;
    }
    function looksQuestion(l) { return l && /^\s*(?:soal\s*)?\d{1,3}\s*[\.\):]\s+\S/i.test(l); }
    function walk(nodes, nested) {
      Array.prototype.forEach.call(nodes, function (n) {
        if (n.nodeType === 3) { if (n.nodeValue.trim()) lines.push(n.nodeValue.trim()); return; }
        if (n.nodeType !== 1) return;
        var t = n.tagName;
        if (t === 'OL' || t === 'UL') {
          var items = Array.prototype.filter.call(n.children, function (li) { return li.tagName === 'LI'; });
          var asLetters = nested || (t === 'OL' && items.length <= 5 && looksQuestion(lines[lines.length - 1]));
          items.forEach(function (li, i) {
            var txt = inline(li).trim(), prefix = '';
            if (!/^\s*(?:\d{1,3}|[A-Ea-e])\s*[\.\)]\s/.test(txt)) {
              if (asLetters) prefix = String.fromCharCode(65 + i) + '. ';
              else if (t === 'OL') { qn++; prefix = qn + '. '; }
            }
            if (txt) lines.push(prefix + txt);
            walk(Array.prototype.filter.call(li.children, function (c) { return c.tagName === 'OL' || c.tagName === 'UL' || c.tagName === 'TABLE'; }), true);
          });
        } else if (t === 'TABLE') {
          n.querySelectorAll('tr').forEach(function (tr) {
            var cells = Array.prototype.map.call(tr.children, function (td) { return inline(td).trim(); }).filter(Boolean);
            if (cells.length) lines.push(cells.join(' '));
          });
        } else if (/^(DIV|SECTION|BODY|BLOCKQUOTE|ARTICLE)$/.test(t)) {
          walk(n.childNodes, nested);
        } else {
          var s = inline(n).trim();
          if (s) lines.push(s);
        }
      });
    }
    walk(doc.body.childNodes, false);
    return { text: lines.join('\n'), images: images };
  }

  function shrinkImage(src) {
    return new Promise(function (resolve) {
      if (!/^data:image\//.test(src)) return resolve(null);
      var img = new Image();
      img.onload = function () {
        try {
          var max = 900, w = img.width, h = img.height, k = Math.min(1, max / Math.max(w, h));
          var c = document.createElement('canvas');
          c.width = Math.max(1, Math.round(w * k)); c.height = Math.max(1, Math.round(h * k));
          var ctx = c.getContext('2d');
          ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
          ctx.drawImage(img, 0, 0, c.width, c.height);
          var out = c.toDataURL('image/jpeg', 0.82);
          if (out.length > 700000) out = c.toDataURL('image/jpeg', 0.6);
          resolve(out.length > 900000 ? null : out);
        } catch (e) { resolve(src.length < 900000 ? src : null); }
      };
      img.onerror = function () { resolve(null); };
      img.src = src;
    });
  }

  async function pdfToText(buf) {
    await loadLib('pdf');
    window.pdfjsLib.GlobalWorkerOptions.workerSrc = PDF_WORKER;
    var pdf = await window.pdfjsLib.getDocument({ data: new Uint8Array(buf) }).promise;
    var out = [];
    for (var p = 1; p <= pdf.numPages; p++) {
      var page = await pdf.getPage(p);
      var tc = await page.getTextContent();
      var rows = [];
      tc.items.forEach(function (it) {
        if (!it.str && it.str !== ' ') return;
        var y = Math.round(it.transform[5]), x = it.transform[4], found = null;
        for (var i = 0; i < rows.length; i++) if (Math.abs(rows[i].y - y) <= 2) { found = rows[i]; break; }
        if (!found) { found = { y: y, parts: [] }; rows.push(found); }
        found.parts.push({ x: x, w: it.width, s: it.str });
      });
      rows.sort(function (a, b) { return b.y - a.y; });
      rows.forEach(function (r) {
        r.parts.sort(function (a, b) { return a.x - b.x; });
        var s = '', end = null;
        r.parts.forEach(function (pt) {
          if (end !== null && pt.x - end > 1.5 && s && !/\s$/.test(s) && !/^\s/.test(pt.s)) s += ' ';
          s += pt.s; end = pt.x + pt.w;
        });
        s = s.trim();
        if (s) out.push(s);
      });
      out.push('');
    }
    return out.join('\n');
  }

  /* CSV sederhana: mendukung tanda kutip, pemisah koma / titik koma / tab */
  function parseCsv(text) {
    text = String(text).replace(/^\uFEFF/, '');
    var first = text.split(/\r?\n/)[0] || '';
    var best = ',', bestN = -1;
    [',', ';', '\t'].forEach(function (d) { var n = first.split(d).length; if (n > bestN) { bestN = n; best = d; } });
    var rows = [], row = [], cell = '', q = false;
    for (var i = 0; i < text.length; i++) {
      var c = text.charAt(i);
      if (q) {
        if (c === '"') { if (text.charAt(i + 1) === '"') { cell += '"'; i++; } else q = false; }
        else cell += c;
      } else if (c === '"') q = true;
      else if (c === best) { row.push(cell); cell = ''; }
      else if (c === '\n' || c === '\r') {
        if (c === '\r' && text.charAt(i + 1) === '\n') i++;
        row.push(cell); cell = ''; rows.push(row); row = [];
      } else cell += c;
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
    return rows;
  }

  async function readFile(file) {
    var ext = (file.name.split('.').pop() || '').toLowerCase();
    var buf = await file.arrayBuffer();
    if (ext === 'docx') {
      await loadLib('mammoth');
      var res = await window.mammoth.convertToHtml({ arrayBuffer: buf });
      var t = htmlToText(res.value);
      var imgs = [];
      for (var i = 0; i < t.images.length; i++) imgs.push(await shrinkImage(t.images[i]));
      return { kind: 'text', text: t.text, images: imgs };
    }
    if (ext === 'pdf') return { kind: 'text', text: await pdfToText(buf), images: [], pdf: true };
    if (ext === 'csv') {
      return { kind: 'rows', rows: parseCsv(new TextDecoder('utf-8').decode(buf)) };
    }
    if (ext === 'xlsx' || ext === 'xls') {
      await loadLib('xlsx');
      var wb = window.XLSX.read(buf, { type: 'array' });
      var sheet = wb.Sheets[wb.SheetNames[0]];
      var rows = window.XLSX.utils.sheet_to_json(sheet, { header: 1, raw: false, defval: '' });
      return { kind: 'rows', rows: rows };
    }
    if (ext === 'txt' || ext === 'md') return { kind: 'text', text: new TextDecoder('utf-8').decode(buf), images: [] };
    throw new Error('Format .' + ext + ' belum didukung (pakai .docx, .pdf, .xlsx, .csv, .txt)');
  }

  /* ---------- alur impor ---------- */
  function stripExt(n) { return String(n).replace(/\.[^.]+$/, ''); }

  async function ingest(fileList) {
    var files = Array.prototype.slice.call(fileList || []);
    if (!files.length) return;
    ST.im = { files: [], keyOf: {}, results: [], busy: 'Membaca file...', open: {} };
    renderImport();
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      ST.im.busy = 'Membaca ' + f.name + ' (' + (i + 1) + ' dari ' + files.length + ')...';
      renderImport();
      var entry = { name: f.name, read: null, error: null };
      try { entry.read = await readFile(f); } catch (e) { entry.error = e.message; }
      ST.im.files.push(entry);
    }
    var ok = ST.im.files.filter(function (x) { return !x.error; }).map(function (x) { return x.name; });
    var pf = window.Parser.pairFiles(ok);
    pf.pairs.forEach(function (p) { ST.im.keyOf[p.q] = p.k || ''; });
    ST.im.busy = null;
    buildAll();
    renderImport();
  }

  function fileByName(n) { return ST.im.files.filter(function (x) { return x.name === n; })[0]; }
  function readText(entry) { return entry.read.kind === 'rows' ? rowsToText(entry.read.rows) : entry.read.text; }

  function buildOne(name) {
    var P = window.Parser, f = fileByName(name), rd = f.read, items, keyInFile = false, notes = [];
    if (rd.kind === 'rows') {
      var pr = P.parseQuestionsRows(rd.rows);
      items = pr.items; keyInFile = pr.keyInFile;
      if (!items.length) { items = P.parseQuestionsText(rowsToText(rd.rows)); }
    } else {
      items = P.parseQuestionsText(rd.text, rd.images);
      if (rd.pdf) notes.push('Gambar di dalam PDF tidak ikut terbaca; tambahkan lewat Word/Excel bila perlu.');
    }
    var kf = ST.im.keyOf[name], keyMap = null;
    if (kf) { var k = fileByName(kf); if (k && !k.error) keyMap = P.parseKeyText(readText(k)); }
    P.applyKeys(items, keyMap);
    var old = (ST.im.results.filter(function (r) { return r.name === name; })[0]) || {};
    return { name: name, bank: old.bank || stripExt(name), items: items, keyFile: kf, keyInFile: keyInFile, notes: notes,
             keyCount: keyMap ? Object.keys(keyMap).length : 0, include: old.include !== false };
  }
  function buildAll() {
    var qnames = ST.im.files.filter(function (x) { return !x.error && !window.Parser.isKeyFile(x.name); }).map(function (x) { return x.name; });
    ST.im.results = qnames.map(buildOne);
  }

  function counts(r) {
    var valid = 0, issues = 0;
    r.items.forEach(function (it) { if (window.Parser.validItem(it)) valid++; if (it.warnings.length || !window.Parser.validItem(it)) issues++; });
    return { valid: valid, issues: issues };
  }

  function importHtml() {
    var im = ST.im;
    var html = '<h2 class="bold" style="font-size:20px">Impor soal</h2>' +
      '<label class="dropzone" for="impfile" id="dz"><span class="bold" style="font-size:16px">Unggah file soal dan file kunci</span>' +
      '<span class="small muted">Format .docx, .pdf, .xlsx, .csv, .txt. Kunci dipasangkan lewat nama file (mis. "Kardiologi.docx" dan "Kunci Kardiologi.pdf"). Bisa pilih banyak file sekaligus atau seret ke sini.</span>' +
      '<input id="impfile" type="file" multiple accept=".docx,.pdf,.xlsx,.xls,.csv,.txt,.md" class="hidden" data-change="imp-files"></label>';
    if (!im) return html + '<p class="small muted">Soal tidak boleh memuat pembahasan. Pratinjau akan menunjukkan hasil bacaan sebelum disimpan.</p>';
    if (im.busy) return html + '<p class="bold" role="status">' + esc(im.busy) + '</p>';
    var errs = im.files.filter(function (x) { return x.error; });
    errs.forEach(function (x) { html += '<div class="notice" style="background:var(--bad-bg);color:var(--bad)">' + esc(x.name) + ': ' + esc(x.error) + '</div>'; });
    var keyChoices = im.files.filter(function (x) { return !x.error; }).map(function (x) { return x.name; });
    var unusedKeys = keyChoices.filter(function (n) {
      return window.Parser.isKeyFile(n) && !Object.keys(im.keyOf).some(function (q) { return im.keyOf[q] === n; });
    });
    if (unusedKeys.length) html += '<div class="notice" style="background:var(--warn-bg);color:var(--warn)">File kunci belum terpasang ke soal mana pun: ' + esc(unusedKeys.join(', ')) + '. Pilih di kartu file soal yang sesuai.</div>';
    if (!im.results.length) return html + '<p class="muted">Tidak ada file soal yang bisa dibaca.</p>';

    html += im.results.map(function (r, ri) {
      var c = counts(r), open = im.open[r.name];
      var missingKey = r.items.filter(function (it) { return !it.answer; }).length;
      var card = '<div class="col" style="gap:12px;border:1px solid var(--line);border-radius:12px;padding:16px">' +
        '<div class="row row-c between" style="gap:12px"><label class="row row-c" style="gap:10px;flex-wrap:nowrap"><input type="checkbox" data-change="imp-include" data-i="' + ri + '"' + (r.include ? ' checked' : '') + ' style="width:20px;height:20px;accent-color:var(--primary)"><span class="bold">' + esc(r.name) + '</span></label>' +
        '<span>' + (c.valid === r.items.length && r.items.length ? '<span class="badge b-ok">Siap: ' + c.valid + ' soal</span>' : '<span class="badge b-warn">' + c.valid + ' valid dari ' + r.items.length + '</span>') + '</span></div>' +
        '<div class="row"><div class="field grow" style="flex:1 1 220px"><label for="bn' + ri + '">Nama bank (label asal soal)</label><input id="bn' + ri + '" class="input" value="' + esc(r.bank) + '" data-change="imp-bank" data-i="' + ri + '" maxlength="60"></div>' +
        '<div class="field grow" style="flex:1 1 220px"><label for="kf' + ri + '">File kunci</label><select id="kf' + ri + '" class="input" data-change="imp-key" data-i="' + ri + '"><option value="">' + (r.keyInFile ? 'Kunci ada di dalam file' : 'Tidak ada / kunci di dalam file') + '</option>' +
        keyChoices.filter(function (n) { return n !== r.name; }).map(function (n) { return '<option value="' + esc(n) + '"' + (n === r.keyFile ? ' selected' : '') + '>' + esc(n) + '</option>'; }).join('') + '</select></div></div>' +
        '<p class="small muted">' + r.items.length + ' soal terbaca' + (r.keyFile ? ', ' + r.keyCount + ' kunci terbaca dari file kunci' : '') + (missingKey ? ', <b style="color:var(--bad)">' + missingKey + ' belum punya kunci</b>' : '') + (c.issues ? ', ' + c.issues + ' perlu dicek' : '') + '.</p>' +
        r.notes.map(function (n) { return '<p class="small" style="color:var(--warn);font-weight:600">' + esc(n) + '</p>'; }).join('') +
        '<div class="row" style="gap:8px"><button class="btn btn-sm" type="button" data-act="imp-open" data-i="' + ri + '" data-v="' + (open === 'issues' ? 'all' : 'issues') + '">' + (open === 'issues' ? 'Tampilkan semua' : 'Tinjau yang bermasalah') + '</button>' +
        (open ? '<button class="btn btn-sm" type="button" data-act="imp-open" data-i="' + ri + '" data-v="">Sembunyikan</button>' : (c.issues ? '' : '<button class="btn btn-sm" type="button" data-act="imp-open" data-i="' + ri + '" data-v="all">Tinjau semua</button>')) + '</div>';
      if (open) {
        var show = r.items.map(function (it, ii) { return { it: it, ii: ii }; }).filter(function (x) { return open === 'all' || x.it.warnings.length || !window.Parser.validItem(x.it); });
        card += '<div style="max-height:460px;overflow:auto">' + (show.length ? show.slice(0, 300).map(function (x) {
          var it = x.it, v = window.Parser.validItem(it);
          return '<div class="qrow' + (it.skip ? ' off' : '') + '"><div class="row row-c between" style="gap:8px;flex-wrap:nowrap"><span class="bold">' + esc(it.num) + '. ' + esc((it.stem || '(teks soal kosong)').slice(0, 180)) + '</span>' +
            '<label class="row row-c small bold" style="gap:6px;flex-wrap:nowrap;white-space:nowrap"><input type="checkbox" data-change="imp-skip" data-i="' + ri + '" data-q="' + x.ii + '"' + (it.skip ? '' : ' checked') + '>Simpan</label></div>' +
            '<span class="qopts">' + it.options.length + ' pilihan' + (it.image ? ' · ada gambar' : '') + ' · ' + esc(it.options.map(function (o, k) { return 'ABCDE'.charAt(k) + ': ' + o.slice(0, 28); }).join(' | ')) + '</span>' +
            '<div class="row row-c" style="gap:8px"><label class="small bold" for="ka' + ri + '_' + x.ii + '">Kunci</label><select id="ka' + ri + '_' + x.ii + '" class="input" style="width:90px;height:34px" data-change="imp-ans" data-i="' + ri + '" data-q="' + x.ii + '"><option value="">-</option>' +
            'ABCDE'.split('').slice(0, Math.max(it.options.length, 2)).map(function (L) { return '<option value="' + L + '"' + (it.answer === L ? ' selected' : '') + '>' + L + '</option>'; }).join('') + '</select>' +
            it.warnings.map(function (w) { return '<span class="badge b-warn">' + esc(w) + '</span>'; }).join('') + (v ? '' : '<span class="badge b-bad">Belum valid</span>') + '</div></div>';
        }).join('') + (show.length > 300 ? '<p class="small muted">Menampilkan 300 pertama.</p>' : '') : '<p class="small muted">Tidak ada soal bermasalah.</p>') + '</div>';
      }
      return card + '</div>';
    }).join('');

    var total = 0;
    im.results.forEach(function (r) { if (r.include) r.items.forEach(function (it) { if (!it.skip && window.Parser.validItem(it)) total++; }); });
    html += '<div class="row row-c between"><p class="small muted" style="flex:1 1 280px">Hanya soal yang valid (teks, pilihan, dan kunci lengkap) yang disimpan. Soal yang sama persis dengan yang sudah ada dilewati.</p>' +
      '<div class="row" style="gap:8px"><button class="btn" type="button" data-act="imp-cancel">Batal</button><button class="btn btn-primary" type="button" data-act="imp-save"' + (total && !ST.saving ? '' : ' disabled') + '>' + (ST.saving ? 'Menyimpan...' : 'Simpan ' + total + ' soal ke bank') + '</button></div></div>';
    return html;
  }

  H['imp-files'] = function (el) { var fl = Array.prototype.slice.call(el.files); el.value = ''; ingest(fl); };
  H['imp-include'] = function (el) { ST.im.results[+el.dataset.i].include = el.checked; renderImport(); };
  H['imp-bank'] = function (el) { ST.im.results[+el.dataset.i].bank = el.value.trim(); };
  H['imp-key'] = function (el) {
    var r = ST.im.results[+el.dataset.i];
    ST.im.keyOf[r.name] = el.value;
    ST.im.results[+el.dataset.i] = buildOne(r.name);
    renderImport();
  };
  H['imp-open'] = function (el) { ST.im.open[ST.im.results[+el.dataset.i].name] = el.dataset.v || false; renderImport(); };
  H['imp-skip'] = function (el) { ST.im.results[+el.dataset.i].items[+el.dataset.q].skip = !el.checked; renderImport(); };
  H['imp-ans'] = function (el) {
    var it = ST.im.results[+el.dataset.i].items[+el.dataset.q];
    it.answer = el.value || null;
    it.warnings = it.warnings.filter(function (w) { return w !== 'Kunci belum ada'; });
    renderImport();
  };
  H['imp-cancel'] = function () { ST.im = null; renderImport(); };

  H['imp-save'] = async function () {
    var im = ST.im; if (!im || ST.saving) return;
    ST.saving = true; renderImport();
    var ins = 0, skp = 0, failed = null;
    try {
      for (var ri = 0; ri < im.results.length; ri++) {
        var r = im.results[ri];
        if (!r.include) continue;
        var bank = (r.bank || stripExt(r.name)).trim();
        var list = r.items.filter(function (it) { return !it.skip && window.Parser.validItem(it); }).map(function (it) {
          return { num: it.num, stem: it.stem, options: it.options, answer: it.answer, image: it.image || null };
        });
        var batch = [], size = 0;
        for (var i = 0; i <= list.length; i++) {
          var it2 = list[i];
          var sz = it2 ? JSON.stringify(it2).length : 0;
          if (batch.length && (!it2 || batch.length >= 40 || size + sz > 600000)) {
            var res = await Api.call('adm_import', { p_bank_name: bank, p_items: batch });
            ins += res.inserted; skp += res.skipped;
            batch = []; size = 0;
          }
          if (it2) { batch.push(it2); size += sz; }
        }
      }
    } catch (e) { failed = e; }
    ST.saving = false;
    if (failed) { A.toast('Gagal menyimpan: ' + failed.message + (ins ? ' (sebagian sudah tersimpan: ' + ins + ' soal)' : ''), true); renderImport(); return; }
    A.toast(ins + ' soal tersimpan' + (skp ? ', ' + skp + ' dilewati karena sudah ada' : '') + '.');
    ST.im = null;
    soalTab();
  };

  /* seret & lepas file */
  document.addEventListener('dragover', function (e) {
    var z = e.target.closest && e.target.closest('#dz'); if (!z) return;
    e.preventDefault(); z.classList.add('over');
  });
  document.addEventListener('dragleave', function (e) { var z = e.target.closest && e.target.closest('#dz'); if (z) z.classList.remove('over'); });
  document.addEventListener('drop', function (e) {
    var z = e.target.closest && e.target.closest('#dz'); if (!z) return;
    e.preventDefault(); z.classList.remove('over');
    ingest(e.dataTransfer.files);
  });

  window.AdminUI = { view: view };
})();
