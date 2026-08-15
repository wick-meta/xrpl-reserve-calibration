# Complete-reserves security review

Review scope: the disabled complete-reserves program only.

- Public endpoints are read-only and HTTPS-only; execution has no public endpoint setting.
- The 120-run matrix is unreachable while the tracked authorization is false, before signing input is read.
- Candidate configuration changes both reserve fields only; unsigned workload identities bind study, distribution, run, class, and ordinal.
- Builder source fan-out is limited to ten in-flight transactions per source and requires validated finality.
- Snapshots bind candidate, study, distribution, both reserves, scale, expected populations, database, and build hashes. Clone reuse is rejected.
- Artifact publication rejects sensitive keys, host identifiers, paths, location data, and secret-shaped values.
- No cleanup path accepts a user-selected broad target.

Residual limitation: these checks validate code and fake boundaries. They are not evidence from a counted run, and do not change the false authorization state.
