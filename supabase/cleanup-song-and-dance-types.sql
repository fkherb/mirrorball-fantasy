-- cleanup-song-and-dance-types.sql — the last step of song-and-dance-styles-plan.md.
-- Run once in the Supabase SQL editor (2026-10-16). Safe now because:
--   • every app is build 15+ (ios_min_build = 15) and saves through save_dance_atomic_v2;
--   • get_song_format_migration_status(): legacy_calls = [], mirror_mismatches = 0;
--   • nothing in the database, website (origin/main df3105f) or worker calls the old
--     save_dance_atomic, update_performance_dance_details or dance_song_part, and no
--     function, view or foreign key reads dance_types (get_week_automation_status only
--     uses 'dance_types' as a JSON key name).
begin;

drop trigger if exists sync_dance_song_compatibility on public.dances;
drop function if exists public.sync_dance_song_compatibility();
drop function if exists public.save_dance_atomic(uuid, uuid, text, uuid, text, text, text, jsonb, uuid[], boolean, text, text);
drop function if exists public.update_performance_dance_details(uuid, text, text);
drop function if exists public.dance_song_part(text, integer);
drop function if exists public.get_song_format_migration_status();

alter table public.dances drop column if exists song;
drop table if exists public.dance_types;

-- Leftovers from the YouTube matcher setup (2026-10-15).
drop table if exists public._youtube_match_snapshot;
drop function if exists public.youtube_match_work_unused();

commit;
