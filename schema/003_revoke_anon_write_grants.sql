-- 003_revoke_anon_write_grants.sql
--
-- Removes TRUNCATE, TRIGGER and REFERENCES from the anon role.
--
-- WHAT WAS FOUND
-- ==============
-- Applying 002 printed every grant anon holds, and the list was longer
-- than the six SELECTs just added: anon already held TRUNCATE, TRIGGER
-- and REFERENCES on all ten relations in `public` - including
-- tle_history and ingestion_log, which have RLS enabled and deliberately
-- no public policy.
--
-- These come from Supabase's default privileges, which grant ALL on new
-- tables in `public` to anon and authenticated. SELECT and the DML
-- privileges were evidently revoked at some point; the remainder was not.
--
-- WHY TRUNCATE IS THE ONE THAT MATTERS
-- ====================================
-- Row-level security does not apply to TRUNCATE. A policy that restricts
-- which rows anon may read offers no protection at all against a role
-- that can empty the table outright - RLS filters rows, TRUNCATE removes
-- the table's contents without consulting them.
--
-- Concretely: anon could empty satellites, tle_history and
-- visibility_windows despite every "Public read" policy being correct.
--
-- HOW EXPOSED IS IT, HONESTLY
-- ===========================
-- Not very, today. anon is not a login role - it is assumed by PostgREST
-- via SET ROLE after validating the JWT - and PostgREST exposes only
-- SELECT/INSERT/UPDATE/DELETE on tables plus RPC on functions. There is
-- no route from the public API to a TRUNCATE statement, so this is not a
-- live vulnerability.
--
-- It becomes one the moment anything executes SQL as anon: a
-- SECURITY INVOKER function doing dynamic SQL, a future direct-connection
-- feature, a misconfigured pooler. The privilege has no legitimate use
-- here either way. Remove it while it costs nothing.
--
-- TRIGGER and REFERENCES go with it: anon has no reason to attach a
-- trigger to a table or create a foreign key against one.
--
-- SELECT is left exactly as 002 set it.

REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public FROM anon;

-- Stop the same privileges being handed to anon on tables created later.
-- Without this, migration 004 reintroduces the problem silently.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLES FROM anon;

-- Verify: anon should hold SELECT and nothing else, on the six tables
-- 002 granted.
--
--   SELECT table_name, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE grantee = 'anon' AND table_schema = 'public'
--    ORDER BY table_name, privilege_type;
