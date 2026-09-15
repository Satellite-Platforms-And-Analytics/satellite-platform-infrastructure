-- 018_taxonomy_areas.sql
--
-- The TX areas get their names from NASA, not from memory.
--
-- WHY
-- ===
-- 015 stores a taxonomy node's code and title, and derives `tx_top` by
-- prefix. So the platform knows a project sits under TX08 and knows the
-- node is "Microwave, Millimeter Waves, and Submillimeter Waves" - and
-- has no idea that TX08 itself is called "Sensors and Instruments".
--
-- A readiness page labelled "TX08" is a page nobody can read. The
-- obvious fix is to hardcode seventeen names, which is the mistake this
-- project has made and corrected twice: the 09-11 plan written from
-- memory instead of from `data/seed/README.md`, and the rate limit
-- asserted as 1,000/hr while the server was printing 2,000 on every
-- response.
--
-- THE SOURCE ALREADY CARRIES THEM. TechPort's `primaryTxTree` is the
-- full ancestry of each node, and its `level: 1` entry is the area with
-- its official title:
--
--     {"code": "TX03", "title": "Aerospace Power and Energy Storage",
--      "level": 1, ...}
--
-- Found by reading a cached detail rather than by assuming the field was
-- not there - the same look that found lastUpdated's MM/DD/YY format.
--
-- BACKFILL IS FREE. Every project detail is held in
-- data/cache/techport, so `seed_techport --apply --refresh` fills this
-- table for projects already imported at a cost of zero API requests.

CREATE TABLE IF NOT EXISTS research_taxonomy_areas (
    code        TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    data_source TEXT NOT NULL DEFAULT 'techport',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Top level only. TX08, never TX08.1.5 - the whole point is a label
    -- for the seventeen buckets `tx_top` rolls up to, and a deeper code
    -- in here would produce an area that no row ever joins to.
    CONSTRAINT research_area_is_top_level
        CHECK (code ~ '^TX[0-9]{2}$')
);

COMMENT ON TABLE research_taxonomy_areas IS
    'NASA TX top-level areas with their official titles, taken from '
    'TechPort''s primaryTxTree (level 1). Populated by the importer - '
    'not hardcoded, because seventeen names typed from memory is how a '
    'label drifts from the taxonomy it claims to describe.';

-- The view gains the title. DROP and CREATE rather than CREATE OR
-- REPLACE: replace can only append columns, and the title belongs
-- beside the code it names rather than after the statistics.
DROP VIEW IF EXISTS research_activity_by_area;

CREATE VIEW research_activity_by_area
WITH (security_invoker = true) AS
SELECT
    t.tx_top                                    AS tx_area,
    a.title                                     AS tx_area_title,
    count(DISTINCT p.techport_id)               AS projects,
    count(DISTINCT p.lead_org_id)               AS performers,
    count(p.trl_current)                        AS projects_with_trl,
    min(p.trl_current)                          AS trl_min,
    max(p.trl_current)                          AS trl_max,
    round(avg(p.trl_current)::numeric, 1)       AS trl_mean
FROM research_project_taxonomy t
JOIN research_projects p USING (techport_id)
-- LEFT, so an area whose title has not been imported yet still appears
-- with its projects. A missing label is worth seeing; a missing row is
-- not.
LEFT JOIN research_taxonomy_areas a ON a.code = t.tx_top
GROUP BY t.tx_top, a.title;

COMMENT ON VIEW research_activity_by_area IS
    'R&D activity per TX top-level area. Grouped on the GENERATED '
    'tx_top, never on a node title. tx_area_title is NULL until the '
    'importer has seen a primaryTxTree naming that area.';

-- ── Access ───────────────────────────────────────────────────────────

ALTER TABLE research_taxonomy_areas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read research_taxonomy_areas"
    ON research_taxonomy_areas;
CREATE POLICY "Public read research_taxonomy_areas"
    ON research_taxonomy_areas FOR SELECT USING (true);

-- The DROP VIEW above took its grants with it, so they are restated
-- rather than assumed to have survived.
GRANT SELECT ON research_taxonomy_areas   TO anon;
GRANT SELECT ON research_activity_by_area TO anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON research_taxonomy_areas
    FROM anon, authenticated;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON research_activity_by_area
    FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON research_taxonomy_areas
    FROM anon, authenticated;

-- Verify:
--
--   SELECT * FROM research_taxonomy_areas ORDER BY code;   -- <= 17 rows
--   SELECT tx_area, tx_area_title, projects
--     FROM research_activity_by_area ORDER BY projects DESC;
--   -- a deeper code is refused
--   INSERT INTO research_taxonomy_areas (code, title)
--   VALUES ('TX08.1', 'too deep');                         -- expect refusal
