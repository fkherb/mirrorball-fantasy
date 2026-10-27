-- Who goes home (iOS Home): lock in your pick, and picks close 15 minutes (was 10) before
-- the week's last night ends. Applied 2026-10-27 as migration elimination_pick_lock_in.
--
-- confirmed_at: set when you lock your pick in; the app won't change a locked pick until
-- you unlock it (allowed while picks are open, by the existing "change pick while open" policy).
alter table public.elimination_picks add column if not exists confirmed_at timestamptz;

create or replace function public.elimination_pick_deadline(p_week_id uuid)
 returns timestamp with time zone
 language sql
 stable
 set search_path to 'public'
as $function$
  select ((coalesce(w.second_air_date, w.air_date))::timestamp
          + coalesce(case when w.second_air_date is not null then w.second_air_end_time else w.air_end_time end, time '22:00'))
         at time zone 'America/New_York' - interval '15 minutes'
  from weeks w where w.id = p_week_id
$function$;
