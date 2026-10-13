-- Public display metadata for the same judge panel used by the worker.
-- Automation settings remain the source of the Wikipedia tuple order.
begin;
set local lock_timeout = '5s';

alter table public.weeks
  add column if not exists judge_order text[],
  add column if not exists guest_judge_image_path text,
  add column if not exists guest_judge_avatar_frame jsonb not null default '{}'::jsonb;

create or replace function public.validate_week_judge_display()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare expected text[] := array['Carrie Ann','Derek','Bruno'];
begin
  if nullif(btrim(new.guest_judge_name),'') is not null then
    expected := expected || array[btrim(new.guest_judge_name)];
  end if;
  if tg_op = 'UPDATE' and new.guest_judge_name is distinct from old.guest_judge_name then
    if new.judge_order is not distinct from old.judge_order then new.judge_order := null; end if;
    -- A replacement guest must not inherit the previous guest's portrait.
    if new.guest_judge_image_path is not distinct from old.guest_judge_image_path then
      new.guest_judge_image_path := null;
      new.guest_judge_avatar_frame := '{}'::jsonb;
    end if;
  end if;
  new.judge_order := coalesce(new.judge_order, expected);
  if cardinality(new.judge_order) <> cardinality(expected)
    or array_position(new.judge_order,null) is not null
    or not new.judge_order @> expected or not new.judge_order <@ expected then
    raise exception 'Judge order must contain every judge exactly once';
  end if;
  if nullif(btrim(new.guest_judge_name),'') is null then
    new.guest_judge_image_path := null;
    new.guest_judge_avatar_frame := '{}'::jsonb;
  end if;
  return new;
end $$;
revoke all on function public.validate_week_judge_display() from public,anon,authenticated;
drop trigger if exists validate_week_judge_display on public.weeks;
create trigger validate_week_judge_display
  before insert or update of guest_judge_name,judge_order on public.weeks
  for each row execute function public.validate_week_judge_display();

create or replace function public.sync_automation_judge_display()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    update public.weeks set judge_order = null where id = old.week_id;
    return old;
  end if;
  update public.weeks set judge_order = new.judge_order where id = new.week_id;
  return new;
end $$;
revoke all on function public.sync_automation_judge_display() from public,anon,authenticated;
drop trigger if exists sync_automation_judge_display on public.dwts_automation_weeks;
create trigger sync_automation_judge_display
  after insert or update of judge_order or delete on public.dwts_automation_weeks
  for each row execute function public.sync_automation_judge_display();

-- Expose only the panel, not private worker status, to existing week readers.
update public.weeks w set judge_order = a.judge_order
  from public.dwts_automation_weeks a where a.week_id = w.id
  and w.judge_order is distinct from a.judge_order;
update public.weeks set judge_order = null where judge_order is null;

comment on column public.weeks.judge_order is
  'Public display copy of dwts_automation_weeks.judge_order; configure via the existing week automation controls.';
comment on column public.weeks.guest_judge_image_path is
  'Optional repository portrait path for a guest judge who is not a cast member.';
comment on column public.weeks.guest_judge_avatar_frame is
  'Circular portrait crop: x/y percentages and zoom, using the same framing as cast headshots.';

-- Tonight's panel. Do not change schedule, modes, dances, or cast membership.
update public.weeks set guest_judge_name = 'Joe Buck',
  guest_judge_image_path = 'Images/Cast Thumbnails/Joe Buck.webp',
  guest_judge_avatar_frame = '{"x":54,"y":5,"zoom":1.7}'::jsonb
where number = 5 and air_date = date '2026-10-13';
update public.dwts_automation_weeks a
  set judge_order = array['Carrie Ann','Derek','Joe Buck','Bruno'], updated_at = now()
  from public.weeks w where w.id = a.week_id
  and w.number = 5 and w.air_date = date '2026-10-13';

notify pgrst,'reload schema';
commit;
