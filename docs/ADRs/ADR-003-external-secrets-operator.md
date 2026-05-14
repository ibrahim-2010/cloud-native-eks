# ADR-003: External Secrets Operator over Manual Secret Management

**Status:** Accepted
**Date:** 2026-05-14
**Deciders:** Platform team

---

## Context

The Nimbus services require sensitive configuration: `JWT_SECRET`, `DATABASE_URL`
(with embedded password), and `REDIS_URL`. These must reach pods as Kubernetes
Secrets. Options evaluated:

| Option | Description |
|---|---|
| A | `kubectl create secret` — manual, run once per deployment |
| B | Sealed Secrets — encrypted secrets committed to Git |
| C | External Secrets Operator (ESO) + AWS Secrets Manager |

## Decision

**Option C** — ESO with AWS Secrets Manager, using IRSA for authentication.

## Rationale

**Option A** was used in Phase 3 as a starting point and immediately showed its
problems: the secret values are entered on the command line (risk of shell history
leak), not version-controlled (risk of loss), and must be re-entered on every fresh
cluster deployment.

**Option B** (Sealed Secrets) keeps encrypted blobs in Git, which is better than
plaintext but requires a cluster-specific master key. Rotating a secret requires
re-encrypting and committing. The encrypted blob is not auditable.

**Option C** (ESO + Secrets Manager) provides:
- Secrets stored in AWS Secrets Manager (audited, versioned, access-controlled via IAM)
- Kubernetes Secrets created and kept in sync automatically by ESO
- Rotation: update in Secrets Manager, ESO refreshes within `refreshInterval` (1h)
- IRSA: the ESO service account assumes an IAM role scoped to `nimbus-cluster/*` secrets only
- Zero plaintext values in Git or shell history

## Consequences

**Positive:**
- Secret rotation does not require any Kubernetes operations
- Full AWS CloudTrail audit trail for every `GetSecretValue` call
- IRSA limits blast radius — ESO can only read secrets under the cluster prefix
- `ExternalSecret` CRs are version-controlled in Git (no sensitive values in the YAML)

**Negative:**
- Adds operational complexity: ESO must be running before services can start
- Secrets must be pre-created in Secrets Manager before first deployment
- ESO sync failure blocks pods from starting if the Kubernetes Secret doesn't exist yet

**Mitigation:** The `creationPolicy: Owner` on `ExternalSecret` means ESO owns the
lifecycle of the Kubernetes Secret. If ESO is unavailable at deploy time, the existing
Secret (from a previous sync) remains intact and pods continue to use it.
