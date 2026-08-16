# Complete-reserves operator runbook

This runbook separates commands that work today from integration work that an
operator must still supply. Nothing here authorizes counted execution. All
transaction-capable work is restricted to an isolated private XRPL network;
the tooling must never submit reserve-study transactions to Mainnet, Testnet,
Devnet, or a public RPC endpoint.

## Readiness at a glance

| Surface | Available now | Boundary |
|---|---|---|
| Exact-ledger distribution | HTTPS capture or offline import from an operator's indexed Clio, `rippled`, or database dataset | Read-only; a partial public-RPC scan is not accepted |
| Private-network pilot | Reviewed small 3.3.0 non-counted pilot evidence | It is not complete-reserves capacity evidence |
| Population construction | Deterministic AccountRoot construction and transaction recipes for all 20 classified owner-object types | Requires an operator-supplied isolated runtime and signing authority |
| State reset | Verified stopped-state snapshots and one-use clones | Library contract; no turnkey snapshot CLI |
| Duration planning | Measured-only benchmark and deterministic scheduler | Requires observed 10k, 25k, and 50k calibration samples and a 1m disposition |
| Calibration execution | Guarded three-cell executor library with security workloads, recovery, reset, resume, and artifact publication | No live operator runtime adapter or execution CLI is included |
| Full matrix | Frozen 120-item profile and secret-free planning CLI | Execution is hard-disabled and unauthorized |

## 1. Validate a clean clone

Requirements are Ruby 3.3 or newer and, for private-network runtime work,
Docker with Compose. Run:

```sh
bin/check
bin/reserve-study validate
bin/reserve-study complete-reserves-preflight --profile calibrated-v1
bin/reserve-study complete-reserves-preflight --profile full-v1
```

The calibrated preflight reports three cells and `executor_available: true` for
the guarded library contract. The full preflight reports 120 cells,
`executor_available: false`, `timed_floor_seconds: 252000`, and unbounded
provisioning. Both must report `network_scope: isolated-network-only`,
`counted_run: false`, and `execution_authorized: false`.

## 2. Create the exact-ledger distribution

For an indexed local dataset, copy
[`study/operator-owner-object-report-v1.example.json`](../study/operator-owner-object-report-v1.example.json)
outside the repository, fill only its closed aggregate fields, and run:

```sh
bin/reserve-study complete-reserves-import \
  --report /safe/path/operator-owner-object-report.json
```

For an operator-owned HTTPS state endpoint, copy
[`study/operator-local-endpoints-v1.example.yml`](../study/operator-local-endpoints-v1.example.yml)
outside the repository and run:

```sh
bin/reserve-study complete-reserves-distribution \
  --endpoints /safe/path/operator-local.yml
```

The output stays in ignored `evidence/generated/`. One complete, hash-bound
observation is valid `operator_local` input. A matching independent observation
may upgrade it to `independently_corroborated`, but is not required to use the
framework. Never publish database credentials, private endpoints, raw query
results, host identifiers, or personal data.

## 3. Generate profiles without executing transactions

Create a local JSON document containing aggregate totals from the accepted
distribution:

```json
{
  "distribution": {
    "account_roots": 1,
    "owned_objects": 1
  }
}
```

Use real positive totals; the values above only show the closed input shape.
Then generate either profile:

```sh
bin/reserve-study complete-reserves-profile \
  --profile calibrated-v1 --json-stdin < /safe/path/profile-input.json

bin/reserve-study complete-reserves-profile \
  --profile full-v1 --json-stdin < /safe/path/profile-input.json
```

These commands only calculate deterministic cells. They do not start a node,
read a secret, create an account, or authorize execution.

## 4. Measure provisioning before scheduling

The full-profile benchmark accepts only observed isolated-network samples at
10k, 25k, and 50k AccountRoots, with owner objects scaled from the frozen
distribution. A 1m sample is optional, but the benchmark always requires an
explicit 1m checkpoint:

- `measured`, bound to the 1m sample artifact; or
- `not_measured`, with exactly one of `not-yet-executed`,
  `operator-resource-limit`, or `calibration-failed`.

The benchmark input contains `distribution`, its SHA-256, the candidate
SHA-256, the observed samples, and `one_million_checkpoint`:

```sh
bin/reserve-study complete-reserves-benchmark \
  --profile full-v1 --json-stdin < /safe/path/benchmark-input.json \
  > /safe/path/benchmark.json
```

The output reports measured resource maxima and non-binding provisioning
ranges. It deliberately keeps `provisioning_bounded: false`,
`provisioning_seconds: null`, and `completion_seconds: null`. The known full
matrix minimum is only the fixed 252,000 seconds of warmup and measurement:
70 serial hours before provisioning, snapshots, clones, recovery, or any
operator-approved rerun.

## 5. Build the deterministic schedule

The planning input contains the same distribution and hashes, the exact
benchmark record, measured available resources, and zero or more verified
resume records. The resource object declares logical CPUs, memory bytes, free
disk bytes, and read/write I/O bytes per second.

```sh
bin/reserve-study complete-reserves-plan \
  --profile full-v1 --json-stdin < /safe/path/plan-input.json \
  > /safe/path/schedule.json
```

The scheduler rejects resources below the observed calibration maxima, orders
all 120 items deterministically and exclusively, and accepts a resumed item
only when its result hash and reset/recovery confirmations bind to that exact
schedule item. A successful planning command does not make the matrix
executable.

## 6. Operator runtime integration boundary

Live calibration requires an operator integration that is not bundled as a
turnkey command. It must provide:

1. a commit- and image-pinned isolated XRPL candidate with no public endpoint
   selection;
2. a concrete loopback HTTPS/mTLS transaction channel and exact private-network
   identity response;
3. an ephemeral signer pool and funded synthetic source accounts inside that
   isolated network;
4. deterministic AccountRoot and owner-object construction through validated
   transactions, never direct database injection;
5. clean stop, verified state-image capture, read-only restart at the same
   ledger identity, and a separate one-use clone for each run/repetition;
6. measured CPU, memory, disk, I/O, close-time, finality, queue, transaction,
   reset, and recovery records; and
7. an explicit deadline, batch ceiling, zero retries for calibration items,
   and enough capacity to respect every declared resource limit.

The guarded executor accepts only a calibrated item that is an exact member of
a reverified, checksummed planning bundle. It rejects public or missing network
identity, stale artifacts, unmatched snapshots/clones, missing security
ceilings, full-profile items, counted mode, and authorization changes before it
reads signing authority. Signing authority is supplied at execution time from
protected standard input or an equivalently protected in-memory operator
boundary; it must never enter Git, argv, environment variables, files, Docker
metadata, logs, exceptions, or published artifacts.

## 7. Snapshots, recovery, resume, and provenance

Runtime files are contained below ignored `capacity/runtime/complete-reserves/`:

- `snapshots/<snapshot-id>/` holds an actual stopped-state image, file manifest,
  exact candidate/study/distribution/config/source bindings, and verified ledger
  identity;
- `clones/` holds run-and-repetition-bound, one-use clone images;
- `planning/<schedule-sha256>/` holds `benchmark.json`, `bindings.json`,
  `calibration.json`, `schedule.json`, `security.json`, and `SHA256SUMS`; and
- `executions/<run-id>/` holds `bindings.json`, `metrics.json`, `result.json`,
  `resume.json`, `security.json`, and `SHA256SUMS`.

A resume record is valid only after both reset and recovery are confirmed and
the published execution payload hash still verifies. Failed, partial, stale,
or modified artifacts do not become resumable successes. Runtime directories
may contain local machine state and are ignored by Git; review and sanitize any
proposed public evidence separately.

## 8. Stop conditions

Stop without claiming evidence if any exact hash, ledger identity, candidate
identity, distribution count, class allocation, resource ceiling, security
gate, finality result, reset, recovery, or artifact checksum fails. Also stop if
the 1m checkpoint has no explicit disposition or observed provisioning is not
bounded well enough for the operator to accept the risk.

The tracked authorization remains false. No counted complete-reserves evidence
has been collected, and no reserve-policy change is recommended.
