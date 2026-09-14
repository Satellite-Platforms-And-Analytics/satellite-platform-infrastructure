-- 013_organization_activity.sql
--
-- What each organisation has actually flown.
--
-- WHY A VIEW AND NOT A QUERY IN THE APPLICATION
-- =============================================
-- PostgREST cannot express GROUP BY, so an aggregate reached through the
-- anon key has to exist in the database or be computed in the browser
-- from every row. Pulling 17,487 satellites to count them client-side
-- would move ~200 KB per visitor to produce forty numbers.
--
-- It also puts the definition in one place. "How many objects has this
-- organisation flown" is about to appear on a page, in the readiness
-- framework as manufacturing evidence, and in whatever asks the question
-- next. Three implementations of one count is how three answers happen.
--
-- WHAT IT IS EVIDENCE FOR
-- =======================
-- AD-051 and AD-058: the catalogue is the strongest manufacturing-
-- readiness evidence available, and it needs no new source. A bus that
-- flew 2,000 units has a manufacturing readiness no announcement can
-- argue with; one that flew once in six years does not.
--
-- `payloads` is separated from `objects` deliberately. A rocket body is
-- something an organisation launched, not something it built to operate,
-- and counting the two together would credit a launch provider with
-- manufacturing it never did. The distinction only became possible on
-- 2026-09-14, when 011 gave satellites an exact operator code and f8ecdeb
-- stopped rocket-stage records being attributed to payloads.
--
-- `active_years` is the span, not the count of distinct years: an
-- organisation that flew in 1962 and 2024 gets 63, and the honest reading
-- is "has been flying that long", not "flew every year". A rate is
-- deliberately NOT computed here - objects/active_years would turn a
-- Soviet-era programme and a modern constellation into the same number,
-- and this view's job is to supply the terms, not to divide them.

CREATE OR REPLACE VIEW organization_activity
WITH (security_invoker = true) AS
SELECT
    o.code,
    o.display_name,
    o.name_short,
    o.org_type,
    o.state_code,
    o.latitude,
    o.longitude,
    o.parent_code,
    count(s.norad_id)                                          AS objects,
    count(*) FILTER (WHERE s.object_type = 'PAYLOAD')           AS payloads,
    min(COALESCE(s.deployment_date, s.launch_date))             AS first_flight,
    max(COALESCE(s.deployment_date, s.launch_date))             AS last_flight,
    -- The span in years between first and last, NULL when either is
    -- unknown. See the header: this is not a rate and must not be read
    -- as one.
    CASE
        WHEN min(COALESCE(s.deployment_date, s.launch_date)) IS NULL
          OR max(COALESCE(s.deployment_date, s.launch_date)) IS NULL
        THEN NULL
        ELSE EXTRACT(YEAR FROM age(
                 max(COALESCE(s.deployment_date, s.launch_date)),
                 min(COALESCE(s.deployment_date, s.launch_date))))::int
    END                                                         AS active_years
FROM organizations o
JOIN satellites s ON s.operator_code = o.code
GROUP BY o.code, o.display_name, o.name_short, o.org_type,
         o.state_code, o.latitude, o.longitude, o.parent_code;

COMMENT ON VIEW organization_activity IS
    'Organisations that operate at least one object this catalogue '
    'tracks, with what they have flown. An INNER join: an organisation '
    'with nothing in the catalogue does not appear, because "0 objects" '
    'and "we do not track any of their objects" are different statements '
    'and this view can only honestly make the second. The catalogue holds '
    '~17,500 of ~70,000 GCAT objects.';

COMMENT ON COLUMN organization_activity.payloads IS
    'Objects of type PAYLOAD only. Separated from `objects` because a '
    'rocket body is something an organisation launched rather than built '
    'to operate, and counting them together credits a launch provider '
    'with manufacturing it never did.';

COMMENT ON COLUMN organization_activity.active_years IS
    'Years between first and last flight. A SPAN, not a count of years '
    'flown and not a rate: an organisation that flew in 1962 and 2024 '
    'reads 63. Dividing objects by this would make a Soviet-era programme '
    'and a modern constellation look alike.';

-- ── Access ───────────────────────────────────────────────────────────
--
-- security_invoker means the caller needs SELECT on `organizations` and
-- `satellites` as well; both are public-read, so anon can use this.

GRANT SELECT ON organization_activity TO anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON organization_activity FROM anon, authenticated;

-- Verify:
--
--   SELECT display_name, objects, payloads, first_flight, last_flight
--     FROM organization_activity ORDER BY objects DESC LIMIT 15;
--
--   -- organisations in the catalogue at all
--   SELECT count(*) FROM organization_activity;
--
--   -- the manufacturing-evidence shape (AD-058): who flies at rate
--   SELECT display_name, payloads, active_years
--     FROM organization_activity
--    WHERE payloads > 50 ORDER BY payloads DESC LIMIT 20;
