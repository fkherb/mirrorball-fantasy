-- Isolated test database only. Extend the existing automation fixture with the
-- production dance fields and permissive fixture ACLs; production ACLs stay unchanged.
alter table public.weeks add column is_season_finale boolean not null default false;
alter table public.cast_members add column role text;
update public.cast_members set role=case when name in ('Pasha Pashkov','Rylee Arnold') then 'Pro' else 'Star' end;
alter table public.partnerships add column active boolean not null default true;
alter table public.dances add column name text, add column choreography text,
  add column performance_type text, add column airing_night smallint,
  add column song_title text, add column song_artist text,
  add column apple_music_url text, add column spotify_url text,
  add column music_match_status text, add column music_matched_at timestamptz;
alter table public.dances add constraint fixture_night check(airing_night in (1,2));
alter table public.dances add constraint dances_performance_without_type check(kind<>'performance' or dance_type is null);
create table public.dance_appearances(id uuid primary key default gen_random_uuid(),
  dance_id uuid references public.dances on delete cascade,
  cast_member_id uuid references public.cast_members);
create table public.dance_types(name text primary key);
insert into public.dance_types values('Rumba'),('Jive'),('Cha-cha'),('Tango'),('Fusion'),('Retired style');
create table public.dance_styles(name text primary key,type text not null,description text not null);
insert into public.dance_styles values
  ('Rumba','Latin','Test Rumba'),('Jive','Latin','Test Jive'),('Cha-cha','Latin','Test Cha-cha'),
  ('Tango','Standard','Test Tango'),('Fusion','Specialty','Test Fusion'),
  ('Bolero','Specialty','Test style that exists only in the new catalog');
create or replace function public.is_platform_admin() returns boolean language sql stable
  as $$ select current_setting('test.owner',true)='yes' $$;
create or replace function public.is_league_commissioner() returns boolean language sql stable
  as $$ select current_setting('test.owner',true)='yes' $$;
