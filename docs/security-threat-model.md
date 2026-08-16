# Overview

XRPL Reserve Calibration is a local research toolkit that captures read-only public-ledger observations, generates deterministic experimental inputs, operates a disposable standalone `xrpld` environment, and publishes reproducible evidence for reserve-policy analysis. It is not a wallet, public service, validator operator, governance automation system, or production transaction client.

The primary runtime surfaces are `bin/reserve-study`, the Ruby library under
`lib/xrpl_reserve_study`, `bin/capacity-harness`, and the isolated Compose
configurations. Complete-reserves adds a concrete loopback HTTPS/mTLS channel,
ephemeral signer pool, state-image snapshot and one-use clone boundary,
measured scheduler, guarded calibration executor, and checksummed planning and
execution bundles. Capacity execution is security-sensitive because it
introduces signing and submission, even though the only allowed destination is
a pinned isolated network.

Security objectives are to prevent any transaction from reaching Mainnet, Testnet, Devnet, or an operator-selected endpoint; prevent signing material from entering source control, command arguments, environment variables, logs, artifacts, exceptions, process listings, or Docker metadata; preserve immutable study/config/workload provenance; constrain destructive cleanup to the checkout-specific Docker project; and ensure preliminary transaction acceptance is never reported as validated success.

# Threat Model, Trust Boundaries, and Assumptions

## Assets and privileges

- Operator signing material, including any standalone-genesis secret supplied at runtime.
- The host Docker daemon and the ability to create, inspect, stop, and delete checkout-scoped resources.
- The invariant that public-network observation remains read-only.
- The invariant that transaction-capable code can target only a fixed,
  identity-verified isolated network and never an operator-selected endpoint.
- Preregistered study inputs, run ordering, candidate configuration, generated workloads, recorded outcomes, checksums, and lifecycle labels.
- Host filesystem integrity outside ignored `capacity/runtime/`.
- Public-repository integrity: no secrets, private infrastructure identifiers, personal paths, or misleading readiness claims.

## Trust boundaries

1. **Operator to CLI:** command names, run IDs, counts, paths, confirmation flags, timeouts, and standard input are operator-controlled and can be malformed or accidentally unsafe.
2. **Public RPC to observer:** HTTPS responses are attacker-controlled untrusted data. The observer is restricted to fixed read-only methods and must remain transaction-incapable.
   A local full-history indexer or operator database may provide an
   `operator_local` frozen distribution when it retains exact-ledger and
   query/result-digest provenance. The aggregate importer accepts no endpoint,
   credential, query text, raw database result, hostname, or private path. A matching second operator report upgrades the
   evidence tier; a local index is not trusted merely because it is local.
3. **Repository to runtime:** tracked study/config/lock bytes are developer-controlled but may drift; runtime use requires exact SHA-256 verification.
4. **Generated artifacts to executor:** JSONL, manifests, and checksums are untrusted until schema, containment, exact-file-set, run-identity, network-identity, scope, and digest checks pass.
5. **Host to Docker daemon:** Docker is privileged infrastructure. The harness assumes the local daemon and pinned image content are within the operator's administrative trust boundary, but does not trust unrelated containers, networks, volumes, labels, or paths.
6. **Host process to isolated container:** signing requests cross this boundary only through standard input to a fixed checkout-scoped container and its loopback admin RPC. Secrets must not cross through argv, environment, files, Compose interpolation, or persistent output.
7. **Open ledger to validated ledger:** a successful submission response is preliminary. Only a deterministic `ledger_accept` followed by validated transaction and AccountRoot queries can establish final outcomes.
8. **Runtime output to public evidence:** runtime records are not evidence merely because they exist. Publication requires schema/provenance checks and an explicit later lifecycle gate.
9. **State image to run clone:** a snapshot is trusted only after a clean stop,
   manifest verification, read-only restart at the same ledger identity, and
   exact candidate/study/distribution/config/source binding. Every clone is
   bound to one run and repetition and consumed once.
10. **Planning bundle to executor:** a self-hashed item is insufficient. It
    must be an exact member of the reverified `calibration.json` bundle and
    retain all benchmark, schedule, security, snapshot, ledger, and resource
    bindings.

## Assumptions

- The operator controls the workstation and Docker daemon; compromise of either can observe process memory and is outside the repository's ability to contain.
- The pinned `xrpld` image digest and Docker engine enforce the declared container/network configuration.
- Capacity commands run only from an unmodified checkout whose locked inputs validate.
- No production credential is ever supplied. A signing input is authorized only for the documented standalone genesis account and only after isolation verification succeeds.
- Emulated `amd64` execution on an `arm64` host is permitted for functional, explicitly non-counted development only.
- CI has no signing input and does not execute transaction-capable integration paths.

# Attack Surface, Mitigations, and Attacker Stories

## Transaction redirection

An operator option, environment variable, compromised manifest, or path could attempt to redirect submission to a public endpoint or a different container. Transaction execution must expose no endpoint option, must derive a fixed checkout-specific Compose identity, must resolve exactly one running container, and must re-verify image digest, standalone mode, build version, network ID, zero peers, zero validation quorum, no published ports, and exact internal-network attachment before reading signing input or constructing a transaction.

## Secret disclosure

Secrets in argv can appear in process listings; environment variables can appear in process and container metadata; files can persist or be committed; sign-and-submit errors can echo input. The allowed interface is explicit secret-on-standard-input after preflight. It must reject terminal input unless the operator explicitly chooses an interactive prompt that disables echo, never accept secret flags/files/environment variables, never include the secret in exceptions or logs, redact exact input from all captured responses, and submit only the signed `tx_blob` after a separate signing step. Raw signing responses are not artifacts.

## Workload/config substitution and path attacks

Symlinks, traversal, concurrent replacement, alternate study files, edited JSONL, reordered records, duplicate destinations, mismatched run IDs, excessive counts, or stale candidate configuration could invalidate results or expand work. Existing descriptor-anchored publication, no-follow traversal, atomic no-replace rename, and locked input checks remain mandatory. Execution additionally validates exact artifact sets and checksums, binds workload and configuration to one preregistered run, caps the functional smoke count, and reads files through descriptor-bound handles or an equivalent ancestry/identity check.

## Unsafe execution volume and denial of service

Unbounded submission, retries, queues, sleeps, or output capture could exhaust CPU, memory, disk, descriptors, or ledger capacity. Every RPC and process action needs a deadline; batches and total transactions need hard caps; counted retries are forbidden; functional execution must fail closed on unexpected preliminary results; existing Docker CPU, memory, PID, tmpfs, and disk-abort controls remain in force. A failure or interrupt must attempt checkout-scoped teardown without sweeping unrelated Docker resources.

The read-only public distribution path is separately bounded by endpoint
response and pagination limits. It must not turn an unavailable public gateway
into unbounded retries or an indefinite workstation job. Indexed aggregate
reports are preferred when a full-tree public-RPC read has no bounded duration.

The full 120-run profile has a 70-hour timed floor before provisioning. Because
provisioning is unbounded until observed calibration samples exist, the full
profile remains rejected by the guarded executor. The measured scheduler
rejects inadequate CPU, memory, disk, or I/O declarations; planning output is
not permission to execute.

## Incorrect finality or evidence claims

`status=success`, `accepted=true`, or `tesSUCCESS` from `submit` does not prove a validated result. The executor must advance the standalone ledger explicitly, query each transaction from a validated ledger, confirm `meta.TransactionResult=tesSUCCESS`, confirm the destination AccountRoot exists at the expected validated ledger, and record failures without converting them to success. Functional-smoke artifacts remain `counted_run=false` and cannot satisfy pilot or matrix gates.

## Command and serialization injection

Run IDs, addresses, amounts, and paths could be interpreted by a shell or malformed JSON. Runtime code must use argument arrays rather than shell interpolation, canonical JSON serialization, strict address/amount/network validation, bounded response parsing, and fixed RPC method allowlists. No generated value may become a command name, endpoint, Compose project, container name, or host path outside the runtime root.

## Cleanup confusion

Malicious labels or naming collisions could cause deletion of unrelated resources. Project identity remains derived from the canonical checkout path. Destructive reset requires explicit confirmation and uses only `docker compose --project-name <derived> ... down --volumes`; no global prune, orphan sweep, wildcard, or user-provided project identifier is permitted.

## Supply-chain and CI

Mutable images, actions, or dependencies could alter results or exfiltrate inputs. The image and CI actions are pinned by digest/commit, Ruby runtime code uses the standard library, CI tokens are read-only, and CI receives no signing material. Transaction integration tests use controlled fakes unless explicitly run locally against the isolated node.

Realistic attackers include a contributor supplying malicious input artifacts, an operator making a dangerous CLI mistake, an unrelated local Docker project colliding with loose cleanup logic, and malformed public RPC responses. A remote attacker directly invoking the local capacity executor is out of scope because no service or host port is exposed. Host-root or Docker-daemon compromise is also out of scope, but the tool must not make such compromise easier through persistent secrets or broad deletion.

# Severity Calibration (Critical, High, Medium, Low)

## Critical

- A reachable path that can submit a transaction to Mainnet, Testnet, Devnet, or an operator-controlled endpoint.
- Committing, persisting, printing, or publishing a production-capable seed/private key.
- Broad destructive cleanup capable of deleting unrelated host data or Docker projects without an exact confirmation boundary.

## High

- Signing input exposed through argv, environment, Docker metadata, logs, artifacts, or unredacted exceptions.
- Isolation verification bypass that allows execution against a container with published ports, extra networks, peers, a wrong network ID, or an unpinned image.
- Workload/config substitution that permits execution outside the preregistered run or beyond hard transaction caps.
- Reporting preliminary submission as validated success or counted evidence.

## Medium

- Missing timeouts, bounded parsing, or teardown on a transaction-capable path that can hang or exhaust the constrained local environment.
- Incomplete outcome capture that loses failed/aborted dispositions while remaining explicitly non-counted.
- Symlink or race behavior confined to ignored runtime storage without secret disclosure or external transaction reachability.

## Low

- Ambiguous operator diagnostics that do not weaken an authorization gate.
- Documentation/provenance drift that is caught before execution and cannot alter runtime behavior.
- Test-only portability or cleanup-residue defects confined to temporary local artifacts.

Source note: this execution slice was designed against this threat model.
