-- Isolated regression database only. Roll back fixtures so worker tests can
-- continue with the original eleven Week 5 couples.
begin;
create function pg_temp.check_song_style(condition boolean,message text) returns void language plpgsql as $$
begin if condition is distinct from true then raise exception 'TEST FAILED: %',message; end if; end $$;
do $$
declare w uuid;pair uuid;cast_id uuid;perf uuid;comp uuid;old_id uuid;old_count bigint;
  original jsonb;actual jsonb;
begin
  select id into w from public.weeks where number=5;
  select id into pair from public.partnerships order by id limit 1;
  select id into cast_id from public.cast_members order by id limit 1;
  perform pg_temp.check_song_style(public.canonical_dance_type('bolero')='Bolero','Old helper reads new catalog');
  perform pg_temp.check_song_style(public.canonical_dance_style('cha cha cha / tango fusion')='Cha-cha/Tango Fusion','Wiki spelling and Fusion normalize');
  begin perform public.canonical_dance_style('Retired style'); raise exception 'TEST FAILED: Old catalog accepted';
    exception when others then if sqlerrm like 'TEST FAILED:%' then raise; end if; end;
  begin perform public.canonical_dance_style('Cha-cha/cha cha Fusion'); raise exception 'TEST FAILED: Duplicate Fusion accepted';
    exception when others then if sqlerrm like 'TEST FAILED:%' then raise; end if; end;
  begin perform public.canonical_dance_style('Fusion'); raise exception 'TEST FAILED: Bare Fusion accepted';
    exception when others then if sqlerrm like 'TEST FAILED:%' then raise; end if; end;
  perf:=public.save_dance_atomic_v2(w,null,'performance',null,null,null,
    'Title by the Sea','Music by Friends','[]','{}',false,
    '{"performance_type":"Anything / experimental freestyle","choreography":"The troupe","airing_night":2}');
  perform pg_temp.check_song_style((select song_title='Title by the Sea' and song_artist='Music by Friends'
    and song='Title by the Sea by Music by Friends' and performance_type='Anything / experimental freestyle'
    and choreography='The troupe' and airing_night=2 and dance_type is null from public.dances where id=perf),
    'Separate values never parsed; performance free text saved atomically');
  comp:=public.save_dance_atomic_v2(w,null,'competitive',pair,null,'Bolero','Song','Artist',
    '[{"judge_name":"Carrie Ann","score":8},{"judge_name":"Derek","score":7},{"judge_name":"Bruno","score":9}]',
    array[cast_id],false);
  perform pg_temp.check_song_style((select dance_type='Bolero' and song_confirmed and dance_type_confirmed from public.dances where id=comp),'Competitive catalog and manual confirmation');
  old_id:=public.save_dance_atomic(p_week_id=>w,p_dance_id=>null,p_kind=>'performance',p_partnership_id=>null,
    p_name=>null,p_dance_type=>null,p_song=>'Legacy title by Legacy artist');
  perform pg_temp.check_song_style((select song_title='Legacy title' and song_artist='Legacy artist' from public.dances where id=old_id),'Legacy endpoint keeps working');
  perform public.save_dance_atomic(p_week_id=>w,p_dance_id=>old_id,p_kind=>'performance',p_partnership_id=>null,
    p_name=>null,p_dance_type=>null,p_song=>'Ignored stale value',
    p_song_title=>'New by Title',p_song_artist=>'New by Artist');
  perform pg_temp.check_song_style((select song_title='New by Title' and song_artist='New by Artist' from public.dances where id=old_id),'Expanded original endpoint accepts and prioritizes new fields');
  update public.dances set song='Direct legacy by Direct artist' where id=old_id;
  perform pg_temp.check_song_style((select song_title='Direct legacy' and song_artist='Direct artist' from public.dances where id=old_id),'Cached direct writes bridge safely');
  perform pg_temp.check_song_style((select calls>0 from mirrorball_private.legacy_song_usage where source='save_dance_atomic'),'Legacy API usage counted');
  perform pg_temp.check_song_style((select calls>0 from mirrorball_private.legacy_song_usage where source='direct_song_write'),'Legacy column writes counted');

  update public.dances set apple_music_url='https://music.apple.com/test',spotify_url='https://open.spotify.com/track/test',
    music_match_status='matched',music_matched_at=now() where id=comp;
  update public.dances set song_artist='Changed artist' where id=comp;
  perform pg_temp.check_song_style((select apple_music_url is null and spotify_url is null
    and music_match_status='pending' and song_confirmed from public.dances where id=comp),'Artist changes invalidate automatic matches and confirm manual details');
  perform public.record_dance_music_match_v2(comp,'Song','Artist','https://music.apple.com/stale',null,'matched');
  perform pg_temp.check_song_style((select apple_music_url is null from public.dances where id=comp),'Stale artist callback ignored');
  perform public.record_dance_music_match_v2(comp,'Song','Changed artist','https://music.apple.com/current',null,'matched');
  perform pg_temp.check_song_style((select apple_music_url='https://music.apple.com/current' from public.dances where id=comp),'Matching title and artist callback accepted');
  update public.dances set music_match_status='manual',apple_music_url='https://music.apple.com/manual' where id=comp;
  update public.dances set song_title='Edited title',song_artist='Edited artist' where id=comp;
  perform pg_temp.check_song_style((select apple_music_url='https://music.apple.com/manual' and music_match_status='manual'
    and song='Edited title by Edited artist' from public.dances where id=comp),'Manual links preserved');
  perform public.record_dance_music_match_v2(comp,'Edited title','Edited artist','https://music.apple.com/auto',null,'matched');
  perform pg_temp.check_song_style((select apple_music_url='https://music.apple.com/manual' from public.dances where id=comp),'Worker cannot overwrite manual links');
  update public.dances set music_match_status='matched' where id=comp;
  perform public.save_dance_atomic_v2(w,comp,'competitive',pair,null,'Bolero',null,null,'[]',array[cast_id],false);
  perform pg_temp.check_song_style((select song is null and song_title is null and song_artist is null
    and music_match_status is null and apple_music_url is null and not song_confirmed from public.dances where id=comp),'Clear both song fields without resurrecting legacy value');
  perform public.save_dance_atomic_v2(w,comp,'competitive',pair,null,'Bolero','Score-only title','Score-only artist','[]',array[cast_id],false);
  select to_jsonb(d) into original from public.dances d where id=comp;
  begin
    perform public.save_dance_atomic_v2(w,comp,'competitive',pair,null,'Rumba','Wrong','Wrong',
      '[{"judge_name":"Nobody","score":8}]','{}',false);
    raise exception 'TEST FAILED: Invalid judge accepted';
  exception when others then if sqlerrm like 'TEST FAILED:%' then raise; end if; end;
  perform pg_temp.check_song_style((select to_jsonb(d)=original from public.dances d where id=comp),'Validation failure rolls back dance');
  begin
    perform public.save_dance_atomic_v2(w,comp,'competitive',pair,null,'Rumba','Wrong','Wrong','[]',
      array['00000000-0000-0000-0000-000000000999'::uuid],false);
    raise exception 'TEST FAILED: Invalid cast accepted';
  exception when foreign_key_violation then null; end;
  perform pg_temp.check_song_style((select to_jsonb(d)=original from public.dances d where id=comp),'Late cast error rolls back all row changes');
  update public.weeks set is_complete=true where id=w;
  perform public.save_dance_atomic_v2(w,comp,'competitive',null,null,'Wrong','Wrong','Wrong',
    '[{"judge_name":"Carrie Ann","score":10}]','{}',true,'{"performance_type":"Wrong"}');
  perform pg_temp.check_song_style((select song_title='Score-only title' and song_artist='Score-only artist' and dance_type='Bolero'
    from public.dances where id=comp),'Score-only correction preserves metadata');
  perform pg_temp.check_song_style((select count(*)=1 from public.dance_appearances where dance_id=comp),'Score-only correction preserves cast');
  begin
    perform public.save_dance_atomic_v2(w,comp,'competitive',pair,null,'Rumba','Wrong','Wrong','[]','{}',false);
    raise exception 'TEST FAILED: Completed detail edit accepted';
  exception when others then if sqlerrm like 'TEST FAILED:%' then raise; end if; end;
  perform set_config('test.owner','no',true);
  begin
    perform public.save_dance_atomic_v2(w,null,'performance',null,null,null,null,null,'[]','{}',false);
    raise exception 'TEST FAILED: Unauthorized save accepted';
  exception when others then if sqlerrm like 'TEST FAILED:%' then raise; end if; end;
  perform set_config('test.owner','yes',true);
  perform pg_temp.check_song_style(not has_function_privilege('anon',
    'public.save_dance_atomic_v2(uuid,uuid,text,uuid,text,text,text,text,jsonb,uuid[],boolean,jsonb)','execute'),'Anonymous save forbidden');
  perform pg_temp.check_song_style(not has_function_privilege('authenticated',
    'public.record_dance_music_match_v2(uuid,text,text,text,text,text)','execute'),'Clients cannot finalize automatic music matches');
  perform pg_temp.check_song_style(not has_table_privilege('authenticated','mirrorball_private.legacy_song_usage','select'),'Legacy ledger private');
  perform pg_temp.check_song_style((public.get_song_format_migration_status()->>'mirror_mismatches')::integer=0,'Compatibility mirrors remain consistent');
end $$;
rollback;
