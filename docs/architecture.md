# Architecture

## Topology

```
                          OCI Ampere A1 VM (same host as kafka-slo-observability)
 +-------------------------------------------------------------------------+
 |                             k3s v1.36                                   |
 |                                                                         |
 |  namespace: vm                                                          |
 |  +---------------------+   watches  +---------------------------+       |
 |  | vmoperator          |----------->| CRs (VMSingle, VMAgent,   |       |
 |  | (Deployment)        |            | VMAlert, VMRule, VMPodScr |       |
 |  +---------------------+            | ape, VMNodeScrape, ...)   |       |
 |            |                        +---------------------------+       |
 |            | reconciles                       |                         |
 |            v                                  v                         |
 |  +---------------+     scrape      +----------------+                   |
 |  | VMAgent       |---------------->| k8s targets    |                   |
 |  | (Deployment)  |                 | (kubelet,      |                   |
 |  +---------------+                 |  node-exp,     |                   |
 |     | remote-write                 |  ksm, apps)    |                   |
 |     v                              +----------------+                   |
 |  +---------------+     query       +----------------+                   |
 |  | VMSingle      |<----------------| Grafana        |                   |
 |  | (StatefulSet) |                 | (monitoring/)  |                   |
 |  | storage: 5Gi  |                 +----------------+                   |
 |  +---------------+     query          ^                                 |
 |     ^                  back-fill      |                                 |
 |     | eval rules       recording      |                                 |
 |  +---------------+---------------------+                                |
 |  | VMAlert       |                                                      |
 |  | (Deployment)  |------fire-->+--------------------+                   |
 |  +---------------+             | VMAlertmanager     |---webhook--->     |
 |                                | (StatefulSet)      |                   |
 |                                +--------------------+                   |
 +-----------------------------------------------------|-------------------+
                                                       | wg0 (WireGuard)
                                                       v
                                        homelab Pi: alertmanager-telegram-bridge
                                                       |
                                                       v
                                                 Telegram bot
```

## How the operator reconciles

vmoperator watches six CRD groups: VMSingle, VMCluster, VMAgent, VMAlert,
VMAlertmanager, and the three scrape kinds (VMPodScrape, VMServiceScrape,
VMNodeScrape). For each one it produces:

- **VMSingle / VMCluster** → StatefulSet + PVCs + Service
- **VMAgent** → Deployment + a generated `vmagent-config.yml` Secret with
  the scrape list built from all matching VMPodScrape / VMServiceScrape /
  VMNodeScrape CRs
- **VMAlert** → Deployment + a `vmalert-rules.yml` Secret built from all
  matching VMRule CRs
- **VMAlertmanager** → StatefulSet + Service + a Secret holding
  `alertmanager.yml`

Reconcile loop is identical in shape to Prometheus Operator - watch
Kubernetes API for CR changes, re-render config, replace the Secret,
rolling-update the pod. Where it differs:

| | Prometheus Operator | vmoperator |
|---|---|---|
| CRD group | monitoring.coreos.com | operator.victoriametrics.com |
| Scraper | Prometheus | VMAgent (also exports Prom format) |
| Storage | Prometheus TSDB (local) + Thanos sidecar (optional) | VMSingle or VMCluster (native dedup, native downsampling in Enterprise) |
| HA | 2+ Prometheus + Thanos query | vmselect dedup across vmstorage replicas |
| Memory per 1M active series | ~2 GB | ~400 MB |
| WAL | Yes (bug prone) | No (direct LSM-tree writes) |

Compatibility: VMAgent reads Prometheus's `scrape_config` syntax and
VMAlert reads PrometheusRule's `groups` syntax verbatim, so existing
dashboards + alerts port over without edits. The Prometheus Converter
inside vmoperator (enabled by default) will even auto-translate
PodMonitor / ServiceMonitor / PrometheusRule into VM equivalents at
reconcile time if you want to migrate incrementally.

## Resource budget on OCI Ampere A1 (2 OCPU, 12 GiB)

Measured RSS at steady-state scraping the OCI VM's k3s cluster
(kubelet, node-exporter, kube-state-metrics, plus the Kafka project's
PodMonitor-equivalents = ~400 scrape targets, ~15K active series):

| Pod | Requests | Limits | Observed RSS |
|---|---:|---:|---:|
| vmoperator | 64 MiB | 128 MiB | ~80 MiB |
| vmsingle-main-0 | 256 MiB | 512 MiB | ~300 MiB |
| vmagent-main | 128 MiB | 256 MiB | ~120 MiB |
| vmalert-main | 64 MiB | 128 MiB | ~60 MiB |
| vmalertmanager-main-0 | 32 MiB | 64 MiB | ~50 MiB |
| **Total** | **544 MiB** | **1088 MiB** | **~610 MiB** |

Same scrape surface measured under kube-prometheus-stack on the same VM:

| Pod | Observed RSS |
|---|---:|
| prometheus-monitoring-kube-prometheus-prometheus-0 | ~700 MiB |
| monitoring-kube-prometheus-operator | ~80 MiB |
| alertmanager-monitoring-kube-prometheus-alertmanager-0 | ~55 MiB |
| grafana | (same, shared) |
| **Total** | **~835 MiB** |

Roughly **27% less resident memory** at this scale. The gap widens with
active-series count - VictoriaMetrics ships with built-in cardinality
limiters and its storage engine doesn't keep a per-series mmap page the
way Prometheus TSDB does.

For benchmark methodology and query-latency comparison see
`docs/benchmark.md`.

## Known gaps (v0.1)

- **No HA**: single VMSingle, single VMAgent. Fine for a single-node
  k3s on a free-tier VM, but a real production setup would use
  VMCluster (vmstorage x3 + vminsert x2 + vmselect x2). Scoped out of
  v0.1 to keep the resource footprint honest.
- **No downsampling**: VMSingle in the OSS build keeps full-resolution
  samples for the whole retention window. The Enterprise build has
  native downsampling; the OSS alternative is to layer vmagent -> a
  longer-retention VMSingle at lower scrape rate, planned as v0.3.
- **Prometheus Converter disabled in demo**: vmoperator can auto-create
  VMPodScrape from PodMonitor, which would let both projects coexist on
  the same VM without manual conversion. Turning it on belongs in the
  migration ADR, not v0.1.
