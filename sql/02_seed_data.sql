-- =============================================================================
-- 02_seed_data.sql
-- Deterministic sample data for sensor_readings.
--
-- Default volume: 10 devices x 7 days at 5-minute resolution = 20,160 rows.
--
--   * Deterministic - values depend only on the timestamp and device index, so
--     every run produces exactly the same data and benchmarks are comparable.
--   * Repeat-safe   - ON CONFLICT (device_id, recorded_at) DO NOTHING means
--     re-running this file never duplicates a reading.
--   * Realistic     - a daily cycle + a weekly drift + a per-device offset +
--     a short-term wiggle, so hourly AVG/MIN/MAX are all meaningful.
-- =============================================================================

-- Want a clean re-seed after changing the range below? Uncomment:
-- TRUNCATE sensor_readings;

INSERT INTO sensor_readings (recorded_at, device_id, temperature)
SELECT
    ts                                                  AS recorded_at,
    'device-' || lpad(dev::text, 2, '0')               AS device_id,
    round((
          20.0                                                        -- baseline (C)
        + 6.0 * sin(2 * pi() * (extract(epoch FROM ts) / 86400.0))    -- daily cycle
        + 1.5 * sin(2 * pi() * (extract(epoch FROM ts) / 604800.0))   -- weekly drift
        + 0.4 * (dev - 5.5)                                          -- per-device offset
        + 0.8 * sin(extract(epoch FROM ts) / 900.0 + dev)            -- short-term wiggle
    )::numeric, 2)                                      AS temperature
FROM generate_series(
        TIMESTAMPTZ '2026-09-01 00:00:00+00',
        TIMESTAMPTZ '2026-09-07 23:55:00+00',
        INTERVAL '5 minutes'
     ) AS ts
CROSS JOIN generate_series(1, 10) AS dev
ON CONFLICT (device_id, recorded_at) DO NOTHING;

-- Sanity check: expect 20160 readings, 10 devices, temps roughly 10-30 C.
SELECT
    count(*)                            AS readings,
    count(DISTINCT device_id)           AS devices,
    min(recorded_at)                    AS first_reading,
    max(recorded_at)                    AS last_reading,
    round(min(temperature)::numeric, 2) AS min_temp,
    round(max(temperature)::numeric, 2) AS max_temp
FROM sensor_readings;

-- -----------------------------------------------------------------------------
-- SCALING UP FOR BENCHMARKS
-- -----------------------------------------------------------------------------
-- 20k rows is small; on a fast machine the raw table can still be quick, which
-- can make the benchmark inconclusive. To force a measurable gap, make the
-- series denser by changing ONLY the INTERVAL '5 minutes' above:
--
--   INTERVAL '1 minute'  ->  ~100,000 rows
--   INTERVAL '30 seconds'->  ~200,000 rows
--   INTERVAL '5 seconds' -> ~1,000,000 rows
--   INTERVAL '1 second'  -> ~6,000,000 rows
--
-- Then re-run 03 and 04 so the aggregate and its refresh policy cover the new
-- range, and re-run 06 to benchmark again.
-- -----------------------------------------------------------------------------
