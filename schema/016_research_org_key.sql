-- 016_research_org_key.sql
--
-- The survey answered 015's open question, so the key changes.
--
-- WHAT 015 SAID
-- =============
-- 015 recorded, rather than guessed:
--
--   > TechPort's `leadOrganization` is an object. The survey extracted
--   > `organizationName` from it and nothing else, so it is NOT KNOWN
--   > whether it carries a stable organisation id. [...] this table uses
--   > a surrogate key with a UNIQUE normalised name, and reserves
--   > `techport_org_id` for the day the importer's survey answers the
--   > question. When it does, the FK does not have to change.
--
-- WHAT THE SURVEY MEASURED, 2026-09-15
-- ====================================
-- `organizationId` is present on 50 of 50 sampled projects, alongside
-- organizationName, organizationType, city, stateTerritory, country and
-- organizationRole. So TechPort does carry a stable id, and it - not a
-- normalised name - is what `research_organizations` upserts on.
--
-- WHY THAT MAKES `name_norm` UNIQUE WRONG
-- =======================================
-- `name_norm` was UNIQUE for exactly one reason: it was going to be the
-- upsert key. It is not, and leaving the constraint in place would now
-- REJECT legitimate rows - two distinct TechPort organisation records
-- whose names normalise alike, which is entirely ordinary once
-- punctuation and corporate suffixes are stripped ("Ames Research
-- Center" recorded twice under different ids, a renamed division, a
-- subsidiary).
--
-- The failure would not be a bad row. It would be an IntegrityError
-- partway through an import of 19,690 projects, on project number
-- unknown, for a reason that reads like corruption and is not.
--
-- This costs nothing today because `research_organizations` holds zero
-- rows. That is the whole argument for doing it now: the survey was run
-- BEFORE the import, so the key decision is a constraint swap rather
-- than a data migration.
--
-- WHAT REPLACES IT
-- ================
-- `techport_org_id` stays UNIQUE and becomes the natural key. It is NOT
-- made NOT NULL: 100% of a 50-project sample is not 100% of 19,690, and
-- a performer with no id must still be importable rather than crash the
-- run. For those rows `name_norm` remains the identity, so it keeps a
-- UNIQUE index - but only among rows that have no id, which is exactly
-- where it is still the key and nowhere else.

ALTER TABLE research_organizations
    DROP CONSTRAINT IF EXISTS research_org_name_norm_key;

-- The fallback key, scoped to the rows it is actually the key for.
CREATE UNIQUE INDEX IF NOT EXISTS research_org_name_norm_when_no_id
    ON research_organizations (name_norm)
    WHERE techport_org_id IS NULL;

-- Lookups by name remain common (the organizations match runs over it),
-- and dropping the constraint dropped its index with it.
CREATE INDEX IF NOT EXISTS idx_research_org_name_norm
    ON research_organizations (name_norm);

COMMENT ON COLUMN research_organizations.name_norm IS
    'Normalised name, by src/catalog/org_match.py''s rules. The upsert '
    'key ONLY for performers with no techport_org_id - unique among '
    'those rows and deliberately not unique overall, since two TechPort '
    'organisation records can normalise alike (016).';

COMMENT ON COLUMN research_organizations.techport_org_id IS
    'TechPort''s organizationId. The natural key: present on 50 of 50 '
    'sampled projects, 2026-09-15. Nullable on purpose - 100% of a '
    'sample is not 100% of 19,690, and a performer with no id must be '
    'importable rather than stop a ten-hour run.';

-- Verify:
--
--   -- two records normalising alike are now both storable
--   INSERT INTO research_organizations (name, name_norm, techport_org_id)
--   VALUES ('Ames Research Center','ames research center', 1),
--          ('Ames Research Center.','ames research center', 2);   -- expect OK
--
--   -- but two id-less records that normalise alike are still refused
--   INSERT INTO research_organizations (name, name_norm)
--   VALUES ('X','collide'), ('X.','collide');                     -- expect refusal
