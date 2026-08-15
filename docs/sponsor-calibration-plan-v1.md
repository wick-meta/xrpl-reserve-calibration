# Sponsor calibration plan v1

This is a candidate-specific supplemental matrix for `rippled` 3.3.0. It does
not rewrite or pool the original reserve-calibration population.

The isolated standalone network must verify the Sponsor amendment is active
before sponsored runs. Each scenario is paired with an unsponsored control and
captures fees, balances, base and owner reserve, `OwnerCount`, sponsorship
counters, ledger/database bytes, memory, CPU, ledger-close time, success ratio,
recovery, and cleanup.

Scenario groups are fee-only sponsorship, reserve-only sponsorship, combined
fee and reserve sponsorship, sponsored trust lines/offers/tickets/NFT pages,
insufficient allowance and permission/signature failures, and sponsorship
transfer/dissolution with reserve recovery.

All supplemental runs remain non-counted until amendment-state, boundary,
reset, schema, and artifact-review gates pass. No public-network submission or
secret material is permitted.

## Current gate state

The immutable 3.3.0 image, locked candidate inputs, protocol validator,
transaction-boundary tests, and full offline verifier are passing. A fresh
isolated container also passes health and identity checks. Sponsor remains
disabled in standalone mode, so `sponsor-preflight` fails closed and no Sponsor
transaction is submitted there. A fresh three-validator private network has
now reached consensus and observed Sponsor as `enabled: true` on all three
validators at the same validated ledger. This clears the amendment-state gate
for the supplemental scenarios, but it does not authorize counted capacity
work. The six scenarios, non-counted transaction evidence, native execution,
counted matrix, replication, and final review remain open gates.
