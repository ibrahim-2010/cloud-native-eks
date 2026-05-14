# ADR-005: Loki over AWS CloudWatch for Log Aggregation

**Status:** Accepted
**Date:** 2026-05-14
**Deciders:** Platform team

---

## Context

The platform needs centralised log aggregation for the five Nimbus services. Options:

| Option | Description |
|---|---|
| A | AWS CloudWatch Logs — managed, native AWS |
| B | Grafana Loki + Promtail — open-source, runs in-cluster |
| C | Elasticsearch/OpenSearch — powerful but heavyweight |

## Decision

**Option B** — Grafana Loki with Promtail as the log shipper.

## Rationale

**CloudWatch** requires deploying the CloudWatch Agent or Fluent Bit as a DaemonSet,
and charges per GB of log data ingested ($0.50/GB) and stored ($0.03/GB/month).
For a capstone with five verbose services, costs accumulate quickly. Log querying
requires switching to the CloudWatch console, breaking the single-pane-of-glass
experience in Grafana.

**Loki** runs inside the EKS cluster at no additional AWS cost. Promtail runs as a
DaemonSet and tails all container log files automatically — zero configuration
required in the application services. Loki integrates natively with Grafana as a
datasource, enabling correlated metrics + logs in the same dashboard panel.

**OpenSearch** (Option C) was ruled out due to resource overhead (minimum 1 Gi RAM
per node) and operational complexity disproportionate to project size.

The `loki-stack` Helm chart bundles Loki + Promtail, reducing the deployment to a
single Helm release.

## Consequences

**Positive:**
- Zero additional AWS cost
- Promtail auto-discovers all pod logs — no per-service config
- LogQL queries available in Grafana Explore alongside Prometheus metrics
- Single observability UI (Grafana) for metrics, logs, and traces

**Negative:**
- Loki uses ephemeral storage (no persistence) in this deployment — logs are lost on
  pod restart. Enabling persistence requires an EBS PVC.
- Loki is not a replacement for a full-text search engine; complex log queries
  are slower than Elasticsearch

**Mitigation:** For a capstone, ephemeral storage is acceptable. In production,
enable `loki.persistence.enabled = true` with a 50 Gi EBS volume for 7-day retention.
