#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PostgreSQL monitoring demo workload cleanup
# ------------------------------------------------------------

PG_DATABASE="${PG_DATABASE:-pgbench}"
PG_WORKLOAD_USER="${PG_WORKLOAD_USER:-pgbench_user}"

echo "==> Cleaning PostgreSQL demo workload environment"

# ------------------------------------------------------------
# Validate prerequisites
# ------------------------------------------------------------

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed"
  exit 1
fi

if ! sudo -u postgres pg_isready -q; then
  echo "ERROR: PostgreSQL is not ready"
  exit 1
fi

# ------------------------------------------------------------
# Drop workload database
# ------------------------------------------------------------

DATABASE_EXISTS="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${PG_DATABASE}'"
)"

if [[ "${DATABASE_EXISTS}" == "1" ]]; then
  echo "==> Terminating connections to database: ${PG_DATABASE}"

  sudo -u postgres psql \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    --set=target_database="${PG_DATABASE}" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'target_database'
  AND pid <> pg_backend_pid();
SQL

  echo "==> Dropping database: ${PG_DATABASE}"

  sudo -u postgres dropdb "${PG_DATABASE}"

  echo "==> Database removed"
else
  echo "==> Database ${PG_DATABASE} does not exist, skipping"
fi

# ------------------------------------------------------------
# Drop workload role
# ------------------------------------------------------------

ROLE_EXISTS="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname = '${PG_WORKLOAD_USER}'"
)"

if [[ "${ROLE_EXISTS}" == "1" ]]; then
  echo "==> Dropping workload role: ${PG_WORKLOAD_USER}"

  sudo -u postgres psql \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    --set=workload_user="${PG_WORKLOAD_USER}" <<'SQL'
SELECT format(
  'DROP ROLE %I',
  :'workload_user'
)
\gexec
SQL

  echo "==> Workload role removed"
else
  echo "==> Role ${PG_WORKLOAD_USER} does not exist, skipping"
fi

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

DATABASE_REMAINS="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT count(*) FROM pg_database WHERE datname = '${PG_DATABASE}'"
)"

ROLE_REMAINS="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${PG_WORKLOAD_USER}'"
)"

if [[ "${DATABASE_REMAINS}" != "0" ]]; then
  echo "ERROR: Database cleanup verification failed"
  exit 1
fi

if [[ "${ROLE_REMAINS}" != "0" ]]; then
  echo "ERROR: Role cleanup verification failed"
  exit 1
fi

echo
echo "==> Demo workload environment cleaned successfully"
echo
echo "    Database removed : ${PG_DATABASE}"
echo "    Role removed     : ${PG_WORKLOAD_USER}"