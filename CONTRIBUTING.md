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

## Security

Do not open a public issue for a vulnerability. Follow [SECURITY.md](SECURITY.md).
