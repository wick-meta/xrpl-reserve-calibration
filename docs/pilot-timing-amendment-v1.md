# Non-counted Pilot Timing Amendment

## Status

This amendment is prospective and candidate-specific. It was made before a
successful non-counted pilot. It does not authorize counted execution.

## Reason

The isolated harness invokes `ledger_accept` through its fixed container-local
RPC transport. Direct measurement of five fresh ledger-advance calls observed a
fastest completed call of 0.319 seconds. The previous maximum target lateness
of 0.25 seconds was therefore infeasible even without scheduler jitter.

## Replacement timing policy

The locked pilot protocol now requires:

- a two-second absolute monotonic target cadence;
- at most 1.0 second of completion lateness; and
- consecutive completion intervals from 1.0 through 3.0 seconds.

For a two-second target cadence and a completion lateness bounded to the range
zero through one second, the permitted consecutive-completion interval range
is exactly one through three seconds. The amended contract retains fail-closed
behavior for a missed target, no catch-up ledger advances, exact ledger binding,
and all transaction and recovery requirements.

## Evidence disposition

Every previous protected non-counted-pilot attempt used the infeasible
0.25-second timing policy, failed, and is invalidated. Those attempts are not
pilot evidence and must not be compared, combined, or pooled with any run made
under the amended locked protocol. A new successful protected pilot remains
required before any counted-execution gate can advance.
