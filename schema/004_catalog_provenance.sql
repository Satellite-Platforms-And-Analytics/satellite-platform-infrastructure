-- 004_catalog_provenance.sql
--
-- Phase 2 groundwork: record WHERE catalogue attribution came from, and add
-- the one descriptive field the existing schema lacks.
--
-- WHY THIS MIGRATION IS SMALLER THAN PLANNED
-- ==========================================
-- The Phase 2 sprint plan called for adding operator, country, purpose,
-- launch date, mass and so on. They already exist. 001_core_schema.sql
-- defined them on 2026-07-10, ahead of any data to put in them:
--
--   operator, manufacturer, purpose, country_code, orbit_type,
--   launch_date, launch_site, launch_vehicle, expected_lifetime_yr,
--   mass_kg, perigee_km, apogee_km, inclination_deg, period_min,
--   rcs_size, status, object_type
--
-- They are almost certainly all NULL: CelesTrak's OMM feed supplies name,
-- catalogue number, international designator and orbital elements, and
-- nothing about who owns the thing or what it is for. Phase 2 is about
-- filling columns that already exist, not creating them.
--
-- Better still, writer.py's upsert already reads
--
--     ON CONFLICT (norad_id) DO UPDATE SET
--         col = COALESCE(EXCLUDED.col, satellites.col)
--
-- so a slow enrichment pass and the 2-hourly TLE refresh can coexist: the
-- fetcher passes NULL for the attribution columns and COALESCE keeps
-- whatever enrichment wrote. Phase 2 does not need to change the writer's
-- conflict behaviour, only to use it.
--
-- WHAT IS ACTUALLY MISSING
-- ========================
-- 1. `users` - the UCS Satellite Database's own field, distinguishing
--    civil / commercial / government / military. Different from `purpose`
--    (what it does) and from `operator` (who runs it), and the field most
--    of the Phase 3 industry work will group by.
--
-- 2. Provenance. Once a value can come from CelesTrak, UCS, UNOOSA or a
--    name match, "operator = SpaceX" is not self-describing: it matters
--    whether that came from an exact NORAD join or a fuzzy name match.
--    Without this, a wrong attribution is indistinguishable from a right
--    one and cannot be re-examined later.
--
-- A NOTE ON THE PROVENANCE DESIGN
-- ===============================
-- These columns are ROW-level, not per-field: they describe how the
-- satellite was matched, not where each individual value came from. If
-- UCS supplies the operator and UNOOSA the launch site, this schema
-- records only the last match.
--
-- That is a deliberate first pass. Per-field provenance wants a separate
-- `satellite_attribution` table keyed (norad_id, field, source), which is
-- the right answer once sources actually conflict — and premature before
-- there is a second source to conflict with. Revisit when UNOOSA lands.

ALTER TABLE satellites
    ADD COLUMN IF NOT EXISTS users             TEXT,
    ADD COLUMN IF NOT EXISTS data_source       TEXT,
    ADD COLUMN IF NOT EXISTS match_method      TEXT,
    ADD COLUMN IF NOT EXISTS source_confidence REAL,
    ADD COLUMN IF NOT EXISTS matched_at        TIMESTAMPTZ;

COMMENT ON COLUMN satellites.users IS
    'UCS "Users" field: civil, commercial, government, military, or a '
    'slash-separated combination. Distinct from purpose (what it does) '
    'and operator (who runs it).';

COMMENT ON COLUMN satellites.data_source IS
    'Which dataset supplied the attribution: ucs, unoosa, celestrak, '
    'manual. NULL means never enriched.';

COMMENT ON COLUMN satellites.match_method IS
    'How the row was joined to its source: norad_id, intl_designator, '
    'name_exact, name_fuzzy. Recorded because the failure modes differ - '
    'a norad_id join is either right or absent, a name match can be '
    'confidently wrong.';

COMMENT ON COLUMN satellites.source_confidence IS
    '0.0-1.0. Convention: 1.0 norad_id, 0.9 intl_designator, 0.7 exact '
    'name, below 0.7 fuzzy. Prefer leaving a satellite unattributed to '
    'attributing it wrongly - see the attribution false-positive risk in '
    'the master roadmap.';

COMMENT ON COLUMN satellites.matched_at IS
    'When enrichment last ran for this row. Lets a re-run target only '
    'rows never matched, or matched before a source was updated.';

-- Find unenriched rows quickly; this is the working set for every
-- enrichment pass. Partial, because the whole point is the NULL side.
CREATE INDEX IF NOT EXISTS idx_satellites_unenriched
    ON satellites (norad_id) WHERE data_source IS NULL;

-- Phase 3 groups by these constantly.
CREATE INDEX IF NOT EXISTS idx_satellites_operator ON satellites (operator);
CREATE INDEX IF NOT EXISTS idx_satellites_users    ON satellites (users);

-- Verify:
--
--   SELECT count(*) AS total,
--          count(operator)    AS have_operator,
--          count(purpose)     AS have_purpose,
--          count(mass_kg)     AS have_mass,
--          count(data_source) AS enriched
--     FROM satellites;
--
-- Expect total ~18,000 and every other column 0 before the first
-- enrichment run. If have_operator is non-zero, something already wrote
-- attribution and this migration's assumptions need re-checking.
