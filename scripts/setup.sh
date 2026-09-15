#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PostgreSQL monitoring demo workload setup
# ------------------------------------------------------------

PG_DATABASE="${PG_DATABASE:-pgbench}"
PG_WORKLOAD_USER="${PG_WORKLOAD_USER:-pgbench_user}"
PGBENCH_SCALE="${PGBENCH_SCALE:-10}"

echo "==> Preparing PostgreSQL demo workload"

# ------------------------------------------------------------
# Validate prerequisites
# ------------------------------------------------------------

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql is not installed"
  exit 1
fi

if ! command -v pgbench >/dev/null 2>&1; then
  echo "ERROR: pgbench is not installed"
  exit 1
fi

if [[ -z "${PG_WORKLOAD_PASSWORD:-}" ]]; then
  echo "ERROR: PG_WORKLOAD_PASSWORD is not set"
  echo
  echo "Example:"
  echo "  PG_WORKLOAD_PASSWORD='change-me' ./scripts/setup.sh"
  exit 1
fi

if ! sudo -u postgres pg_isready -q; then
  echo "ERROR: PostgreSQL is not ready"
  exit 1
fi

echo "==> PostgreSQL is ready"

# ------------------------------------------------------------
# Create workload role
# ------------------------------------------------------------

echo "==> Configuring workload role: ${PG_WORKLOAD_USER}"

sudo -u postgres psql \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  --set=workload_user="${PG_WORKLOAD_USER}" \
  --set=workload_password="${PG_WORKLOAD_PASSWORD}" <<'SQL'
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L',
  :'workload_user',
  :'workload_password'
)
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_roles
  WHERE rolname = :'workload_user'
)
\gexec

SELECT format(
  'ALTER ROLE %I PASSWORD %L',
  :'workload_user',
  :'workload_password'
)
\gexec
SQL

echo "==> Workload role is ready"

# ------------------------------------------------------------
# Create pgbench database
# ------------------------------------------------------------

DATABASE_EXISTS="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${PG_DATABASE}'"
)"

if [[ "${DATABASE_EXISTS}" != "1" ]]; then
  echo "==> Creating database: ${PG_DATABASE}"

  sudo -u postgres createdb \
    --owner="${PG_WORKLOAD_USER}" \
    "${PG_DATABASE}"
else
  echo "==> Database ${PG_DATABASE} already exists"
fi

# ------------------------------------------------------------
# Check whether pgbench is already initialized
# ------------------------------------------------------------

PGBENCH_INITIALIZED="$(
  sudo -u postgres psql \
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

if [[ "${PGBENCH_INITIALIZED}" == "1" ]]; then
  echo "==> pgbench schema already initialized"
else
  echo "==> Initializing pgbench schema with scale ${PGBENCH_SCALE}"

  sudo -u postgres pgbench \
    -i \
    -s "${PGBENCH_SCALE}" \
    "${PG_DATABASE}"

  echo "==> pgbench initialization completed"
fi

# ------------------------------------------------------------
# Configure ownership
# ------------------------------------------------------------

echo "==> Configuring pgbench object ownership"

sudo -u postgres psql \
  -d "${PG_DATABASE}" \
  -v ON_ERROR_STOP=1 \
  --set=workload_user="${PG_WORKLOAD_USER}" <<'SQL'
SELECT format(
  'ALTER TABLE %I OWNER TO %I',
  tablename,
  :'workload_user'
)
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
    'pgbench_accounts',
    'pgbench_branches',
    'pgbench_tellers',
    'pgbench_history'
  )
\gexec

SELECT format(
  'ALTER SEQUENCE %I OWNER TO %I',
  sequencename,
  :'workload_user'
)
FROM pg_sequences
WHERE schemaname = 'public'
  AND sequencename LIKE 'pgbench_%'
\gexec
SQL

# ------------------------------------------------------------
# Refresh planner statistics
# ------------------------------------------------------------

echo "==> Running ANALYZE"

sudo -u postgres psql \
  -d "${PG_DATABASE}" \
  -v ON_ERROR_STOP=1 \
  -c "ANALYZE;"

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

echo "==> Verifying demo workload environment"

ROLE_OK="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname = '${PG_WORKLOAD_USER}'"
)"

DATABASE_OK="$(
  sudo -u postgres psql \
    -d postgres \
    -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${PG_DATABASE}'"
)"

TABLE_COUNT="$(
  sudo -u postgres psql \
    -d "${PG_DATABASE}" \
    -tAc "
      SELECT count(*)
      FROM pg_tables
      WHERE schemaname = 'public'
        AND tablename IN (
          'pgbench_accounts',
          'pgbench_branches',
          'pgbench_tellers',
          'pgbench_history'
        );
    "
)"

ACCOUNT_COUNT="$(
  sudo -u postgres psql \
    -d "${PG_DATABASE}" \
    -tAc "SELECT count(*) FROM pgbench_accounts;"
)"

if [[ "${ROLE_OK}" != "1" ]]; then
  echo "ERROR: Workload role verification failed"
  exit 1
fi

if [[ "${DATABASE_OK}" != "1" ]]; then
  echo "ERROR: Database verification failed"
  exit 1
fi

if [[ "${TABLE_COUNT}" != "4" ]]; then
  echo "ERROR: Expected 4 pgbench tables, found ${TABLE_COUNT}"
  exit 1
fi

if [[ "${ACCOUNT_COUNT}" -le 0 ]]; then
  echo "ERROR: pgbench_accounts contains no rows"
  exit 1
fi

echo
echo "==> Demo workload environment is ready"
echo
echo "    Database : ${PG_DATABASE}"
echo "    User     : ${PG_WORKLOAD_USER}"
echo "    Scale    : ${PGBENCH_SCALE}"
echo "    Accounts : ${ACCOUNT_COUNT}"
echo
echo "Next step:"
echo "  ./scripts/run.sh"