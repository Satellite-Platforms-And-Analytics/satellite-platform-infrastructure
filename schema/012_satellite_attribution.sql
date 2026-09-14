-- 012_satellite_attribution.sql
--
-- Every source's claim about every field, kept side by side instead of
-- collapsed at write time.
--
-- WHY NOW: THE TRIGGER 004 NAMED HAS FIRED THREE TIMES
-- ===================================================
-- `004_catalog_provenance.sql` put `data_source`, `match_method`,
-- `source_confidence` and `matched_at` on `satellites` and said plainly
-- that they are row-level: one answer for the whole row. It named the
-- condition that would make them insufficient - two sources writing
-- different fields of the same row - and left the per-field table for
-- when that actually happened.
--
--   2026-09-11  GCAT's pass took ownership of the provenance columns for
--               17,486 rows whose country_code, launch_site, object_type,
--               rcs_size and status came from SATCAT. The row now says
--               'gcat' for five fields GCAT never wrote.
--
--   2026-09-14  66 launch dates where SATCAT and GCAT disagree. The write
--               path is COALESCE(new, existing) - last writer wins - so
--               the source rated 0.95 was about to overrule the one rated
--               1.0. Stopped with `fill_only`, which is a stopgap: it
--               picks a winner earlier rather than keeping both.
--
--   2026-09-14  24 operator disagreements, plus 1,944 objects where GCAT
--               holds several records under one catalogue number. Which
--               record's claim won was, until f8ecdeb, whichever row
--               Postgres reached first.
--
-- Each was handled by choosing a winner and discarding the loser. This
-- table stops discarding it.
--
-- WHAT IT IS FOR, PRECISELY
-- =========================
-- `satellites` stays the serving table: typed columns, one value, what
-- the API reads. Nothing about that changes, and no query has to learn a
-- new shape.
--
-- This is the evidence beneath it. It answers three questions the serving
-- table cannot:
--
--   1. Where did THIS field come from - not this row.
--   2. What did the other source say, and with what confidence.
--   3. Has anything changed since the last run, and what.
--
-- "SATCAT says 2023-11-03, GCAT says 2023-11-04" becomes a queryable
-- fact instead of a decision baked into whichever importer ran last.
--
-- WHY value IS TEXT
-- =================
-- A date, a real and a text column all have to live in one place, and the
-- alternatives are worse: a column per type is five mostly-NULL columns,
-- and JSONB buys flexibility this does not need at the cost of every
-- comparison. The typed column on `satellites` remains authoritative -
-- this is a record of what was claimed, and a claim is a string until
-- something decides it is a date.
--
-- Comparison is therefore textual. Two sources that agree on a date but
-- format it differently would read as a conflict, which is why writers
-- normalise before recording rather than after.
--
-- SIZE, BECAUSE THIS PROJECT HAS BEEN HERE
-- ========================================
-- 17,487 tracked objects x ~8 descriptive fields x 2 sources is ~280,000
-- rows at roughly 90 bytes: **~25 MB**. The tier is 500 MB and sits at
-- 45% after the 2026-09-10 archive work, so this fits - but it is the
-- largest single addition since, and it is bounded by design: one row per
-- (object, field, source), never per run. A fourth source adds ~12 MB,
-- not a multiple.
--
-- `observed_at` is overwritten on re-import rather than appended. History
-- of a *claim over time* would be unbounded and is what `ingestion_log`
-- and the Parquet archive are for.

CREATE TABLE IF NOT EXISTS satellite_attribution (
    norad_id          INTEGER NOT NULL
                      REFERENCES satellites(norad_id) ON DELETE CASCADE,

    -- The column on `satellites` this claim is about. Not an enum: a new
    -- enrichment column should not need a migration here, and a typo is
    -- caught by the writer against the real column list rather than by a
    -- constraint that has to be maintained twice.
    field             TEXT NOT NULL,

    -- 'satcat', 'gcat', 'ucs', 'curated' - the same vocabulary as
    -- satellites.data_source, deliberately, so the two can be compared.
    source            TEXT NOT NULL,

    value             TEXT,
    match_method      TEXT,
    source_confidence REAL,
    observed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (norad_id, field, source)
);

COMMENT ON TABLE satellite_attribution IS
    'One row per (object, field, source): what each source claims about '
    'each field. `satellites` remains the serving table with one typed '
    'value per column; this is the evidence beneath it, so a disagreement '
    'between sources is a queryable fact rather than a decision baked '
    'into whichever importer ran last. Anticipated by 004; built after '
    'the condition it named fired three times.';

COMMENT ON COLUMN satellite_attribution.value IS
    'The claim, as text. The typed column on `satellites` is '
    'authoritative; this records what was said. Writers normalise before '
    'recording, since comparison here is textual and two sources '
    'formatting one date differently would otherwise read as a conflict.';

COMMENT ON COLUMN satellite_attribution.observed_at IS
    'When this source last made this claim. Overwritten on re-import, not '
    'appended: the history of a claim over time is unbounded and belongs '
    'in ingestion_log and the Parquet archive.';

-- "What does every source say about this object" - the per-object view.
CREATE INDEX IF NOT EXISTS idx_attr_object ON satellite_attribution (norad_id);
-- "Which objects does this source have an opinion about" - per-pass
-- reporting, and the index a coverage query needs.
CREATE INDEX IF NOT EXISTS idx_attr_source_field
    ON satellite_attribution (source, field);

-- ── Where the sources disagree ───────────────────────────────────────
--
-- The whole point of the table, as a query nobody has to re-derive.
--
-- security_invoker = true from the start (AD-070). Three views shipped in
-- 001 without it and ran with their owner's privileges for nine months;
-- every view since states it.

CREATE OR REPLACE VIEW satellite_field_conflicts
WITH (security_invoker = true) AS
SELECT
    a.norad_id,
    s.name,
    a.field,
    count(DISTINCT a.value)                      AS distinct_values,
    count(*)                                     AS sources,
    max(a.source_confidence)                     AS best_confidence,
    (array_agg(a.source ORDER BY a.source_confidence DESC NULLS LAST,
                                a.source))[1]    AS most_confident_source,
    (array_agg(a.value  ORDER BY a.source_confidence DESC NULLS LAST,
                                a.source))[1]    AS most_confident_value,
    array_agg(a.source || '=' || COALESCE(a.value, 'NULL')
              ORDER BY a.source)                 AS claims
FROM satellite_attribution a
JOIN satellites s ON s.norad_id = a.norad_id
WHERE a.value IS NOT NULL
GROUP BY a.norad_id, s.name, a.field
HAVING count(DISTINCT a.value) > 1;

COMMENT ON VIEW satellite_field_conflicts IS
    'Objects where two sources claim different values for one field. '
    '`most_confident_value` is what the confidence ordering would choose - '
    'which is NOT necessarily what satellites holds, because the write '
    'path is last-writer-wins. A row here whose satellites value differs '
    'from most_confident_value is a case where the less reliable source '
    'won, and that gap is the reason this table exists.';

-- ── Access ───────────────────────────────────────────────────────────

ALTER TABLE satellite_attribution ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read satellite_attribution" ON satellite_attribution;
CREATE POLICY "Public read satellite_attribution"
    ON satellite_attribution FOR SELECT USING (true);

GRANT SELECT ON satellite_attribution TO anon;

-- 010 revoked these schema-wide and set ALTER DEFAULT PRIVILEGES. Stated
-- anyway, and tests/test_db_privileges.py is what proves it worked.
REVOKE TRUNCATE, TRIGGER, REFERENCES ON satellite_attribution FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE       ON satellite_attribution FROM anon, authenticated;

-- The view inherits nothing: a grant on a view is separate from a grant
-- on its tables, and with security_invoker the caller still needs SELECT
-- on satellite_attribution and satellites. Both are public-read.
GRANT SELECT ON satellite_field_conflicts TO anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON satellite_field_conflicts FROM anon, authenticated;

-- Verify:
--
--   SELECT source, field, count(*) FROM satellite_attribution
--    GROUP BY 1,2 ORDER BY 1,2;
--
--   -- the 66 launch-date disagreements, as data rather than as a report
--   SELECT * FROM satellite_field_conflicts WHERE field = 'launch_date';
--
--   -- where the less reliable source won
--   SELECT c.norad_id, c.field, c.most_confident_value, s.launch_date
--     FROM satellite_field_conflicts c JOIN satellites s USING (norad_id)
--    WHERE c.field = 'launch_date'
--      AND c.most_confident_value IS DISTINCT FROM s.launch_date::text;
--
--   python check_grants.py     -- expect security_invoker=true on the view
