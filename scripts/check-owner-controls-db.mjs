// Disposable PostgreSQL only; fake net/cron/Vault never contact external services.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
const container=process.argv[2];
assert.match(container||'',/^mirrorball-owner-test-\d{8}$/);
for(const command of ['dropdb','createdb']) {
  const r=spawnSync('docker',['exec',container,command,'-U','supabase_admin',...(command==='dropdb'?['--if-exists']:[]),'owner_operations_test'],{encoding:'utf8'});
  if(r.status)throw Error(r.stderr);
}
const query=sql=>{
  const r=spawnSync('docker',['exec','-i',container,'psql','-U','supabase_admin','-d','owner_operations_test','-X','-qAt','-v','ON_ERROR_STOP=1'],{input:sql,encoding:'utf8'});
  if(r.status)throw Error(r.stderr);return r.stdout.trim();
};
query(`
create schema auth;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create function public.is_platform_admin() returns boolean language sql stable as $$select auth.uid()='00000000-0000-4000-8000-000000000001'::uuid$$;
grant usage on schema auth to authenticated;
create table public.weeks(id uuid primary key default gen_random_uuid(),number int,guest_judge_name text,
  judge_order text[],guest_judge_image_path text,guest_judge_avatar_frame jsonb not null default '{}',
  air_date date,second_air_date date,air_end_time time default '22:00',second_air_end_time time,
  is_complete boolean default false,is_finale boolean default false,elimination_predictions_enabled boolean default false);
grant select,update,insert on public.weeks to authenticated;
alter table public.weeks enable row level security;
create policy owner_weeks on public.weeks to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
create function public.save_week_with_automation(p_setup jsonb,p_automation jsonb) returns void language plpgsql as $$begin
  update public.weeks set guest_judge_name=p_setup->>'p_guest_judge_name' where id=(p_setup->>'p_week_id')::uuid;
end$$;
create table public.dances(id uuid primary key default gen_random_uuid(),song_title text,song_artist text,
 music_match_status text,apple_music_url text,spotify_url text,music_matched_at timestamptz,protected_score int);
create function public.record_dance_music_match_v2(p_dance_id uuid,p_song_title text,p_song_artist text,p_apple_url text,p_spotify_url text,p_status text)
returns void language plpgsql security invoker set search_path='' as $$begin
 if p_status not in ('matched','no_match') then raise exception 'Bad match status.'; end if;
 update public.dances set apple_music_url=p_apple_url,spotify_url=p_spotify_url,music_match_status=p_status,music_matched_at=now()
 where id=p_dance_id and song_title is not distinct from p_song_title and song_artist is not distinct from p_song_artist and coalesce(music_match_status,'')<>'manual';
end$$;
revoke all on public.dances from public,anon,authenticated,service_role;
revoke all on function public.record_dance_music_match_v2(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.record_dance_music_match_v2(uuid,text,text,text,text,text) to service_role;
create table public.market_prediction_sync_state(id int primary key,refreshed_at timestamptz,snapshot_bucket timestamptz);
insert into public.market_prediction_sync_state(id) values(1);
create table public.cast_market_predictions(week_id uuid,event_ticker text,market_status text,percent numeric,fetched_at timestamptz);
create schema vault;create table vault.decrypted_secrets(name text,decrypted_secret text);
insert into vault.decrypted_secrets values('market_prediction_sync_url','https://test.invalid'),('market_prediction_sync_secret','test-only');
create schema net;create table net._http_response(id bigint,status_code int,timed_out boolean,error_msg text);
create table net.test_requests(id bigserial primary key,body jsonb);
create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds int) returns bigint language plpgsql as $$declare i bigint;begin
 insert into net.test_requests(body) values(body) returning id into i;return i;end$$;
create schema cron;create table cron.job_run_details(status text,start_time timestamptz,end_time timestamptz);
create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;
insert into public.weeks(number,guest_judge_name,guest_judge_image_path,is_complete,air_date) values
 (5,'Joe Buck','Images/Cast Thumbnails/Joe Buck.webp',true,current_date-1),
 (6,'Kym Johnson',null,false,current_date+7);
`);
query(await readFile(new URL('../supabase/migrations/20261014221333_owner_week_operations.sql',import.meta.url),'utf8'));
query(`
create function pg_temp.check_true(v boolean,m text) returns void language plpgsql as $$begin if v is distinct from true then raise exception 'TEST: %',m;end if;end$$;
select pg_temp.check_true((select guest_judge_image_path='Images/Guests/Kym Johnson.jpeg' from weeks where number=6),'Kym linked');
select pg_temp.check_true((select guest_judge_image_path='Images/Guests/Joe Buck.jpeg' from weeks where number=5),'Joe moved');
update weeks set guest_judge_avatar_frame='{"x":20,"y":30,"zoom":2}' where number=6;
update weeks set guest_judge_name='Another Guest' where number=6;
select pg_temp.check_true((select guest_judge_image_path='Images/Guests/Another Guest.jpeg' and guest_judge_avatar_frame='{}'::jsonb from weeks where number=6),'rename clears crop and assigns photo');
update weeks set guest_judge_name=null where number=6;
select pg_temp.check_true((select guest_judge_image_path is null and cardinality(judge_order)=3 from weeks where number=6),'disable guest clears photo');
update weeks set guest_judge_name='Kym Johnson' where number=6;
select pg_temp.check_true(not has_function_privilege('authenticated','private.enqueue_prediction_refresh(boolean)','execute'),'no direct enqueue access');
select pg_temp.check_true(not has_function_privilege('anon','public.get_week_prediction_status(uuid)','execute'),'no anonymous status access');
select pg_temp.check_true(not has_column_privilege('service_role','public.dances','protected_score','update'),'music cannot edit scores');
select pg_temp.check_true(not has_column_privilege('service_role','public.dances','song_title','update'),'music cannot edit titles');
insert into dances(id,song_title,song_artist,music_match_status) values('00000000-0000-4000-8000-000000000003','Song','Artist','pending');
set role service_role;
select record_dance_music_match_v2('00000000-0000-4000-8000-000000000003','Song','Artist','https://music.test',null,'matched');
reset role;
select pg_temp.check_true((select apple_music_url='https://music.test' from dances),'service callback can save');
set role authenticated;
set test.uid='00000000-0000-4000-8000-000000000002';
do $$begin
  begin perform public.get_week_prediction_status(null);raise exception 'TEST unauthorized status';exception when raise_exception then if sqlerrm<>'Platform-owner access required' then raise;end if;end;
  begin perform public.request_week_prediction_refresh(null);raise exception 'TEST unauthorized refresh';exception when raise_exception then if sqlerrm<>'Platform-owner access required' then raise;end if;end;
end$$;
set test.uid='00000000-0000-4000-8000-000000000001';
select public.save_week_with_owner_controls(jsonb_build_object('p_week_id',(select id from weeks where number=6),
  'p_guest_judge_name','Kym Johnson','p_guest_judge_image_path',null,'p_guest_judge_avatar_frame',jsonb_build_object('x',45,'y',20,'zoom',1.7)),'{}');
select pg_temp.check_true((select guest_judge_image_path='Images/Guests/Kym Johnson.jpeg' and guest_judge_avatar_frame->>'zoom'='1.7' from weeks where number=6),'owner crop saves');
reset role;
select private.enqueue_prediction_refresh(false);
-- Enabling predictions immediately after an ordinary scheduled refresh must still force a fetch.
update weeks set elimination_predictions_enabled=true where number=6;
select pg_temp.check_true((select count(*)=2 from net.test_requests),'enable queues force even after cron');
set role authenticated;
select pg_temp.check_true((public.request_week_prediction_refresh((select id from weeks where number=6))->>'queued')::boolean=false,'repeat forced refresh is throttled');
select pg_temp.check_true((public.get_week_prediction_status((select id from weeks where number=6))->>'pending')::boolean,'owner sees pending');
reset role;
insert into cron.job_run_details values
 ('succeeded',now()-interval '20 days',now()-interval '20 days'),
 ('failed',now()-interval '20 days',now()-interval '20 days'),
 ('failed',now()-interval '40 days',now()-interval '40 days'),
 ('running',now()-interval '40 days',null),('succeeded',now(),now());
select pg_temp.check_true(private.prune_scheduler_logs()=2,'only expired finished logs deleted');
select pg_temp.check_true((select count(*)=3 from cron.job_run_details),'recent, failures and running preserved');
`);
console.log('Owner access, automatic guest paths/crops, limited music grants, immediate refresh, cooldown, status and retention verified in disposable Postgres.');
