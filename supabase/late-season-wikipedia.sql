-- Late-season Wikipedia imports (2026-10-24). Only weeks with Special formats set (weeks.formats)
-- change behaviour: every round's dances become automation targets, the worker gets the week's
-- couples / dances / special dances to map Wikipedia rows, and team dances, dance-offs, relays and
-- marathons are filled in (or created) after two matching reads. Ordinary weeks are unchanged.

alter table public.dwts_automation_weeks add column if not exists special_candidates jsonb not null default '{}'::jsonb;

-- Names as Wikipedia writes them: the couple's round-1 fill-in pro (injury) applies to every round.
create or replace function public.dwts_pending_targets(p_week uuid, p_mode text)
 returns jsonb language sql stable security definer set search_path to '' as $function$
  with wk as (
    select coalesce(cardinality(w.formats), 0) > 0 as late, w.formats from public.weeks w where w.id = p_week
  ), comp as (
    select d.id, d.sort_order, coalesce(d.round, 1) as round, p.id as pid, s.name as star,
           case when p_mode = 'photos' then r.name else coalesce(f.name, r.name) end as pro
      from public.dances d
      join public.partnerships p on p.id = d.partnership_id
      join public.cast_members s on s.id = p.star_id
      join public.cast_members r on r.id = p.pro_id
      left join lateral (select x.id from public.dances x where x.week_id = d.week_id and x.kind = 'competitive'
                          and x.partnership_id = d.partnership_id and coalesce(x.round, 1) = 1 limit 1) first on true
      left join public.dance_cast_changes ch on ch.dance_id = coalesce(first.id, d.id) and ch.cast_member_id = p.pro_id
      left join public.cast_members f on f.id = ch.replacement_cast_member_id
     where d.week_id = p_week and d.kind = 'competitive'
       and (coalesce(d.round, 1) = 1 or (p_mode <> 'photos' and (select late from wk)))
       and case p_mode
         when 'pre-show' then not d.dance_type_confirmed or not d.song_confirmed
         when 'live-show' then not d.scores_confirmed
         when 'post-show' then not d.elimination_confirmed
         when 'photos' then not d.photos_uploaded else false end
  ), spec as (
    select d.id, d.sort_order, d.kind, d.bonus_kind
      from public.dances d
     where (select late from wk) and d.week_id = p_week and d.kind in ('team', 'bonus')
       and case p_mode
         when 'pre-show' then not d.song_confirmed or ((d.kind = 'team' or d.bonus_kind <> 'marathon') and not d.dance_type_confirmed)
         when 'live-show' then case
           when d.kind = 'team' then not d.scores_confirmed
           when d.bonus_kind = 'marathon' then not exists (select 1 from public.dance_couples c where c.dance_id = d.id and c.points is not null)
           else not exists (select 1 from public.dance_couples c where c.dance_id = d.id and c.result = 'winner') end
         else false end
  ), discover as (
    select 1 as yes
     where (select late from wk) and p_mode in ('pre-show', 'live-show')
       and exists (select 1 from unnest((select formats from wk)) f
                    where f in ('team_dance', 'dance_off', 'relay', 'marathon')
                      and not exists (select 1 from public.dances d where d.week_id = p_week
                                        and case f when 'team_dance' then d.kind = 'team'
                                                   else d.kind = 'bonus' and d.bonus_kind = f end))
  )
  select coalesce((select jsonb_agg(jsonb_build_object('dance_id', c.id, 'partnership_id', c.pid, 'star_name', c.star,
                                                       'pro_name', c.pro, 'round', c.round) order by c.sort_order, c.id) from comp c), '[]'::jsonb)
      || coalesce((select jsonb_agg(jsonb_build_object('dance_id', s.id, 'special', true, 'kind', s.kind, 'bonus_kind', s.bonus_kind)
                                    order by s.sort_order, s.id) from spec s), '[]'::jsonb)
      || case when exists (select 1 from discover) then '[{"discover": true}]'::jsonb else '[]'::jsonb end;
$function$;

-- What the worker needs to map a late-season week ({} for ordinary weeks).
create or replace function public.dwts_week_context(p_week uuid)
 returns jsonb language sql stable security definer set search_path to '' as $function$
  with wk as (select * from public.weeks where id = p_week),
  dancers as (
    select d.id, d.partnership_id, d.sort_order, coalesce(d.round, 1) as round, d.round_label, d.dance_type, d.song_title,
           s.name as star, coalesce(f.name, r.name) as pro
      from public.dances d
      join public.partnerships p on p.id = d.partnership_id
      join public.cast_members s on s.id = p.star_id
      join public.cast_members r on r.id = p.pro_id
      left join lateral (select x.id from public.dances x where x.week_id = d.week_id and x.kind = 'competitive'
                          and x.partnership_id = d.partnership_id and coalesce(x.round, 1) = 1 limit 1) first on true
      left join public.dance_cast_changes ch on ch.dance_id = coalesce(first.id, d.id) and ch.cast_member_id = p.pro_id
      left join public.cast_members f on f.id = ch.replacement_cast_member_id
     where d.week_id = p_week and d.kind = 'competitive'
  )
  select case when coalesce(cardinality(wk.formats), 0) = 0 then '{}'::jsonb else jsonb_build_object(
    'formats', to_jsonb(wk.formats),
    'week_couples', coalesce((select jsonb_agg(jsonb_build_object('partnership_id', x.partnership_id, 'star_name', x.star, 'pro_name', x.pro)
                                               order by x.sort_order) from dancers x where x.round = 1), '[]'::jsonb),
    'week_dances', coalesce((select jsonb_agg(jsonb_build_object('dance_id', x.id, 'partnership_id', x.partnership_id,
                                               'star_name', x.star, 'pro_name', x.pro, 'round', x.round, 'round_label', x.round_label,
                                               'dance_type', x.dance_type, 'song_title', x.song_title) order by x.round, x.sort_order)
                              from dancers x), '[]'::jsonb),
    'week_specials', coalesce((select jsonb_agg(jsonb_build_object('dance_id', d.id, 'kind', d.kind, 'bonus_kind', d.bonus_kind,
                                               'team_name', d.team_name, 'name', d.name,
                                               'couples', coalesce((select jsonb_agg(c.partnership_id) from public.dance_couples c where c.dance_id = d.id), '[]'::jsonb))
                                               order by d.sort_order)
                                 from public.dances d where d.week_id = p_week and d.kind in ('team', 'bonus')), '[]'::jsonb)) end
    from wk;
$function$;
revoke execute on function public.dwts_week_context(uuid) from public, anon, authenticated;

-- Team dances, dance-offs, relays and marathons from a pre-show / live-show report.
-- Existing dances are filled field by field after two matching reads (style, song, couples;
-- live: team scores, the match winner, marathon points). Ones Wikipedia lists that the week
-- doesn't have yet are created after two matching reads, only for formats ticked on the week.
create or replace function public.dwts_import_specials(p_run uuid, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare r public.dwts_automation_runs%rowtype; j public.dwts_automation_jobs%rowtype; w public.weeks%rowtype;
  s jsonb; d public.dances%rowtype; n integer; value jsonb; errors jsonb := '[]'::jsonb; imported integer := 0;
  candidate boolean := false; pids uuid[]; names text[]; expected text[]; total integer; i integer; item jsonb; score integer;
  cands jsonb; k text; v_id uuid; style text; old_marker text;
begin
  select * into r from public.dwts_automation_runs where id = p_run;
  select * into j from public.dwts_automation_jobs where id = r.job_id;
  select * into w from public.weeks where id = j.week_id;
  if w.is_complete or coalesce(cardinality(w.formats), 0) = 0 or j.mode not in ('pre-show', 'live-show')
     or jsonb_typeof(p_result->'specials') is distinct from 'array' then
    return jsonb_build_object('errors', errors, 'imported', 0, 'candidate', false);
  end if;
  old_marker := coalesce(current_setting('mirrorball.automation_import', true), '');
  perform set_config('mirrorball.automation_import', 'on', true);
  for s in select x from jsonb_array_elements(p_result->'specials') x limit 40 loop
    begin
      if s->>'kind' not in ('team', 'bonus') or (s->>'kind' = 'bonus' and coalesce(s->>'bonus_kind', '') not in ('dance_off', 'relay', 'marathon')) then
        raise exception 'Unknown special dance';
      end if;
      -- Only couples dancing this week.
      select coalesce(array_agg(distinct (c->>'partnership_id')::uuid), '{}') into pids
        from jsonb_array_elements(coalesce(s->'couples', '[]'::jsonb)) c
       where c->>'partnership_id' ~ '^[0-9a-f-]{36}$'
         and exists (select 1 from public.dances x where x.week_id = w.id and x.kind = 'competitive'
                       and x.partnership_id = (c->>'partnership_id')::uuid);

      if nullif(s->>'dance_id', '') is null then
        if not ((case when s->>'kind' = 'team' then 'team_dance' else s->>'bonus_kind' end) = any(w.formats))
           or cardinality(pids) = 0 or (s->>'kind' = 'team' and nullif(btrim(s->>'team_name'), '') is null) then continue; end if;
        k := left(coalesce(s->>'key', ''), 200);
        if k = '' then continue; end if;
        value := jsonb_build_object('couples', (select jsonb_agg(x order by x) from unnest(pids) x),
                                    'team_name', s->>'team_name', 'name', s->>'name');
        select coalesce(special_candidates, '{}'::jsonb) into cands from public.dwts_automation_weeks where week_id = w.id for update;
        if cands->k->'value' = value and cands->k->>'run' is distinct from p_run::text then
          insert into public.dances(week_id, kind, bonus_kind, team_name, name, sort_order)
          values (w.id, s->>'kind', case when s->>'kind' = 'bonus' then s->>'bonus_kind' end,
                  case when s->>'kind' = 'team' then btrim(s->>'team_name') end,
                  case when s->>'bonus_kind' = 'marathon' then nullif(btrim(s->>'name'), '') end,
                  coalesce((select max(sort_order) + 1 from public.dances where week_id = w.id), 1))
          returning id into v_id;
          insert into public.dance_couples(dance_id, partnership_id) select v_id, x from unnest(pids) x;
          cands := cands - k;
          imported := imported + 1;
        elsif cands->k->>'run' is distinct from p_run::text then
          cands := cands || jsonb_build_object(k, jsonb_build_object('value', value, 'run', p_run));
          candidate := true;
        end if;
        update public.dwts_automation_weeks set special_candidates = cands where week_id = w.id;
        continue;
      end if;

      select * into d from public.dances where id = (s->>'dance_id')::uuid and week_id = w.id and kind = s->>'kind'
         and (kind = 'team' or bonus_kind = s->>'bonus_kind') for update;
      if not found then continue; end if;

      -- Couples (added, never removed: a couple Freddy added by hand stays).
      if cardinality(pids) > 0 and not exists (select 1 from public.dance_confirmation_checks
                                                 where dance_id = d.id and field_name = 'special_couples' and confirmed_source is not null) then
        n := public.dwts_observe_field(d.id, 'special_couples', (select jsonb_agg(x order by x) from unnest(pids) x), p_run);
        if n = 1 then candidate := true; end if;
        if n = 2 then
          insert into public.dance_couples(dance_id, partnership_id) select d.id, x from unnest(pids) x on conflict do nothing;
          imported := imported + 1;
        end if;
      end if;

      -- Style (not marathons) and song.
      if (d.kind = 'team' or d.bonus_kind <> 'marathon') and not d.dance_type_confirmed then
        style := public.canonical_dance_style(nullif(btrim(s->>'dance'), ''));
        n := public.dwts_observe_field(d.id, 'dance_type', case when style is null then null else to_jsonb(style) end, p_run);
        if n = 1 then candidate := true; end if;
        if n = 2 then update public.dances set dance_type = style, dance_type_confirmed = true where id = d.id; imported := imported + 1; end if;
      end if;
      if d.bonus_kind = 'marathon' and nullif(btrim(d.name), '') is null and nullif(btrim(s->>'name'), '') is not null then
        n := public.dwts_observe_field(d.id, 'special_name', to_jsonb(btrim(s->>'name')), p_run);
        if n = 1 then candidate := true; end if;
        if n = 2 then update public.dances set name = btrim(s->>'name') where id = d.id; end if;
      end if;
      if not d.song_confirmed and nullif(btrim(s->>'song'), '') is not null then
        value := jsonb_build_object('title', btrim(s->>'song'), 'artist', nullif(btrim(s->>'artist'), ''));
        n := public.dwts_observe_field(d.id, 'song', value, p_run);
        if n = 1 then candidate := true; end if;
        if n = 2 then
          update public.dances set song_title = value->>'title', song_artist = value->>'artist', song_confirmed = true where id = d.id;
          imported := imported + 1;
        end if;
      end if;

      if j.mode = 'live-show' then
        -- Team dance scores, in the week's judge order.
        if d.kind = 'team' and not d.scores_confirmed and jsonb_typeof(s->'scores') = 'array' then
          names := array(select jsonb_array_elements_text(r.payload->'judge_order'));
          expected := public.dance_expected_judges(d.id);
          if expected is null or not names @> expected or not names <@ expected or cardinality(names) <> cardinality(expected) then
            raise exception 'Judge panel changed during run';
          end if;
          if public.dwts_array_length(s->'scores') <> cardinality(names) then raise exception 'Team scores don''t match the judges'; end if;
          value := '[]'::jsonb; total := 0; i := 1;
          for item in select x from jsonb_array_elements(s->'scores') x loop
            if jsonb_typeof(item) <> 'number' or (item#>>'{}') !~ '^(10|[1-9])$' then raise exception 'Each judge score must be an integer 1–10'; end if;
            score := (item#>>'{}')::integer; total := total + score;
            value := value || jsonb_build_array(jsonb_build_object('judge_name', names[i], 'score', score));
            i := i + 1;
          end loop;
          if s->>'total' is null or s->>'total' !~ '^[0-9]{1,2}$' or (s->>'total')::integer <> total then
            raise exception 'Score total does not match individual judges';
          end if;
          n := public.dwts_observe_field(d.id, 'scores', value, p_run);
          if n = 1 then candidate := true; end if;
          if n = 2 then
            insert into public.dance_judge_scores(dance_id, judge_name, score, confirmed)
            select d.id, x->>'judge_name', (x->>'score')::integer, true from jsonb_array_elements(value) x
            on conflict (dance_id, judge_name) do update set score = excluded.score, confirmed = true
              where not public.dance_judge_scores.confirmed;
            perform public.refresh_dance_scores_confirmed(d.id);
            imported := imported + 1;
          end if;
        end if;
        -- Dance-off / relay winner.
        if d.bonus_kind in ('dance_off', 'relay') and nullif(s->>'winner', '') is not null
           and not exists (select 1 from public.dance_couples c where c.dance_id = d.id and c.result = 'winner') then
          if not exists (select 1 from public.dance_couples c where c.dance_id = d.id and c.partnership_id::text = s->>'winner') then
            raise exception 'The winner isn''t one of this match''s couples yet';
          end if;
          n := public.dwts_observe_field(d.id, 'match_result', to_jsonb(s->>'winner'), p_run);
          if n = 1 then candidate := true; end if;
          if n = 2 then
            update public.dance_couples set result = case when partnership_id::text = s->>'winner' then 'winner' else 'loser' end
             where dance_id = d.id;
            imported := imported + 1;
          end if;
        end if;
        -- Marathon points.
        if d.bonus_kind = 'marathon' and not exists (select 1 from public.dance_couples c where c.dance_id = d.id and c.points is not null) then
          value := (select jsonb_object_agg(c->>'partnership_id', (c->>'points')::integer)
                      from jsonb_array_elements(coalesce(s->'couples', '[]'::jsonb)) c
                     where c->>'points' ~ '^[0-9]{1,2}$' and c->>'partnership_id' ~ '^[0-9a-f-]{36}$'
                       and (c->>'partnership_id')::uuid = any(pids));
          if value is not null then
            n := public.dwts_observe_field(d.id, 'marathon_points', value, p_run);
            if n = 1 then candidate := true; end if;
            if n = 2 then
              insert into public.dance_couples(dance_id, partnership_id, points)
              select d.id, e.key::uuid, e.value::integer from jsonb_each_text(value) e
              on conflict (dance_id, partnership_id) do update set points = excluded.points;
              imported := imported + 1;
            end if;
          end if;
        end if;
      end if;
    exception when others then
      errors := errors || jsonb_build_array(jsonb_build_object('dance_id', s->>'dance_id', 'field', 'special', 'error', left(sqlerrm, 1000)));
    end;
  end loop;
  perform set_config('mirrorball.automation_import', old_marker, true);
  return jsonb_build_object('errors', errors, 'imported', imported, 'candidate', candidate);
end $function$;
revoke execute on function public.dwts_import_specials(uuid, jsonb) from public, anon, authenticated;

-- Report wrapper: import the late-season specials, then put the week's round-1 dances in
-- Wikipedia's running order. Second / third dances keep the slot Freddy dragged them to.
create or replace function public.report_dwts_work_before_photo_diagnostics(p_worker text, p_run uuid, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  result jsonb;
  run_row public.dwts_automation_runs%rowtype;
  v_week_id uuid;
  v_mode text := p_result->>'mode';
  candidate record;
  next_sequence integer;
  previous_setting text;
  observed boolean := false;
  specials jsonb;
begin
  result := public.report_dwts_work_base(p_worker,p_run,p_result);
  if v_mode not in ('pre-show','live-show')
    or coalesce((result->>'already_reported')::boolean,false)
    or coalesce((p_result->>'failed_run')::boolean,false)
    or p_result ? 'error' then return result; end if;

  select * into run_row from public.dwts_automation_runs where id = p_run;
  select j.week_id into v_week_id from public.dwts_automation_jobs j where j.id = run_row.job_id;
  if not exists (select 1 from public.weeks w where w.id = v_week_id and not w.is_complete) then
    return result;
  end if;

  specials := public.dwts_import_specials(p_run, p_result);
  if public.dwts_array_length(specials->'errors') > 0 or (specials->>'imported')::integer > 0 then
    result := result || jsonb_build_object(
      'errors', coalesce(result->'errors', '[]'::jsonb) || (specials->'errors'),
      'confirmed_or_uploaded', coalesce((result->>'confirmed_or_uploaded')::integer, 0) + (specials->>'imported')::integer);
    update public.dwts_automation_runs set summary = result,
      status = case when public.dwts_array_length(result->'errors') > 0 then 'failed' else status end where id = p_run;
    update public.dwts_automation_jobs set last_error = case when public.dwts_array_length(result->'errors') > 0
      then left((result->'errors')::text, 2000) end where id = run_row.job_id;
  end if;
  if (specials->>'candidate')::boolean then
    update public.dwts_automation_jobs set next_run_at = least(next_run_at, now() + interval '1 minute') where id = run_row.job_id;
  end if;

  -- Only couples in the claimed payload; never trust extra JSON couples.
  for candidate in
    select d.id, d.wiki_score_sequence,
      nullif(c.perf->>'table_index','')::integer as table_index,
      nullif(c.perf->>'row_index','')::integer as row_index,
      c.perf, t->>'star_name' as star_name
    from jsonb_array_elements(run_row.payload->'targets') t
    join public.dances d on d.id = (t->>'dance_id')::uuid and d.week_id = v_week_id and d.kind = 'competitive'
      and coalesce(d.round, 1) = 1
    cross join lateral (
      select case when item ? 'by_dance' then item->'by_dance'->(d.id::text) else item->'performances'->0 end as perf
      from jsonb_array_elements(coalesce(p_result->'couples','[]'::jsonb)) item
      where item->>'star_name' = t->>'star_name'
        and item->>'pro_name' = t->>'pro_name'
        and item->>'found' = 'true'
        and jsonb_typeof(item->'performances') = 'array'
        and (item ? 'by_dance' or public.dwts_array_length(item->'performances') = 1)
      limit 1
    ) c
    where jsonb_typeof(c.perf) = 'object'
      and not exists (select 1 from jsonb_array_elements(coalesce(result->'errors','[]'::jsonb)) e
        where e->>'dance_id' = d.id::text)
    order by coalesce(nullif(c.perf->>'table_index','')::integer,2147483647),
             coalesce(nullif(c.perf->>'row_index','')::integer,2147483647), t->>'star_name', d.id
  loop
    if candidate.table_index is not null and candidate.row_index is not null then
      update public.dances set wiki_row_order = candidate.table_index * 1000 + candidate.row_index
       where id = candidate.id and wiki_row_order is distinct from candidate.table_index * 1000 + candidate.row_index;
      observed := true;
    end if;
    if v_mode = 'live-show' and candidate.wiki_score_sequence is null
       and jsonb_typeof(candidate.perf->'scores') = 'array'
       and public.dwts_array_length(candidate.perf->'scores') in (3,4)
       and exists (select 1 from public.dance_judge_scores s where s.dance_id = candidate.id) then
      select coalesce(max(wiki_score_sequence),0)+1 into next_sequence
        from public.dances where week_id = v_week_id;
      update public.dances set wiki_score_sequence = next_sequence where id = candidate.id;
      observed := true;
    end if;
  end loop;

  if not observed then return result; end if;
  previous_setting := coalesce(current_setting('mirrorball.automation_import',true),'');
  perform set_config('mirrorball.automation_import','on',true);
  with slots as (
    select d.sort_order, row_number() over (order by d.sort_order,d.id) as position
    from public.dances d where d.week_id = v_week_id and d.kind = 'competitive' and coalesce(d.round, 1) = 1
  ), ranked as (
    select d.id, row_number() over (order by d.wiki_row_order nulls last, d.wiki_score_sequence nulls last,
      s.name collate "C", d.id) as position
    from public.dances d
    join public.partnerships p on p.id = d.partnership_id
    join public.cast_members s on s.id = p.star_id
    where d.week_id = v_week_id and d.kind = 'competitive' and coalesce(d.round, 1) = 1
  )
  update public.dances d set sort_order = slots.sort_order
    from ranked join slots on slots.position = ranked.position
    where d.id = ranked.id and d.sort_order is distinct from slots.sort_order;
  perform set_config('mirrorball.automation_import',previous_setting,true);
  return result;
end $function$;

-- Late-season Wikipedia imports, part 2: small patches to the existing importer functions,
-- applied by text replacement so the rest of each function stays exactly as deployed.
do $patch$
declare def text; old text; new text;
begin
  -- report_dwts_work_base: a couple's rows are picked per dance from the worker's round mapping
  -- (by_dance) when it sends one; otherwise exactly as before.
  def := pg_get_functiondef('public.report_dwts_work_base(text,uuid,jsonb)'::regprocedure);
  old := $o$      if not is_failed and coalesce((couple->>'found')::boolean,false)
        and jsonb_typeof(couple->'performances')='array' and public.dwts_array_length(couple->'performances')=1 then perf:=couple->'performances'->0; end if;
      if jsonb_typeof(couple->'performances')='array' and public.dwts_array_length(couple->'performances')>1 then
        errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'error','Multiple Wikipedia performances need explicit mapping; not guessing'));
      end if;$o$;
  new := $n$      if couple ? 'by_dance' then
        if not is_failed and coalesce((couple->>'found')::boolean,false)
          and jsonb_typeof(couple->'by_dance'->(d.id::text))='object' then perf:=couple->'by_dance'->(d.id::text); end if;
      else
      if not is_failed and coalesce((couple->>'found')::boolean,false)
        and jsonb_typeof(couple->'performances')='array' and public.dwts_array_length(couple->'performances')=1 then perf:=couple->'performances'->0; end if;
      if jsonb_typeof(couple->'performances')='array' and public.dwts_array_length(couple->'performances')>1 then
        errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'error','Multiple Wikipedia performances need explicit mapping; not guessing'));
      end if;
      end if;$n$;
  if position(old in def) = 0 then raise exception 'report_dwts_work_base changed; patch not applied'; end if;
  execute replace(def, old, new);

  -- claim_dwts_work: late-season weeks may have several dances per couple (mapped by the
  -- worker), and their payload carries the week's couples, dances and special dances.
  def := pg_get_functiondef('public.claim_dwts_work(text)'::regprocedure);
  old := $o$    if exists(select 1 from jsonb_array_elements(targets) t group by t->>'partnership_id' having count(*)>1) then$o$;
  new := $n$    if not exists(select 1 from public.weeks lw where lw.id=j.week_id and coalesce(cardinality(lw.formats),0)>0)
      and exists(select 1 from jsonb_array_elements(targets) t group by t->>'partnership_id' having count(*)>1) then$n$;
  if position(old in def) = 0 then raise exception 'claim_dwts_work changed (guard); patch not applied'; end if;
  def := replace(def, old, new);
  old := $o$    insert into public.dwts_automation_runs(job_id,worker_name,payload) values(j.id,p_worker,payload) returning id into run_id;$o$;
  new := $n$    if j.mode in ('pre-show','live-show','post-show') then payload:=payload||public.dwts_week_context(j.week_id); end if;
    insert into public.dwts_automation_runs(job_id,worker_name,payload) values(j.id,p_worker,payload) returning id into run_id;$n$;
  if position(old in def) = 0 then raise exception 'claim_dwts_work changed (payload); patch not applied'; end if;
  execute replace(def, old, new);

  -- preview_dwts_work: the same context, so a preview shows what the worker would get.
  def := pg_get_functiondef('public.preview_dwts_work(integer,text,text)'::regprocedure);
  old := $o$'since',w.air_date,'folder','Images/Dances/Week '||w.number,'known_photo_posts','[]'::jsonb);$o$;
  new := $n$'since',w.air_date,'folder','Images/Dances/Week '||w.number,'known_photo_posts','[]'::jsonb)
    || case when p_mode in ('pre-show','live-show','post-show') then public.dwts_week_context(w.id) else '{}'::jsonb end;$n$;
  if position(old in def) = 0 then raise exception 'preview_dwts_work changed; patch not applied'; end if;
  execute replace(def, old, new);
end $patch$;

-- Part 3: dance_confirmation_checks only allows dance_type / song / scores / elimination, so
-- dwts_import_specials reuses the slots special dances don't otherwise have (applied 2026-10-24).
do $patch$
declare def text;
begin
  def := pg_get_functiondef('public.dwts_import_specials(uuid,jsonb)'::regprocedure);
  def := replace(def, $o$'special_couples'$o$, $n$'elimination'$n$);
  def := replace(def, $o$'special_name'$o$, $n$'dance_type'$n$);
  def := replace(def, $o$'match_result'$o$, $n$'scores'$n$);
  def := replace(def, $o$'marathon_points'$o$, $n$'scores'$n$);
  def := replace(def, $o$declare r public.dwts_automation_runs%rowtype;$o$,
    $n$-- dance_confirmation_checks only allows dance_type / song / scores / elimination, so special
-- dances reuse the slots they don't otherwise have: their couples are read into "elimination"
-- (special dances have none), a marathon's title into "dance_type" (marathons have no style),
-- and a match winner or marathon points into "scores" (bonus rounds have no judges' scores).
declare r public.dwts_automation_runs%rowtype;$n$);
  execute def;
end $patch$;
