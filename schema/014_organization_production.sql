-- 014_organization_production.sql
--
-- How many payloads each organisation put up, per year.
--
-- WHY THIS IS THE CHEAPEST REAL EVIDENCE IN THE PLATFORM
-- =====================================================
-- The Technology Assessment Framework (2026-09-12) lists the indicators
-- that can support a manufacturing-readiness judgement and ranks them by
-- what each can honestly signal. At the top:
--
--     Units flown per year -> MRL 8-9 directly.  Source: our own
--     catalogue.  Honest limit: only for things that reach orbit.
--
-- AD-058 made it a decision: the catalogue is the primary MRL evidence
-- source, and counting production rate per operator per year is a QUERY,
-- not an acquisition. No new source, no account, no rate limit, no terms
-- to verify. It has been available since GCAT landed and unbuilt because
-- nothing could join an object to an organisation by key until 011.
--
-- > A bus that flew 2,000 units last year has a manufacturing readiness
-- > no announcement can argue with. A technology that has flown once in
-- > six years does not, whatever the press release says.
--
-- WHAT THIS VIEW REFUSES TO DO
-- ============================
-- It does not assign an MRL. It counts payloads per organisation per
-- year and stops.
--
-- That restraint is the same one AD-061 forced on TechPort. A production
-- count is EVIDENCE FOR a manufacturing-readiness judgement, not the
-- judgement: it says nothing about whether the organisation built the
-- spacecraft or bought it, whether one year's output was a constellation
-- deployment or a decade of work arriving at once, or whether the line
-- still exists. Turning a number into a level is an assessment, it
-- carries a basis (AD-052), and it does not happen in a view.
--
-- PAYLOADS, NOT OBJECTS
-- =====================
-- Counting rocket bodies would credit a launch provider with
-- manufacturing it never did - the distinction 013 introduced and the
-- reason f8ecdeb had to stop stage records being attributed to payloads
-- first. Objects are carried too, because "put 3,000 things up and
-- operated 200 of them" is itself a fact about an organisation.
--
-- THE YEAR IS THE DEPLOYMENT YEAR WHERE THERE IS ONE
-- ==================================================
-- COALESCE(deployment_date, launch_date), the same EFFECTIVE_LAUNCH rule
-- every age query uses since 008. Without it all 532 ISS-deployed
-- cubesats would count as 1998 production - the designator convention
-- that made every one of them look like a historical object.

CREATE OR REPLACE VIEW organization_production
WITH (security_invoker = true) AS
SELECT
    o.code,
    o.display_name,
    o.name_short,
    EXTRACT(YEAR FROM COALESCE(s.deployment_date, s.launch_date))::int
                                                            AS year,
    count(*) FILTER (WHERE s.object_type = 'PAYLOAD')        AS payloads,
    count(*)                                                 AS objects
FROM organizations o
JOIN satellites s ON s.operator_code = o.code
WHERE COALESCE(s.deployment_date, s.launch_date) IS NOT NULL
GROUP BY o.code, o.display_name, o.name_short,
         EXTRACT(YEAR FROM COALESCE(s.deployment_date, s.launch_date));

COMMENT ON VIEW organization_production IS
    'Payloads and objects per organisation per year, by deployment year '
    'where one is known. Evidence for a manufacturing-readiness judgement '
    '(AD-051, AD-058) and not the judgement itself: it says nothing about '
    'whether the organisation built or bought the spacecraft, whether a '
    'year''s output was a constellation deployment or a decade arriving '
    'at once, or whether the line still exists. Objects with no date at '
    'all are excluded, so the totals here can be lower than '
    'organization_activity.objects.';

COMMENT ON COLUMN organization_production.year IS
    'Deployment year where known, launch year otherwise - the same '
    'COALESCE(deployment_date, launch_date) every age query has used '
    'since 008. Without it the 532 ISS-deployed cubesats would all count '
    'as 1998 production.';

-- ── The summary an assessment actually wants ─────────────────────────
--
-- Peak and recent, side by side, because they answer different
-- questions. Peak says what an organisation has ever been able to do;
-- recent says whether it still does. An organisation whose peak is 1971
-- and whose last five years are empty is not a manufacturing base.

CREATE OR REPLACE VIEW organization_production_summary
WITH (security_invoker = true) AS
SELECT
    p.code,
    p.display_name,
    p.name_short,
    max(p.payloads)                                          AS peak_payloads,
    (array_agg(p.year ORDER BY p.payloads DESC, p.year DESC))[1]
                                                             AS peak_year,
    sum(p.payloads) FILTER (
        WHERE p.year >= EXTRACT(YEAR FROM CURRENT_DATE)::int - 4)
                                                             AS payloads_last_5y,
    sum(p.payloads)                                          AS payloads_total,
    count(*) FILTER (WHERE p.payloads > 0)                   AS years_with_output,
    min(p.year)                                              AS first_year,
    max(p.year)                                              AS last_year
FROM organization_production p
GROUP BY p.code, p.display_name, p.name_short;

COMMENT ON VIEW organization_production_summary IS
    'Peak and recent output side by side, because they answer different '
    'questions: peak is what an organisation has ever been able to do, '
    'recent is whether it still does. An organisation peaking in 1971 '
    'with five empty years is not a manufacturing base. Deliberately no '
    'average and no rate - dividing total by span would make a Soviet-era '
    'programme and a modern constellation look alike.';

GRANT SELECT ON organization_production         TO anon;
GRANT SELECT ON organization_production_summary TO anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON organization_production         FROM anon, authenticated;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON organization_production_summary FROM anon, authenticated;

-- Verify:
--
--   -- who is building at rate now
--   SELECT display_name, peak_payloads, peak_year, payloads_last_5y
--     FROM organization_production_summary
--    ORDER BY payloads_last_5y DESC NULLS LAST LIMIT 15;
--
--   -- and who used to: peak long past, nothing recent
--   SELECT display_name, peak_payloads, peak_year, last_year
--     FROM organization_production_summary
--    WHERE COALESCE(payloads_last_5y, 0) = 0 AND peak_payloads >= 10
--    ORDER BY peak_payloads DESC LIMIT 15;
--
--   SELECT * FROM organization_production
--    WHERE code = 'SPXS' ORDER BY year DESC LIMIT 10;
