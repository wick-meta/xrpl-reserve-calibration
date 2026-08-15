# Sponsor private-network activation observation

Status: `observed_non_counted`

This record documents the guarded private-network smoke for the candidate
`rippled` 3.3.0 image. It is an amendment-state observation, not a capacity
measurement and not a public-network result.

- Candidate release: `3.3.0`
- Candidate source commit: `00a178fb92ca49521b937ae1a99d863765ea8a90`
- Image digest: `sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70`
- Network: private network ID `21339`
- Validators: `3`; each reported `server_state=proposing` and `peers=2`
- Sponsor: `supported=true`, `enabled=true` on all three validators
- Agreement check: all three returned validated ledger `783` with hash
  `227561E9C77A11539CC8FC40B0688293089E20FE3E2F4FEB19FD9D9133AD4092`
- Counted execution: `false`
- Transaction submission: none

The runtime credentials, Compose volumes, and raw RPC responses were removed
after the observation. No validator secret or signing material is part of this
repository.
