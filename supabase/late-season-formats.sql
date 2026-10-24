-- Late-season formats (2026-10-24). Kept here as the record; see claude/late-season-formats-plan.md.
-- Already applied: late_season_formats_tables (weeks.formats/rounds, dances.round/round_label/team_name/bonus_kind,
-- dance_couples, week_immunities, dance_styles.specialty, Lindy Hop + Hustle) and the elimination_picks second pick.

-- Late-season formats: functions (second performances, instant dances, team dances,
-- dance-offs, relays, marathons, immunity). The automation only ever sees round 1.

drop index if exists public.one_competitive_dance_per_pair_per_week;

-- Automation targets: round 1 only, so second performances stay manual for now.
create or replace function public.dwts_pending_targets(p_week uuid, p_mode text)
 returns jsonb language sql stable security definer set search_path to '' as $function$
  select coalesce(jsonb_agg(jsonb_build_object('dance_id',d.id,'partnership_id',p.id,
    'star_name',s.name,
    'pro_name', case when p_mode = 'photos' then r.name else coalesce(f.name, r.name) end)
    order by d.sort_order,d.id),'[]'::jsonb)
  from public.dances d join public.partnerships p on p.id=d.partnership_id
    join public.cast_members s on s.id=p.star_id join public.cast_members r on r.id=p.pro_id
    left join public.dance_cast_changes ch on ch.dance_id=d.id and ch.cast_member_id=p.pro_id
    left join public.cast_members f on f.id=ch.replacement_cast_member_id
  where d.week_id=p_week and d.kind='competitive' and coalesce(d.round,1)=1 and case p_mode
    when 'pre-show' then not d.dance_type_confirmed or not d.song_confirmed
    when 'live-show' then not d.scores_confirmed
    when 'post-show' then not d.elimination_confirmed
    when 'photos' then not d.photos_uploaded else false end;
$function$;

-- Team dances are judged too.
create or replace function public.dance_expected_judges(p_dance_id uuid)
 returns text[] language sql stable security definer set search_path to '' as $function$
  select public.regular_judge_names()::text[] ||
    case when nullif(btrim(w.guest_judge_name), '') is null then '{}'::text[]
         else array[btrim(w.guest_judge_name)] end
  from public.dances d join public.weeks w on w.id = d.week_id
  where d.id = p_dance_id and d.kind in ('competitive', 'team');
$function$;

-- A couple being judged (its own dance, or a team dance / bonus round it is in) never earns an appearance for it.
create or replace function public.prevent_competing_pair_appearance()
 returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if exists (
    select 1 from public.dances as d
    join public.partnerships as pair on pair.id = d.partnership_id
    where d.id = new.dance_id and d.kind = 'competitive'
      and new.cast_member_id in (pair.star_id, pair.pro_id)
  ) or exists (
    select 1 from public.dance_couples dc
    join public.partnerships as pair on pair.id = dc.partnership_id
    where dc.dance_id = new.dance_id and new.cast_member_id in (pair.star_id, pair.pro_id)
  ) then
    raise exception 'The competing couple cannot be added as a cast appearance.';
  end if;
  return new;
end;
$function$;

-- Week Settings → Special formats. p_rounds: [{"number":1},{"number":2,"label":"Instant Dance"}].
-- Creates a round 2 / 3 dance for every couple dancing round 1, removes unscored extra rounds
-- that are no longer wanted, and applies each round's label.
create or replace function public.set_week_formats(p_week_id uuid, p_formats text[], p_rounds jsonb)
 returns void language plpgsql security definer set search_path to '' as $function$
declare w public.weeks%rowtype; max_round int; r jsonb; n int; lbl text;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  select * into w from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if w.is_complete then raise exception 'Completed weeks are locked.'; end if;
  if jsonb_typeof(coalesce(p_rounds, '[]'::jsonb)) <> 'array' then raise exception 'Rounds must be a list.'; end if;
  max_round := greatest(1, coalesce((select max((x->>'number')::int) from jsonb_array_elements(coalesce(p_rounds,'[]'::jsonb)) x), 1));
  if max_round > 3 then raise exception 'At most three rounds.'; end if;

  update public.weeks set formats = coalesce(p_formats, '{}'), rounds = coalesce(p_rounds, '[]'::jsonb) where id = p_week_id;

  -- Extra rounds no longer wanted (only if nothing was entered on them).
  if exists (select 1 from public.dances d where d.week_id = p_week_id and d.kind = 'competitive' and d.round > max_round
             and exists (select 1 from public.dance_judge_scores s where s.dance_id = d.id)) then
    raise exception 'A later round already has scores; clear them first.';
  end if;
  delete from public.dances d where d.week_id = p_week_id and d.kind = 'competitive' and d.round > max_round;

  for n in 2..max_round loop
    insert into public.dances(week_id, kind, partnership_id, round, sort_order)
    select p_week_id, 'competitive', d.partnership_id, n,
           (select coalesce(max(sort_order),0) from public.dances where week_id = p_week_id) + row_number() over (order by d.sort_order)::int
      from public.dances d
     where d.week_id = p_week_id and d.kind = 'competitive' and coalesce(d.round,1) = 1
       and not exists (select 1 from public.dances e where e.week_id = p_week_id and e.kind = 'competitive'
                        and e.partnership_id = d.partnership_id and e.round = n);
  end loop;

  for n in 1..max_round loop
    select nullif(btrim(x->>'label'), '') into lbl from jsonb_array_elements(coalesce(p_rounds,'[]'::jsonb)) x
     where (x->>'number')::int = n limit 1;
    update public.dances set round_label = lbl
     where week_id = p_week_id and kind = 'competitive' and coalesce(round,1) = n and round_label is distinct from lbl;
    lbl := null;
  end loop;
end $function$;

-- Team dances and bonus rounds (dance-off, relay, marathon), with their couples.
-- p_couples: [{"partnership_id": "...", "result": "winner"|"loser"|null, "points": 3|null}].
-- p_judge_scores (team dances only): [{"judge_name": "...", "score": 9}]. Pass p_kind null with
-- an existing p_dance_id to delete it.
create or replace function public.save_special_dance(
  p_week_id uuid, p_dance_id uuid, p_kind text, p_bonus_kind text, p_team_name text, p_name text,
  p_dance_type text, p_song_title text, p_song_artist text, p_couples jsonb, p_judge_scores jsonb,
  p_cast_member_ids uuid[], p_airing_night smallint default null)
 returns uuid language plpgsql security definer set search_path to '' as $function$
declare w public.weeks%rowtype; v_id uuid; c jsonb; expected text[]; s jsonb; old_format text;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  select * into w from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if w.is_complete then raise exception 'Completed weeks are locked.'; end if;
  if p_dance_id is not null and not exists (select 1 from public.dances where id = p_dance_id and week_id = p_week_id and kind in ('team','bonus')) then
    raise exception 'Dance not found in this week.';
  end if;
  if p_kind is null then
    if p_dance_id is not null then delete from public.dances where id = p_dance_id; end if;
    return null;
  end if;
  if p_kind not in ('team', 'bonus') then raise exception 'Choose team or bonus.'; end if;
  if p_kind = 'bonus' and coalesce(p_bonus_kind,'') not in ('dance_off', 'relay', 'marathon') then raise exception 'Choose dance-off, relay or marathon.'; end if;
  if p_kind = 'team' and nullif(btrim(p_team_name), '') is null then raise exception 'Enter the team name.'; end if;
  if jsonb_typeof(coalesce(p_couples, '[]'::jsonb)) <> 'array' then raise exception 'Couples must be a list.'; end if;
  if (select count(*) from jsonb_array_elements(coalesce(p_couples,'[]'::jsonb)) x where x->>'result' = 'winner') > 1 then
    raise exception 'Only one winner.';
  end if;
  if p_kind = 'bonus' and p_bonus_kind <> 'marathon' and jsonb_array_length(coalesce(p_couples,'[]'::jsonb)) > 2 then
    raise exception 'A match has two couples.';
  end if;
  if p_kind = 'bonus' and jsonb_array_length(coalesce(p_judge_scores,'[]'::jsonb)) > 0 then
    raise exception 'Bonus rounds have no judges'' scores.';
  end if;

  old_format := coalesce(current_setting('mirrorball.song_input_format', true), '');
  perform set_config('mirrorball.song_input_format', 'split', true);
  if p_dance_id is null then
    insert into public.dances(week_id, kind, bonus_kind, team_name, name, dance_type, song_title, song_artist, airing_night, sort_order)
    values (p_week_id, p_kind, case when p_kind = 'bonus' then p_bonus_kind end,
            case when p_kind = 'team' then btrim(p_team_name) end, nullif(btrim(p_name),''),
            nullif(btrim(p_dance_type),''), nullif(btrim(p_song_title),''), nullif(btrim(p_song_artist),''), p_airing_night,
            coalesce((select max(sort_order) + 1 from public.dances where week_id = p_week_id), 1))
    returning id into v_id;
  else
    v_id := p_dance_id;
    update public.dances set kind = p_kind, bonus_kind = case when p_kind = 'bonus' then p_bonus_kind end,
      team_name = case when p_kind = 'team' then btrim(p_team_name) end, name = nullif(btrim(p_name),''),
      dance_type = nullif(btrim(p_dance_type),''), song_title = nullif(btrim(p_song_title),''),
      song_artist = nullif(btrim(p_song_artist),''), airing_night = coalesce(p_airing_night, airing_night)
    where id = v_id;
  end if;
  perform set_config('mirrorball.song_input_format', old_format, true);

  delete from public.dance_couples where dance_id = v_id;
  insert into public.dance_couples(dance_id, partnership_id, result, points)
  select v_id, (x->>'partnership_id')::uuid, nullif(x->>'result',''),
         case when p_bonus_kind = 'marathon' and p_kind = 'bonus' then nullif(x->>'points','')::int end
    from jsonb_array_elements(coalesce(p_couples,'[]'::jsonb)) x;

  expected := public.regular_judge_names()::text[];
  if nullif(btrim(w.guest_judge_name), '') is not null then expected := array_append(expected, btrim(w.guest_judge_name)); end if;
  for s in select * from jsonb_array_elements(coalesce(p_judge_scores,'[]'::jsonb)) loop
    if not ((s->>'judge_name') = any(expected)) then raise exception 'Unrecognized judge.'; end if;
    if coalesce(s->>'score','') !~ '^(10|[0-9])$' then raise exception 'Each judge score must be a whole number from 0 to 10.'; end if;
  end loop;
  delete from public.dance_judge_scores where dance_id = v_id;
  insert into public.dance_judge_scores(dance_id, judge_name, score)
  select v_id, x->>'judge_name', (x->>'score')::int from jsonb_array_elements(coalesce(p_judge_scores,'[]'::jsonb)) x;

  delete from public.dance_appearances where dance_id = v_id;
  insert into public.dance_appearances(dance_id, cast_member_id)
  select v_id, m from unnest(coalesce(p_cast_member_ids, '{}'::uuid[])) m;
  return v_id;
end $function$;

-- Immunity: p_points null removes it.
create or replace function public.set_week_immunity(p_week_id uuid, p_partnership_id uuid, p_points integer, p_note text)
 returns void language plpgsql security definer set search_path to '' as $function$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if exists (select 1 from public.weeks where id = p_week_id and is_complete) then raise exception 'Completed weeks are locked.'; end if;
  if p_points is null then
    delete from public.week_immunities where week_id = p_week_id and partnership_id = p_partnership_id;
  else
    insert into public.week_immunities(week_id, partnership_id, points, note)
    values (p_week_id, p_partnership_id, p_points, nullif(btrim(p_note), ''))
    on conflict (week_id, partnership_id) do update set points = excluded.points, note = excluded.note;
  end if;
end $function$;

revoke execute on function public.set_week_formats(uuid, text[], jsonb) from public, anon;
revoke execute on function public.save_special_dance(uuid, uuid, text, text, text, text, text, text, text, jsonb, jsonb, uuid[], smallint) from public, anon;
revoke execute on function public.set_week_immunity(uuid, uuid, integer, text) from public, anon;
grant execute on function public.set_week_formats(uuid, text[], jsonb) to authenticated;
grant execute on function public.save_special_dance(uuid, uuid, text, text, text, text, text, text, text, jsonb, jsonb, uuid[], smallint) to authenticated;
grant execute on function public.set_week_immunity(uuid, uuid, integer, text) to authenticated;

-- Pick your paddle for dance-offs and relays: the couple you think did better. Final (insert only).
create table if not exists public.dance_match_picks (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  dance_id uuid not null references public.dances on delete cascade,
  partnership_id uuid not null references public.partnerships on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, dance_id)
);
alter table public.dance_match_picks enable row level security;
create policy "own match picks" on public.dance_match_picks for select using (user_id = auth.uid());
create policy "insert own match pick" on public.dance_match_picks for insert with check (
  user_id = auth.uid()
  and exists (select 1 from public.dance_couples dc join public.dances d on d.id = dc.dance_id
              where dc.dance_id = dance_match_picks.dance_id and dc.partnership_id = dance_match_picks.partnership_id
                and d.kind = 'bonus' and d.bonus_kind in ('dance_off', 'relay')));
revoke all on public.dance_match_picks from anon;
grant select, insert on public.dance_match_picks to authenticated;

-- get_league_scores: rounds, team dances, bonus rounds and immunity
CREATE OR REPLACE FUNCTION public.get_league_scores(p_league_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- Server copy of scoreLeague() (scoring.js / Scoring.swift), read-only, for shadow
-- comparison (audit F2 step B). Returns {"teams": {team_id: points}, "error": null|"missing_snapshot"}.
-- Injured / suspended dancers (dance_cast_changes) follow Scoring.competitiveAwards.
-- Late-season formats: every round a couple dances pays its judges' total; a team dance pays its
-- total to every couple on the team (dance_couples); a dance-off / relay win pays 3, a marathon
-- DWTS's points, immunity what was entered (week_immunities). Couples in a team dance or bonus
-- round earn no appearance for it.
declare
  l record;
  is_original boolean;
  starts_after int;
  missing boolean;
  totals jsonb;
begin
  if not (public.is_league_member(p_league_id) or public.is_platform_admin()) then
    raise exception 'Not a member of this league' using errcode = '42501';
  end if;

  select * into l from public.leagues where id = p_league_id;
  if not found then
    raise exception 'League not found' using errcode = 'P0002';
  end if;
  is_original := l.slug = 'dwts-fantasy-league' or l.id = '00000000-0000-4000-8000-000000000001'::uuid;
  starts_after := coalesce(l.scoring_starts_after_week, 0);

  if l.status <> 'active' then
    select coalesce(jsonb_object_agg(t.id, 0), '{}'::jsonb) into totals
      from public.fantasy_teams t where t.league_id = p_league_id;
    return jsonb_build_object('teams', totals, 'error', null);
  end if;

  select exists (
    select 1 from public.weeks w
     where w.is_complete and w.number > starts_after
       and not exists (select 1 from public.league_weekly_roster_snapshots s
                        where s.league_id = p_league_id and s.week_id = w.id)
  ) into missing;

  if not missing then
    select exists (
      select 1
        from public.dances d
        join public.weeks w on w.id = d.week_id and w.is_complete and w.number > starts_after
        join public.partnerships p on p.id = d.partnership_id
        cross join lateral (values (p.star_id), (p.pro_id)) c(cast_id)
       where d.kind = 'competitive' and c.cast_id is not null
         and not exists (select 1 from public.league_weekly_roster_snapshots s
                          where s.league_id = p_league_id and s.week_id = w.id and s.cast_member_id = c.cast_id)
      union all
      select 1
        from public.dance_cast_changes ch
        join public.dances d on d.id = ch.dance_id and d.kind = 'competitive' and d.partnership_id is not null
        join public.weeks w on w.id = d.week_id and w.is_complete and w.number > starts_after
       where ch.replacement_cast_member_id is not null
         and not exists (select 1 from public.league_weekly_roster_snapshots s
                          where s.league_id = p_league_id and s.week_id = w.id
                            and s.cast_member_id = ch.replacement_cast_member_id)
      union all
      select 1
        from public.dance_appearances a
        join public.dances d on d.id = a.dance_id
        join public.weeks w on w.id = d.week_id and w.is_complete and w.number > starts_after
        join public.cast_members cm on cm.id = a.cast_member_id
       where not exists (select 1 from public.league_weekly_roster_snapshots s
                          where s.league_id = p_league_id and s.week_id = w.id and s.cast_member_id = a.cast_member_id)
    ) into missing;
  end if;

  if missing then
    return jsonb_build_object('teams', null, 'error', 'missing_snapshot');
  end if;

  with rates as (
    select r.name, coalesce(r.appearance_points, 0) as pts from public.roles r
  ),
  dance_totals as (
    select ds.dance_id, sum(ds.score)::int as total from public.dance_judge_scores ds group by ds.dance_id
  ),
  comp as (
    select d.id, d.week_id, p.star_id, p.pro_id, coalesce(dt.total, 0) as total
      from public.dances d
      join public.weeks w on w.id = d.week_id and w.is_complete and w.number > starts_after
      join public.partnerships p on p.id = d.partnership_id
      left join dance_totals dt on dt.dance_id = d.id
     where d.kind = 'competitive'
  ),
  own as (
    select distinct c.week_id, x.cast_id
      from comp c cross join lateral (values (c.star_id), (c.pro_id)) x(cast_id)
     where x.cast_id is not null
       and not exists (select 1 from public.dance_cast_changes ch where ch.dance_id = c.id and ch.cast_member_id = x.cast_id)
  ),
  -- Team dances and bonus rounds: each couple in them (dance_couples).
  special as (
    select d.id as dance_id, d.week_id, p.star_id, p.pro_id,
           case when d.kind = 'team' then coalesce(dt.total, 0)
                when d.bonus_kind = 'marathon' then coalesce(dc.points, 0)
                when dc.result = 'winner' then 3 else 0 end as pts
      from public.dances d
      join public.weeks w on w.id = d.week_id and w.is_complete and w.number > starts_after
      join public.dance_couples dc on dc.dance_id = d.id
      join public.partnerships p on p.id = dc.partnership_id
      left join dance_totals dt on dt.dance_id = d.id
     where d.kind in ('team', 'bonus')
  ),
  awards as (
    select c.week_id, x.cast_id,
           case when ch.id is null then c.total
                when ch.reason = 'suspended' then 0
                when x.cast_id = c.pro_id then (c.total + 1) / 2
                else c.total end as pts
      from comp c
      cross join lateral (values (c.star_id), (c.pro_id)) x(cast_id)
      left join public.dance_cast_changes ch on ch.dance_id = c.id and ch.cast_member_id = x.cast_id
     where x.cast_id is not null
    union all
    select c.week_id, ch.replacement_cast_member_id,
           case when exists (select 1 from own o where o.week_id = c.week_id and o.cast_id = ch.replacement_cast_member_id)
                then (c.total + 1) / 2 else c.total end
      from comp c
      join public.dance_cast_changes ch on ch.dance_id = c.id
     where ch.replacement_cast_member_id is not null
    union all
    select sp.week_id, x.cast_id, sp.pts
      from special sp cross join lateral (values (sp.star_id), (sp.pro_id)) x(cast_id)
     where x.cast_id is not null
    union all
    select im.week_id, x.cast_id, im.points
      from public.week_immunities im
      join public.weeks w on w.id = im.week_id and w.is_complete and w.number > starts_after
      join public.partnerships p on p.id = im.partnership_id
      cross join lateral (values (p.star_id), (p.pro_id)) x(cast_id)
     where x.cast_id is not null
  ),
  official as (
    select s.fantasy_team_id as team_id, a.pts
      from awards a
      join public.league_weekly_roster_snapshots s
        on s.league_id = p_league_id and s.week_id = a.week_id and s.cast_member_id = a.cast_id
  ),
  appearance as (
    select s.fantasy_team_id as team_id,
           case
             when cm.is_hough then coalesce((select pts from rates where name = 'Hough'), 0)
             when s.cast_role = 'Surprise' then
               case when not is_original and coalesce(cm.surprise_base_role, '') <> ''
                    then coalesce((select pts from rates where name = cm.surprise_base_role), 0) + 2
                    else coalesce(cm.custom_appearance_points, 0) end
             else coalesce((select pts from rates where name = s.cast_role), 0)
           end as pts
      from public.dance_appearances a
      join public.dances d on d.id = a.dance_id
      join public.weeks w on w.id = d.week_id and w.is_complete and w.number > starts_after
      join public.cast_members cm on cm.id = a.cast_member_id
      join public.league_weekly_roster_snapshots s
        on s.league_id = p_league_id and s.week_id = w.id and s.cast_member_id = a.cast_member_id
     where not exists (select 1 from public.dance_cast_changes ch
                        where ch.dance_id = a.dance_id and ch.replacement_cast_member_id = a.cast_member_id)
       and not exists (select 1 from public.dance_couples dc join public.partnerships p on p.id = dc.partnership_id
                        where dc.dance_id = a.dance_id and a.cast_member_id in (p.star_id, p.pro_id))
  ),
  earned as (
    select team_id, pts from official union all select team_id, pts from appearance
  )
  select coalesce(jsonb_object_agg(t.id, coalesce(e.pts, 0)), '{}'::jsonb) into totals
    from public.fantasy_teams t
    left join (select team_id, sum(pts)::int as pts from earned group by team_id) e on e.team_id = t.id
   where t.league_id = p_league_id;

  return jsonb_build_object('teams', totals, 'error', null);
end $function$;
