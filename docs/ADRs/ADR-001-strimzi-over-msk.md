# ADR-001: Strimzi over Amazon MSK for Kafka

**Status:** Accepted
**Date:** 2026-05-14
**Deciders:** Platform team

---

## Context

The NimbusRetail platform requires an Apache Kafka cluster for asynchronous event
streaming between auth-service (producer: `users.registered`) and order-service
(producer: `orders.created`) to notification-service (consumer).

Two options were evaluated:

| Option | Description |
|---|---|
| Amazon MSK | AWS managed Kafka service |
| Strimzi | CNCF-graduated Kafka operator for Kubernetes |

## Decision

**Use Strimzi** to run Kafka as pods inside the EKS cluster.

## Rationale

**Cost:** MSK has a minimum cost of approximately $450/month even at the smallest
broker instance size (`kafka.t3.small` × 3 brokers). Strimzi runs inside the
existing EKS node group at no additional AWS cost.

**Project alignment:** The NimbusRetail project specification explicitly lists
Strimzi as an approved approach for Kafka.

**Cloud-native fit:** Strimzi is CNCF-graduated and uses Kubernetes-native CRDs
(`Kafka`, `KafkaNodePool`). The cluster CR is version-controlled in Git and
deployed by ArgoCD — consistent with the GitOps pattern used for all other
workloads.

**KRaft mode:** Strimzi 0.42+ supports KRaft (no ZooKeeper), which matches the
local development setup (`apache/kafka:3.7.2` in docker-compose).

## Consequences

**Positive:**
- Zero additional AWS cost
- Consistent GitOps deployment model
- Kafka configuration is version-controlled
- Operator handles rolling upgrades and broker rebalancing

**Negative:**
- Kafka competes with application pods for node resources (3 brokers × 512 Mi RAM)
- No built-in cross-AZ replication managed by AWS
- Operator upgrades must be managed manually (Helm release version pin)

**Mitigation:** Kafka pods have explicit resource requests/limits; t3.xlarge nodes
(4 vCPU, 16 GiB) have sufficient capacity for 3 brokers alongside 5 application pods.
