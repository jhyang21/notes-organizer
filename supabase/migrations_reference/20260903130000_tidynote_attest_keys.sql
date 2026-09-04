-- TidyNote App Attest keys. See 20260807120000_tidynote_quota_and_rate_limits.sql
-- for why TidyNote objects live in this project under a `tidynote_` prefix.
-- Nothing here reads, writes, or references any Relora object.
--
-- The tidynote_organize edge function identifies an install by a client-chosen
-- `tidy:<UUID>`. On its own that string proves nothing: anyone with the
-- publishable key can mint IDs for free tidies or borrow a subscriber's ID.
-- App Attest fixes that. Each install generates a hardware-backed key, Apple
-- signs a statement that the key belongs to a genuine copy of the app, and the
-- edge function stores the key's public half here, bound to the app user ID.
-- Every later request carries an assertion signed by that key, and the
-- function checks the signature and the monotonic counter against this row.
--
-- Service-role only, same as the other tidynote_ tables: RLS on with no
-- policies, and all privileges revoked from anon and authenticated.

create table if not exists public.tidynote_attest_keys (
  key_id text primary key,
  app_user_id text not null,
  rp_id text not null,
  public_key text not null,
  counter bigint not null default 0,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

alter table public.tidynote_attest_keys enable row level security;

create index if not exists tidynote_attest_keys_app_user_id_idx
  on public.tidynote_attest_keys (app_user_id);

comment on table public.tidynote_attest_keys is
  'TidyNote App Attest keys, one row per attested device key. key_id is the base64url SHA-256 of the public key as Apple defines it, public_key is the leaf key as a JWK, rp_id is the App ID the key was attested for, counter is the last assertion counter seen. Service-role only; written exclusively by the tidynote_organize edge function.';

revoke all on table public.tidynote_attest_keys from anon, authenticated;
