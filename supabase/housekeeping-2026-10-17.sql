-- housekeeping-2026-10-17.sql — maintenance pass (Claude). Nothing here changes
-- scoring, roster rules, drafting or any RPC the apps call.
--
-- PART 1 — already applied live on 2026-10-17 (record copy).
--
-- Trigger functions can't be called directly anyway, but the security advisor flags
-- them as callable through /rest/v1/rpc. Triggers keep firing: Postgres only checks
-- EXECUTE when a trigger is created, not when it fires.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as fn
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_type t on t.oid = p.prorettype
    where n.nspname = 'public' and t.typname in ('trigger', 'event_trigger')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.fn);
  end loop;
end $$;

-- Pin search_path on the three trigger functions that didn't set one.
alter function public.prevent_competing_pair_appearance() set search_path = public;
alter function public.prevent_completed_week_edit() set search_path = public;
alter function public.prevent_completed_week_metadata_edit() set search_path = public;

-- Keep successful cron runs for 3 days instead of 14 (the 10-second draft clock alone
-- logs ~8,600 rows a day; job_run_details was 37 MB, over half the database).
create or replace function private.prune_scheduler_logs()
 returns bigint language plpgsql set search_path to ''
as $function$
declare removed bigint;
begin
  delete from cron.job_run_details where end_time is not null and
    ((status = 'succeeded' and end_time < now() - interval '3 days')
     or (status <> 'succeeded' and end_time < now() - interval '30 days'));
  get diagnostics removed = row_count;
  return removed;
end $function$;

-- Indexes for the foreign keys the apps filter on most.
create index if not exists league_roster_assignments_team_idx on public.league_roster_assignments (league_id, fantasy_team_id);
create index if not exists league_roster_assignments_cast_idx on public.league_roster_assignments (cast_member_id);
create index if not exists league_weekly_roster_snapshots_week_idx on public.league_weekly_roster_snapshots (week_id);
create index if not exists league_weekly_roster_snapshots_team_idx on public.league_weekly_roster_snapshots (fantasy_team_id);
create index if not exists league_draft_picks_team_idx on public.league_draft_picks (league_id, fantasy_team_id);
create index if not exists league_trade_offers_awaiting_idx on public.league_trade_offers (awaiting_team_id);
create index if not exists league_trade_offers_initiator_idx on public.league_trade_offers (league_id, initiator_team_id);
create index if not exists league_trade_offers_counterparty_idx on public.league_trade_offers (league_id, counterparty_team_id);
create index if not exists cast_market_predictions_week_idx on public.cast_market_predictions (week_id);


-- PART 2 — for Freddy to run in the Supabase SQL editor (DROP statements need the
-- editor; they time out through the assistant's connection).
begin;

-- Exact duplicate policies (same rule twice under two names).
drop policy if exists "public read players" on public.cast_members;           -- = "public read cast members"
drop policy if exists "commissioner writes rosters" on public.roster_history;  -- = "commissioner writes roster history"
drop policy if exists "commissioner writes scores" on public.score_events;     -- = "commissioner writes score events"

-- Leftovers from the song format migration (finished 2026-10-16): nothing in the
-- apps, website or worker calls log_legacy_song_use any more.
drop function if exists public.log_legacy_song_use(text);
drop table if exists mirrorball_private.legacy_song_usage;

commit;

-- LATER — once ios_min_build is 16 or higher (build 15 still reads these):
--   delete from public.app_config where key in ('feature.dance_videos', 'video_base_url');
