-- Read-only verification after canonical_song_fields_and_dance_styles.
select public.get_song_format_migration_status();

select count(*) as catalog_styles,
  bool_and(name<>'' and type in ('Standard','Latin','Specialty')) as catalog_valid
from public.dance_styles;

select public.canonical_dance_style('Cha-cha-cha') as wiki_cha_cha,
  public.canonical_dance_style('cha cha / tango fusion') as wiki_fusion;

select p.proname,pg_get_function_arguments(p.oid) as arguments
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
  ('save_dance_atomic','save_dance_atomic_v2','record_dance_music_match_v2');

-- No normal importer/save/confirmation function may depend on the old fields
-- or table. Legacy adapters and the mirror trigger are intentionally excluded.
select p.proname as unexpected_dependency
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prokind='f'
  and p.proname in ('save_dance_atomic_v2','report_dwts_work_base',
    'ensure_week_competitive_dances','mark_manual_dance_details_confirmed',
    'record_manual_dance_confirmation','canonical_dance_type','canonical_dance_style')
  and p.prosrc ~ '(public\.dance_types|\mnew\.song\M|\mold\.song\M|\mset song\M|dance_type,song,sort_order)';

select name,performance_type,song_title,song_artist
from public.dances where kind='performance' order by week_id,sort_order;
