# Account Reserve Calibration Decision Brief v1

Status: `insufficient_evidence`

## Decision

No reserve-policy change is recommended from the current evidence. The
critical execution gates are not satisfied, so this brief is a stop decision,
not an estimate of safety or a rejection of any candidate reserve.

## Verified facts

- The preregistered reserve study remains byte-for-byte identified as the
  original `3.1.3` study.
- The prospective execution target is the immutable `rippled` 3.3.0 release;
  its results must remain candidate-specific and cannot be pooled with the
  original study.
- The 3.3.0 image is pinned by immutable digest and the repository verifier
  passes its locked-input, schema, protocol, and fixture checks.
- The Sponsor calibration matrix, boundary validator, and fail-closed
  preflight are implemented. A three-validator private network reached
  consensus and reported Sponsor enabled on all validators at one validated
  ledger; no Sponsor transaction evidence exists yet.
- The protected native non-counted pilot passed on the pinned 3.3.0 candidate;
  its evidence is isolated, candidate-specific, and non-counted.

## Required but absent evidence

- A separately reviewed and authorized counted-run mechanism.
- All 72 counted run dispositions, metrics, thresholds, and uncertainty
  analysis.
- Second-environment replication.
- Maintainer review of the completed capacity evidence.
- Completed economic/ecosystem analysis tied to measured capacity results.

## Assumptions and limits

The economic model and preregistered thresholds remain inputs, not results.
Synthetic workload preparation and passing tests demonstrate controls and
reproducibility mechanisms; they do not demonstrate ledger capacity, reserve
safety, or Sponsor behavior.

## Reopening conditions

Reopen the decision only after Sponsor activation is observed on the isolated
candidate, the supplemental Sponsor scenarios and non-counted pilot complete,
native execution is established,
the preregistered counted matrix and replication are complete, and the final
review accepts the resulting evidence bundle. Any material candidate or study
change requires a new versioned decision record.
