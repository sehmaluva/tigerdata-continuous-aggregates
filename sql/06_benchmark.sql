-- =============================================================================
-- 06_benchmark.sql
-- Compares the same hourly rollup computed two ways:
--
--   Query A - from the raw hypertable        (sensor_readings)
--   Query B - from the continuous aggregate  (sensor_hourly)
--
-- Both use the same device + time window and return the same columns, so their
-- plans and timings are comparable. These are EXPLAIN (ANALYZE, BUFFERS)
-- statements: they run the query and report the plan, but change no data.
--
-- Read the plans, not just the milliseconds:
--   * Query A shows Seq/Index Scan + GroupAggregate over many rows.
--   * Query B shows a small scan of far fewer rows.
-- Timings depend on machine, plan, caching and data volume. Do not claim the
-- aggregate is faster unless YOUR measured numbers show it; increase the
-- dataset (see 02_seed_data.sql) if the gap is not visible.
-- =============================================================================

\if :{?device_id}
\else
\set device_id 'device-03'
\endif

\if :{?range_start}
\else
\set range_start '2026-09-01 00:00:00+00'
\endif

\if :{?range_end}
\else
\set range_end '2026-09-08 00:00:00+00'
\endif

\echo ''
\echo '=== Data volume ==='
SELECT
    (SELECT count(*) FROM sensor_readings) AS raw_rows,
    (SELECT count(*) FROM sensor_hourly)   AS aggregate_rows;

\echo ''
\echo '=== Query A: hourly metrics computed from raw sensor_readings ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    time_bucket(INTERVAL '1 hour', recorded_at) AS bucket,
    device_id,
    AVG(temperature) AS avg_temperature,
    MIN(temperature) AS min_temperature,
    MAX(temperature) AS max_temperature,
    COUNT(*)         AS reading_count
FROM sensor_readings
WHERE device_id = :'device_id'
  AND recorded_at >= :'range_start'::timestamptz
  AND recorded_at <  :'range_end'::timestamptz
GROUP BY bucket, device_id
ORDER BY bucket;

\echo ''
\echo '=== Query B: identical metrics read from sensor_hourly ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    bucket,
    device_id,
    avg_temperature,
    min_temperature,
    max_temperature,
    reading_count
FROM sensor_hourly
WHERE device_id = :'device_id'
  AND bucket >= :'range_start'::timestamptz
  AND bucket <  :'range_end'::timestamptz
ORDER BY bucket;

\echo ''
\echo '=== Sanity check: both paths must return the same numbers ==='
WITH raw AS (
    SELECT
        time_bucket(INTERVAL '1 hour', recorded_at) AS bucket,
        device_id,
        AVG(temperature) AS avg_temperature,
        MIN(temperature) AS min_temperature,
        MAX(temperature) AS max_temperature,
        COUNT(*)         AS reading_count
    FROM sensor_readings
    WHERE device_id = :'device_id'
      AND recorded_at >= :'range_start'::timestamptz
      AND recorded_at <  :'range_end'::timestamptz
    GROUP BY bucket, device_id
),
agg AS (
    SELECT bucket, device_id, avg_temperature, min_temperature,
           max_temperature, reading_count
    FROM sensor_hourly
    WHERE device_id = :'device_id'
      AND bucket >= :'range_start'::timestamptz
      AND bucket <  :'range_end'::timestamptz
)
SELECT
    count(*)                                                        AS buckets,
    -- AVG is compared with a tolerance: the aggregate stores a partial
    -- (sum, count) and can differ from a fresh AVG in the last float bit.
    bool_and(abs(raw.avg_temperature - agg.avg_temperature) < 1e-9) AS avg_matches,
    bool_and(raw.min_temperature = agg.min_temperature)            AS min_matches,
    bool_and(raw.max_temperature = agg.max_temperature)            AS max_matches,
    bool_and(raw.reading_count   = agg.reading_count)              AS count_matches
FROM raw JOIN agg USING (bucket, device_id);
