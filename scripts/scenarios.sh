#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PostgreSQL monitoring demo scenarios
# ------------------------------------------------------------

PG_DATABASE="${PG_DATABASE:-pgbench}"
PG_WORKLOAD_USER="${PG_WORKLOAD_USER:-pgbench_user}"
SCENARIO_DURATION="${SCENARIO_DURATION:-45}"

echo "==> Starting PostgreSQL monitoring scenarios"

# ------------------------------------------------------------
# Validate prerequisites
# ------------------------------------------------------------

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed"
  exit 1
fi

if [[ -z "${PG_WORKLOAD_PASSWORD:-}" ]]; then
  echo "ERROR: PG_WORKLOAD_PASSWORD is not set"
  echo
  echo "Example:"
  echo "  PG_WORKLOAD_PASSWORD='test-password' ./scripts/scenarios.sh"
  exit 1
fi

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

if ! [[ "${SCENARIO_DURATION}" =~ ^[0-9]+$ ]] || [[ "${SCENARIO_DURATION}" -lt 15 ]]; then
  echo "ERROR: SCENARIO_DURATION must be an integer >= 15 seconds"
  exit 1
fi

echo
echo "    Database          : ${PG_DATABASE}"
echo "    User              : ${PG_WORKLOAD_USER}"
echo "    Scenario duration : ${SCENARIO_DURATION}s"
echo

# ------------------------------------------------------------
# Scenario 1: Idle in transaction
# ------------------------------------------------------------

echo "==> Scenario 1/2: idle in transaction"
echo "    Session will remain idle in transaction for ${SCENARIO_DURATION}s"

{
  echo "BEGIN;"
  echo "SELECT 1;"
  sleep "${SCENARIO_DURATION}"
  echo "COMMIT;"
} | PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
    psql \
      -h 127.0.0.1 \
      -U "${PG_WORKLOAD_USER}" \
      -d "${PG_DATABASE}" \
      -v ON_ERROR_STOP=1 \
      >/dev/null &

IDLE_PID=$!

echo "    Started background session PID ${IDLE_PID}"
echo "    Observe Grafana: Idle in Transaction / Connections Over Time"

wait "${IDLE_PID}"

echo "==> Idle in transaction scenario completed"
echo

# ------------------------------------------------------------
# Scenario 2: Lock wait
# ------------------------------------------------------------

echo "==> Scenario 2/2: lock wait"
echo "    One session will hold a row lock for ${SCENARIO_DURATION}s"
echo "    Another session will wait for the same row"

ACCOUNT_ID="$(
  PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
  psql \
    -h 127.0.0.1 \
    -U "${PG_WORKLOAD_USER}" \
    -d "${PG_DATABASE}" \
    -tAc "SELECT aid FROM pgbench_accounts ORDER BY aid LIMIT 1;"
)"

if [[ -z "${ACCOUNT_ID}" ]]; then
  echo "ERROR: Could not select a pgbench account"
  exit 1
fi

# Session A: acquire row lock and keep transaction open.
PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
psql \
  -h 127.0.0.1 \
  -U "${PG_WORKLOAD_USER}" \
  -d "${PG_DATABASE}" \
  -v ON_ERROR_STOP=1 \
  -c "
    BEGIN;
    UPDATE pgbench_accounts
    SET abalance = abalance
    WHERE aid = ${ACCOUNT_ID};

    SELECT pg_sleep(${SCENARIO_DURATION});
    ROLLBACK;
  " \
  >/dev/null &

LOCK_HOLDER_PID=$!

# Give session A enough time to acquire the row lock.
sleep 2

# Session B: block waiting for the row held by session A.
PGPASSWORD="${PG_WORKLOAD_PASSWORD}" \
psql \
  -h 127.0.0.1 \
  -U "${PG_WORKLOAD_USER}" \
  -d "${PG_DATABASE}" \
  -v ON_ERROR_STOP=1 \
  -c "
    BEGIN;
    UPDATE pgbench_accounts
    SET abalance = abalance
    WHERE aid = ${ACCOUNT_ID};
    ROLLBACK;
  " \
  >/dev/null &

LOCK_WAITER_PID=$!

echo "    Lock holder PID : ${LOCK_HOLDER_PID}"
echo "    Lock waiter PID : ${LOCK_WAITER_PID}"
echo "    Account ID      : ${ACCOUNT_ID}"
echo
echo "    Observe Grafana: Wait Events / Locks / Active Connections"

wait "${LOCK_HOLDER_PID}"
wait "${LOCK_WAITER_PID}"

echo
echo "==> Lock wait scenario completed"
echo
echo "==> All monitoring scenarios completed"
