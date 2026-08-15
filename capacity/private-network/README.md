# Private three-validator network

This is the controlled consensus environment for Sponsor amendment testing. It
is separate from the standalone capacity harness and uses three validators on
private network ID `21339`, with no host ports and no public endpoint.

Validator identity keys and tokens are generated only in ignored runtime
storage. They are not account-signing keys; transaction scenarios may require
separate temporary accounts and protected account authority. See
[`docs/secrets-and-credentials.md`](../../docs/secrets-and-credentials.md).

Run the guarded lifecycle from the repository root:

```text
bin/private-network prepare
bin/private-network up
bin/private-network verify
bin/private-network activate   # request Sponsor votes
bin/private-network wait       # wait through majority and flag-ledger gates
bin/private-network down
XRPL_PRIVATE_NETWORK_CONFIRM_RESET=1 bin/private-network reset
```

`prepare` generates validator credentials inside the ignored runtime directory.
They are never tracked, printed, or accepted as command-line arguments. The
Compose file pins the exact `rippled` 3.3.0 image, uses an internal network,
read-only containers, dropped capabilities, and bounded resources.

`verify` is fail-closed: every validator must be proposing, see two peers, and
report Sponsor as supported and enabled. `activate` only records the normal
consensus vote; the configured 15-minute majority window must elapse before
`verify` can pass. These are non-counted amendment and transaction-smoke
prerequisites, not capacity measurements.

The layout follows the official XRPL private-network tutorial and amendment
testing guidance: [Run a Private Network with Docker](https://xrpl.org/docs/infrastructure/testing-and-auditing/run-private-network-with-docker)
and [Test Amendments](https://xrpl.org/docs/infrastructure/testing-and-auditing/test-amendments).
