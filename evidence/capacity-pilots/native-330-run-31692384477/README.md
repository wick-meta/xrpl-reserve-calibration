# Native non-counted pilot on rippled 3.3.0

Status: `passed`, non-counted, candidate-specific.

This bundle is the sanitized artifact uploaded by the protected native pilot
workflow run [31692384477](https://github.com/wick-meta/xrpl-reserve-calibration/actions/runs/31692384477), executed from source commit
`a97cadfe8d9815f4468c67323a98ae2957a2e629`.

The recorded result contains 901 ordered samples, three validated successful
transactions, no abort-rule breach, successful controlled recovery, confirmed
reset, and all declared pilot thresholds passed. The metrics summary records a
2.027184808000129-second p95 ledger-close interval and 2.244405985999947-second
recovery time.

Verify this bundle from this directory with:

```sh
sha256sum -c SHA256SUMS
```

This is isolated standalone-network evidence only. It does not establish
native execution for counted measurements or authorize counted execution; both
flags remain `false` in `pilot-result.json`. It is not Mainnet evidence and
must not be pooled with any other rippled release.
