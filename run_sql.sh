#!/usr/bin/env bash
# =============================================================================
# run_sql.sh - run every SQL file in ./sql, in order, against Tiger Cloud.
#
#   ./run_sql.sh                 run all steps 01..06
#   ./run_sql.sh 01 05           run only files whose names start with 01 / 05
#   ./run_sql.sh --reset         drop the view + table first, then run all
#   ./run_sql.sh --dry-run       list the files that would run, execute nothing
#
# DATABASE_URL is read from ./.env (see .env.example). The connection string is
# never printed. TLS is required for the hosted database.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SQL_DIR="sql"
ENV_FILE=".env"

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

# Load .env without executing it: parse simple KEY=VALUE lines only.
load_env() {
    local file="$1" line key val
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then
            val="${val:1:${#val}-2}"
        fi
        export "$key=$val"
    done < "$file"
}

DRY_RUN=0
RESET=0
SELECTORS=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        --reset)   RESET=1 ;;
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         SELECTORS+=("$arg") ;;
    esac
done

load_env "$ENV_FILE"

# Fail loudly instead of connecting somewhere unexpected.
if [[ -z "${DATABASE_URL:-}" ]]; then
    cat >&2 <<'MSG'
ERROR: DATABASE_URL is not set.

  1. Copy the example file:  cp .env.example .env
  2. Edit .env and paste your Tiger Cloud connection URL.
  3. Re-run ./run_sql.sh

.env is git-ignored - never commit it.
MSG
    exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: psql not found. Install the PostgreSQL client (psql 15+)." >&2
    exit 1
fi

# Hosted TimescaleDB requires TLS. Keep an explicit override if the user set
# one; otherwise require SSL.
export PGSSLMODE="${PGSSLMODE:-require}"
export PGAPPNAME="${PGAPPNAME:-tigerdata-continuous-aggregates}"

# Collect SQL files in numeric order.
mapfile -t files < <(find "$SQL_DIR" -maxdepth 1 -type f -name '*.sql' | sort)

if [[ ${#SELECTORS[@]} -gt 0 ]]; then
    selected=()
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        for s in "${SELECTORS[@]}"; do
            if [[ "$base" == "$s"* ]]; then selected+=("$f"); break; fi
        done
    done
    files=("${selected[@]}")
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "ERROR: no SQL files matched." >&2
    exit 1
fi

echo "SQL files to run (${#files[@]}):"
for f in "${files[@]}"; do echo "  - $f"; done

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "(dry run - nothing was executed)"
    exit 0
fi

# One psql session so session state and -v variables carry across files.
psql_args=( "$DATABASE_URL" --no-psqlrc --quiet -v ON_ERROR_STOP=1 -P pager=off )

if [[ "$RESET" -eq 1 ]]; then
    psql_args+=( -c "DROP MATERIALIZED VIEW IF EXISTS sensor_hourly CASCADE;" )
    psql_args+=( -c "DROP TABLE IF EXISTS sensor_readings CASCADE;" )
fi

for f in "${files[@]}"; do
    psql_args+=( -f "$f" )
done

echo "Connecting to Tiger Cloud over TLS (connection string hidden)..."
psql "${psql_args[@]}"

echo "Done."
