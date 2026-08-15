# XRPL Reserve Calibration

XRPL Reserve Calibration is an independent, open-source research project for evaluating XRPL base- and owner-reserve policy options with reproducible measurements, explicit uncertainty, and conservative decision gates.

The project separates four kinds of evidence:

1. protocol semantics and current network parameters;
2. controlled capacity measurements;
3. ecosystem and economic impact modelling; and
4. a decision brief that states whether the evidence supports a change.

Complete-reserves calibration uses a hash-pinned current-state distribution
covering both AccountRoot and owner-reserve objects. A serial public-RPC
full-tree scan is supported as a correctness reference but is not the
recommended production path because it has no total-page estimate and can be
interrupted by public gateway limits. An operator can use its own indexed
Clio/`rippled` dataset or database to produce a hash-bound `operator_local`
report. A matching report from another operator upgrades the bundle to
`independently_corroborated`; it is not required to use the framework. This
remains read-only and never submits to a public network.

## What works now / what is not yet executable

### Works now

- An operator can create and import a hash-bound, exact-ledger owner-object
  distribution from its own indexed Clio, `rippled`, or database dataset. This
  path is read-only, can remain entirely local, and does not require a second
  operator to use the framework.
- The bounded private-network pilot has been exercised at its deliberately
  small, non-counted scope. It is an isolated mechanism check, not a reserve
  recommendation or capacity result.
- The deterministic study inputs, distribution classifier, model, safety
  checks, schemas, and offline validation are available for review and reuse.

### Not yet executable

- The complete-reserves 120-run matrix is a frozen study design, **not** a
  turnkey executor. It remains disabled, has no full population/snapshot/clone
  executor, and has collected no counted capacity evidence.
- The matrix's five-minute warmup and thirty-minute measurement window impose
  a **70-hour serial timed minimum** (120 runs × 35 minutes). Population
  construction, verified snapshots/clones, recovery, and retries are extra;
  their duration is intentionally not claimed until a calibrated run measures
  them.
- Neither the existing authorization record nor this documentation authorizes
  a full-matrix run. A full executor must first prove deterministic population
  construction, equivalent fresh state for repetitions, bounded resource use,
  recovery, and artifact integrity in a realistic non-counted calibration.

This staging protects the operator and the study's validity, not XRPL Mainnet:
capacity work is limited to an isolated private network. Until the execution
model is measured, a large run could exhaust the operator's CPU, memory, disk,
or I/O; fail to create equivalent starting states; or yield invalid comparisons
because a partial clone, workload, or recovery changed one run's conditions.
No public-network reserve-study transactions are permitted.

## Current status

| Capability | State |
|---|---|
| Versioned study specification | Preregistered final in Phase 1 PR |
| Exact-ledger, multi-operator Mainnet baseline capture | Verified at ledger 106034050 in Phase 1 PR |
| Deterministic economic model | Implemented |
| Controlled capacity harness | Guarded isolated harness; the protected native 3.3.0 non-counted pilot passed and its reviewed artifact is published |
| Metrics reducer and non-counted-pilot manifest | Validated by the reviewed native non-counted pilot; counted execution remains unauthorized |
| Protocol-reference alignment | Resolved prospectively for the sole `3.3.0` execution target; counted execution remains unauthorized |
| Non-counted pilot mechanism | Completed successfully as candidate-specific, non-counted isolated evidence; counted execution remains unauthorized |
| Multi-run capacity evidence | Not collected |
| Policy recommendation | `insufficient_evidence`; no change recommended |
| Complete-reserves program | Disabled implementation contract; no counted data collected |

An implemented tool is not evidence that a reserve change is safe. The current decision brief is [`docs/decision-brief-v1.md`](docs/decision-brief-v1.md); it records `insufficient_evidence`, not a reserve recommendation. The project cannot recommend a change until the preregistered capacity matrix, repeat runs, uncertainty analysis, and documented maintainer review are complete. Optional external review is reported separately and is not a completion dependency.

The functional-smoke artifact and prospective preparation outputs are intentionally local and ignored; they are not committed evidence. The completed non-counted pilot bundle is reviewed evidence at [`evidence/capacity-pilots/native-330-run-31692384477`](evidence/capacity-pilots/native-330-run-31692384477/README.md). Neither a smoke nor a pilot establishes counted authorization, counted execution, replication, final review, release, deployment, or production outcome; these remain separate lifecycle states.

The original `3.1.3` preregistration remains byte-for-byte unchanged. Before any pilot or counted data, the project added a prospective candidate-specific amendment selecting XRPLF `3.3.0` as the sole execution target. Material release deltas are candidate factors, not evidence that `3.1.3` and `3.3.0` are implementation-equivalent; results may not be pooled across or generalized to `3.1.3`. The pinned sources are the official [`3.1.3` release](https://github.com/XRPLF/rippled/releases/tag/3.1.3) at immutable [commit `46b241ace8b30d9c9775d60ffba7d24b21903896`](https://github.com/XRPLF/rippled/commit/46b241ace8b30d9c9775d60ffba7d24b21903896) and the official [`3.3.0` release](https://github.com/XRPLF/rippled/releases/tag/3.3.0) at immutable [commit `00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/commit/00a178fb92ca49521b937ae1a99d863765ea8a90).

Alignment resolution does not validate live metrics, complete a pilot, establish native execution, authorize counted execution, merge, release, deploy, or produce results.

The frozen non-counted pilot contract selects the sole representative run, exactly three keyless destinations, a 300-second warmup, 900 measurement steps at two-second intervals between ledger advancements, and transaction sequences 1, 450, and 900. A scheduled step signs and submits one `Payment` before its one advancement; an unscheduled step advances without a transaction. Controlled recovery succeeds only when validated-ledger tracking resumes. Run manifests bind the validated protocol and both closed pilot artifact schemas to one clean source commit. This contract is candidate-specific and cannot establish native execution or authorize counted work.

The guarded implementation accepts only `capacity-non-counted-pilot --run-id r0500000-a000010000-n01 --pilot-accounts 3 --secret-stdin`. It revalidates the clean source, locked inputs, fixed runtime bundle, manifest, schemas, and normalized environment before reading the authority; performs exactly one checkout-scoped reset attempt after any start attempt; and publishes only a complete, schema-valid five-file bundle after reset and a second binding check. Partial, interrupted, invalid, or reset-unconfirmed work is not published. Implementation and synthetic verification are not live pilot evidence.

The 3.3.0 candidate also has a supplemental Sponsor calibration matrix in
[`docs/sponsor-calibration-plan-v1.md`](docs/sponsor-calibration-plan-v1.md).
The private three-validator amendment-state smoke is complete and recorded in
[`evidence/sponsor-private-network-330`](evidence/sponsor-private-network-330/README.md).
The scenarios remain non-counted until their transaction, boundary, cleanup,
and artifact gates pass.

## Safety boundary

- The network observer permits HTTPS only and exposes two hard-coded read-only RPC methods: `server_info` and `ledger_data`.
- The guarded functional-smoke command can construct, sign, submit, and validate exactly one transaction only against its verified isolated standalone container. It cannot select a public endpoint or alternate Docker target, and it is not a pilot or capacity evidence.
- Signing authority is accepted only at execution time from standard input with terminal echo disabled. It is never accepted in an argument, file, environment variable, Compose metadata, output, or log.
- Capacity experiments belong on isolated ephemeral networks, never Mainnet.
- Generated evidence is treated as untrusted input and must pass schema and provenance checks.
- CI receives read-only repository permissions and does not execute network observations.

See [docs/safety.md](docs/safety.md) before running any network-facing command.
Credential classes, secret-handling boundaries, and the complete local
workflow are documented in [docs/secrets-and-credentials.md](docs/secrets-and-credentials.md).

## Quick start

Requirements: Ruby 3.3 or newer. Runtime code uses only the Ruby standard library. Phase 2 harness work additionally requires Docker with Compose.

```sh
bin/check
bin/reserve-study validate
bin/reserve-study capacity-plan
bin/reserve-study model
```

The capacity preparation sequence is documented in [capacity/README.md](capacity/README.md). It creates only ignored local inputs and a non-counted-pilot manifest; it does not start a daemon, complete a pilot, authorize counted execution, or establish metric accuracy on the pinned candidate. Metric definitions and record schemas are in [docs/metrics-protocol-v1.md](docs/metrics-protocol-v1.md).

To capture a fresh read-only public-network baseline:

```sh
bin/reserve-study baseline --endpoint https://s1.ripple.com:51234
bin/reserve-study baseline-set
```

The single-endpoint command prints JSON to standard output. The set command writes an ignored evidence directory and prints a status summary. Review generated files before proposing any evidence for publication.

The accepted Phase 1 baseline and maintainer review are published at [evidence/baselines/mainnet-106034050](evidence/baselines/mainnet-106034050/README.md) and [docs/reviews/phase-1-maintainer-review.md](docs/reviews/phase-1-maintainer-review.md).

## Research sequence

The complete sequence and its gates are in [docs/roadmap.md](docs/roadmap.md). Method definitions are in [docs/methodology.md](docs/methodology.md). Contributions are welcome under [CONTRIBUTING.md](CONTRIBUTING.md).

## Most useful contribution now

The complete-reserves capacity study is intentionally disabled until its
frozen input distribution exists. The immediate public contribution is
[the current prerequisite issue](https://github.com/wick-meta/xrpl-reserve-calibration/issues/2):
an operator with an indexed XRPL dataset can produce a reproducible,
hash-bound aggregate report for the study. A second matching operator report
is welcome as corroboration, but is not required to use the framework. A
contribution does **not** require submitting a transaction, operating a public
service, or publishing database access or credentials.

Each imported report contains only the ledger index and hash, declared
operator, dataset type, query and result SHA-256 values, classifier version,
`AccountRoot` total, and owner-object class totals. It deliberately excludes
the raw query/result, database credentials, private endpoint, host identity,
and personal data. Do not submit a partial public-RPC scan as the study input.
See the [methodology](docs/methodology.md#frozen-distribution-acquisition-paths)
and [contribution guidance](CONTRIBUTING.md#complete-reserves-distribution-contributions)
for the acceptance rules.

An operator using its own HTTPS endpoint can copy
[`study/operator-local-endpoints-v1.example.yml`](study/operator-local-endpoints-v1.example.yml)
outside the repository, replace its placeholders, and run:

```sh
bin/reserve-study complete-reserves-distribution \
  --endpoints /safe/path/operator-local.yml
```

The resulting bundle stays under ignored `evidence/generated/`; review it
before deciding whether to publish its sanitized aggregate report.

An operator who has an indexed Clio, `rippled`, or database dataset but no
public HTTPS state endpoint can instead create the closed local report from
[`study/operator-owner-object-report-v1.example.json`](study/operator-owner-object-report-v1.example.json), then import it without any network request:

```sh
bin/reserve-study complete-reserves-import \
  --report /safe/path/operator-owner-object-report.json
```

The importer writes the same ignored distribution-bundle form and labels a
single observation `operator_local`. A matching independent bundle may be
recorded later as `independently_corroborated`; it is not required to run the
framework.

## License

MIT. See [LICENSE](LICENSE).
