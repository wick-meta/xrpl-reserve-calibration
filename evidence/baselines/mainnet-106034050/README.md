# Mainnet reserve baseline at ledger 106034050

Status: `agreed`

Honeycluster and Ripple independently returned ledger hash `D8A5E8C8BCEE3139A56510E62B242D833D8F7730927109DF9EAFB7559204A90A` at exact validated ledger 106034050. The canonical `FeeSettings` entry reported:

- base reserve: 1,000,000 drops (1 XRP);
- reserve increment: 200,000 drops (0.2 XRP).

The bundle was generated from source commit `0177fe123998384fe1dbc145afe7e62c02b2ff15`. Raw responses are preserved byte-for-byte. Verify them from this directory with:

```sh
shasum -a 256 -c SHA256SUMS
```

InFTF was not part of this accepted bundle. A prior local smoke attempt rejected that optional endpoint because it reported a stale ledger and `disconnected` state. That failed smoke was not committed and does not affect the agreed two-operator baseline.
