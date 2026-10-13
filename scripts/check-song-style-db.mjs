// Real PostgreSQL regression suite. Never accepts a live URL or credentials.
// Usage: node scripts/check-song-style-db.mjs mirrorball-song-style-test-20261013
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const container=process.argv[2];
assert.match(container || '', /^mirrorball-song-style-test-\d{8}$/);
const database='mirrorball_song_style_tests';
for(const command of ['dropdb','createdb']) {
  const r=spawnSync('docker',['exec',container,command,'-U','supabase_admin',
    ...(command==='dropdb'?['--if-exists']:[]),database],{encoding:'utf8'});
  if(r.status!==0) throw Error(r.stderr || r.error?.message);
}
const query=sql=>{
  const r=spawnSync('docker',['exec','-i',container,'psql','-U','supabase_admin','-d',database,
    '-X','-qAt','-v','ON_ERROR_STOP=1'],{input:"set test.owner='yes';\n"+sql,encoding:'utf8'});
  if(r.status!==0) throw Error(r.stderr || r.error?.message);
  return r.stdout.trim();
};
const file=path=>readFile(new URL(`../${path}`,import.meta.url),'utf8');
query(await file('scripts/tests/dwts-automation-fixture.sql'));
query(await file('scripts/tests/song-style-schema-fixture.sql'));
for(const path of ['add-dance-confirmation-tracking.sql','add-dwts-automation-functions.sql',
  'add-dwts-worker-support.sql','order-competitive-dances-by-wiki-scores.sql','add-score-desk-automation-controls.sql'])
  query(await file(`supabase/${path}`));
query(`select public.configure_dwts_automation(4,true,array['get-weeks','pre-show']);
  update public.weeks set is_complete=true where number=4;
  insert into public.weeks(number,air_date,air_start_time,air_end_time) select 5,air_date,air_start_time,air_end_time from public.weeks where number=4;
  insert into public.weeks(number) values(6);
  select public.configure_dwts_automation(5,false,array['pre-show']);
  update public.dwts_automation_weeks set wiki_tag='#Week_5:_Super_Bowl_Night' where week_id=(select id from public.weeks where number=5);
  do $$ declare s uuid;p uuid;begin for i in 1..10 loop
    insert into public.cast_members(name,role) values('Test Star '||i,'Star') returning id into s;
    insert into public.cast_members(name,role) values('Test Pro '||i,'Pro') returning id into p;
    insert into public.partnerships(star_id,pro_id) values(s,p);
  end loop;end $$;
  update public.cast_members set role='Eliminated Star',eliminated_week_id=(select id from public.weeks where number=4) where name='Test Star 10';
  update public.partnerships set active=false where star_id=(select id from public.cast_members where name='Test Star 10');
`);
query(await file('supabase/auto-create-week-dances-and-photo-diagnostics.sql'));
query('drop function public.canonical_dance_type(text);');
query(await file('scripts/tests/song-style-live-functions.sql'));
query(`create trigger split_dance_song before insert or update of song on public.dances
  for each row execute function public.split_dance_song();
  create function public.check_dance_type_catalog() returns trigger language plpgsql as $$ begin
    new.dance_type:=public.canonical_dance_type(new.dance_type);
    if new.kind='performance' and new.dance_type is not null then raise exception 'Only competitive styles'; end if;
    return new;
  end $$;
  create trigger check_dance_type_catalog before insert or update of dance_type,kind on public.dances
    for each row execute function public.check_dance_type_catalog();
  update public.dances set song='Preserved title by Preserved artist' where kind='performance';
  grant usage on schema public to anon,authenticated,service_role;
  grant select,insert,update,delete on all tables in schema public to authenticated,service_role;
`);
const before=query("select jsonb_agg(to_jsonb(d) order by id) from public.dances d;");
const migration=await file('supabase/migrations/20261013200106_canonical_song_fields_and_dance_styles.sql');
query(migration);
assert.equal(query("select jsonb_agg(to_jsonb(d) order by id) from public.dances d;"),before,'Migration must not alter historical dances.');
query(migration);
assert.equal(query("select jsonb_agg(to_jsonb(d) order by id) from public.dances d;"),before,'Rerunning must preserve dances.');
query(await file('scripts/tests/canonical-song-styles.sql'));
// Existing end-to-end worker tests exercise first-seen imports, changed values,
// two consecutive confirmations, pending-target removal, ordering and photo diagnostics.
query(await file('scripts/tests/week-dance-creation-and-diagnostics.sql'));
assert.equal(query(`select count(*) from public.dances where song is distinct from
  case when song_title is null then null else song_title||case when song_artist is null then '' else ' by '||song_artist end end;`),'0');
assert.equal(query(`select count(*) from public.dances d join public.weeks w on w.id=d.week_id
  where w.number=5 and d.kind='competitive' and d.song_title is not null and d.song_artist='Artist' and d.song_confirmed;`),'11');
console.log('Canonical song fields, new style catalog, Fusion, free-text performances, compatibility, music races, authorization, rollback, rerun preservation, and full Wiki automation verified in isolated PostgreSQL.');
