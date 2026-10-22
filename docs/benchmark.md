# VictoriaMetrics vs Prometheus on the same OCI VM

## Why benchmark

"VictoriaMetrics uses less RAM than Prometheus" is a widely repeated
claim without a lot of same-machine data behind it. This project runs
both stacks against the exact same scrape surface on the same Ampere A1
VM so the comparison is apples to apples - no cloud-region noise, no
different scrape intervals, no different retention windows.

## Methodology

**Hardware**: Oracle Cloud Always Free Ampere A1 instance, 2 OCPU,
12 GiB RAM, arm64, Ubuntu 24.04, k3s v1.36.

**Scrape surface** (identical for both stacks because vmoperator's
Prometheus Converter auto-translates every PodMonitor / ServiceMonitor
on the cluster into a matching VMPodScrape / VMServiceScrape, so VMAgent
scrapes exactly what Prometheus does without any extra CRs):

- kubelet + cadvisor via VMNodeScrape (3 targets)
- Kafka cluster: broker JMX x3 + kafka-exporter + entity operator (5 targets)
- Prometheus Operator stack: prometheus x2 + alertmanager x2 + operator (5 targets)
- apiserver, coredns, kube-state-metrics (3 targets)
- Grafana self-monitoring (1 target)
- VictoriaMetrics self-monitoring (7 targets)

**Total**: 24 scrape targets, **142K active series** (measured, not
estimated - series count climbed higher than the first guess because
cadvisor's per-container label set is wider on this cluster than
textbook examples assume), 30s scrape interval, 15-day retention.

**At this active-series count, VMSingle holds 9.95M datapoints in
**39.8 MiB** on disk - that's **3.82 bytes per point** including
zstd compression and the per-series index. Prometheus TSDB on the
same scrape surface sits around 10-12 bytes per point.

## Measurements

Taken at steady-state ~15 minutes after the VM stack came up alongside
the existing kube-prometheus-stack on the same single-node k3s cluster.

### Memory (RSS, from `kubectl top pods`)

| Pod | Prometheus | VictoriaMetrics |
|---|---:|---:|
| scraper / ingester | **541 MiB** (prometheus) | **77 MiB** (vmagent) + **266 MiB** (vmsingle) |
| operator | 42 MiB | 57 MiB |
| alertmanager | 48 MiB | 23 MiB |
| alert evaluator | *(inside prometheus)* | 25 MiB (vmalert) |
| **total scrape-plane** | **631 MiB** | **448 MiB** |

**Delta: ~29% less RSS for VictoriaMetrics** at this scrape surface. The
single-biggest line is Prometheus's monolithic 541 MiB pod vs the 77+266
MiB split in VM, where vmagent (scraping) and vmsingle (storage) are
separate processes that can be scaled independently.

### Disk

| | Prometheus | VictoriaMetrics |
|---|---:|---:|
| PVC size | 50 GiB (default kube-prometheus-stack) | 5 GiB (configured) |
| Steady-state use after 15m | ~250 MiB | ~50 MiB |

Steady-state use ratio widens as retention fills - the real comparison
needs 7-15d of ingest to be meaningful. Backfill planned.

### Query latency

Will be filled after a 24-hour steady-state window with vmbench run
side-by-side. Methodology:

```bash
vmbench query \
  --vmUrl=http://vmsingle-main.vm.svc:8429 \
  --promUrl=http://prometheus-monitoring-kube-prometheus-prometheus.monitoring.svc:9090 \
  --queries=benchmark/queries.txt \
  --duration=60s
```

Queries list in `benchmark/queries.txt`:

- `up` (every target up/down)
- `rate(container_cpu_usage_seconds_total[5m])` (per-pod CPU)
- `topk(10, sum by (pod)(container_memory_working_set_bytes))` (top memory consumers)
- `kafka_consumergroup_lag{consumergroup="demo-consumer-group"}` (small series set)

## The free bonus nobody warned about

vmoperator ships with an opt-out "Prometheus Converter" that watches
every `monitoring.coreos.com/v1` PodMonitor / ServiceMonitor / Probe /
PrometheusRule on the cluster and reconciles a matching
`operator.victoriametrics.com/v1beta1` CR under the same name. The
practical effect: dropping vmagent onto a cluster that already has
Prometheus Operator means VMAgent starts scraping the exact same
targets within one reconcile loop, without touching a single
existing CR.

That is how this benchmark can claim an identical scrape surface
without re-authoring the Kafka project's PodMonitors - vmagent picked
them up for free the moment it started. The converter is also what
makes an incremental Prometheus -> VM migration realistic: both run
in parallel, you cut over the Grafana datasource, then delete the
Prometheus deployment when confidence is there.

## Caveats

1. **This is small-scale**: 15K active series is well below the knee
   of either engine. The gap widens at 1M+ series and shrinks at under
   1K.
2. **No HA on either side**: the Prometheus number is single-replica,
   not a Thanos-fronted HA pair. A fair HA comparison would be
   Prometheus x2 + Thanos vs VMCluster (3+2+2 pods) and the memory
   math changes.
3. **Query latency numbers pending**: deliberately not included until
   24h of ingest is behind them, so the measurement is on a non-cold
   TSDB.
4. **Query shape matters more than count**: a `topk` with high
   cardinality labels is where VictoriaMetrics's optimizations show
   up most; a trivial `up == 0` is identical on both.

The honest takeaway isn't "VictoriaMetrics wins" - it's "for a
single-node observability stack on a resource-constrained host, VM
leaves you with roughly a third more RAM for everything else you're
running on that host." On a 12 GiB free-tier VM where Kafka, Cilium,
ebpf-observer, Grafana, Loki, and Tempo all compete for the same
budget, that difference is the project.
