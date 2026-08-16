# Safety model

## Trust boundaries

Public RPC responses, experiment output, contributor-provided files, and generated JSON are untrusted. They are parsed with bounded inputs, validated before analysis, and never executed.

## Network observation

The observer accepts an HTTPS endpoint, uses fixed `server_info` and `ledger_data` JSON-RPC request bodies, limits response size, applies connection and read timeouts, and rejects malformed responses. It does not accept arbitrary RPC method names. CI does not call public endpoints.

Public endpoints are convenient observation sources but are not authoritative by themselves. Every usable distribution must be bound to an exact validated ledger and provenance. Independent reproduction is encouraged and upgrades the evidence tier; it is not required for an operator-local study.

The local aggregate-report importer makes no network request. It accepts only
a bounded regular JSON file with a closed field set: ledger binding, operator
identifier, dataset type, classifier version, counts, and query/result
digests. It rejects extra fields, credential-like material, and unsafe
evidence URLs. Raw database output, query text, hostnames, paths, private
addresses, and credentials remain outside the repository and generated bundle.

## Capacity experiments

Capacity work must use disposable, isolated networks with no route to production credentials. Runtime containment enforces resource ceilings and an explicit network identity check. The earlier base-reserve workload preparation creates keyless synthetic AccountIDs. Complete-reserves population construction instead uses an ephemeral deterministic signer pool because AccountRoots and owner objects must be created through validated transactions. Those signer values exist only in mutable process memory, are wiped after each use, and cross only the verified loopback HTTPS/mTLS private-network channel; they are never committed or published.

Complete-reserves execution additionally requires exact membership in a
checksummed calibration plan, a private-network identity bound to the pinned
candidate, an exact-ledger verified snapshot, a run-and-repetition-bound
one-use clone, declared transaction/deadline ceilings, and the fixed security
workloads. Public, missing, stale, counted, full-profile, or self-invented items
are rejected before signing authority is read.

Metrics and manifests are local, immutable-after-publication runtime outputs and are ignored by version control. A manifest binds locked configuration and workload hashes, source commit, candidate runtime, normalized environment fields, the metric-protocol document and schema hashes, thresholds, abort rules, and the immutable prospective alignment record. The normalized environment is limited to Docker server version, host architecture and operating-system class, logical CPUs, memory bytes, candidate image digest and architecture, and native-architecture eligibility; it must not contain a hostname, username, filesystem path, address, or signing material.

The original `3.1.3` preregistration remains byte-for-byte unchanged. Before pilot or counted data, a prospective candidate-specific amendment selected XRPLF `3.3.0` as the sole execution target. Material release deltas are candidate factors rather than implementation-equivalence evidence, and results cannot be pooled with or generalized to `3.1.3`. The source pins are the official [`3.1.3` release](https://github.com/XRPLF/rippled/releases/tag/3.1.3) at immutable [commit `46b241ace8b30d9c9775d60ffba7d24b21903896`](https://github.com/XRPLF/rippled/commit/46b241ace8b30d9c9775d60ffba7d24b21903896) and the official [`3.3.0` release](https://github.com/XRPLF/rippled/releases/tag/3.3.0) at immutable [commit `00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/commit/00a178fb92ca49521b937ae1a99d863765ea8a90). Manifests record the resolved prospective status, no-equivalence and no-cross-version-use declarations, the alignment digest, `counted_execution_authorized: false`, and the remaining pilot-validation and native-execution gates.

Alignment resolution does not validate live metrics, complete a pilot, establish native execution, authorize counted execution, merge, release, deploy, or produce results.

The immutable non-counted pilot protocol is a fourth locked candidate input. Its parser rejects aliases, duplicate keys, extra documents, changed ordering or values, and non-regular, oversized, or changed files. Run manifests copy the validated protocol semantics and hash the protocol plus both pilot artifact schemas from one verified clean source commit. The frozen step contract permits exactly one `Payment` on a scheduled sequence, signs and submits it before one ledger advancement, and permits no transaction on an unscheduled advancement. Cadence is measured between ledger advancements, and restart recovery requires resumed validated-ledger tracking.

The artifact schemas are closed: unknown signing, private, host, path, or location fields cannot validate. Every result disposition has exact status, count, threshold, abort, recovery, reset, and binding invariants. `sample_count` counts fully captured samples including post-warmup, while `transaction_count` counts fully validated scheduled Payments. Partial-run branches couple those counts to the exact sequences 1, 450, and 900; abort checks occur after capture, while interruption/runtime records allow only the exact post-validation, pre-capture boundary windows. A threshold failure records the full 901 samples and three transactions with recovery, reset, and bindings confirmed, while thresholds are false and no abort breach occurred. A result can set `pilot_complete: true` only when its status is `passed` and every frozen success condition is true; `counted_execution_authorized` and `native_execution_established` remain false for passed, failed, and aborted records.

Freezing these contracts performs no transaction and starts no candidate. The guarded pilot mechanism now implements protected standard-input authority handling, bounded execution, identity-preserving restart, exactly one confirmed reset attempt after any start attempt, post-reset binding revalidation, and durable atomic local publication. Its tests use fake boundaries and do not constitute execution evidence.

The earlier pinned 3.3.0 non-counted pilot has reviewed isolated evidence. No
live complete-reserves calibration, measured provisioning bundle, full-matrix
run, or counted complete-reserves evidence exists. Implemented preparation,
fake-boundary verification, pilot completion, calibration, counted
authorization, counted execution, replication, final review, release, and
deployment are distinct states. None is evidence for another.

Generated workload records are unsigned intents and are always marked `counted_run: false`. Syntactic address acceptance does not establish that an AccountRoot exists. Generation does not sign, submit, advance a ledger, complete a pilot, or produce capacity evidence. The generator never reads or writes the standalone genesis secret documented by [XRPL's standalone-genesis procedure](https://xrpl.org/docs/infrastructure/testing-and-auditing/start-a-new-genesis-ledger-in-stand-alone-mode). Its public address encoding follows `tokens.cpp` at immutable release commit [`00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/blob/00a178fb92ca49521b937ae1a99d863765ea8a90/src/libxrpl/protocol/tokens.cpp), resolved from the signed `3.3.0` release tag.

The separate `capacity-functional-smoke` mechanism may sign, submit, and validate exactly one transaction only after fixed isolated-container checks pass. It cannot target Mainnet, Testnet, Devnet, an operator-selected endpoint, or an alternate Compose resource. It accepts the standalone authority only through `--secret-stdin`: a terminal prompt uses no-echo input, while a pipe must contain one bounded newline-terminated value. The authority is not accepted from argv, a file, the environment, Compose, Docker metadata, output, or logs. The command validates finality after exactly one standalone-ledger advancement, attempts only its confirmed checkout-scoped reset, and publishes a sanitized outcome only after reset succeeds. The outcome is explicitly `functional-smoke`, non-counted, and not a pilot.

## Secrets and privacy

The base-workload generator requires no secret. Transaction-capable functional
smoke, pilot, and complete-reserves calibration paths require separately
supplied isolated-network authority only at live execution time; this
repository contains none. `.env` files and generated runtime output are ignored
by default. Evidence intended for publication must be reviewed for hostnames,
usernames, paths, tokens, IP addresses, and other identifying data.

## Non-goals

This project does not submit transactions to public XRPL networks, manage validators, vote on amendments or fees, or automate governance decisions.
