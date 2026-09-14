-- 011_organizations.sql
--
-- The organisations that build, own and operate what is in orbit - and an
-- exact key from a satellite to one of them.
--
-- WHY THIS IS THE COMPANY SPINE, AND WHY THAT REVERSES AD-044
-- ==========================================================
-- AD-044 named WIT the Phase 3 company source, on the reasoning that it
-- supplies curated entities and relationships. That reasoning still holds
-- for what WIT is good at. It is not the right *spine*.
--
-- `data/seed/orgs.tsv` - GCAT's organisation table, already on disk since
-- 2026-08-26, CC-BY, no account and no rate limit - carries **4,109
-- organisations** with a stable code, a short name, a native name, an
-- English name, a type, a class, a state, a location and a parent.
--
-- Measured against the GCAT catalogue on 2026-09-14:
--
--     objects with a NORAD id     74,059
--     distinct owner org codes     1,641
--     90% of objects belong to        63 codes
--
-- That concentration is the argument. Sixty-three organisations account
-- for nine objects in ten, so even partial enrichment of this table moves
-- almost the whole catalogue - and the remaining 1,578 codes still exist,
-- named and attributable, rather than being an unattributed tail.
--
-- So: GCAT orgs is the spine, because it is complete, exact-keyed and
-- already here. WIT becomes enrichment - websites, relationships, the
-- things GCAT has no opinion about. A curated list is worth more when it
-- has something to attach to.
--
-- THE EXACT KEY, WHICH WAS BEING THROWN AWAY
-- ==========================================
-- `seed_gcat.py` reads GCAT's `Owner` code, uses it to resolve a display
-- name, and discards it. `owner_code` on `satellites` could not receive it
-- because that column belongs to SATCAT's *different* code system (005:
-- US, PRC, CIS, ESA - 130 country-ish codes), so the GCAT org code had
-- nowhere to go.
--
-- The consequence is that nothing in this database records WHICH
-- organisation operates an object - only a name string. Every
-- company-to-satellite question would have to be answered by matching
-- names, which is the one risk class Phase 2 spent real effort avoiding
-- and which AD-062 flagged again for TechPort.
--
-- `operator_code` fixes that. It is the same quality of join as
-- `norad_id`: a code, from the source, matched exactly or not at all.
--
-- NAMES: THREE OF THEM, ON PURPOSE
-- ================================
-- GCAT gives three and they are not interchangeable:
--
--   name_native   `Name`       100% populated. The transliterated native
--                              form - "Zhongguo kongjian jishu yanjiu
--                              yuan", "Ucyu Koku Kenkyu Kaihatsu Kikou".
--   name_english  `EName`       34% populated - and populated *precisely*
--                              where `Name` is not English. CAST ->
--                              "Chinese Academy of Space Technology".
--   name_short    `ShortName`  100% populated. The recognisable handle:
--                              SpaceX, Planet, ESA, ISRO, CAST.
--
-- `satellites.operator` currently holds `Name`, because that is what
-- resolve_owner() preferred. A "top operators" chart built on it would
-- list transliterated names nobody recognises - and would read as a data
-- problem rather than a column choice.
--
-- Storing all three means the display decision is made in a query, once,
-- and can be changed without re-importing anything. `display_name` is
-- generated: English if there is one, else the native form, with the short
-- name available separately for axis labels and chips.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- ============================================
-- It does not change `satellites.operator`. Re-resolving 17,457 rows onto
-- a different name column is a data change, and this project's rule is
-- survey first with the predicted effect written down. That is the next
-- step, not this one.

-- ── Organisations ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS organizations (
    code          TEXT PRIMARY KEY,        -- GCAT org code: SPX, CAST, ESA
    ucode         TEXT,                    -- GCAT's normalised form

    name_native   TEXT NOT NULL,           -- Name       (100%)
    name_english  TEXT,                    -- EName      (34%, where needed)
    name_short    TEXT,                    -- ShortName  (100%)

    -- 'O' operator, 'LV' launch vehicle, 'PL' payload builder, 'LA'
    -- launch agency, 'S' site... and compounds: 'O/LA/LV/PL/E/LS/S'.
    -- Kept verbatim. Splitting it into booleans is a decision that wants
    -- its own survey, and a compound value is information, not noise.
    org_type      TEXT,
    org_class     TEXT,                    -- A / B / C / D

    state_code    TEXT,                    -- GCAT's own state vocabulary
    location      TEXT,
    longitude     DOUBLE PRECISION,
    latitude      DOUBLE PRECISION,
    parent_code   TEXT,                    -- self-reference, NOT an FK: see below

    data_source       TEXT,
    match_method      TEXT,
    source_confidence REAL,
    matched_at        TIMESTAMPTZ,

    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- `parent_code` is not declared REFERENCES organizations(code) on purpose.
-- GCAT's parent values are not guaranteed to resolve within the file, and
-- a foreign key would make one dangling parent reject the whole import.
-- Prefer loading every organisation with an unresolvable parent over
-- loading none - the same principle as 005: keep the source's value
-- losslessly and resolve where it is confident.
CREATE INDEX IF NOT EXISTS idx_org_parent ON organizations (parent_code);
CREATE INDEX IF NOT EXISTS idx_org_short  ON organizations (name_short);
CREATE INDEX IF NOT EXISTS idx_org_type   ON organizations (org_type);

-- One name to render, decided once. English where GCAT has it, native
-- otherwise. Generated rather than stored by the importer so it cannot
-- drift from its inputs - the same reasoning as technologies.readiness_gap.
ALTER TABLE organizations
    ADD COLUMN IF NOT EXISTS display_name TEXT
    GENERATED ALWAYS AS (COALESCE(NULLIF(name_english, ''), name_native)) STORED;

COMMENT ON TABLE organizations IS
    'Organisations from GCAT''s org table (4,109 rows): operators, '
    'manufacturers, launch agencies, sites and states. The spine of the '
    'company picture - complete, exact-keyed and already on disk. WIT '
    'enriches these rows; it does not define them.';

COMMENT ON COLUMN organizations.name_native IS
    'GCAT `Name`: the transliterated native form, 100% populated. Not a '
    'display name for an English-language audience.';

COMMENT ON COLUMN organizations.name_english IS
    'GCAT `EName`, 34% populated - present precisely where `Name` is not '
    'English. Absence means `Name` is already English, not that the name '
    'is unknown.';

COMMENT ON COLUMN organizations.org_type IS
    'GCAT type, verbatim, including compounds like O/LA/LV/PL/E/LS/S. '
    'O=operator, LV=launch vehicle, PL=payload builder, LA=launch agency, '
    'S=site, E=engine, LS=launch site. Compound values are information.';

-- ── The exact key from an object to an organisation ──────────────────

ALTER TABLE satellites
    ADD COLUMN IF NOT EXISTS operator_code TEXT;

COMMENT ON COLUMN satellites.operator_code IS
    'GCAT organisation code for the operator - the exact join to '
    'organizations(code). Distinct from owner_code, which holds SATCAT''s '
    'country-ish vocabulary (005). seed_gcat.py read this code, used it to '
    'resolve a name and discarded it, which left every company-to-satellite '
    'question needing a fuzzy name match.';

CREATE INDEX IF NOT EXISTS idx_sat_operator_code ON satellites (operator_code);

-- ── Access ───────────────────────────────────────────────────────────

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read organizations" ON organizations;
CREATE POLICY "Public read organizations"
    ON organizations FOR SELECT USING (true);

GRANT SELECT ON organizations TO anon;

-- 010 revoked these at the schema level and set ALTER DEFAULT PRIVILEGES,
-- so a new table should no longer be born with them. Stated anyway: this
-- is the first table created after that change, and "should no longer" is
-- a belief until something checks it. tests/test_db_privileges.py is what
-- checks it.
REVOKE TRUNCATE, TRIGGER, REFERENCES ON organizations FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE       ON organizations FROM anon, authenticated;

-- Verify:
--
--   SELECT count(*) FROM organizations;                       -- expect 4,109
--   SELECT count(*) FROM organizations WHERE name_english <> '';  -- ~1,388
--   SELECT code, name_short, display_name FROM organizations
--    WHERE code IN ('CAST','JAXA','SPX','PLAN','ESA');
--
--   -- after seed_gcat writes operator_code:
--   SELECT o.display_name, count(*) FROM satellites s
--     JOIN organizations o ON o.code = s.operator_code
--    GROUP BY 1 ORDER BY 2 DESC LIMIT 15;
--
--   python check_grants.py     -- organizations: SELECT to anon, nothing else
