-- 005_owner_code.sql
--
-- Record SATCAT's OWNER verbatim, because country_code cannot hold it.
--
-- WHAT THE SURVEY FOUND
-- =====================
-- `python -m src.catalog.seed_satcat --survey` against the live SATCAT
-- (70,580 records, 2026-09-05):
--
--     OWNER: 130 distinct codes
--       resolve to a seeded ISO country: 43,271 rows (61.3%)
--       longer than country_code's VARCHAR(3): 49 codes
--         ARGN, ASRA, AZER, BELA, BHUT, BRAZ, CHBZ, CHLE, CZCH,
--         EGYP, ESRO, EUME, TURK, ...
--
-- So `country_code VARCHAR(3) REFERENCES countries(code)` cannot take
-- this field, for three independent reasons:
--
--   1. LENGTH. 49 of the 130 codes are four characters or more.
--   2. VOCABULARY. SATCAT uses its own abbreviations - US not USA,
--      PRC not CHN, UK not GBR - not ISO 3166-1 alpha-3.
--   3. THEY ARE NOT ALL COUNTRIES. ESA (181), ITSO (143), ISS (135),
--      GLOB (86), SES (69), EUTE (62), O3B (30), NATO (8) are
--      organisations. A table called `countries` should not grow rows
--      for them, and the largest single code is CIS (25,220) - the
--      former Soviet Union, which is not a current state at all.
--
-- WHY NOT JUST MAP EVERYTHING
-- ===========================
-- Because attributing an object to the wrong country is worse than
-- leaving it unattributed - the convention 004 established, and the
-- reason source_confidence exists. CIS is the clear case: collapsing
-- 25,220 objects to RUS asserts a succession this project has no basis
-- to assert object by object, and it would silently rewrite the
-- ownership of every Soviet-era launch.
--
-- So: keep the source's own value, always, losslessly. Resolve
-- country_code only where a mapping is confident and the ISO code is
-- actually seeded in `countries`. An object can have owner_code without
-- country_code; that is the honest state, not a gap to be filled.

ALTER TABLE satellites
    ADD COLUMN IF NOT EXISTS owner_code TEXT;

COMMENT ON COLUMN satellites.owner_code IS
    'SATCAT OWNER, verbatim: US, PRC, CIS, ESA, ITSO, NATO and ~124 '
    'others. Not ISO, not always a country, and not always three '
    'characters. country_code holds the resolved ISO alpha-3 where one '
    'exists and is seeded in countries; this column always holds what '
    'the source actually said.';

-- Phase 3 groups by operator nationality constantly, and owner_code is
-- the only column that covers every row.
CREATE INDEX IF NOT EXISTS idx_satellites_owner_code
    ON satellites (owner_code);

-- Objects SATCAT reports as still in orbit, for the coverage gap the
-- new-object detector reports against.
CREATE INDEX IF NOT EXISTS idx_satellites_object_type
    ON satellites (object_type);

-- Verify:
--
--   SELECT count(*) AS total,
--          count(owner_code)   AS have_owner,
--          count(country_code) AS have_iso
--     FROM satellites;
--
-- Before the first enrichment run all three of the last columns are 0.
-- After it, expect have_owner to approach the row count and have_iso to
-- sit near 61% of it. A have_iso ABOVE have_owner means something
-- resolved a country without recording the source value, which inverts
-- the design and should be investigated rather than accepted.
