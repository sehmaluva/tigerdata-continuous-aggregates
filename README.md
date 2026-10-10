# Accelerate Dashboards with Continuous Aggregates

A small, standalone, SQL-first project showing how **TimescaleDB continuous
aggregates** precompute time-series metrics so dashboard queries do far less
work. Built for the Global Hack Week: Hacktoberfest open-source challenge
_Accelerate Dashboards with Continuous Aggregates_, running against
**Tiger Cloud** (hosted TimescaleDB).

There is no app, no API and no frontend: the whole project is six ordered SQL
scripts plus a shell runner, so it is easy to read, reproduce and review.

## Objective

Given raw sensor readings written every few minutes, a dashboard usually wants
hourly averages, minimums, maximums and counts. Computing those on every page
load means scanning the raw table each time. This project instead:

1. stores the raw readings in a TimescaleDB **hypertable**;
2. defines a **continuous aggregate** `sensor_hourly` that maintains the hourly
   rollup automatically;
3. serves the dashboard from that rollup; and
4. **measures** both paths with `EXPLAIN (ANALYZE, BUFFERS)` so any speed
   claim is backed by numbers you produced yourself.

## How it works

```
                       writes
  sensors  ─────────────────────────▶  sensor_readings  (hypertable, 1-day chunks)
                                              │
                                              │  background refresh job
                                              │  (every 30 min, last 7 days,
                                              │   excluding the newest hour)
                                              ▼
                                        sensor_hourly  (continuous aggregate)
                                              │
                                              │  reads
                                              ▼
                                       dashboard query
                                  (hourly avg / min / max / count)
```

A **hypertable** is a normal-looking table that TimescaleDB transparently
partitions into time chunks. A **continuous aggregate** is a materialized view
defined over a hypertable, plus a background job that keeps it current. The
aggregate stores one row per `(hour, device)` instead of one row per reading,
so the dashboard reads a much smaller relation and skips the aggregation work
entirely.

## Repository layout

```
tigerdata-continuous-aggregates/
├── README.md                          <- you are here
├── .gitignore                         <- keeps .env and local junk out of git
├── .env.example                       <- placeholder DATABASE_URL (safe to commit)
├── run_sql.sh                         <- loads .env, runs sql/*.sql in order
├── sql/
│   ├── 01_create_hypertable.sql       <- table + hypertable
│   ├── 02_seed_data.sql               <- deterministic sample data
│   ├── 03_create_continuous_aggregate.sql
│   ├── 04_refresh_policy.sql          <- automatic refresh
│   ├── 05_dashboard_query.sql         <- the read path
│   └── 06_benchmark.sql               <- EXPLAIN (ANALYZE, BUFFERS) A vs B
└── screenshots/
    └── README.md                      <- what to screenshot for the submission
```

## Prerequisites

- A free **Tiger Cloud** account and a running TimescaleDB service
  (<https://console.cloud.timescale.com/>). The free tier is enough.
- The **PostgreSQL client `psql`, version 15 or newer**, available on your
  `PATH`. Check with `psql --version`.
  - macOS: `brew install libpq` (then add its `bin` to `PATH`) or
    `brew install postgresql`.
  - Debian/Ubuntu: `sudo apt install postgresql-client`.
- `bash` (macOS/Linux; on Windows use WSL or Git Bash).

No Python, Node, Docker or framework is required.

## Tiger Cloud setup

1. Sign in at <https://console.cloud.timescale.com/> and create a service
   (any region close to you; the free plan is fine).
2. Wait until the service shows as **Running**.
3. Open the service, click **Connect**, and copy the **PostgreSQL connection
   string** (the `psql`/URI form). It looks like:

   ```
   postgres://tsdbadmin:<PASSWORD>@<HOST>:<PORT>/<DBNAME>?sslmode=require
   ```

   Treat this string as a secret - it contains your password.

## Connect: environment setup

This project reads the connection string from a local `.env` file. `.env` is
git-ignored; only the placeholder `.env.example` is committed.

```bash
cp .env.example .env
$EDITOR .env            # paste your real Tiger Cloud URL after DATABASE_URL=
chmod 600 .env          # optional: keep it readable only by you
```

`.env` should contain exactly one line:

```dotenv
DATABASE_URL=postgres://tsdbadmin:<PASSWORD>@<HOST>:<PORT>/<DBNAME>?sslmode=require
```

`run_sql.sh` parses this file as `KEY=VALUE` only (it never executes it), fails
with a clear error if `DATABASE_URL` is missing, forces `PGSSLMODE=require`,
and never prints the URL. You can also skip `.env` and export the variable
directly:

```bash
export DATABASE_URL='postgres://...sslmode=require'
./run_sql.sh
```

Verify your connection before running anything:

```bash
psql "$DATABASE_URL" -c '\conninfo'
```

## Run the SQL, in order

The runner executes every file in `sql/` in numeric order inside a single
`psql` session:

```bash
./run_sql.sh                # runs 01 -> 06
./run_sql.sh --reset        # drop the view + table first, then run 01 -> 06
./run_sql.sh 02 03          # re-run only the seed and the aggregate
./run_sql.sh --dry-run      # show the file list without connecting
```

Or run the files yourself, in order:

```bash
export PGSSLMODE=require
for f in sql/*.sql; do
  echo "==> $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -f "$f" || break
done
```

**Order matters.** `02` needs the table from `01`; `03` needs the data from
`02`; `04` needs the view from `03`; `05` and `06` need everything before them.
Running the dashboard or benchmark query before the aggregate exists will fail.

### What each script does

| File | Purpose |
| --- | --- |
| `01_create_hypertable.sql` | Creates `sensor_readings` and converts it to a hypertable (1-day chunks). Safe to re-run. |
| `02_seed_data.sql` | Inserts ~20,160 deterministic readings (10 devices x 7 days x 5 min). Repeat-safe via `ON CONFLICT DO NOTHING`. |
| `03_create_continuous_aggregate.sql` | Defines `sensor_hourly` and backfills history, then verifies it against the raw data. |
| `04_refresh_policy.sql` | Adds the automatic refresh policy and prints it back for confirmation. |
| `05_dashboard_query.sql` | The dashboard read path: reads `sensor_hourly` only. |
| `06_benchmark.sql` | `EXPLAIN (ANALYZE, BUFFERS)` for the raw path (A) and the aggregate path (B), plus an equality check. |

## Schema

`sensor_readings` - one row per reading:

| Column | Type | Notes |
| --- | --- | --- |
| `recorded_at` | `TIMESTAMPTZ NOT NULL` | time dimension (hypertable partition key) |
| `device_id` | `TEXT NOT NULL` | which sensor |
| `temperature` | `DOUBLE PRECISION NOT NULL` | degrees Celsius |

Primary key `(device_id, recorded_at)`. A hypertable's unique constraints must
include the time column; this one does, and it is also what makes seeding
idempotent.

`sensor_hourly` - the continuous aggregate, one row per `(hour, device)`:

| Column | Meaning |
| --- | --- |
| `bucket` | `time_bucket(INTERVAL '1 hour', recorded_at)` |
| `device_id` | grouped device |
| `avg_temperature` | hourly average (C) |
| `min_temperature` | hourly minimum (C) |
| `max_temperature` | hourly maximum (C) |
| `reading_count` | readings that contributed to the bucket |

## Sample data

`02_seed_data.sql` builds readings with `generate_series` and a deterministic
formula (a daily cycle + a weekly drift + a per-device offset + a short-term
wiggle), so the same run always produces the same values and benchmark numbers
stay comparable. Default volume:

```
10 devices x 7 days x 288 readings/day = 20,160 rows
```

Re-running is safe: rows conflict on `(device_id, recorded_at)` and are
skipped, so nothing is duplicated. To re-seed cleanly after changing the range,
uncomment the `TRUNCATE sensor_readings;` line at the top of the file (or run
`./run_sql.sh --reset`).

**Generating a larger dataset for performance testing.** 20k rows is small; on
a fast machine the raw query can still be quick, which can make the benchmark
inconclusive. Make the series denser by changing only the interval in
`generate_series(...)` in `02_seed_data.sql`:

| Interval | Approx. rows |
| --- | --- |
| `INTERVAL '5 minutes'` (default) | ~20,000 |
| `INTERVAL '1 minute'` | ~100,000 |
| `INTERVAL '30 seconds'` | ~200,000 |
| `INTERVAL '5 seconds'` | ~1,000,000 |
| `INTERVAL '1 second'` | ~6,000,000 |

Adding more devices multiplies the count further. After enlarging the dataset,
re-run `03` and `04` so the aggregate and refresh policy cover the new range,
then re-run `06`.

## The continuous aggregate

```sql
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

CALL refresh_continuous_aggregate('sensor_hourly', NULL, NULL);  -- backfill
```

`WITH NO DATA` creates the view empty; the `CALL` then materialises all existing
history. Expect **1,680 rows** (7 days x 24 hours x 10 devices) from ~20,160 raw
rows - about a 12x reduction on the default dataset. `03` prints a
row-by-row comparison proving the aggregate equals the raw computation.

`refresh_continuous_aggregate()` cannot run inside an explicit transaction
block. `run_sql.sh` autocommits, so it works there; if you wrap the scripts in
`BEGIN ... COMMIT` yourself, run the `CALL` outside the transaction.

## Refresh policy

```sql
SELECT add_continuous_aggregate_policy(
    'sensor_hourly',
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes',
    if_not_exists     => TRUE
);
```

| Argument | Value | Meaning |
| --- | --- | --- |
| `start_offset` | 7 days | how far back each refresh re-scans for new/late data |
| `end_offset` | 1 hour | how close to "now" the refresh may write |
| `schedule_interval` | 30 minutes | how often the background job runs |

So the job runs every 30 minutes and recomputes the last 7 days, **leaving the
most recent hour alone**. The current hour is still being written to and its
bucket is incomplete; skipping it avoids rewriting a half-filled bucket on every
tick.

**Why the latest hour might not appear:** because `end_offset` is 1 hour, a
bucket is not materialised by the scheduled job until it is more than an hour
old. For a live "last hour" view, read that hour from `sensor_readings`, or
refresh it on demand:

```sql
CALL refresh_continuous_aggregate('sensor_hourly', now() - INTERVAL '2 hours', NULL);
```

Confirm the policy with the queries in `04_refresh_policy.sql` (they read
`timescaledb_information.jobs` and
`timescaledb_information.continuous_aggregates`). Change the cadence later with
`alter_job(...)` - an example is in that same file.

## Dashboard query

`05_dashboard_query.sql` takes three parameters (with defaults) and reads the
aggregate only:

```sql
SELECT
    bucket, device_id,
    round(avg_temperature::numeric, 2) AS avg_temperature,
    round(min_temperature::numeric, 2) AS min_temperature,
    round(max_temperature::numeric, 2) AS max_temperature,
    reading_count
FROM sensor_hourly
WHERE device_id = :'device_id'
  AND bucket >= :'range_start'::timestamptz
  AND bucket <  :'range_end'::timestamptz
ORDER BY bucket;
```

Override the defaults from the shell:

```bash
psql "$DATABASE_URL" \
  -v device_id=device-07 \
  -v range_start='2026-09-02 00:00:00+00' \
  -v range_end='2026-09-03 00:00:00+00' \
  -f sql/05_dashboard_query.sql
```

Expected output shape (values are illustrative of the default dataset):

```
        bucket         | device_id | avg_temperature | min_temperature | max_temperature | reading_count
-----------------------+-----------+-----------------+-----------------+-----------------+---------------
 2026-09-01 00:00:00+00 | device-03 |           15.42 |           14.10 |           16.90 |            12
 2026-09-01 01:00:00+00 | device-03 |           14.98 |           13.75 |           16.20 |            12
 ... (one row per hour in the selected range)
```

Each bucket contains 12 readings (one every 5 minutes), so `reading_count` is 12
on the default dataset.

## Benchmark

`06_benchmark.sql` runs `EXPLAIN (ANALYZE, BUFFERS)` for two logically identical
queries over the same device and window:

- **Query A** aggregates hourly metrics from raw `sensor_readings`.
- **Query B** reads the same metrics from `sensor_hourly`.

Read the plans as well as the times: Query A shows a scan plus a
`GroupAggregate` over many rows; Query B scans far fewer rows. A final query
asserts the two paths return identical values.

**Important:** execution plans, dataset size, warm/cold cache and the state of
the machine all affect timings. Run each query a couple of times; the first run
is usually slower while pages are read from storage. **Do not claim the
aggregate is faster unless your own measurements show it** - if the default
20k-row dataset is too small to show a gap, enlarge it as described above and
re-run.

### Recording your results

Fill this in with your own numbers. A skeleton is provided; do not invent values.

| Metric | Query A - raw | Query B - aggregate |
| --- | --- | --- |
| Plan node (top) | _e.g. GroupAggregate_ | _e.g. Index Scan_ |
| Rows processed at scan | | |
| `Buffers` shared hits/reads | | |
| Execution time, run 1 (ms) | | |
| Execution time, run 2 (ms) | | |
| Execution time, run 3 (ms) | | |

Dataset size used: `______` rows. Service size / region: `______`.

## Limitations

- **Small default dataset.** 20k rows may be too small to show a clear timing
  difference; the plan shapes still differ, but timings might not. Scale up.
- **Freshness trade-off.** The refresh policy excludes the most recent hour, so
  the newest bucket is intentionally absent from the scheduled aggregate.
- **Grouping is fixed.** Only hourly buckets grouped by `device_id` are
  materialised. A different granularity needs another continuous aggregate.
- **Buckets are UTC-anchored.** `time_bucket` buckets are aligned to UTC; local
  timezone handling is out of scope here.
- **Not a production app.** No auth, API, or UI - on purpose, to keep the
  demonstration focused on the database.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `ERROR: DATABASE_URL is not set` | Create `.env` from `.env.example` and fill in your URL, or `export DATABASE_URL=...`. |
| `could not translate host name` / timeouts | Wrong host/port, or your IP is not allowed. Check the Tiger Cloud "Connect" details. |
| SSL / certificate errors | Use `?sslmode=require` in the URL (the runner also sets `PGSSLMODE=require`). |
| `relation "sensor_hourly" does not exist` | Run `03` before `05`/`06`. |
| `relation "sensor_readings" does not exist` | Run `01` and `02` first. |
| `function create_hypertable(...) does not exist` | Not connected to TimescaleDB. Confirm you are on Tiger Cloud, not a plain Postgres. |
| `CALL ... cannot run inside a transaction block` | Run the `CALL refresh_continuous_aggregate(...)` outside `BEGIN/COMMIT`. |
| Numbers differ from the examples | Expected if you changed the date range, device count, or interval. |

## Security notes

- `.env` is git-ignored; only `.env.example` (placeholders) is committed.
- The runner never echoes `DATABASE_URL`.
- TLS (`sslmode=require`) is enforced for hosted connections.
- No credentials belong in SQL files, the README, or screenshots. Confirm with
  `git check-ignore -v .env` before any commit.

## Publish to GitHub

Nothing is pushed automatically. After reviewing the files:

```bash
git init
git add .
git status                 # confirm .env is NOT staged
git commit -m "Add TigerDB continuous aggregates dashboard demo"

# create an empty PUBLIC repo (only when you are ready), then:
gh repo create tigerdata-continuous-aggregates --public --source=. --remote=origin
git push -u origin main
```

Verify the secret is ignored first:

```bash
git check-ignore -v .env   # should print a .gitignore match
```

## Screenshots

See `screenshots/README.md` for the exact checklist of images to capture from
the real Tiger Cloud console and your own query output. No screenshots are
generated for you, and none should contain credentials.
