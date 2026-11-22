-- ============================================================
-- Patch 2026-11-23c: timer berlaku PER BAGIAN bila kunci tampil per bagian (mis. 10 menit untuk 20 nomor).
--   - Tiap peserta punya jam bagian sendiri (dimulai saat bagian itu terbuka baginya, tidak jalan saat diskusi/jeda).
--   - Waktu bagian habis: bagian otomatis diselesaikan (jawaban dikunci, kunci dibuka), bagian berikutnya mulai.
--   - Pada sesi bertimer + bagian, hanya bagian yang sedang berjalan yang bisa dijawab (urut).
--   - Info progres teman di bagian yang sama untuk layar ujian.
-- Bersifat tambahan. Aman dijalankan ulang. Dijalankan SETELAH patch-2026-11-23b-belajar-ulang.sql.
-- ============================================================
begin;

alter table attempts add column if not exists block_starts jsonb not null default '{}'::jsonb;  -- {"1": detik-berjalan saat bagian 1 mulai, ...}

-- ---------- Fungsi bantu ----------
-- batas soal yang boleh dijawab satu peserta (null = semua)
create or replace function _open_for(s sessions, a attempts) returns int
language sql stable as $$
  select case
    when _bsize(s) is not null and s.timer_minutes is not null
      then least(coalesce(_open_n(s), cardinality(s.question_ids)), (a.locked_n / _bsize(s) + 1) * _bsize(s), cardinality(s.question_ids))
    else _open_n(s) end
$$;

create or replace function _blk_info(s sessions, a attempts) returns jsonb
language sql stable as $$
  select case
    when _bsize(s) is null or s.timer_minutes is null or a.locked_n >= cardinality(s.question_ids)
      then jsonb_build_object('blk', null, 'blk_start', null)
    else jsonb_build_object('blk', a.locked_n / _bsize(s) + 1,
                            'blk_start', (a.block_starts ->> (a.locked_n / _bsize(s) + 1)::text)::int)
  end
$$;

-- berapa teman yang sudah menyelesaikan bagian yang sedang dikerjakan / baru selesai dikerjakan peserta ini
create or replace function _blk_peers(s sessions, a attempts) returns jsonb
language plpgsql stable as $$
declare n int := _bsize(s); total int := cardinality(s.question_ids); re int;
begin
  if n is null or s.owner is not null then return null; end if;
  if a.locked_n > 0 and s.lock_mode = 'locked' and a.locked_n >= s.unlocked_n then re := a.locked_n;
  else re := least((a.locked_n / n + 1) * n, total); end if;
  return (select jsonb_build_object('done', count(*) filter (where t.submitted_at is not null or t.locked_n >= re),
                                    'all', count(*), 'blk', (re + n - 1) / n)
            from attempts t where t.session_id = s.id);
end $$;

-- Terapkan batas waktu bagian: selesaikan otomatis bagian yang waktunya habis, catat awal bagian yang sedang berjalan
create or replace function _blk_sync(p_session uuid, p_profile uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; a attempts; n int; total int; dl int; el int; k int; st int; carry int; avail boolean; ln int; bs jsonb;
begin
  select * into s from sessions where id = p_session;
  if not found then return; end if;
  n := _bsize(s);
  if n is null or s.timer_minutes is null then return; end if;
  select * into a from attempts where session_id = p_session and profile_id = p_profile and submitted_at is null for update;
  if not found then return; end if;
  total := cardinality(s.question_ids); dl := s.timer_minutes * 60; el := _elapsed(s, a);
  ln := a.locked_n; bs := a.block_starts;
  loop
    exit when ln >= total;
    k := ln / n + 1;
    avail := s.lock_mode <> 'locked' or ((k - 1) * n) < s.unlocked_n;
    exit when not avail;
    st := (bs ->> (k::text))::int;
    if st is null then
      st := coalesce(carry, el);
      bs := bs || jsonb_build_object(k::text, st);
    end if;
    carry := null;
    if el >= st + dl then
      ln := least(ln + n, total);
      carry := st + dl;
    else
      exit;
    end if;
  end loop;
  if ln <> a.locked_n or bs <> a.block_starts then
    update attempts set locked_n = ln, block_starts = bs where id = a.id;
  end if;
end $$;

revoke execute on function _open_for(sessions, attempts)  from public, anon, authenticated;
revoke execute on function _blk_info(sessions, attempts)  from public, anon, authenticated;
revoke execute on function _blk_peers(sessions, attempts) from public, anon, authenticated;
revoke execute on function _blk_sync(uuid, uuid)          from public, anon, authenticated;

-- ---------- Peserta ----------
create or replace function app_start(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_q jsonb; v_open int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;

  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then
    if s.status <> 'open' then raise exception 'Sesi ini sudah ditutup.'; end if;
    insert into attempts (session_id, profile_id) values (s.id, r.id) returning * into a;
  end if;

  if a.submitted_at is not null then
    return jsonb_build_object('submitted', true);
  end if;

  perform _blk_sync(s.id, r.id);
  select * into a from attempts where id = a.id;

  v_open := _open_for(s, a);
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
                                  'discussing', _discussing(s), 'kind', s.kind, 'allow_pause', s.allow_pause),
    'questions', v_q,
    'answers', a.answers,
    'flags', a.flags,
    'locked', a.locked_n,
    'revealed', to_jsonb(a.revealed),
    'viol', jsonb_array_length(a.violations),
    'times', a.times,
    'paused', _is_paused(a),
    'notes', coalesce((select jsonb_object_agg(n.question_id::text, n.body) from notes n
                        where n.profile_id = r.id and n.question_id = any(s.question_ids)), '{}'::jsonb),
    'bp', _blk_peers(s, a),
    'elapsed', _elapsed(s, a)
  ) || _blk_info(s, a);
end $$;

create or replace function app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; a attempts; s sessions; v_ans jsonb;
begin
  r := _me(p_token);
  if jsonb_typeof(p_answers) <> 'object' or jsonb_typeof(p_flags) <> 'object' then
    raise exception 'Data tidak valid.';
  end if;
  perform _blk_sync(p_session, r.id);
  select * into a from attempts where session_id = p_session and profile_id = r.id and submitted_at is null for update;
  if found then
    select * into s from sessions where id = p_session;
    v_ans := _strip_after(s.question_ids, _open_for(s, a), _keep_locked(s.question_ids, a.locked_n, a.answers, p_answers));
    if _discussing(s) or _is_paused(a) then v_ans := a.answers; end if;
    update attempts
       set answers = v_ans,
           flags   = _keep_locked(s.question_ids, a.locked_n, a.flags, p_flags)
     where id = a.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists app_finalize(uuid, uuid, jsonb, jsonb);

-- p_upto: nomor terakhir bagian yang ingin diselesaikan; bila sudah selesai (mis. otomatis karena waktu habis) tidak maju lagi
create or replace function app_finalize(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb, p_upto int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; n int; total int; nxt int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if s.feedback_mode !~ '^[0-9]' then raise exception 'Sesi ini tidak memakai blok.'; end if;
  n := regexp_replace(s.feedback_mode, 's$', '')::int;
  total := cardinality(s.question_ids);
  perform app_save(p_token, p_session, p_answers, p_flags);
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  if a.submitted_at is not null then return jsonb_build_object('locked', total); end if;
  if p_upto is not null and a.locked_n >= p_upto then
    return jsonb_build_object('locked', a.locked_n) || _blk_info(s, a);
  end if;
  if s.lock_mode = 'locked' and a.locked_n >= s.unlocked_n then
    raise exception 'Bagian berikutnya belum dibuka admin.';
  end if;
  nxt := least(a.locked_n + n, total);
  update attempts set locked_n = greatest(locked_n, nxt) where id = a.id;
  perform _blk_sync(s.id, r.id);
  select * into a from attempts where id = a.id;
  return jsonb_build_object('locked', a.locked_n) || _blk_info(s, a);
end $$;

create or replace function app_reveal(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb; qid uuid; idx int; ok boolean; k text;
        v_new uuid[] := '{}';
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  perform _blk_sync(p_session, r.id);
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
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then return jsonb_build_object('rev', 0, 'notice', null, 'submitted', false); end if;
  perform _blk_sync(p_session, r.id);
  select * into a from attempts where session_id = p_session and profile_id = r.id;
  v_has := found;
  if v_has and a.submitted_at is null then
    update attempts set last_seen = now() where id = a.id;
  end if;
  return jsonb_build_object('rev', s.rev, 'notice', s.notice,
    'submitted', coalesce(v_has and a.submitted_at is not null, false),
    'discussing', _discussing(s), 'unlocked_n', s.unlocked_n, 'lock_mode', s.lock_mode,
    'paused', v_has and _is_paused(a),
    'locked', case when v_has then a.locked_n end,
    'bp', case when v_has then _blk_peers(s, a) end,
    'elapsed', case when v_has and a.submitted_at is null then _elapsed(s, a) end)
    || case when v_has and a.submitted_at is null then _blk_info(s, a) else '{}'::jsonb end;
end $$;

create or replace function app_submit(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_score int; v_time int; v_cap int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  perform _blk_sync(p_session, r.id);
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  if a.submitted_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;

  p_answers := _strip_after(s.question_ids, _open_for(s, a),
      _keep_locked(s.question_ids, a.locked_n, a.answers, case when jsonb_typeof(p_answers) = 'object' then p_answers else a.answers end));
  p_flags   := _keep_locked(s.question_ids, a.locked_n, a.flags, case when jsonb_typeof(p_flags) = 'object' then p_flags else a.flags end);

  select count(*) into v_score
  from unnest(s.question_ids) as u(qid)
  join question_keys k on k.question_id = u.qid
  where p_answers ->> (u.qid::text) = k.answer;

  v_time := _elapsed(s, a);
  if s.timer_minutes is not null then
    v_cap := s.timer_minutes * 60 * case when _bsize(s) is not null then ceil(cardinality(s.question_ids)::numeric / _bsize(s))::int else 1 end;
    if v_time > v_cap then v_time := v_cap; end if;
  end if;

  update attempts
     set answers = p_answers, flags = p_flags, submitted_at = now(), score = v_score, time_taken = v_time,
         locked_n = cardinality(s.question_ids)
   where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_submit_attempts(p_token uuid, p_session uuid, p_profile uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; a attempts; v_score int; v_time int; v_cap int; c int := 0;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  for a in select * from attempts where session_id = p_session and submitted_at is null and (p_profile is null or profile_id = p_profile) for update loop
    select count(*) into v_score from unnest(s.question_ids) as u(qid) join question_keys k on k.question_id = u.qid where a.answers ->> (u.qid::text) = k.answer;
    v_time := _elapsed(s, a);
    if s.timer_minutes is not null then
      v_cap := s.timer_minutes * 60 * case when _bsize(s) is not null then ceil(cardinality(s.question_ids)::numeric / _bsize(s))::int else 1 end;
      if v_time > v_cap then v_time := v_cap; end if;
    end if;
    update attempts set submitted_at = now(), score = v_score, time_taken = v_time, locked_n = cardinality(s.question_ids) where id = a.id;
    c := c + 1;
  end loop;
  return jsonb_build_object('ok', true, 'submitted', c);
end $$;

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
