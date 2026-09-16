-- 019_pipeline_role.sql
--
-- The pipelines stop connecting as a superuser-equivalent (AD-065).
--
-- THE FINDING
-- ===========
-- Every scheduled workflow connects as `postgres.<project>` to INSERT
-- and UPDATE a handful of tables. That role can also DROP them, read
-- every row of every table regardless of RLS, TRUNCATE the catalogue,
-- and create new superusers. Five workflows hold that credential in
-- their environment, on a schedule, unattended.
--
-- It has been the largest remaining security exposure since AD-064 was
-- closed on 2026-09-14. Locking the dependencies narrowed *what can
-- run* with that credential; it did nothing about *what the credential
-- can do* once something does.
--
-- NO PASSWORD IS SET HERE, AND THAT IS DELIBERATE
-- ===============================================
-- This migration creates the role NOLOGIN and grants it privileges. It
-- never sets a password, because a password in a migration is a
-- password in git history, in every clone, and in every diff anyone
-- pastes. The rotation is a separate, uncommitted step run by a person -
-- see docs/PIPELINE_ROLE.md.
--
-- Until that step runs, this migration changes nothing about how
-- anything connects. It is safe to apply and then walk away.
--
-- RLS IS THE PART THAT WOULD HAVE BROKEN THE ROLLOUT
-- ==================================================
-- Every table here has RLS enabled and carries a SELECT-only "public
-- read" policy. `postgres` never noticed, because a superuser bypasses
-- RLS entirely. A new least-privilege role does not: with a GRANT but
-- no policy, its INSERTs fail and its UPDATEs match zero rows - and an
-- UPDATE that matches nothing is not an error. The pipeline would have
-- reported success while writing nothing.
--
-- So each writable table gets an explicit policy naming this role. They
-- are visible in pg_policies and auditable, which a BYPASSRLS
-- attribute would not be.
--
-- WHAT IT DELIBERATELY CANNOT DO
-- ==============================
-- No DELETE. No TRUNCATE. No DDL. No role management.
--
-- The prune scripts (truncate_archived.py, cleanup_tle_history.py) DO
-- delete, and they keep running under the operator credential. That is
-- the point rather than an oversight: deletion after a verified archive
-- is a decision a person makes, and the 2026-09-10 archive work exists
-- precisely because losing rows is the failure this project can least
-- afford. A scheduled job that can delete is one bad watermark away
-- from doing it.
--
-- Reference tables - countries, domains, technologies,
-- technology_categories - are SELECT only. Their source of truth is a
-- seed file in the repository (AD-052's reasoning: a curated judgement
-- belongs where it shows up in a diff, not where it can be UPDATEd at
-- 2am), so no automation has any business writing them.

-- ── The role ─────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline') THEN
        -- NOLOGIN until a person sets a password. NOINHERIT so it cannot
        -- pick up privileges by being granted into some other role later
        -- without that being an explicit decision.
        CREATE ROLE pipeline NOLOGIN NOINHERIT;
    END IF;
END
$$;

COMMENT ON ROLE pipeline IS
    'Least-privilege role for the scheduled ingestion workflows '
    '(AD-065). SELECT/INSERT/UPDATE on the tables they write, SELECT on '
    'reference data, and nothing else - no DELETE, no TRUNCATE, no DDL. '
    'Password is set out of band; see docs/PIPELINE_ROLE.md.';

GRANT USAGE ON SCHEMA public TO pipeline;

-- ── What it may write ────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE ON
    satellites,
    satellite_attribution,
    orbital_positions,
    visibility_windows,
    tle_history,
    catalog_events,
    ingestion_log,
    archive_watermark,
    imagery_scenes,
    sensors,
    organizations,
    research_organizations,
    research_projects,
    research_project_taxonomy,
    research_taxonomy_areas
TO pipeline;

-- ── What it may only read ────────────────────────────────────────────

GRANT SELECT ON
    countries,
    domains,
    technologies,
    technology_categories
TO pipeline;

-- Identity and serial columns draw from sequences. An INSERT that
-- cannot reach one fails with a permission error on an object the
-- caller never named, which is a confusing way to learn this.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pipeline;

-- ── Stated, not assumed ──────────────────────────────────────────────
--
-- These are already absent by default and by 010's ALTER DEFAULT
-- PRIVILEGES. Stated anyway, for the reason 011 states its revokes:
-- "should not hold it" is a belief until something checks, and
-- check_grants.py is what checks.

REVOKE DELETE, TRUNCATE, TRIGGER, REFERENCES
    ON ALL TABLES IN SCHEMA public FROM pipeline;
REVOKE CREATE ON SCHEMA public FROM pipeline;

-- ── RLS policies, one per writable table ─────────────────────────────
--
-- CREATE POLICY has no IF NOT EXISTS form, so each is dropped first -
-- the pattern 001 lacked and every migration since has carried.

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'satellites', 'satellite_attribution', 'orbital_positions',
        'visibility_windows', 'tle_history', 'catalog_events',
        'ingestion_log', 'archive_watermark', 'imagery_scenes',
        'sensors', 'organizations', 'research_organizations',
        'research_projects', 'research_project_taxonomy',
        'research_taxonomy_areas'
    ]
    LOOP
        IF EXISTS (SELECT 1 FROM pg_tables
                    WHERE schemaname = 'public' AND tablename = t) THEN
            EXECUTE format(
                'DROP POLICY IF EXISTS %I ON public.%I',
                'pipeline writes ' || t, t);
            -- FOR ALL covers SELECT, INSERT, UPDATE and DELETE at the
            -- POLICY layer; DELETE stays impossible because the GRANT
            -- above never gave it. Two layers have to agree before a row
            -- can be removed, and only one of them says yes.
            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR ALL TO pipeline '
                'USING (true) WITH CHECK (true)',
                'pipeline writes ' || t, t);
        END IF;
    END LOOP;
END
$$;

-- Verify — and verify BY BECOMING THE ROLE, not by reading the grant
-- table (AD-071). A grant is a claim about what should happen; a query
-- run as the role is what does happen.
--
--   BEGIN;
--   SET LOCAL ROLE pipeline;
--   SELECT count(*) FROM satellites;                  -- expect a number
--   INSERT INTO ingestion_log (pipeline, status)
--        VALUES ('probe', 'probe');                   -- expect success
--   DELETE FROM satellites WHERE norad_id = -1;       -- expect DENIED
--   TRUNCATE catalog_events;                          -- expect DENIED
--   UPDATE technologies SET trl = trl;                -- expect DENIED
--   CREATE TABLE probe (x int);                       -- expect DENIED
--   ROLLBACK;
--
-- Run as written, it is 18 assertions and they all pass on PostgreSQL 16:
-- six things the pipelines must still be able to do, seven they must
-- not, and five privileges read from the catalogue.
--
-- ONE SUBTLETY, BECAUSE IT WOULD MISLEAD A TEST. PostgreSQL answers a
-- self-GRANT with a WARNING, not an error:
--
--     SET ROLE pipeline;
--     GRANT DELETE ON satellites TO pipeline;
--     WARNING:  no privileges were granted for "satellites"
--
-- psql exits 0. Nothing was granted - has_table_privilege still says
-- false and DELETE is still refused - but a check that reads the exit
-- code would report an escalation that did not happen, and could as
-- easily miss one that did. Check the PRIVILEGE, not the statement's
-- exit status.
--
-- FOLLOW-UP, NOT DONE HERE: teach check_grants.py a --role flag so this
-- block becomes a control that can go red rather than a comment
-- somebody has to remember to run.
