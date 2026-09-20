#!/usr/bin/env bash
set -euo pipefail

# Run this script on the monitoring VM after PostgreSQL and workload setup.

PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"

for tool in curl jq; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "FAIL | Required command is missing: ${tool}" >&2
    exit 1
  fi
done

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

if ! curl --fail --silent --show-error --max-time 5 \
  "${PROMETHEUS_URL}/-/ready" >/dev/null; then
  fail "Prometheus is not ready at ${PROMETHEUS_URL}"
fi
pass "Prometheus is ready"

GRAFANA_HEALTH="$(curl --fail --silent --show-error --max-time 5 \
  "${GRAFANA_URL}/api/health")" \
  || fail "Grafana health endpoint did not respond at ${GRAFANA_URL}"

if ! jq -e '.database == "ok"' >/dev/null <<<"${GRAFANA_HEALTH}"; then
  fail "Grafana database health is not ok"
fi
pass "Grafana is healthy"

TARGETS="$(curl --fail --silent --show-error --max-time 5 \
  "${PROMETHEUS_URL}/api/v1/targets?state=active")" \
  || fail "Prometheus targets API did not respond"

if ! jq -e '[.data.activeTargets[] | select(.labels.job == "pg_exporter" and .health == "up")] | length > 0' \
  >/dev/null <<<"${TARGETS}"; then
  fail "No active pg_exporter target is up"
fi
pass "Prometheus pg_exporter target is up"

check_metric() {
  local metric="$1"
  local description="$2"
  local response

  response="$(curl --fail --silent --show-error --max-time 10 \
    --get --data-urlencode "query=count(${metric})" \
    "${PROMETHEUS_URL}/api/v1/query")" \
    || fail "Prometheus query failed for ${metric}"

  if ! jq -e '.status == "success" and (.data.result | length > 0)' \
    >/dev/null <<<"${response}"; then
    fail "Metric is missing or has no samples: ${metric}"
  fi
  pass "${description}"
}

check_metric 'pg_custom_activity_count' 'PostgreSQL activity metrics are present'
check_metric 'pg_custom_query_calls' 'pg_stat_statements query metrics are present'

printf '\nAll monitoring checks passed.\n'
