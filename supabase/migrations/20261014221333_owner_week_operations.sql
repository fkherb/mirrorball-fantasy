begin;
set local lock_timeout = '5s';

-- Music callbacks remain SECURITY INVOKER and service-role-only. Grant only
-- the columns they read/write, never blanket writes to dances or scores.
grant select (id, song_title, song_artist, music_match_status) on public.dances to service_role;
grant update (apple_music_url, spotify_url, music_match_status, music_matched_at)
  on public.dances to service_role;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create or replace function public.guest_judge_default_image(p_name text)
returns text language plpgsql immutable security invoker set search_path = '' as $$
declare name text := nullif(regexp_replace(btrim(p_name),'\s+',' ','g'),'');
begin
  if name is null then return null; end if;
  if length(name)>100 or name ~ '[/\\?#%]' or name like '%..%' then
    raise exception 'Guest name contains unsupported filename characters';
  end if;
  return 'Images/Guests/' || name || '.jpeg';
end $$;
revoke all on function public.guest_judge_default_image(text) from public, anon;
grant execute on function public.guest_judge_default_image(text) to authenticated, service_role;

create or replace function public.validate_week_judge_display()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare expected text[] := array['Carrie Ann','Derek','Bruno']; default_image text;
begin
  new.guest_judge_name := nullif(regexp_replace(btrim(new.guest_judge_name),'\s+',' ','g'),'');
  default_image := public.guest_judge_default_image(new.guest_judge_name);
  if new.guest_judge_name is not null then expected := expected || array[new.guest_judge_name]; end if;
  if tg_op='UPDATE' and new.guest_judge_name is distinct from old.guest_judge_name then
    if new.judge_order is not distinct from old.judge_order then new.judge_order := null; end if;
    if new.guest_judge_image_path is not distinct from old.guest_judge_image_path then
      new.guest_judge_image_path := null;
      new.guest_judge_avatar_frame := '{}'::jsonb;
    end if;
  end if;
  new.judge_order := coalesce(new.judge_order,expected);
  if cardinality(new.judge_order)<>cardinality(expected) or array_position(new.judge_order,null) is not null
    or not new.judge_order @> expected or not new.judge_order <@ expected then
    raise exception 'Judge order must contain every judge exactly once';
  end if;
  if new.guest_judge_name is null then
    new.guest_judge_image_path := null; new.guest_judge_avatar_frame := '{}'::jsonb;
  else
    new.guest_judge_image_path := coalesce(nullif(btrim(new.guest_judge_image_path),''),default_image);
    if new.guest_judge_image_path !~ '^Images/Guests/[^/\\]+\.(jpeg|jpg|png|webp)$'
      or new.guest_judge_image_path like '%..%' then raise exception 'Choose a photo in Images/Guests'; end if;
    if jsonb_typeof(new.guest_judge_avatar_frame) is distinct from 'object'
      or coalesce((new.guest_judge_avatar_frame->>'x')::numeric,50) not between 0 and 100
      or coalesce((new.guest_judge_avatar_frame->>'y')::numeric,50) not between 0 and 100
      or coalesce((new.guest_judge_avatar_frame->>'zoom')::numeric,1) not between 1 and 3 then
      raise exception 'Invalid guest portrait framing';
    end if;
  end if;
  return new;
end $$;
-- Set existing paths before enabling validation of the new directory.
update public.weeks set guest_judge_image_path=public.guest_judge_default_image(guest_judge_name)
where guest_judge_name in ('Joe Buck','Kym Johnson');
drop trigger if exists validate_week_judge_display on public.weeks;
create trigger validate_week_judge_display before insert or update of guest_judge_name,judge_order,
  guest_judge_image_path,guest_judge_avatar_frame on public.weeks
for each row execute function public.validate_week_judge_display();

create or replace function public.save_week_with_owner_controls(p_setup jsonb,p_automation jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if auth.uid() is null or not coalesce(public.is_platform_admin(),false) then
    raise exception 'Platform-owner access required'; end if;
  perform public.save_week_with_automation(p_setup,p_automation);
  update public.weeks set
    guest_judge_image_path=nullif(p_setup->>'p_guest_judge_image_path',''),
    guest_judge_avatar_frame=coalesce(p_setup->'p_guest_judge_avatar_frame','{}'::jsonb)
  where id=(p_setup->>'p_week_id')::uuid;
end $$;
revoke all on function public.save_week_with_owner_controls(jsonb,jsonb) from public,anon;
grant execute on function public.save_week_with_owner_controls(jsonb,jsonb) to authenticated;

alter table public.market_prediction_sync_state
  add column if not exists last_request_id bigint,
  add column if not exists last_requested_at timestamptz,
  add column if not exists last_forced_at timestamptz,
  add column if not exists last_attempt_at timestamptz,
  add column if not exists last_completed_at timestamptz,
  add column if not exists last_error text,
  add column if not exists last_weekly_event text,
  add column if not exists last_weekly_count integer;

create or replace function private.next_prediction_week_id()
returns uuid language sql stable security invoker set search_path = '' as $$
  select id from public.weeks
  where (coalesce(second_air_date,air_date)+
    case when second_air_date is null then air_end_time else coalesce(second_air_end_time,'22:00'::time) end)
    > now() at time zone 'America/New_York'
  order by number limit 1;
$$;

create or replace function private.enqueue_prediction_refresh(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.market_prediction_sync_state%rowtype; endpoint text; secret text; request_id bigint;
begin
  select * into s from public.market_prediction_sync_state where id=1 for update;
  if (case when p_force then s.last_forced_at else s.last_requested_at end) > now()-interval '60 seconds' then
    return jsonb_build_object('queued',false,'message','A refresh was recently requested. Check status shortly.');
  end if;
  select decrypted_secret into endpoint from vault.decrypted_secrets where name='market_prediction_sync_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name='market_prediction_sync_secret';
  if endpoint is null or secret is null then
    update public.market_prediction_sync_state set last_error='Prediction sync is not configured' where id=1;
    return jsonb_build_object('queued',false,'message','Prediction sync is not configured');
  end if;
  select net.http_post(url:=endpoint,headers:=jsonb_build_object('Content-Type','application/json',
    'Authorization','Bearer '||secret),body:=jsonb_build_object('force',p_force),timeout_milliseconds:=120000)
    into request_id;
  update public.market_prediction_sync_state set last_request_id=request_id,last_requested_at=now(),
    last_forced_at=case when p_force then now() else last_forced_at end where id=1;
  return jsonb_build_object('queued',true,'message','Refresh requested. Check status in a few seconds.');
end $$;

create or replace function private.owner_request_prediction_refresh(p_week_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not coalesce(public.is_platform_admin(),false) then
    raise exception 'Platform-owner access required'; end if;
  if not exists(select 1 from public.weeks where id=p_week_id and not is_complete and not is_finale
    and elimination_predictions_enabled and id=private.next_prediction_week_id()) then
    raise exception 'Enable predictions for the next airing week first'; end if;
  return private.enqueue_prediction_refresh(true);
end $$;
create or replace function public.request_week_prediction_refresh(p_week_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.owner_request_prediction_refresh(p_week_id);
$$;

create or replace function private.owner_prediction_status(p_week_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w public.weeks%rowtype; s public.market_prediction_sync_state%rowtype;
  response net._http_response%rowtype; day_after date; ticker text; quote_count integer; last_quote timestamptz;
begin
  if auth.uid() is null or not coalesce(public.is_platform_admin(),false) then
    raise exception 'Platform-owner access required'; end if;
  select * into w from public.weeks where id=p_week_id;
  if not found then raise exception 'Week not found'; end if;
  select * into s from public.market_prediction_sync_state where id=1;
  select * into response from net._http_response where id=s.last_request_id;
  day_after:=coalesce(w.second_air_date,w.air_date)+1;
  ticker:='KXDWTSELIMINATION-'||upper(to_char(day_after,'YYMONDD'));
  select count(*),max(fetched_at) into quote_count,last_quote from public.cast_market_predictions
    where week_id=w.id and event_ticker=ticker and market_status in ('active','open') and percent is not null;
  return jsonb_build_object('event_ticker',ticker,'enabled',w.elimination_predictions_enabled,
    'can_refresh',not w.is_complete and not w.is_finale and w.elimination_predictions_enabled
      and w.id=private.next_prediction_week_id(),
    'quote_count',quote_count,'last_quote_at',last_quote,'last_sync_at',s.refreshed_at,
    'last_requested_at',s.last_requested_at,'last_weekly_event',s.last_weekly_event,
    'pending',s.last_requested_at>now()-interval '2 minutes' and response.id is null,
    'error',case when response.timed_out then 'Prediction request timed out'
      when response.status_code>=400 then 'Prediction service returned HTTP '||response.status_code::text
      when response.error_msg is not null then 'Prediction request could not reach the service'
      when s.last_requested_at<now()-interval '2 minutes' and response.id is null
        and (s.last_completed_at is null or s.last_completed_at<s.last_requested_at)
        then 'No response received from the last prediction request'
      else s.last_error end);
end $$;
create or replace function public.get_week_prediction_status(p_week_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.owner_prediction_status(p_week_id);
$$;

create or replace function private.refresh_predictions_on_week_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.elimination_predictions_enabled and not new.is_complete and not new.is_finale
    and new.id=private.next_prediction_week_id() then
    if tg_op='INSERT' then perform private.enqueue_prediction_refresh(true);
    elsif not old.elimination_predictions_enabled or new.air_date is distinct from old.air_date
      or new.second_air_date is distinct from old.second_air_date or new.is_finale is distinct from old.is_finale then
      perform private.enqueue_prediction_refresh(true);
    end if;
  end if;
  return new;
end $$;
create trigger refresh_predictions_on_week_change after insert or update of elimination_predictions_enabled,
  air_date,second_air_date,is_finale on public.weeks for each row
execute function private.refresh_predictions_on_week_change();

-- Only the two owner-checked entry points are available to signed-in clients.
revoke all on function private.next_prediction_week_id(),private.enqueue_prediction_refresh(boolean),
  private.owner_request_prediction_refresh(uuid),private.owner_prediction_status(uuid),
  private.refresh_predictions_on_week_change() from public,anon,authenticated;
grant execute on function private.owner_request_prediction_refresh(uuid),private.owner_prediction_status(uuid) to authenticated;
revoke all on function public.request_week_prediction_refresh(uuid),public.get_week_prediction_status(uuid) from public,anon;
grant execute on function public.request_week_prediction_refresh(uuid),public.get_week_prediction_status(uuid) to authenticated;
select cron.schedule('mirrorball-market-predictions','*/5 * * * *',
  $$select private.enqueue_prediction_refresh(false);$$);

-- Only scheduler diagnostics are pruned. Never league history, market history,
-- dance confirmations, automation results or source-photo receipts.
create or replace function private.prune_scheduler_logs()
returns bigint language plpgsql security invoker set search_path = '' as $$
declare removed bigint;
begin
  delete from cron.job_run_details where end_time is not null and
    ((status='succeeded' and end_time<now()-interval '14 days')
     or (status<>'succeeded' and end_time<now()-interval '30 days'));
  get diagnostics removed=row_count;
  return removed;
end $$;
revoke all on function private.prune_scheduler_logs() from public,anon,authenticated,service_role;
select cron.schedule('mirrorball-prune-scheduler-logs','23 8 * * *',
  $$select private.prune_scheduler_logs();$$);
notify pgrst,'reload schema';
commit;
