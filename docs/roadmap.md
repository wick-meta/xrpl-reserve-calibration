# Complete recommended sequence

This is the contributor-facing sequence for the complete-reserves program.
The original base-reserve preregistration and its non-counted pilot remain
preserved as historical evidence, but they do not satisfy the owner-reserve or
combined-reserve gates below.

## Phase 0 — public foundation

1. Maintain the standalone repository, community policies, least-privilege CI,
   vulnerability reporting, and protected review flow.
2. Keep capacity execution isolated from Mainnet and public Testnet services.
3. Keep the complete-reserves authorization record disabled until its named
   inputs and review gates are satisfied.

Exit gate: a public clone passes `bin/check`, contribution and security paths
are documented, and no credential or public-network transaction path is
required for evidence acquisition.

## Phase 1 — freeze the current-state distribution

1. Select one validated XRPL ledger and bind every report to its exact index
   and hash.
2. Use one declared operator's indexed data. A local Clio/`rippled` index or
   an operator database is acceptable when it preserves query and hash
   provenance.
3. Produce a closed local report with normalized `AccountRoot` and
   owner-object-class counts, query/result SHA-256 values, classifier version,
   and exact ledger binding; import it into the source-commit-bound bundle with
   `complete-reserves-import`. Keep raw queries/results and infrastructure
   details outside the repository.
4. If another operator reproduces the counts at the same hash, record the
   exact agreement and upgrade the evidence tier.
5. Publish the accepted aggregate evidence without credentials, private
   infrastructure details, or personal data.

Exit gate: one provenance-bound bundle passes the repository's schema checks
and is labelled `operator_local`. Exact agreement from another operator is
recorded as `independently_corroborated`, but is not required to proceed. This
gate is tracked in [the current prerequisite issue](https://github.com/wick-meta/xrpl-reserve-calibration/issues/2).

The serial public-RPC `ledger_data` collector is a correctness reference only.
It has no reliable remaining-page estimate and may fail at ordinary gateway
limits; a partial scan cannot satisfy this phase.

## Phase 2 — controlled complete-reserves capacity experiment

1. Implement and test deterministic AccountRoot and owner-object population
   construction, verified fresh-state snapshots/clones, bounded scheduling,
   recovery, and sanitized artifact publication.
2. Measure a realistic, explicitly non-counted calibration profile before
   estimating full provisioning time or considering authorization. Its results
   cannot be pooled with the full matrix.
3. Bind the frozen Phase 1 distribution to the still-disabled authorization
   record and require review before any signing authority can be read.
4. Only after the execution model is reviewed and separately authorized, use
   the commit-pinned isolated-network harness with synthetic execution
   authority, resource ceilings, timeouts, and explicit abort rules.
5. Execute the predeclared 120-run matrix: 48 base-reserve cells, 48
   owner-reserve cells, and 24 combined corner cells, each repeated three
   times. Its timed warmup-and-measurement floor is 70 serial hours, excluding
   measured provisioning, snapshot/clone, recovery, and retry time.
6. Preserve successes, failures, exclusions, logs, metrics, environment
   manifests, and checksums. Do not pool results across candidate versions,
   profiles, or environments.
7. Reproduce a representative subset on a second environment and state
   whether it was maintainer-performed or independently performed.

Exit gate: every planned run has a disposition, predeclared thresholds and
uncertainty are evaluated, and the replication outcome is documented. This
phase is blocked by Phase 1 and is tracked through this roadmap until an execution issue is opened.

## Phase 3 — economic and ecosystem analysis

1. Model base reserve, owner reserve, and combined-policy effects from the
   frozen distribution using identical horizons and documented assumptions.
2. Report aggregate and segment-level effects, sensitivity, uncertainty,
   operator cost, abuse implications, onboarding effects, and migration
   considerations.
3. Record structured ecosystem feedback and conflicts of interest separately
   from measurements.

Exit gate: calculations reproduce from committed inputs, material objections
have dispositions, and the analysis remains traceable to the frozen
distribution and Phase 2 results. It is tracked through this roadmap until an analysis issue is opened.

## Phase 4 — decision and contribution

1. Generate a decision brief that separates facts, assumptions, measurements,
   results, and judgments.
2. Apply predeclared gates. Any unmet critical gate produces
   `insufficient_evidence`, not a recommendation.
3. Complete and publish documented technical and methodological review;
   identify self-review and independent review accurately.
4. Publish the evidence bundle and checksums under a versioned release.
5. Contribute a concise, evidence-backed proposal to the appropriate public
   XRPL forum.
6. Track discussion, corrections, validator/operator feedback, implementation,
   voting, and activation as separate later states.

Exit gate: the public contribution is traceable to a released evidence bundle.
It is tracked through this roadmap until a decision issue is opened.
