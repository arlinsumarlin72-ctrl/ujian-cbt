-- Salinan fungsi database yang SEDANG berjalan (diambil 2026-11-23 setelah patch-2026-11-23c-timer-per-bagian.sql).
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
end $function$
;

CREATE OR REPLACE FUNCTION public._blk_info(s sessions, a attempts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when _bsize(s) is null or s.timer_minutes is null or a.locked_n >= cardinality(s.question_ids)
      then jsonb_build_object('blk', null, 'blk_start', null)
    else jsonb_build_object('blk', a.locked_n / _bsize(s) + 1,
                            'blk_start', (a.block_starts ->> (a.locked_n / _bsize(s) + 1)::text)::int)
  end
$function$
;

CREATE OR REPLACE FUNCTION public._blk_peers(s sessions, a attempts)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare n int := _bsize(s); total int := cardinality(s.question_ids); re int;
begin
  if n is null or s.owner is not null then return null; end if;
  if a.locked_n > 0 and s.lock_mode = 'locked' and a.locked_n >= s.unlocked_n then re := a.locked_n;
  else re := least((a.locked_n / n + 1) * n, total); end if;
  return (select jsonb_build_object('done', count(*) filter (where t.submitted_at is not null or t.locked_n >= re),
                                    'all', count(*), 'blk', (re + n - 1) / n)
            from attempts t where t.session_id = s.id);
end $function$
;

CREATE OR REPLACE FUNCTION public._blk_sync(p_session uuid, p_profile uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._bsize(s sessions)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  select case when s.feedback_mode ~ '^[0-9]+' then nullif(regexp_replace(s.feedback_mode, 's$', '')::int, 0) end
$function$
;

CREATE OR REPLACE FUNCTION public._discussing(s sessions)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (select 1 from jsonb_array_elements(s.discuss_log) d where d ->> 'e' is null)
$function$
;

CREATE OR REPLACE FUNCTION public._drill_pool(p_profile uuid, p_kind text, p_sys text, p_session uuid DEFAULT NULL::uuid)
 RETURNS TABLE(o_qid uuid, o_w integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._elapsed(s sessions, a attempts)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  select greatest(0, floor(extract(epoch from (now() - a.started_at))
                           - _paused_secs(s.discuss_log, a.started_at, now())
                           - _paused_secs(a.pause_log, a.started_at, now())))::int
$function$
;

CREATE OR REPLACE FUNCTION public._is_paused(a attempts)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (select 1 from jsonb_array_elements(a.pause_log) d where d ->> 'e' is null)
$function$
;

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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public._open_for(s sessions, a attempts)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when _bsize(s) is not null and s.timer_minutes is not null
      then least(coalesce(_open_n(s), cardinality(s.question_ids)), (a.locked_n / _bsize(s) + 1) * _bsize(s), cardinality(s.question_ids))
    else _open_n(s) end
$function$
;

CREATE OR REPLACE FUNCTION public._open_n(s sessions)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  select case when s.lock_mode = 'locked' then s.unlocked_n end
$function$
;

CREATE OR REPLACE FUNCTION public._paused_secs(p_log jsonb, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(sum(greatest(0, extract(epoch from (
           least(coalesce((d ->> 'e')::timestamptz, p_to), p_to) - greatest((d ->> 's')::timestamptz, p_from))))), 0)
  from jsonb_array_elements(coalesce(p_log, '[]'::jsonb)) d
$function$
;

CREATE OR REPLACE FUNCTION public._pj(r profiles)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select jsonb_build_object('id', r.id, 'name', r.name, 'role', r.role, 'avatar_color', r.avatar_color)
$function$
;

CREATE OR REPLACE FUNCTION public._qtype(p_stem text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._result(p_profile uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._review(p_profile uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public._strip_after(p_ids uuid[], p_open integer, p_j jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'extensions'
AS $function$
declare v jsonb := coalesce(p_j, '{}'::jsonb); i int;
begin
  if p_open is null then return v; end if;
  for i in greatest(p_open, 0) + 1 .. cardinality(p_ids) loop
    v := v - (p_ids[i]::text);
  end loop;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public._times(p_profile uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
    'submitted', a.submitted_at is not null, 'score', a.score,
    'viol', jsonb_array_length(a.violations),
    'viol_secs', (select coalesce(sum((x ->> 'd')::int), 0) from jsonb_array_elements(a.violations) x),
    'viol_log', a.violations,
    'seen', case when a.last_seen is null then null else extract(epoch from (now() - a.last_seen))::int end
  ) order by (a.submitted_at is not null), p.name), '[]'::jsonb)
  into v from attempts a join profiles p on p.id = a.profile_id join sessions s on s.id = a.session_id where a.session_id = p_session;
  return v;
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_block_recap(p_token uuid, p_session uuid, p_block integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_create_session(p_token uuid, p_title text, p_bank_ids uuid[], p_count integer, p_timer integer, p_feedback text, p_exclude_sessions uuid[] DEFAULT '{}'::uuid[], p_lock text DEFAULT 'free'::text, p_strict boolean DEFAULT false, p_pause boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_delete_bank(p_token uuid, p_bank uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ declare n int; begin perform _admin(p_token); select count(*) into n from questions where bank_id = p_bank; delete from banks where id = p_bank; return jsonb_build_object('ok', true, 'deleted_questions', n); end $function$
;

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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_flow(p_token uuid, p_session uuid, p_action text, p_unlock boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_flow_state(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
      insert into questions (bank_id, num, stem, image, options, qtype)
      values (v_bank, nullif(it ->> 'num', '')::int, v_stem, nullif(it ->> 'image', ''), v_opts, _qtype(v_stem))
      returning id into v_id;
      insert into question_keys (question_id, answer) values (v_id, v_ans);
      ins := ins + 1;
    end if;
  end loop;
  return jsonb_build_object('bank_id', v_bank, 'inserted', ins, 'skipped', skp);
end $function$
;

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
           'done', (select count(*) from attempts a join sessions s on s.id = a.session_id
                     where a.profile_id = p.id and a.submitted_at is not null and s.owner is null)
         ) order by p.created_at), '[]'::jsonb) into v
  from profiles p;
  return v;
end $function$
;

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
end $function$
;

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
           'answer', k.answer, 'active', q.active, 'has_image', q.image is not null, 'qtype', coalesce(q.qtype, 'Lainnya'))
           order by q.num nulls last, q.created_at), '[]'::jsonb) into v
  from questions q left join question_keys k on k.question_id = q.id
  where q.bank_id = p_bank;
  return v;
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_result(p_token uuid, p_session uuid, p_profile uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  return _result(p_profile, p_session) || jsonb_build_object('person', (select name from profiles where id = p_profile),
                                                              'time', _times(p_profile, p_session),
                                                              'kind', (select kind from sessions where id = p_session));
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_review(p_token uuid, p_session uuid, p_profile uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  return _review(p_profile, p_session) || jsonb_build_object('person', (select name from profiles where id = p_profile));
end $function$
;

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
end $function$
;

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
           s.lock_mode, s.unlocked_n, s.ketat, s.allow_pause, _discussing(s) as discussing,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is not null) as finished,
           (select count(*) from attempts t where t.session_id = s.id and t.submitted_at is null) as ongoing
    from sessions s
    where s.owner is null
  ) x;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_set_qtype(p_token uuid, p_qid uuid, p_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  perform _admin(p_token);
  p_type := btrim(coalesce(p_type, ''));
  if length(p_type) < 2 or length(p_type) > 40 then raise exception 'Jenis soal harus 2 sampai 40 karakter.'; end if;
  update questions set qtype = p_type where id = p_qid;
  return jsonb_build_object('ok', true);
end $function$
;

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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.adm_submit_attempts(p_token uuid, p_session uuid, p_profile uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
end $function$
;

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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_drill_create(p_token uuid, p_kind text, p_count integer, p_sys text DEFAULT NULL::text, p_session uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_drill_delete(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  delete from sessions where id = p_session and owner = r.id;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.app_drill_stats(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_finalize(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb, p_upto integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_history(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
end $function$
;

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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_note_set(p_token uuid, p_qid uuid, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_notes(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles; v jsonb;
begin
  r := _me(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('qid', n.question_id, 'body', n.body, 'at', n.updated_at,
           'stem', left(q.stem, 240), 'file', b.name, 'system', coalesce(b.system, b.name), 'qtype', coalesce(q.qtype, 'Lainnya'))
           order by n.updated_at desc), '[]'::jsonb) into v
  from notes n join questions q on q.id = n.question_id join banks b on b.id = q.bank_id
  where n.profile_id = r.id;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.app_pause(p_token uuid, p_session uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_peers(p_token uuid, p_session uuid, p_qids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_progress(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_rank_by(p_token uuid, p_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_result(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  return _result(r.id, p_session) || jsonb_build_object('time', _times(r.id, p_session),
                                                       'kind', (select kind from sessions where id = p_session));
end $function$
;

CREATE OR REPLACE FUNCTION public.app_rev(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_reveal(p_token uuid, p_session uuid, p_qids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_review(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare r profiles;
begin
  r := _me(p_token);
  return _review(r.id, p_session);
end $function$
;

CREATE OR REPLACE FUNCTION public.app_save(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_start(p_token uuid, p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_submit(p_token uuid, p_session uuid, p_answers jsonb, p_flags jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_times(p_token uuid, p_session uuid, p_times jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_violation(p_token uuid, p_session uuid, p_kind text, p_secs integer, p_update boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$
;

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
    else n end $function$
;

CREATE OR REPLACE FUNCTION public.banks_set_system()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin if new.system is null then new.system := public.bank_system_of(new.name); end if; return new; end $function$

;
