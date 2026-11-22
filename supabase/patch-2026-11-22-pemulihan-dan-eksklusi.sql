-- ============================================================
-- Patch 2026-11-22: (1) pulihkan fungsi yang tertimpa skema lama,
--                   (2) tambah opsi "kecualikan soal dari sesi sebelumnya".
-- Aman dijalankan ulang. Dijalankan dalam satu transaksi.
-- ============================================================
begin;

-- ---------- Mode tampil kunci: angka boleh diikuti "s" (buka satu per satu) ----------
alter table sessions drop constraint if exists sessions_feedback_mode_check;
alter table sessions add constraint sessions_feedback_mode_check
  check (feedback_mode in ('each','end') or feedback_mode ~ '^[0-9]{1,3}s?$');

-- ---------- Fungsi bantu: jawaban pada soal yang sudah dikunci tidak boleh berubah ----------
create or replace function _keep_locked(p_ids uuid[], p_locked int, p_old jsonb, p_new jsonb) returns jsonb
language plpgsql immutable set search_path = public, extensions as $$
declare v jsonb := coalesce(p_new, '{}'::jsonb); i int; k text;
begin
  if coalesce(p_locked, 0) <= 0 then return v; end if;
  for i in 1..least(p_locked, cardinality(p_ids)) loop
    k := p_ids[i]::text;
    v := v - k;
    if p_old ? k then v := v || jsonb_build_object(k, p_old -> k); end if;
  end loop;
  return v;
end $$;
revoke execute on function _keep_locked(uuid[], int, jsonb, jsonb) from public, anon, authenticated;

-- ---------- Profil: warna boleh diikuti "|" lalu emoji / foto ----------
create or replace function app_set_avatar(p_token uuid, p_color text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  if p_color is null or length(p_color) > 60000 or p_color !~ '^#[0-9A-Fa-f]{6}(\|.*)?$' then
    raise exception 'Warna atau gambar profil tidak valid.';
  end if;
  update profiles set avatar_color = p_color where id = r.id returning * into r;
  return _pj(r);
end $$;

-- ---------- Daftar file/bidang ----------
create or replace function adm_banks(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'system', b.system,
           'active', (select count(*) from questions q where q.bank_id = b.id and q.active),
           'total',  (select count(*) from questions q where q.bank_id = b.id)
         ) order by b.name), '[]'::jsonb) into v
  from banks b;
  return v;
end $$;

-- ---------- Buat sesi: dibagi rata per sistem + opsi eksklusi sesi lama ----------
create or replace function adm_create_session(p_token uuid, p_title text, p_bank_ids uuid[], p_count int,
                                              p_timer int, p_feedback text,
                                              p_exclude_sessions uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; v_ids uuid[]; v_title text := btrim(coalesce(p_title, ''));
        v_used uuid[]; v_n int; v_sys text[]; v_avail int[]; v_alloc int[]; v_left int; i int; moved boolean;
        v_total int;
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
  if p_timer is not null and (p_timer < 1 or p_timer > 600) then raise exception 'Timer harus 1 sampai 600 menit.'; end if;
  if p_bank_ids is null or cardinality(p_bank_ids) = 0 then raise exception 'Pilih minimal satu file/bidang.'; end if;

  -- Soal yang sudah dipakai di sesi lama yang dipilih admin (kosong = tanpa eksklusi)
  select coalesce(array_agg(distinct t.u), '{}') into v_used
    from sessions s, unnest(s.question_ids) as t(u)
   where s.id = any(coalesce(p_exclude_sessions, '{}'));

  -- Soal tersedia per sistem
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

  -- Bagi rata per sistem (bergiliran); sistem yang soalnya kurang dilewati
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

  insert into sessions (title, question_ids, timer_minutes, feedback_mode, created_by, bank_ids)
  values (v_title, v_ids, p_timer, p_feedback, r.id, p_bank_ids);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Hitung soal tersedia (untuk tampilan form) ----------
create or replace function adm_pool_count(p_token uuid, p_bank_ids uuid[], p_exclude_sessions uuid[] default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_n int; v_all int;
begin
  perform _admin(p_token);
  select count(*) into v_all from questions q join question_keys k on k.question_id = q.id
   where q.active and q.bank_id = any(coalesce(p_bank_ids, '{}'));
  select count(*) into v_n from questions q join question_keys k on k.question_id = q.id
   where q.active and q.bank_id = any(coalesce(p_bank_ids, '{}'))
     and q.id <> all (coalesce((select array_agg(distinct t.x) from sessions s, unnest(s.question_ids) as t(x)
                                 where s.id = any(coalesce(p_exclude_sessions, '{}'))), '{}'));
  return jsonb_build_object('available', v_n, 'excluded', v_all - v_n);
end $$;

-- ---------- Ujian: mulai (kirim juga jumlah soal terkunci dan nomor revisi) ----------
create or replace function app_start(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_q jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'no', u.ord, 'bank', coalesce(b.system, b.name), 'system', coalesce(b.system, b.name),
           'stem', q.stem, 'image', q.image, 'options', q.options
         ) order by u.ord), '[]'::jsonb) into v_q
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id;

  return jsonb_build_object(
    'submitted', false,
    'session', jsonb_build_object('id', s.id, 'title', s.title, 'timer_minutes', s.timer_minutes,
                                  'feedback_mode', s.feedback_mode, 'total', cardinality(s.question_ids), 'rev', s.rev),
    'questions', v_q,
    'answers', a.answers,
    'flags', a.flags,
    'locked', a.locked_n,
    'elapsed', extract(epoch from (now() - a.started_at))::int
  );
end $$;

-- ---------- Ujian: simpan (jawaban pada soal terkunci tidak bisa diubah) ----------
create or replace function app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; a attempts; s sessions;
begin
  r := _me(p_token);
  if jsonb_typeof(p_answers) <> 'object' or jsonb_typeof(p_flags) <> 'object' then
    raise exception 'Data tidak valid.';
  end if;
  select * into a from attempts where session_id = p_session and profile_id = r.id and submitted_at is null for update;
  if found then
    select * into s from sessions where id = p_session;
    update attempts
       set answers = _keep_locked(s.question_ids, a.locked_n, a.answers, p_answers),
           flags   = _keep_locked(s.question_ids, a.locked_n, a.flags, p_flags)
     where id = a.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Ujian: buka kunci. each = per nomor; blok = hanya soal yang sudah diselesaikan (terkunci) ----------
create or replace function app_reveal(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb; qid uuid; idx int; ok boolean; k text;
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
      if k is not null then res := res || jsonb_build_object(qid::text, k); end if;
    end if;
  end loop;
  return res;
end $$;

-- ---------- Ujian: kumpulkan ----------
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

  p_answers := _keep_locked(s.question_ids, a.locked_n, a.answers, case when jsonb_typeof(p_answers) = 'object' then p_answers else a.answers end);
  p_flags   := _keep_locked(s.question_ids, a.locked_n, a.flags,   case when jsonb_typeof(p_flags) = 'object' then p_flags else a.flags end);

  select count(*) into v_score
  from unnest(s.question_ids) as u(qid)
  join question_keys k on k.question_id = u.qid
  where p_answers ->> (u.qid::text) = k.answer;

  v_time := extract(epoch from (now() - a.started_at))::int;
  if s.timer_minutes is not null and v_time > s.timer_minutes * 60 then
    v_time := s.timer_minutes * 60;
  end if;

  update attempts
     set answers = p_answers, flags = p_flags, submitted_at = now(), score = v_score, time_taken = v_time,
         locked_n = cardinality(s.question_ids)
   where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Hasil: analisis per sistem organ ----------
create or replace function app_result(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_rows jsonb; v_sys jsonb; v_rank int; v_n int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found or a.submitted_at is null then raise exception 'Hasil belum tersedia. Kumpulkan dulu sesinya.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'id', q.id, 'bank', coalesce(b.system, b.name),
           'mine', coalesce(a.answers ->> (q.id::text), '-'),
           'key', k.answer,
           'ok', (a.answers ->> (q.id::text)) = k.answer,
           'flag', coalesce((a.flags ->> (q.id::text))::boolean, false)
         ) order by u.ord), '[]'::jsonb) into v_rows
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id;

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

  select 1 + count(*) into v_rank from attempts t
   where t.session_id = s.id and t.submitted_at is not null
     and (t.score > a.score or (t.score = a.score and t.time_taken < a.time_taken));
  select count(*) into v_n from attempts t where t.session_id = s.id and t.submitted_at is not null;

  return jsonb_build_object(
    'title', s.title, 'score', a.score, 'total', cardinality(s.question_ids),
    'time_taken', a.time_taken, 'rank', v_rank, 'participants', v_n,
    'rows', v_rows, 'banks', v_sys
  );
end $$;

-- ---------- Riwayat: per sistem organ ----------
create or replace function app_history(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v_hist jsonb; v_banks jsonb;
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

  return jsonb_build_object('history', v_hist, 'banks', v_banks);
end $$;

-- ---------- Admin: ganti satu soal (peserta diberi tahu lewat nomor revisi) ----------
create or replace function adm_swap_question(p_token uuid, p_session uuid, p_qid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; idx int; v_new uuid; v_sys text;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session for update;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  idx := array_position(s.question_ids, p_qid);
  if idx is null then raise exception 'Soal tidak ada di sesi ini.'; end if;
  if exists (select 1 from attempts a where a.session_id = s.id and a.answers ? p_qid::text) then
    raise exception 'Soal ini sudah dijawab oleh peserta, tidak bisa diganti.';
  end if;

  select coalesce(b.system, b.name) into v_sys from questions q join banks b on b.id = q.bank_id where q.id = p_qid;

  select q.id into v_new
  from questions q
  join question_keys k on k.question_id = q.id
  join banks b on b.id = q.bank_id
  where q.active and coalesce(b.system, b.name) = v_sys
    and (cardinality(s.bank_ids) = 0 or q.bank_id = any(s.bank_ids))
    and q.id <> all (s.question_ids)
    and q.id <> all (s.swapped_out)
  order by random() limit 1;
  if v_new is null then raise exception 'Tidak ada soal pengganti yang tersedia untuk sistem ini.'; end if;

  update sessions
     set question_ids = (select array_agg(case when ord = idx then v_new else qid end order by ord)
                         from unnest(s.question_ids) with ordinality as u(qid, ord)),
         swapped_out = array_append(s.swapped_out, p_qid),
         rev = s.rev + 1,
         notice = 'Soal nomor ' || idx || ' diganti oleh admin.'
   where id = s.id;
  update attempts set flags = flags - p_qid::text where session_id = s.id;

  return jsonb_build_object('ok', true, 'no', idx);
end $$;

-- ---------- Buka fungsi ke aplikasi ----------
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

commit;
notify pgrst, 'reload schema';
