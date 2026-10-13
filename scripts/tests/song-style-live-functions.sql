-- Read-only production function definitions captured before the migration.
-- Test fixture only; never execute this file against production.
CREATE OR REPLACE FUNCTION public.save_dance_atomic(p_week_id uuid, p_dance_id uuid, p_kind text, p_partnership_id uuid, p_name text, p_dance_type text, p_song text, p_judge_scores jsonb, p_cast_member_ids uuid[], p_scores_only boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_week public.weeks%rowtype; v_dance public.dances%rowtype; v_dance_id uuid;
  v_score jsonb; v_judge_name text; v_expected_judges text[];
  v_cast_ids uuid[] := coalesce(p_cast_member_ids, '{}'::uuid[]);
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if p_dance_id is not null then
    select * into v_dance from public.dances where id = p_dance_id and week_id = p_week_id for update;
    if not found then raise exception 'Dance not found in this week.'; end if;
  end if;
  if v_week.is_complete and not (
    (coalesce(p_scores_only, false) and p_dance_id is not null) or
    (p_dance_id is null and p_kind = 'performance' and not coalesce(p_scores_only, false))
  ) then raise exception 'Use the Week Ledger to correct a completed week.'; end if;
  if p_scores_only and (p_dance_id is null or v_dance.kind <> 'competitive') then raise exception 'Only an existing competitive dance supports score-only edits.'; end if;
  if p_scores_only then p_kind := v_dance.kind; end if;
  if p_kind is null or p_kind not in ('competitive','performance') then raise exception 'Choose a valid dance type.'; end if;
  if p_kind = 'competitive' and (case when p_scores_only then v_dance.partnership_id else p_partnership_id end) is null then raise exception 'A competitive dance needs a couple.'; end if;
  if p_kind = 'performance' and p_partnership_id is not null then raise exception 'A performance cannot have a competing couple.'; end if;
  if jsonb_typeof(p_judge_scores) is distinct from 'array' then raise exception 'Judge scores must be a list.'; end if;
  if p_kind = 'performance' and jsonb_array_length(p_judge_scores) > 0 then raise exception 'A performance cannot have judge scores.'; end if;
  if (select count(*) from unnest(v_cast_ids) m(member_id)) <> (select count(distinct member_id) from unnest(v_cast_ids) m(member_id)) then raise exception 'A cast member can appear only once in a dance.'; end if;
  v_expected_judges := array['Carrie Ann','Derek','Bruno']::text[];
  if nullif(trim(v_week.guest_judge_name), '') is not null then v_expected_judges := array_append(v_expected_judges, v_week.guest_judge_name); end if;
  for v_score in select item from jsonb_array_elements(p_judge_scores) scores(item) loop
    v_judge_name := v_score->>'judge_name';
    if v_judge_name is null or not (v_judge_name = any(v_expected_judges)) then raise exception 'Unrecognized judge: %.', coalesce(v_judge_name, '(blank)'); end if;
    if coalesce(v_score->>'score', '') !~ '^(10|[0-9])$' then raise exception 'Each judge score must be a whole number from 0 to 10.'; end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_judge_scores)) <> (select count(distinct item->>'judge_name') from jsonb_array_elements(p_judge_scores) scores(item)) then raise exception 'Each judge can score a dance only once.'; end if;
  if p_dance_id is null then
    insert into public.dances (week_id,kind,partnership_id,name,dance_type,song,sort_order)
    values (p_week_id,p_kind,p_partnership_id,nullif(trim(p_name),''),nullif(trim(p_dance_type),''),nullif(trim(p_song),''),coalesce((select max(sort_order)+1 from public.dances where week_id=p_week_id),1))
    returning id into v_dance_id;
  else
    v_dance_id := p_dance_id;
    if not p_scores_only then update public.dances set kind=p_kind, partnership_id=p_partnership_id, name=nullif(trim(p_name),''), dance_type=nullif(trim(p_dance_type),''), song=nullif(trim(p_song),'') where id=v_dance_id; end if;
  end if;
  delete from public.dance_judge_scores where dance_id=v_dance_id;
  insert into public.dance_judge_scores (dance_id,judge_name,score)
  select v_dance_id,item->>'judge_name',(item->>'score')::integer from jsonb_array_elements(p_judge_scores) scores(item);
  if not p_scores_only then
    delete from public.dance_appearances where dance_id=v_dance_id;
    insert into public.dance_appearances (dance_id,cast_member_id) select v_dance_id,member_id from unnest(v_cast_ids) m(member_id);
  end if;
  return v_dance_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_dance_music_match(p_dance_id uuid, p_song_title text, p_apple_url text, p_spotify_url text, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_status not in ('matched', 'no_match') then
    raise exception 'Bad match status.';
  end if;
  -- Only if the song hasn't changed (or been set by hand) since the match started.
  update public.dances
  set apple_music_url = p_apple_url, spotify_url = p_spotify_url,
      music_match_status = p_status, music_matched_at = now()
  where id = p_dance_id and song_title is not distinct from p_song_title
    and coalesce(music_match_status, '') <> 'manual';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.canonical_dance_type(p_value text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_value text := nullif(btrim(p_value), '');
  v_parts text[]; v_type text; v_first text; v_second text;
begin
  if v_value is null then return null; end if;
  select name into v_type from public.dance_types
    where lower(name) = lower(v_value) and name <> 'Fusion';
  if v_type is not null then return v_type; end if;
  v_parts := regexp_match(v_value, '^([^/]+)/([^/]+) Fusion$');
  if v_parts is null then
    raise exception 'Choose a listed dance type, or select two styles for Fusion.' using errcode = 'P0001';
  end if;
  select name into v_first from public.dance_types
    where lower(name) = lower(btrim(v_parts[1])) and name <> 'Fusion';
  select name into v_second from public.dance_types
    where lower(name) = lower(btrim(v_parts[2])) and name <> 'Fusion';
  if v_first is null or v_second is null or v_first = v_second then
    raise exception 'Fusion needs two different listed dance types.' using errcode = 'P0001';
  end if;
  return v_first || '/' || v_second || ' Fusion';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_manual_dance_confirmation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f text; present boolean; changed boolean;
begin
  if auth.role() = 'service_role' or current_setting('mirrorball.automation_import',true) = 'on' then return new; end if;
  foreach f in array array['dance_type','song','elimination_result'] loop
    changed := tg_op = 'INSERT';
    if tg_op = 'UPDATE' then changed := to_jsonb(new)->f is distinct from to_jsonb(old)->f or new.kind is distinct from old.kind; end if;
    if changed then
      present := new.kind = 'competitive' and nullif(btrim(to_jsonb(new)->>f),'') is not null;
      insert into public.dance_confirmation_checks(dance_id,field_name,confirmed_source,confirmed_at)
      values(new.id,case when f='elimination_result' then 'elimination' else f end,
        case when present then 'manual' end,case when present then now() end)
      on conflict(dance_id,field_name) do update set confirmed_source=excluded.confirmed_source,
        confirmed_at=excluded.confirmed_at,candidate_value=null,matching_checks=0,last_check_id=null,last_checked_at=null;
    end if;
  end loop;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.mark_manual_dance_details_confirmed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.role() = 'service_role' or current_setting('mirrorball.automation_import',true) = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    new.dance_type_confirmed := new.kind = 'competitive' and nullif(btrim(new.dance_type),'') is not null;
    new.song_confirmed := new.kind = 'competitive' and nullif(btrim(new.song),'') is not null;
    new.elimination_confirmed := new.kind = 'competitive' and new.elimination_result is not null;
  else
    if new.dance_type is distinct from old.dance_type or new.kind is distinct from old.kind then
      new.dance_type_confirmed := new.kind = 'competitive' and nullif(btrim(new.dance_type),'') is not null;
    end if;
    if new.song is distinct from old.song or new.kind is distinct from old.kind then
      new.song_confirmed := new.kind = 'competitive' and nullif(btrim(new.song),'') is not null;
    end if;
    if new.elimination_result is distinct from old.elimination_result or new.kind is distinct from old.kind then
      new.elimination_confirmed := new.kind = 'competitive' and new.elimination_result is not null;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.dwts_observe_field(p_dance uuid, p_field text, p_value jsonb, p_run uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.dance_confirmation_checks%rowtype; n integer;
begin
  insert into public.dance_confirmation_checks(dance_id,field_name) values(p_dance,p_field) on conflict do nothing;
  select * into c from public.dance_confirmation_checks where dance_id=p_dance and field_name=p_field for update;
  if c.last_check_id=p_run then return c.matching_checks; end if;
  if p_value is null or p_value='null'::jsonb then n:=0;
  elsif c.candidate_value=p_value then n:=least(c.matching_checks+1,2);
  else n:=1; end if;
  update public.dance_confirmation_checks set candidate_value=p_value,matching_checks=n,
    last_check_id=p_run,last_checked_at=now(),confirmed_source=case when n=2 then 'wiki' end,
    confirmed_at=case when n=2 then now() end where dance_id=p_dance and field_name=p_field;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_week_automation_status(p_week_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.weeks%rowtype; data jsonb;
begin
  if not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access required'; end if;
  select * into w from public.weeks where id=p_week_id;
  if not found then raise exception 'Week not found'; end if;
  select jsonb_build_object('settings',to_jsonb(a),'worker',to_jsonb(s),'server_time',now(),
    'previous_complete',w.number=1 or exists(select 1 from public.weeks p where p.number=w.number-1 and p.is_complete),
    'progress',(select jsonb_build_object('total',count(*),
      'dance_types',count(*) filter(where dance_type_confirmed),'songs',count(*) filter(where song_confirmed),
      'scores',count(*) filter(where scores_confirmed),'eliminations',count(*) filter(where elimination_confirmed),
      'photos',count(*) filter(where photos_uploaded)) from public.dances where week_id=w.id and kind='competitive'),
    'jobs',coalesce((select jsonb_agg(jsonb_build_object('mode',j.mode,'next_run_at',j.next_run_at,
      'lease_until',j.lease_until,'last_error',j.last_error,'pending',jsonb_array_length(public.dwts_pending_targets(w.id,j.mode)),
      'window',case when j.mode in ('photos','live-show','post-show') then public.dwts_window_opening(w.id,j.mode,now()) else now() end,
      'elimination_found',exists(select 1 from public.dances d where d.week_id=w.id and d.elimination_confirmed and d.elimination_result),
      'last_run',to_jsonb(r))) from public.dwts_automation_jobs j
      left join lateral (select started_at,finished_at,status,summary from public.dwts_automation_runs
        where job_id=j.id order by started_at desc limit 1) r on true
      where j.week_id=w.id),'[]'::jsonb)) into data
  from (select 1) seed left join public.dwts_automation_weeks a on a.week_id=w.id
    left join public.dwts_automation_state s on s.id=1;
  return data;
end $function$
;

CREATE OR REPLACE FUNCTION public.update_performance_dance_details(p_dance_id uuid, p_song text, p_choreography text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then
    raise exception 'Platform-owner access is required.';
  end if;

  update public.dances
  set song = nullif(trim(p_song), ''),
      choreography = nullif(trim(p_choreography), '')
  where id = p_dance_id and kind = 'performance';

  if not found then
    raise exception 'Performance dance not found.';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.ensure_week_competitive_dances(p_week_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.weeks%rowtype; previous public.weeks%rowtype;
  rows jsonb; old_marker text;
begin
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-week-dances:'||p_week_id::text,0));
  select * into w from public.weeks where id=p_week_id for update;
  if not found or w.is_complete then return '[]'::jsonb; end if;
  select * into previous from public.weeks where number=w.number-1;
  if not found or not previous.is_complete or previous.is_season_finale then return '[]'::jsonb; end if;
  old_marker:=coalesce(current_setting('mirrorball.automation_import',true),'');
  perform set_config('mirrorball.automation_import','on',true);
  with eligible as (
    select p.id, row_number() over(order by s.name,r.name,p.id) as position
    from public.partnerships p
    join public.cast_members s on s.id=p.star_id
    join public.cast_members r on r.id=p.pro_id
    where p.active and s.role='Star' and r.role='Pro'
      and s.eliminated_week_id is null and r.eliminated_week_id is null
      and not exists(select 1 from public.dances d
        where d.week_id=w.id and d.kind='competitive' and d.partnership_id=p.id)
  ), inserted as (
    insert into public.dances(week_id,kind,partnership_id,sort_order)
    select w.id,'competitive',e.id,
      (select greatest(coalesce(max(sort_order),0),0) from public.dances where week_id=w.id)+e.position::integer
    from eligible e order by e.position
    returning id,kind,partnership_id,name,dance_type,song,sort_order
  ) select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order),'[]'::jsonb) into rows from inserted i;
  perform set_config('mirrorball.automation_import',old_marker,true);
  return rows;
end $function$
;

CREATE OR REPLACE FUNCTION public.report_dwts_work_base(p_worker text, p_run uuid, p_result jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.dwts_automation_runs%rowtype; j public.dwts_automation_jobs%rowtype;
  w public.weeks%rowtype; target jsonb; couple jsonb; perf jsonb; data jsonb;
  d public.dances%rowtype; n integer; checks integer;
  field_name text; value jsonb; score_item jsonb; score integer; total integer;
  names text[]; artist text; title text; dance_type text; v_song text;
  tag text; tagged jsonb; files jsonb; post jsonb; upload jsonb;
  cooldown integer:=0; errors jsonb:='[]'::jsonb; imported integer:=0;
  delay interval; old_marker text; is_failed boolean; has_candidate boolean:=false;
begin
  if p_result is null or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>2000000 then raise exception 'Invalid or oversized result'; end if;
  perform pg_advisory_xact_lock(2601005,1);
  select * into r from public.dwts_automation_runs where id=p_run;
  if not found or r.worker_name<>p_worker then raise exception 'Unknown run or worker'; end if;
  select * into j from public.dwts_automation_jobs where id=r.job_id for update;
  select * into r from public.dwts_automation_runs where id=p_run for update;
  if r.status in ('finished','failed') then return r.summary||jsonb_build_object('already_reported',true); end if;
  if r.status<>'running' or j.active_run_id is distinct from p_run or j.lease_until<=now() then raise exception 'Run lease expired; claim new work'; end if;
  select * into w from public.weeks where id=j.week_id for update;
  perform public.heartbeat_dwts_worker(p_worker);
  old_marker:=coalesce(current_setting('mirrorball.automation_import',true),'');
  perform set_config('mirrorball.automation_import','on',true);
  is_failed:=coalesce((p_result->>'failed_run')::boolean,false) or p_result ? 'error';
  if p_result ? 'error' then errors:=errors||jsonb_build_array(left(p_result->>'error',1000)); end if;
  if jsonb_typeof(p_result->'errors')='array' then
    errors:=errors||(p_result->'errors');
    for data in select * from jsonb_array_elements(p_result->'errors') loop
      if data->>'cooldown_seconds' ~ '^[0-9]{1,7}$' then cooldown:=greatest(cooldown,(data->>'cooldown_seconds')::integer); end if;
    end loop;
  end if;
  if w.is_complete then
    errors:=errors||jsonb_build_array('Week was completed while this job was running; ignored result');
  elsif j.mode='get-weeks' then
    select item into tagged from jsonb_array_elements(coalesce(p_result->'weeks','[]'::jsonb)) item
      where item->>'week'=w.number::text limit 1;
    tag:=nullif(btrim(tagged->>'week_tag'),'');
    if tag is not null and (tag not like '#Week\_'||w.number||':%' escape '\' or length(tag)>250) then tag:=null; end if;
    update public.dwts_automation_weeks a set
      wiki_tag_checks=case when tag is null then 0 when a.wiki_tag_candidate=tag then least(a.wiki_tag_checks+1,2) else 1 end,
      wiki_tag_candidate=tag,wiki_tag_last_check=p_run,updated_at=now()
      where week_id=w.id and a.wiki_tag_last_check is distinct from p_run returning wiki_tag_checks into checks;
    if checks=2 then
      update public.dwts_automation_weeks set wiki_tag=tag where week_id=w.id;
      update public.dwts_automation_jobs set next_run_at=now() where week_id=w.id and mode='pre-show';
    elsif checks=1 then has_candidate:=true; end if;
  elsif j.mode='photos' then
    if coalesce((p_result->>'dry_run')::boolean,false) then raise exception 'Dry-run uploads cannot be reported as production work'; end if;
    if p_result->>'week' is distinct from w.number::text then raise exception 'Photo result week mismatch'; end if;
    for upload in select * from jsonb_array_elements(coalesce(p_result->'uploaded_couples','[]'::jsonb)) loop
      begin
        select item into target from jsonb_array_elements(r.payload->'targets') item
          where item->>'star_name'=upload->>'star_name' and item->>'pro_name'=upload->>'pro_name';
        if target is null then raise exception 'Upload is not a claimed couple'; end if;
        files:=upload->'files';
        if jsonb_typeof(files) is distinct from 'array' or public.dwts_array_length(files)=0
          or coalesce(upload->>'commit_sha','') !~ '^[0-9a-f]{40}$'
          or jsonb_typeof(upload->'post_ids') is distinct from 'array' or public.dwts_array_length(upload->'post_ids')=0 then
          raise exception 'Upload receipt needs files, post IDs and a successful GitHub commit';
        end if;
        for data in select * from jsonb_array_elements(files) loop
          if left(coalesce(data->>'path',''),length(r.payload->>'folder')+1) <> (r.payload->>'folder')||'/'
            or data->>'path' ~ '(^|/)\.\.(/|$)' or data->>'path' ~ '[\\]' then raise exception 'Invalid upload path'; end if;
          if position((target->>'star_name')||' and '||(target->>'pro_name')||'-' in data->>'path')=0 then raise exception 'Upload filename does not match the couple'; end if;
        end loop;
        select * into d from public.dances where id=(target->>'dance_id')::uuid and week_id=w.id
          and partnership_id=(target->>'partnership_id')::uuid and kind='competitive' for update;
        if not found then raise exception 'Claimed dance no longer exists'; end if;
        for post in select * from jsonb_array_elements(upload->'post_ids') loop
          if jsonb_typeof(post)<>'string' or (post#>>'{}') !~ '^[0-9]{1,30}$' then raise exception 'Invalid source post ID'; end if;
          if exists(select 1 from public.dwts_photo_receipts where week_id=w.id and post_id=post#>>'{}' and partnership_id<>d.partnership_id) then raise exception 'Source post already belongs to another couple'; end if;
          insert into public.dwts_photo_receipts(week_id,post_id,partnership_id,files,commit_sha)
          values(w.id,post#>>'{}',d.partnership_id,files,upload->>'commit_sha') on conflict(week_id,post_id) do nothing;
        end loop;
        update public.dances set photos_uploaded=true where id=d.id;
        imported:=imported+1;
      exception when others then errors:=errors||jsonb_build_array(left(sqlerrm,1000)); end;
    end loop;
    if is_failed then
      cooldown:=greatest(cooldown,case when coalesce((p_result->>'skip_next_run')::boolean,false) then 600 else 300 end);
      update public.dwts_automation_state set photos_not_before=greatest(coalesce(photos_not_before,now()),now()+make_interval(secs=>cooldown)) where id=1;
    end if;
  else
    if p_result ? 'week' and p_result->>'week' is distinct from w.number::text then raise exception 'Wiki result week mismatch'; end if;
    if not is_failed and (p_result->>'mode' is distinct from j.mode or p_result->>'week_tag' is distinct from r.payload->>'week_tag') then raise exception 'Wiki result mode/tag mismatch'; end if;
    for target in select * from jsonb_array_elements(r.payload->'targets') loop
      select * into d from public.dances where id=(target->>'dance_id')::uuid and week_id=w.id
        and partnership_id=(target->>'partnership_id')::uuid and kind='competitive' for update;
      if not found then continue; end if;
      couple:=null; perf:=null;
      select item into couple from jsonb_array_elements(coalesce(p_result->'couples','[]'::jsonb)) item
        where item->>'star_name'=target->>'star_name' and item->>'pro_name'=target->>'pro_name';
      if not is_failed and coalesce((couple->>'found')::boolean,false)
        and jsonb_typeof(couple->'performances')='array' and public.dwts_array_length(couple->'performances')=1 then perf:=couple->'performances'->0; end if;
      if jsonb_typeof(couple->'performances')='array' and public.dwts_array_length(couple->'performances')>1 then
        errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'error','Multiple Wikipedia performances need explicit mapping; not guessing'));
      end if;
      if j.mode='pre-show' then
        foreach field_name in array array['dance_type','song'] loop
          if field_name='dance_type' and d.dance_type_confirmed or field_name='song' and d.song_confirmed then continue; end if;
          begin
            value:=null;
            if field_name='dance_type' then
              dance_type:=public.canonical_dance_type(nullif(btrim(perf->>'dance'),''));
              if dance_type is not null then value:=to_jsonb(dance_type); end if;
            else
              title:=nullif(btrim(perf->>'song'),''); artist:=nullif(btrim(perf->>'artist'),'');
              if title is not null then value:=jsonb_build_object('title',title,'artist',artist); end if;
            end if;
            n:=public.dwts_observe_field(d.id,field_name,value,p_run);
            if n=1 then has_candidate:=true; end if;
            if field_name='dance_type' then
              update public.dances set dance_type=case when value is null then null else value#>>'{}' end,dance_type_confirmed=n=2 where id=d.id;
            else
              v_song:=case when value is null then null else title||case when artist is null then '' else ' by '||artist end end;
              update public.dances set song=v_song,song_confirmed=n=2 where id=d.id;
            end if;
            if n=2 then imported:=imported+1; end if;
          exception when others then
            perform public.dwts_observe_field(d.id,field_name,null,p_run);
            errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'field',field_name,'error',left(sqlerrm,1000)));
          end;
        end loop;
      elsif j.mode='live-show' and not d.scores_confirmed then
        begin
          names:=array(select jsonb_array_elements_text(r.payload->'judge_order'));
          if public.dance_expected_judges(d.id) is null
            or not names @> public.dance_expected_judges(d.id) or not names <@ public.dance_expected_judges(d.id)
            or cardinality(names)<>cardinality(public.dance_expected_judges(d.id)) then raise exception 'Judge panel changed during run'; end if;
          value:=null; total:=0;
          if jsonb_typeof(perf->'scores')='array' and public.dwts_array_length(perf->'scores')=cardinality(names) then
            value:='[]'::jsonb; checks:=1;
            for score_item in select * from jsonb_array_elements(perf->'scores') loop
              if jsonb_typeof(score_item)<>'number' or (score_item#>>'{}') !~ '^(10|[1-9])$' then raise exception 'Each judge score must be an integer 1–10'; end if;
              score:=(score_item#>>'{}')::integer; total:=total+score;
              value:=value||jsonb_build_array(jsonb_build_object('judge_name',names[checks],'score',score)); checks:=checks+1;
            end loop;
            if perf->>'total' is null or perf->>'total' !~ '^[0-9]{1,2}$' or (perf->>'total')::integer<>total then raise exception 'Score total does not match individual judges'; end if;
          end if;
          if value is not null and exists(select 1 from public.dance_judge_scores s
            join jsonb_array_elements(value) v on v->>'judge_name'=s.judge_name
            where s.dance_id=d.id and s.confirmed and s.score<>(v->>'score')::integer) then raise exception 'Wikipedia conflicts with a manually confirmed judge score'; end if;
          n:=public.dwts_observe_field(d.id,'scores',value,p_run);
          if value is null then
            delete from public.dance_judge_scores where dance_id=d.id and not confirmed;
          else
            for score_item in select * from jsonb_array_elements(value) loop
              insert into public.dance_judge_scores(dance_id,judge_name,score,confirmed)
              values(d.id,score_item->>'judge_name',(score_item->>'score')::integer,n=2)
              on conflict(dance_id,judge_name) do update set score=excluded.score,confirmed=excluded.confirmed
                where not public.dance_judge_scores.confirmed;
            end loop;
          end if;
          perform public.refresh_dance_scores_confirmed(d.id);
          if n=2 then imported:=imported+1; end if;
        exception when others then
          perform public.dwts_observe_field(d.id,'scores',null,p_run);
          delete from public.dance_judge_scores where dance_id=d.id and not confirmed;
          perform public.refresh_dance_scores_confirmed(d.id);
          errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'field','scores','error',left(sqlerrm,1000)));
        end;
      elsif j.mode='post-show' and not d.elimination_confirmed then
        value:=case when jsonb_typeof(perf->'eliminated')='boolean' then perf->'eliminated' end;
        n:=public.dwts_observe_field(d.id,'elimination',value,p_run);
        update public.dances set elimination_result=case when value is null then null else (value#>>'{}')::boolean end,
          elimination_confirmed=n=2 where id=d.id;
        if n=2 then imported:=imported+1; end if;
      end if;
    end loop;
  end if;
  delay:=case when j.mode in ('photos','live-show','post-show') then interval '5 minutes'
    when has_candidate then interval '1 minute' when j.mode='get-weeks' then interval '1 hour' else interval '30 minutes' end;
  update public.dwts_automation_jobs set active_run_id=null,lease_until=null,
    next_run_at=greatest(now()+delay,case when j.mode='photos' then (select photos_not_before from public.dwts_automation_state where id=1) else now() end),
    last_error=case when public.dwts_array_length(errors)>0 then left(errors::text,2000) end where id=j.id;
  data:=jsonb_build_object('run_id',p_run,'mode',j.mode,'confirmed_or_uploaded',imported,
    'errors',errors,'next_run_at',(select next_run_at from public.dwts_automation_jobs where id=j.id));
  update public.dwts_automation_runs set status=case when is_failed or public.dwts_array_length(errors)>0 then 'failed' else 'finished' end,
    finished_at=now(),summary=data where id=p_run;
  perform set_config('mirrorball.automation_import',old_marker,true);
  return data;
end $function$
;

CREATE OR REPLACE FUNCTION public.split_dance_song()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_song text := nullif(btrim(coalesce(new.song, '')), '');
begin
  -- dances.song stays the source of truth ("Title by Artist"); title and artist follow it.
  new.song_title := public.dance_song_part(v_song, 1);
  new.song_artist := public.dance_song_part(v_song, 2);
  -- A new or changed song needs matching again, unless its links were set by hand.
  if tg_op = 'INSERT' then
    if coalesce(new.music_match_status, '') <> 'manual' then
      new.apple_music_url := null;
      new.spotify_url := null;
      new.music_matched_at := null;
      new.music_match_status := case when v_song is null then null else 'pending' end;
    end if;
  elsif new.song is distinct from old.song and coalesce(old.music_match_status, '') <> 'manual' then
    new.apple_music_url := null;
    new.spotify_url := null;
    new.music_matched_at := null;
    new.music_match_status := case when v_song is null then null else 'pending' end;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dance_song_part(p_song text, p_part integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- 1 = title, 2 = artist. Splits "Title by Artist" on the last " by ".
  select case
    when nullif(btrim(coalesce(p_song, '')), '') is null then null
    when (regexp_match(btrim(p_song), '^(.*[^ ]) by ([^ ].*)$')) is null then case when p_part = 1 then btrim(p_song) end
    else btrim((regexp_match(btrim(p_song), '^(.*[^ ]) by ([^ ].*)$'))[p_part])
  end;
$function$
;
