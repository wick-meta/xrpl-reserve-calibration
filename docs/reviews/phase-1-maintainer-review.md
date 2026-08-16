# Phase 1 maintainer self-review

> **Historical / superseded:** This review records the earlier Phase 1 design
> and its 72-run matrix. The current study uses the complete-reserves design
> documented in the [methodology](../methodology.md) and the staged operator
> sequence in the [README](../../README.md). This file is retained for
> provenance and must not be read as the current execution plan or evidence.

Reviewer: `wick-meta` project maintainer, performed with Codex assistance

Date: 2026-08-03

Scope: study specification, semantic sources, baseline implementation, evidence bundle, schemas, and Phase 1 exit gate

Review type: maintainer self-review; not independent external review

## Disposition

Accepted for preregistration and merge after required CI passes. No external reviewer or contributor is required. Optional later review must be recorded separately and must not be described as having occurred here.

## Checklist

- [x] Candidate base reserves are explicit: 1, 0.5, 0.25, and 0.1 XRP.
- [x] Current reference base reserve is explicit: 1 XRP.
- [x] Matrix size is deterministic: four reserve settings by six account counts by three repetitions, or 72 counted runs.
- [x] Every metric has an operational definition.
- [x] Counted runs cannot be retried in place and every run requires a disposition.
- [x] Thresholds and abort rules are fixed before counted execution.
- [x] Capacity execution is restricted to isolated ephemeral networks.
- [x] Mainnet capability is read-only and method-allowlisted.
- [x] The canonical per-ledger `FeeSettings` entry is queried in integer drops.
- [x] The accepted baseline uses two documented independent operators at one exact validated ledger.
- [x] Raw responses, source commit, and SHA-256 checksums are preserved.
- [x] Existing v1 observation schema is unchanged; the exact-ledger observation is v2.
- [x] Unhealthy optional endpoints do not block completion and are not silently counted.

## Threshold rationale

The 99% transaction-success floor detects material workload failure while retaining failed transactions as evidence. The 5-second p95 ledger-close ceiling reflects the upper bound of the normal close-time range used by the study. The 300-second recovery ceiling bounds operational restart impact. Ten-percent free-memory and free-disk floors preserve minimum headroom; absolute abort ceilings remain emergency safety controls rather than evidence of acceptance.

These are preregistered decision rules, not claims that the candidates are safe. Phase 2 results may pass or fail them. Changing a threshold after counted execution begins requires a new study version and cannot reinterpret version 1 results.

## Limitations and conflicts

This review is author-controlled and therefore does not provide independent assurance. Public endpoint operator identity comes from a mutable documentation registry; exact response integrity comes from the preserved ledger hash and raw-response digests. No capacity, economic, or policy conclusion is established by Phase 1.
