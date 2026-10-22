#!/usr/bin/env bash
# Fetch the upstream VictoriaMetrics "VMSingle" Grafana dashboard (id 10229
# on grafana.com) and expose it as a sidecar-loadable ConfigMap in the
# monitoring namespace.
#
# The dashboard shows VMSingle health: ingest rate, active series, RSS,
# query latency, disk usage, per-stage pipeline metrics.
#
# Prereq: kube-prometheus-stack Grafana running in monitoring namespace
# with the dashboard sidecar watching ConfigMaps labelled
# grafana_dashboard=1 (default kube-prometheus-stack behaviour).
#
# Note: `kubectl apply` stores the full ConfigMap in the
# kubectl.kubernetes.io/last-applied-configuration annotation, which has a
# hard 256 KiB limit. The VictoriaMetrics dashboard JSON blows past that,
# so we use plain `create` + `label` here. For GitOps you'd want
# `kubectl apply --server-side` (SSA bypasses the annotation path) or
# split the JSON across multiple files.
set -euo pipefail

NAMESPACE=${NAMESPACE:-monitoring}
DASHBOARD_ID=${DASHBOARD_ID:-10229}
DASHBOARD_URL="https://grafana.com/api/dashboards/${DASHBOARD_ID}/revisions/latest/download"

tmp=$(mktemp)
trap "rm -f $tmp" EXIT

curl -sSfL "$DASHBOARD_URL" -o "$tmp"
echo "Downloaded dashboard, size: $(wc -c < "$tmp") bytes"

kubectl -n "$NAMESPACE" delete configmap vmsingle-dashboard --ignore-not-found
kubectl -n "$NAMESPACE" create configmap vmsingle-dashboard --from-file=vmsingle.json="$tmp"
kubectl -n "$NAMESPACE" label configmap vmsingle-dashboard grafana_dashboard=1 --overwrite

echo "Dashboard imported. Reload Grafana (or wait ~30s for sidecar reload)."
