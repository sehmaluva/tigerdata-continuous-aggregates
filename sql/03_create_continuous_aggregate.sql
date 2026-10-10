-- =============================================================================
-- 03_create_continuous_aggregate.sql
-- Defines the hourly rollup the dashboard reads, then backfills its history.
--
-- A continuous aggregate is a materialized view TimescaleDB keeps up to date:
-- it stores one row per (hour, device) so dashboard queries never have to
-- re-scan the raw readings.
-- =============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS sensor_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 hour', recorded_at) AS bucket,
    device_id,
    AVG(temperature) AS avg_temperature,
    MIN(temperature) AS min_temperature,
    MAX(temperature) AS max_temperature,
    COUNT(*)         AS reading_count
FROM sensor_readings
GROUP BY bucket, device_id
WITH NO DATA;

-- Backfill history. NULL, NULL means "the entire range that exists".
-- refresh_continuous_aggregate() cannot run inside an explicit transaction
-- block; run_sql.sh autocommits, so this is fine there.
CALL refresh_continuous_aggregate('sensor_hourly', NULL, NULL);

-- Verification A: aggregate values vs. values computed directly from raw data
-- for one device and one day. Every agg_* column must equal its raw_* column.
WITH raw AS (
    SELECT
        time_bucket(INTERVAL '1 hour', recorded_at) AS bucket,
        device_id,
        AVG(temperature) AS avg_temperature,
        MIN(temperature) AS min_temperature,
        MAX(temperature) AS max_temperature,
        COUNT(*)         AS reading_count
    FROM sensor_readings
    WHERE device_id = 'device-03'
      AND recorded_at >= TIMESTAMPTZ '2026-09-01 00:00:00+00'
      AND recorded_at <  TIMESTAMPTZ '2026-09-02 00:00:00+00'
    GROUP BY bucket, device_id
)
SELECT
    h.bucket,
    round(h.avg_temperature::numeric, 3)   AS agg_avg,
    round(raw.avg_temperature::numeric, 3) AS raw_avg,
    h.min_temperature                      AS agg_min,
    raw.min_temperature                    AS raw_min,
    h.max_temperature                      AS agg_max,
    raw.max_temperature                    AS raw_max,
    h.reading_count                        AS agg_count,
    raw.reading_count                      AS raw_count
FROM sensor_hourly h
JOIN raw USING (bucket, device_id)
ORDER BY h.bucket;

-- Verification B: shape of the materialised aggregate.
-- Expect 1680 rows (7 days x 24 hours x 10 devices).
SELECT
    count(*)                  AS hourly_rows,
    count(DISTINCT device_id) AS devices,
    min(bucket)               AS first_bucket,
    max(bucket)               AS last_bucket
FROM sensor_hourly;
