import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
const read=path=>readFile(new URL(`../${path}`,import.meta.url),'utf8');
const [app,sql,edge]=await Promise.all([
  read('app.js'),read('supabase/migrations/20261013200106_canonical_song_fields_and_dance_styles.sql'),
  read('supabase/functions/match-dance-songs/index.ts'),
]);
assert.match(app,/from\('dance_styles'\)\.select\('name'\)/);
assert.doesNotMatch(app,/from\('dance_types'\)|p_song:/);
assert.match(app,/Performance style.*<input id="performanceType"/);
assert.match(app,/danceTypes\.filter\(\(type\) => type\.name !== 'Fusion'\)/);
assert.match(sql,/from public\.dance_styles/);
assert.doesNotMatch(sql,/from public\.dance_types|drop column.*song/i);
assert.match(sql,/p_song_title text default null,p_song_artist text default null/);
assert.match(sql,/legacy_song_usage/);
assert.match(sql,/song_title=case when value is null then null else title end/);
assert.match(sql,/song_artist=case when value is null then null else artist end/);
assert.match(edge,/record_dance_music_match_v2/);
assert.doesNotMatch(edge,/rpc\('record_dance_music_match',/);
assert.equal((edge.match(/p_song_artist: dance\.song_artist/g)||[]).length,2);

// Execute the actual editor's save callback without touching Supabase.
const start=app.indexOf("  $('#saveDance').addEventListener('click', async () => {");
const end=app.indexOf("  $('#deleteDance')",start);
assert.ok(start>=0&&end>start);
for(const kind of ['competitive','performance']) {
  const elements=new Map(); let click; const calls=[]; const alerts=[];
  const fields={
    '#dancePartnership':'pair','#danceName':'Performance',
    '#danceType':'Fusion','#fusionTypeOne':'Tango','#fusionTypeTwo':'Rumba',
    '#danceSongTitle':'Title by the Sea','#danceSongArtist':'Music by Friends',
    '#performanceType':'Free text / not a catalog style','#danceChoreography':'Choreographer',
    '#danceAiringNight':'2',
  };
  const get=selector=>{
    if(!elements.has(selector))elements.set(selector,{value:fields[selector]||'',disabled:false,
      addEventListener(event,fn){assert.equal(event,'click');click=fn;},close(){}});
    return elements.get(selector);
  };
  runInNewContext(app.slice(start,end),{
    $:get,kind,scoresOnly:false,existingDance:null,existingAppearanceIds:[],week:{id:'week',second_air_date:'2026-10-14'},
    document:{querySelectorAll(selector){
      if(selector==='[data-judge]')return[{value:'8',dataset:{judge:'Derek'}}];
      return[{value:'cast'}];
    }},
    joinDanceType:(type,a,b)=>type==='Fusion'?`${a}/${b} Fusion`:type,
    db:{async rpc(name,args){calls.push({name,args});return{data:'dance',error:null};}},
    alert:message=>alerts.push(message),
    loadScoreDesk(){},refreshRoster(){},loadStandings(){},missingRpc(){return false;},
  });
  if(kind==='performance') {
    // Performances do not send any competitive scores.
    // The real callback branches before querying the judge selectors.
  }
  await click();
  assert.equal(alerts.length,0);
  assert.equal(calls.length,1);
  const {name,args}=calls[0];
  assert.equal(name,'save_dance_atomic_v2');
  assert.equal(args.p_song_title,'Title by the Sea');
  assert.equal(args.p_song_artist,'Music by Friends');
  assert.equal('p_song' in args,false);
  assert.equal(args.p_dance_type,kind==='competitive'?'Tango/Rumba Fusion':null);
  assert.equal(args.p_details.airing_night,2);
  if(kind==='performance') {
    assert.equal(args.p_details.performance_type,'Free text / not a catalog style');
    assert.equal(args.p_details.choreography,'Choreographer');
    assert.equal(args.p_judge_scores.length,0);
  }
  // Fusion components must differ before any database call.
  if(kind==='competitive') {
    get('#fusionTypeTwo').value='Tango'; calls.length=0;
    await click();
    assert.equal(calls.length,0);
    assert.match(alerts.pop(),/two different dance styles/);
  }
}
console.log('New style catalog, separate song saves, optional free-text performances, Fusion validation, and music callback snapshots verified.');
