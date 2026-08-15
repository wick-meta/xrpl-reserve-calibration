# Phase 2 harness foundation verification

This review records the earlier 3.2.1 harness snapshot for provenance. The
current reserve candidate is 3.3.0; its Sponsor-specific calibration state is
documented in [the supplemental plan](../sponsor-calibration-plan-v1.md) and
must not be pooled with these historical observations.

Date: 2026-08-04

Lifecycle state: functional foundation and deterministic workload input preparation verified; integration calibration failed closed with teardown complete, and the final exact CLI local standalone smoke passed one transaction end to end. Counted-run readiness remains blocked on native execution architecture and later execution/metrics slices.

## Verified runtime

- Image: `xrpllabsofficial/xrpld:3.2.1`
- Immutable digest: `sha256:12352a54543e972ecf806eac4317bffdf4168131b889b9601a0a31d91d44a5ef`
- Reported server version: 3.2.1
- Mode: standalone
- Network ID: 21338
- Peer count: 0
- Validation quorum: 0
- RPC: loopback-only HTTP, no published host ports
- Reference reserve: 1 XRP base and 0.2 XRP increment

Docker inspection confirmed the container is attached to exactly its checkout-specific internal non-attachable network and that the attachment records the inspected network ID. It also confirmed image-native unprivileged UID/GID 997, a read-only root filesystem, all Linux capabilities dropped, privilege escalation disabled, a 16 GiB memory ceiling, four-CPU ceiling, 512-PID ceiling, and no host port mappings. Each physical checkout derives a stable path-hashed Compose project identity, preventing resource-name collisions across clones.

The guarded reset removed the exact checkout-scoped Compose container, internal network, and two experiment volumes created by the smoke without an orphan sweep.

## Counted-run blocker

The image is `linux/amd64`; the current workstation reports `aarch64`. Docker emulation is acceptable for functional smoke tests but invalid for counted performance measurements. `bin/capacity-harness doctor` reports architecture eligibility separately as `native_architecture_eligible=false` and exits 2 with `counted_run_ready=false`. On a native host it reports `native_architecture_eligible=true` but still exits 2 with `counted_run_ready=false`; architecture eligibility cannot authorize counted execution while later execution, metrics, manifest, pilot-validation, replication, and review gates remain open.

Before counted execution, the project must use native amd64 capacity or separately build, pin, and review a native arm64 image from the same source commit. Candidate-specific configuration rendering is implemented: `bin/reserve-study capacity-config --run-id <planned-run-id>` resolves a run only after the checked-out study and canonical configuration match tracked SHA-256 locks, renders `rippled.cfg` atomically under ignored `capacity/runtime/`, and reports the verified input hashes plus its output checksum. `--output-dir` is restricted to that ignored runtime root. This generated configuration is not evidence and does not start a run.

Deterministic input preparation for `accountroot-create-and-hold-v1` is also implemented. `bin/reserve-study capacity-workload` supports an explicitly sized non-counted pilot or the exact planned account population. It publishes public, keyless destination AccountIDs and unsigned Payment intents atomically under ignored runtime, with a closed manifest and checksums. No seed, key, signature, or transaction submission is created. Pilot output is prefix-stable against the full plan. The address format follows `tokens.cpp` at immutable release commit [`d4c1359921f34a4e96c5c8483119e59f0e30e4df`](https://github.com/XRPLF/rippled/blob/d4c1359921f34a4e96c5c8483119e59f0e30e4df/src/libxrpl/protocol/tokens.cpp), resolved from the signed `3.2.1` release tag, and the source account lifecycle is described by the official [standalone-genesis documentation](https://xrpl.org/docs/infrastructure/testing-and-auditing/start-a-new-genesis-ledger-in-stand-alone-mode).

## Guarded functional-smoke mechanism

Integration attempts failed closed during transport, API-shape, and readiness calibration, with teardown complete. The final exact CLI local standalone functional smoke then passed one transaction end to end. Before reading standard-input authority material it validates locked inputs, no pre-existing checkout-scoped Docker resources, immutable image and isolation, the exact read-only candidate configuration mount, build `3.2.1`, network `21338`, zero peers, zero validation quorum, and candidate reserve. It then signs, submits, advances one standalone ledger, validates finality, attempts only the confirmed checkout-scoped reset, and atomically writes a sanitized `execution.json` and `SHA256SUMS` only after reset succeeds.

The authority boundary is stdin-only (no-echo on a terminal); no seed-shaped material is stored in repository content, runtime output, Docker/Compose metadata, arguments, files, or environment. The generated runtime artifact is intentionally ignored and local, not committed evidence. The command is always `execution_scope: functional-smoke`, `counted_run: false`, and `pilot_complete: false`. It is not a completed pilot or capacity result and establishes no public-network, PR-ready/merge, release, deployment, or production outcome; counted-run prerequisites and remaining phases stay separate.

Metrics capture, run manifests, non-counted pilot calibration, native execution, 72 counted runs, second-environment replication, and final review remain unimplemented or unverified. Counted-run readiness remains false, and workload or functional-smoke artifacts are not evidence of pilot completion or counted/capacity execution.
