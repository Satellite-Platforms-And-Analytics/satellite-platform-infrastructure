-- 002_public_read_grants.sql
--
-- Grants the anon role SELECT on the tables 001_core_schema.sql declares
-- publicly readable.
--
-- WHY THIS IS NEEDED
-- ==================
-- 001_core_schema.sql enables row-level security and creates six "Public
-- read" policies. That is only half of what public read access requires,
-- and the half that is easy to mistake for all of it.
--
--   GRANT  decides whether a role may touch the table at all.
--   POLICY decides which rows it sees once it may.
--
-- Without the grant, Postgres refuses before any policy is consulted. The
-- two failures look nothing alike, which is the useful part:
--
--   missing GRANT   -> "permission denied for table satellites" (error)
--   missing POLICY  -> zero rows, no error
--
-- Discovered 2026-09-01 when the frontend's /api/tles returned exactly
-- that error against a schema whose policies were all correct.
--
-- SCOPE
-- =====
-- Only the six tables with a "Public read" policy in 001_core_schema.sql.
-- Deliberately NOT granted:
--
--   tle_history    -- 346k rows of raw element sets; the frontend reads
--                     current TLEs from `satellites` instead
--   ingestion_log  -- operational telemetry, no public interest
--
-- Both have RLS enabled and no public policy, so they were never intended
-- to be readable. Leaving them ungranted means the grant list and the
-- policy list say the same thing.
--
-- SELECT only. anon never writes; ingestion authenticates as postgres
-- through DATABASE_URL.

GRANT USAGE ON SCHEMA public TO anon;

GRANT SELECT ON TABLE countries          TO anon;
GRANT SELECT ON TABLE satellites         TO anon;
GRANT SELECT ON TABLE orbital_positions  TO anon;
GRANT SELECT ON TABLE visibility_windows TO anon;
GRANT SELECT ON TABLE sensors            TO anon;
GRANT SELECT ON TABLE imagery_scenes     TO anon;

-- Verify: this should list exactly the six tables above.
--
--   SELECT table_name, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE grantee = 'anon' AND table_schema = 'public'
--    ORDER BY table_name;
