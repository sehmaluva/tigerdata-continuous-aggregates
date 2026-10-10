-- =============================================================================
-- 05_dashboard_query.sql
-- The dashboard read path.
--
-- This is the query a dashboard would run for a selected device and time
-- range. It reads ONLY the continuous aggregate sensor_hourly - it never
-- touches sensor_readings, so the hourly AVG/MIN/MAX/COUNT work was already
-- done by TimescaleDB at write/refresh time.
--
-- Parameters (defaults are set below; override from the shell, e.g.):
--   psql "$DATABASE_URL" -v device_id=device-07 \
--        -v range_start='2026-09-02 00:00:00+00' -f sql/05_dashboard_query.sql
--
--   device_id    which sensor to chart
--   range_start  inclusive start of the window
--   range_end    exclusive end of the window
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

SELECT
    bucket,
    device_id,
    round(avg_temperature::numeric, 2) AS avg_temperature,
    round(min_temperature::numeric, 2) AS min_temperature,
    round(max_temperature::numeric, 2) AS max_temperature,
    reading_count
FROM sensor_hourly
WHERE device_id = :'device_id'
  AND bucket >= :'range_start'::timestamptz
  AND bucket <  :'range_end'::timestamptz
ORDER BY bucket;
