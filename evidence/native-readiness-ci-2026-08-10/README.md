# Native readiness CI observation

Status: `native_readiness_verified_non_counted`

The public pull-request CI run verified the immutable candidate and exact pilot
inputs on a GitHub-hosted native amd64 runner. This is a readiness observation,
not pilot or capacity evidence.

- Repository: `wick-meta/xrpl-reserve-calibration`
- Pull request: `8`
- Workflow run: `31358002863`
- Run URL: <https://github.com/wick-meta/xrpl-reserve-calibration/actions/runs/31358002863>
- Validated branch commit: `2e53f15829534913ab3eee6d0cd2e8bf96ed6cbc`
- Native job: passed
- Full test job: passed
- Candidate image: `xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70`
- Signing authority read: `false`
- Transaction submission: `false`
- Counted execution: `false`

The native job checked `native_architecture_eligible=true`, retained
`counted_run_ready=false`, and regenerated the exact 3.3.0 pilot inputs. The
local arm64 Docker host remains unsuitable for counted execution; this record
proves that a native runner is available in the public CI path, not that a live
pilot has been run.
