-- Applied 2026-10-20 (live). Competitive dances follow Wikipedia's running order:
-- pre-show and live-show runs record each couple's table row (dances.wiki_row_order =
-- table_index * 1000 + row_index); live-show also records score arrival
-- (wiki_score_sequence) as the fallback. Performances keep their slots, so moving them by
-- hand no longer stops the automation from ordering the couples.
-- Supersedes the week-level dance_order_manually_set check in
-- order-competitive-dances-by-wiki-scores.sql (the flag is still recorded, just not obeyed).
alter table public.dances add column if not exists wiki_row_order integer;

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

  for candidate in
    select d.id, d.wiki_score_sequence,
      nullif(c.perf->>'table_index','')::integer as table_index,
      nullif(c.perf->>'row_index','')::integer as row_index,
      c.perf, t->>'star_name' as star_name
    from jsonb_array_elements(run_row.payload->'targets') t
    join public.dances d on d.id = (t->>'dance_id')::uuid and d.week_id = v_week_id and d.kind = 'competitive'
    cross join lateral (
      select item->'performances'->0 as perf
      from jsonb_array_elements(coalesce(p_result->'couples','[]'::jsonb)) item
      where item->>'star_name' = t->>'star_name'
        and item->>'pro_name' = t->>'pro_name'
        and item->>'found' = 'true'
        and jsonb_typeof(item->'performances') = 'array'
        and public.dwts_array_length(item->'performances') = 1
      limit 1
    ) c
    where not exists (select 1 from jsonb_array_elements(coalesce(result->'errors','[]'::jsonb)) e
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
    from public.dances d where d.week_id = v_week_id and d.kind = 'competitive'
  ), ranked as (
    select d.id, row_number() over (order by d.wiki_row_order nulls last, d.wiki_score_sequence nulls last,
      s.name collate "C", d.id) as position
    from public.dances d
    join public.partnerships p on p.id = d.partnership_id
    join public.cast_members s on s.id = p.star_id
    where d.week_id = v_week_id and d.kind = 'competitive'
  )
  update public.dances d set sort_order = slots.sort_order
    from ranked join slots on slots.position = ranked.position
    where d.id = ranked.id and d.sort_order is distinct from slots.sort_order;
  perform set_config('mirrorball.automation_import',previous_setting,true);
  return result;
end $function$;
