#!/usr/bin/env bash
# run_pipeline.sh
# Rebuilds the project end to end, in dependency order. Run from the repo root with the venv active.
#
#   ./run_pipeline.sh            core layer onward (20_core -> risk -> PD model -> reporting -> charts)
#   ./run_pipeline.sh --full     also reload raw files and staging (00_load, 10_staging) first
#
# Connection: psql uses PGHOST / PGPORT / PGUSER / PGDATABASE if set, else the defaults below
# (password from ~/.pgpass). Python reads DATABASE_URL from .env.
# Stops at the first error; each SQL script runs in its own transaction, so a failed step leaves
# the tables of that step unchanged.

set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGUSER="${PGUSER:-mikhail}"
export PGDATABASE="${PGDATABASE:-freddie}"
PYTHON="${PYTHON:-python}"

cd "$(dirname "$0")"

run_sql() {
    local f
    for f in "$@"; do
        [ -e "$f" ] || continue
        local t0=$SECONDS
        echo "== $f"
        psql -q -v ON_ERROR_STOP=1 -f "$f" > "logs/$(basename "$f" .sql).log" 2>&1 \
            || { echo "FAILED: $f (see logs/$(basename "$f" .sql).log)"; tail -5 "logs/$(basename "$f" .sql).log"; exit 1; }
        echo "   ok ($((SECONDS - t0))s)"
    done
}

run_py() {
    local t0=$SECONDS
    echo "== $1"
    "$PYTHON" "$1" > "logs/$(basename "$1" .py).log" 2>&1 \
        || { echo "FAILED: $1 (see logs/$(basename "$1" .py).log)"; tail -5 "logs/$(basename "$1" .py).log"; exit 1; }
    echo "   ok ($((SECONDS - t0))s)"
}

mkdir -p logs
START=$SECONDS

if [ "${1:-}" = "--full" ]; then
    run_sql sql/00_load/*.sql sql/10_staging/*.sql
fi

run_sql sql/20_core/*.sql                      # loan_month, default_event, snapshot, checks
run_sql sql/30_risk/3[0-4]_*.sql               # PD sample, bins, binning, stability, WoE for all snapshots
run_py  python/fit_pd_model.py                 # logistic regression -> mart.pd_coef, mart.pd_validation
run_sql sql/30_risk/3[5-9]_*.sql               # scores and master scale, staging, LGD, ECL
run_sql sql/40_reporting/*.sql                 # reporting marts
run_py  python/make_charts.py                  # docs/img/*.png

echo "== pipeline finished in $(((SECONDS - START) / 60))m $(((SECONDS - START) % 60))s; per-step output in logs/"