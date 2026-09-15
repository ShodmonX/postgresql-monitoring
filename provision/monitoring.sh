#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning monitoring stack on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

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


