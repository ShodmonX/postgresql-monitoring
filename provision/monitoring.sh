#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning monitoring stack on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

GRAFANA_VERSION="13.2.1"

# ------------------------------------------------------------
# Install prometheus
# ------------------------------------------------------------

apt-get update

apt-get install -y prometheus

# ------------------------------------------------------------
# Configure prometheus
# ------------------------------------------------------------

install -m 0644 -o prometheus -g prometheus \
  /vagrant/configs/prometheus/prometheus.yml \
  /etc/prometheus/prometheus.yml

# ------------------------------------------------------------
# Start prometheus
# ------------------------------------------------------------

systemctl daemon-reload

systemctl enable --now prometheus

systemctl restart prometheus

# ------------------------------------------------------------
# Validate Prometheus is running
# ------------------------------------------------------------

echo "==> Waiting for Prometheus to become ready"

PROMETHEUS_READY=false

for attempt in $(seq 1 60); do
  if curl --fail --silent --show-error --max-time 5 \
      http://127.0.0.1:9090/-/ready \
      >/dev/null; then
    PROMETHEUS_READY=true
    break
  fi

  sleep 1
done

if [[ "${PROMETHEUS_READY}" != "true" ]]; then
  echo "ERROR: Prometheus did not become ready within 60 seconds"
  systemctl --no-pager status prometheus || true
  journalctl -u prometheus -n 30 --no-pager || true
  exit 1
fi

echo "==> Prometheus is ready"

# ------------------------------------------------------------
# Install Grafana
# ------------------------------------------------------------

echo "==> Installing Grafana"

mkdir -p /etc/apt/keyrings

wget -q -O - https://apt.grafana.com/gpg.key \
  | gpg --dearmor \
  > /etc/apt/keyrings/grafana.gpg

echo \
  "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list

apt-get update

apt-get install -y "grafana=${GRAFANA_VERSION}"

# ------------------------------------------------------------
# Configure Grafana provisioning
# ------------------------------------------------------------

echo "==> Configuring Grafana provisioning"

install -d -m 0755 \
  /etc/grafana/provisioning/datasources \
  /etc/grafana/provisioning/dashboards \
  /var/lib/grafana/dashboards

install -m 0644 \
/vagrant/configs/grafana/provisioning/datasources/prometheus.yml \
/etc/grafana/provisioning/datasources/prometheus.yml

install -m 0644 \
  /vagrant/configs/grafana/provisioning/dashboards/postgresql.yml \
  /etc/grafana/provisioning/dashboards/postgresql.yml

install -m 0644 -o grafana -g grafana \
  /vagrant/configs/grafana/dashboards/postgresql-overview.json \
  /var/lib/grafana/dashboards/postgresql-overview.json

chown -R grafana:grafana /var/lib/grafana/dashboards

# ------------------------------------------------------------
# Start Grafana
# ------------------------------------------------------------

echo "==> Starting Grafana"

systemctl daemon-reload

systemctl enable --now grafana-server

systemctl restart grafana-server

# ------------------------------------------------------------
# Validate Grafana is running
# ------------------------------------------------------------

echo "==> Waiting for Grafana to become ready"

GRAFANA_READY=false

for attempt in $(seq 1 60); do
  if curl --fail --silent --show-error --max-time 5 \
      http://127.0.0.1:3000/api/health \
      >/dev/null; then
    GRAFANA_READY=true
    break
  fi

  sleep 1
done

if [[ "${GRAFANA_READY}" != "true" ]]; then
  echo "ERROR: Grafana did not become ready within 60 seconds"
  systemctl --no-pager status grafana-server || true
  journalctl -u grafana-server -n 50 --no-pager || true
  exit 1
fi

echo "==> Grafana is ready"


