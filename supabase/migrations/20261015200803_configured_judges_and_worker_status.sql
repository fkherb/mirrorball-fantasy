-- Applied live as 20261015200803; filename matches Supabase migration history.
-- Continue the GitHub on-demand worker setup. No dispatch, schedule, secret,
-- matching, push-notification, or scoring-rate settings are changed here.
begin;

create or replace function public.regular_judge_names()
returns text[] language plpgsql stable security invoker set search_path = '' as $fn$
declare config jsonb; names text[];
begin
  select value into config from public.app_config where key = 'regular_judges';
  if jsonb_typeof(config) is distinct from 'array' then
    raise exception 'app_config.regular_judges must be a nonempty list of judge names';
  end if;
  if exists (select 1 from jsonb_array_elements(config) item
      where jsonb_typeof(item) is distinct from 'string') then
    raise exception 'Each regular judge must have a name';
  end if;
  select array_agg(btrim(name) order by ordinal) into names
    from jsonb_array_elements_text(config) with ordinality j(name, ordinal);
  if coalesce(cardinality(names), 0) = 0 or '' = any(names)
    or cardinality(names) <> (select count(distinct lower(name)) from unnest(names) j(name)) then
    raise exception 'Regular judges must have unique, nonempty names';
  end if;
  return names;
end $fn$;
revoke all on function public.regular_judge_names() from public, anon, authenticated;
grant execute on function public.regular_judge_names() to anon, authenticated, service_role;

-- Keep the deployed definitions, signatures, security attributes, and grants.
-- Only replace the fixed regular panel. This preserves Claude's split-song v2
-- save function, guest photo validation, and worker claim/skip rules verbatim.
do $patch$
declare f record; original text; updated text;
begin
  for f in select p.oid, p.proname from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = any(array[
      'dance_expected_judges', 'save_dance_atomic_v2', 'validate_week_judge_display',
      'save_week_with_automation', 'update_week_setup_and_order',
      'preview_dwts_work', 'claim_dwts_work']) loop
    original := pg_get_functiondef(f.oid);
    updated := replace(original, 'array[''Carrie Ann'', ''Derek'', ''Bruno'']', 'public.regular_judge_names()');
    updated := replace(updated, 'array[''Carrie Ann'',''Derek'',''Bruno'']', 'public.regular_judge_names()');
    updated := replace(updated, 'array[''carrie ann'',''derek'',''bruno'']::text[]',
      'array(select lower(name) from unnest(public.regular_judge_names()) j(name))');
    if f.proname = 'save_week_with_automation' then
      updated := replace(updated, 'cardinality(expected)=4',
        'nullif(btrim(p_setup->>''p_guest_judge_name''),'''') is not null');
    end if;
    if updated like '%Carrie Ann%' or updated not like '%public.regular_judge_names()%' then
      raise exception 'Unexpected judge function definition: %; review before applying', f.proname;
    end if;
    if updated is distinct from original then execute updated; end if;
  end loop;
end $patch$;

-- Use the exact readiness predicate used by dispatch, rather than repeating it
-- in JavaScript. Owner status can show an idle worker as healthy between runs.
-- claim_dwts_work's selection and dwts_work_ready's skip mirror are unchanged.
do $patch$
declare original text; updated text;
begin
  original := pg_get_functiondef('public.get_week_automation_status(uuid)'::regprocedure);
  if original not like '%''worker_execution''%' then
    updated := replace(original, 'return data;', $replacement$
  return data || jsonb_build_object('worker_execution', jsonb_build_object(
    'mode', case when coalesce((select enabled from public.dwts_dispatch_state where id=1),false)
      then 'github_actions' else 'service' end,
    'work_ready', public.dwts_work_ready(),
    'last_dispatch_at', (select last_dispatch_at from public.dwts_dispatch_state where id=1)));
$replacement$);
    if updated = original then raise exception 'Unexpected automation status definition'; end if;
    execute updated;
  end if;
end $patch$;

-- Fail atomically if the existing configuration cannot drive scoring.
select public.regular_judge_names();
notify pgrst, 'reload schema';
commit;
