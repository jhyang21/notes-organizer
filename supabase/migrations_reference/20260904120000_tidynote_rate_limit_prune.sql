-- Prune spent TidyNote rate-limit windows.
--
-- `public.tidynote_rate_limits` holds one row per caller per minute. Nothing
-- ever deletes them, so the table grows by every request the function has ever
-- served and never shrinks. A window is dead the moment its minute passes:
-- `tidynote_consume_rate` only ever reads and writes the current minute, so an
-- old row is storage and nothing else.
--
-- One hour of history, not one minute. The extra slack costs almost nothing and
-- leaves recent rows in place to look at when a rate-limit complaint arrives.
--
-- `window_start` is text, not a timestamp: the edge function writes the
-- minute-truncated ISO stamp produced by `minuteKey` in index.ts,
-- `YYYY-MM-DDTHH:MM` in UTC. That format sorts lexicographically in the same
-- order it sorts chronologically, so the cutoff is a string built the same way
-- rather than a cast. A row whose stamp is malformed sorts below any real
-- cutoff and is swept with the rest, which is the right outcome for a row
-- nothing can match.
--
-- The quota table is deliberately untouched. Its rows are the month's usage
-- record and have to outlive the month.
--
-- Note: Relora's repository owns the real migration for this shared Supabase
-- project. This file is the reference copy that lives with the code it serves.

create extension if not exists pg_cron;

create or replace function public.tidynote_prune_rate_limits()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.tidynote_rate_limits
   where window_start < to_char(now() at time zone 'utc' - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI');
$$;

-- Revoking from PUBLIC is the whole job: anon and authenticated hold no grant
-- of their own on a function created here, only the one PUBLIC carries.
revoke all on function public.tidynote_prune_rate_limits() from public;

-- The IP half of the key is an HMAC now, not a bare digest; keep the table
-- comment honest.
comment on table public.tidynote_rate_limits is
  'TidyNote per-minute request counters keyed by "u:<appUserId>" or "ip:<hmac-sha256>". Rows are disposable; window_start is a UTC minute stamp, pruned after one hour.';

comment on function public.tidynote_prune_rate_limits() is
  'Deletes TidyNote rate-limit windows older than one hour. Scheduled by pg_cron every 15 minutes.';

-- Re-scheduling is idempotent: unschedule any previous job with this name.
do $$
begin
  perform cron.unschedule('tidynote-prune-rate-limits');
exception
  when others then null; -- job did not exist yet
end;
$$;

select cron.schedule(
  'tidynote-prune-rate-limits',
  '*/15 * * * *', -- every 15 minutes
  $$select public.tidynote_prune_rate_limits()$$
);
