# Contributing

Contributions to code, experiment design, documentation, and independent replication are welcome.

## Before opening a pull request

1. Open or join an issue that states the claim, scope, and acceptance evidence.
2. Fork the repository and create a focused branch.
3. Run `bin/check` locally.
4. Explain methodology changes and their effect on comparability.
5. Identify generated artifacts, their source commit, environment, and checksums.

Pull requests should be small enough to review, contain tests for changed behaviour, and avoid unrelated formatting changes. A documented maintainer review and passing required checks are expected before merge. The author may perform the maintainer review when no other maintainer is available, provided the review is explicitly labelled as self-review and does not claim independence.

## Evidence rules

- Do not edit measured values by hand.
- Do not combine results produced by different study versions without an explicit compatibility note.
- Preserve failed and excluded runs; mark their disposition and reason.
- Never commit credentials, wallet seeds, signed transactions, personal data, or private infrastructure details.
- Never run capacity experiments against Mainnet or public Testnet services.
- Treat endpoints and mutable URLs as discovery sources, not immutable proof.

## Complete-reserves distribution contributions

### Reserves as economic anti-spam and state-growth controls

Reserve calibration is also a security and state-growth study. The base reserve
raises the cost of creating `AccountRoot` state; the owner reserve raises the
cost of retaining trust lines, offers, escrows, NFTs, AMMs, and other ledger
objects. Contributions must therefore preserve separate base-only, owner-only,
and combined scenarios, and must report account-burst, object-burst, mixed,
churn, and recovery behavior together with ledger/database growth, CPU, memory,
disk/I/O, close-time, finality, transaction outcomes, reset, and recovery.
These measurements inform anti-spam trade-offs but do not by themselves prove
network security or justify a reserve-policy change.

The current evidence prerequisite is a frozen current-state distribution for
one validated ledger. One declared operator may create an `operator_local`
bundle and use it for a reproducible local study. A matching report from
another declared operator upgrades the bundle to `independently_corroborated`;
it is encouraged but not required. This is a read-only contribution. It must
not submit transactions or disclose database access, credentials, private
infrastructure details, wallet material, or personal data.

An acceptable imported operator report contains only:

1. the validated ledger index and ledger hash;
2. the declared operator identity and dataset type;
3. the classifier version and source commit captured by the importer;
4. SHA-256 values for the local query and its result;
5. `AccountRoot` total and owner-object totals by class; and
6. enough provenance for another operator to reproduce the same normalized counts at the same hash, if they choose to do so.

Use `bin/reserve-study complete-reserves-import --report /safe/path/report.json`
with the closed [`study/operator-owner-object-report-v1.schema.json`](study/operator-owner-object-report-v1.schema.json)
format. Do not put query text, raw result data, hostnames, private URLs,
database access, credentials, or personal data in that report.

A serial public-RPC `ledger_data` scan is useful for implementation checking, but it has no reliable remaining-page estimate and is not the recommended evidence-acquisition path. A partial scan, an aggregate with no hash/query bindings, or a result at a different ledger hash cannot satisfy this prerequisite. A complete, provenance-bound single-operator report is valid `operator_local` evidence; it must not be described as independently corroborated. See [docs/methodology.md](docs/methodology.md#frozen-distribution-acquisition-paths).

## Complete-reserves implementation contributions

The most useful implementation contributions are operator runtime adapters,
measured provisioning samples, reproducible state-image fixtures, recovery
probes, and artifact/schema verification. Follow the
[operator runbook](docs/complete-reserves-operator-runbook.md) and preserve all
of these boundaries:

- keep the 120-run full profile disabled and `authorized: false`;
- make every transaction target a pinned isolated private network;
- keep signing material out of Git, argv, environment variables, files, logs,
  exceptions, container metadata, and artifacts;
- construct ledger state through validated transactions, not database injection;
- bind samples to the exact distribution, candidate, profile, snapshot, ledger,
  security configuration, and source hashes; and
- report missing, failed, partial, and not-measured states explicitly rather
  than converting them into estimates or successes.

Do not commit generated `capacity/runtime/` or `evidence/generated/` content.
Proposed public evidence must be sanitized, checksummed, source-commit-bound,
and reviewed separately from the code that produced it.

## Required staged operator contribution sequence

Operator integrations and evidence contributions must identify which gate they
satisfy and proceed in this order:

1. Produce a hash-bound, exact-ledger distribution containing the AccountRoot
   total and owner-object totals by class. This is read-only work against the
   operator's own indexed Clio, `rippled`, database, or HTTPS source.
2. Integrate an operator-supplied isolated XRPL runtime adapter and run the
   non-counted 10k, 25k, and 50k calibration checkpoints. Cover base reserve,
   owner reserve, and combined pressure through the baseline, account-burst,
   object-burst, mixed, churn, and recovery workloads, including reset and
   artifact checks.
3. Record the 1m checkpoint as either `measured`, bound to its observed
   artifact, or `not_measured` with a permitted reason. Do not substitute a
   projection or omit the disposition.
4. Review measured provisioning and resource requirements, verified
   snapshot/one-use-clone behavior, all security gates, reset/recovery, and
   checksummed artifact publication. A failed or incomplete gate must remain a
   failed, incomplete, or not-measured result.
5. Only after those gates pass may maintainers consider a separate proposal to
   authorize the frozen 120-run full profile. The current executor rejects that
   profile, the matrix remains hard-disabled and `authorized: false`, and no
   earlier contribution enables or authorizes it.

All transaction-capable steps are isolated-private-network-only. Never submit
reserve-study transactions to Mainnet, Testnet, Devnet, or a public endpoint.
The repository does not bundle a live operator runtime adapter, no counted
complete-reserves evidence has been collected, and no reserve-policy change is
recommended. Planning output, a successful small calibration, and future full
authorization are separate states and must be described separately.

## Security

Do not open a public issue for a vulnerability. Follow [SECURITY.md](SECURITY.md).
