-- =============================================================================
-- Supabase keep-alive bootstrap
-- =============================================================================
-- Run this ONCE, by hand, in the Supabase SQL Editor as a superuser
-- (project tyqnggsgcbcxbkdpubkw, database `postgres`).
--
-- Why this exists
-- ---------------
-- Supabase pauses free-tier projects after 7 days without "user database
-- activity". A running Redash does NOT produce that activity when nobody opens
-- the UI:
--   * redash-web only answers the k8s probes on GET /ping, which logs
--     query_count=0 and never opens a transaction against Postgres.
--   * redash-worker and redash-scheduler poll Redis, not Postgres.
-- An idle-but-open pooler connection does not count either (the pods had been
-- up for 75 days when the project got paused).
--
-- So something outside Redash has to write to the database on a schedule.
-- That is the CronJob in 60-keepalive.yaml (layer 1) and the GitHub Actions
-- workflow in .github/workflows/keepalive.yml (layer 2). Both write to the
-- single row created below.
--
-- Design notes
-- ------------
-- * Dedicated schema `keepalive`, NOT `public`: `public` holds Redash's Alembic
--   migrations and must stay untouched by anything but Redash.
-- * A real INSERT/UPDATE/SELECT, not `SELECT 1`: Supabase does not document the
--   exact threshold for "sufficient user database activity", so the heartbeat
--   performs an actual write.
-- * A dedicated least-privilege role: the credential also lives in GitHub
--   Actions secrets. Reusing the `postgres` superuser there would make a leaked
--   secret catastrophic; `keepalive_bot` can only touch one table.
-- =============================================================================

create schema if not exists keepalive;

create table if not exists keepalive.heartbeat (
  id         smallint primary key default 1 check (id = 1),
  last_ping  timestamptz not null default now(),
  ping_count bigint      not null default 0
);

insert into keepalive.heartbeat (id) values (1) on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Least-privilege role used by both keep-alive layers.
-- Generate a strong password first and keep it somewhere safe, e.g.:
--     openssl rand -base64 32 | tr -d '/+=' | head -c 40
-- -----------------------------------------------------------------------------
create role keepalive_bot with login password 'REEMPLAZAR_CON_PASSWORD_GENERADA';
grant usage on schema keepalive to keepalive_bot;
grant select, insert, update on keepalive.heartbeat to keepalive_bot;

-- =============================================================================
-- Connection string to build from the password above
-- =============================================================================
-- The Supabase session pooler (Supavisor) requires the role name to carry the
-- project-ref suffix, otherwise it cannot resolve the tenant:
--
--   postgresql://keepalive_bot.tyqnggsgcbcxbkdpubkw:<PASSWORD>@aws-1-us-east-1.pooler.supabase.com:5432/postgres
--
-- Do NOT fall back to the direct endpoint db.<ref>.supabase.co: on the free tier
-- it is IPv6-only and GitHub-hosted runners cannot reach it.
--
-- Verify the role actually authenticates through the pooler before wiring the
-- secrets (any machine with psql):
--
--   psql "postgresql://keepalive_bot.tyqnggsgcbcxbkdpubkw:<PASSWORD>@aws-1-us-east-1.pooler.supabase.com:5432/postgres" \
--     -v ON_ERROR_STOP=1 -Atc "select last_ping, ping_count from keepalive.heartbeat"
--
-- Then store that URL in:
--   * `KEEPALIVE_DATABASE_URL` in .env            (local ./deploy.sh)
--   * repo secret `KEEPALIVE_DATABASE_URL`        (both GitHub workflows)
-- =============================================================================

-- Health check, any time:
--   select last_ping, ping_count from keepalive.heartbeat;
