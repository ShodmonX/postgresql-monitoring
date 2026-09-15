#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PostgreSQL monitoring demo workload
# ------------------------------------------------------------

PG_DATABASE="${PG_DATABASE:-pgbench}"
PG_WORKLOAD_USER="${PG_WORKLOAD_USER:-pgbench_user}"

PGBENCH_DURATION="${PGBENCH_DURATION:-300}"
PGBENCH_CLIENTS="${PGBENCH_CLIENTS:-5}"
PGBENCH_JOBS="${PGBENCH_JOBS:-2}"

echo "==> Starting PostgreSQL demo workload"

# ------------------------------------------------------------
# Validate prerequisites
# ------------------------------------------------------------

if ! command -v pgbench >/dev/null 2>&1; then
  echo "ERROR: pgbench is not installed"
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed"
  exit 1
fi

if [[ -z "${PG_WORKLOAD_PASSWORD:-}" ]]; then
  echo "ERROR: PG_WORKLOAD_PASSWORD is not set"
  echo
  echo "Example:"
  echo "  PG_WORKLOAD_PASSWORD='test-password' ./scripts/run.sh"
  exit 1
fi

# ------------------------------------------------------------
# Verify workload database
# ------------------------------------------------------------

echo "==> Verifying workload database"

if ! PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
  psql \
    -h 127.0.0.1 \
    -U "${PG_WORKLOAD_USER}" \
    -d "${PG_DATABASE}" \
    -tAc "SELECT 1;" \
    >/dev/null; then

  echo "ERROR: Could not connect to ${PG_DATABASE} as ${PG_WORKLOAD_USER}"
  echo "Run ./scripts/setup.sh first"
  exit 1
fi

PGBENCH_READY="$(
  PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
  psql \
    -h 127.0.0.1 \
    -U "${PG_WORKLOAD_USER}" \
    -d "${PG_DATABASE}" \
    -tAc "
      SELECT CASE
        WHEN to_regclass('public.pgbench_accounts') IS NOT NULL
         AND to_regclass('public.pgbench_branches') IS NOT NULL
         AND to_regclass('public.pgbench_tellers') IS NOT NULL
         AND to_regclass('public.pgbench_history') IS NOT NULL
        THEN 1
        ELSE 0
      END;
    "
)"

if [[ "${PGBENCH_READY}" != "1" ]]; then
  echo "ERROR: pgbench schema is not initialized"
  echo "Run ./scripts/setup.sh first"
  exit 1
fi

# ------------------------------------------------------------
# Run demo workload
# ------------------------------------------------------------

echo
echo "==> Demo workload configuration"
echo
echo "    Database : ${PG_DATABASE}"
echo "    User     : ${PG_WORKLOAD_USER}"
echo "    Duration : ${PGBENCH_DURATION}s"
echo "    Clients  : ${PGBENCH_CLIENTS}"
echo "    Jobs     : ${PGBENCH_JOBS}"
echo
echo "==> Open Grafana and observe PostgreSQL metrics"
echo

PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
pgbench \
  -h 127.0.0.1 \
  -U "${PG_WORKLOAD_USER}" \
  -T "${PGBENCH_DURATION}" \
  -c "${PGBENCH_CLIENTS}" \
  -j "${PGBENCH_JOBS}" \
  -P 10 \
  "${PG_DATABASE}"

echo
echo "==> Demo workload completed"