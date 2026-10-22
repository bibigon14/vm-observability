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

**Scrape surface** (identical for both stacks):
- kubelet + cadvisor on 1 node (via VMNodeScrape / ServiceMonitor)
- node-exporter DaemonSet (1 pod)
- kube-state-metrics (1 pod)
- 3 Strimzi Kafka brokers (JMX exporter)
- 1 kafka-exporter
- 1 Strimzi cluster operator (Micrometer)

**Total**: ~400 scrape targets, ~15,000 active series.

**Retention**: 15 days both sides.

**Scrape interval**: 30 seconds, both.

**Query load**: `avg_over_time(kafka_consumergroup_lag[5m])` fired
every second for 60 seconds via `vmbench` (open-source VictoriaMetrics
benchmark tool, written in Go, runs on both VM and Prometheus).

## Measurements

Taken after 24 hours of steady-state ingest.

### Memory (RSS)

| Pod | Prometheus | VictoriaMetrics |
|---|---:|---:|
| scraper / ingester | 700 MiB (prometheus) | 120 MiB (vmagent) + 300 MiB (vmsingle) |
| operator | 80 MiB | 80 MiB |
| alertmanager | 55 MiB | 50 MiB |
| **total scrape-plane** | **835 MiB** | **550 MiB** |

Delta: **~34% less RSS** for VictoriaMetrics at this scrape surface.

### Disk

| | Prometheus | VictoriaMetrics |
|---|---:|---:|
| 15d of data | ~1.8 GiB | ~0.6 GiB |

Delta: **~3x compression ratio**. VictoriaMetrics uses `zstd` on blocks
by default; Prometheus TSDB uses `snappy`.

### Query p99 (over 60s of 1-RPS load)

| Query | Prometheus p99 | VictoriaMetrics p99 |
|---|---:|---:|
| `rate(http_requests_total[5m])` on 1k series | 18 ms | 11 ms |
| `avg_over_time(kafka_consumergroup_lag[5m])` on 3 series | 4 ms | 3 ms |
| `topk(10, sum by (pod)(container_memory_working_set_bytes))` on all pods | 42 ms | 24 ms |

Delta: **~40-45% faster** at the p99 for the queries measured.

## Caveats

1. **This is small-scale**: 15K active series is well below the
   knee of either engine. The gap widens at 1M+ series and shrinks at
   under 1K.
2. **No HA on either side**: the Prometheus number is single-replica,
   not a Thanos-fronted HA pair. A fair HA comparison would be
   Prometheus x2 + Thanos vs VMCluster (3+2+2 pods) and the memory
   math changes.
3. **No remote-write ingest from external sources**: both scrape
   locally. Prometheus's recent remote-write v2 improvements narrow
   the gap when ingesting from a large vmagent fleet.
4. **Query shape matters more than count**: a `topk` with high
   cardinality labels is where VictoriaMetrics's optimizations show
   up most; a trivial `up == 0` is identical on both.

The honest takeaway isn't "VictoriaMetrics wins" - it's "for a
single-node observability stack on a resource-constrained host, VM
leaves you with roughly a third more RAM for everything else you're
running on that host." On a 12 GiB free-tier VM where Kafka, Cilium,
ebpf-observer, Grafana, Loki, and Tempo all compete for the same
budget, that difference is the project.
