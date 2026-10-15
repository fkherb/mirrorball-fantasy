-- add-github-worker-dispatch.sql — applied live 2026-10-16 (Claude).
-- Runs the DWTS automation worker on GitHub Actions instead of the homelab service.
-- pg_cron job "mirrorball-dispatch-worker" calls dwts_dispatch_worker() every minute;
-- when a claim would hand out work, no worker has checked in for 2 minutes and nothing
-- was dispatched in the last 4, it sends a repository_dispatch ("dwts-work") that starts
-- .github/workflows/dwts-worker.yml. The worker runs `dwts-worker.py --until-idle 10`:
-- it claims like the service, keeps polling while a job is due within 10 minutes, then
-- exits. Because a running worker heartbeats every minute, the homelab service and the
-- dispatcher never overlap: while the service runs, the dispatcher reports "worker active".
-- Vault secret: github_dispatch_token (fine-grained token, this repo, Contents: read and write).

-- Read-only mirror of claim_dwts_work's selection (keep in sync with claim_dwts_work):
-- jobs claim skips without rescheduling (get-weeks once tagged, no pending targets, no
-- open window, finished post-show) don't count, so GitHub isn't started for them.
create or replace function public.dwts_work_ready()
returns boolean language plpgsql stable security definer set search_path = '' as $fn$
declare j record; targets jsonb; opening timestamptz;
begin
  if exists (select 1 from public.dwts_automation_weeks a cross join lateral unnest(a.modes) m
             join public.weeks w on w.id = a.week_id
             where a.enabled and not w.is_complete
               and (w.number = 1 or exists (select 1 from public.weeks p where p.number = w.number - 1 and p.is_complete))
               and not exists (select 1 from public.dwts_automation_jobs q where q.week_id = a.week_id and q.mode = m)) then
    return true;
  end if;
  for j in select q.*, w.number, w.is_finale, a.wiki_tag from public.dwts_automation_jobs q
      join public.weeks w on w.id = q.week_id join public.dwts_automation_weeks a on a.week_id = w.id
      where a.enabled and q.mode = any(a.modes) and not w.is_complete
        and (w.number = 1 or exists (select 1 from public.weeks p where p.number = w.number - 1 and p.is_complete))
        and q.next_run_at <= now() and (q.lease_until is null or q.lease_until <= now())
      order by q.next_run_at loop
    if j.mode = 'get-weeks' and j.wiki_tag is not null then continue; end if;
    if j.mode <> 'get-weeks' and j.mode <> 'photos' and j.wiki_tag is null then continue; end if;
    if j.mode = 'post-show' and (j.is_finale or exists (select 1 from public.dances d
        where d.week_id = j.week_id and d.elimination_confirmed and d.elimination_result)) then continue; end if;
    targets := public.dwts_pending_targets(j.week_id, j.mode);
    if j.mode <> 'get-weeks' and jsonb_array_length(targets) = 0 then continue; end if;
    if j.mode in ('photos', 'live-show', 'post-show') then
      opening := public.dwts_window_opening(j.week_id, j.mode, now());
      if opening is null then continue; end if;
    end if;
    if j.mode = 'photos' then
      select photos_not_before into opening from public.dwts_automation_state where id = 1;
      if opening > now() then continue; end if;
      if exists (select 1 from public.dwts_automation_jobs where mode = 'photos' and lease_until > now()) then continue; end if;
    end if;
    return true;
  end loop;
  return false;
end $fn$;
revoke all on function public.dwts_work_ready() from public, anon, authenticated;

create table if not exists public.dwts_dispatch_state (
  id integer primary key default 1 check (id = 1),
  enabled boolean not null default false,
  repository text not null default 'fkherb/mirrorball-fantasy',
  last_dispatch_at timestamptz,
  last_request_id bigint,
  dispatch_count integer not null default 0
);
alter table public.dwts_dispatch_state enable row level security;   -- no policies
insert into public.dwts_dispatch_state(id, enabled) values (1, true) on conflict do nothing;

create or replace function public.dwts_dispatch_worker(p_force boolean default false)
returns text language plpgsql security definer set search_path = '' as $fn$
declare s public.dwts_dispatch_state%rowtype; beat timestamptz; token text; rid bigint;
begin
  select * into s from public.dwts_dispatch_state where id = 1 for update;
  if not found or (not s.enabled and not p_force) then return 'disabled'; end if;
  if not p_force then
    if not public.dwts_work_ready() then return 'no due work'; end if;
    select last_heartbeat_at into beat from public.dwts_automation_state where id = 1;
    if beat > now() - interval '2 minutes' then return 'worker active'; end if;
    if s.last_dispatch_at > now() - interval '4 minutes' then return 'recently dispatched'; end if;
  end if;
  select decrypted_secret into token from vault.decrypted_secrets where name = 'github_dispatch_token';
  if token is null then return 'missing github_dispatch_token'; end if;
  select net.http_post(
    url := 'https://api.github.com/repos/' || s.repository || '/dispatches',
    body := jsonb_build_object('event_type', 'dwts-work'),
    headers := jsonb_build_object('Accept', 'application/vnd.github+json', 'Authorization', 'Bearer ' || token,
      'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'mirrorball-dispatcher', 'Content-Type', 'application/json'),
    timeout_milliseconds := 15000) into rid;
  update public.dwts_dispatch_state set last_dispatch_at = now(), last_request_id = rid,
    dispatch_count = dispatch_count + 1 where id = 1;
  return 'dispatched';
end $fn$;
revoke all on function public.dwts_dispatch_worker(boolean) from public, anon, authenticated;

select cron.schedule('mirrorball-dispatch-worker', '* * * * *', $cron$select public.dwts_dispatch_worker()$cron$);

-- Checks:
--   select public.dwts_work_ready(), public.dwts_dispatch_worker();      -- what it would do now
--   select public.dwts_dispatch_worker(true);                            -- start a run by hand
--   select status_code, content from net._http_response
--     where id = (select last_request_id from public.dwts_dispatch_state); -- 204 = accepted
-- Back to the homelab: update public.dwts_dispatch_state set enabled = false; then start the service.
