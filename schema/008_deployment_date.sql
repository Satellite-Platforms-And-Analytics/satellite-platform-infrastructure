-- 008_deployment_date.sql
--
-- When an object began flying independently, which is not always when the
-- rocket that carried it left the ground.
--
-- THE BUG THIS FIXES
-- ==================
-- The international designator convention gives an object deployed from a
-- space station the STATION's launch designator. Every cubesat released
-- from the ISS is 1998-067<xx>, because 1998-067A is Zarya, and SATCAT's
-- LAUNCH_DATE for all of them is therefore 1998-11-20 - the day the ISS
-- launched, up to twenty-eight years before the object in question
-- existed as a separate thing.
--
-- That is correct by convention and wrong for the purpose. Measured
-- 2026-09-12 against GCAT: 634 objects carry an ISS designator, 532 of
-- them with catalogue numbers, deployed continuously - 8 in 2026 so far,
-- 24 in 2025, 28 in 2024, 40 in 2022.
--
-- `check_new_objects.py` classifies arrivals by the age of their launch
-- date:
--
--     if launch_age_days <= DEPLOYMENT_WINDOW_DAYS and not debris:
--         return "deployment"
--     ...
--     return "newly_visible"
--
-- An ISS cubesat's launch age is about 10,000 days, so it fails that test
-- and falls through to `newly_visible` - filed as an old object that
-- merely became trackable. **Every station-deployed payload has been
-- misclassified**, at 25-40 a year.
--
-- This is the same shape as the 2026-203 defect found on 2026-09-09: a
-- detector keyed on `launch_date` fed a value that was technically
-- defensible and useless for the question being asked. There the value
-- was NULL; here it is 1998.
--
-- WHY A COLUMN AND NOT AN OVERRIDE
-- ================================
-- The tempting fix is to let GCAT's date win for 1998-067*. That throws
-- away a real fact - the carrying vehicle's launch date - and needs an
-- exception list maintained as new stations appear (Mir 1986-017,
-- Tiangong 2021-035).
--
-- They are two different quantities and the schema should say so:
--
--     launch_date       when the vehicle that carried it launched
--     deployment_date   when it became an independent object
--
-- For the overwhelming majority these are the same day - of 17,457
-- objects where SATCAT and GCAT both have a date, 17,138 agree exactly.
-- The column earns its place on the ~532 where they cannot agree, because
-- they are answering different questions.
--
-- WHERE THE VALUE COMES FROM
-- ==========================
-- GCAT's `LDate`, via src/catalog/seed_gcat.py. GCAT is object-centric:
-- an object's date is when it began independent existence, which is the
-- deployment for anything released from a station and the launch for
-- everything else. That is exactly this column's definition, so the same
-- source field populates it for every row rather than only the exceptions
-- - a column filled only on special cases would need the special-case
-- list this design exists to avoid.
--
-- NO INDEX
-- ========
-- Deliberate. `satellites` holds ~18,000 rows and the detector's window
-- query is a sequential scan either way; an index here would be cargo.
-- Add one if the table grows toward the 35,023 on-orbit objects
-- COVERAGE_DECISION.md discusses.

ALTER TABLE satellites
    ADD COLUMN IF NOT EXISTS deployment_date DATE;

COMMENT ON COLUMN satellites.deployment_date IS
    'When the object began flying independently. Equal to launch_date for '
    'a directly-launched satellite; the release date for anything deployed '
    'from a space station, whose international designator - and therefore '
    'whose SATCAT launch_date - belongs to the station. Source: GCAT LDate '
    'via seed_gcat.py. Prefer COALESCE(deployment_date, launch_date) when '
    'asking how old an object is.';

COMMENT ON COLUMN satellites.launch_date IS
    'When the vehicle carrying this object launched. For an object '
    'deployed from a space station this is the STATION''s launch - 1998-11-20 '
    'for everything with a 1998-067 designator - which is correct by the '
    'designator convention and wrong for judging the object''s age. See '
    'deployment_date.';

-- Verify:
--
--   SELECT count(*) FROM satellites WHERE deployment_date IS NOT NULL;
--
--   -- the station-deployed objects this column exists for
--   SELECT norad_id, name, intl_designator, launch_date, deployment_date,
--          deployment_date - launch_date AS days_apart
--     FROM satellites
--    WHERE deployment_date IS DISTINCT FROM launch_date
--    ORDER BY days_apart DESC NULLS LAST
--    LIMIT 20;
--
-- Expect the ISS family at roughly 9,700-10,100 days apart, and the
-- midnight-straddling launches at 1.
