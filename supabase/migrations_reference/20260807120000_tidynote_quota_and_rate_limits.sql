-- TidyNote (a separate app) shares this Supabase project with Relora.
--
-- Sharing was a deliberate call: the free tier caps at two active projects per
-- user. Isolation is therefore by naming, not by project or schema. Everything
-- TidyNote owns carries a `tidynote_` prefix and lives in `public`, because a
-- dedicated Postgres schema would need a PostgREST `db-schema` change, and that
-- setting is project-wide -- it would alter Relora's API surface. The prefix
-- costs nothing and touches nothing of Relora's.
--
-- Nothing in this migration reads, writes, or references any Relora object.
--
-- Both tables are written only by the `tidynote_organize` edge function through
-- the service role. RLS is enabled with no policies, which denies every
-- anon/authenticated request outright (the service role bypasses RLS). Execute
-- on the two functions is revoked from PUBLIC as well: without that, any holder
-- of the publishable anon key -- which ships inside the app -- could call them
-- over PostgREST and burn another install's monthly quota.

create table if not exists public.tidynote_cloud_quota (
  user_id text not null,
  month text not null,
  count int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, month)
);

alter table public.tidynote_cloud_quota enable row level security;

comment on table public.tidynote_cloud_quota is
  'TidyNote premium-tidy usage, one row per anonymous app user per calendar month (UTC). Service-role only; written exclusively by the tidynote_organize edge function.';

create table if not exists public.tidynote_rate_limits (
  key text not null,
  window_start text not null,
  count int not null default 0,
  primary key (key, window_start)
);

alter table public.tidynote_rate_limits enable row level security;

comment on table public.tidynote_rate_limits is
  'TidyNote per-minute request counters keyed by "u:<appUserId>" or "ip:<sha256>". Rows are disposable; window_start is a UTC minute stamp.';

-- Consume one unit of a user's monthly quota, atomically.
--
-- The ceiling lives in the ON CONFLICT ... WHERE clause, so the check and the
-- increment are one statement and one row lock. A read-then-write version would
-- let two concurrent requests both observe count = 4 and both write 5.
--
-- When the ceiling blocks the update, RETURNING yields no row, so `consumed` is
-- empty and the second branch reports the current count instead. The count read
-- there is snapshot-consistent rather than freshly locked, but it only feeds the
-- number shown to the user; the allow/deny decision itself is always exact.
create or replace function public.tidynote_consume_quota(
  p_user_id text,
  p_month text,
  p_limit int
)
returns table (allowed boolean, used int)
language sql
set search_path = ''
as $$
  with consumed as (
    insert into public.tidynote_cloud_quota as q (user_id, month, count, updated_at)
    select p_user_id, p_month, 1, now()
    where p_limit > 0
    on conflict (user_id, month) do update
      set count = q.count + 1,
          updated_at = now()
      where q.count < p_limit
    returning q.count as new_count
  )
  select true, c.new_count
  from consumed c
  union all
  select
    false,
    coalesce(
      (
        select q.count
        from public.tidynote_cloud_quota q
        where q.user_id = p_user_id and q.month = p_month
      ),
      greatest(p_limit, 0)
    )
  where not exists (select 1 from consumed);
$$;

comment on function public.tidynote_consume_quota(text, text, int) is
  'Atomically consumes one TidyNote premium tidy. Returns (allowed, used); allowed is false once used has reached p_limit.';

-- Same single-statement ceiling, for a fixed-width rate-limit window.
create or replace function public.tidynote_consume_rate(
  p_key text,
  p_window text,
  p_limit int
)
returns boolean
language sql
set search_path = ''
as $$
  with consumed as (
    insert into public.tidynote_rate_limits as r (key, window_start, count)
    select p_key, p_window, 1
    where p_limit > 0
    on conflict (key, window_start) do update
      set count = r.count + 1
      where r.count < p_limit
    returning 1
  )
  select exists (select 1 from consumed);
$$;

comment on function public.tidynote_consume_rate(text, text, int) is
  'Atomically consumes one request against a rate-limit window. Returns false once the window is full.';

revoke all on table public.tidynote_cloud_quota from anon, authenticated;
revoke all on table public.tidynote_rate_limits from anon, authenticated;

revoke all on function public.tidynote_consume_quota(text, text, int) from public;
revoke all on function public.tidynote_consume_rate(text, text, int) from public;

grant execute on function public.tidynote_consume_quota(text, text, int) to service_role;
grant execute on function public.tidynote_consume_rate(text, text, int) to service_role;
