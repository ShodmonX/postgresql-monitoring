#!/usr/bin/env bash
set -euo pipefail

echo "==> Running common provisioning on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# Refresh package metadata only. Do not perform a full system upgrade.
apt-get update

# Minimal utilities required by later provisioning and verification.
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  nano \
  jq

# Use the same timezone on every node.
timedatectl set-timezone Asia/Tashkent

# Keep internal host mappings idempotent.
sed -i \
  '/# BEGIN POSTGRESQL-MONITORING/,/# END POSTGRESQL-MONITORING/d' \
  /etc/hosts

cat >> /etc/hosts <<'EOF'

# BEGIN POSTGRESQL-MONITORING
192.168.167.201 pg-primary
192.168.167.210 monitoring
# END POSTGRESQL-MONITORING
EOF

echo "==> Common provisioning completed on $(hostname)"
