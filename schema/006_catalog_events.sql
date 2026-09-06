-- 006_catalog_events.sql
--
-- A durable record of what the catalogue noticed, and when.
--
-- WHY A TABLE AND NOT JUST AN ALERT
-- =================================
-- `check_new_objects.py` classifies arrivals into new launches,
-- fragmentation, ingestion changes and newly-visible objects. Until now
-- that analysis existed only in the terminal of whoever ran it.
--
-- Two things need it to persist. A daily monitor has to know what it
-- already reported, or it opens the same issue every morning. And the
-- satellite dashboard will want to show what happened recently, link an
-- event to the objects involved, and plot launch cadence over time --
-- none of which can be served from text in a GitHub issue.
--
-- So the detection writes rows, and the alert is a consumer of those
-- rows rather than the only place they live.
--
-- IDEMPOTENCY IS THE WHOLE DESIGN
-- ===============================
-- The monitor runs daily over a rolling 30-day window, so it re-detects
-- the same launches every day for a month. Without a natural key the
-- table fills with duplicates and every dashboard count is wrong.
--
-- `event_key` is that natural key:
--
--   launch-scoped events   '<launch_key>:<first_seen>'  e.g. '2026-196:2026-09-01'
--   whole-catalogue events '<metric>:<date>'            e.g. 'latency:2026-09-05'
--
-- UNIQUE (event_type, event_key) then makes a re-run an update rather
-- than an insert, and the counts stay honest across as many runs as you
-- like.
--
-- A NOTE ON norad_ids
-- ===================
-- Stored so the dashboard can link an event to the objects it concerns
-- without re-deriving the classification -- and AD-034 (clicking a
-- satellite should reach the analysis domain) needs exactly that join.
-- Capped in the writer: object_count is always the true total, the array
-- is a sample when an event covers hundreds of fragments.

CREATE TABLE IF NOT EXISTS catalog_events (
    id            BIGSERIAL PRIMARY KEY,
    event_type    TEXT NOT NULL,      -- new_launch, fragmentation,
                                      -- ingestion_change, newly_visible,
                                      -- latency_regression,
                                      -- uncatalogued_growth
    event_key     TEXT NOT NULL,      -- natural key, see above
    launch_key    TEXT,               -- 'YYYY-NNN', null for metrics
    launch_date   DATE,
    object_count  INTEGER NOT NULL DEFAULT 0,
    object_types  TEXT,               -- '586 DEBRIS, 1 PAYLOAD'
    norad_ids     INTEGER[],          -- sample; see the note above
    first_seen    DATE,               -- when the objects reached us
    notable       BOOLEAN NOT NULL DEFAULT false,
    details       JSONB,              -- thresholds, means, free-form
    detected_at   TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (event_type, event_key)
);

COMMENT ON TABLE catalog_events IS
    'What the catalogue noticed: launches, fragmentations, ingestion '
    'changes and health metrics. Written by check_new_objects.py '
    '--record, read by the daily monitor and the dashboard.';

COMMENT ON COLUMN catalog_events.event_key IS
    'Natural key making a re-run an update rather than a duplicate. '
    'The monitor sweeps a rolling window daily and re-detects the same '
    'launches for weeks; without this every count would inflate.';

COMMENT ON COLUMN catalog_events.notable IS
    'Whether this should interrupt someone. Fragmentation and latency '
    'regressions are notable; routine deployment is not.';

COMMENT ON COLUMN catalog_events.norad_ids IS
    'Sample of the objects involved, for linking to satellites. '
    'object_count is the true total - do not use array_length for counts.';

-- The dashboard reads "what happened recently" constantly.
CREATE INDEX IF NOT EXISTS idx_catalog_events_detected
    ON catalog_events (detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_catalog_events_type
    ON catalog_events (event_type, detected_at DESC);

-- The monitor reads only this slice.
CREATE INDEX IF NOT EXISTS idx_catalog_events_notable
    ON catalog_events (detected_at DESC) WHERE notable;

-- Launch cadence over time.
CREATE INDEX IF NOT EXISTS idx_catalog_events_launch_date
    ON catalog_events (launch_date) WHERE launch_date IS NOT NULL;

-- ── Access ───────────────────────────────────────────────────────────
--
-- Both halves, for the reason 002_public_read_grants.sql exists: GRANT
-- decides whether a role may touch the table, POLICY decides which rows
-- it sees. Missing grant is an error; missing policy is silently zero
-- rows.

ALTER TABLE catalog_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read catalog_events" ON catalog_events;
CREATE POLICY "Public read catalog_events"
    ON catalog_events FOR SELECT USING (true);

GRANT SELECT ON catalog_events TO anon;

-- And the half a new table quietly reintroduces.
--
-- 003_revoke_anon_write_grants.sql found anon holding TRUNCATE, TRIGGER
-- and REFERENCES on all ten relations in `public`, from Supabase's
-- default privileges granting ALL on new tables to anon and
-- authenticated. Those defaults are still in force, so this table was
-- born with the same grants 003 spent a migration removing.
--
-- RLS does not apply to TRUNCATE. Revoking here rather than in a later
-- clean-up keeps the grant list and the policy list saying the same
-- thing from the table's first day.
REVOKE TRUNCATE, TRIGGER, REFERENCES ON catalog_events FROM anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON catalog_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON catalog_events FROM anon;

-- Verify:
--
--   SELECT grantee, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE table_name = 'catalog_events'
--    ORDER BY grantee, privilege_type;
--
-- anon should hold SELECT and nothing else.
