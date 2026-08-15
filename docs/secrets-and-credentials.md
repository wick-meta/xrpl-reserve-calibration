# Secrets and credentials

This repository is intentionally public. It contains the study specification,
source code, locked inputs, schemas, tests, container configuration, and
sanitized evidence. It must not contain private keys, account secrets,
validator tokens, credentials, or operator-specific machine details.

## Three separate credential types

### Validator identity credentials

The private three-validator network uses validator identity keys and validator
tokens so its validators can identify one another and participate in consensus.
`bin/private-network prepare` creates these credentials in the ignored
`capacity/runtime/` directory and renders them into the local validator
configuration. They are runtime credentials, not payment-account keys. They
are never committed, passed as command-line arguments, or printed by the
repository commands. For a disposable network they may be regenerated; if a
network must be retained, store them only in an operator-controlled secret
store with appropriate access control.

The standalone capacity candidate does not participate in consensus and does
not need validator credentials.

### Account signing authority

An XRPL account secret is separate from validator identity. A funded source
account must sign a Payment or Sponsor transaction before the isolated
execution environment can submit it. The guarded commands accept that
authority only at execution time through protected standard input. It is not
accepted from an argument, file, environment variable, Docker/Compose
metadata, output, or log.

Never paste an account secret into an issue, pull request, chat, or CI log.
The repository deliberately does not provide a real authority value or a
command example containing one.

### Destination addresses

The pilot workload uses deterministic, syntactically valid synthetic
destination addresses. They are unsigned intents and have no generated seed,
private key, public key, or signing capability. A destination does not need a
private key merely to receive funds.

## Correct local workflow

1. Clone the public repository and run validation and input-preparation
   commands. These commands are secret-free and produce only ignored runtime
   files.
2. Prepare the private network when amendment-state testing is required.
   Validator credentials are generated locally by `prepare`.
3. For transaction scenarios, create temporary test accounts inside the
   isolated standalone or private network and fund them from that environment's
   local genesis/faucet authority. Keep every resulting secret in volatile
   runtime storage or an operator secret manager; never add it to Git.
4. On a trusted native runner, supply the source account authority
   interactively to the guarded non-counted pilot or functional smoke through
   `--secret-stdin`. Do not place it in shell history, process arguments,
   environment variables, files, or automation output.
5. Let the harness submit only to its verified internal network. After the
   run, require the guarded reset and review generated artifacts before any
   publication.
6. Destroy disposable networks and remove or rotate temporary credentials
   when the work is complete.

Creating an account inside a standalone or private network is permitted and
is often the safest way to make temporary test accounts. It does not remove
the need to protect the account secret, and it does not make validator keys a
replacement for account-signing authority.

## Public-repository rules

- Public: source, tests, schemas, deterministic public inputs, image digests,
  protocol references, and sanitized evidence.
- Private: account seeds/secrets, validator private keys and tokens, faucet or
  genesis secrets, Docker credentials, SSH keys, API tokens, and local machine
  identifiers.
- CI readiness checks remain secret-free. The separate manual pilot workflow
  uses only the protected `reserve-pilot` GitHub Environment secret
  `XRPL_STANDALONE_GENESIS`; it is not a repository variable, workflow value,
  pull-request input, or public artifact. The workflow is manual-only and
  uploads artifacts only after reset and schema validation.
- Before publishing artifacts, scan for secrets, hostnames, usernames, paths,
  IP addresses, tokens, and other identifying data.

The complete-reserves workflow starts with a false-authorization preflight and
has no workflow inputs. It does not read a secret while authorization remains
false. A future reviewed authorization must remain protected in the dedicated
environment and must not make a credential part of the repository, workflow
definition, logs, or artifacts.

The repository's ignored runtime paths and safety checks enforce the intended
boundary, but operators remain responsible for their local secret manager,
shell, Docker installation, and cleanup.
