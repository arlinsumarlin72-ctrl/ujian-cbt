-- ============================================================
-- Patch 2026-11-23d: bantuan diskusi
--   - timer diskusi dengan target durasi (hitung mundur di layar semua peserta)
--   - sorotan admin (layar peserta ikut ke soal yang dibahas) + tunjuk penjelas acak
--   - urutan bahas untuk peserta (persentase benar, sebaran jawaban, "mau dibahas")
--   - pembahasan kelompok (ditulis admin, tampil ke peserta setelah kunci terbuka & di Tinjau)
-- Bersifat tambahan. Aman dijalankan ulang. Dijalankan SETELAH patch-2026-11-23c-timer-per-bagian.sql.
-- ============================================================
begin;

alter table sessions add column if not exists spotlight jsonb;   -- {"no": 17, "seq": 3, "explainer": "Nama"|null}

create table if not exists hand_votes (
  session_id  uuid not null references sessions(id) on delete cascade,
  profile_id  uuid not null references profiles(id) on delete cascade,
  question_id uuid not null references questions(id) on delete cascade,
  primary key (session_id, profile_id, question_id)
);
create table if not exists explanations (
  question_id uuid primary key references questions(id) on delete cascade,
  body        text not null,
  updated_by  uuid references profiles(id) on delete set null,
  updated_at  timestamptz not null default now()
);
alter table hand_votes   enable row level security;
alter table explanations enable row level security;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table hand_votes from anon'; execute 'revoke all on table explanations from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table hand_votes from authenticated'; execute 'revoke all on table explanations from authenticated';
  end if;
end $$;

-- diskusi yang sedang berjalan (entri log yang belum selesai)
create or replace function _dopen(s sessions) returns jsonb
language sql stable as $$
  select d from jsonb_array_elements(s.discuss_log) d where d ->> 'e' is null limit 1
$$;
revoke execute on function _dopen(sessions) from public, anon, authenticated;

-- ---------- Admin: kendali diskusi + sorotan ----------
drop function if exists adm_flow(uuid, uuid, text, boolean);

-- start (p_secs = target durasi detik, opsional) | end (p_unlock) | unlock | spot (p_no, p_pick) | unspot
create or replace function adm_flow(p_token uuid, p_session uuid, p_action text, p_unlock boolean default false,
                                    p_secs int default null, p_no int default null, p_pick boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; n int; total int; v_name text; v_seq int; v_expl text;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session for update;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s); total := cardinality(s.question_ids);
  if p_action not in ('start', 'end', 'unlock', 'spot', 'unspot') then raise exception 'Aksi tidak dikenal.'; end if;

  if p_action = 'start' then
    if not _discussing(s) then
      update sessions set discuss_log = s.discuss_log || jsonb_build_array(
               jsonb_build_object('s', now(), 'e', null, 'p', case when p_secs is not null and p_secs between 60 and 7200 then p_secs end)),
             spotlight = null
       where id = s.id;
    end if;
  elsif p_action = 'end' then
    if _discussing(s) then
      update sessions
         set discuss_log = (select coalesce(jsonb_agg(case when d ->> 'e' is null then jsonb_set(d, '{e}', to_jsonb(now())) else d end order by ord), '[]'::jsonb)
                              from jsonb_array_elements(s.discuss_log) with ordinality as t(d, ord)),
             spotlight = null
       where id = s.id;
    end if;
  elsif p_action = 'spot' then
    if p_no is null or p_no < 1 or p_no > total then raise exception 'Nomor soal tidak valid.'; end if;
    v_seq := coalesce((s.spotlight ->> 'seq')::int, 0) + 1;
    if p_pick then
      -- pilih acak satu peserta yang menjawab soal ini dengan benar (dan sudah menyelesaikannya)
      select p.name into v_name
        from attempts t join profiles p on p.id = t.profile_id
        join question_keys k on k.question_id = s.question_ids[p_no]
       where t.session_id = s.id and t.answers ->> (s.question_ids[p_no]::text) = k.answer
         and (t.submitted_at is not null or s.feedback_mode = 'each' or (s.feedback_mode ~ '^[0-9]' and t.locked_n >= p_no))
       order by random() limit 1;
    end if;
    update sessions set spotlight = jsonb_build_object('no', p_no, 'seq', v_seq, 'explainer', v_name) where id = s.id;
    return jsonb_build_object('ok', true, 'explainer', v_name);
  elsif p_action = 'unspot' then
    update sessions set spotlight = null where id = s.id;
  end if;
  if (p_action = 'unlock' or (p_action = 'end' and p_unlock)) and s.lock_mode = 'locked' and n is not null then
    update sessions set unlocked_n = least(total, s.unlocked_n + n) where id = s.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function adm_flow_state(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s sessions; v_since int; n int; v_open jsonb;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s);
  v_open := _dopen(s);
  if v_open is not null then v_since := extract(epoch from (now() - (v_open ->> 's')::timestamptz))::int; end if;
  return jsonb_build_object(
    'total', cardinality(s.question_ids), 'block', n, 'lock_mode', s.lock_mode, 'unlocked_n', s.unlocked_n,
    'ketat', s.ketat, 'status', s.status, 'discussing', _discussing(s), 'since', v_since, 'plan', (v_open ->> 'p')::int,
    'spot', s.spotlight,
    'disc_secs', floor(_paused_secs(s.discuss_log, s.created_at, now()))::int,
    'disc_count', jsonb_array_length(s.discuss_log),
    'max_fin', case when n is null then 0 else coalesce((select max(case when t.submitted_at is not null then cardinality(s.question_ids) else t.locked_n end) / n
                                                           from attempts t where t.session_id = s.id), 0) end);
end $$;

-- ---------- Peserta: mulai & sinkron (tambah sorotan dan target diskusi) ----------
create or replace function app_start(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_q jsonb; v_open int; v_d jsonb;
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
  v_d := _dopen(s);
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
    'spot', s.spotlight,
    'dplan', (v_d ->> 'p')::int,
    'dsince', case when v_d is not null then extract(epoch from (now() - (v_d ->> 's')::timestamptz))::int end,
    'elapsed', _elapsed(s, a)
  ) || _blk_info(s, a);
end $$;

create or replace function app_rev(p_token uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_has boolean; v_d jsonb;
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
  v_d := _dopen(s);
  return jsonb_build_object('rev', s.rev, 'notice', s.notice,
    'submitted', coalesce(v_has and a.submitted_at is not null, false),
    'discussing', _discussing(s), 'unlocked_n', s.unlocked_n, 'lock_mode', s.lock_mode,
    'paused', v_has and _is_paused(a),
    'locked', case when v_has then a.locked_n end,
    'bp', case when v_has then _blk_peers(s, a) end,
    'spot', s.spotlight,
    'dplan', (v_d ->> 'p')::int,
    'dsince', case when v_d is not null then extract(epoch from (now() - (v_d ->> 's')::timestamptz))::int end,
    'elapsed', case when v_has and a.submitted_at is null then _elapsed(s, a) end)
    || case when v_has and a.submitted_at is null then _blk_info(s, a) else '{}'::jsonb end;
end $$;

-- ---------- Peserta: persentase teman + pembahasan kelompok ----------
create or replace function app_peers(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb; qid uuid; idx int; ok boolean; v jsonb; k text; v_e text;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
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
    select body into v_e from explanations where question_id = qid;
    if s.owner is null then
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
    else
      v := '{}'::jsonb;
    end if;
    res := res || jsonb_build_object(qid::text, v || jsonb_build_object('e', v_e));
  end loop;
  return res;
end $$;

-- ---------- Peserta: urutan bahas untuk satu bagian ----------
-- Hanya soal yang kuncinya sudah terbuka bagi pemanggil. Pada mode "satu per satu", sebaran jawaban hanya untuk kunci yang sudah dibuka.
create or replace function app_block_recap(p_token uuid, p_session uuid, p_block int default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; n int; total int; fin int; a0 int; b0 int; b1 int; v jsonb; v_final int; v_all int; v_step boolean;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and owner is null;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  n := _bsize(s);
  if n is null then raise exception 'Sesi ini tidak memakai bagian.'; end if;
  total := cardinality(s.question_ids);
  fin := case when a.submitted_at is not null then total else a.locked_n end;
  v_step := s.feedback_mode ~ 's$';
  if fin = 0 then return jsonb_build_object('block', null, 'qs', '[]'::jsonb, 'blocks', 0); end if;
  if p_block is null then p_block := (fin + n - 1) / n; end if;
  a0 := (p_block - 1) * n + 1; b0 := least(p_block * n, total);
  if a0 > fin then return jsonb_build_object('block', p_block, 'qs', '[]'::jsonb, 'blocks', (fin + n - 1) / n); end if;
  b1 := least(b0, fin);

  select count(*) filter (where t.submitted_at is not null or t.locked_n >= b0), count(*) into v_final, v_all
    from attempts t where t.session_id = s.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'sy', coalesce(b.system, b.name), 'ty', coalesce(q.qtype, 'Lainnya'),
           'mine', a.answers ->> (q.id::text),
           'show', rv.shw,
           'key', case when rv.shw then k.answer end,
           'n', case when rv.shw then st.n end, 'ok', case when rv.shw then st.ok end, 'd', case when rv.shw then st.d end,
           'hands', (select count(*) from hand_votes h where h.session_id = s.id and h.question_id = q.id),
           'my_hand', exists (select 1 from hand_votes h where h.session_id = s.id and h.question_id = q.id and h.profile_id = r.id),
           'expl', case when rv.shw then (select e.body from explanations e where e.question_id = q.id) end
         ) order by u.ord), '[]'::jsonb) into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id
  cross join lateral (select (not v_step) or a.submitted_at is not null or q.id = any(a.revealed) as shw) rv
  cross join lateral (
    select count(*)::int as n,
           (count(*) filter (where t.answers ->> (q.id::text) = k.answer))::int as ok,
           jsonb_build_object('A', count(*) filter (where t.answers ->> (q.id::text) = 'A'), 'B', count(*) filter (where t.answers ->> (q.id::text) = 'B'),
                              'C', count(*) filter (where t.answers ->> (q.id::text) = 'C'), 'D', count(*) filter (where t.answers ->> (q.id::text) = 'D'),
                              'E', count(*) filter (where t.answers ->> (q.id::text) = 'E')) as d
    from attempts t
    where t.session_id = s.id and (t.submitted_at is not null or t.locked_n >= b0)
  ) st
  where u.ord between a0 and b1;

  return jsonb_build_object('block', p_block, 'from', a0, 'to', b0, 'final', v_final, 'all', v_all,
                            'blocks', (fin + n - 1) / n, 'qs', v);
end $$;

create or replace function app_hand(p_token uuid, p_session uuid, p_qid uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; idx int; fin int; v_n int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and owner is null;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  idx := array_position(s.question_ids, p_qid);
  if idx is null then raise exception 'Soal tidak ada di sesi ini.'; end if;
  fin := case when a.submitted_at is not null then cardinality(s.question_ids)
              when s.feedback_mode = 'each' and a.answers ? p_qid::text then idx
              when s.feedback_mode ~ '^[0-9]' then a.locked_n else 0 end;
  if idx > fin then raise exception 'Selesaikan soal ini dulu sebelum meminta dibahas.'; end if;
  if p_on then
    insert into hand_votes (session_id, profile_id, question_id) values (s.id, r.id, p_qid) on conflict do nothing;
  else
    delete from hand_votes where session_id = s.id and profile_id = r.id and question_id = p_qid;
  end if;
  select count(*) into v_n from hand_votes where session_id = s.id and question_id = p_qid;
  return jsonb_build_object('ok', true, 'hands', v_n);
end $$;

-- ---------- Admin: pembahasan kelompok + rekap lengkap ----------
create or replace function adm_set_expl(p_token uuid, p_qid uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles;
begin
  r := _admin(p_token);
  p_body := left(btrim(coalesce(p_body, '')), 3000);
  if not exists (select 1 from questions where id = p_qid) then raise exception 'Soal tidak ditemukan.'; end if;
  if p_body = '' then
    delete from explanations where question_id = p_qid;
  else
    insert into explanations (question_id, body, updated_by) values (p_qid, p_body, r.id)
    on conflict (question_id) do update set body = excluded.body, updated_by = excluded.updated_by, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

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
           'no', u.ord, 'id', q.id, 'sy', coalesce(b.system, b.name), 'ty', coalesce(q.qtype, 'Lainnya'),
           'stem', left(q.stem, 200), 'key', k.answer,
           'n', st.n, 'ok', st.ok, 'd', st.d, 'ok_names', st.ok_names,
           'hands', (select count(*) from hand_votes h where h.session_id = s.id and h.question_id = q.id),
           'expl', (select e.body from explanations e where e.question_id = q.id)) order by u.ord), '[]'::jsonb) into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id
  cross join lateral (
    select count(*)::int as n,
           (count(*) filter (where t.answers ->> (q.id::text) = k.answer))::int as ok,
           jsonb_build_object('A', count(*) filter (where t.answers ->> (q.id::text) = 'A'), 'B', count(*) filter (where t.answers ->> (q.id::text) = 'B'),
                              'C', count(*) filter (where t.answers ->> (q.id::text) = 'C'), 'D', count(*) filter (where t.answers ->> (q.id::text) = 'D'),
                              'E', count(*) filter (where t.answers ->> (q.id::text) = 'E')) as d,
           coalesce(jsonb_agg(p.name order by p.name) filter (where t.answers ->> (q.id::text) = k.answer), '[]'::jsonb) as ok_names
    from attempts t join profiles p on p.id = t.profile_id
    where t.session_id = s.id and (t.submitted_at is not null or t.locked_n >= b0)
  ) st
  where u.ord between a0 and b0;

  return jsonb_build_object('block', p_block, 'from', a0, 'to', b0, 'final', v_final, 'waiting', v_wait, 'qs', v);
end $$;

-- Tinjau soal: sertakan pembahasan kelompok
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
      'flag', coalesce((a.flags ->> (q.id::text))::boolean, false),
      'expl', (select e.body from explanations e where e.question_id = q.id)) order by u.ord), '[]'::jsonb)
  into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id;
  return jsonb_build_object('title', s.title, 'questions', v, 'block', _bsize(s));
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
