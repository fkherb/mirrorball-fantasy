-- Who sang or played a dance's music live (e.g. "Heather Headley"), shown as "Performed live by";
-- special_guest stays for people who joined the couple on the floor. Applied 2026-10-30 (dance_live_performer).
alter table public.dances add column if not exists live_performer text;
