-- Salinan fungsi database yang SEDANG berjalan (diambil 2026-11-22 setelah patch pemulihan).
-- Ini sumber kebenaran fungsi. schema.sql lama tidak lengkap: JANGAN dijalankan ulang di database yang sudah berjalan.

CREATE OR REPLACE FUNCTION public._admin(p_token uuid)
 RETURNS profiles
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  if r.role <> 'admin' then
    raise exception 'Fitur ini khusus admin.' using errcode = '42501';
  end if;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION public._keep_locked(p_ids uuid[], p_locked integer, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'extensions'
AS $function$
declare v jsonb := coalesce(p_new, '{}'::jsonb); i int; k text;
begin
  if coalesce(p_locked, 0) <= 0 then return v; end if;
  for i in 1..least(p_locked, cardinality(p_ids)) loop
    k := p_ids[i]::text;
    v := v - k;
    if p_old ? k then v := v || jsonb_build_object(k, p_old -> k); end if;
  end loop;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public._me(p_token uuid)
 RETURNS profiles
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  select * into r from profiles where token = p_token;
  if not found then
    raise exception 'Sesi login tidak valid. Silakan masuk lagi.' using errcode = '28000';
  end if;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION public._pj(r profiles)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select jsonb_build_object('id', r.id, 'name', r.name, 'role', r.role, 'avatar_color', r.avatar_color)
$function$;

CREATE OR REPLACE FUNCTION public.adm_attempts(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('profile_id', p.id, 'name', p.name, 'avatar_color', p.avatar_color,
    'answered', (select count(*) from jsonb_object_keys(a.answers)), 'total', cardinality(s.question_ids), 'locked', a.locked_n,
    'submitted', a.submitted_at is not null, 'score', a.score) order by (a.submitted_at is not null), p.name), '[]'::jsonb)
  into v from attempts a join profiles p on p.id = a.profile_id join sessions s on s.id = a.session_id where a.session_id = p_session;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.adm_banks(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'system', b.system,
           'active', (select count(*) from questions q where q.bank_id = b.id and q.active),
           'total',  (select count(*) from questions q where q.bank_id = b.id)
         ) order by b.name), '[]'::jsonb) into v
  from banks b;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.adm_create_session(p_token uuid, p_title text, p_bank_ids uuid[], p_count integer, p_timer integer, p_feedback text, p_exclude_sessions uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.adm_delete_bank(p_token uuid, p_bank uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ declare n int; begin perform _admin(p_token); select count(*) into n from questions where bank_id = p_bank; delete from banks where id = p_bank; return jsonb_build_object('ok', true, 'deleted_questions', n); end $function$;

CREATE OR REPLACE FUNCTION public.adm_delete_profile(p_token uuid, p_profile uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare me profiles; t profiles;
begin
  me := _admin(p_token);
  select * into t from profiles where id = p_profile;
  if not found then raise exception 'Peserta tidak ditemukan.'; end if;
  if t.id = me.id then raise exception 'Tidak bisa menghapus akunmu sendiri.'; end if;
  if t.role = 'admin' then raise exception 'Admin tidak bisa dihapus. Jadikan peserta dulu.'; end if;
  delete from profiles where id = p_profile;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.adm_delete_session(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  delete from sessions where id = p_session;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.adm_import(p_token uuid, p_bank_name text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.adm_people(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
           'avatar_color', p.avatar_color, 'created_at', p.created_at,
           'done', (select count(*) from attempts a where a.profile_id = p.id and a.submitted_at is not null)
         ) order by p.created_at), '[]'::jsonb) into v
  from profiles p;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.adm_pool_count(p_token uuid, p_bank_ids uuid[], p_exclude_sessions uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.adm_questions(p_token uuid, p_bank uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v jsonb;
begin
  perform _admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'num', q.num, 'stem', q.stem, 'options', q.options,
           'answer', k.answer, 'active', q.active, 'has_image', q.image is not null)
           order by q.num nulls last, q.created_at), '[]'::jsonb) into v
  from questions q left join question_keys k on k.question_id = q.id
  where q.bank_id = p_bank;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.adm_reset_pin(p_token uuid, p_profile uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN harus 4 sampai 6 angka.'; end if;
  update profiles set pin_hash = crypt(p_pin, gen_salt('bf')) where id = p_profile;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.adm_session_questions(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s sessions; v jsonb;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'no', u.ord, 'id', q.id, 'bank', b.name, 'stem', left(q.stem, 220),
           'answered', exists (select 1 from attempts a where a.session_id = s.id and a.answers ? q.id::text)
         ) order by u.ord), '[]'::jsonb) into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid
  join banks b on b.id = q.bank_id;
  return jsonb_build_object('title', s.title, 'status', s.status, 'swappable', cardinality(s.bank_ids) > 0, 'questions', v);
end $function$;

CREATE OR REPLACE FUNCTION public.adm_sessions(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.adm_set_role(p_token uuid, p_profile uuid, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.adm_set_session_status(p_token uuid, p_session uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  if p_status not in ('open','closed') then raise exception 'Status tidak valid.'; end if;
  update sessions set status = p_status where id = p_session;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.adm_submit_attempts(p_token uuid, p_session uuid, p_profile uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare s sessions; a attempts; v_score int; v_time int; c int := 0;
begin
  perform _admin(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  for a in select * from attempts where session_id = p_session and submitted_at is null and (p_profile is null or profile_id = p_profile) for update loop
    select count(*) into v_score from unnest(s.question_ids) as u(qid) join question_keys k on k.question_id = u.qid where a.answers ->> (u.qid::text) = k.answer;
    v_time := extract(epoch from (now() - a.started_at))::int;
    if s.timer_minutes is not null and v_time > s.timer_minutes * 60 then v_time := s.timer_minutes * 60; end if;
    update attempts set submitted_at = now(), score = v_score, time_taken = v_time, locked_n = cardinality(s.question_ids) where id = a.id;
    c := c + 1;
  end loop;
  return jsonb_build_object('ok', true, 'submitted', c);
end $function$;

CREATE OR REPLACE FUNCTION public.adm_swap_question(p_token uuid, p_session uuid, p_qid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.adm_toggle_question(p_token uuid, p_qid uuid, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  update questions set active = p_active where id = p_qid;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.app_change_pin(p_token uuid, p_old text, p_new text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  if r.pin_hash <> crypt(coalesce(p_old,''), r.pin_hash) then raise exception 'PIN lama salah.'; end if;
  if p_new is null or p_new !~ '^[0-9]{4,6}$' then raise exception 'PIN baru harus 4 sampai 6 angka.'; end if;
  update profiles set pin_hash = crypt(p_new, gen_salt('bf')) where id = r.id;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.app_finalize(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  nxt := least(a.locked_n + n, total);
  update attempts set locked_n = greatest(locked_n, nxt) where id = a.id;
  return jsonb_build_object('locked', greatest(a.locked_n, nxt));
end $function$;

CREATE OR REPLACE FUNCTION public.app_history(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_leaderboard(p_token uuid, p_session uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_login(p_name text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  select * into r from profiles where lower(name) = lower(btrim(coalesce(p_name, '')));
  if not found or r.pin_hash <> crypt(coalesce(p_pin, ''), r.pin_hash) then
    raise exception 'Nama atau PIN salah.';
  end if;
  return jsonb_build_object('token', r.token, 'profile', _pj(r));
end $function$;

CREATE OR REPLACE FUNCTION public.app_me(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  return _pj(r);
end $function$;

CREATE OR REPLACE FUNCTION public.app_register(p_name text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_result(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_rev(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles; s sessions; a attempts;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then return jsonb_build_object('rev', 0, 'notice', null, 'submitted', false); end if;
  select * into a from attempts where session_id = p_session and profile_id = r.id;
  return jsonb_build_object('rev', s.rev, 'notice', s.notice, 'submitted', coalesce(a.submitted_at is not null, false));
end $function$;

CREATE OR REPLACE FUNCTION public.app_reveal(p_token uuid, p_session uuid, p_qids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_review(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles; s sessions; a attempts; v jsonb;
begin
  r := _me(p_token);
  select * into s from sessions where id = p_session;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  select * into a from attempts where session_id = s.id and profile_id = r.id;
  if not found or a.submitted_at is null then raise exception 'Tinjauan tersedia setelah sesi dikumpulkan.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('no', u.ord, 'id', q.id, 'system', coalesce(b.system, b.name), 'stem', q.stem,
      'image', q.image, 'options', q.options, 'key', k.answer, 'mine', a.answers ->> (q.id::text),
      'flag', coalesce((a.flags ->> (q.id::text))::boolean, false)) order by u.ord), '[]'::jsonb)
  into v
  from unnest(s.question_ids) with ordinality as u(qid, ord)
  join questions q on q.id = u.qid join banks b on b.id = q.bank_id
  left join question_keys k on k.question_id = q.id;
  return jsonb_build_object('title', s.title, 'questions', v);
end $function$;

CREATE OR REPLACE FUNCTION public.app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_sessions(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_set_avatar(p_token uuid, p_color text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  if p_color is null or length(p_color) > 60000 or p_color !~ '^#[0-9A-Fa-f]{6}(\|.*)?$' then
    raise exception 'Warna atau gambar profil tidak valid.';
  end if;
  update profiles set avatar_color = p_color where id = r.id returning * into r;
  return _pj(r);
end $function$;

CREATE OR REPLACE FUNCTION public.app_start(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_submit(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.app_update_name(p_token uuid, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles; v text := btrim(coalesce(p_name,''));
begin
  r := _me(p_token);
  if length(v) < 2 or length(v) > 40 then raise exception 'Nama harus 2 sampai 40 karakter.'; end if;
  if exists (select 1 from profiles where lower(name) = lower(v) and id <> r.id) then
    raise exception 'Nama sudah dipakai peserta lain.';
  end if;
  update profiles set name = v where id = r.id returning * into r;
  return _pj(r);
end $function$;

CREATE OR REPLACE FUNCTION public.bank_system_of(n text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when n ~* '(kulit|integumen)' or n ~ 'DV [0-9]' then 'Kulit & Kelamin'
    when n ~ 'GEH' or n ~* 'gastro' then 'Gastro-Entero-Hepatologi'
    when n ~* 'neuro' then 'Neurologi'
    when n ~* '(ginek|obstetri|obgyn|obsgyn)' then 'Obstetri & Ginekologi'
    else n end $function$;

CREATE OR REPLACE FUNCTION public.banks_set_system()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin if new.system is null then new.system := public.bank_system_of(new.name); end if; return new; end $function$;

