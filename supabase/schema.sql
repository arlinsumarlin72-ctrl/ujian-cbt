-- !! PERINGATAN (2026-11-22): file ini TIDAK LENGKAP dan lebih lama dari database yang berjalan
-- !! (tidak ada kolom locked_n/rev/notice/system, dan beberapa fungsi versi lama).
-- !! JANGAN dijalankan ulang di database yang sudah berisi data: fungsi yang lebih baru akan tertimpa.
-- !! Sumber kebenaran: supabase/fungsi-live-2026-11-22.sql + patch-*.sql di folder ini.
-- ============================================================
-- Ruang Ujian: skema database (Supabase / PostgreSQL)
-- Jalankan SEKALI di Supabase > SQL Editor > New query > Run.
-- Aman dijalankan ulang (memakai "if not exists" / "or replace").
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabel ----------
create table if not exists profiles (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  pin_hash     text not null,
  role         text not null default 'peserta' check (role in ('peserta','admin')),
  avatar_color text not null default '#0E6A73',
  token        uuid not null default gen_random_uuid(),
  created_at   timestamptz not null default now()
);
create unique index if not exists profiles_name_uq  on profiles (lower(name));
create unique index if not exists profiles_token_uq on profiles (token);

create table if not exists banks (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists questions (
  id         uuid primary key default gen_random_uuid(),
  bank_id    uuid not null references banks(id) on delete cascade,
  num        int,
  stem       text not null,
  image      text,
  options    jsonb not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists questions_bank_idx on questions (bank_id);

-- Kunci jawaban dipisah supaya tidak pernah ikut terkirim ke peserta sebelum waktunya
create table if not exists question_keys (
  question_id uuid primary key references questions(id) on delete cascade,
  answer      text not null check (answer in ('A','B','C','D','E'))
);

create table if not exists sessions (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  question_ids   uuid[] not null,
  timer_minutes  int,
  feedback_mode  text not null default 'end' check (feedback_mode in ('each','10','20','end')),
  status         text not null default 'open' check (status in ('open','closed')),
  created_by     uuid references profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);

create table if not exists attempts (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references sessions(id) on delete cascade,
  profile_id   uuid not null references profiles(id) on delete cascade,
  answers      jsonb not null default '{}'::jsonb,
  flags        jsonb not null default '{}'::jsonb,
  started_at   timestamptz not null default now(),
  submitted_at timestamptz,
  score        int,
  time_taken   int,
  unique (session_id, profile_id)
);

-- Kunci semua tabel: tidak ada akses langsung. Semua lewat fungsi (RPC) di bawah.
alter table profiles      enable row level security;
alter table banks         enable row level security;
alter table questions     enable row level security;
alter table question_keys enable row level security;
alter table sessions      enable row level security;
alter table attempts      enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema public from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on all tables in schema public from authenticated';
  end if;
end $$;

-- ---------- Fungsi bantu (tidak dibuka ke publik) ----------
create or replace function _me(p_token uuid) returns profiles
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles;
begin
  select * into r from profiles where token = p_token;
  if not found then
    raise exception 'Sesi login tidak valid. Silakan masuk lagi.' using errcode = '28000';
  end if;
  return r;
end $$;

create or replace function _admin(p_token uuid) returns profiles
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  if r.role <> 'admin' then
    raise exception 'Fitur ini khusus admin.' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function _pj(r profiles) returns jsonb
language sql immutable as $$
  select jsonb_build_object('id', r.id, 'name', r.name, 'role', r.role, 'avatar_color', r.avatar_color)
$$;

revoke execute on function _me(uuid)       from public, anon, authenticated;
revoke execute on function _admin(uuid)    from public, anon, authenticated;
revoke execute on function _pj(profiles)   from public, anon, authenticated;

-- ---------- Akun ----------
create or replace function app_register(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; v_role text; v_name text := btrim(coalesce(p_name, ''));
begin
  if length(v_name) < 2 or length(v_name) > 40 then
    raise exception 'Nama harus 2 sampai 40 karakter.';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN harus 4 sampai 6 angka.';
  end if;
  if exists (select 1 from profiles where lower(name) = lower(v_name)) then
    raise exception 'Nama sudah dipakai. Masuk saja, atau pakai nama lain.';
  end if;
  -- pendaftar pertama otomatis menjadi admin
  v_role := case when exists (select 1 from profiles) then 'peserta' else 'admin' end;
  insert into profiles (name, pin_hash, role)
  values (v_name, crypt(p_pin, gen_salt('bf')), v_role)
  returning * into r;
  return jsonb_build_object('token', r.token, 'profile', _pj(r));
end $$;

create or replace function app_login(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  select * into r from profiles where lower(name) = lower(btrim(coalesce(p_name, '')));
  if not found or r.pin_hash <> crypt(coalesce(p_pin, ''), r.pin_hash) then
    raise exception 'Nama atau PIN salah.';
  end if;
  return jsonb_build_object('token', r.token, 'profile', _pj(r));
end $$;

create or replace function app_me(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  return _pj(r);
end $$;

create or replace function app_set_avatar(p_token uuid, p_color text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  if p_color is null or p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Warna tidak valid.';
  end if;
  update profiles set avatar_color = p_color where id = r.id returning * into r;
  return _pj(r);
end $$;

-- ---------- Peserta: sesi ----------
create or replace function app_sessions(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; v jsonb;
begin
  r := _me(p_token);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v
  from (
    select s.id, s.title, cardinality(s.question_ids) as total, s.timer_minutes,
           s.feedback_mode, s.status, s.created_at,
           (a.id is not null) as started,
           (a.submitted_at is not null) as done,
           a.score,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished
    from sessions s
    left join attempts a on a.session_id = s.id and a.profile_id = r.id
  ) x;
  return v;
end $$;

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
           'id', q.id, 'no', u.ord, 'bank', b.name,
           'stem', q.stem, 'image', q.image, 'options', q.options
         ) order by u.ord), '[]'::jsonb) into v_q
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id;

  return jsonb_build_object(
    'submitted', false,
    'session', jsonb_build_object('id', s.id, 'title', s.title, 'timer_minutes', s.timer_minutes,
                                  'feedback_mode', s.feedback_mode, 'total', cardinality(s.question_ids)),
    'questions', v_q,
    'answers', a.answers,
    'flags', a.flags,
    'elapsed', extract(epoch from (now() - a.started_at))::int
  );
end $$;

create or replace function app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _me(p_token);
  if jsonb_typeof(p_answers) <> 'object' or jsonb_typeof(p_flags) <> 'object' then
    raise exception 'Data tidak valid.';
  end if;
  update attempts set answers = p_answers, flags = p_flags
  where session_id = p_session and profile_id = r.id and submitted_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Kunci hanya dibuka sesuai mode: per nomor / per 10 / per 20 / di akhir
create or replace function app_reveal(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb;
        qid uuid; idx int; n int; blk_start int; blk_end int; i int; ok boolean; k text; total int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  total := cardinality(s.question_ids);

  foreach qid in array coalesce(p_qids, '{}'::uuid[]) loop
    idx := array_position(s.question_ids, qid);
    continue when idx is null;
    ok := false;
    if a.submitted_at is not null then
      ok := true;
    elsif s.feedback_mode = 'each' then
      ok := a.answers ? qid::text;
    elsif s.feedback_mode in ('10','20') then
      n := s.feedback_mode::int;
      blk_start := ((idx - 1) / n) * n + 1;
      blk_end := least(blk_start + n - 1, total);
      ok := true;
      for i in blk_start..blk_end loop
        if not (a.answers ? (s.question_ids[i])::text) then ok := false; exit; end if;
      end loop;
    end if;
    if ok then
      select answer into k from question_keys where question_id = qid;
      if k is not null then res := res || jsonb_build_object(qid::text, k); end if;
    end if;
  end loop;
  return res;
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

  if jsonb_typeof(p_answers) <> 'object' then p_answers := a.answers; end if;
  if jsonb_typeof(p_flags) <> 'object' then p_flags := a.flags; end if;

  select count(*) into v_score
  from unnest(s.question_ids) as u(qid)
  join question_keys k on k.question_id = u.qid
  where p_answers ->> (u.qid::text) = k.answer;

  v_time := extract(epoch from (now() - a.started_at))::int;
  if s.timer_minutes is not null and v_time > s.timer_minutes * 60 then
    v_time := s.timer_minutes * 60;
  end if;

  update attempts
     set answers = p_answers, flags = p_flags, submitted_at = now(), score = v_score, time_taken = v_time
   where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function app_result(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_rows jsonb; v_banks jsonb; v_rank int; v_n int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found or a.submitted_at is null then raise exception 'Hasil belum tersedia. Kumpulkan dulu sesinya.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'id', q.id, 'bank', b.name,
           'mine', coalesce(a.answers ->> (q.id::text), '-'),
           'key', k.answer,
           'ok', (a.answers ->> (q.id::text)) = k.answer,
           'flag', coalesce((a.flags ->> (q.id::text))::boolean, false)
         ) order by u.ord), '[]'::jsonb) into v_rows
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id;

  select coalesce(jsonb_agg(jsonb_build_object('bank', t.bank, 'correct', t.correct, 'total', t.total) order by t.bank), '[]'::jsonb)
    into v_banks
  from (
    select b.name as bank,
           count(*) filter (where (a.answers ->> (q.id::text)) = k.answer) as correct,
           count(*) as total
    from unnest(s.question_ids) as u(qid)
    join questions q on q.id = u.qid
    join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    group by b.name
  ) t;

  select 1 + count(*) into v_rank from attempts t
   where t.session_id = s.id and t.submitted_at is not null
     and (t.score > a.score or (t.score = a.score and t.time_taken < a.time_taken));
  select count(*) into v_n from attempts t where t.session_id = s.id and t.submitted_at is not null;

  return jsonb_build_object(
    'title', s.title, 'score', a.score, 'total', cardinality(s.question_ids),
    'time_taken', a.time_taken, 'rank', v_rank, 'participants', v_n,
    'rows', v_rows, 'banks', v_banks
  );
end $$;

-- p_session null = akumulasi semua sesi
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
      where a.session_id = p_session and a.submitted_at is not null
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
      where a.submitted_at is not null
      group by p.id, p.name, p.avatar_color
    ) x;
  end if;
  return v;
end $$;

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
    select b.name as bank,
           count(*) filter (where (a.answers ->> (q.id::text)) = k.answer) as correct,
           count(*) as total
    from attempts a
    join sessions s on s.id = a.session_id
    cross join lateral unnest(s.question_ids) as u(qid)
    join questions q on q.id = u.qid
    join banks b on b.id = q.bank_id
    left join question_keys k on k.question_id = q.id
    where a.profile_id = r.id and a.submitted_at is not null
    group by b.name
  ) t;

  return jsonb_build_object('history', v_hist, 'banks', v_banks);
end $$;

-- ---------- Admin ----------
create or replace function adm_banks(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name,
           'active', (select count(*) from questions q where q.bank_id = b.id and q.active),
           'total',  (select count(*) from questions q where q.bank_id = b.id)
         ) order by b.name), '[]'::jsonb) into v
  from banks b;
  return v;
end $$;

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
      insert into questions (bank_id, num, stem, image, options)
      values (v_bank, nullif(it ->> 'num', '')::int, v_stem, nullif(it ->> 'image', ''), v_opts)
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
           'answer', k.answer, 'active', q.active, 'has_image', q.image is not null)
           order by q.num nulls last, q.created_at), '[]'::jsonb) into v
  from questions q left join question_keys k on k.question_id = q.id
  where q.bank_id = p_bank;
  return v;
end $$;

create or replace function adm_toggle_question(p_token uuid, p_qid uuid, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  update questions set active = p_active where id = p_qid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_create_session(p_token uuid, p_title text, p_bank_ids uuid[], p_count int,
                                              p_timer int, p_feedback text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; v_ids uuid[]; v_pool int; v_title text := btrim(coalesce(p_title, ''));
begin
  r := _admin(p_token);
  if v_title = '' then raise exception 'Nama sesi kosong.'; end if;
  if p_count is null or p_count < 1 or p_count > 500 then raise exception 'Jumlah soal harus 1 sampai 500.'; end if;
  if p_feedback not in ('each','10','20','end') then raise exception 'Mode tampil kunci tidak valid.'; end if;
  if p_timer is not null and (p_timer < 1 or p_timer > 600) then raise exception 'Timer harus 1 sampai 600 menit.'; end if;
  if p_bank_ids is null or cardinality(p_bank_ids) = 0 then raise exception 'Pilih minimal satu file/bidang.'; end if;

  select count(*) into v_pool from questions q
   join question_keys k on k.question_id = q.id
   where q.active and q.bank_id = any(p_bank_ids);
  if v_pool < p_count then
    raise exception 'Soal yang tersedia hanya % (diminta %).', v_pool, p_count;
  end if;

  select array_agg(x.id) into v_ids from (
    select q.id from questions q
    join question_keys k on k.question_id = q.id
    where q.active and q.bank_id = any(p_bank_ids)
    order by random() limit p_count
  ) x;

  insert into sessions (title, question_ids, timer_minutes, feedback_mode, created_by)
  values (v_title, v_ids, p_timer, p_feedback, r.id);
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
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is null) as ongoing
    from sessions s
  ) x;
  return v;
end $$;

create or replace function adm_set_session_status(p_token uuid, p_session uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  if p_status not in ('open','closed') then raise exception 'Status tidak valid.'; end if;
  update sessions set status = p_status where id = p_session;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_delete_session(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  delete from sessions where id = p_session;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_people(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
           'avatar_color', p.avatar_color, 'created_at', p.created_at,
           'done', (select count(*) from attempts a where a.profile_id = p.id and a.submitted_at is not null)
         ) order by p.created_at), '[]'::jsonb) into v
  from profiles p;
  return v;
end $$;

create or replace function adm_reset_pin(p_token uuid, p_profile uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN harus 4 sampai 6 angka.'; end if;
  update profiles set pin_hash = crypt(p_pin, gen_salt('bf')) where id = p_profile;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_set_role(p_token uuid, p_profile uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare n_admin int;
begin
  perform _admin(p_token);
  if p_role not in ('peserta','admin') then raise exception 'Peran tidak valid.'; end if;
  if p_role = 'peserta' then
    select count(*) into n_admin from profiles where role = 'admin' and id <> p_profile;
    if n_admin = 0 then raise exception 'Harus ada minimal satu admin.'; end if;
  end if;
  update profiles set role = p_role where id = p_profile;
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
