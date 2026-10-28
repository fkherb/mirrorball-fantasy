-- Medleys: one Apple Music / Spotify link pair per song (2026-10-28, migration dance_medley_song_links).
-- song_links follows the order of song_title's semicolon-separated songs:
--   [{"apple": "https://music.apple.com/...", "spotify": "https://open.spotify.com/track/..."}, ...]
-- The iOS app uses each song's pair and falls back to a search for a song without one.
alter table public.dances add column if not exists song_links jsonb;
alter table public.dances drop constraint if exists dances_song_links_shape;
alter table public.dances add constraint dances_song_links_shape check (
  song_links is null or (jsonb_typeof(song_links) = 'array' and not jsonb_path_exists(song_links,
    '$[*] ? (@.type() != "object"
             || (exists(@.apple) && @.apple != null && !(@.apple starts with "https://music.apple.com/"))
             || (exists(@.spotify) && @.spotify != null && !(@.spotify starts with "https://open.spotify.com/track/")))')));

-- A changed song clears song_links along with the single links (unless set by hand).
create or replace function public.refresh_dance_music_links()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
declare changed boolean;
begin
  changed:=tg_op='INSERT';
  if tg_op='UPDATE' then
    changed:=new.song_title is distinct from old.song_title or new.song_artist is distinct from old.song_artist;
    if coalesce(old.music_match_status,'')='manual' then return new; end if;
  end if;
  if changed and coalesce(new.music_match_status,'')<>'manual' then
    new.apple_music_url:=null; new.spotify_url:=null; new.song_links:=null; new.music_matched_at:=null;
    new.music_match_status:=case when new.song_title is null then null else 'pending' end;
  end if;
  return new;
end $function$;
