-- ============================================================
-- Patch 2026-11-23b: latihan ulang soal salah/bendera/catatan/soal baru,
--   catatan pribadi, persentase teman, rekap diskusi admin, waktu per soal,
--   jeda mandiri, peringkat per sistem/jenis, perkembangan jangka panjang.
-- Bersifat tambahan. Aman dijalankan ulang. Dijalankan SETELAH patch-2026-11-23-diskusi-kunci-jenis.sql.
-- ============================================================
begin;

-- ---------- Kolom & tabel baru ----------
alter table sessions add column if not exists owner       uuid references profiles(id) on delete cascade;  -- null = sesi umum; terisi = latihan pribadi
alter table sessions add column if not exists kind        text not null default 'sesi';
alter table sessions drop constraint if exists sessions_kind_check;
alter table sessions add constraint sessions_kind_check check (kind in ('sesi','latihan'));
alter table sessions add column if not exists allow_pause boolean not null default false;
alter table attempts add column if not exists times      jsonb not null default '{}'::jsonb;   -- {id soal: detik}
alter table attempts add column if not exists pause_log  jsonb not null default '[]'::jsonb;   -- jeda mandiri [{"s","e"}]

create table if not exists notes (
  profile_id  uuid not null references profiles(id) on delete cascade,
  question_id uuid not null references questions(id) on delete cascade,
  body        text not null,
  updated_at  timestamptz not null default now(),
  primary key (profile_id, question_id)
);
alter table notes enable row level security;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on table notes from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on table notes from authenticated'; end if;
end $$;

-- ---------- Waktu: jeda mandiri ikut dikurangi ----------
create or replace function _is_paused(a attempts) returns boolean
language sql stable as $$
  select exists (select 1 from jsonb_array_elements(a.pause_log) d where d ->> 'e' is null)
$$;

create or replace function _elapsed(s sessions, a attempts) returns int
language sql stable as $$
  select greatest(0, floor(extract(epoch from (now() - a.started_at))
                           - _paused_secs(s.discuss_log, a.started_at, now())
                           - _paused_secs(a.pause_log, a.started_at, now())))::int
$$;
revoke execute on function _is_paused(attempts) from public, anon, authenticated;

-- ---------- Peserta: mulai, simpan, sinkron ----------
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

  v_open := _open_n(s);
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
    if _discussing(s) or _is_paused(a) then v_ans := a.answers; end if;   -- saat diskusi / jeda jawaban tidak berubah
    update attempts
       set answers = v_ans,
           flags   = _keep_locked(s.question_ids, a.locked_n, a.flags, p_flags)
     where id = a.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function app_rev(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_has boolean;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then return jsonb_build_object('rev', 0, 'notice', null, 'submitted', false); end if;
  select * into a from attempts where session_id = p_session and profile_id = r.id;
  v_has := found;
  if v_has and a.submitted_at is null then
    update attempts set last_seen = now() where id = a.id;
  end if;
  return jsonb_build_object('rev', s.rev, 'notice', s.notice,
    'submitted', coalesce(v_has and a.submitted_at is not null, false),
    'discussing', _discussing(s), 'unlocked_n', s.unlocked_n, 'lock_mode', s.lock_mode,
    'paused', v_has and _is_paused(a),
    'elapsed', case when v_has and a.submitted_at is null then _elapsed(s, a) end);
end $$;

-- Jeda mandiri (hanya sesi yang mengizinkan)
create or replace function app_pause(p_token uuid, p_session uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if not s.allow_pause then raise exception 'Sesi ini tidak mengizinkan jeda.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found or a.submitted_at is not null then raise exception 'Sesi belum dimulai atau sudah dikumpulkan.'; end if;
  if p_action = 'start' then
    if not _is_paused(a) then
      update attempts set pause_log = a.pause_log || jsonb_build_array(jsonb_build_object('s', now(), 'e', null)) where id = a.id;
    end if;
  elsif p_action = 'end' then
    if _is_paused(a) then
      update attempts
         set pause_log = (select coalesce(jsonb_agg(case when d ->> 'e' is null then jsonb_set(d, '{e}', to_jsonb(now())) else d end order by ord), '[]'::jsonb)
                            from jsonb_array_elements(a.pause_log) with ordinality as t(d, ord))
       where id = a.id;
    end if;
  else
    raise exception 'Aksi tidak dikenal.';
  end if;
  return jsonb_build_object('ok', true, 'paused', p_action = 'start');
end $$;

-- Waktu per soal (detik, nilai kumulatif dari peserta; nilai terbesar yang dipakai)
create or replace function app_times(p_token uuid, p_session uuid, p_times jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; k text; v int; cur jsonb;
begin
  r := _me(p_token);
  if jsonb_typeof(p_times) <> 'object' then return jsonb_build_object('ok', false); end if;
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then return jsonb_build_object('ok', false); end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id and submitted_at is null for update;
  if not found then return jsonb_build_object('ok', false); end if;
  cur := a.times;
  for k, v in select key, least(3600, greatest(0, floor(value::numeric)::int)) from jsonb_each_text(p_times) where value ~ '^[0-9]+(\.[0-9]+)?$' loop
    if k ~ '^[0-9a-f-]{36}$' and k::uuid = any(s.question_ids) then
      if v > coalesce((cur ->> k)::int, 0) then cur := cur || jsonb_build_object(k, v); end if;
    end if;
  end loop;
  update attempts set times = cur where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

-- Persentase teman per soal (hanya untuk soal yang kuncinya sudah terbuka bagi pemanggil)
create or replace function app_peers(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb; qid uuid; idx int; ok boolean; v jsonb; k text;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and owner is null;
  if not found then return res; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then return res; end if;
  foreach qid in array coalesce(p_qids, '{}'::uuid[]) loop
    idx := array_position(s.question_ids, qid);
    continue when idx is null;
    ok := a.submitted_at is not null
          or (s.feedback_mode = 'each' and a.answers ? qid::text)
          or (s.feedback_mode ~ '^[0-9]' and idx <= a.locked_n);
    continue when not ok;
    select answer into k from question_keys where question_id = qid;
    continue when k is null;
    select jsonb_build_object('n', count(*), 'ok', count(*) filter (where t.answers ->> qid::text = k),
             'd', jsonb_build_object(
               'A', count(*) filter (where t.answers ->> qid::text = 'A'), 'B', count(*) filter (where t.answers ->> qid::text = 'B'),
               'C', count(*) filter (where t.answers ->> qid::text = 'C'), 'D', count(*) filter (where t.answers ->> qid::text = 'D'),
               'E', count(*) filter (where t.answers ->> qid::text = 'E'))) into v
    from attempts t
    where t.session_id = s.id
      and (t.submitted_at is not null
           or (s.feedback_mode = 'each' and t.answers ? qid::text)
           or (s.feedback_mode ~ '^[0-9]' and idx <= t.locked_n));
    res := res || jsonb_build_object(qid::text, v);
  end loop;
  return res;
end $$;

-- ---------- Catatan pribadi ----------
create or replace function app_note_set(p_token uuid, p_qid uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  if not exists (select 1 from attempts a join sessions s on s.id = a.session_id
                  where a.profile_id = r.id and p_qid = any(s.question_ids)) then
    raise exception 'Soal tidak ditemukan.';
  end if;
  p_body := left(btrim(coalesce(p_body, '')), 2000);
  if p_body = '' then
    delete from notes where profile_id = r.id and question_id = p_qid;
  else
    insert into notes (profile_id, question_id, body) values (r.id, p_qid, p_body)
    on conflict (profile_id, question_id) do update set body = excluded.body, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function app_notes(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v jsonb;
begin
  r := _me(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('qid', n.question_id, 'body', n.body, 'at', n.updated_at,
           'stem', left(q.stem, 240), 'file', b.name, 'system', coalesce(b.system, b.name), 'qtype', coalesce(q.qtype, 'Lainnya'))
           order by n.updated_at desc), '[]'::jsonb) into v
  from notes n join questions q on q.id = n.question_id join banks b on b.id = q.bank_id
  where n.profile_id = r.id;
  return v;
end $$;

-- ---------- Latihan ulang ----------
-- kind: wrong (salah/kosong terakhir kali), flag (bendera terakhir), note (punya catatan), fresh (belum pernah),
--       mix (gabungan wrong+flag+note), sesi (salah/bendera pada satu sesi)
create or replace function _drill_pool(p_profile uuid, p_kind text, p_sys text, p_session uuid default null)
returns table (o_qid uuid, o_w int)
language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_column
begin
  return query
  with att as (
    select a.submitted_at, a.answers, a.flags, s.question_ids, s.id as sid
    from attempts a join sessions s on s.id = a.session_id
    where a.profile_id = p_profile and a.submitted_at is not null
  ), ev as (
    select u.qid, att.submitted_at, att.sid, att.answers ->> (u.qid::text) as mine,
           coalesce((att.flags ->> (u.qid::text))::boolean, false) as flag, k.answer as key
    from att cross join lateral unnest(att.question_ids) as u(qid)
    join question_keys k on k.question_id = u.qid
  ), latest as (
    select distinct on (e.qid) e.qid, (e.mine is distinct from e.key) as wrong, e.flag
    from ev e order by e.qid, e.submitted_at desc
  ), wr as (
    select e.qid, count(*) filter (where e.mine is distinct from e.key)::int as w from ev e group by e.qid
  ), cand as (
    select q.id as qid, coalesce(wr.w, 0) as w,
      case p_kind
        when 'wrong' then coalesce(l.wrong, false)
        when 'flag'  then coalesce(l.flag, false)
        when 'note'  then exists (select 1 from notes n where n.profile_id = p_profile and n.question_id = q.id)
        when 'fresh' then l.qid is null
        when 'sesi'  then exists (select 1 from ev e where e.sid = p_session and e.qid = q.id and (e.mine is distinct from e.key or e.flag))
        else coalesce(l.wrong, false) or coalesce(l.flag, false)
             or exists (select 1 from notes n where n.profile_id = p_profile and n.question_id = q.id)
      end as hit
    from questions q
    join question_keys k on k.question_id = q.id
    join banks b on b.id = q.bank_id
    left join latest l on l.qid = q.id
    left join wr on wr.qid = q.id
    where q.active and (p_sys is null or coalesce(b.system, b.name) = p_sys)
  )
  select c.qid, c.w from cand c where c.hit;
end $$;
revoke execute on function _drill_pool(uuid, text, text, uuid) from public, anon, authenticated;

create or replace function app_drill_stats(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; v jsonb; v_ever int; v_master int;
begin
  r := _me(p_token);
  with att as (
    select a.submitted_at, a.answers, s.question_ids
    from attempts a join sessions s on s.id = a.session_id
    where a.profile_id = r.id and a.submitted_at is not null
  ), ev as (
    select u.qid, att.submitted_at, (att.answers ->> (u.qid::text)) is distinct from k.answer as wrong
    from att cross join lateral unnest(att.question_ids) as u(qid)
    join question_keys k on k.question_id = u.qid
  ), latest as (
    select distinct on (qid) qid, wrong from ev order by qid, submitted_at desc
  )
  select count(*) filter (where e.ever), count(*) filter (where e.ever and not l.wrong)
    into v_ever, v_master
  from (select qid, bool_or(wrong) as ever from ev group by qid) e join latest l on l.qid = e.qid;

  select jsonb_build_object(
    'wrong', (select count(*) from _drill_pool(r.id, 'wrong', null)),
    'flag',  (select count(*) from _drill_pool(r.id, 'flag', null)),
    'note',  (select count(*) from _drill_pool(r.id, 'note', null)),
    'fresh', (select count(*) from _drill_pool(r.id, 'fresh', null)),
    'mix',   (select count(*) from _drill_pool(r.id, 'mix', null)),
    'ever_wrong', coalesce(v_ever, 0), 'mastered', coalesce(v_master, 0),
    'by_sys', coalesce((select jsonb_agg(jsonb_build_object('sy', z.sy, 'n', z.n) order by z.n desc)
                          from (select coalesce(b.system, b.name) as sy, count(*) as n
                                  from _drill_pool(r.id, 'mix', null) p join questions q on q.id = p.o_qid join banks b on b.id = q.bank_id
                                 group by 1) z), '[]'::jsonb),
    'systems', coalesce((select jsonb_agg(distinct coalesce(b.system, b.name)) from banks b), '[]'::jsonb),
    'drills', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'total', cardinality(s.question_ids),
                          'done', a.submitted_at is not null, 'score', a.score, 'started', a.id is not null) order by s.created_at desc)
                          from sessions s left join attempts a on a.session_id = s.id and a.profile_id = r.id
                         where s.owner = r.id), '[]'::jsonb)
  ) into v;
  return v;
end $$;

create or replace function app_drill_create(p_token uuid, p_kind text, p_count int, p_sys text default null, p_session uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; v_ids uuid[]; v_id uuid; v_label text; v_n int;
begin
  r := _me(p_token);
  if p_kind not in ('wrong', 'flag', 'note', 'fresh', 'mix', 'sesi') then raise exception 'Jenis latihan tidak dikenal.'; end if;
  p_count := least(greatest(coalesce(p_count, 20), 5), 100);
  p_sys := nullif(btrim(coalesce(p_sys, '')), '');
  if (select count(*) from sessions where owner = r.id) >= 30 then
    raise exception 'Sudah ada 30 latihan. Hapus beberapa latihan lama dulu.';
  end if;
  select array_agg(x.o_qid order by random()) into v_ids from (
    select o_qid from _drill_pool(r.id, p_kind, p_sys, p_session) order by o_w desc, random() limit p_count
  ) x;
  if v_ids is null then raise exception 'Belum ada soal yang bisa dilatih untuk pilihan ini.'; end if;
  v_label := case p_kind when 'wrong' then 'Soal salah' when 'flag' then 'Soal bendera' when 'note' then 'Soal bercatatan'
                         when 'fresh' then 'Soal baru' when 'sesi' then 'Ulang sesi' else 'Campuran' end;
  insert into sessions (title, question_ids, timer_minutes, feedback_mode, created_by, bank_ids, owner, kind)
  values (v_label || coalesce(' · ' || p_sys, '') || ' · ' || to_char(now() at time zone 'Asia/Makassar', 'DD/MM HH24:MI'),
          v_ids, null, 'each', r.id, '{}', r.id, 'latihan')
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'total', cardinality(v_ids));
end $$;

create or replace function app_drill_delete(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  delete from sessions where id = p_session and owner = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Daftar sesi, peringkat, riwayat: latihan pribadi tidak ikut ----------
create or replace function app_sessions(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v jsonb;
begin
  r := _me(p_token);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v
  from (
    select s.id, s.title, cardinality(s.question_ids) as total, s.timer_minutes,
           s.feedback_mode, s.status, s.created_at, s.lock_mode, s.ketat, s.kind, s.allow_pause,
           (a.id is not null) as started,
           (a.submitted_at is not null) as done,
           a.score,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished
    from sessions s
    left join attempts a on a.session_id = s.id and a.profile_id = r.id
    where s.owner is null or s.owner = r.id
  ) x;
  return v;
end $$;

create or replace function app_leaderboard(p_token uuid, p_session uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v jsonb;
begin
  r := _me(p_token);
  if p_session is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank', x.rank, 'name', x.name, 'avatar_color', x.avatar_color,
             'score', x.score, 'total', x.total, 'time_taken', x.time_taken, 'me', x.me
           ) order by x.rank), '[]'::jsonb) into v
    from (
      select row_number() over (order by a.score desc, a.time_taken asc, p.name asc) as rank,
             p.name, p.avatar_color, a.score, cardinality(s.question_ids) as total, a.time_taken,
             (p.id = r.id) as me
      from attempts a
      join profiles p on p.id = a.profile_id
      join sessions s on s.id = a.session_id
      where a.session_id = p_session and a.submitted_at is not null and s.owner is null
    ) x;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank', x.rank, 'name', x.name, 'avatar_color', x.avatar_color,
             'score', x.score, 'total', x.total, 'time_taken', x.time_taken, 'me', x.me, 'sessions', x.sessions
           ) order by x.rank), '[]'::jsonb) into v
    from (
      select row_number() over (order by sum(a.score) desc, sum(a.time_taken) asc, p.name asc) as rank,
             p.name, p.avatar_color, sum(a.score)::int as score,
             sum(cardinality(s.question_ids))::int as total,
             sum(a.time_taken)::int as time_taken, bool_or(p.id = r.id) as me, count(*)::int as sessions
      from attempts a
      join profiles p on p.id = a.profile_id
      join sessions s on s.id = a.session_id
      where a.submitted_at is not null and s.owner is null
      group by p.id, p.name, p.avatar_color
    ) x;
  end if;
  return v;
end $$;

-- Peringkat berdasarkan akurasi per sistem / jenis soal (minimal 5 soal)
create or replace function app_rank_by(p_token uuid, p_by text default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v jsonb; v_kind text; v_val text;
begin
  r := _me(p_token);
  if p_by is not null and p_by ~ '^(sy|ty):' then v_kind := left(p_by, 2); v_val := substr(p_by, 4); end if;
  select jsonb_build_object(
    'systems', coalesce((select jsonb_agg(distinct coalesce(b.system, b.name)) from banks b), '[]'::jsonb),
    'types', coalesce((select jsonb_agg(distinct coalesce(q.qtype, 'Lainnya')) from questions q), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('rank', y.rank, 'name', y.name, 'avatar_color', y.avatar_color,
               'correct', y.c, 'total', y.n, 'me', y.me) order by y.rank)
      from (
        select row_number() over (order by x.c::numeric / x.n desc, x.n desc, x.name) as rank, x.*
        from (
          select p.id, p.name, p.avatar_color, (p.id = r.id) as me,
                 count(*) filter (where a.answers ->> (q.id::text) = k.answer) as c, count(*) as n
          from attempts a
          join sessions s on s.id = a.session_id and s.owner is null
          join profiles p on p.id = a.profile_id
          cross join lateral unnest(s.question_ids) as u(qid)
          join questions q on q.id = u.qid
          join banks b on b.id = q.bank_id
          left join question_keys k on k.question_id = q.id
          where a.submitted_at is not null
            and (v_kind is null
                 or (v_kind = 'sy' and coalesce(b.system, b.name) = v_val)
                 or (v_kind = 'ty' and coalesce(q.qtype, 'Lainnya') = v_val))
          group by p.id, p.name, p.avatar_color
          having count(*) >= 5
        ) x
      ) y), '[]'::jsonb)
  ) into v;
  return v;
end $$;

-- Perkembangan jangka panjang per sistem / jenis soal (sesi umum saja) + hari belajar
create or replace function app_progress(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v_sys jsonb; v_types jsonb; v_days jsonb;
begin
  r := _me(p_token);
  with pts as (
    select a.submitted_at as t, s.id as sid, coalesce(b.system, b.name) as sy, coalesce(q.qtype, 'Lainnya') as ty,
           (a.answers ->> (q.id::text)) = k.answer as ok
    from attempts a
    join sessions s on s.id = a.session_id and s.owner is null
    cross join lateral unnest(s.question_ids) as u(qid)
    join questions q on q.id = u.qid join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    where a.profile_id = r.id and a.submitted_at is not null
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object('name', g.sy, 'pts', g.pts) order by g.sy)
              from (select sy, jsonb_agg(jsonb_build_object('t', t, 'c', c, 'n', n) order by t) as pts
                      from (select sy, t, sid, count(*) filter (where ok) as c, count(*) as n from pts group by sy, t, sid) z
                     group by sy) g), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('name', g.ty, 'pts', g.pts) order by g.ty)
              from (select ty, jsonb_agg(jsonb_build_object('t', t, 'c', c, 'n', n) order by t) as pts
                      from (select ty, t, sid, count(*) filter (where ok) as c, count(*) as n from pts group by ty, t, sid) z
                     group by ty) g), '[]'::jsonb)
  into v_sys, v_types;
  select coalesce(jsonb_agg(distinct to_char(a.submitted_at at time zone 'Asia/Makassar', 'YYYY-MM-DD')), '[]'::jsonb) into v_days
    from attempts a where a.profile_id = r.id and a.submitted_at is not null;
  return jsonb_build_object('sys', v_sys, 'types', v_types, 'days', v_days);
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
  where a.profile_id = r.id and a.submitted_at is not null and s.owner is null;

  select coalesce(jsonb_agg(jsonb_build_object('bank', t.bank, 'correct', t.correct, 'total', t.total) order by t.bank), '[]'::jsonb)
    into v_banks
  from (
    select coalesce(b.system, b.name) as bank,
           count(*) filter (where (a.answers ->> (q.id::text)) = k.answer) as correct,
           count(*) as total
    from attempts a
    join sessions s on s.id = a.session_id and s.owner is null
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
    join sessions s on s.id = a.session_id and s.owner is null
    cross join lateral unnest(s.question_ids) as u(qid)
    join questions q on q.id = u.qid
    left join question_keys k on k.question_id = q.id
    where a.profile_id = r.id and a.submitted_at is not null
    group by coalesce(q.qtype, 'Lainnya')
  ) t;

  return jsonb_build_object('history', v_hist, 'banks', v_banks, 'types', v_types);
end $$;

-- ---------- Hasil: tambah analisis waktu ----------
create or replace function _times(p_profile uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s sessions; a attempts; v jsonb;
begin
  select * into s from sessions where id = p_session;
  select * into a from attempts where session_id = p_session and profile_id = p_profile;
  if not found then return jsonb_build_object('has', false); end if;
  with t as (
    select u.ord, coalesce(b.system, b.name) as sy, coalesce(q.qtype, 'Lainnya') as ty,
           (a.times ->> q.id::text)::int as secs,
           (a.answers ? q.id::text) as answered,
           coalesce((a.answers ->> q.id::text) = k.answer, false) as ok
    from unnest(s.question_ids) with ordinality as u(qid, ord)
    join questions q on q.id = u.qid join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    where a.times ? q.id::text
  )
  select jsonb_build_object(
    'has', count(*) > 0, 'n', count(*),
    'avg', round(avg(secs))::int,
    'avg_ok', round(avg(secs) filter (where ok))::int,
    'avg_bad', round(avg(secs) filter (where answered and not ok))::int,
    'fast_wrong', count(*) filter (where answered and not ok and secs < 10),
    'slow', coalesce((select jsonb_agg(jsonb_build_object('no', x.ord, 'sy', x.sy, 'ty', x.ty, 'secs', x.secs, 'ok', x.ok) order by x.secs desc)
                        from (select * from t order by secs desc limit 5) x), '[]'::jsonb),
    'by_sys', coalesce((select jsonb_agg(jsonb_build_object('name', g.sy, 'avg', g.av, 'n', g.n) order by g.av desc)
                          from (select sy, round(avg(secs))::int as av, count(*) as n from t group by sy) g), '[]'::jsonb),
    'by_type', coalesce((select jsonb_agg(jsonb_build_object('name', g.ty, 'avg', g.av, 'n', g.n) order by g.av desc)
                          from (select ty, round(avg(secs))::int as av, count(*) as n from t group by ty) g), '[]'::jsonb)
  ) into v from t;
  return coalesce(v, jsonb_build_object('has', false));
end $$;
revoke execute on function _times(uuid, uuid) from public, anon, authenticated;

create or replace function app_result(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  return _result(r.id, p_session) || jsonb_build_object('time', _times(r.id, p_session),
                                                       'kind', (select kind from sessions where id = p_session));
end $$;

create or replace function adm_result(p_token uuid, p_session uuid, p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  return _result(p_profile, p_session) || jsonb_build_object('person', (select name from profiles where id = p_profile),
                                                              'time', _times(p_profile, p_session),
                                                              'kind', (select kind from sessions where id = p_session));
end $$;

-- ---------- Admin ----------
create or replace function adm_sessions(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v
  from (
    select s.id, s.title, cardinality(s.question_ids) as total, s.timer_minutes, s.feedback_mode, s.status, s.created_at,
           s.lock_mode, s.unlocked_n, s.ketat, s.allow_pause, _discussing(s) as discussing,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is null) as ongoing
    from sessions s
    where s.owner is null
  ) x;
  return v;
end $$;

create or replace function adm_people(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
           'avatar_color', p.avatar_color, 'created_at', p.created_at,
           'done', (select count(*) from attempts a join sessions s on s.id = a.session_id
                     where a.profile_id = p.id and a.submitted_at is not null and s.owner is null)
         ) order by p.created_at), '[]'::jsonb) into v
  from profiles p;
  return v;
end $$;

create or replace function adm_flow_state(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s sessions; v_since int; n int;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s);
  select extract(epoch from (now() - (d ->> 's')::timestamptz))::int into v_since
    from jsonb_array_elements(s.discuss_log) d where d ->> 'e' is null limit 1;
  return jsonb_build_object(
    'total', cardinality(s.question_ids), 'block', n, 'lock_mode', s.lock_mode, 'unlocked_n', s.unlocked_n,
    'ketat', s.ketat, 'status', s.status, 'discussing', _discussing(s), 'since', v_since,
    'disc_secs', floor(_paused_secs(s.discuss_log, s.created_at, now()))::int,
    'disc_count', jsonb_array_length(s.discuss_log),
    'max_fin', case when n is null then 0 else coalesce((select max(case when t.submitted_at is not null then cardinality(s.question_ids) else t.locked_n end) / n
                                                           from attempts t where t.session_id = s.id), 0) end);
end $$;

-- Rekap satu bagian untuk bahan diskusi: persentase benar & sebaran jawaban tiap soal (peserta yang sudah menyelesaikan bagian itu)
create or replace function adm_block_recap(p_token uuid, p_session uuid, p_block int) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s sessions; n int; a0 int; b0 int; v jsonb; v_final int; v_wait jsonb;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s);
  if n is null or p_block is null or p_block < 1 then raise exception 'Sesi ini tidak memakai bagian.'; end if;
  a0 := (p_block - 1) * n + 1; b0 := least(p_block * n, cardinality(s.question_ids));
  if a0 > cardinality(s.question_ids) then raise exception 'Bagian tidak ada.'; end if;

  select count(*) into v_final from attempts t where t.session_id = s.id and (t.submitted_at is not null or t.locked_n >= b0);
  select coalesce(jsonb_agg(p.name order by p.name), '[]'::jsonb) into v_wait
    from attempts t join profiles p on p.id = t.profile_id
   where t.session_id = s.id and t.submitted_at is null and t.locked_n < b0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'sy', coalesce(b.system, b.name), 'ty', coalesce(q.qtype, 'Lainnya'),
           'stem', left(q.stem, 200), 'key', k.answer,
           'n', st.n, 'ok', st.ok, 'd', st.d) order by u.ord), '[]'::jsonb) into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id
  cross join lateral (
    select count(*)::int as n,
           (count(*) filter (where t.answers ->> (q.id::text) = k.answer))::int as ok,
           jsonb_build_object('A', count(*) filter (where t.answers ->> (q.id::text) = 'A'), 'B', count(*) filter (where t.answers ->> (q.id::text) = 'B'),
                              'C', count(*) filter (where t.answers ->> (q.id::text) = 'C'), 'D', count(*) filter (where t.answers ->> (q.id::text) = 'D'),
                              'E', count(*) filter (where t.answers ->> (q.id::text) = 'E')) as d
    from attempts t
    where t.session_id = s.id and (t.submitted_at is not null or t.locked_n >= b0)
  ) st
  where u.ord between a0 and b0;

  return jsonb_build_object('block', p_block, 'from', a0, 'to', b0, 'final', v_final, 'waiting', v_wait, 'qs', v);
end $$;

drop function if exists adm_create_session(uuid, text, uuid[], int, int, text, uuid[], text, boolean);

create or replace function adm_create_session(p_token uuid, p_title text, p_bank_ids uuid[], p_count int, p_timer int,
                                              p_feedback text, p_exclude_sessions uuid[] default '{}'::uuid[],
                                              p_lock text default 'free', p_strict boolean default false,
                                              p_pause boolean default false) returns jsonb
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
  if coalesce(p_pause, false) and coalesce(p_strict, false) then raise exception 'Jeda mandiri tidak bisa dipakai bersama mode ketat.'; end if;
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

  insert into sessions (title, question_ids, timer_minutes, feedback_mode, created_by, bank_ids, lock_mode, unlocked_n, ketat, allow_pause)
  values (v_title, v_ids, p_timer, p_feedback, r.id, p_bank_ids, p_lock, v_unlock, coalesce(p_strict, false), coalesce(p_pause, false));
  return jsonb_build_object('ok', true);
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
