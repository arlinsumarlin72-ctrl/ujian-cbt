/* Pembaca soal: teks mentah (dari docx/pdf) atau baris tabel (xlsx/csv) -> daftar soal.
   Murni fungsi tanpa DOM, supaya bisa diuji di Node. */
(function (root) {
  'use strict';

  var LETTERS = ['A', 'B', 'C', 'D', 'E'];

  function normalize(text) {
    return String(text || '')
      .replace(/\r\n?/g, '\n')
      .replace(/[   ]/g, ' ')
      .replace(/[​‌‍﻿]/g, '')
      .replace(/\t/g, ' ')
      .replace(/[ ]{2,}/g, ' ')
      .replace(/[（]/g, '(').replace(/[）]/g, ')')
      .replace(/\n{3,}/g, '\n\n');
  }

  var Q_START = /^\s*(?:soal\s*)?(?:no\.?\s*)?(\d{1,3})\s*[\.\):]\s+(\S[\s\S]*)$/i;
  var ANS_LINE = /(?:^|\n)[ \t]*(?:jawaban(?:\s*yang\s*benar)?|kunci(?:\s*jawaban)?|answer|ans)[ \t]*[:=\-][ \t]*\(?([A-Ea-e])\)?[ \t]*\.?[ \t]*(?=\n|$)/i;

  /* Pecah teks menjadi blok per nomor soal (nomor harus berurutan agar angka di dalam
     vignette seperti "1. ..." pada daftar tidak dianggap soal baru). */
  function splitBlocks(text) {
    var lines = normalize(text).split('\n');
    var blocks = [];
    var cur = null;
    var expected = null;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var m = Q_START.exec(line);
      var isStart = false;
      if (m) {
        var n = parseInt(m[1], 10);
        if (expected === null) {
          isStart = n >= 1 && n <= 5;
        } else if (n === expected) {
          isStart = true;
        } else if (n > expected && n <= expected + 2 && cur && countMarkers(cur.lines.join('\n')) >= 2) {
          isStart = true; // ada nomor yang terlewat di file
        }
        if (isStart) {
          cur = { num: n, lines: [m[2]] };
          blocks.push(cur);
          expected = n + 1;
          continue;
        }
      }
      if (cur) cur.lines.push(line);
    }
    return blocks;
  }

  function countMarkers(s) {
    var re = /(^|[\s\(])([A-E])[\.\)]\s+\S/g, c = 0;
    while (re.exec(s)) c++;
    return c;
  }

  /* Cari rantai penanda pilihan A, B, C, D, (E) -- ambil rantai dari "A" terakhir
     yang masih disusul B, C, D supaya "vitamin A." di dalam soal tidak tertukar. */
  function findOptionChain(s) {
    var re = /(^|[\s\(])([A-E])[\.\)]\s+(?=\S)/g;
    var occ = [], m;
    while ((m = re.exec(s)) !== null) {
      occ.push({ letter: m[2], start: m.index + m[1].length, textStart: re.lastIndex });
    }
    for (var a = occ.length - 1; a >= 0; a--) {
      if (occ[a].letter !== 'A') continue;
      var chain = [occ[a]];
      var next = 1; // indeks huruf berikutnya
      var from = a + 1;
      while (next < 5) {
        var found = -1;
        for (var k = from; k < occ.length; k++) {
          if (occ[k].letter === LETTERS[next]) { found = k; break; }
        }
        if (found < 0) break;
        chain.push(occ[found]);
        from = found + 1;
        next++;
      }
      if (chain.length >= 4) return chain;
    }
    return null;
  }

  function cleanText(s) {
    return String(s)
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n[ \t]+/g, '\n')
      .replace(/(?<!\n)\n(?!\n)/g, ' ')
      .replace(/\n{2,}/g, '\n\n')
      .replace(/ {2,}/g, ' ')
      .trim();
  }

  function takeImage(s, images) {
    // token gambar dari docx: [[IMG:n]]
    var found = null;
    var out = s.replace(/\[\[IMG:(\d+)\]\]/g, function (all, n) {
      if (!found && images && images[+n]) found = images[+n];
      return ' ';
    });
    return { text: out, image: found };
  }

  function parseBlock(block, images) {
    var warnings = [];
    var raw = block.lines.join('\n');
    var answer = null;
    var am = ANS_LINE.exec(raw);
    if (am) {
      answer = am[1].toUpperCase();
      raw = raw.slice(0, am.index) + '\n' + raw.slice(am.index + am[0].length);
    }
    var img = takeImage(raw, images);
    raw = img.text;

    var chain = findOptionChain(raw);
    if (!chain) {
      return { num: block.num, stem: cleanText(raw), options: [], answer: answer, image: img.image,
               warnings: ['Pilihan jawaban A-E tidak terbaca'] };
    }
    var stem = cleanText(raw.slice(0, chain[0].start));
    var options = [];
    for (var i = 0; i < chain.length; i++) {
      var end = i + 1 < chain.length ? chain[i + 1].start : raw.length;
      options.push(cleanText(raw.slice(chain[i].textStart, end)));
    }
    if (options.length < 5) warnings.push('Hanya ' + options.length + ' pilihan terbaca');
    for (var j = 0; j < options.length; j++) {
      if (!options[j]) warnings.push('Pilihan ' + LETTERS[j] + ' kosong');
    }
    if (!stem) warnings.push('Teks soal kosong');
    return { num: block.num, stem: stem, options: options, answer: answer, image: img.image, warnings: warnings };
  }

  /* Teks soal -> daftar soal (kunci kosong bila tidak ada di dalam teks) */
  function parseQuestionsText(text, images) {
    var blocks = splitBlocks(text);
    return blocks.map(function (b) { return parseBlock(b, images); });
  }

  /* Teks kunci -> { nomor: 'A' }. Menerima "1. A", "1 A", "1-A", "1) b", "1.A 2.B 3.C" */
  function parseKeyText(text) {
    var map = {};
    var s = normalize(text).replace(/\n/g, ' \n ');
    var re = /(?:^|[\s,;\(])(\d{1,3})\s*[\.\)\:\-=]?\s*([A-Ea-e])(?=[\s,;\.\)]|$)/g;
    var m;
    while ((m = re.exec(s)) !== null) {
      var n = parseInt(m[1], 10);
      if (!(n in map)) map[n] = m[2].toUpperCase();
    }
    return map;
  }

  /* ---------- Tabel (xlsx/csv): baris = array sel ---------- */
  function lc(x) { return String(x == null ? '' : x).trim().toLowerCase(); }

  function parseQuestionsRows(rows) {
    rows = rows.filter(function (r) { return r && r.some(function (c) { return String(c == null ? '' : c).trim() !== ''; }); });
    if (!rows.length) return { items: [], keyInFile: false };
    var header = rows[0].map(lc);
    var idx = { num: -1, stem: -1, opts: [-1, -1, -1, -1, -1], key: -1 };
    header.forEach(function (h, i) {
      if (/^(no\.?|nomor|number|#)$/.test(h)) idx.num = i;
      else if (/^(soal|pertanyaan|question|stem)$/.test(h)) idx.stem = i;
      else if (/^(kunci|jawaban|answer|key|kunci jawaban)$/.test(h)) idx.key = i;
      else {
        var mm = /^(?:opsi|pilihan|option)?\s*([a-e])$/.exec(h);
        if (mm) idx.opts[mm[1].charCodeAt(0) - 97] = i;
      }
    });
    var hasHeader = idx.stem >= 0 && idx.opts[0] >= 0 && idx.opts[1] >= 0;
    var data = rows;
    if (hasHeader) {
      data = rows.slice(1);
    } else {
      // tanpa header: [no?], soal, A..E, kunci
      var firstNum = /^\d+$/.test(String(rows[0][0]).trim());
      var o = firstNum ? 1 : 0;
      idx = { num: firstNum ? 0 : -1, stem: o, opts: [o + 1, o + 2, o + 3, o + 4, o + 5], key: o + 6 };
    }
    var items = [];
    var keyInFile = idx.key >= 0;
    data.forEach(function (r, n) {
      var cell = function (i) { return i >= 0 && i < r.length && r[i] != null ? String(r[i]).trim() : ''; };
      var options = idx.opts.map(cell).filter(function (x, i, arr) {
        // buang sisa kolom kosong di belakang
        for (var k = i; k < arr.length; k++) if (arr[k] !== '') return true;
        return false;
      });
      var warnings = [];
      var ans = cell(idx.key).toUpperCase().replace(/[^A-E]/g, '').charAt(0) || null;
      var stem = cell(idx.stem);
      if (!stem) return;
      if (options.length < 4) warnings.push('Hanya ' + options.length + ' pilihan terbaca');
      var num = idx.num >= 0 ? parseInt(cell(idx.num), 10) : n + 1;
      items.push({ num: isNaN(num) ? n + 1 : num, stem: stem, options: options, answer: ans, image: null, warnings: warnings });
    });
    return { items: items, keyInFile: keyInFile };
  }

  /* ---------- Gabungkan kunci ke soal, beri peringatan ---------- */
  function applyKeys(items, keyMap) {
    var missing = 0;
    items.forEach(function (it) {
      if (!it.answer && keyMap && keyMap[it.num]) it.answer = keyMap[it.num];
      if (!it.answer) { it.warnings.push('Kunci belum ada'); missing++; }
      else if (it.options.length && LETTERS.indexOf(it.answer) >= it.options.length) {
        it.warnings.push('Kunci ' + it.answer + ' di luar pilihan yang terbaca');
      }
    });
    return missing;
  }

  function validItem(it) {
    return !!(it.stem && it.options.length >= 2 && it.options.length <= 5 && it.answer &&
              LETTERS.indexOf(it.answer) >= 0 && LETTERS.indexOf(it.answer) < it.options.length &&
              it.options.every(function (o) { return o; }));
  }

  /* ---------- Pasangkan file soal dengan file kunci lewat nama ---------- */
  var KEY_WORDS = /(kunci|jawaban|answer|key|jawab)/i;

  function baseName(name) {
    return String(name).replace(/\.[^.]+$/, '').toLowerCase()
      .replace(/(kunci|jawaban|answer|key|jawab|soal|questions?)/g, '')
      .replace(/[^a-z0-9]+/g, '');
  }

  function isKeyFile(name) { return KEY_WORDS.test(String(name).replace(/\.[^.]+$/, '')); }

  /* files: [{name}] -> { pairs: [{q: name, k: name|null}], keysLeft: [names] } */
  function pairFiles(names) {
    var qs = names.filter(function (n) { return !isKeyFile(n); });
    var ks = names.filter(isKeyFile);
    var used = {};
    var pairs = qs.map(function (q) {
      var b = baseName(q), hit = null;
      ks.forEach(function (k) { if (!used[k] && baseName(k) === b && b) hit = hit || k; });
      if (hit) used[hit] = true;
      return { q: q, k: hit };
    });
    var left = ks.filter(function (k) { return !used[k]; });
    var openPairs = pairs.filter(function (p) { return !p.k; });
    if (left.length === 1 && openPairs.length === 1) { openPairs[0].k = left[0]; left = []; }
    return { pairs: pairs, keysLeft: left };
  }

  var api = {
    normalize: normalize, parseQuestionsText: parseQuestionsText, parseKeyText: parseKeyText,
    parseQuestionsRows: parseQuestionsRows, applyKeys: applyKeys, validItem: validItem,
    pairFiles: pairFiles, isKeyFile: isKeyFile
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.Parser = api;
})(typeof window !== 'undefined' ? window : this);
