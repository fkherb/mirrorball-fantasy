-- Phase 1: keep dances.song and the legacy APIs; make split fields authoritative.
-- Run database changes BEFORE publishing the updated website.
-- Does not delete any songs, dances, catalogs, or historical scores.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $$
begin
  if to_regclass('public.dance_styles') is null then
    raise exception 'Create/populate public.dance_styles before running this migration.';
  end if;
  if not exists (select 1 from public.dance_styles where name='Fusion') then
    raise exception 'The dance_styles catalog must include Fusion.';
  end if;
  if exists (select 1 from public.dances where nullif(btrim(song),'') is not null
    and nullif(btrim(song_title),'') is null) then
    raise exception 'Backfill separate song fields before making them authoritative.';
  end if;
end $$;

-- Preserve catalog metadata and the existing read-only access model.
alter table public.dance_styles enable row level security;
drop policy if exists "public read dance styles" on public.dance_styles;
create policy "public read dance styles" on public.dance_styles
  for select to anon,authenticated using (true);
revoke all on public.dance_styles from anon,authenticated;
grant select on public.dance_styles to anon,authenticated,service_role;

create or replace function public.canonical_dance_style(p_value text)
returns text language plpgsql stable security invoker set search_path='' as $$
declare v_value text:=nullif(btrim(p_value),''); v_key text;
  v_parts text[]; v_style text; v_first text; v_second text;
begin
  if v_value is null then return null; end if;
  v_key:=regexp_replace(lower(v_value),'[^a-z0-9]','','g');
  if v_key='chachacha' then v_key:='chacha'; end if;
  select name into v_style from public.dance_styles
    where regexp_replace(lower(name),'[^a-z0-9]','','g')=v_key and name<>'Fusion';
  if v_style is not null then return v_style; end if;
  v_parts:=regexp_match(v_value,'^([^/]+)/([^/]+)[[:space:]]+Fusion$','i');
  if v_parts is null then
    raise exception 'Choose a listed dance style, or two different styles for Fusion.';
  end if;
  v_first:=public.canonical_dance_style(btrim(v_parts[1]));
  v_second:=public.canonical_dance_style(btrim(v_parts[2]));
  if v_first is null or v_second is null or v_first=v_second then
    raise exception 'Fusion needs two different listed dance styles.';
  end if;
  return v_first||'/'||v_second||' Fusion';
end $$;

-- Keep the old helper's name for callers, but never query dance_types.
create or replace function public.canonical_dance_type(p_value text)
returns text language sql stable security invoker set search_path='' as $$
  select public.canonical_dance_style(p_value);
$$;
revoke all on function public.canonical_dance_style(text),public.canonical_dance_type(text) from public,anon;
grant execute on function public.canonical_dance_style(text),public.canonical_dance_type(text) to authenticated,service_role;

-- No personal data or song text is logged; counters identify legacy callers.
create schema if not exists mirrorball_private;
revoke all on schema mirrorball_private from public,anon,authenticated;
create table if not exists mirrorball_private.legacy_song_usage(
  source text primary key,
  calls bigint not null default 0,
  last_seen_at timestamptz not null default now()
);
alter table mirrorball_private.legacy_song_usage enable row level security;
revoke all on mirrorball_private.legacy_song_usage from public,anon,authenticated;

create or replace function public.log_legacy_song_use(p_source text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if p_source not in ('save_dance_atomic','update_performance_dance_details',
    'direct_song_write','record_dance_music_match') then raise exception 'Unknown legacy source'; end if;
  if session_user<>'postgres' and not (coalesce(public.is_platform_admin(),false)
    or coalesce(public.is_league_commissioner(),false) or coalesce(auth.role()='service_role',false)) then
    raise exception 'Authorized dance access required';
  end if;
  insert into mirrorball_private.legacy_song_usage(source,calls,last_seen_at)
  values(p_source,1,now()) on conflict(source) do update
    set calls=mirrorball_private.legacy_song_usage.calls+1,last_seen_at=excluded.last_seen_at;
end $$;
revoke all on function public.log_legacy_song_use(text) from public,anon;
grant execute on function public.log_legacy_song_use(text) to authenticated,service_role;

-- This is the only row-level compatibility bridge that reads/writes song.
-- New RPCs explicitly mark split input so even clearing unchanged/null fields
-- cannot accidentally restore a stale legacy value.
create or replace function public.sync_dance_song_compatibility()
returns trigger language plpgsql security definer set search_path='' as $$
declare legacy boolean:=false;
begin
  if coalesce(current_setting('mirrorball.song_input_format',true),'')<>'split' then
    if tg_op='INSERT' then
      legacy:=new.song_title is null and new.song_artist is null and nullif(btrim(new.song),'') is not null;
    else
      legacy:=new.song is distinct from old.song
        and new.song_title is not distinct from old.song_title
        and new.song_artist is not distinct from old.song_artist;
    end if;
  end if;
  if legacy then
    new.song_title:=public.dance_song_part(new.song,1);
    new.song_artist:=public.dance_song_part(new.song,2);
    perform public.log_legacy_song_use('direct_song_write');
  end if;
  new.song_title:=nullif(btrim(new.song_title),'');
  new.song_artist:=nullif(btrim(new.song_artist),'');
  new.song:=case when new.song_title is null then null
    else new.song_title||case when new.song_artist is null then '' else ' by '||new.song_artist end end;
  return new;
end $$;
drop trigger if exists split_dance_song on public.dances;
drop function if exists public.split_dance_song();
drop trigger if exists sync_dance_song_compatibility on public.dances;
create trigger sync_dance_song_compatibility before insert or update of song,song_title,song_artist
  on public.dances for each row execute function public.sync_dance_song_compatibility();
revoke all on function public.sync_dance_song_compatibility() from public,anon,authenticated,service_role;

-- Runs after the compatibility bridge, including legacy song-only writes.
create or replace function public.refresh_dance_music_links()
returns trigger language plpgsql security invoker set search_path='' as $$
declare changed boolean;
begin
  changed:=tg_op='INSERT';
  if tg_op='UPDATE' then
    changed:=new.song_title is distinct from old.song_title or new.song_artist is distinct from old.song_artist;
    if coalesce(old.music_match_status,'')='manual' then return new; end if;
  end if;
  if changed and coalesce(new.music_match_status,'')<>'manual' then
    new.apple_music_url:=null; new.spotify_url:=null; new.music_matched_at:=null;
    new.music_match_status:=case when new.song_title is null then null else 'pending' end;
  end if;
  return new;
end $$;
drop trigger if exists z_refresh_dance_music_links on public.dances;
create trigger z_refresh_dance_music_links before insert or update on public.dances
  for each row execute function public.refresh_dance_music_links();
revoke all on function public.refresh_dance_music_links() from public,anon,authenticated,service_role;

create or replace function public.mark_manual_dance_details_confirmed()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if auth.role()='service_role' or current_setting('mirrorball.automation_import',true)='on' then return new; end if;
  if tg_op='INSERT' then
    new.dance_type_confirmed:=new.kind='competitive' and nullif(btrim(new.dance_type),'') is not null;
    new.song_confirmed:=new.kind='competitive' and nullif(btrim(new.song_title),'') is not null;
    new.elimination_confirmed:=new.kind='competitive' and new.elimination_result is not null;
  else
    if new.dance_type is distinct from old.dance_type or new.kind is distinct from old.kind then
      new.dance_type_confirmed:=new.kind='competitive' and nullif(btrim(new.dance_type),'') is not null;
    end if;
    if new.song_title is distinct from old.song_title or new.song_artist is distinct from old.song_artist
      or new.kind is distinct from old.kind then
      new.song_confirmed:=new.kind='competitive' and nullif(btrim(new.song_title),'') is not null;
    end if;
    if new.elimination_result is distinct from old.elimination_result or new.kind is distinct from old.kind then
      new.elimination_confirmed:=new.kind='competitive' and new.elimination_result is not null;
    end if;
  end if;
  return new;
end $$;

create or replace function public.record_manual_dance_confirmation()
returns trigger language plpgsql security definer set search_path='' as $$
declare f text; present boolean; changed boolean;
begin
  if auth.role()='service_role' or current_setting('mirrorball.automation_import',true)='on' then return new; end if;
  foreach f in array array['dance_type','song','elimination_result'] loop
    changed:=tg_op='INSERT';
    if tg_op='UPDATE' then
      changed:=new.kind is distinct from old.kind;
      if f='song' then
        changed:=changed or new.song_title is distinct from old.song_title or new.song_artist is distinct from old.song_artist;
      else changed:=changed or to_jsonb(new)->f is distinct from to_jsonb(old)->f; end if;
    end if;
    if changed then
      present:=new.kind='competitive' and case when f='song'
        then nullif(btrim(new.song_title),'') is not null else nullif(btrim(to_jsonb(new)->>f),'') is not null end;
      insert into public.dance_confirmation_checks(dance_id,field_name,confirmed_source,confirmed_at)
      values(new.id,case when f='elimination_result' then 'elimination' else f end,
        case when present then 'manual' end,case when present then now() end)
      on conflict(dance_id,field_name) do update set confirmed_source=excluded.confirmed_source,
        confirmed_at=excluded.confirmed_at,candidate_value=null,matching_checks=0,last_check_id=null,last_checked_at=null;
    end if;
  end loop;
  return new;
end $$;
-- UPDATE OF checks the statement's target list, not changes made by another
-- trigger. Use all updates + value comparisons to catch compatibility writes.
drop trigger if exists zz_mark_manual_dance_details_confirmed on public.dances;
create trigger zz_mark_manual_dance_details_confirmed before insert or update on public.dances
  for each row execute function public.mark_manual_dance_details_confirmed();
drop trigger if exists record_manual_dance_confirmation on public.dances;
create trigger record_manual_dance_confirmation after insert or update on public.dances
  for each row execute function public.record_manual_dance_confirmation();
revoke all on function public.mark_manual_dance_details_confirmed(),public.record_manual_dance_confirmation()
  from public,anon,authenticated,service_role;

-- Same atomic scoring/appearance transaction as before; split songs are never parsed.
-- Optional details also save performance free text/choreographers/night atomically.
create or replace function public.save_dance_atomic_v2(
  p_week_id uuid,p_dance_id uuid,p_kind text,p_partnership_id uuid,
  p_name text,p_dance_type text,p_song_title text,p_song_artist text,
  p_judge_scores jsonb,p_cast_member_ids uuid[],p_scores_only boolean,
  p_details jsonb default null
)
returns uuid language plpgsql security invoker set search_path='' as $$
declare v_week public.weeks%rowtype; v_dance public.dances%rowtype; v_dance_id uuid;
  v_score jsonb; v_judge_name text; v_expected_judges text[];
  v_cast_ids uuid[]:=coalesce(p_cast_member_ids,'{}'::uuid[]); old_format text;
begin
  if not coalesce(public.is_league_commissioner(),false) then raise exception 'Commissioner access is required.'; end if;
  select * into v_week from public.weeks where id=p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if p_dance_id is not null then
    select * into v_dance from public.dances where id=p_dance_id and week_id=p_week_id for update;
    if not found then raise exception 'Dance not found in this week.'; end if;
  end if;
  p_scores_only:=coalesce(p_scores_only,false);
  if v_week.is_complete and not (
    (p_scores_only and p_dance_id is not null) or
    (p_dance_id is null and p_kind='performance' and not p_scores_only)
  ) then raise exception 'Use the Week Ledger to correct a completed week.'; end if;
  if p_scores_only and (p_dance_id is null or v_dance.kind<>'competitive') then
    raise exception 'Only an existing competitive dance supports score-only edits.'; end if;
  if p_scores_only then p_kind:=v_dance.kind; end if;
  if p_kind is null or p_kind not in ('competitive','performance') then raise exception 'Choose a valid dance kind.'; end if;
  if p_kind='competitive' and (case when p_scores_only then v_dance.partnership_id else p_partnership_id end) is null then
    raise exception 'A competitive dance needs a couple.'; end if;
  if p_kind='performance' and p_partnership_id is not null then raise exception 'A performance cannot have a competing couple.'; end if;
  if not p_scores_only then
    if p_kind='performance' and nullif(btrim(p_dance_type),'') is not null then
      raise exception 'Use the optional free-text performance style, not the competitive catalog field.';
    end if;
    if nullif(btrim(p_song_title),'') is null and nullif(btrim(p_song_artist),'') is not null then
      raise exception 'Enter a song title before the artist.';
    end if;
    if p_details is not null and jsonb_typeof(p_details)<>'object' then raise exception 'Dance details must be an object.'; end if;
  end if;
  if jsonb_typeof(p_judge_scores) is distinct from 'array' then raise exception 'Judge scores must be a list.'; end if;
  if p_kind='performance' and jsonb_array_length(p_judge_scores)>0 then raise exception 'A performance cannot have judge scores.'; end if;
  if cardinality(v_cast_ids)<>(select count(distinct member_id) from unnest(v_cast_ids) m(member_id))
    or exists(select 1 from unnest(v_cast_ids) m(member_id) where member_id is null) then
    raise exception 'Choose each cast member once.';
  end if;
  v_expected_judges:=array['Carrie Ann','Derek','Bruno']::text[];
  if nullif(btrim(v_week.guest_judge_name),'') is not null then
    v_expected_judges:=array_append(v_expected_judges,v_week.guest_judge_name);
  end if;
  for v_score in select item from jsonb_array_elements(p_judge_scores) scores(item) loop
    v_judge_name:=v_score->>'judge_name';
    if v_judge_name is null or not(v_judge_name=any(v_expected_judges)) then raise exception 'Unrecognized judge.'; end if;
    if coalesce(v_score->>'score','') !~ '^(10|[0-9])$' then raise exception 'Each judge score must be a whole number from 0 to 10.'; end if;
  end loop;
  if jsonb_array_length(p_judge_scores)<>(select count(distinct item->>'judge_name') from jsonb_array_elements(p_judge_scores) scores(item)) then
    raise exception 'Each judge can score a dance only once.';
  end if;
  old_format:=coalesce(current_setting('mirrorball.song_input_format',true),'');
  perform set_config('mirrorball.song_input_format','split',true);
  if p_dance_id is null then
    insert into public.dances(week_id,kind,partnership_id,name,dance_type,song_title,song_artist,sort_order)
    values(p_week_id,p_kind,p_partnership_id,nullif(btrim(p_name),''),nullif(btrim(p_dance_type),''),
      nullif(btrim(p_song_title),''),nullif(btrim(p_song_artist),''),
      coalesce((select max(sort_order)+1 from public.dances where week_id=p_week_id),1))
    returning id into v_dance_id;
  else
    v_dance_id:=p_dance_id;
    if not p_scores_only then
      update public.dances set kind=p_kind,partnership_id=p_partnership_id,name=nullif(btrim(p_name),''),
        dance_type=nullif(btrim(p_dance_type),''),song_title=nullif(btrim(p_song_title),''),
        song_artist=nullif(btrim(p_song_artist),'') where id=v_dance_id;
    end if;
  end if;
  if not p_scores_only and p_details is not null then
    update public.dances set
      performance_type=case when p_kind<>'performance' then null
        when p_details ? 'performance_type' then nullif(btrim(p_details->>'performance_type'),'') else performance_type end,
      choreography=case when p_kind<>'performance' then null
        when p_details ? 'choreography' then nullif(btrim(p_details->>'choreography'),'') else choreography end,
      airing_night=case when p_details ? 'airing_night' then nullif(p_details->>'airing_night','')::smallint else airing_night end
    where id=v_dance_id;
  end if;
  delete from public.dance_judge_scores where dance_id=v_dance_id;
  insert into public.dance_judge_scores(dance_id,judge_name,score)
    select v_dance_id,item->>'judge_name',(item->>'score')::integer from jsonb_array_elements(p_judge_scores) scores(item);
  if not p_scores_only then
    delete from public.dance_appearances where dance_id=v_dance_id;
    insert into public.dance_appearances(dance_id,cast_member_id) select v_dance_id,member_id from unnest(v_cast_ids) m(member_id);
  end if;
  perform set_config('mirrorball.song_input_format',old_format,true);
  return v_dance_id;
exception when others then
  if old_format is not null then perform set_config('mirrorball.song_input_format',old_format,true); end if;
  raise;
end $$;
revoke all on function public.save_dance_atomic_v2(uuid,uuid,text,uuid,text,text,text,text,jsonb,uuid[],boolean,jsonb) from public,anon;
grant execute on function public.save_dance_atomic_v2(uuid,uuid,text,uuid,text,text,text,text,jsonb,uuid[],boolean,jsonb) to authenticated;

-- A single expanded signature avoids ambiguous PostgREST overloads. All old
-- positional/named arguments still work; new callers may omit p_song entirely.
drop function if exists public.save_dance_atomic(uuid,uuid,text,uuid,text,text,text,jsonb,uuid[],boolean);
create or replace function public.save_dance_atomic(
  p_week_id uuid,p_dance_id uuid,p_kind text,p_partnership_id uuid,
  p_name text,p_dance_type text,p_song text default null,p_judge_scores jsonb default '[]'::jsonb,
  p_cast_member_ids uuid[] default '{}'::uuid[],p_scores_only boolean default false,
  p_song_title text default null,p_song_artist text default null
)
returns uuid language plpgsql security invoker set search_path='' as $$
declare result uuid; legacy boolean;
begin
  legacy:=p_song is not null and p_song_title is null and p_song_artist is null;
  result:=public.save_dance_atomic_v2(p_week_id,p_dance_id,p_kind,p_partnership_id,p_name,p_dance_type,
    case when legacy then public.dance_song_part(p_song,1) else p_song_title end,
    case when legacy then public.dance_song_part(p_song,2) else p_song_artist end,
    p_judge_scores,p_cast_member_ids,p_scores_only);
  if legacy then perform public.log_legacy_song_use('save_dance_atomic'); end if;
  return result;
end $$;
revoke all on function public.save_dance_atomic(uuid,uuid,text,uuid,text,text,text,jsonb,uuid[],boolean,text,text) from public,anon;
grant execute on function public.save_dance_atomic(uuid,uuid,text,uuid,text,text,text,jsonb,uuid[],boolean,text,text) to authenticated;
-- The legacy parser is used only by these compatibility adapters.
revoke all on function public.dance_song_part(text,integer) from public,anon;
grant execute on function public.dance_song_part(text,integer) to authenticated,service_role;

create or replace function public.update_performance_dance_details(p_dance_id uuid,p_song text,p_choreography text)
returns void language plpgsql security invoker set search_path='' as $$
declare old_format text;
begin
  if not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access is required.'; end if;
  old_format:=coalesce(current_setting('mirrorball.song_input_format',true),'');
  perform set_config('mirrorball.song_input_format','split',true);
  update public.dances set song_title=public.dance_song_part(p_song,1),song_artist=public.dance_song_part(p_song,2),
    choreography=nullif(btrim(p_choreography),'') where id=p_dance_id and kind='performance';
  if not found then raise exception 'Performance dance not found.'; end if;
  perform public.log_legacy_song_use('update_performance_dance_details');
  perform set_config('mirrorball.song_input_format',old_format,true);
exception when others then
  if old_format is not null then perform set_config('mirrorball.song_input_format',old_format,true); end if;
  raise;
end $$;

revoke all on function public.update_performance_dance_details(uuid,text,text) from public,anon;
grant execute on function public.update_performance_dance_details(uuid,text,text) to authenticated;

-- Preserve installed automation/order/photo hotfixes; replace only the song
-- write and the catalog helper. Rerunning is supported, unexpected code fails
-- closed rather than silently leaving a dependency behind.
do $$
declare definition text; old_write text:='update public.dances set song=v_song,song_confirmed=n=2 where id=d.id;';
  new_write text:='update public.dances set song_title=case when value is null then null else title end, song_artist=case when value is null then null else artist end, song_confirmed=n=2 where id=d.id;';
begin
  definition:=pg_get_functiondef('public.report_dwts_work_base(text,uuid,jsonb)'::regprocedure);
  if position(old_write in definition)=0 and position(new_write in definition)=0 then
    raise exception 'Unexpected Wiki importer version: review before migrating.';
  end if;
  definition:=replace(definition,old_write,new_write);
  definition:=replace(definition,
    'v_song:=case when value is null then null else title||case when artist is null then '''' else '' by ''||artist end end;','');
  definition:=replace(definition,'dance_type text; v_song text;','dance_type text;');
  definition:=replace(definition,'public.canonical_dance_type(','public.canonical_dance_style(');
  execute definition;
  definition:=pg_get_functiondef('public.ensure_week_competitive_dances(uuid)'::regprocedure);
  definition:=replace(definition,'dance_type,song,sort_order','dance_type,song_title,song_artist,sort_order');
  execute definition;
end $$;

create or replace function public.record_dance_music_match_v2(
  p_dance_id uuid,p_song_title text,p_song_artist text,p_apple_url text,p_spotify_url text,p_status text
)
returns void language plpgsql security invoker set search_path='' as $$
begin
  if p_status not in ('matched','no_match') then raise exception 'Bad match status.'; end if;
  update public.dances set apple_music_url=p_apple_url,spotify_url=p_spotify_url,
    music_match_status=p_status,music_matched_at=now()
  where id=p_dance_id and song_title is not distinct from p_song_title
    and song_artist is not distinct from p_song_artist and coalesce(music_match_status,'')<>'manual';
end $$;
revoke all on function public.record_dance_music_match_v2(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.record_dance_music_match_v2(uuid,text,text,text,text,text) to service_role;
-- Keep the old callback working during Edge Function deployment. A title-only
-- request cannot prove its artist snapshot; do not finalize those matches.
create or replace function public.record_dance_music_match(
  p_dance_id uuid,p_song_title text,p_apple_url text,p_spotify_url text,p_status text
)
returns void language plpgsql security invoker set search_path='' as $$
begin
  perform public.log_legacy_song_use('record_dance_music_match');
  if exists(select 1 from public.dances where id=p_dance_id and song_artist is null) then
    perform public.record_dance_music_match_v2(p_dance_id,p_song_title,null,p_apple_url,p_spotify_url,p_status);
  end if;
end $$;

revoke all on function public.record_dance_music_match(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.record_dance_music_match(uuid,text,text,text,text) to service_role;

create or replace function public.get_song_format_migration_status()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if session_user<>'postgres' and not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access required'; end if;
  return jsonb_build_object(
    'legacy_column_retained',true,
    'legacy_calls',coalesce((select jsonb_agg(to_jsonb(u) order by source) from mirrorball_private.legacy_song_usage u),'[]'::jsonb),
    'dances',(select count(*) from public.dances),
    'mirror_mismatches',(select count(*) from public.dances where song is distinct from
      case when song_title is null then null else song_title||case when song_artist is null then '' else ' by '||song_artist end end)
  );
end $$;
revoke all on function public.get_song_format_migration_status() from public,anon;
grant execute on function public.get_song_format_migration_status() to authenticated;

notify pgrst,'reload schema';
commit;
