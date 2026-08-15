# Native execution handoff v1

The remaining Phase 2 execution gate is native amd64 hardware. The current
Docker server reports `arm64`; selecting `linux/amd64` on that host is
emulation and is not valid evidence for counted capacity.

The repository also provides a manually dispatched, secret-free GitHub Actions
native-readiness workflow at `.github/workflows/native-readiness.yml`. It runs
only the immutable-image architecture check and exact input preparation; it
does not read signing authority, submit transactions, or authorize counted
execution. The same preflight passed in pull-request CI run `31358002863`; the
record is preserved in [`evidence/native-readiness-ci-2026-08-10`](../evidence/native-readiness-ci-2026-08-10/README.md).

A native operator should verify all of the following before running anything:

```text
uname -m                         # must report x86_64/amd64
docker version                   # server architecture must be amd64
bin/capacity-harness doctor     # native_architecture_eligible=true
bin/reserve-study validate
bin/reserve-study capacity-config --run-id r0500000-a000010000-n01
bin/reserve-study capacity-workload --run-id r0500000-a000010000-n01 --pilot-accounts 3
bin/reserve-study capacity-run-manifest --run-id r0500000-a000010000-n01 --pilot-accounts 3
```

The pilot must then be invoked only with the protected standard-input option:

```text
bin/reserve-study capacity-non-counted-pilot \
  --run-id r0500000-a000010000-n01 \
  --pilot-accounts 3 \
  --secret-stdin
```

The authority is supplied interactively or by a protected pipe at execution
time. It must not be placed in repository content, arguments, environment
variables, files, Compose metadata, logs, or evidence. The command itself
performs the candidate identity checks, bounded sampling, restart/recovery,
single reset, schema validation, and atomic publication.

## Maintainer-operated hosted execution

The public repository includes a manually dispatched workflow at
`.github/workflows/native-pilot.yml`. It runs only on a native hosted runner,
uses the `reserve-pilot` GitHub Environment, and reads one environment secret
named `XRPL_STANDALONE_GENESIS`. Configure that secret in the environment's
Actions settings; never put it in repository variables, workflow text, an
issue, a pull request, or a command argument. Environment approval may be
required by repository policy, but public contribution or external review is
not required.

Dispatch the workflow only after confirming the environment secret is the
intended isolated standalone authority. The workflow verifies native
architecture, regenerates the exact locked inputs, supplies the authority only
through standard input, and uploads artifacts only after a complete successful
run and confirmed reset. It does not run on pull requests and does not expose
the authority in logs or artifacts. Downloaded artifacts remain candidate-
specific non-counted evidence until they pass the documented review gates.

Pilot output is candidate-specific and non-counted. Counted execution remains
forbidden until the pilot passes its declared gates, native eligibility is
recorded, and counted authorization is separately documented. No public XRPL
endpoint is used by this handoff.
