# Schemas

JSON files in this directory are closed public interchange contracts. The
current complete-reserves surface is indexed by
[`study/complete-reserves-public-contract-v1.yml`](../study/complete-reserves-public-contract-v1.yml).

The active execution path uses:

- `complete-reserves-preflight-v1` for secret-free capability reporting;
- `complete-reserves-provisioning-sample-v1` and
  `complete-reserves-provisioning-estimate-v1` for observed calibration and
  unbounded full-profile projections;
- `complete-reserves-profile-schedule-v1` for the disabled 120-item schedule;
- `complete-reserves-security-evaluation-v1` for named security gates;
- `verified-state-snapshot-v1` for actual stopped-state images;
- `complete-reserves-calibration-item-v1` for the three-cell guarded profile;
  and
- `complete-reserves-execution-result-v1` plus `complete-reserves-resume-v1`
  for successful, reset-and-recovery-confirmed calibrated execution.

The Ruby validators additionally recompute canonical SHA-256 values, exact
cross-record joins, file manifests, one-use clone state, ledger identities, and
artifact checksums. Passing a JSON Schema alone is never sufficient for
execution or evidence admission.

The earlier `state-snapshot-v1`, `complete-reserves-result-v1`,
`complete-reserves-summary-v1`, and `complete-reserves-workload-v1` files
describe preserved pre-executor scaffolding. The guarded executor does not
accept them in place of the active contracts above.
