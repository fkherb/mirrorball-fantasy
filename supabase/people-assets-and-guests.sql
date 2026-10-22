-- People assets and guests (applied to production 2026-10-22 via SQL editor; kept here as the record).
-- Assets/<Pros|Stars|Bonus|Guest>/<Name>/ is the source of truth for cast and guest photos and bios.
-- The "Prepare people photos" Action syncs folders (people-sync), renders Images/People/<Name>/
-- {profile,card,portrait,full}.webp with the crops set in the app, and records them (people-rendered).

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  bio text,
  hometown text,
  birthdate text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.guests enable row level security;
create policy "guests are public" on public.guests for select using (true);
create policy "platform owner writes guests" on public.guests for all using (public.is_platform_admin()) with check (public.is_platform_admin());

alter table public.cast_members add column if not exists hometown text;
alter table public.cast_members add column if not exists birthdate text;

create table if not exists public.people_assets (
  id uuid primary key default gen_random_uuid(),
  folder text not null unique,                       -- e.g. Assets/Pros/Emma Slater
  category text not null check (category in ('Pros', 'Stars', 'Bonus', 'Guest')),
  name text not null,
  source_photo text,
  source_sha text,
  source_width integer,
  source_height integer,
  cast_member_id uuid unique references public.cast_members(id) on delete set null,
  guest_id uuid unique references public.guests(id) on delete set null,
  crops jsonb not null default '{}'::jsonb,          -- {profile|card|portrait: {x, y, zoom}}
  crops_updated_at timestamptz,
  rendered_crops jsonb,
  rendered_sha text,
  photo_version integer not null default 0,          -- cache-buster for Images/People files
  missing boolean not null default false,
  synced_at timestamptz,
  rendered_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.people_assets enable row level security;
create policy "people assets are public" on public.people_assets for select using (true);

alter table public.weeks add column if not exists guest_judge_id uuid references public.guests(id) on delete set null;

create or replace function public.link_week_guest_judge() returns trigger language plpgsql set search_path to 'public' as $$
begin
  new.guest_judge_id := (select g.id from public.guests g
    where lower(g.name) = lower(nullif(btrim(new.guest_judge_name), '')) limit 1);
  return new;
end $$;
create trigger weeks_link_guest_judge before insert or update of guest_judge_name on public.weeks
  for each row execute function public.link_week_guest_judge();

-- Service role only (called by dwts-automation-worker 'people-sync').
create or replace function public.sync_people_assets(p_people jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare p jsonb; a public.people_assets%rowtype; gid uuid; cid uuid; folders text[] := '{}';
begin
  if jsonb_typeof(p_people) <> 'array' then raise exception 'people must be an array'; end if;
  for p in select * from jsonb_array_elements(p_people) loop
    folders := folders || (p->>'folder');
    insert into people_assets(folder, category, name) values (p->>'folder', p->>'category', p->>'name')
      on conflict (folder) do update set category = excluded.category, name = excluded.name
      returning * into a;
    gid := a.guest_id; cid := a.cast_member_id;
    if p->>'category' = 'Guest' then
      insert into guests(name, bio, hometown, birthdate)
        values (p->>'name', nullif(p->>'bio',''), nullif(p->>'hometown',''), nullif(p->>'birthdate',''))
        on conflict (name) do update set bio = coalesce(excluded.bio, guests.bio), hometown = coalesce(excluded.hometown, guests.hometown),
          birthdate = coalesce(excluded.birthdate, guests.birthdate), updated_at = now()
        returning id into gid;
      cid := null;
    else
      cid := coalesce(cid, (select id from cast_members where lower(name) = lower(p->>'name') limit 1));
      if cid is not null then
        update cast_members set bio = coalesce(nullif(p->>'bio',''), bio), hometown = coalesce(nullif(p->>'hometown',''), hometown),
          birthdate = coalesce(nullif(p->>'birthdate',''), birthdate) where id = cid;
      end if;
      gid := null;
    end if;
    update people_assets set guest_id = gid, cast_member_id = cid, source_photo = nullif(p->>'source_photo',''),
      source_sha = nullif(p->>'source_sha',''), source_width = nullif(p->>'width','')::integer,
      source_height = nullif(p->>'height','')::integer, missing = false, synced_at = now(), updated_at = now()
    where id = a.id;
  end loop;
  update people_assets set missing = true, updated_at = now() where not (folder = any(folders)) and not missing;
  update weeks w set guest_judge_id = g.id from guests g
    where w.guest_judge_id is null and lower(g.name) = lower(btrim(w.guest_judge_name));
  return coalesce((select jsonb_agg(jsonb_build_object('folder', folder, 'name', name, 'crops', crops,
    'rendered_crops', rendered_crops, 'rendered_sha', rendered_sha, 'photo_version', photo_version) order by folder)
    from people_assets where not missing), '[]'::jsonb);
end $$;

-- Service role only (dwts-automation-worker 'people-rendered').
create or replace function public.record_people_photos_rendered(p_rendered jsonb) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; n integer := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rendered, '[]'::jsonb)) loop
    update people_assets set rendered_crops = r->'crops', rendered_sha = r->>'source_sha',
      photo_version = photo_version + 1, rendered_at = now(), updated_at = now()
    where folder = r->>'folder';
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke execute on function public.sync_people_assets(jsonb), public.record_people_photos_rendered(jsonb) from public, anon, authenticated;

create or replace function public.set_people_photo_crops(p_asset_id uuid, p_crops jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if jsonb_typeof(p_crops) <> 'object' then raise exception 'Crops must be an object'; end if;
  update people_assets set crops = p_crops, crops_updated_at = now(), updated_at = now() where id = p_asset_id;
  if not found then raise exception 'Photo not found.'; end if;
end $$;

create or replace function public.add_cast_from_asset(p_asset_id uuid, p_role text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare a public.people_assets%rowtype; cid uuid;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  select * into a from people_assets where id = p_asset_id for update;
  if not found then raise exception 'Folder not found.'; end if;
  if a.category = 'Guest' then raise exception 'Guests are added automatically.'; end if;
  if a.cast_member_id is not null then return a.cast_member_id; end if;
  if not exists (select 1 from roles where name = p_role) then raise exception 'Unknown role.'; end if;
  select id into cid from cast_members where lower(name) = lower(a.name);
  if cid is null then
    insert into cast_members(name, role, role_id, is_hough) values (a.name, p_role, (select id from roles where name = p_role), false)
      returning id into cid;
  end if;
  update people_assets set cast_member_id = cid, updated_at = now() where id = a.id;
  return cid;
end $$;

-- Crops saved in the app start the Action (repository_dispatch people-photos), at most every 3 minutes.
create table if not exists public.people_photos_dispatch_state (
  id integer primary key default 1 check (id = 1),
  last_dispatch_at timestamptz,
  last_request_id bigint
);
alter table public.people_photos_dispatch_state enable row level security;
insert into public.people_photos_dispatch_state(id) values (1) on conflict do nothing;

create or replace function public.dispatch_people_photos(p_force boolean default false) returns text
language plpgsql security definer set search_path to '' as $$
declare s public.people_photos_dispatch_state%rowtype; token text; repo text; rid bigint;
begin
  select * into s from public.people_photos_dispatch_state where id = 1 for update;
  if not p_force then
    if not exists (select 1 from public.people_assets where not missing and source_photo is not null
                   and crops_updated_at > coalesce(rendered_at, '-infinity')
                   and crops_updated_at > coalesce(s.last_dispatch_at, '-infinity')) then return 'nothing to render'; end if;
    if s.last_dispatch_at > now() - interval '3 minutes' then return 'recently dispatched'; end if;
  end if;
  select decrypted_secret into token from vault.decrypted_secrets where name = 'github_dispatch_token';
  if token is null then return 'missing github_dispatch_token'; end if;
  select repository into repo from public.dwts_dispatch_state where id = 1;
  select net.http_post(
    url := 'https://api.github.com/repos/' || coalesce(repo, 'fkherb/mirrorball-fantasy') || '/dispatches',
    body := jsonb_build_object('event_type', 'people-photos'),
    headers := jsonb_build_object('Accept', 'application/vnd.github+json', 'Authorization', 'Bearer ' || token,
      'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'mirrorball-dispatcher', 'Content-Type', 'application/json'),
    timeout_milliseconds := 15000) into rid;
  update public.people_photos_dispatch_state set last_dispatch_at = now(), last_request_id = rid where id = 1;
  return 'dispatched';
end $$;
revoke execute on function public.dispatch_people_photos(boolean) from public, anon, authenticated;

create or replace function public.request_people_photos_render() returns text
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  return public.dispatch_people_photos(true);
end $$;

select cron.schedule('mirrorball-people-photos', '* * * * *', $$select public.dispatch_people_photos(false)$$);

-- 2026-10-22 (later): bios are never applied automatically.
-- sync_people_assets stores each .txt in people_assets.file_bio and creates new guests by name only;
-- apply_asset_bio (app: "Use Assets bio") copies it to the live cast member or guest;
-- request_asset_bio (app: "Generate bio") dispatches "people-bios" so generate-people-bios.yml drafts
-- <Name>.txt from Wikipedia; pending_people_bios / record_people_bios are its service-only endpoints.
alter table public.people_assets add column if not exists file_bio jsonb,
  add column if not exists bio_status text check (bio_status in ('requested','generated','failed')),
  add column if not exists bio_message text,
  add column if not exists bio_requested_at timestamptz;
alter table public.guests add column if not exists career_highlights text;
-- (Function bodies as deployed: see pg_get_functiondef for sync_people_assets, apply_asset_bio,
--  request_asset_bio, pending_people_bios and record_people_bios.)
revoke execute on function public.pending_people_bios(), public.record_people_bios(jsonb) from public, anon, authenticated;

-- The worker calls these with the service role, which needs an explicit grant once public is revoked.
grant execute on function public.sync_people_assets(jsonb), public.record_people_photos_rendered(jsonb),
  public.pending_people_bios(), public.record_people_bios(jsonb) to service_role;

-- 2026-10-22: Images/People replaces Images/<Name>.jpg, Images/Cast Thumbnails and Images/Guests.
-- cast_members.image_path and weeks.guest_judge_image_path always point at the rendered portrait
-- (Images/People/<Name>/portrait.webp?v=<photo_version>); clients swap portrait → profile for circles.
-- Crops are baked into the files, so _avatar_frame and guest_judge_avatar_frame are no longer used.
create or replace function public.people_photo_path(p_name text, p_variant text default 'portrait') returns text
language sql stable security definer set search_path to '' as $$
  select 'Images/People/' || a.name || '/' || p_variant || '.webp?v=' || a.photo_version
  from public.people_assets a
  where lower(a.name) = lower(btrim(p_name)) and a.photo_version > 0 and not a.missing and a.source_photo is not null
  order by a.category = 'Guest' limit 1;
$$;

create or replace function public.cast_member_people_photo() returns trigger
language plpgsql set search_path to '' as $$
declare path text;
begin
  select 'Images/People/' || a.name || '/portrait.webp?v=' || a.photo_version into path
  from public.people_assets a
  where (a.cast_member_id = new.id or (a.cast_member_id is null and lower(a.name) = lower(btrim(new.name))))
    and a.photo_version > 0 and not a.missing and a.source_photo is not null
  order by a.cast_member_id is null limit 1;
  if path is not null then
    new.image_path := path;
    new.image_position := 50;
  end if;
  return new;
end $$;
create trigger cast_members_people_photo before insert or update on public.cast_members
  for each row execute function public.cast_member_people_photo();

CREATE OR REPLACE FUNCTION public.validate_week_judge_display() RETURNS trigger
LANGUAGE plpgsql SET search_path TO '' AS $function$
declare expected text[] := public.regular_judge_names();
begin
  new.guest_judge_name := nullif(regexp_replace(btrim(new.guest_judge_name),'\s+',' ','g'),'');
  if new.guest_judge_name is not null then expected := expected || array[new.guest_judge_name]; end if;
  if tg_op='UPDATE' and new.guest_judge_name is distinct from old.guest_judge_name then
    if new.judge_order is not distinct from old.judge_order then new.judge_order := null; end if;
  end if;
  new.judge_order := coalesce(new.judge_order,expected);
  if cardinality(new.judge_order)<>cardinality(expected) or array_position(new.judge_order,null) is not null
    or not new.judge_order @> expected or not new.judge_order <@ expected then
    raise exception 'Judge order must contain every judge exactly once';
  end if;
  new.guest_judge_image_path := case when new.guest_judge_name is null then null
    else public.people_photo_path(new.guest_judge_name, 'portrait') end;
  new.guest_judge_avatar_frame := '{}'::jsonb;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.record_people_photos_rendered(p_rendered jsonb) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
declare r jsonb; n integer := 0; a public.people_assets%rowtype;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rendered, '[]'::jsonb)) loop
    update people_assets set rendered_crops = r->'crops', rendered_sha = r->>'source_sha',
      photo_version = photo_version + 1, rendered_at = now(), updated_at = now()
    where folder = r->>'folder' returning * into a;
    if found then
      n := n + 1;
      if a.cast_member_id is not null then update cast_members set image_path = image_path where id = a.cast_member_id; end if;
      if a.guest_id is not null then update weeks set guest_judge_name = guest_judge_name where guest_judge_id = a.guest_id; end if;
    end if;
  end loop;
  return n;
end $$;

-- Backfill (run once): every cast member and guest-judge week to Images/People; drop the old avatar crops.
update public.cast_members set image_path = image_path, profile_details = coalesce(profile_details, '{}'::jsonb) - '_avatar_frame';
update public.weeks set guest_judge_name = guest_judge_name where guest_judge_name is not null;
