# XRPL Reserve Calibration Decision Brief v1

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
- The complete-reserves design covers both AccountRoot base reserve and the
  owner reserve across separate base, owner, and combined checks.
- AccountDelete is specified as a separate non-counted lifecycle: its special
  burned fee, deletion blockers, OwnerCount release, balance transfer, and
  cleanup/finality behavior are not folded into either reserve multiplier.
- Deterministic builders, verified state snapshots and one-use clones,
  measured-only scheduling, security workloads, and a guarded three-cell
  calibration executor exist as tested implementation contracts.
- The full 120-run profile remains disabled, unauthorized, and unavailable to
  the guarded executor.

## Required but absent evidence

- A hash-bound complete-reserves distribution from an indexed operator source.
- A validated AccountDelete lifecycle bundle covering success, failure,
  cleanup, fee burn, and state-growth measurements.
- Observed 10k, 25k, and 50k provisioning samples and an explicit 1m checkpoint
  disposition.
- Live operator-runtime integration and a realistic non-counted calibration.
- A separately reviewed authorization decision after that calibration.
- All 120 full-matrix dispositions, metrics, security gates, thresholds, and
  uncertainty analysis.
- Second-environment replication.
- Maintainer review of the completed capacity evidence.
- Completed economic/ecosystem analysis tied to measured capacity results.

## Assumptions and limits

The economic model and preregistered thresholds remain inputs, not results.
Synthetic workload preparation and passing tests demonstrate controls and
reproducibility mechanisms; they do not demonstrate ledger capacity, reserve
safety, or Sponsor behavior.

## Reopening conditions

Reopen the decision only after the exact-ledger distribution, measured
calibration, explicit 1m disposition, reviewed authorization, full 120-run
matrix, replication, economic/ecosystem analysis, and final review are
complete. Sponsor-specific conclusions additionally require the supplemental
Sponsor scenarios. Any material candidate or study change requires a new
versioned decision record and results must not be pooled across versions.
