-- =============================================================================
-- 01_create_hypertable.sql
-- Target: Tiger Cloud (hosted TimescaleDB)
--
-- Creates the raw time-series table and converts it into a TimescaleDB
-- hypertable partitioned on the time column `recorded_at`.
--
-- Safe to run more than once: CREATE ... IF NOT EXISTS and
-- create_hypertable(..., if_not_exists => TRUE) are both idempotent.
-- =============================================================================

-- Tiger Cloud always ships TimescaleDB pre-installed. This line keeps the
-- script portable to a self-managed instance where the extension must be
-- enabled first. On Tiger Cloud it is a harmless no-op.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS sensor_readings (
    recorded_at TIMESTAMPTZ      NOT NULL,
    device_id   TEXT             NOT NULL,
    temperature DOUBLE PRECISION NOT NULL,
    -- A hypertable primary key must contain the time partitioning column.
    -- The same constraint is what lets the seed script use ON CONFLICT DO
    -- NOTHING to stay repeat-safe.
    CONSTRAINT sensor_readings_pkey PRIMARY KEY (device_id, recorded_at)
);

-- Convert the plain table into a hypertable.
--
--   by_range('recorded_at', INTERVAL '1 day')  -> modern dimension builder
--   INTERVAL '1 day'                            -> chunk size (one chunk/day)
--
-- `by_range` requires TimescaleDB 2.13+ (Tiger Cloud is newer). On an older
-- release use the legacy positional form instead:
--   SELECT create_hypertable('sensor_readings', 'recorded_at',
--                            if_not_exists => TRUE);
SELECT create_hypertable(
    'sensor_readings',
    by_range('recorded_at', INTERVAL '1 day'),
    if_not_exists => TRUE
);

-- Confirm the hypertable exists and how it is partitioned.
SELECT
    hypertable_schema,
    hypertable_name,
    num_dimensions,
    num_chunks
FROM timescaledb_information.hypertables
WHERE hypertable_name = 'sensor_readings';
