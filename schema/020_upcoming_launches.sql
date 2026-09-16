-- 020_upcoming_launches.sql
--
-- MVP piece 2: objects upcoming. And the honest version of it.
--
-- WHAT THE SURVEY FOUND, AND WHY IT CHANGES THE TABLE
-- ===================================================
-- Launch Library 2 lists 363 upcoming launches. It would be easy to
-- render those as a schedule. They are not one:
--
--     net_precision      Year        181   50%
--                        Month        50   14%
--                        Decade       35   10%
--                        Quarter/Half 62   17%
--                        Day or finer 20    5%
--     status             To Be Determined 348 of 363
--                        Go for Launch     10
--
-- Half the manifest is known only to the YEAR. A tenth is known only to
-- the DECADE. Twenty launches out of 363 have a date anyone could plan
-- around.
--
-- `net` is "no earlier than", and it arrives with `net_precision`. A
-- launch known to the second and one known to the decade are both ISO
-- timestamps, and storing them the same way presents a guess as a fact.
-- That is the error AD-061 caught when TechPort's per-project TRL was
-- about to become a technology's TRL, and the one AD-082 caught when a
-- sparkline's axis changed per row: a number that LOOKS precise is read
-- as precise.
--
-- So `net_precision` is not a nice-to-have column. It is the field that
-- decides whether a row may be shown as a date at all.
--
-- THE TIER IS DERIVED, NOT ASSERTED
-- =================================
-- `net_confidence` is GENERATED. The frontend must not be the place
-- that decides what counts as scheduled, because then two surfaces can
-- disagree and neither is wrong. Same reasoning as
-- technologies.readiness_gap, organizations.display_name and
-- research_project_taxonomy.tx_top: a derived value is computed where it
-- cannot drift from its input.
--
-- An UNRECOGNISED precision falls to 'approximate', never to 'dated'.
-- theSpaceDevs can add a precision name tomorrow, and the failure mode
-- of guessing wrong must be "shown as vaguer than it is", not "shown as
-- a schedule when it is not".
--
-- NOTHING IS EVER DELETED
-- =======================
-- A launch leaves the upcoming manifest by happening. The obvious
-- implementation is to delete the rows that are gone, and it is wrong
-- twice: it destroys the record of what was expected and when, which is
-- the only way to ever ask whether a provider's dates slip; and 019 has
-- just taken DELETE away from the pipeline role on purpose.
--
-- `last_seen_at` is stamped on every import instead. A row missing from
-- the latest run keeps its history and simply stops being current.

-- ── 019 FIRST. FAIL NOW, NOT HALFWAY ─────────────────────────────────
--
-- This migration grants to, and writes a policy for, the `pipeline`
-- role that 019 creates. Applied without it, the first sixteen
-- statements succeed and the seventeenth fails with
--
--     UndefinedObject: role "pipeline" does not exist
--
-- leaving the table, its indexes, its view and its public policy in
-- place and its pipeline access missing. That happened on 2026-09-15.
-- Everything here is IF NOT EXISTS or DROP-then-CREATE so a re-run
-- completes it cleanly - which is the only reason it was a nuisance
-- rather than a mess.
--
-- A dependency that announces itself only after partially applying is
-- the same shape of defect as an UPDATE that matches zero rows: the
-- thing that went wrong is not the thing that gets reported. So it
-- refuses up front, and names the fix.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline') THEN
        RAISE EXCEPTION
            'role "pipeline" does not exist: apply '
            '019_pipeline_role.sql before this migration. Nothing in '
            '020 has been applied.';
    END IF;
END
$$;


CREATE TABLE IF NOT EXISTS upcoming_launches (
    -- theSpaceDevs' own id, a UUID string. Their key, not a surrogate:
    -- the same choice 011 made with GCAT's org code and 015 with
    -- TechPort's projectId, so a re-import is an upsert rather than a
    -- diff.
    id              TEXT PRIMARY KEY,
    slug            TEXT,
    name            TEXT NOT NULL,

    status_id       INTEGER,
    status_name     TEXT,

    -- "No earlier than". NOT a launch date - see above.
    net             TIMESTAMPTZ,
    net_precision   TEXT,
    window_start    TIMESTAMPTZ,
    window_end      TIMESTAMPTZ,

    provider_name   TEXT,
    -- AN ATTRIBUTE, NEVER A REQUIREMENT (AD-085). 55% of providers match
    -- GCAT strictly - far better than TechPort's 3%, because launch
    -- providers are the population an operator catalogue exists to name.
    -- The rest stay NULL on purpose: ULA has no single GCAT row, and
    -- CASC's nearest neighbour is a different company.
    provider_code   TEXT REFERENCES organizations (code),
    -- 'strict' | 'alias' | 'agency_prefix_stripped'. Which rule matched
    -- is part of the claim: a curated alias and a normalisation hit are
    -- different kinds of evidence and must stay distinguishable.
    match_method    TEXT,

    mission         TEXT,
    mission_type    TEXT,
    pad             TEXT,
    location        TEXT,
    image_url       TEXT,

    source_updated  TIMESTAMPTZ,
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    data_source     TEXT NOT NULL DEFAULT 'launchlibrary2',
    fetched_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT upcoming_match_complete CHECK (
        (provider_code IS NULL AND match_method IS NULL)
        OR (provider_code IS NOT NULL AND match_method IS NOT NULL)
    ),
    CONSTRAINT upcoming_window_order CHECK (
        window_start IS NULL OR window_end IS NULL
        OR window_end >= window_start
    )
);

-- The field the product keys on, computed where it cannot drift.
ALTER TABLE upcoming_launches
    ADD COLUMN IF NOT EXISTS net_confidence TEXT
    GENERATED ALWAYS AS (
        CASE
            WHEN net IS NULL THEN 'undated'
            WHEN net_precision IN ('Second', 'Minute', 'Hour', 'Day')
                THEN 'dated'
            WHEN net_precision IS NULL THEN 'undated'
            ELSE 'approximate'
        END
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_upcoming_net ON upcoming_launches (net);
CREATE INDEX IF NOT EXISTS idx_upcoming_confidence
    ON upcoming_launches (net_confidence);
CREATE INDEX IF NOT EXISTS idx_upcoming_provider
    ON upcoming_launches (provider_code) WHERE provider_code IS NOT NULL;

COMMENT ON TABLE upcoming_launches IS
    'Upcoming launch manifest from Launch Library 2 (theSpaceDevs). '
    'NOT a schedule: 348 of 363 are "To Be Determined" and half are '
    'known only to the year. Free tier is 15 requests/hour; attribution '
    'to theSpaceDevs is required wherever this renders.';

COMMENT ON COLUMN upcoming_launches.net IS
    '"No earlier than", not a launch date. Meaningless without '
    'net_precision beside it.';

COMMENT ON COLUMN upcoming_launches.net_precision IS
    'theSpaceDevs'' own precision name: Second, Minute, Hour, Day, '
    'Month, Quarter N, Year Half N, Year, Fiscal Year, Decade. Kept '
    'verbatim rather than mapped, because the vocabulary is theirs and '
    'a mapping is a place to be wrong.';

COMMENT ON COLUMN upcoming_launches.net_confidence IS
    'GENERATED. dated = Day or finer, and may be rendered as a date. '
    'approximate = Month or coarser, and may not. undated = no net. An '
    'unrecognised precision falls to approximate deliberately: the '
    'failure mode must be "vaguer than it is", never "a schedule when '
    'it is not".';

COMMENT ON COLUMN upcoming_launches.last_seen_at IS
    'Stamped every import. A launch leaves the manifest by happening; '
    'rows are never deleted, so what was expected and when stays on the '
    'record - and 019 took DELETE away from the pipeline role anyway.';

-- ── Current manifest ─────────────────────────────────────────────────

CREATE OR REPLACE VIEW upcoming_launches_current
WITH (security_invoker = true) AS
SELECT *
  FROM upcoming_launches
 WHERE last_seen_at >= (SELECT max(last_seen_at) - INTERVAL '1 hour'
                          FROM upcoming_launches);

COMMENT ON VIEW upcoming_launches_current IS
    'Rows present in the most recent import. The hour of slack covers a '
    'run that spans the boundary; it is not a freshness guarantee.';

-- ── Access ───────────────────────────────────────────────────────────

ALTER TABLE upcoming_launches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read upcoming_launches" ON upcoming_launches;
CREATE POLICY "Public read upcoming_launches"
    ON upcoming_launches FOR SELECT USING (true);

DROP POLICY IF EXISTS "pipeline writes upcoming_launches" ON upcoming_launches;
CREATE POLICY "pipeline writes upcoming_launches"
    ON upcoming_launches FOR ALL TO pipeline USING (true) WITH CHECK (true);

GRANT SELECT ON upcoming_launches         TO anon;
GRANT SELECT ON upcoming_launches_current TO anon;
GRANT SELECT, INSERT, UPDATE ON upcoming_launches TO pipeline;

REVOKE TRUNCATE, TRIGGER, REFERENCES ON upcoming_launches         FROM anon, authenticated;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON upcoming_launches_current FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON upcoming_launches FROM anon, authenticated;
REVOKE DELETE, TRUNCATE ON upcoming_launches FROM pipeline;

-- Verify:
--
--   SELECT net_confidence, count(*) FROM upcoming_launches
--    GROUP BY 1 ORDER BY 2 DESC;      -- expect approximate >> dated
--
--   -- an unrecognised precision must NOT become 'dated'
--   INSERT INTO upcoming_launches (id, name, net, net_precision)
--   VALUES ('probe', 'x', NOW(), 'Fortnight');
--   SELECT net_confidence FROM upcoming_launches WHERE id='probe';
--   -- expect: approximate
