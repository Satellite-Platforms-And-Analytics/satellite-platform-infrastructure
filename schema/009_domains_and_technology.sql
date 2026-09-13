-- 009_domains_and_technology.sql
--
-- Technology readiness, and the domain scoping that lets this outlive
-- space.
--
-- WHY THIS IS THE FIRST BUILD OF THE NEW DIRECTION
-- ================================================
-- Restated 2026-09-12: the main effort is industry, company and
-- technology capability. The question is *what technology exists across
-- the human space domain, who builds it, and how ready is it* - not
-- *where is this satellite*. The satellite catalogue becomes an evidence
-- stream feeding that picture (AD-051).
--
-- TRL/MRL was absent from the roadmap entirely while being a stated MVP
-- requirement, and 69 curated records have sat unused in
-- `technologies_readiness.py` since 2026-06-26. They span the WHOLE
-- domain - Launch Propulsion, Hypersonic Systems, Reentry & Landing,
-- On-Orbit Operations - not just satellites. The prior art was already
-- aligned with the ambition; the satellite catalogue is the narrower
-- thing.
--
-- DOMAIN SCOPING (AD-050)
-- =======================
-- The requirement includes adding other domains later. So `space` is a
-- ROW in `domains`, not an assumption baked into table names, columns or
-- queries.
--
-- This is one small table and one foreign key. It is NOT an abstraction
-- layer, and no further generality is being bought here: no polymorphic
-- attributes, no entity-attribute-value, no plugin registry. The whole
-- justification is arithmetic - adding `domain_id` now costs one column;
-- adding it after `technologies`, `companies` and their join tables are
-- populated means rewriting every one of them and every query over them.
--
-- The Phase 3 definition of done states the test: **adding a second
-- domain must require no schema change.**
--
-- ASSESSMENT BASIS IS NOT NULL (AD-052)
-- =====================================
-- A TRL or MRL with no stated basis is an opinion. Every one of the 69
-- curated records carries one - NASA/ESA, DARPA/AFRL, SpaceX/Blue Origin,
-- Industry - and the column is NOT NULL so the next source cannot quietly
-- drop it. A readiness level is a judgement; a judgement with no
-- provenance cannot be revisited, defended or corrected.
--
-- This is the same discipline as 004_catalog_provenance.sql, applied to
-- assessments rather than facts.

-- ── Domains ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS domains (
    id          SERIAL PRIMARY KEY,
    slug        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE domains IS
    'The subject areas this platform assesses. `space` is row one; the '
    'reason technologies, categories and companies carry domain_id rather '
    'than assuming space. Adding a domain must require no schema change.';

INSERT INTO domains (slug, name, description)
VALUES ('space', 'Human Space Domain',
        'Everything humans build, launch, operate and recover beyond the '
        'atmosphere - launch, spacecraft, payloads, ground segment, '
        'on-orbit operations, reentry and hypersonics.')
ON CONFLICT (slug) DO NOTHING;

-- ── Technology categories ────────────────────────────────────────────
--
-- Nested under a domain, so "Launch Propulsion" belongs to space and a
-- future domain brings its own without colliding.

CREATE TABLE IF NOT EXISTS technology_categories (
    id          SERIAL PRIMARY KEY,
    domain_id   INTEGER NOT NULL REFERENCES domains(id),
    slug        TEXT NOT NULL,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (domain_id, slug)
);

COMMENT ON COLUMN technology_categories.slug IS
    'Short stable key, taken from the curated file''s id prefix (lp, sp, '
    'cm ...). Survives a rename of the display name.';

-- ── Technologies ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS technologies (
    id               SERIAL PRIMARY KEY,
    domain_id        INTEGER NOT NULL REFERENCES domains(id),
    category_id      INTEGER REFERENCES technology_categories(id),

    ref              TEXT NOT NULL,      -- 'lp-001', the curated natural key
    name             TEXT NOT NULL,

    trl              SMALLINT CHECK (trl BETWEEN 1 AND 9),
    mrl              SMALLINT CHECK (mrl BETWEEN 1 AND 9),

    -- AD-052. NOT NULL on purpose: see the header.
    assessment_basis TEXT NOT NULL,
    assessed_at      DATE,

    description      TEXT,
    notes            TEXT,

    -- Same provenance discipline as satellites (004). An assessment is a
    -- claim and has to say where it came from.
    data_source       TEXT,
    match_method      TEXT,
    source_confidence REAL,
    matched_at        TIMESTAMPTZ,

    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (domain_id, ref)
);

-- The headline analytic of this whole epic, computed rather than stored
-- by hand so it cannot drift from its inputs.
--
-- TRL above MRL means a technology is proven but not manufacturable at
-- rate - flight-demonstrated with a supply chain that cannot deliver it.
-- 18 of the 69 curated records sit 2 or more apart. That set is the most
-- useful thing a readiness assessment produces, and everything else here
-- exists to make this column queryable.
ALTER TABLE technologies
    ADD COLUMN IF NOT EXISTS readiness_gap SMALLINT
    GENERATED ALWAYS AS (trl - mrl) STORED;

COMMENT ON COLUMN technologies.readiness_gap IS
    'trl - mrl. Positive means proven faster than it can be built: '
    'demonstrated capability outrunning manufacturing maturity. The '
    'primary view of this table.';

COMMENT ON COLUMN technologies.assessment_basis IS
    'Who or what the TRL/MRL judgement rests on - a programme, agency or '
    'industry position (NASA/ESA, DARPA/AFRL, Industry). NOT NULL by '
    'design: a readiness level with no basis is an opinion, and an '
    'opinion that cannot be attributed cannot be revisited (AD-052).';

CREATE INDEX IF NOT EXISTS idx_tech_domain      ON technologies (domain_id);
CREATE INDEX IF NOT EXISTS idx_tech_category    ON technologies (category_id);
CREATE INDEX IF NOT EXISTS idx_tech_gap         ON technologies (readiness_gap DESC);
CREATE INDEX IF NOT EXISTS idx_tech_trl_mrl     ON technologies (trl, mrl);

-- ── Access ───────────────────────────────────────────────────────────
--
-- Both halves, for the reason 002_public_read_grants.sql exists: GRANT
-- decides whether a role may touch the table, POLICY decides which rows
-- it sees. Missing grant is an error; missing policy is silently zero
-- rows.

ALTER TABLE domains               ENABLE ROW LEVEL SECURITY;
ALTER TABLE technology_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE technologies          ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read domains" ON domains;
CREATE POLICY "Public read domains"
    ON domains FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read technology_categories" ON technology_categories;
CREATE POLICY "Public read technology_categories"
    ON technology_categories FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public read technologies" ON technologies;
CREATE POLICY "Public read technologies"
    ON technologies FOR SELECT USING (true);

GRANT SELECT ON domains               TO anon;
GRANT SELECT ON technology_categories TO anon;
GRANT SELECT ON technologies          TO anon;

-- Supabase's default privileges grant ALL on new tables in public to anon
-- and authenticated, so these were born with the grants 003 spent a
-- migration removing. RLS does not apply to TRUNCATE.
REVOKE TRUNCATE, TRIGGER, REFERENCES ON domains               FROM anon, authenticated;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON technology_categories FROM anon, authenticated;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON technologies          FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON domains               FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON technology_categories FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON technologies          FROM anon, authenticated;

-- Verify:
--
--   SELECT d.slug, count(t.id)
--     FROM domains d LEFT JOIN technologies t ON t.domain_id = d.id
--    GROUP BY d.slug;
--   -- space | 69
--
--   -- the view this epic exists for
--   SELECT c.name, t.name, t.trl, t.mrl, t.readiness_gap, t.assessment_basis
--     FROM technologies t JOIN technology_categories c ON c.id = t.category_id
--    WHERE t.readiness_gap >= 2
--    ORDER BY t.readiness_gap DESC, c.name;
--   -- expect 18 rows
--
--   SELECT count(*) FROM technologies WHERE assessment_basis IS NULL;
--   -- 0, and the column will not permit otherwise
