#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning PostgreSQL on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Validate required secrets
# ------------------------------------------------------------

if [[ -z "${PG_MONITORING_PASSWORD:-}" ]]; then
  echo "ERROR: PG_MONITORING_PASSWORD is not set"
  exit 1
fi

# ------------------------------------------------------------
# Install PostgreSQL
# ------------------------------------------------------------

apt-get update

apt-get install -y \
  postgresql-16 \
  postgresql-client-16

# ------------------------------------------------------------
# PostgreSQL paths
# ------------------------------------------------------------

PG_VERSION="16"
PG_CLUSTER="main"

PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_CONF="${PG_CONF_DIR}/postgresql.conf"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"

# ------------------------------------------------------------
# Create PostgreSQL roles
# ------------------------------------------------------------

echo "==> Creating PostgreSQL role for monitoring"

sudo -u postgres psql \
  --set=monitoring_password="${PG_MONITORING_PASSWORD}" <<'SQL'

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'monitoring'
  ) THEN
    CREATE ROLE monitoring WITH LOGIN;
  END IF;
END
$$;

ALTER ROLE monitoring
  PASSWORD :'monitoring_password';

GRANT pg_monitor TO monitoring;

GRANT CONNECT ON DATABASE postgres TO monitoring;

SQL


# ------------------------------------------------------------
# Configure client authentication
# ------------------------------------------------------------

echo "==> Configuring pg_hba.conf"

sed -i \
  '/# BEGIN POSTGRESQL-MONITORING/,/# END POSTGRESQL-MONITORING/d' \
  "${PG_HBA}"

cat >> "${PG_HBA}" <<'EOF'

# BEGIN POSTGRESQL-MONITORING

# Monitoring connection
host    all     monitoring    localhost    scram-sha-256

# END POSTGRESQL-MONITORING
EOF

# ------------------------------------------------------------
# Configure pg_stat_statements
# ------------------------------------------------------------

echo "==> Configuring pg_stat_statements"

sudo -u postgres psql \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';"

# ------------------------------------------------------------
# Apply configuration
# ------------------------------------------------------------

echo "==> Restarting PostgreSQL"

systemctl restart postgresql

echo "==> Waiting for PostgreSQL to become ready"

PG_ISREADY=false

for attempt in $(seq 1 60); do
  if pg_isready \
      -h 127.0.0.1 \
      -p 5432 \
      -d postgres \
      >/dev/null 2>&1; then

    PG_ISREADY=true
    break
  fi

  sleep 1
done

if [[ "${PG_ISREADY}" != "true" ]]; then
  echo "ERROR: PostgreSQL did not become ready within 60 seconds"
  systemctl --no-pager status postgresql || true
  exit 1
fi

echo "==> PostgreSQL is accepting TCP connections"

# ------------------------------------------------------------
# Enable pg_stat_statements
# ------------------------------------------------------------

echo "==> Enabling pg_stat_statements"

sudo -u postgres psql \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"


echo "==> Verifying pg_stat_statements"

sudo -u postgres psql \
  -d postgres \
  -tAc "SHOW shared_preload_libraries;" \
  | grep -qw 'pg_stat_statements'

sudo -u postgres psql \
  -d postgres \
  -tAc "SELECT extname FROM pg_extension WHERE extname = 'pg_stat_statements';" \
  | grep -qx 'pg_stat_statements'

echo "==> pg_stat_statements is enabled"

# ------------------------------------------------------------
# Install pg_exporter
# ------------------------------------------------------------

echo "==> Installing pg_exporter"

wget https://github.com/pgsty/pg_exporter/releases/download/v1.4.1/pg-exporter_1.4.1-1_amd64.deb

apt-get install ./pg-exporter_1.4.1-1_amd64.deb

pg_exporter --version

echo "==> pg_exporter installed"

# ------------------------------------------------------------
# Configure pg_exporter
# ------------------------------------------------------------

echo "==> Configuring pg_exporter"

mkdir -p /etc/pg_exporter

# Package-provided default collectors
install -m 0640 -o root -g prometheus \
  /etc/pg_exporter.yml \
  /etc/pg_exporter/0000-default.yml

# Project-specific custom collectors
install -m 0640 -o root -g prometheus \
  /vagrant/configs/pg_exporter/custom_metrics.yml \
  /etc/pg_exporter/9000-custom_metrics.yml

cat > /etc/default/pg_exporter <<EOF
PG_EXPORTER_URL='postgresql://monitoring:${PG_MONITORING_PASSWORD}@127.0.0.1:5432/postgres?sslmode=disable'
PG_EXPORTER_CONFIG='/etc/pg_exporter'
PG_EXPORTER_AUTO_DISCOVERY=true
PG_EXPORTER_EXCLUDE_DATABASE='template0,template1'
EOF

chown root:prometheus /etc/default/pg_exporter
chmod 640 /etc/default/pg_exporter

#------------------------------------------------------------
# Configure systemd service
#------------------------------------------------------------

echo "==> Configuring systemd service for pg_exporter"

systemctl daemon-reload

systemctl enable pg_exporter
systemctl restart pg_exporter

if ! systemctl is-active --quiet pg_exporter; then
  echo "ERROR: pg_exporter service is not running"
  systemctl --no-pager status pg_exporter || true
  exit 1
fi

echo "==> systemd service for pg_exporter configured and running"

#------------------------------------------------------------
# Check pg_exporter metrics endpoint
#------------------------------------------------------------

echo "==> Waiting for pg_exporter metrics endpoint"

PG_EXPORTER_READY=false

for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 \
      http://127.0.0.1:9630/metrics \
      | grep -q '^pg_up 1'; then
    PG_EXPORTER_READY=true
    break
  fi

  sleep 1
done

if [[ "${PG_EXPORTER_READY}" != "true" ]]; then
  echo "ERROR: pg_exporter metrics endpoint did not become ready within 30 seconds"
  systemctl --no-pager status pg_exporter || true
  journalctl -u pg_exporter -n 30 --no-pager || true
  exit 1
fi

echo "==> pg_exporter is running and PostgreSQL is up"