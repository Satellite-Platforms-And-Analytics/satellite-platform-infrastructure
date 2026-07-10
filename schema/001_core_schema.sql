-- ============================================================
-- Satellite Platforms And Analytics
-- Phase 1 Core Schema
-- Run in: Supabase SQL Editor
-- ============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- COUNTRIES (reference table)
-- ============================================================
CREATE TABLE IF NOT EXISTS countries (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(3) UNIQUE NOT NULL,  -- ISO 3166-1 alpha-3
    code2           VARCHAR(2),                  -- ISO 3166-1 alpha-2
    name            TEXT NOT NULL,
    region          TEXT,                        -- North America, Europe, Asia, etc.
    space_agency    TEXT,                        -- NASA, ESA, JAXA, etc.
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Seed key countries
INSERT INTO countries (code, code2, name, region, space_agency) VALUES
    ('USA', 'US', 'United States', 'North America', 'NASA/USSF'),
    ('RUS', 'RU', 'Russia', 'Europe/Asia', 'Roscosmos'),
    ('CHN', 'CN', 'China', 'Asia', 'CNSA'),
    ('GBR', 'GB', 'United Kingdom', 'Europe', 'UKSA'),
    ('FRA', 'FR', 'France', 'Europe', 'CNES'),
    ('DEU', 'DE', 'Germany', 'Europe', 'DLR'),
    ('JPN', 'JP', 'Japan', 'Asia', 'JAXA'),
    ('IND', 'IN', 'India', 'Asia', 'ISRO'),
    ('ISR', 'IL', 'Israel', 'Middle East', 'ISA'),
    ('CAN', 'CA', 'Canada', 'North America', 'CSA'),
    ('AUS', 'AU', 'Australia', 'Oceania', 'ASA'),
    ('BRA', 'BR', 'Brazil', 'South America', 'AEB'),
    ('ITA', 'IT', 'Italy', 'Europe', 'ASI'),
    ('ESP', 'ES', 'Spain', 'Europe', 'AEE'),
    ('NLD', 'NL', 'Netherlands', 'Europe', 'NSO'),
    ('KOR', 'KR', 'South Korea', 'Asia', 'KARI'),
    ('ARE', 'AE', 'UAE', 'Middle East', 'UAESA'),
    ('NOR', 'NO', 'Norway', 'Europe', NULL),
    ('SWE', 'SE', 'Sweden', 'Europe', NULL),
    ('UKR', 'UA', 'Ukraine', 'Europe', 'SSAU'),
    ('INT', 'XZ', 'International/Multinational', 'International', NULL)
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- SATELLITES (core catalog)
-- ============================================================
CREATE TABLE IF NOT EXISTS satellites (
    id                  SERIAL PRIMARY KEY,
    norad_id            INTEGER UNIQUE NOT NULL,    -- NORAD catalog number
    name                TEXT NOT NULL,              -- common name
    intl_designator     TEXT,                       -- YYYY-NNNX format
    country_code        VARCHAR(3) REFERENCES countries(code),
    operator            TEXT,                       -- operating organization
    manufacturer        TEXT,                       -- who built it
    purpose             TEXT,                       -- communications, imaging, navigation, etc.
    orbit_regime        VARCHAR(10),                -- LEO, MEO, GEO, HEO, SSO
    orbit_type          TEXT,                       -- more specific: polar, sun-sync, etc.
    launch_date         DATE,
    launch_site         TEXT,
    launch_vehicle      TEXT,
    expected_lifetime_yr REAL,
    mass_kg             REAL,
    perigee_km          REAL,
    apogee_km           REAL,
    inclination_deg     REAL,
    period_min          REAL,
    rcs_size            VARCHAR(10),                -- SMALL, MEDIUM, LARGE
    status              VARCHAR(20) DEFAULT 'ACTIVE', -- ACTIVE, INACTIVE, DECAYED, UNKNOWN
    object_type         VARCHAR(20),                -- PAYLOAD, ROCKET BODY, DEBRIS, UNKNOWN
    -- TLE data
    tle_line1           TEXT,
    tle_line2           TEXT,
    tle_epoch           TEXT,
    mean_motion         REAL,
    eccentricity        REAL,
    -- Metadata
    source              TEXT DEFAULT 'spacetrack',
    last_updated        TIMESTAMPTZ DEFAULT NOW(),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_satellites_norad    ON satellites(norad_id);
CREATE INDEX IF NOT EXISTS idx_satellites_country  ON satellites(country_code);
CREATE INDEX IF NOT EXISTS idx_satellites_regime   ON satellites(orbit_regime);
CREATE INDEX IF NOT EXISTS idx_satellites_status   ON satellites(status);
CREATE INDEX IF NOT EXISTS idx_satellites_type     ON satellites(object_type);
CREATE INDEX IF NOT EXISTS idx_satellites_name     ON satellites USING gin(to_tsvector('english', name));

-- ============================================================
-- TLE HISTORY
-- ============================================================
CREATE TABLE IF NOT EXISTS tle_history (
    id          BIGSERIAL PRIMARY KEY,
    norad_id    INTEGER NOT NULL REFERENCES satellites(norad_id) ON DELETE CASCADE,
    line1       TEXT NOT NULL,
    line2       TEXT NOT NULL,
    epoch       TIMESTAMPTZ NOT NULL,
    source      TEXT DEFAULT 'spacetrack',
    fetched_at  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (norad_id, epoch)
);

CREATE INDEX IF NOT EXISTS idx_tle_history_norad   ON tle_history(norad_id);
CREATE INDEX IF NOT EXISTS idx_tle_history_epoch   ON tle_history(epoch DESC);

-- ============================================================
-- ORBITAL POSITIONS (time series — pruned to 48 hours)
-- ============================================================
CREATE TABLE IF NOT EXISTS orbital_positions (
    id          BIGSERIAL PRIMARY KEY,
    norad_id    INTEGER NOT NULL REFERENCES satellites(norad_id) ON DELETE CASCADE,
    timestamp   TIMESTAMPTZ NOT NULL,
    latitude    REAL NOT NULL,
    longitude   REAL NOT NULL,
    altitude_km REAL NOT NULL,
    velocity_km_s REAL,
    azimuth_deg REAL,
    elevation_deg REAL,
    range_km    REAL,
    UNIQUE (norad_id, timestamp)
);

CREATE INDEX IF NOT EXISTS idx_positions_norad     ON orbital_positions(norad_id);
CREATE INDEX IF NOT EXISTS idx_positions_timestamp ON orbital_positions(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_positions_location  ON orbital_positions(latitude, longitude);

-- ============================================================
-- SENSORS (radar/optical sensor profiles)
-- ============================================================
CREATE TABLE IF NOT EXISTS sensors (
    id                      SERIAL PRIMARY KEY,
    name                    TEXT NOT NULL,
    short_name              TEXT UNIQUE NOT NULL,
    sensor_type             TEXT,           -- radar, optical, etc.
    latitude                REAL NOT NULL,
    longitude               REAL NOT NULL,
    elevation_m             REAL,
    min_elevation_deg       REAL DEFAULT 0,
    max_elevation_deg       REAL DEFAULT 90,
    boresight_azimuth_deg   REAL,
    azimuth_half_width_deg  REAL,
    apply_field_of_regard   BOOLEAN DEFAULT TRUE,
    country_code            VARCHAR(3) REFERENCES countries(code),
    notes                   TEXT,
    created_at              TIMESTAMPTZ DEFAULT NOW()
);

-- Seed from Satellite Visibility Tool sensor profiles
INSERT INTO sensors (name, short_name, sensor_type, latitude, longitude,
    elevation_m, min_elevation_deg, max_elevation_deg,
    boresight_azimuth_deg, azimuth_half_width_deg,
    apply_field_of_regard, country_code) VALUES
    ('AN/FPS-85 Eglin AFB', 'FPS85', 'radar',
     30.57, -86.21, 40.0, 3.0, 90.0, 180.0, 60.0, TRUE, 'USA'),
    ('GEODSS Socorro', 'GEODSS_SOC', 'optical',
     33.99, -106.66, 1829.0, 10.0, 90.0, 180.0, 90.0, FALSE, 'USA'),
    ('Millstone Hill', 'MILLSTONE', 'radar',
     42.62, -71.49, 130.0, 5.0, 90.0, 180.0, 90.0, FALSE, 'USA')
ON CONFLICT (short_name) DO NOTHING;

-- ============================================================
-- VISIBILITY WINDOWS
-- ============================================================
CREATE TABLE IF NOT EXISTS visibility_windows (
    id              BIGSERIAL PRIMARY KEY,
    norad_id        INTEGER NOT NULL REFERENCES satellites(norad_id) ON DELETE CASCADE,
    sensor_id       INTEGER NOT NULL REFERENCES sensors(id),
    analysis_date   DATE NOT NULL,
    window_start    TIMESTAMPTZ NOT NULL,
    window_end      TIMESTAMPTZ NOT NULL,
    hour_bin        INTEGER,                -- hour of day (0-23 UTC)
    max_elevation   REAL,
    max_azimuth     REAL,
    min_range_km    REAL,
    orbit_regime    VARCHAR(10),
    confidence_score REAL,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (norad_id, sensor_id, window_start)
);

CREATE INDEX IF NOT EXISTS idx_visibility_norad    ON visibility_windows(norad_id);
CREATE INDEX IF NOT EXISTS idx_visibility_sensor   ON visibility_windows(sensor_id);
CREATE INDEX IF NOT EXISTS idx_visibility_date     ON visibility_windows(analysis_date DESC);
CREATE INDEX IF NOT EXISTS idx_visibility_window   ON visibility_windows(window_start, window_end);

-- ============================================================
-- IMAGERY SCENES (from ingest.py Sentinel-2 pipeline)
-- ============================================================
CREATE TABLE IF NOT EXISTS imagery_scenes (
    id              SERIAL PRIMARY KEY,
    scene_id        TEXT UNIQUE NOT NULL,       -- e.g. S2C_20260621_T13SED
    filename        TEXT NOT NULL,
    sensor          TEXT NOT NULL,              -- Sentinel-2C, Landsat-8, etc.
    satellite       TEXT,                       -- S2A, S2B, S2C, LC08, etc.
    date_acquired   DATE NOT NULL,
    date_ingested   TIMESTAMPTZ DEFAULT NOW(),
    tile            TEXT,                       -- e.g. T13SED
    crs             TEXT,                       -- e.g. EPSG:32613
    bounds_west     REAL,
    bounds_east     REAL,
    bounds_south    REAL,
    bounds_north    REAL,
    cloud_cover_pct REAL,
    bands           JSONB,                      -- ["B02","B03","B04","B08"]
    resolution_m    REAL,
    shape_rows      INTEGER,
    shape_cols      INTEGER,
    file_size_mb    REAL,
    raw_path        TEXT,
    processed_path  TEXT,
    status          TEXT DEFAULT 'processed',
    processing_log  TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_imagery_date     ON imagery_scenes(date_acquired DESC);
CREATE INDEX IF NOT EXISTS idx_imagery_tile     ON imagery_scenes(tile);
CREATE INDEX IF NOT EXISTS idx_imagery_sensor   ON imagery_scenes(sensor);
CREATE INDEX IF NOT EXISTS idx_imagery_bounds   ON imagery_scenes(bounds_west, bounds_east, bounds_south, bounds_north);

-- ============================================================
-- INGESTION LOG (pipeline audit)
-- ============================================================
CREATE TABLE IF NOT EXISTS ingestion_log (
    id              BIGSERIAL PRIMARY KEY,
    run_id          UUID DEFAULT uuid_generate_v4(),
    pipeline        TEXT NOT NULL,      -- tle_fetch, visibility, imagery, etc.
    step            TEXT NOT NULL,      -- validate, convert, index, archive
    status          TEXT NOT NULL,      -- success, failed, skipped, partial
    message         TEXT,
    records_processed INTEGER DEFAULT 0,
    duration_s      REAL,
    source          TEXT,               -- celestrak, spacetrack, copernicus, etc.
    github_run_id   TEXT,               -- GitHub Actions run ID for traceability
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_log_pipeline    ON ingestion_log(pipeline);
CREATE INDEX IF NOT EXISTS idx_log_status      ON ingestion_log(status);
CREATE INDEX IF NOT EXISTS idx_log_created     ON ingestion_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_log_run_id      ON ingestion_log(run_id);

-- ============================================================
-- ROW LEVEL SECURITY
-- Enable RLS on all tables
-- Public read access for core catalog tables
-- Write access only for service role (ingestion pipeline)
-- ============================================================

ALTER TABLE countries           ENABLE ROW LEVEL SECURITY;
ALTER TABLE satellites          ENABLE ROW LEVEL SECURITY;
ALTER TABLE tle_history         ENABLE ROW LEVEL SECURITY;
ALTER TABLE orbital_positions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sensors             ENABLE ROW LEVEL SECURITY;
ALTER TABLE visibility_windows  ENABLE ROW LEVEL SECURITY;
ALTER TABLE imagery_scenes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingestion_log       ENABLE ROW LEVEL SECURITY;

-- Public read policies (anon key can read these)
CREATE POLICY "Public read countries"
    ON countries FOR SELECT USING (true);

CREATE POLICY "Public read satellites"
    ON satellites FOR SELECT USING (true);

CREATE POLICY "Public read orbital_positions"
    ON orbital_positions FOR SELECT USING (true);

CREATE POLICY "Public read visibility_windows"
    ON visibility_windows FOR SELECT USING (true);

CREATE POLICY "Public read sensors"
    ON sensors FOR SELECT USING (true);

CREATE POLICY "Public read imagery_scenes"
    ON imagery_scenes FOR SELECT USING (true);

-- Service role can do everything (no policy needed — bypasses RLS)
-- The ingestion pipeline uses SUPABASE_SERVICE_KEY which bypasses RLS

-- ============================================================
-- CLEANUP FUNCTION (prune old orbital positions)
-- Run via pg_cron or GitHub Actions daily
-- ============================================================
CREATE OR REPLACE FUNCTION prune_old_positions()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM orbital_positions
    WHERE timestamp < NOW() - INTERVAL '48 hours';
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- USEFUL VIEWS
-- ============================================================

-- Active satellites summary
CREATE OR REPLACE VIEW active_satellites AS
SELECT
    s.norad_id,
    s.name,
    s.country_code,
    c.name AS country_name,
    s.operator,
    s.orbit_regime,
    s.purpose,
    s.launch_date,
    s.object_type,
    s.tle_epoch,
    p.latitude,
    p.longitude,
    p.altitude_km,
    p.timestamp AS position_timestamp
FROM satellites s
LEFT JOIN countries c ON s.country_code = c.code
LEFT JOIN LATERAL (
    SELECT latitude, longitude, altitude_km, timestamp
    FROM orbital_positions op
    WHERE op.norad_id = s.norad_id
    ORDER BY timestamp DESC
    LIMIT 1
) p ON true
WHERE s.status = 'ACTIVE'
  AND s.object_type = 'PAYLOAD';

-- Satellite counts by country
CREATE OR REPLACE VIEW satellites_by_country AS
SELECT
    c.name AS country,
    c.code AS country_code,
    COUNT(*) FILTER (WHERE s.object_type = 'PAYLOAD') AS active_payloads,
    COUNT(*) FILTER (WHERE s.orbit_regime = 'LEO') AS leo_count,
    COUNT(*) FILTER (WHERE s.orbit_regime = 'MEO') AS meo_count,
    COUNT(*) FILTER (WHERE s.orbit_regime = 'GEO') AS geo_count
FROM satellites s
JOIN countries c ON s.country_code = c.code
WHERE s.status = 'ACTIVE'
GROUP BY c.name, c.code
ORDER BY active_payloads DESC;

-- Recent ingestion status
CREATE OR REPLACE VIEW ingestion_status AS
SELECT
    pipeline,
    status,
    message,
    records_processed,
    duration_s,
    created_at
FROM ingestion_log
ORDER BY created_at DESC
LIMIT 50;

-- ============================================================
-- SCHEMA COMPLETE
-- Next: Run 002_phase2_catalog.sql for industry intelligence tables
-- ============================================================
