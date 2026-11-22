-- ============================================================
-- Patch 2026-11-24:
--   * Pembahasan kelompok: satu teks bersama yang bisa diedit semua peserta (kunci soal sudah terbuka),
--     bisa memuat gambar (tempel gambar), dengan pengecekan versi supaya tidak saling menimpa.
--   * Suara ulang (pemungutan suara ulang) pada soal yang disorot, hasil membandingkan jawaban awal vs sesudah diskusi.
--   * Penjelas dihapus (Sorot saja). Daftar nama yang menjawab benar dibuang dari rekap admin.
--   * Admin yang ikut mengerjakan: rekap bagian hanya untuk bagian yang sudah ia selesaikan.
--   * Mode ketat: id klien (satu tab/perangkat aktif), deteksi senyap & muat ulang di server, durasi pelanggaran tak bisa diperkecil.
-- Bersifat tambahan. Aman dijalankan ulang. Dijalankan SETELAH patch-2026-11-23d-bantuan-diskusi.sql.
-- ============================================================
begin;

alter table explanations add column if not exists images jsonb not null default '[]'::jsonb;  -- gambar (data URL jpeg), maks 4
alter table sessions     add column if not exists revote jsonb;                              -- {"no":17,"open":true,"seq":2}
alter table attempts     add column if not exists client_id text;                            -- id tab/perangkat yang sedang aktif

create table if not exists revotes (
  session_id  uuid not null references sessions(id)  on delete cascade,
  question_id uuid not null references questions(id) on delete cascade,
  profile_id  uuid not null references profiles(id)  on delete cascade,
  answer      text not null check (answer in ('A','B','C','D','E')),
  at          timestamptz not null default now(),
  primary key (session_id, question_id, profile_id)
);
alter table revotes enable row level security;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on table revotes from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on table revotes from authenticated'; end if;
end $$;

-- ---------- Fungsi bantu ----------
-- apakah kunci soal ini sudah terbuka bagi peserta (aturan sama dengan persentase teman)
create or replace function _key_open(p_session uuid, p_profile uuid, p_qid uuid) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare s sessions; a attempts; idx int;
begin
  select * into s from sessions where id = p_session;
  if not found then return false; end if;
  select * into a from attempts where session_id = s.id and profile_id = p_profile;
  if not found then return false; end if;
  idx := array_position(s.question_ids, p_qid);
  if idx is null then return false; end if;
  return a.submitted_at is not null
      or (s.feedback_mode = 'each' and a.answers ? p_qid::text)
      or (s.feedback_mode ~ '^[0-9]' and idx <= a.locked_n);
end $$;

create or replace function _viol_add(p_attempt uuid, p_kind text, p_secs int) returns void
language sql security definer set search_path = public, extensions as $$
  update attempts
     set violations = violations || jsonb_build_array(jsonb_build_object('t', now(), 'k', left(p_kind, 20), 'd', least(greatest(coalesce(p_secs, 0), 0), 86400)))
   where id = p_attempt and jsonb_array_length(violations) < 300
$$;

-- mode ketat: catat di SERVER bila peserta "senyap" (tidak ada detak) atau memuat ulang halaman, walau klien tidak melapor
create or replace function _strict_gap(p_session uuid, p_profile uuid, p_kind text, p_min int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; a attempts; gap numeric;
begin
  select * into s from sessions where id = p_session;
  if not found or not s.ketat then return; end if;
  select * into a from attempts where session_id = p_session and profile_id = p_profile;
  if not found or a.submitted_at is not null or a.last_seen is null then return; end if;
  if _discussing(s) or _is_paused(a) then return; end if;
  gap := extract(epoch from (now() - a.last_seen));
  if gap <= p_min then return; end if;
  if _paused_secs(s.discuss_log, a.last_seen, now()) > 0 then return; end if;       -- ada diskusi selama jeda detak
  -- sudah dilaporkan klien sejak detak terakhir? jangan dihitung dua kali
  if exists (select 1 from jsonb_array_elements(a.violations) v where (v ->> 't')::timestamptz >= a.last_seen - interval '10 seconds') then return; end if;
  perform _viol_add(a.id, p_kind, floor(gap)::int);
end $$;

create or replace function _client_check(a attempts, p_client text) returns void
language plpgsql stable as $$
begin
  if p_client is not null and a.client_id is not null and a.client_id <> p_client then
    raise exception 'Akun ini sedang dipakai di tab atau perangkat lain. Muat ulang halaman untuk mengambil alih.' using errcode = 'P0409';
  end if;
end $$;

revoke execute on function _key_open(uuid, uuid, uuid)          from public, anon, authenticated;
revoke execute on function _viol_add(uuid, text, int)            from public, anon, authenticated;
revoke execute on function _strict_gap(uuid, uuid, text, int)    from public, anon, authenticated;
revoke execute on function _client_check(attempts, text)         from public, anon, authenticated;

-- ---------- Suara ulang: ringkasan untuk layar ----------
create or replace function _revote_info(s sessions, p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare rv jsonb := s.revote; qn int; qid uuid; v_key text; v_open boolean; v_elig int; v_voted int; v_mine text; v_res jsonb;
begin
  if rv is null then return null; end if;
  qn := (rv ->> 'no')::int; qid := s.question_ids[qn]; v_open := coalesce((rv ->> 'open')::boolean, false);
  select count(*) into v_elig from attempts t
   where t.session_id = s.id
     and (t.submitted_at is not null or (s.feedback_mode = 'each' and t.answers ? qid::text) or (s.feedback_mode ~ '^[0-9]' and qn <= t.locked_n));
  select count(*) into v_voted from revotes where session_id = s.id and question_id = qid;
  select answer into v_mine from revotes where session_id = s.id and question_id = qid and profile_id = p_profile;
  if not v_open then
    select answer into v_key from question_keys where question_id = qid;
    select jsonb_build_object('n', count(*), 'key', v_key,
             'init', jsonb_build_object('A', count(*) filter (where t.answers ->> qid::text = 'A'), 'B', count(*) filter (where t.answers ->> qid::text = 'B'),
                                        'C', count(*) filter (where t.answers ->> qid::text = 'C'), 'D', count(*) filter (where t.answers ->> qid::text = 'D'),
                                        'E', count(*) filter (where t.answers ->> qid::text = 'E')),
             'vote', jsonb_build_object('A', count(*) filter (where v.answer = 'A'), 'B', count(*) filter (where v.answer = 'B'),
                                        'C', count(*) filter (where v.answer = 'C'), 'D', count(*) filter (where v.answer = 'D'),
                                        'E', count(*) filter (where v.answer = 'E')),
             'to_ok',   count(*) filter (where t.answers ->> qid::text is distinct from v_key and v.answer = v_key),
             'to_bad',  count(*) filter (where t.answers ->> qid::text = v_key and v.answer <> v_key),
             'same_ok', count(*) filter (where t.answers ->> qid::text = v_key and v.answer = v_key),
             'same_bad',count(*) filter (where t.answers ->> qid::text is distinct from v_key and v.answer <> v_key)) into v_res
      from revotes v join attempts t on t.session_id = v.session_id and t.profile_id = v.profile_id
     where v.session_id = s.id and v.question_id = qid;
  end if;
  return jsonb_build_object('no', qn, 'open', v_open, 'seq', (rv ->> 'seq')::int, 'eligible', v_elig, 'voted', v_voted, 'mine', v_mine, 'res', v_res);
end $$;
revoke execute on function _revote_info(sessions, uuid) from public, anon, authenticated;

-- ---------- Peserta: pembahasan bersama ----------
create or replace function app_expl_get(p_token uuid, p_session uuid, p_qid uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; e explanations; v_by text;
begin
  r := _me(p_token);
  if not exists (select 1 from sessions where id = p_session and (owner is null or owner = r.id)) then raise exception 'Sesi tidak ditemukan.'; end if;
  if r.role <> 'admin' and not _key_open(p_session, r.id, p_qid) then raise exception 'Kunci soal ini belum terbuka.'; end if;
  select * into e from explanations where question_id = p_qid;
  if not found then return jsonb_build_object('body', null, 'images', '[]'::jsonb, 'v', null, 'by', null); end if;
  select name into v_by from profiles where id = e.updated_by;
  return jsonb_build_object('body', e.body, 'images', e.images, 'v', e.updated_at::text, 'by', v_by, 'at', e.updated_at);
end $$;

-- semua gambar pembahasan untuk soal yang kuncinya sudah terbuka (dipakai halaman Tinjau)
create or replace function app_expl_images(p_token uuid, p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; v jsonb;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then return '{}'::jsonb; end if;
  select coalesce(jsonb_object_agg(e.question_id::text, e.images), '{}'::jsonb) into v
    from explanations e
   where jsonb_array_length(e.images) > 0 and e.question_id = any(s.question_ids)
     and (r.role = 'admin' or _key_open(s.id, r.id, e.question_id));
  return v;
end $$;

-- p_version = versi (updated_at) yang terakhir dilihat penyunting; bila sudah berubah, ditolak (P0409)
create or replace function app_expl_set(p_token uuid, p_session uuid, p_qid uuid, p_body text,
                                        p_images jsonb default '[]'::jsonb, p_version text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; e explanations; v_by text; i int; v_new timestamptz;
begin
  r := _me(p_token);
  if not exists (select 1 from sessions where id = p_session and (owner is null or owner = r.id) and p_qid = any(question_ids)) then
    raise exception 'Soal tidak ditemukan.';
  end if;
  if r.role <> 'admin' and not _key_open(p_session, r.id, p_qid) then
    raise exception 'Buka kunci soal ini dulu sebelum menulis pembahasan.';
  end if;
  p_body := left(btrim(coalesce(p_body, '')), 3000);
  if p_images is null or jsonb_typeof(p_images) <> 'array' then p_images := '[]'::jsonb; end if;
  if jsonb_array_length(p_images) > 4 then raise exception 'Maksimal 4 gambar per pembahasan.'; end if;
  for i in 0 .. jsonb_array_length(p_images) - 1 loop
    if jsonb_typeof(p_images -> i) <> 'string' or (p_images ->> i) !~ '^data:image/(jpeg|png|webp);base64,' or length(p_images ->> i) > 500000 then
      raise exception 'Gambar tidak valid atau terlalu besar.';
    end if;
  end loop;
  select * into e from explanations where question_id = p_qid for update;
  if found then
    if p_version is distinct from e.updated_at::text then
      select name into v_by from profiles where id = e.updated_by;
      raise exception 'Pembahasan sudah diubah oleh % sejak kamu membukanya.', coalesce(v_by, 'orang lain') using errcode = 'P0410';
    end if;
  elsif p_version is not null then
    raise exception 'Pembahasan sudah dihapus oleh orang lain.' using errcode = 'P0410';
  end if;
  if p_body = '' and jsonb_array_length(p_images) = 0 then
    if r.role <> 'admin' then raise exception 'Hanya admin yang boleh mengosongkan pembahasan.'; end if;
    delete from explanations where question_id = p_qid;
    return jsonb_build_object('ok', true, 'deleted', true);
  end if;
  insert into explanations (question_id, body, images, updated_by) values (p_qid, p_body, p_images, r.id)
  on conflict (question_id) do update set body = excluded.body, images = excluded.images, updated_by = excluded.updated_by, updated_at = now()
  returning updated_at into v_new;
  return jsonb_build_object('ok', true, 'v', v_new::text, 'by', r.name);
end $$;

-- persentase teman + info pembahasan (teks, versi, penulis, jumlah gambar)
create or replace function app_peers(p_token uuid, p_session uuid, p_qids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; res jsonb := '{}'::jsonb; qid uuid; idx int; ok boolean; v jsonb; k text;
        v_e text; v_ev text; v_eb text; v_ei int;
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
    v_e := null; v_ev := null; v_eb := null; v_ei := 0;
    select e.body, e.updated_at::text, p.name, jsonb_array_length(e.images) into v_e, v_ev, v_eb, v_ei
      from explanations e left join profiles p on p.id = e.updated_by where e.question_id = qid;
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
    res := res || jsonb_build_object(qid::text, v || jsonb_build_object('e', v_e, 'ev', v_ev, 'eb', v_eb, 'ei', coalesce(v_ei, 0)));
  end loop;
  return res;
end $$;

-- Tinjau soal: pembahasan bersama (teks + info versi/penulis + jumlah gambar)
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
      'expl', e.body, 'expl_v', e.updated_at::text, 'expl_by', ep.name, 'expl_n', coalesce(jsonb_array_length(e.images), 0)) order by u.ord), '[]'::jsonb)
  into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id
  left join explanations e on e.question_id = q.id
  left join profiles ep on ep.id = e.updated_by;
  return jsonb_build_object('title', s.title, 'questions', v, 'block', _bsize(s));
end $$;

-- ---------- Peserta: suara ulang ----------
create or replace function app_revote(p_token uuid, p_session uuid, p_answer text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; qn int; qid uuid;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and owner is null;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if s.revote is null or not coalesce((s.revote ->> 'open')::boolean, false) then raise exception 'Suara ulang belum dibuka atau sudah ditutup.'; end if;
  p_answer := upper(coalesce(p_answer, ''));
  if p_answer !~ '^[A-E]$' then raise exception 'Pilihan tidak valid.'; end if;
  qn := (s.revote ->> 'no')::int; qid := s.question_ids[qn];
  if not _key_open(s.id, r.id, qid) then raise exception 'Selesaikan bagian soal ini dulu untuk ikut suara ulang.'; end if;
  insert into revotes (session_id, question_id, profile_id, answer) values (s.id, qid, r.id, p_answer)
  on conflict (session_id, question_id, profile_id) do update set answer = excluded.answer, at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Admin: kendali (Sorot, suara ulang) ----------
-- p_pick dipertahankan hanya agar klien lama tidak error; diabaikan (fitur Penjelas dihapus)
create or replace function adm_flow(p_token uuid, p_session uuid, p_action text, p_unlock boolean default false,
                                    p_secs int default null, p_no int default null, p_pick boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions; n int; total int; v_seq int; v_rseq int;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session for update;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s); total := cardinality(s.question_ids);
  if p_action not in ('start', 'end', 'unlock', 'spot', 'unspot', 'revote_open', 'revote_close') then raise exception 'Aksi tidak dikenal.'; end if;

  if p_action = 'start' then
    if not _discussing(s) then
      update sessions set discuss_log = s.discuss_log || jsonb_build_array(
               jsonb_build_object('s', now(), 'e', null, 'p', case when p_secs is not null and p_secs between 60 and 7200 then p_secs end)),
             spotlight = null, revote = null
       where id = s.id;
    end if;
  elsif p_action = 'end' then
    if _discussing(s) then
      update sessions
         set discuss_log = (select coalesce(jsonb_agg(case when d ->> 'e' is null then jsonb_set(d, '{e}', to_jsonb(now())) else d end order by ord), '[]'::jsonb)
                              from jsonb_array_elements(s.discuss_log) with ordinality as t(d, ord)),
             spotlight = null, revote = null
       where id = s.id;
    end if;
  elsif p_action in ('spot', 'revote_open') then
    if p_no is null or p_no < 1 or p_no > total then raise exception 'Nomor soal tidak valid.'; end if;
    v_seq := coalesce((s.spotlight ->> 'seq')::int, 0) + 1;
    update sessions set spotlight = jsonb_build_object('no', p_no, 'seq', v_seq) where id = s.id;
    if p_action = 'revote_open' then
      v_rseq := coalesce((s.revote ->> 'seq')::int, 0) + 1;
      delete from revotes where session_id = s.id and question_id = s.question_ids[p_no];
      update sessions set revote = jsonb_build_object('no', p_no, 'open', true, 'seq', v_rseq) where id = s.id;
    end if;
    return jsonb_build_object('ok', true);
  elsif p_action = 'revote_close' then
    if s.revote is not null then update sessions set revote = jsonb_set(s.revote, '{open}', 'false'::jsonb) where id = s.id; end if;
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
declare s sessions; v_since int; n int; v_open jsonb; r profiles;
begin
  r := _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s);
  v_open := _dopen(s);
  if v_open is not null then v_since := extract(epoch from (now() - (v_open ->> 's')::timestamptz))::int; end if;
  return jsonb_build_object(
    'total', cardinality(s.question_ids), 'block', n, 'lock_mode', s.lock_mode, 'unlocked_n', s.unlocked_n,
    'ketat', s.ketat, 'status', s.status, 'discussing', _discussing(s), 'since', v_since, 'plan', (v_open ->> 'p')::int,
    'spot', s.spotlight, 'revote', _revote_info(s, r.id),
    'disc_secs', floor(_paused_secs(s.discuss_log, s.created_at, now()))::int,
    'disc_count', jsonb_array_length(s.discuss_log),
    'max_fin', case when n is null then 0 else coalesce((select max(case when t.submitted_at is not null then cardinality(s.question_ids) else t.locked_n end) / n
                                                           from attempts t where t.session_id = s.id), 0) end);
end $$;

-- Rekap admin: tanpa daftar nama; admin yang ikut mengerjakan hanya boleh melihat bagian yang sudah ia selesaikan
drop function if exists adm_block_recap(uuid, uuid, int);
create or replace function adm_block_recap(p_token uuid, p_session uuid, p_block int) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r profiles; s sessions; ma attempts; n int; a0 int; b0 int; v jsonb; v_final int; v_wait jsonb;
begin
  r := _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  n := _bsize(s);
  if n is null or p_block is null or p_block < 1 then raise exception 'Sesi ini tidak memakai bagian.'; end if;
  a0 := (p_block - 1) * n + 1; b0 := least(p_block * n, cardinality(s.question_ids));
  if a0 > cardinality(s.question_ids) then raise exception 'Bagian tidak ada.'; end if;
  select * into ma from attempts where session_id = s.id and profile_id = r.id and submitted_at is null;
  if found and ma.locked_n < b0 then
    raise exception 'Kamu ikut mengerjakan sesi ini. Selesaikan bagian % dulu untuk melihat rekapnya.', p_block;
  end if;

  select count(*) into v_final from attempts t where t.session_id = s.id and (t.submitted_at is not null or t.locked_n >= b0);
  select coalesce(jsonb_agg(p.name order by p.name), '[]'::jsonb) into v_wait
    from attempts t join profiles p on p.id = t.profile_id
   where t.session_id = s.id and t.submitted_at is null and t.locked_n < b0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'id', q.id, 'sy', coalesce(b.system, b.name), 'ty', coalesce(q.qtype, 'Lainnya'),
           'stem', left(q.stem, 200), 'key', k.answer,
           'n', st.n, 'ok', st.ok, 'd', st.d,
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
                              'E', count(*) filter (where t.answers ->> (q.id::text) = 'E')) as d
    from attempts t
    where t.session_id = s.id and (t.submitted_at is not null or t.locked_n >= b0)
  ) st
  where u.ord between a0 and b0;

  return jsonb_build_object('block', p_block, 'from', a0, 'to', b0, 'final', v_final, 'waiting', v_wait, 'qs', v);
end $$;

-- ---------- Mode ketat: durasi pelanggaran tidak bisa diperkecil ----------
create or replace function app_violation(p_token uuid, p_session uuid, p_kind text, p_secs int, p_update boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; n int; v_old int;
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
      v_old := coalesce((a.violations -> (n - 1) ->> 'd')::int, 0);
      update attempts set violations = jsonb_set(a.violations, array[(n - 1)::text, 'd'], to_jsonb(greatest(p_secs, v_old))) where id = a.id;
    end if;
  elsif not _discussing(s) and n < 300 then
    perform _viol_add(a.id, p_kind, p_secs);
    n := n + 1;
  end if;
  return jsonb_build_object('ok', true, 'count', n);
end $$;

-- ---------- Peserta: mulai / sinkron / simpan / selesaikan / kumpulkan (dengan id klien) ----------
drop function if exists app_start(uuid, uuid);
drop function if exists app_rev(uuid, uuid);
drop function if exists app_save(uuid, uuid, jsonb, jsonb);
drop function if exists app_finalize(uuid, uuid, jsonb, jsonb, int);
drop function if exists app_submit(uuid, uuid, jsonb, jsonb);

create or replace function app_start(p_token uuid, p_session uuid, p_client text default null) returns jsonb
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

  -- mode ketat: halaman dimuat ulang / dibuka lagi setelah jeda → catat di server
  if p_client is not null and a.client_id is not null and a.client_id <> p_client
     and s.ketat and a.last_seen is not null and a.last_seen > now() - interval '30 seconds' and not _discussing(s) then
    perform _viol_add(a.id, 'perangkat_ganda', 0);
  else
    perform _strict_gap(s.id, r.id, 'muat_ulang', 20);
  end if;
  update attempts set last_seen = now(), client_id = coalesce(p_client, client_id) where id = a.id;

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
    'revote', _revote_info(s, r.id),
    'dplan', (v_d ->> 'p')::int,
    'dsince', case when v_d is not null then extract(epoch from (now() - (v_d ->> 's')::timestamptz))::int end,
    'elapsed', _elapsed(s, a)
  ) || _blk_info(s, a);
end $$;

create or replace function app_rev(p_token uuid, p_session uuid, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; v_has boolean; v_d jsonb;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then return jsonb_build_object('rev', 0, 'notice', null, 'submitted', false); end if;
  select * into a from attempts where session_id = p_session and profile_id = r.id;
  v_has := found;
  if v_has and a.submitted_at is null then
    perform _client_check(a, p_client);
    perform _strict_gap(s.id, r.id, 'senyap', 45);
    update attempts set last_seen = now(), client_id = coalesce(client_id, p_client) where id = a.id;
  end if;
  perform _blk_sync(p_session, r.id);
  select * into a from attempts where session_id = p_session and profile_id = r.id;
  v_has := found;
  v_d := _dopen(s);
  return jsonb_build_object('rev', s.rev, 'notice', s.notice,
    'submitted', coalesce(v_has and a.submitted_at is not null, false),
    'discussing', _discussing(s), 'unlocked_n', s.unlocked_n, 'lock_mode', s.lock_mode,
    'paused', v_has and _is_paused(a),
    'locked', case when v_has then a.locked_n end,
    'bp', case when v_has then _blk_peers(s, a) end,
    'spot', s.spotlight,
    'revote', _revote_info(s, r.id),
    'dplan', (v_d ->> 'p')::int,
    'dsince', case when v_d is not null then extract(epoch from (now() - (v_d ->> 's')::timestamptz))::int end,
    'elapsed', case when v_has and a.submitted_at is null then _elapsed(s, a) end)
    || case when v_has and a.submitted_at is null then _blk_info(s, a) else '{}'::jsonb end;
end $$;

create or replace function app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb, p_client text default null) returns jsonb
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
    perform _client_check(a, p_client);
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

create or replace function app_finalize(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb, p_upto int default null, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r profiles; s sessions; a attempts; n int; total int; nxt int;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session and (owner is null or owner = r.id);
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if s.feedback_mode !~ '^[0-9]' then raise exception 'Sesi ini tidak memakai blok.'; end if;
  n := regexp_replace(s.feedback_mode, 's$', '')::int;
  total := cardinality(s.question_ids);
  perform app_save(p_token, p_session, p_answers, p_flags, p_client);
  select * into a from attempts where session_id = s.id and profile_id = r.id for update;
  if not found then raise exception 'Kamu belum memulai sesi ini.'; end if;
  perform _client_check(a, p_client);
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

create or replace function app_submit(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb, p_client text default null) returns jsonb
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
  perform _client_check(a, p_client);

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
