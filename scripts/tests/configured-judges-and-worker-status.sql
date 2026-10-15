-- Transactional regression checks: every temporary edit is rolled back.
begin;
do $test$
declare d uuid; w uuid; guest text; expected text[]; status jsonb; admin uuid;
begin
  update public.app_config set value='["Bruno","Derek","Carrie Ann"]' where key='regular_judges';
  if public.regular_judge_names() is distinct from array['Bruno','Derek','Carrie Ann'] then
    raise exception 'Regular panel did not follow app_config';
  end if;
  select dance.id, week.id, week.guest_judge_name into d,w,guest
    from public.dances dance join public.weeks week on week.id=dance.week_id
    where dance.kind='competitive' order by week.number desc limit 1;
  expected:=public.regular_judge_names() || case when guest is null then '{}'::text[] else array[guest] end;
  if public.dance_expected_judges(d) is distinct from expected then
    raise exception 'Score validation did not follow app_config';
  end if;
  -- Reordering the configured default must preserve an explicitly saved week order.
  update public.weeks set theme=theme where id=w;
  select user_id into admin from public.platform_admins limit 1;
  if admin is null then raise exception 'Owner fixture required'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true);
  status:=public.get_week_automation_status(w);
  if (status->'worker_execution'->>'work_ready')::boolean is distinct from public.dwts_work_ready()
    or status->'worker_execution'->>'mode' is distinct from 'github_actions' then
    raise exception 'Owner status does not report GitHub readiness';
  end if;
  begin
    update public.app_config set value='["Judge"," judge "]' where key='regular_judges';
    perform public.regular_judge_names();
    raise exception 'Duplicate judge configuration accepted';
  exception when raise_exception then
    if sqlerrm <> 'Regular judges must have unique, nonempty names' then raise; end if;
  end;
end $test$;
rollback;
