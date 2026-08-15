# Evidence directory

Reviewed evidence is stored in versioned subdirectories. The first accepted semantic baseline is [`baselines/mainnet-106034050`](baselines/mainnet-106034050/README.md). The reviewed isolated 3.3.0 non-counted pilot is [`capacity-pilots/native-330-run-31692384477`](capacity-pilots/native-330-run-31692384477/README.md).

Publish reviewed evidence as a versioned bundle containing normalized JSONL, raw artifacts or content-addressed references, SHA-256 checksums, the source commit, environment manifest, and a human-readable index. Generated local output belongs under `evidence/generated/` and is ignored until intentionally reviewed.

Run `bin/verify-evidence` to verify every committed checksum manifest. The same command runs in CI through `bin/check`.
