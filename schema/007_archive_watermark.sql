-- 007_archive_watermark.sql
--
-- How far the workstation has archived, so the cloud knows what it is
-- safe to delete.
--
-- WHY THIS EXISTS
-- ===============
-- As of 2026-09-10 this database is the serving layer and `D:` is the
-- warehouse. The frontend's one API route reads `satellites` and five
-- columns; nothing reads visibility_windows, orbital_positions or
-- tle_history but diagnostics and their own prunes. History is copied to
-- local Parquet by archive_to_local.py and then removed from here.
--
-- That creates a hazard the old design did not have. The prunes run in
-- GitHub Actions on a fixed clock -- orbital_positions at 48h,
-- visibility_windows at 3 days, tle_history at 14 -- and the archive runs
-- on a workstation that might be off. A fixed-clock prune plus an
-- intermittent archive loses data, silently, and `orbital_positions`
-- gives a two-day margin before it does.
--
-- So the prune stops being a function of the clock alone and becomes a
-- function of the clock AND what is provably on disk:
--
--     DELETE WHERE time_col < LEAST(now() - retention, archived_through)
--
-- Machine on: identical to today's behaviour.
-- Machine off: the cutoff stops advancing. The table GROWS rather than
--              losing rows. Nothing is lost.
-- Machine off a long time: the backstop fires (see below), because the
--              alternative is filling the tier and stopping ingestion for
--              everything.
--
-- WHAT archived_through MEANS
-- ===========================
-- Every row whose time column is <= this value is on disk at the host
-- named in archive_host. It is advanced ONLY after a partition has been
-- written and its row count verified against the database. It must never
-- be set optimistically, by hand, or in advance -- the entire safety
-- property of the prune rests on this column being conservative.
--
-- The time column differs per table, which is a real wrinkle rather than
-- a detail:
--
--     tle_history         epoch          timestamptz
--     orbital_positions   timestamp      timestamptz
--     visibility_windows  analysis_date  date  -> stored here as that
--                                                date at 00:00 UTC
--
-- THE BACKSTOP
-- ============
-- max_retention_days is the point past which the prune deletes regardless
-- of the watermark. It exists because an unbounded table is not a safe
-- failure mode on a 500 MB tier: ~93 MB/day flows through these three
-- tables, so a stalled archive would exhaust the tier in days and stop
-- TLE ingestion, propagation and visibility all at once.
--
-- It is the one path that destroys unarchived data, so it must never be
-- quiet. The writer logs at ERROR and records a `catalog_events` row of
-- type 'archive_backstop', which puts it in the next monitor digest.
--
-- NULL max_retention_days means no backstop: grow without bound rather
-- than ever delete unarchived rows. That is correct for tle_history,
-- whose element sets cannot be re-fetched -- CelesTrak serves current
-- elements only and Space-Track's GP_History is one request per lifetime.
-- Better a full tier that can be fixed by hand than a permanent hole.

CREATE TABLE IF NOT EXISTS archive_watermark (
    table_name         TEXT PRIMARY KEY,
    archived_through   TIMESTAMPTZ,     -- NULL = nothing archived yet
    row_count          BIGINT,          -- rows on disk at that point
    max_retention_days INTEGER,         -- backstop; NULL = never delete
                                        -- unarchived rows
    archive_host       TEXT,
    archive_path       TEXT,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE archive_watermark IS
    'How far archive_to_local.py has copied each history table to local '
    'disk. The prunes will not delete past archived_through except via '
    'max_retention_days, which is logged loudly.';

COMMENT ON COLUMN archive_watermark.archived_through IS
    'Every row whose time column is <= this is on disk at archive_host. '
    'Advanced only after a written partition is verified by row count. '
    'Never set this by hand or in advance - the prune trusts it.';

COMMENT ON COLUMN archive_watermark.max_retention_days IS
    'Delete beyond this age even if unarchived, because an unbounded '
    'table stops all ingestion on a 500 MB tier. NULL disables the '
    'backstop: correct for tle_history, whose rows cannot be re-fetched.';

-- Seed the three tables with their current retention as the backstop
-- multiplied out, and no watermark. Until archive_to_local.py writes a
-- watermark, `LEAST(clock, NULL)` is NULL and a watermark-aware prune
-- deletes nothing -- which is the safe direction to fail while the new
-- prune is being rolled out.
--
-- The backstops are deliberately generous: they are a last resort, not a
-- retention policy. At ~93 MB/day across all three, 274 MB of current
-- headroom is roughly three days of total stall, so these values are
-- about the outer edge of what the tier can absorb.
INSERT INTO archive_watermark
    (table_name, archived_through, max_retention_days)
VALUES
    ('visibility_windows', NULL, 7),
    ('orbital_positions',  NULL, 7),
    ('tle_history',        NULL, NULL)
ON CONFLICT (table_name) DO NOTHING;

-- updated_at is maintained by the writer, not by a trigger.
--
-- A touch trigger exists to defend against writers that forget. This
-- table has exactly one writer -- archive_to_local.py's update_watermark
-- -- and it sets the column explicitly. A trigger here would add a
-- function and a CREATE TRIGGER to a migration that is otherwise
-- trivially re-runnable, to guard against a caller that does not exist.
--
-- (CREATE TRIGGER has no IF NOT EXISTS, so it needs the same
-- drop-then-create dance as CREATE POLICY. Worth it for a policy, which
-- is a security control; not worth it for a timestamp.)

-- ── Access ───────────────────────────────────────────────────────────
--
-- Both halves, for the reason 002_public_read_grants.sql exists: GRANT
-- decides whether a role may touch the table, POLICY decides which rows
-- it sees. Missing grant is an error; missing policy is silently zero
-- rows.
--
-- anon gets SELECT so a future dashboard can show "history archived
-- through ...". It must never write here: a forged watermark is a
-- licence to delete unarchived data, which makes this the
-- highest-consequence table in the schema despite holding three rows.

ALTER TABLE archive_watermark ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read archive_watermark" ON archive_watermark;
CREATE POLICY "Public read archive_watermark"
    ON archive_watermark FOR SELECT USING (true);

GRANT SELECT ON archive_watermark TO anon;

-- Supabase's default privileges grant ALL on new tables in public to
-- anon and authenticated, so this table was born with the grants 003
-- spent a migration removing. RLS does not apply to TRUNCATE.
REVOKE TRUNCATE, TRIGGER, REFERENCES ON archive_watermark FROM anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON archive_watermark FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON archive_watermark FROM anon;
REVOKE INSERT, UPDATE, DELETE ON archive_watermark FROM authenticated;

-- Verify:
--
--   SELECT grantee, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE table_name = 'archive_watermark'
--    ORDER BY grantee, privilege_type;
--
-- anon should hold SELECT and nothing else.
--
--   SELECT table_name, archived_through, row_count, max_retention_days
--     FROM archive_watermark ORDER BY table_name;
--
-- Three rows, archived_through NULL until the first archive run.
