-- ============================================================
-- Patch 2026-11-23: diskusi (waktu dijeda), bagian terkunci, mode ketat,
--                   jenis soal + analisis, kunci "satu per satu" tidak hilang.
-- Bersifat tambahan: tidak menghapus data soal/hasil. Aman dijalankan ulang.
-- Dijalankan setelah patch-2026-11-22-pemulihan-dan-eksklusi.sql.
-- ============================================================
begin;

-- ---------- Kolom baru ----------
alter table sessions  add column if not exists lock_mode   text    not null default 'free';
alter table sessions  drop constraint if exists sessions_lock_mode_check;
alter table sessions  add constraint sessions_lock_mode_check check (lock_mode in ('free','locked'));
alter table sessions  add column if not exists unlocked_n  int     not null default 0;      -- jumlah soal yang sudah dibuka (hanya mode terkunci)
alter table sessions  add column if not exists discuss_log jsonb   not null default '[]'::jsonb; -- [{"s":waktu mulai,"e":waktu selesai|null}]
alter table sessions  add column if not exists ketat       boolean not null default false;
alter table attempts  add column if not exists revealed    uuid[]  not null default '{}';  -- kunci yang sudah dibuka (mode satu per satu)
alter table attempts  add column if not exists violations  jsonb   not null default '[]'::jsonb;
alter table attempts  add column if not exists last_seen   timestamptz;
alter table questions add column if not exists qtype       text;

-- ---------- Fungsi bantu (tidak dibuka ke publik) ----------
create or replace function _bsize(s sessions) returns int
language sql stable as $$
  select case when s.feedback_mode ~ '^[0-9]+' then nullif(regexp_replace(s.feedback_mode, 's$', '')::int, 0) end
$$;

-- jumlah soal yang boleh dikerjakan sekarang (null = semua)
create or replace function _open_n(s sessions) returns int
language sql stable as $$
  select case when s.lock_mode = 'locked' then s.unlocked_n end
$$;

create or replace function _discussing(s sessions) returns boolean
language sql stable as $$
  select exists (select 1 from jsonb_array_elements(s.discuss_log) d where d ->> 'e' is null)
$$;

-- detik diskusi yang beririsan dengan rentang [p_from, p_to]
create or replace function _paused_secs(p_log jsonb, p_from timestamptz, p_to timestamptz) returns numeric
language sql stable as $$
  select coalesce(sum(greatest(0, extract(epoch from (
           least(coalesce((d ->> 'e')::timestamptz, p_to), p_to) - greatest((d ->> 's')::timestamptz, p_from))))), 0)
  from jsonb_array_elements(coalesce(p_log, '[]'::jsonb)) d
$$;

-- waktu mengerjakan = sejak mulai, dikurangi waktu diskusi
create or replace function _elapsed(s sessions, a attempts) returns int
language sql stable as $$
  select greatest(0, floor(extract(epoch from (now() - a.started_at)) - _paused_secs(s.discuss_log, a.started_at, now())))::int
$$;

-- buang jawaban pada soal yang belum dibuka admin
create or replace function _strip_after(p_ids uuid[], p_open int, p_j jsonb) returns jsonb
language plpgsql immutable set search_path = public, extensions as $$
declare v jsonb := coalesce(p_j, '{}'::jsonb); i int;
begin
  if p_open is null then return v; end if;
  for i in greatest(p_open, 0) + 1 .. cardinality(p_ids) loop
    v := v - (p_ids[i]::text);
  end loop;
  return v;
end $$;

-- tebakan jenis soal dari kalimat tanya (kalimat terakhir; bila ada "?" dipakai kalimat ber-"?" terakhir)
-- Urutan penting: aturan yang lebih spesifik diperiksa lebih dulu. Hasil hanya tebakan: admin bisa mengoreksi per soal.
create or replace function _qtype(p_stem text) returns text
language plpgsql immutable set search_path = public, extensions as $$
declare t text := lower(coalesce(p_stem, '')); q text; t2 text;
begin
  q := (regexp_match(t, '([^.?!]*\?)\s*$'))[1];
  if q is null or length(btrim(q)) < 8 then
    t2 := regexp_replace(t, '[\s.…:?]+$', '');
    q := (regexp_match(t2, '([^.?!]*)$'))[1];
    if length(btrim(coalesce(q, ''))) < 6 then q := right(t2, 80); end if;
  end if;
  if q ~ 'dosis|berapa (mg|ml|cc|gram|gr|mcg|unit|iu|tetes|ampul|tablet|kapsul)|mg/kg|mcg/kg|mg/hari|tetes/menit|ml/jam|cc/jam|kebutuhan .*harian|asam folat' then return 'Dosis obat'; end if;
  if q ~ 'mekanisme kerja|efek samping|kontraindikasi|interaksi obat|golongan obat|farmakokinetik|farmakodinamik|antidot|toksisitas|tujuan (utama )?(pemberian|terapi)|indikasi' then return 'Farmakologi obat'; end if;
  if q ~ 'komplikasi|penyulit|dampak (jangka|lanjut)' then return 'Komplikasi'; end if;
  if q ~ 'prognosis|angka harapan hidup' then return 'Prognosis'; end if;
  if q ~ 'etiologi|penyebab|faktor risiko|mikroorganisme|kuman|agen (penyebab|infeksi)' then return 'Etiologi / faktor risiko'; end if;
  if q ~ 'patofisiologi|patogenesis|mekanisme|proses (terjadinya|patologis|yang terjadi)|terjadi(nya)? (akibat|karena)|yang mendasari|perubahan (patologi|histopatologi)|apa yang terjadi' then return 'Patofisiologi'; end if;
  if q ~ 'pencegahan|preventif|edukasi|konseling|vaksin|imunisasi|skrining|promotif|nasihat|kapan(kah)? .*(hamil|boleh|kembali)' then return 'Pencegahan / edukasi'; end if;
  if q ~ '\mhasil\M|akan didapatkan|apa yang anda harapkan|kemungkinan ditemukan|akan ditemukan|akan tampak' then return 'Temuan / gambaran klinis'; end if;
  if q ~ 'pemeriksaan (penunjang|lanjutan|selanjutnya|lanjut|tambahan|lain)|pemeriksan|baku emas|gold standard|dilakukan pemeriksaan|pemeriksaan apa|uji (yang|apa)|sampel|tes diagnostik' then return 'Pemeriksaan penunjang'; end if;
  if q ~ 'anatomi|fisiologi|histolog|persarafan|vaskularisasi|inervasi|letak|lokasi|lokalisasi|lesi (pada|di)|nervus|saraf|dermatom|area (berapa|otak)|lapisan kulit|zona|diagnosa topis|struktur (yang|anatomi)' then return 'Anatomi / lokalisasi'; end if;
  if q ~ 'usia kehamilan|taksiran|perkiraan (usia|tanggal)|tanggal (perkiraan|persalinan)|hodge|derajat|stadium|glasgow|gcs|\mkala\M|fase |skor|score|klasifikasi|jenis ikterus|pola ikterus|presentasi|bangkitan|tipe kejang|berapa' then return 'Staging / derajat / perhitungan'; end if;
  if q ~ 'faktor (yang|etiologi)|disebabkan|menyebabkan|penularan|sumber penular|jenis bakteri' then return 'Etiologi / faktor risiko'; end if;
  if q ~ 'tatalaksana|tata laksana|penatalaksana|penetalaksana|terapi|pengobatan|penanganan|manajemen|diberikan|pemberian|obat|tindakan|langkah|dirujuk|rujuk|prosedur|operasi|pembedahan|antibiotik|analgesik|profilaksis|medikamentosa|kontrasepsi|\mkb\M|suplement|maneuver|manuver|(yang|sebaiknya) .*(lakukan|dilakukan)' then return 'Tatalaksana'; end if;
  if q ~ 'pernyataan|manakah kondisi|yang dimaksud|istilah' then return 'Konsep dasar'; end if;
  if q ~ 'ditemukan|temuan|gambaran|interpretasi|tampak|terlihat|didapatkan|diperoleh|manifestasi|tanda (dan|klinis)|gejala|pewarnaan|pengecatan|histopatolog|pola nyeri|bentuk' then return 'Temuan / gambaran klinis'; end if;
  if q ~ 'diagnosis|diagnosa|diagnose|diagnos|didiagnosis|kemungkinan (penyakit|kelainan|besar|diagnosis)|menderita|dicurigai|penyakit (apa|apakah)|kelainan|kondisi|keadaan|paling mungkin|merupakan|nama' then return 'Diagnosis'; end if;
  if q ~ 'pemeriksaan' then return 'Pemeriksaan penunjang'; end if;
  return 'Lainnya';
end $$;

revoke execute on function _bsize(sessions)                              from public, anon, authenticated;
revoke execute on function _open_n(sessions)                             from public, anon, authenticated;
revoke execute on function _discussing(sessions)                         from public, anon, authenticated;
revoke execute on function _paused_secs(jsonb, timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function _elapsed(sessions, attempts)                  from public, anon, authenticated;
revoke execute on function _strip_after(uuid[], int, jsonb)              from public, anon, authenticated;
revoke execute on function _qtype(text)                                  from public, anon, authenticated;

-- ---------- Peserta: mulai / simpan / kunci ----------
create or replace function app_start(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_q jsonb; v_open int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;

  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then
    if s.status <> 'open' then raise exception 'Sesi ini sudah ditutup.'; end if;
    insert into attempts (session_id, profile_id) values (s.id, r.id) returning * into a;
  end if;

  if a.submitted_at is not null then
    return jsonb_build_object('submitted', true);
  end if;

  v_open := _open_n(s);
  -- soal pada bagian yang belum dibuka admin TIDAK dikirim (hanya nomor dan penanda terkunci)
  select coalesce(jsonb_agg(
           case when v_open is not null and u.ord > v_open
                then jsonb_build_object('id', q.id, 'no', u.ord, 'locked', true)
                else jsonb_build_object('id', q.id, 'no', u.ord, 'bank', b.name, 'file', b.name,
                                        'system', coalesce(b.system, b.name),
                                        'stem', q.stem, 'image', q.image, 'options', q.options) end
           order by u.ord), '[]'::jsonb) into v_q
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id;

  return jsonb_build_object(
    'submitted', false,
    'session', jsonb_build_object('id', s.id, 'title', s.title, 'timer_minutes', s.timer_minutes,
                                  'feedback_mode', s.feedback_mode, 'total', cardinality(s.question_ids), 'rev', s.rev,
                                  'lock_mode', s.lock_mode, 'unlocked_n', s.unlocked_n, 'ketat', s.ketat,
                                  'discussing', _discussing(s)),
    'questions', v_q,
    'answers', a.answers,
    'flags', a.flags,
    'locked', a.locked_n,
    'revealed', to_jsonb(a.revealed),
    'viol', jsonb_array_length(a.violations),
    'elapsed', _elapsed(s, a)
  );
end $$;

create or replace function app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; a attempts; s sessions; v_ans jsonb;
begin
  r := _me(p_token);
  if jsonb_typeof(p_answers) <> 'object' or jsonb_typeof(p_flags) <> 'object' then
    raise exception 'Data tidak valid.';
  end if;
  select * into a from attempts where session_id = p_session and profile_id = r.id and submitted_at is null for update;
  if found then
    select * into s from sessions where id = p_session;
    v_ans := _strip_after(s.question_ids, _open_n(s), _keep_locked(s.question_ids, a.locked_n, a.answers, p_answers));
    if _discussing(s) then v_ans := a.answers; end if;   -- saat diskusi jawaban tidak berubah
    update attempts
       set answers = v_ans,
           flags   = _keep_locked(s.question_ids, a.locked_n, a.flags, p_flags)
     where id = a.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function app_finalize(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; n int; total int; nxt int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if s.feedback_mode !~ '^[0-9]' then raise exception 'Sesi ini tidak memakai blok.'; end if;
  n := regexp_replace(s.feedback_mode, 's$', '')::int;
  total := cardinality(s.question_ids);
  perform app_save(p_token, p_session, p_answers, p_flags);
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  if a.submitted_at is not null then return jsonb_build_object('locked', total); end if;
  if s.lock_mode = 'locked' and a.locked_n >= s.unlocked_n then
    raise exception 'Bagian berikutnya belum dibuka admin.';
  end if;
  nxt := least(a.locked_n + n, total);
  update attempts set locked_n = greatest(locked_n, nxt) where id = a.id;
  return jsonb_build_object('locked', greatest(a.locked_n, nxt));
end $$;

create or replace function app_reveal(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb; qid uuid; idx int; ok boolean; k text;
        v_new uuid[] := '{}';
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;

  foreach qid in array coalesce(p_qids, '{}'::uuid[]) loop
    idx := array_position(s.question_ids, qid);
    continue when idx is null;
    ok := false;
    if a.submitted_at is not null then
      ok := true;
    elsif s.feedback_mode = 'each' then
      ok := a.answers ? qid::text;
    elsif s.feedback_mode ~ '^[0-9]' then
      ok := idx <= a.locked_n;
    end if;
    if ok then
      select answer into k from question_keys where question_id = qid;
      if k is not null then
        res := res || jsonb_build_object(qid::text, k);
        v_new := v_new || qid;
      end if;
    end if;
  end loop;

  -- mode "satu per satu": ingat kunci yang sudah dibuka supaya tidak hilang saat halaman dimuat ulang
  if a.submitted_at is null and s.feedback_mode ~ 's$' and cardinality(v_new) > 0 then
    update attempts
       set revealed = (select coalesce(array_agg(distinct x), '{}') from unnest(a.revealed || v_new) as x)
     where id = a.id;
  end if;
  return res;
end $$;

create or replace function app_rev(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_has boolean;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then return jsonb_build_object('rev', 0, 'notice', null, 'submitted', false); end if;
  select * into a from attempts where session_id = p_session and profile_id = r.id;
  v_has := found;
  if v_has and a.submitted_at is null then
    update attempts set last_seen = now() where id = a.id;
  end if;
  return jsonb_build_object('rev', s.rev, 'notice', s.notice,
    'submitted', coalesce(v_has and a.submitted_at is not null, false),
    'discussing', _discussing(s), 'unlocked_n', s.unlocked_n, 'lock_mode', s.lock_mode,
    'elapsed', case when v_has and a.submitted_at is null then _elapsed(s, a) end);
end $$;

create or replace function app_submit(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_score int; v_time int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  if a.submitted_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;

  p_answers := _strip_after(s.question_ids, _open_n(s),
      _keep_locked(s.question_ids, a.locked_n, a.answers, case when jsonb_typeof(p_answers) = 'object' then p_answers else a.answers end));
  p_flags   := _keep_locked(s.question_ids, a.locked_n, a.flags, case when jsonb_typeof(p_flags) = 'object' then p_flags else a.flags end);

  select count(*) into v_score
  from unnest(s.question_ids) as u(qid)
  join question_keys k on k.question_id = u.qid
  where p_answers ->> (u.qid::text) = k.answer;

  v_time := _elapsed(s, a);
  if s.timer_minutes is not null and v_time > s.timer_minutes * 60 then
    v_time := s.timer_minutes * 60;
  end if;

  update attempts
     set answers = p_answers, flags = p_flags, submitted_at = now(), score = v_score, time_taken = v_time,
         locked_n = cardinality(s.question_ids)
   where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_submit_attempts(p_token uuid, p_session uuid, p_profile uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; a attempts; v_score int; v_time int; c int := 0;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  for a in select * from attempts where session_id = p_session and submitted_at is null and (p_profile is null or profile_id = p_profile) for update loop
    select count(*) into v_score from unnest(s.question_ids) as u(qid) join question_keys k on k.question_id = u.qid where a.answers ->> (u.qid::text) = k.answer;
    v_time := _elapsed(s, a);
    if s.timer_minutes is not null and v_time > s.timer_minutes * 60 then v_time := s.timer_minutes * 60; end if;
    update attempts set submitted_at = now(), score = v_score, time_taken = v_time, locked_n = cardinality(s.question_ids) where id = a.id;
    c := c + 1;
  end loop;
  return jsonb_build_object('ok', true, 'submitted', c);
end $$;

-- Mode ketat: catat peserta yang meninggalkan halaman ujian (tidak dicatat saat diskusi)
create or replace function app_violation(p_token uuid, p_session uuid, p_kind text, p_secs int, p_update boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; n int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found or not s.ketat then return jsonb_build_object('ok', true); end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found or a.submitted_at is not null then return jsonb_build_object('ok', true); end if;
  p_kind := left(coalesce(p_kind, '?'), 20);
  p_secs := least(greatest(coalesce(p_secs, 0), 0), 86400);
  n := jsonb_array_length(a.violations);
  if p_update then
    if n > 0 then
      update attempts set violations = jsonb_set(a.violations, array[(n - 1)::text, 'd'], to_jsonb(p_secs)) where id = a.id;
    end if;
  elsif not _discussing(s) and n < 300 then
    update attempts set violations = a.violations || jsonb_build_array(jsonb_build_object('t', now(), 'k', p_kind, 'd', p_secs)) where id = a.id;
    n := n + 1;
  end if;
  return jsonb_build_object('ok', true, 'count', n);
end $$;

-- ---------- Peserta: daftar sesi, hasil, tinjau, riwayat ----------
create or replace function app_sessions(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v jsonb;
begin
  r := _me(p_token);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v
  from (
    select s.id, s.title, cardinality(s.question_ids) as total, s.timer_minutes,
           s.feedback_mode, s.status, s.created_at, s.lock_mode, s.ketat,
           (a.id is not null) as started,
           (a.submitted_at is not null) as done,
           a.score,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished
    from sessions s
    left join attempts a on a.session_id = s.id and a.profile_id = r.id
  ) x;
  return v;
end $$;

create or replace function _result(p_profile uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_rows jsonb; v_sys jsonb; v_types jsonb; v_cells jsonb; v_hard jsonb;
        v_rank int; v_n int;
begin
  select * into r from profiles where id = p_profile;
  if not found then raise exception 'Peserta tidak ditemukan.'; end if;
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found or a.submitted_at is null then raise exception 'Hasil belum tersedia. Kumpulkan dulu sesinya.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'id', q.id, 'bank', coalesce(b.system, b.name), 'ty', coalesce(q.qtype, 'Lainnya'),
           'mine', coalesce(a.answers ->> (q.id::text), '-'),
           'key', k.answer,
           'ok', (a.answers ->> (q.id::text)) = k.answer,
           'flag', coalesce((a.flags ->> (q.id::text))::boolean, false)
         ) order by u.ord), '[]'::jsonb) into v_rows
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id;

  -- per sistem
  with qs as (
    select q.id as qid, coalesce(b.system, b.name) as sy, k.answer as ans
    from unnest(s.question_ids) as u(x)
    join questions q on q.id = u.x join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
  ), mine as (
    select sy, count(*) as total,
           count(*) filter (where a.answers ->> (qid::text) = ans) as correct,
           count(*) filter (where a.answers ? (qid::text) and a.answers ->> (qid::text) <> ans) as wrong,
           count(*) filter (where not (a.answers ? (qid::text))) as blank,
           count(*) filter (where coalesce((a.flags ->> (qid::text))::boolean, false)) as flag,
           count(*) filter (where coalesce((a.flags ->> (qid::text))::boolean, false) and a.answers ->> (qid::text) = ans) as flag_ok
    from qs group by sy
  ), avgs as (
    select qs.sy, round(100.0 * count(*) filter (where t.answers ->> (qs.qid::text) = qs.ans) / nullif(count(*), 0))::int as avg
    from qs cross join attempts t
    where t.session_id = s.id and t.submitted_at is not null
    group by qs.sy
  )
  select coalesce(jsonb_agg(jsonb_build_object('bank', m.sy, 'correct', m.correct, 'wrong', m.wrong, 'blank', m.blank,
           'total', m.total, 'flag', m.flag, 'flag_ok', m.flag_ok, 'avg', g.avg) order by m.sy), '[]'::jsonb)
    into v_sys
  from mine m left join avgs g on g.sy = m.sy;

  -- per jenis soal
  with qs as (
    select q.id as qid, coalesce(q.qtype, 'Lainnya') as ty, k.answer as ans
    from unnest(s.question_ids) as u(x)
    join questions q on q.id = u.x
    left join question_keys k on k.question_id = q.id
  ), mine as (
    select ty, count(*) as total,
           count(*) filter (where a.answers ->> (qid::text) = ans) as correct,
           count(*) filter (where a.answers ? (qid::text) and a.answers ->> (qid::text) <> ans) as wrong,
           count(*) filter (where not (a.answers ? (qid::text))) as blank
    from qs group by ty
  ), avgs as (
    select qs.ty, round(100.0 * count(*) filter (where t.answers ->> (qs.qid::text) = qs.ans) / nullif(count(*), 0))::int as avg
    from qs cross join attempts t
    where t.session_id = s.id and t.submitted_at is not null
    group by qs.ty
  )
  select coalesce(jsonb_agg(jsonb_build_object('type', m.ty, 'correct', m.correct, 'wrong', m.wrong, 'blank', m.blank,
           'total', m.total, 'avg', g.avg) order by m.ty), '[]'::jsonb)
    into v_types
  from mine m left join avgs g on g.ty = m.ty;

  -- peta sistem x jenis soal
  select coalesce(jsonb_agg(jsonb_build_object('sy', z.sy, 'ty', z.ty, 'correct', z.correct, 'total', z.total) order by z.sy, z.ty), '[]'::jsonb)
    into v_cells
  from (
    select coalesce(b.system, b.name) as sy, coalesce(q.qtype, 'Lainnya') as ty,
           count(*) filter (where a.answers ->> (q.id::text) = k.answer) as correct, count(*) as total
    from unnest(s.question_ids) as u(x)
    join questions q on q.id = u.x join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    group by 1, 2
  ) z;

  -- soal tersulit di sesi ini (bahan diskusi): butuh minimal 2 peserta yang sudah mengumpulkan
  select coalesce(jsonb_agg(jsonb_build_object('no', h.ord, 'sy', h.sy, 'ty', h.ty, 'pct', h.pct, 'n', h.n, 'mine_ok', h.mine_ok)
                            order by h.pct, h.ord), '[]'::jsonb)
    into v_hard
  from (
    select u.ord, coalesce(b.system, b.name) as sy, coalesce(q.qtype, 'Lainnya') as ty,
           round(100.0 * count(*) filter (where t.answers ->> (q.id::text) = k.answer) / count(*))::int as pct,
           count(*)::int as n,
           bool_or(t.profile_id = r.id and t.answers ->> (q.id::text) = k.answer) as mine_ok
    from unnest(s.question_ids) with ordinality as u(x, ord)
    join questions q on q.id = u.x join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    cross join attempts t
    where t.session_id = s.id and t.submitted_at is not null
    group by u.ord, 2, 3
    having count(*) >= 2
    order by 4, 1 limit 5
  ) h;

  select 1 + count(*) into v_rank from attempts t
   where t.session_id = s.id and t.submitted_at is not null
     and (t.score > a.score or (t.score = a.score and t.time_taken < a.time_taken));
  select count(*) into v_n from attempts t where t.session_id = s.id and t.submitted_at is not null;

  return jsonb_build_object(
    'title', s.title, 'score', a.score, 'total', cardinality(s.question_ids),
    'time_taken', a.time_taken, 'rank', v_rank, 'participants', v_n,
    'rows', v_rows, 'banks', v_sys, 'types', v_types, 'cells', v_cells, 'hard', v_hard,
    'block', _bsize(s), 'discuss_secs', floor(_paused_secs(s.discuss_log, a.started_at, a.submitted_at))::int,
    'viol', jsonb_array_length(a.violations), 'ketat', s.ketat
  );
end $$;

create or replace function app_result(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  return _result(r.id, p_session);
end $$;

-- Admin: hasil akhir (analisis) milik peserta tertentu
create or replace function adm_result(p_token uuid, p_session uuid, p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  return _result(p_profile, p_session) || jsonb_build_object('person', (select name from profiles where id = p_profile));
end $$;

create or replace function _review(p_profile uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v jsonb;
begin
  select * into r from profiles where id = p_profile;
  if not found then raise exception 'Peserta tidak ditemukan.'; end if;
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found or a.submitted_at is null then raise exception 'Tinjauan tersedia setelah sesi dikumpulkan.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('no', u.ord, 'id', q.id, 'system', coalesce(b.system, b.name), 'file', b.name,
      'qtype', coalesce(q.qtype, 'Lainnya'), 'stem', q.stem,
      'image', q.image, 'options', q.options, 'key', k.answer, 'mine', a.answers ->> (q.id::text),
      'flag', coalesce((a.flags ->> (q.id::text))::boolean, false)) order by u.ord), '[]'::jsonb)
  into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id;
  return jsonb_build_object('title', s.title, 'questions', v, 'block', _bsize(s));
end $$;

create or replace function app_review(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  return _review(r.id, p_session);
end $$;

-- Admin: tinjau soal milik peserta tertentu
create or replace function adm_review(p_token uuid, p_session uuid, p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  return _review(p_profile, p_session) || jsonb_build_object('person', (select name from profiles where id = p_profile));
end $$;

create or replace function app_history(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v_hist jsonb; v_banks jsonb; v_types jsonb;
begin
  r := _me(p_token);
  select coalesce(jsonb_agg(jsonb_build_object(
           'session_id', s.id, 'title', s.title, 'score', a.score,
           'total', cardinality(s.question_ids), 'time_taken', a.time_taken, 'submitted_at', a.submitted_at
         ) order by a.submitted_at), '[]'::jsonb) into v_hist
  from attempts a join sessions s on s.id = a.session_id
  where a.profile_id = r.id and a.submitted_at is not null;

  select coalesce(jsonb_agg(jsonb_build_object('bank', t.bank, 'correct', t.correct, 'total', t.total) order by t.bank), '[]'::jsonb)
    into v_banks
  from (
    select coalesce(b.system, b.name) as bank,
           count(*) filter (where (a.answers ->> (q.id::text)) = k.answer) as correct,
           count(*) as total
    from attempts a
    join sessions s on s.id = a.session_id
    cross join lateral unnest(s.question_ids) as u(qid)
    join questions q on q.id = u.qid
    join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    where a.profile_id = r.id and a.submitted_at is not null
    group by coalesce(b.system, b.name)
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object('type', t.ty, 'correct', t.correct, 'total', t.total) order by t.ty), '[]'::jsonb)
    into v_types
  from (
    select coalesce(q.qtype, 'Lainnya') as ty,
           count(*) filter (where (a.answers ->> (q.id::text)) = k.answer) as correct,
           count(*) as total
    from attempts a
    join sessions s on s.id = a.session_id
    cross join lateral unnest(s.question_ids) as u(qid)
    join questions q on q.id = u.qid
    left join question_keys k on k.question_id = q.id
    where a.profile_id = r.id and a.submitted_at is not null
    group by coalesce(q.qtype, 'Lainnya')
  ) t;

  return jsonb_build_object('history', v_hist, 'banks', v_banks, 'types', v_types);
end $$;

-- ---------- Admin ----------
revoke execute on function _result(uuid, uuid) from public, anon, authenticated;
revoke execute on function _review(uuid, uuid) from public, anon, authenticated;
drop function if exists adm_create_session(uuid, text, uuid[], int, int, text, uuid[]);

create or replace function adm_create_session(p_token uuid, p_title text, p_bank_ids uuid[], p_count int, p_timer int,
                                              p_feedback text, p_exclude_sessions uuid[] default '{}'::uuid[],
                                              p_lock text default 'free', p_strict boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; v_ids uuid[]; v_title text := btrim(coalesce(p_title, ''));
        v_used uuid[]; v_n int; v_sys text[]; v_avail int[]; v_alloc int[]; v_left int; i int; moved boolean;
        v_total int; v_unlock int := 0;
begin
  r := _admin(p_token);
  if v_title = '' then raise exception 'Nama sesi kosong.'; end if;
  if p_count is null or p_count < 1 or p_count > 500 then raise exception 'Jumlah soal harus 1 sampai 500.'; end if;
  if p_feedback is null or (p_feedback not in ('each','end') and p_feedback !~ '^[0-9]{1,3}s?$') then
    raise exception 'Mode tampil kunci tidak valid.';
  end if;
  if p_feedback ~ '^[0-9]' then
    v_n := regexp_replace(p_feedback, 's$', '')::int;
    if v_n < 1 or v_n > p_count then
      raise exception 'Tampilkan kunci tiap N nomor: N harus 1 sampai jumlah soal (%).', p_count;
    end if;
  end if;
  if p_lock is null or p_lock not in ('free','locked') then raise exception 'Mode lanjut tidak valid.'; end if;
  if p_lock = 'locked' then
    if v_n is null then raise exception 'Mode terkunci memerlukan pembagian bagian (per 10, per 20, atau atur sendiri).'; end if;
    v_unlock := v_n;
  end if;
  if p_timer is not null and (p_timer < 1 or p_timer > 600) then raise exception 'Timer harus 1 sampai 600 menit.'; end if;
  if p_bank_ids is null or cardinality(p_bank_ids) = 0 then raise exception 'Pilih minimal satu file/bidang.'; end if;

  select coalesce(array_agg(distinct t.u), '{}') into v_used
    from sessions s, unnest(s.question_ids) as t(u)
   where s.id = any(coalesce(p_exclude_sessions, '{}'));

  select array_agg(t.sy), array_agg(t.c::int) into v_sys, v_avail from (
    select coalesce(b.system, b.name) as sy, count(*) as c
    from questions q join question_keys k on k.question_id = q.id join banks b on b.id = q.bank_id
    where q.active and q.bank_id = any(p_bank_ids) and q.id <> all (v_used)
    group by 1 order by random()
  ) t;
  select coalesce(sum(x), 0) into v_total from unnest(coalesce(v_avail, '{}'::int[])) x;
  if v_total < p_count then
    raise exception 'Soal yang tersedia hanya % (diminta %)%.', v_total, p_count,
      case when cardinality(v_used) > 0 then ', setelah mengecualikan soal sesi sebelumnya' else '' end;
  end if;

  v_alloc := array_fill(0, array[cardinality(v_sys)]);
  v_left := p_count;
  while v_left > 0 loop
    moved := false;
    for i in 1..cardinality(v_sys) loop
      exit when v_left = 0;
      if v_alloc[i] < v_avail[i] then v_alloc[i] := v_alloc[i] + 1; v_left := v_left - 1; moved := true; end if;
    end loop;
    exit when not moved;
  end loop;

  select array_agg(z.id order by random()) into v_ids from (
    select q.id, coalesce(b.system, b.name) as sy,
           row_number() over (partition by coalesce(b.system, b.name) order by random()) as rn
    from questions q join question_keys k on k.question_id = q.id join banks b on b.id = q.bank_id
    where q.active and q.bank_id = any(p_bank_ids) and q.id <> all (v_used)
  ) z
  join unnest(v_sys, v_alloc) as a(sy, n) on a.sy = z.sy and z.rn <= a.n;

  insert into sessions (title, question_ids, timer_minutes, feedback_mode, created_by, bank_ids, lock_mode, unlocked_n, ketat)
  values (v_title, v_ids, p_timer, p_feedback, r.id, p_bank_ids, p_lock, v_unlock, coalesce(p_strict, false));
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_sessions(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v
  from (
    select s.id, s.title, cardinality(s.question_ids) as total, s.timer_minutes, s.feedback_mode, s.status, s.created_at,
           s.lock_mode, s.unlocked_n, s.ketat, _discussing(s) as discussing,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is null) as ongoing
    from sessions s
  ) x;
  return v;
end $$;

create or replace function adm_attempts(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('profile_id', p.id, 'name', p.name, 'avatar_color', p.avatar_color,
    'answered', (select count(*) from jsonb_object_keys(a.answers)), 'total', cardinality(s.question_ids), 'locked', a.locked_n,
    'submitted', a.submitted_at is not null, 'score', a.score,
    'viol', jsonb_array_length(a.violations),
    'viol_secs', (select coalesce(sum((x ->> 'd')::int), 0) from jsonb_array_elements(a.violations) x),
    'viol_log', a.violations,
    'seen', case when a.last_seen is null then null else extract(epoch from (now() - a.last_seen))::int end
  ) order by (a.submitted_at is not null), p.name), '[]'::jsonb)
  into v from attempts a join profiles p on p.id = a.profile_id join sessions s on s.id = a.session_id where a.session_id = p_session;
  return v;
end $$;

-- Kendali admin: mulai/selesai diskusi (waktu peserta dijeda) dan buka bagian berikutnya
create or replace function adm_flow_state(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s sessions; v_since int;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select extract(epoch from (now() - (d ->> 's')::timestamptz))::int into v_since
    from jsonb_array_elements(s.discuss_log) d where d ->> 'e' is null limit 1;
  return jsonb_build_object(
    'total', cardinality(s.question_ids), 'block', _bsize(s), 'lock_mode', s.lock_mode, 'unlocked_n', s.unlocked_n,
    'ketat', s.ketat, 'status', s.status, 'discussing', _discussing(s), 'since', v_since,
    'disc_secs', floor(_paused_secs(s.discuss_log, s.created_at, now()))::int,
    'disc_count', jsonb_array_length(s.discuss_log));
end $$;

create or replace function adm_flow(p_token uuid, p_session uuid, p_action text, p_unlock boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; n int; total int;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session for update;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s); total := cardinality(s.question_ids);
  if p_action not in ('start', 'end', 'unlock') then raise exception 'Aksi tidak dikenal.'; end if;

  if p_action = 'start' then
    if not _discussing(s) then
      update sessions set discuss_log = s.discuss_log || jsonb_build_array(jsonb_build_object('s', now(), 'e', null)) where id = s.id;
    end if;
  elsif p_action = 'end' then
    if _discussing(s) then
      update sessions
         set discuss_log = (select coalesce(jsonb_agg(case when d ->> 'e' is null then jsonb_set(d, '{e}', to_jsonb(now())) else d end order by ord), '[]'::jsonb)
                              from jsonb_array_elements(s.discuss_log) with ordinality as t(d, ord))
       where id = s.id;
    end if;
  end if;
  if (p_action = 'unlock' or (p_action = 'end' and p_unlock)) and s.lock_mode = 'locked' and n is not null then
    update sessions set unlocked_n = least(total, s.unlocked_n + n) where id = s.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Soal: jenis soal
create or replace function adm_import(p_token uuid, p_bank_name text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_bank uuid; it jsonb; v_id uuid; ins int := 0; skp int := 0; v_name text := btrim(coalesce(p_bank_name, ''));
        v_stem text; v_opts jsonb; v_ans text;
begin
  perform _admin(p_token);
  if v_name = '' then raise exception 'Nama file/bidang kosong.'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'Data soal tidak valid.'; end if;
  if jsonb_array_length(p_items) > 300 then raise exception 'Maksimal 300 soal per kiriman.'; end if;

  insert into banks (name) values (v_name) on conflict (name) do nothing;
  select id into v_bank from banks where name = v_name;

  for it in select * from jsonb_array_elements(p_items) loop
    v_stem := btrim(coalesce(it ->> 'stem', ''));
    v_opts := it -> 'options';
    v_ans  := upper(coalesce(it ->> 'answer', ''));
    if v_stem = '' or jsonb_typeof(v_opts) <> 'array' or jsonb_array_length(v_opts) < 2 or jsonb_array_length(v_opts) > 5
       or v_ans !~ '^[A-E]$' or (ascii(v_ans) - 64) > jsonb_array_length(v_opts) then
      raise exception 'Soal nomor % tidak valid (teks, pilihan, atau kunci).', coalesce(it ->> 'num', '?');
    end if;
    select q.id into v_id from questions q where q.bank_id = v_bank and md5(q.stem) = md5(v_stem) limit 1;
    if v_id is not null then
      update questions set active = true where id = v_id;
      skp := skp + 1;
    else
      insert into questions (bank_id, num, stem, image, options, qtype)
      values (v_bank, nullif(it ->> 'num', '')::int, v_stem, nullif(it ->> 'image', ''), v_opts, _qtype(v_stem))
      returning id into v_id;
      insert into question_keys (question_id, answer) values (v_id, v_ans);
      ins := ins + 1;
    end if;
  end loop;
  return jsonb_build_object('bank_id', v_bank, 'inserted', ins, 'skipped', skp);
end $$;

create or replace function adm_questions(p_token uuid, p_bank uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'num', q.num, 'stem', q.stem, 'options', q.options,
           'answer', k.answer, 'active', q.active, 'has_image', q.image is not null, 'qtype', coalesce(q.qtype, 'Lainnya'))
           order by q.num nulls last, q.created_at), '[]'::jsonb) into v
  from questions q left join question_keys k on k.question_id = q.id
  where q.bank_id = p_bank;
  return v;
end $$;

create or replace function adm_set_qtype(p_token uuid, p_qid uuid, p_type text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  p_type := btrim(coalesce(p_type, ''));
  if length(p_type) < 2 or length(p_type) > 40 then raise exception 'Jenis soal harus 2 sampai 40 karakter.'; end if;
  update questions set qtype = p_type where id = p_qid;
  return jsonb_build_object('ok', true);
end $$;

-- Isi jenis soal untuk soal yang belum punya (tebakan kata kunci; bisa dikoreksi admin)
update questions set qtype = _qtype(stem) where qtype is null;

-- ---------- Buka fungsi ke aplikasi (kunci anon) ----------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like 'app\_%' or p.proname like 'adm\_%')
  loop
    execute format('revoke all on function %s from public', f.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon', f.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
