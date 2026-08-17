# Capacity metrics protocol v1

`capacity-metrics-protocol-v1` defines the closed measurement record and summary
contract for capacity evidence. It consumes the locked study data, one
post-warmup sample, and an ordered nonempty sequence of measurement samples.
All elapsed, CPU, and controlled-restart recovery durations use a monotonic
clock.

Each `capacity-metric-sample-v1` record contains exactly:

| Field | Meaning |
| --- | --- |
| `schema_version` | `capacity-metric-sample-v1` |
| `phase` | `post-warmup` or `measurement` |
| `sample_sequence` | Nonnegative integer sequence number |
| `elapsed_seconds` | Finite, nonnegative monotonic elapsed seconds |
| `validated_ledger_index` | Positive validated ledger index |
| `validated_ledger_hash` | Exact validated-ledger hash, uppercase hexadecimal |
| `ledger_close_time` | Nonnegative Ripple-epoch close time |
| `ledger_state_bytes` | Complete decoded binary state-object bytes for the exact hash |
| `database_bytes` | Apparent bytes of regular files in the database |
| `resident_memory_bytes` | `/proc/1/status` `VmRSS` bytes |
| `memory_current_bytes` | Bytes used by the candidate cgroup |
| `memory_limit_bytes` | Fixed candidate cgroup limit: 17179869184 bytes |
| `process_cpu_seconds` | Finite, nonnegative process CPU seconds |
| `allocated_logical_cpus` | Fixed allocation: 4 |
| `free_disk_bytes` | Free bytes from `statvfs` for the data volume |
| `disk_total_bytes` | Positive total bytes from that `statvfs` result |

The reducer rejects malformed, incomplete, non-finite, non-monotonic, or
inconsistent inputs rather than correcting them. Its seven and only seven
operationalizations are:

| Metric | Operationalization |
| --- | --- |
| `ledger_bytes` | Measurement-end `ledger_state_bytes` minus post-warmup `ledger_state_bytes`. |
| `database_bytes` | Measurement-end `database_bytes` minus post-warmup `database_bytes`. |
| `resident_memory_bytes` | Maximum measurement-sample `resident_memory_bytes`. |
| `cpu_utilization_ratio` | Change in `process_cpu_seconds` divided by measurement elapsed seconds and the fixed four allocated logical CPUs. |
| `ledger_close_seconds` | Monotonic elapsed deltas between adjacent validated-ledger samples, summarized by count, minimum, maximum, p50, and p95. |
| `transaction_success_ratio` | Validated successful account-creation transactions divided by attempted transactions. |
| `recovery_seconds` | Monotonic elapsed time from controlled restart start until validated-ledger tracking resumes. |

Ledger-close percentiles use nearest rank: sorted value at `ceil(p * N) - 1`.

## Time windows and validation

The locked workload has a 300-second warmup and an 1800-second minimum
measurement period. The post-warmup snapshot must be at or after 300 seconds;
the final measurement snapshot must be at least 1800 seconds later. Sample
sequence, elapsed time, validated ledger index, CPU time, ledger-state bytes,
and database bytes must progress monotonically; each validated ledger hash is
bound to only one index. The sample schema is closed: the exact fields in the
table above are required and unknown fields are rejected.

## Summary schema

`capacity-metrics-summary-v1` is a closed object with these required fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | `capacity-metrics-summary-v1`. |
| `metric_protocol_version` | `capacity-metrics-protocol-v1`. |
| `sample_count` | Number of measurement snapshots. |
| `post_warmup_ledger_index`, `measurement_end_ledger_index`, `measurement_elapsed_seconds` | Measurement boundary and duration. |
| `metrics` | The seven operationalized values above. |
| `resource_minima` | Minimum free-memory ratio, free-disk ratio, and free-disk bytes observed during measurement. |
| `thresholds`, `thresholds_passed` | Per-threshold operator, limit, observed value, pass result, and their conjunction. |
| `abort_rule_breaches` | Stable breach codes only. |

The thresholds are success ratio at least 0.99, p95 close interval at most 5.0
seconds, recovery at most 300 seconds, and minimum free-memory and free-disk
ratios of at least 0.10. The only abort codes are `ledger-close-seconds`,
`resident-memory-bytes`, and `free-disk-bytes`; their locked limits are 30
seconds, 17179869184 resident-memory bytes, and 10737418240 free-disk bytes.

## Manifest binding and evidence status

`capacity-run-manifest-v1` is a closed, immutable-after-publication local
record for a non-counted pilot. It binds the locked study and configuration,
workload hashes, source commit, run identity and order, the 300/1800-second
windows, candidate runtime `3.3.0`, metric names, thresholds, abort rules,
normalized environment fields, and SHA-256 hashes of this protocol document
and both metric schemas. Its `environment` field contains exactly
`docker_server_version`, `host_architecture`, `host_operating_system`,
`host_logical_cpus`, `host_memory_bytes`, `candidate_image_digest`,
`candidate_image_architecture`, and `native_architecture_eligible`. It excludes
paths, hostnames, usernames, addresses, and signing material.

The same source capture includes the locked `capacity-pilot-protocol-v1`
semantics and the SHA-256 hashes of its YAML record, sanitized transaction
schema, and complete pilot-result schema. The frozen profile requires one
`Payment` to be signed and submitted before the absolute advancement target at
each scheduled measurement sequence 1, 450, and 900. Unscheduled steps advance
one ledger without a transaction. The target cadence is 2.0 seconds on the
monotonic clock, with at most 1.0 second of target lateness. Consecutive
observed ledger-advancement completions must be between 1.0 and 3.0 seconds.
A missed start or completion window aborts before any later catch-up. Exactly
901 ordered samples include the post-warmup sample, and controlled recovery
within 300 seconds succeeds only when validated-ledger tracking resumes. These
bindings define how a future non-counted pilot is evaluated; they are not live
metric or pilot evidence.

In a pilot result, `sample_count` is the number of fully captured samples and
includes the post-warmup sample. `transaction_count` is the number of scheduled
`Payment` transactions that completed validated finality. Because a scheduled
step signs and submits before advancement and captures after advancement, an
interruption can increase the validated transaction count before the matching
sample count increases.

Pilot-result dispositions are conditionally closed:

| Disposition | Status | Samples / transactions | Thresholds / abort / recovery |
| --- | --- | --- | --- |
| `success` | `passed` | 901 / 3 | true / false / true |
| `threshold-failure` | `failed` | 901 / 3 | false / false / true |
| `validation-failure` | `failed` | 901 / 3 | false / false / false |
| `incomplete` | `failed` | 0 / 0 | false / false / false |
| `abort-rule-breach` | `aborted` | 1/0; 2–450/1; 451–900/2; 901/3 | false / true / false |
| `interrupted` | `aborted` | 0/0; 1/0–1; 2–449/1; 450/1–2; 451–899/2; 900/2–3; 901/3 | false / false / false |
| `runtime-error` | `aborted` | 0/0; 1/0–1; 2–449/1; 450/1–2; 451–899/2; 900/2–3; 901/3 | false / false / false |

Every schema-valid disposition requires confirmed reset and validated source,
manifest, and environment bindings. Only `success` sets `pilot_complete: true`;
every disposition fixes counted authorization and native establishment to false.
Abort rules are checked only after capture, so an abort record has one exact
validated-Payment count for each sample-count range. Interruption and runtime
errors additionally permit the narrow after-validation, before-capture windows
at sample counts 1, 450, and 900.

The original `3.1.3` preregistration remains byte-for-byte unchanged. Before
pilot or counted data, a prospective candidate-specific amendment selected
XRPLF `3.3.0` as the sole execution target. The manifest binds the immutable
alignment bytes and records `protocol_alignment.status:
resolved-prospectively`, the amendment method, its SHA-256, explicit
non-equivalence and no-cross-version-use declarations,
`counted_execution_authorized: false`, and the remaining `pilot-validation`
and `native-execution` gates. Material release deltas are candidate factors,
not implementation-equivalence evidence; results cannot be pooled with or
generalized to `3.1.3`.

The source pins are the official [`3.1.3`
release](https://github.com/XRPLF/rippled/releases/tag/3.1.3) at immutable
[commit
`46b241ace8b30d9c9775d60ffba7d24b21903896`](https://github.com/XRPLF/rippled/commit/46b241ace8b30d9c9775d60ffba7d24b21903896)
and the official [`3.3.0`
release](https://github.com/XRPLF/rippled/releases/tag/3.3.0) at immutable
[commit
`00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/commit/00a178fb92ca49521b937ae1a99d863765ea8a90).
Alignment resolution does not validate live metrics, complete a pilot,
establish native execution, authorize counted execution, merge, release,
deploy, or produce results. The manifest remains ignored local output and is
not pilot completion, counted authorization, counted execution, or metric
evidence.

The reducer, schemas, and manifest boundary were later exercised by the
reviewed pinned 3.3.0 non-counted pilot. That candidate-specific bundle is not
complete-reserves provisioning, calibration, counted-matrix, or policy
evidence. No live complete-reserves metric bundle has been collected.

The guarded pilot orchestrator revalidates immutable source and runtime
bindings before authority input and again after its one confirmed reset
attempt. It permits publication only for a complete schema-valid success or
complete schema-valid threshold failure, writes exactly the five contracted
files with synchronized atomic no-overwrite publication, and publishes no
partial, interrupted, or runtime-error artifact set. These are implementation
and fake-boundary properties, not evidence from a live candidate.

The protocol applies the locked study's warmup, duration, acceptance thresholds,
and abort rules exactly. An abort breach is reported only with one of the stable
codes `ledger-close-seconds`, `resident-memory-bytes`, or `free-disk-bytes`.

## Complete-reserves conformance

Before any capacity run, the isolated-only complete-reserves program executes
closed conformance recipes for reserve responsibility and release. Cases cover
one- and two-sided trust-line responsibility, the first two trust lines,
ordinary owner objects, NFToken page packing, insufficient-reserve rejection,
and deletion/release. Each record contains observed balance and `OwnerCount`
transitions, terminal finality, and cleanup finality. These conformance records
are non-counted implementation evidence; public network submission is
prohibited.

The deletion/release case is specified separately by
`study/account-delete-lifecycle-v1.yml` and
`schemas/account-delete-observation-v1.schema.json`. It must distinguish the
base reserve, owner-reserve release, and AccountDelete's special burned fee;
the latter is at least one owner-reserve increment and is charged even for a
validated deletion failure. It also records deletion blockers, the 1,000-object
limit, the sequence replay guard, balance transfer, cleanup finality, and
ledger/database deltas. It remains non-counted and authorization-disabled.
