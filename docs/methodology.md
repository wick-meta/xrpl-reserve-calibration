# Methodology

## Question

What combination of AccountRoot base reserve and owner reserve best reduces
access cost without creating unacceptable capacity, abuse-resistance, or
operational risk?

## Evidence classes

1. **Semantic evidence:** protocol behaviour and the reserve parameters observed at an exact validated ledger.
2. **Capacity evidence:** controlled measurements over a preregistered matrix of reserve settings, account counts, workloads, and repeated runs.
3. **Economic evidence:** transparent scenario calculations over published population assumptions and sensitivity ranges.
4. **Decision evidence:** a falsifiable synthesis that records unmet gates, dissent, and residual uncertainty.

Evidence classes are not interchangeable. A successful test does not validate an economic assumption, and a lower modelled access cost does not prove operational safety.

## Complete-reserves program

The complete-reserves program adds separate base-reserve and owner-reserve
studies plus combined corner checks: 48 base cells, 48 owner cells, and 24
combined cells, each with three repetitions. Evidence-grade scales are 1.0x,
1.25x, 1.5x, and 2.0x of a frozen hash-bound distribution. Workload classes
are allocated by largest remainder with ascending class-name ties. These 120
runs have a five-minute warmup and thirty-minute measurement window; operators
must report the distribution evidence tier and snapshot construction
calibration separately from capacity evidence, and must never pool results
across environments.

The earlier version-1 base-reserve matrix remains preserved as historical,
base-only work. Its 72-run shape and non-counted pilot do not replace the
frozen owner-object distribution, the 120-run complete-reserves matrix, or
the combined-reserve checks described here.

### Frozen-distribution acquisition paths

The default public-RPC collector uses two declared HTTPS operators and emits
the stronger `independently_corroborated` tier when they agree. An operator-local
manifest may declare one HTTPS endpoint and emits `operator_local` when its
hash-bound capture completes. The collector is self-contained but can be slow
for a full state tree. The same frozen-distribution bundle may instead be
produced by either of the following operator-grade paths:

1. A locally indexed full-history `rippled` or Clio dataset, using a
   hash-pinned state query or aggregate query at one validated ledger hash.
2. An independent operator's node or database, using the same hash-pinned
   query and classifier contract.

For either indexed path, create a local closed
`operator-owner-object-report-v1` JSON file and run
`complete-reserves-import --report /safe/path/report.json`. The command makes
no network request and writes the existing distribution bundle under ignored
`evidence/generated/`. The report records the dataset type, exact ledger
index/hash, classifier version, normalized counts, and SHA-256 digests of the
operator's retained query and result. It must not carry raw query/result data,
credentials, a private endpoint, hostname, user, path, address, or location.

Every path must record the validated ledger index and hash, operator identity,
query/result SHA-256 values, classifier version, AccountRoot total, and
owner-object class totals. The distribution bundle derives the deterministic
largest-remainder allocation. One declared operator with these bindings may
produce a valid `operator_local` study input. Exact agreement from another
declared operator upgrades it to `independently_corroborated`. An aggregate
report without the bindings is informative only and cannot replace the frozen
study input.

#### Public-RPC feasibility boundary

The public-RPC full-tree path is a correctness reference, not the recommended
production acquisition method. `ledger_data` exposes a continuation marker but
does not expose a total-entry or remaining-page count. A scan therefore has no
reliable completion estimate before its terminal page. It is also exposed to
ordinary public gateway failures and must not be restarted indefinitely on a
commodity workstation. Do not treat a partial scan or a progress log as a
frozen distribution bundle. A complete one-operator capture is valid only at
the `operator_local` tier and must retain its full provenance.

Independent reproduction is encouraged for every study and upgrades the
evidence tier when normalized counts agree exactly. It is not a prerequisite
for an operator to run the framework using its own indexed dataset. Each
operator must retain enough query provenance to reproduce its report.

## Capacity design

The version 1 matrix contains four reserve settings and six account-count cells, producing 24 cells. Every cell requires three independent repetitions, for 72 planned runs. Run order must be randomized from the committed seed. Failed runs remain in the dataset.

Primary measurements are ledger growth, database growth, resident memory, CPU utilization, close time, transaction success rate, and recovery behaviour. Acceptance thresholds must be fixed before execution.

The original `3.1.3` preregistration remains byte-for-byte unchanged. Before pilot or counted data, a prospective candidate-specific amendment selected XRPLF `3.3.0` as the sole execution target. Material changes between those releases are candidate-specific factors, not implementation-equivalence evidence. Results cannot be pooled with or generalized to `3.1.3`. The source pins are the official [`3.1.3` release](https://github.com/XRPLF/rippled/releases/tag/3.1.3) at immutable [commit `46b241ace8b30d9c9775d60ffba7d24b21903896`](https://github.com/XRPLF/rippled/commit/46b241ace8b30d9c9775d60ffba7d24b21903896) and the official [`3.3.0` release](https://github.com/XRPLF/rippled/releases/tag/3.3.0) at immutable [commit `00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/commit/00a178fb92ca49521b937ae1a99d863765ea8a90).

The alignment resolves only the reference gate. It does not validate live metrics, complete a pilot, establish native execution, authorize counted execution, merge, release, deploy, or produce results. Pilot validation and native execution remain prerequisites; the matrix, three repetitions per cell, seed, metrics, thresholds, abort rules, and disposition policy are unchanged.

The non-counted pilot protocol is frozen separately in `capacity/pilot-protocol-v1.yml`. It uses only the representative planned run `r0500000-a000010000-n01`, exactly three deterministic keyless destinations, 300 seconds of warmup, and 900 measurement steps at an absolute monotonic target cadence of 2.0 seconds. A target may be observed at most 1.0 second late. Consecutive observed ledger-advancement completions must remain within 1.0 through 3.0 seconds. Transaction ordinals 1, 2, and 3 occur at measurement sequences 1, 450, and 900. A scheduled step signs and submits exactly one `Payment` before its target, then advances exactly one standalone ledger; an unscheduled step advances one standalone ledger without a transaction. Missing the start or completion window aborts before any later catch-up advancement. Each sample is captured after its advancement and binds to an exact validated ledger index and hash. One post-warmup sample plus 900 measurement samples produces exactly 901 ordered samples. The timing allowance was prospectively amended before a successful pilot because the isolated transport's measured ledger-advance boundary exceeds 0.25 seconds; all earlier failed pilot attempts are invalidated and are not evidence.

After measurement, the pilot requires a controlled restart and recovery within the unchanged 300-second limit. Recovery succeeds only when validated-ledger tracking resumes on the verified candidate. A passing record additionally requires three validated successful transactions, schema-valid samples and metrics, no abort breach, all thresholds passed, confirmed reset, and exact source, manifest, and environment bindings. The protocol is candidate-specific and non-counted. It cannot establish native execution or authorize counted work.

The guarded implementation enforces the order: immutable input validation, candidate start and identity verification, binding revalidation, protected authority read, warmup and scheduled sampling, valid-ledger recovery after the bounded identity-preserving restart, reduction, in-memory authority erasure, exactly one confirmed reset attempt, post-reset binding revalidation, schema validation, then durable atomic publication. A standalone restart begins a new ledger chain, so recovery proves resumed validated-ledger tracking on the verified candidate rather than persistence of the pre-restart ledger hash. Only a complete success or complete threshold failure can satisfy the frozen artifact contract and publish its exact five files. Partial, interrupted, and runtime-error executions publish nothing. This implementation and fake-boundary verification are not live pilot execution or metric evidence.

## Economic model

For a scenario with `accounts` AccountRoot objects and `owned_objects` owner-reserve objects:

```text
locked_xrp = accounts * base_reserve_xrp
           + owned_objects * owner_reserve_xrp
```

The model reports levels and deltas; it does not label locked XRP as destroyed or permanently unavailable. Distributional analysis should segment new users, custodial platforms, high-object accounts, infrastructure operators, and abuse scenarios.

## Reproducibility

Every evidence record must identify the study version, source commit, software version, network identity, run identifier, repetition, parameters, timestamps, and checksums for raw artifacts. Exclusions require a machine-readable reason.
