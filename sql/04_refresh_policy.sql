-- =============================================================================
-- 04_refresh_policy.sql
-- Schedules automatic background refreshes of sensor_hourly.
--
-- add_continuous_aggregate_policy() arguments (TimescaleDB 2.x, Tiger Cloud):
--
--   start_offset      how far back each refresh re-scans for new or late data.
--   end_offset        how close to "now" the refresh may write. Buckets newer
--                     than now() - end_offset are deliberately skipped.
--   schedule_interval how often the background job runs.
--
-- With the values below the job runs every 30 minutes, recomputes the last
-- 7 days of history, and leaves the most recent 1 hour untouched.
--
-- Why exclude the latest hour? The current hour is still being written to, so
-- its bucket is incomplete. Skipping it avoids rewriting a half-filled bucket
-- on every tick. Consequence: the newest hour is NOT in the scheduled
-- aggregate until it is older than 1 hour. Query that hour from raw data, or
-- refresh it on demand (see the CALL at the bottom) before a demo.
-- =============================================================================

SELECT add_continuous_aggregate_policy(
    'sensor_hourly',
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes',
    if_not_exists     => TRUE
);

-- Confirm the refresh job was registered. config holds the offsets as JSON.
SELECT
    job_id,
    schedule_interval,
    config->>'start_offset' AS start_offset,
    config->>'end_offset'   AS end_offset
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_refresh_continuous_aggregate'
  AND hypertable_name = 'sensor_hourly';

-- Confirm the view is a continuous aggregate and whether it is real-time.
SELECT view_name, materialized_only
FROM timescaledb_information.continuous_aggregates
WHERE view_name = 'sensor_hourly';

-- Change the schedule later without recreating the policy, e.g. every 5 min:
--   SELECT alter_job(
--       (SELECT job_id FROM timescaledb_information.jobs
--         WHERE proc_name = 'policy_refresh_continuous_aggregate'
--           AND hypertable_name = 'sensor_hourly'),
--       schedule_interval => INTERVAL '5 minutes');

-- On-demand refresh of the newest hours (safe, additive; good before a demo).
-- CALL refresh_continuous_aggregate('sensor_hourly', now() - INTERVAL '2 hours', NULL);
