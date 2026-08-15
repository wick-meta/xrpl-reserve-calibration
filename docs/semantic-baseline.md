# Semantic baseline protocol

## Primary references

- [XRPL reserves](https://xrpl.org/docs/concepts/accounts/reserves) defines the base reserve, owner reserve, reserve calculation, and fee-voting relationship.
- [FeeSettings](https://xrpl.org/docs/references/protocol/ledger-data/ledger-entry-types/feesettings) defines the canonical per-ledger fields in integer drops and the fixed ledger-entry index.
- [Public servers](https://xrpl.org/docs/tutorials/public-servers) identifies the endpoint operators used by the version 1 manifest.
- [`rippled` release 3.1.3](https://github.com/XRPLF/rippled/tree/46b241ace8b30d9c9775d60ffba7d24b21903896) pins the reviewed implementation reference.

Mutable documentation links are discovery provenance. The release commit is the immutable implementation reference; neither replaces measurements at an exact ledger.

## Capture rule

1. Call `server_info` once on every required endpoint. The manifest requires at least two distinct documented operators; additional operators are optional.
2. Reject the preflight if any reported ledger is older than 120 seconds, any reported server state is outside the allowlist, or the latest-ledger spread exceeds 50 ledgers.
3. Select the smallest latest-validated ledger index returned by a healthy set.
4. Query the fixed `FeeSettings` ledger entry at that exact index on every endpoint.
5. Preserve each raw response byte-for-byte and record its SHA-256 digest.
6. Compare ledger index, ledger hash, base reserve drops, and reserve increment drops.

`agreed` means every required healthy operator returned the same comparison tuple. A stale or unhealthy required set produces `preflight_rejected`. An exact-query error produces `capture_failed` while retaining completed preflight and exact responses. A disagreement is preserved and blocks the Phase 1 exit gate until dispositioned; it is never resolved by majority vote alone. Optional operators increase redundancy but their availability is not an exit gate.

## Retry and exclusion

The version 1 capture performs no automatic application-level retry. A failed attempt remains local and a new invocation creates a new timestamped bundle. A required endpoint may be replaced only by changing the manifest through documented maintainer review, preserving the prior manifest and documenting why operator independence remains satisfied. An optional endpoint may be promoted by the same process when healthy.

## Reproduction

```sh
bin/reserve-study baseline-set
```

The command refuses to run when tracked files differ from `HEAD` and embeds that exact source commit in the bundle. Output is created beneath `evidence/generated/`, which is ignored until a reviewer checks raw content for secrets and identifying data. Publication requires schema validation and a checksum manifest in a separate reviewed change.
