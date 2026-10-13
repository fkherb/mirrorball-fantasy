// Test the deployed Edge Function protocol with mocked HTTP; no real music
// lookup, database write, credentials, or listening server is used.
import assert from 'node:assert/strict';
const originalFetch=globalThis.fetch;
const originalDeno=globalThis.Deno;
let handler;let found=true;let authorized=true;let pendingCalls=0;
const callbacks=[];
const dance={id:'test-dance',song_title:'Test song',song_artist:'Test artist'};
globalThis.Deno={
  env:{get(name){return name==='SUPABASE_URL'?'https://database.test':
    name==='SUPABASE_SERVICE_ROLE_KEY'?'fake-local-test-key':undefined;}},
  serve(fn){handler=fn;return{};},
};
globalThis.fetch=async(input,options={})=>{
  const url=String(input);
  const payload=options.body?JSON.parse(options.body):{};
  const json=value=>new Response(JSON.stringify(value),{headers:{'content-type':'application/json'}});
  if(url.endsWith('/rpc/music_match_authorized'))return json(authorized);
  if(url.endsWith('/rpc/pending_dance_music_matches')){pendingCalls++;return json([dance]);}
  if(url.endsWith('/rpc/record_dance_music_match_v2')){callbacks.push(payload);return json(null);}
  if(url.startsWith('https://itunes.apple.com/'))return json({results:found?[{
    trackName:dance.song_title,artistName:dance.song_artist,collectionName:'Studio album',
    collectionType:'Album',kind:'song',wrapperType:'track',releaseDate:'1995-01-01T00:00:00Z',
    trackViewUrl:'https://music.apple.com/us/album/test-song/1?i=2',
  }]:[]});
  throw Error('Unexpected/unmocked HTTP request: '+url);
};
try{
  await import('../supabase/functions/match-dance-songs/index.ts');
  assert.equal(typeof handler,'function');
  const request=()=>new Request('https://functions.test/match-dance-songs',{
    method:'POST',headers:{authorization:'Bearer fake-cron-test-token','content-type':'application/json'},
    body:'{}',
  });
  let response=await handler(request());
  assert.equal(response.status,200);
  let body=await response.json();
  assert.equal(body.results[0].status,'matched');
  assert.deepEqual(callbacks[0],{
    p_dance_id:dance.id,p_song_title:dance.song_title,p_song_artist:dance.song_artist,
    p_apple_url:'https://music.apple.com/us/album/test-song/1?i=2',p_spotify_url:null,p_status:'matched',
  });
  found=false;response=await handler(request());
  assert.equal(response.status,200);
  body=await response.json();assert.equal(body.results[0].status,'no_match');
  assert.deepEqual(callbacks[1],{
    p_dance_id:dance.id,p_song_title:dance.song_title,p_song_artist:dance.song_artist,
    p_apple_url:null,p_spotify_url:null,p_status:'no_match',
  });
  authorized=false;const before=pendingCalls;
  response=await handler(request());
  assert.equal(response.status,401);
  assert.equal(pendingCalls,before,'Unauthorized callers must not claim any music work.');
  assert.equal(callbacks.length,2);
  console.log('Music matched/no-match callbacks carry both song fields; custom authentication remains enforced.');
}finally{globalThis.fetch=originalFetch;globalThis.Deno=originalDeno;}
