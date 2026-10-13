-- Disposable database only: exercise the actual claim/report functions with
-- deliberately different scores so swapping Joe and Bruno cannot go unnoticed.
begin;
create or replace function pg_temp.check_true(condition boolean,message text)
returns void language plpgsql as $$ begin
  if condition is distinct from true then raise exception 'TEST FAILED: %',message; end if;
end $$;
update public.dwts_automation_weeks set enabled=false;
update public.weeks set is_complete=false,guest_judge_name='Joe Buck',
  air_date=(now() at time zone 'America/New_York')::date,
  air_start_time=((now() at time zone 'America/New_York')-interval '1 hour')::time,
  air_end_time=((now() at time zone 'America/New_York')+interval '10 minutes')::time
where number=5;
delete from public.dance_judge_scores where dance_id in (select id from public.dances where week_id=(select id from public.weeks where number=5));
delete from public.dance_confirmation_checks where field_name='scores'
  and dance_id in (select id from public.dances where week_id=(select id from public.weeks where number=5));
update public.dances set scores_confirmed=false where week_id=(select id from public.weeks where number=5);
select public.configure_dwts_automation(5,true,array['live-show'],array['Carrie Ann','Derek','Joe Buck','Bruno']);
do $$ declare w uuid;task jsonb;payload jsonb;result jsonb;n integer;d uuid; begin
  select id into w from public.weeks where number=5;
  perform pg_temp.check_true((select judge_order=array['Carrie Ann','Derek','Joe Buck','Bruno'] from public.weeks where id=w),'display order follows automation');
  task:=public.claim_dwts_work('guest-panel-test');
  perform pg_temp.check_true(task->>'mode'='live-show','live job is available');
  perform pg_temp.check_true(task->'judge_order'='["Carrie Ann","Derek","Joe Buck","Bruno"]'::jsonb,'worker claims exact tuple order');
  n:=jsonb_array_length(task->'targets');
  perform pg_temp.check_true(n>0,'competitive targets exist');
  d:=(task->'targets'->0->>'dance_id')::uuid;
  payload:=jsonb_build_object('mode','live-show','week',5,'week_tag',task->>'week_tag','couples',
    (select jsonb_agg(jsonb_build_object('star_name',t->>'star_name','pro_name',t->>'pro_name','found',true,
      'performances','[{"scores":[7,8,9,10],"total":34,"table_index":0,"row_index":2}]'::jsonb))
      from jsonb_array_elements(task->'targets') t));
  result:=public.report_dwts_work('guest-panel-test',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'four-score report accepted');
  perform pg_temp.check_true((select score=9 and not confirmed from public.dance_judge_scores where dance_id=d and judge_name='Joe Buck'),'Joe gets third score immediately');
  perform pg_temp.check_true((select score=10 and not confirmed from public.dance_judge_scores where dance_id=d and judge_name='Bruno'),'Bruno gets fourth score immediately');
  perform pg_temp.check_true((select sum(score)=34 and count(*)=4 from public.dance_judge_scores where dance_id=d),'all four scores count');
  perform pg_temp.check_true(jsonb_array_length(public.dwts_pending_targets(w,'live-show'))=n,'first run remains pending');
  perform public.configure_dwts_automation(5,true,array['live-show'],array['Carrie Ann','Derek','Joe Buck','Bruno']);
  task:=public.claim_dwts_work('guest-panel-test');
  result:=public.report_dwts_work('guest-panel-test',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'second four-score report accepted');
  perform pg_temp.check_true((select scores_confirmed from public.dances where id=d),'four scores confirmed on second run');
  perform pg_temp.check_true(jsonb_array_length(public.dwts_pending_targets(w,'live-show'))=0,'confirmed couples leave pending list');
  perform pg_temp.check_true(not exists(select 1 from public.cast_members where name='Joe Buck'),'guest never enters cast pool');

  begin
    perform public.configure_dwts_automation(5,true,array['live-show'],array['Carrie Ann','Derek','Joe Buck','Joe Buck']);
    raise exception 'TEST FAILED: duplicate panel accepted';
  exception when others then
    if sqlerrm not like '%every judge exactly once%' then raise; end if;
  end;
  update public.weeks set guest_judge_image_path='Images/Cast Thumbnails/Joe Buck.webp',
    guest_judge_avatar_frame='{"zoom":1.7}' where id=w;
  update public.weeks set guest_judge_name='Different Guest' where id=w;
  perform pg_temp.check_true((select guest_judge_image_path is null and judge_order=array['Carrie Ann','Derek','Bruno','Different Guest'] from public.weeks where id=w),'new guest cannot inherit Joe portrait or order');
end $$;
rollback;
