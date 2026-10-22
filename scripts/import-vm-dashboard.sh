#!/usr/bin/env bash
# Fetch the upstream VictoriaMetrics "VMSingle" Grafana dashboard and
# wrap it as a sidecar-loadable ConfigMap in the monitoring namespace.
# The dashboard shows VMSingle health: ingest rate, active series, RSS,
# query latency, disk usage, per-stage pipeline metrics.
#
# Prereq: kube-prometheus-stack Grafana running in monitoring namespace
# with the dashboard sidecar watching ConfigMaps labelled
# grafana_dashboard=1 (default kube-prometheus-stack config).
set -euo pipefail

NAMESPACE=${NAMESPACE:-monitoring}
# Official VictoriaMetrics VMSingle dashboard on Grafana.com, id 10229
DASHBOARD_URL="https://grafana.com/api/dashboards/10229/revisions/latest/download"

tmp=$(mktemp)
trap "rm -f $tmp" EXIT

curl -sSfL "$DASHBOARD_URL" -o "$tmp"
echo "Downloaded dashboard, size: $(wc -c < "$tmp") bytes"

kubectl -n "$NAMESPACE" create configmap vmsingle-dashboard \
  --from-file=vmsingle.json="$tmp" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -

echo "Dashboard imported. Reload Grafana (or wait ~30s for sidecar reload)."
