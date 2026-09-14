-- 010_revoke_authenticated_and_seal_views.sql
--
-- Finishes the job 003 started, and closes a hole in the schema that no
-- audit had ever looked at.
--
-- HOW THIS WAS FOUND
-- ==================
-- `tests/test_db_privileges.py`, written 2026-09-13 under the standing
-- security requirement, failed on its first run against the live
-- database: `authenticated` holds TRUNCATE, TRIGGER and REFERENCES on
-- eleven relations.
--
-- The cause is exact. 003_revoke_anon_write_grants.sql removed those
-- three privileges **from anon only**. Every table created afterwards -
-- 006, 007, 009 - names `authenticated` explicitly, so the habit formed
-- immediately after 003; the ten relations that predated it were never
-- back-filled.
--
-- That is the week's recurring lesson in schema form: **a fix applied
-- only where the bug was found is half a fix.** The same shape produced
-- the `.env~` gap that survived four days in the sibling repository after
-- being closed in the first one.
--
-- WHY TRUNCATE IS STILL THE ONE THAT MATTERS
-- ==========================================
-- Row-level security does not apply to TRUNCATE. Every "Public read"
-- policy on this schema can be perfectly correct and `satellites`,
-- `tle_history` and `visibility_windows` can still be emptied outright by
-- a role that holds it. 003 says this at length about anon; it is exactly
-- as true of authenticated.
--
-- HOW EXPOSED, HONESTLY
-- =====================
-- Not live today, for the same reason 003 gave: PostgREST exposes
-- SELECT/INSERT/UPDATE/DELETE and RPC, and there is no route from the
-- public API to a TRUNCATE statement. This project also has no
-- authentication, so nothing currently assumes the `authenticated` role
-- at all.
--
-- It becomes live the moment either changes - and adding sign-in is a
-- normal product step, not an exotic one. The privilege has no
-- legitimate use here either way.
--
-- THE VIEWS, WHICH NO AUDIT HAD SEEN
-- ==================================
-- 001 creates three views: active_satellites, satellites_by_country and
-- ingestion_status. Every privilege audit this project has run scanned
-- CREATE TABLE, so all three were invisible - and the RLS test filters to
-- relkind='r', so it passed over them too.
--
-- They deserve the attention. A PostgreSQL view runs with its **owner's**
-- privileges unless declared `security_invoker = true`, and all three are
-- owned by `postgres` at the default. An owner-rights view returns rows
-- that row-level security would refuse the caller directly.
--
-- `ingestion_status` selects pipeline, status, **message**, records and
-- duration from `ingestion_log` - a table with RLS enabled and
-- deliberately no policy, which is deny-all. `message` carries exception
-- text (`log_step(..., message=str(exc)[:500])`): a connection error
-- contains the database host, a SQLAlchemy error can contain the failing
-- statement.
--
-- **Measured before assuming.** `check_grants.py` shows neither anon nor
-- authenticated holds SELECT on any of the three views, so there is no
-- live disclosure. The danger is structural rather than current: a single
-- future `GRANT SELECT` on `ingestion_status` - the obvious thing to do
-- when someone wants a status page - would silently publish log messages
-- past RLS, and nothing would report it.
--
-- `security_invoker = true` makes that impossible to do by accident: the
-- view then reads with the caller's own rights, so RLS and the grants on
-- `ingestion_log` apply as written.
--
-- WHAT THIS CHANGES IN PRACTICE TODAY
-- ===================================
-- Nothing observable. No role holds SELECT on the views, the ingestion
-- pipeline connects as a role that is unaffected, and the frontend reads
-- `satellites` through anon exactly as before. This migration removes
-- privileges nobody exercises and closes a door nobody has walked
-- through. That is the cheapest kind of security work and the only kind
-- worth doing before it is needed.

-- ── Finish 003, for the other public role ────────────────────────────
--
-- ALL TABLES IN SCHEMA covers views as well as tables, which is the point
-- here: the three views carry the same three privileges.

REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public
    FROM authenticated;

-- Belt and braces. These are already absent for both roles - verified by
-- check_grants.py, which shows anon holding SELECT and nothing else, and
-- authenticated holding no SELECT at all - but stating it means a future
-- default-privilege change cannot reintroduce them quietly.
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
    FROM anon, authenticated;

-- Supabase's default privileges are what granted these in the first
-- place. Without this, the next CREATE TABLE starts the cycle again -
-- which is exactly how 006, 007 and 009 each had to carry their own
-- REVOKE block.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

-- ── Views read with the caller's rights, not the owner's ─────────────
--
-- PostgreSQL 15+. Supabase is well past that.

ALTER VIEW active_satellites     SET (security_invoker = true);
ALTER VIEW satellites_by_country SET (security_invoker = true);
ALTER VIEW ingestion_status      SET (security_invoker = true);

COMMENT ON VIEW ingestion_status IS
    'Last 50 ingestion_log rows. security_invoker = true (010): this view '
    'reads with the caller''s privileges, so the deny-all RLS on '
    'ingestion_log applies. Without it an owner-rights view would publish '
    'exception messages - which can contain the database host or a failing '
    'statement - to anyone granted SELECT on the view.';

-- Verify:
--
--   -- expect zero rows
--   SELECT grantee, table_name, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE table_schema = 'public'
--      AND grantee IN ('anon','authenticated')
--      AND privilege_type <> 'SELECT';
--
--   -- expect security_invoker=true on all three
--   SELECT relname, reloptions FROM pg_class c
--     JOIN pg_namespace n ON n.oid = c.relnamespace
--    WHERE n.nspname='public' AND c.relkind='v';
--
--   -- or just:  python check_grants.py
--   --           pytest tests/test_db_privileges.py   (REQUIRE_DB=1)
