# Capacity harness

This directory documents the earlier base-reserve standalone harness and its
reviewed small non-counted pilot. For the separate account-plus-owner
complete-reserves implementation, use the
[complete-reserves operator runbook](../docs/complete-reserves-operator-runbook.md).
The complete-reserves calibrated executor remains an integration library, and
the full 120-run profile remains disabled and unauthorized.

Status: reviewed native non-counted pilot completed; not approved for counted runs.

The harness runs `rippled` 3.3.0 in standalone mode from immutable image digest `sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70`.

## Isolation

Account secrets and validator credentials are separate concerns. See
[`docs/secrets-and-credentials.md`](../docs/secrets-and-credentials.md) before
running any transaction-capable command.

- `--standalone` disables peer connections and consensus participation.
- The Compose network is `internal` and publishes no host ports.
- Each physical checkout derives a stable `xrpl-reserve-capacity-<12-hex>` Compose project name from its canonical path, so containers, networks, and volumes cannot collide across clones.
- Runtime verification requires the container to have exactly the checkout-specific internal network attachment and requires its recorded network ID to match Docker's inspected network ID.
- The configuration defines no peer listener or seed list.
- Network ID `21338` is outside the well-known Mainnet, Testnet, and Devnet identifiers.
- RPC administration binds only to container loopback.
- Signing support is disabled.
- The container drops Linux capabilities, prevents privilege escalation, uses a read-only root filesystem, and has CPU, memory, PID, and temporary-storage ceilings.

## Architecture and lifecycle gates

The official image is currently `linux/amd64` only. Emulation may support a functional smoke but MUST NOT support counted capacity evidence. `doctor` reports `native_architecture_eligible` independently, exits 2, and always reports:

```text
counted_run_ready=false reason=counted-execution-prerequisites-not-complete remaining_gates=pilot-validation,native-execution
phase2_complete=false remaining_gates=pilot-validation,native-execution,randomized-counted-runs,second-environment-replication,final-review
```

The original `3.1.3` preregistration is byte-for-byte unchanged. A prospective candidate-specific amendment made before pilot or counted data selects XRPLF `3.3.0` as the sole execution target. Material release deltas are candidate factors, not implementation-equivalence evidence, so candidate results cannot be pooled with or generalized to `3.1.3`. The source pins are the official [`3.1.3` release](https://github.com/XRPLF/rippled/releases/tag/3.1.3) and immutable [commit `46b241ace8b30d9c9775d60ffba7d24b21903896`](https://github.com/XRPLF/rippled/commit/46b241ace8b30d9c9775d60ffba7d24b21903896), and the official [`3.3.0` release](https://github.com/XRPLF/rippled/releases/tag/3.3.0) and immutable [commit `00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/commit/00a178fb92ca49521b937ae1a99d863765ea8a90).

Alignment resolution removes only the protocol-reference gate. It does not validate live metrics, complete a pilot, establish native execution, authorize counted execution, merge, release, deploy, or produce results. Native architecture remains an independent diagnostic and cannot change either lifecycle flag; pilot validation and native execution are still required.

The fixed non-counted pilot contract is `capacity/pilot-protocol-v1.yml`. It is a fourth SHA-256-locked input and is copied into each immutable pilot run manifest from the same clean source commit as its digest and closed artifact schemas. The sole profile uses run `r0500000-a000010000-n01`, three deterministic destinations, a 300-second warmup, 900 measurement steps at a two-second interval between ledger advancements, transaction sequences 1/450/900, 901 total samples, and a controlled restart with a 300-second recovery ceiling. The prospective timing amendment allows a maximum one-second target lateness and 1.0-to-3.0-second consecutive completion interval; it replaces the infeasible 0.25-second window after direct measurement of the isolated ledger-advance transport. All prior failed pilot attempts are invalidated and cannot be compared or pooled with a run under this contract. At each scheduled sequence, the harness must sign and submit exactly one `Payment` before advancing one standalone ledger; every unscheduled sequence advances one ledger without a transaction. A standalone restart begins a new ledger chain, so recovery succeeds when the already verified candidate returns a valid validated-ledger response; it does not require the pre-restart ledger hash to persist. Freezing the contract does not run it. Passed, failed, and aborted pilot artifacts all remain candidate-specific and non-counted; native execution and counted authorization remain false.

## Commands

```sh
bin/capacity-harness doctor
bin/capacity-harness smoke
bin/capacity-harness verify
bin/capacity-harness down
XRPL_CAPACITY_CONFIRM_RESET=1 bin/capacity-harness reset
bin/reserve-study capacity-workload --run-id r0500000-a000010000-n01 --full-plan
bin/reserve-study capacity-functional-smoke --run-id r0500000-a000010000-n01 --secret-stdin
bin/reserve-study capacity-non-counted-pilot --run-id r0500000-a000010000-n01 --pilot-accounts 3 --secret-stdin
```

To prepare one non-counted-pilot manifest, run exactly:

```sh
bin/reserve-study capacity-config --run-id r0500000-a000010000-n01
bin/reserve-study capacity-workload --run-id r0500000-a000010000-n01 --pilot-accounts 3
bin/reserve-study capacity-run-manifest --run-id r0500000-a000010000-n01 --pilot-accounts 3
```

That sequence renders the candidate configuration, generates the matching pilot workload, then creates the manifest. `capacity-run-manifest` reads only those fixed run-specific local runtime locations and publishes atomically without overwrite to the ignored local manifest location. It records `manifest_scope: non-counted-pilot`, `counted_run: false`, and `pilot_complete: false`; it neither starts a candidate nor collects metrics, submits a transaction, completes a pilot, or authorizes counted work. Do not invoke it as evidence of a live or completed measurement.

`capacity-config` renders one preregistered candidate `rippled.cfg` into `capacity/runtime/<run_id>/config` by default. It accepts only `--run-id` and `--output-dir`. Before resolving the run, it verifies the checked-out study and canonical configuration bytes against tracked `capacity/candidate-inputs.lock.json`; this remains usable in source archives without Git metadata. Returned metadata includes both verified input hashes and the rendered file checksum. Publication uses a sibling temporary directory and an atomic rename after the file and checksum are complete. Any `--output-dir` must resolve beneath ignored `capacity/runtime/`; the generated configuration is not evidence and does not start a run.

`capacity-workload` resolves only a run in the SHA-256-verified study and publishes deterministic input preparation under `capacity/runtime/<run_id>/workload/`. A pilot requires `--pilot-accounts N` and defaults to `pilot-<9-digit-N>`; `--full-plan` defaults to `full-plan` and emits exactly the preregistered population. Both scopes are explicitly non-counted. Publication is atomic, non-overwriting, restricted to ignored runtime, and contains only `accounts.jsonl`, `manifest.json`, and `SHA256SUMS`.

Destination addresses use the public, keyless `keyless-synthetic-account-id-v1` model: SHA-256 derives a 20-byte AccountID from the locked study identity, locked randomization value, exact planned run, and one-based ordinal. The generator creates no seed, private key, public key, or signing capability. It excludes XRPL's reserved numeric-zero and numeric-one AccountIDs, encodes version byte 0 with the XRPL Base58 alphabet and double-SHA-256 checksum, and emits unsigned Payment intents from the public standalone-genesis address. Pilot records are an exact prefix of full-plan records.

The generated addresses are syntactically valid but intentionally have no generated controlling key. The JSONL records are unsigned input intents, not signed transactions, transaction submissions, successful AccountRoot creations, pilot results, or capacity evidence. The standalone genesis lifecycle is documented in [Start a New Genesis Ledger in Stand-Alone Mode](https://xrpl.org/docs/infrastructure/testing-and-auditing/start-a-new-genesis-ledger-in-stand-alone-mode). The signed `3.3.0` release tag resolves to immutable release commit [`00a178fb92ca49521b937ae1a99d863765ea8a90`](https://github.com/XRPLF/rippled/blob/00a178fb92ca49521b937ae1a99d863765ea8a90/src/libxrpl/protocol/tokens.cpp), whose `tokens.cpp` defines the address-token alphabet and checksum used here. The generator never reads or writes the documented standalone genesis signing secret.

## Sponsor amendment preflight

For consensus-level Sponsor testing, use the separate guarded [private
three-validator network](private-network/README.md). It is the only local
environment in this repository intended to exercise amendment voting; the
standalone candidate remains fail-closed and non-consensus.

Before any Sponsor scenario, run `bin/reserve-study sponsor-preflight`. It
queries only the isolated candidate's `feature` RPC method and fails closed
unless the Sponsor amendment is supported and active. Its output is
non-counted status, not capacity evidence.

The candidate configuration includes the documented 15-minute amendment-majority
window. An operator may request activation with `feature Sponsor accept` when
testing a consensus network, but preflight must still observe `enabled: true`
before any Sponsor transaction is attempted. Standalone mode has no consensus
quorum, so the command alone is not treated as activation.

## Guarded functional smoke

The only transaction-capable command is `capacity-functional-smoke`. Prepare the exact preregistered one-account input first, then run the command shown above. It requires both `--run-id` and the boolean `--secret-stdin`; the only optional path is a contained `--output-dir`. It has no endpoint, Compose-project, container, service, configuration, workload, or secret-file option.

Before it reads signing input, the command validates the locked candidate input, starts a checkout-scoped candidate only if no checkout-scoped resources already exist, and verifies the immutable image, isolated network, exact read-only configuration mount, build `3.3.0`, network ID `21338`, zero peers, zero validation quorum, and rendered candidate reserve. It then reads one nonempty line from standard input (or prompts with terminal echo disabled), signs and submits exactly one transaction, advances the standalone ledger once, and requires validated finality. The authority is never written to a file, command argument, environment variable, Compose or Docker metadata, output, or log.

Every started candidate receives one confirmed checkout-scoped reset attempt after success, engine failure, interruption, timeout, or secret-read failure. The command publishes nothing if that reset fails. After a successful reset it atomically publishes only `execution.json` and `SHA256SUMS` under the contained output directory; the execution record has `execution_scope: functional-smoke`, `counted_run: false`, and `pilot_complete: false`. A validated failed or aborted record is still a nonzero command result and is not pilot or capacity evidence.

This repository does not provide a real authority value or a command-line example containing one. The standalone procedures and RPC semantics are documented by XRPL: [start a standalone genesis ledger](https://xrpl.org/docs/infrastructure/testing-and-auditing/start-a-new-genesis-ledger-in-stand-alone-mode), [sign](https://xrpl.org/docs/references/http-websocket-apis/admin-api-methods/signing-methods/sign), [submit](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/transaction-methods/submit), [ledger_accept](https://xrpl.org/docs/references/http-websocket-apis/admin-api-methods/server-control-methods/ledger_accept), and [advance a standalone ledger](https://xrpl.org/docs/infrastructure/testing-and-auditing/advance-the-ledger-in-stand-alone-mode).

## Guarded non-counted pilot

The sole pilot command is `capacity-non-counted-pilot`, with the exact run, account count, and protected standard-input option shown above. It accepts no endpoint, candidate, Compose project, service, configuration, workload, manifest, output-directory, or authority-value override. Before reading authority input, it verifies the clean source commit; locked study, configuration, protocol, and schema bytes; exact runtime configuration, workload, and manifest; immutable hashes and environment bindings; and the isolated candidate identity. Those bindings are checked again immediately before the protected standard-input read.

The command follows the frozen warmup, 900-step sampling, and three-transaction schedule. Its restart action is limited to the verified candidate service, rejects extra or changed project resources, preserves its data and logs, and requires the exact same identity afterward. Whether the run succeeds, fails, is interrupted, or raises an error after a start attempt, the command erases its in-memory authority and makes exactly one confirmed checkout-scoped reset attempt. Reset failure prevents publication.

Only a complete schema-valid success or complete schema-valid threshold failure can publish the exact immutable five-file set `pilot-result.json`, `transactions.jsonl`, `samples.jsonl`, `metrics-summary.json`, and `SHA256SUMS`. Publication revalidates source and runtime bindings after reset, rejects sensitive or local-identifying content, synchronizes every file and directory boundary, and atomically refuses overwrite. Partial, interrupted, and runtime-error executions publish nothing because they cannot satisfy the frozen complete artifact contract. The protected native 3.3.0 pilot completed successfully; its reviewed evidence is published at [`evidence/capacity-pilots/native-330-run-31692384477`](../evidence/capacity-pilots/native-330-run-31692384477/README.md).

`reset` deletes only the current checkout's Compose project and named experiment volumes, requires explicit confirmation, and does not sweep orphans. Candidate configuration, deterministic workload input generation, metrics reduction, immutable manifest creation, protocol-reference alignment, and the non-counted one-transaction mechanism are implemented. A separately reviewed and authorized counted-run mechanism, 72 randomized counted runs, second-environment replication, and final review remain gates; `counted_run_ready` and `phase2_complete` remain false.
