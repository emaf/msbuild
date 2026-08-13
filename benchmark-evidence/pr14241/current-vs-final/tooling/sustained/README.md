# Approved sustained-only campaign

This focused benchmark-only tooling leaves the historical 82-row campaign and
both tested source trees unchanged. It compares unchanged BASE
`ff5b281f0c5828dec0d092fcd1b682019de7d1ca` with FINAL branch
`coordinator-priorities` at
`432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef`.

Only `BASE`, `FINAL-N`, and `FINAL-H` are scheduled. The pinned Roslyn and
Aspire representative projects, dedicated clones, and dedicated worktree roots
are unchanged. Preparation selects `normal1` through `normal10` plus
`injected`; a frozen eight-worker run uses the first eight.

## Safe deterministic validation

These commands parse and test tooling only. They do not build product or run a
public workload:

```powershell
pwsh -NoProfile -File .\Test-SustainedCampaign.ps1
pwsh -NoProfile -File .\Run-SustainedCampaign.ps1 `
  -PlanOnly `
  -PlanOutputRoot C:\perf\results\current-vs-final-sustained-plan-check
```

The 24-row plan has one excluded complete warmup block and three measured
blocks per repository. Measured orders are exactly:

1. `BASE FINAL-N FINAL-H`
2. `FINAL-N FINAL-H BASE`
3. `FINAL-H BASE FINAL-N`

This design is exactly position-balanced and explicitly carryover-unbalanced.

## Authoritative launch

When separately approved for execution, invoke exactly once:

```powershell
pwsh -NoProfile -File .\Launch-SustainedCampaign.ps1
```

The launcher creates one fresh
`C:\perf\benchmark-launches\current-vs-final-sustained-*` record and one
detached process whose fresh result is
`C:\perf\results\current-vs-final-sustained-*`. Duplicate processes or existing
roots are refused. There is no automatic relaunch or resume. The entire process
has a hard eight-hour deadline, and each complete block has at most two
attempts. A separately recorded auxiliary watchdog enforces that deadline
against the exact campaign PID/start identity and terminates its verified
process tree; it is not a second campaign launch.

Exact bootstrap preparation reuses each immutable role independently, so a
validated BASE stage can be reused while the new FINAL is built. The identity
checkpoint records `ReusedRoles`, `BuiltRoles`, exact source commits, product
versions, and stage hashes.

## Fixed sustained window

`Invoke-SustainedWindowScenario.ps1` starts eight or the globally frozen ten
Normal workers in a closed loop. A replacement is launched only after corrected
current Job membership, output streams, and process identity reach quiescence;
the input is touched only after that completion.

Onset requires all of:

- at least one successful initial Normal completion;
- an actual deferred grant;
- at least one active and one waiting Normal request; and
- a continuously nonempty queue for 30 seconds.

The measured window is then exactly 480 seconds. At second 240 the separate
probe is Normal for BASE/FINAL-N and High for FINAL-H. Submissions stop at
second 480 and all work drains. The probe is excluded from Normal throughput.
Trace-time and sampled queue-nonempty fractions must each be at least 90%.

Every run retains environment, PID/start/exit, binlog, trace, monitor,
continuity, worktree, and quiescence evidence. Actual binlog grants are replayed
and matched to strict trace identities. FINAL grants must all be at most four
nodes, with no idle eight-node grant. FINAL-H is valid only when environment
and trace both encode High and the trace records an immediate at-most-four-node
grant while Normal work remains queued and reserve capacity is observed. The
old 12-completions-within-10-minutes gate is not used.

Excluded pilots first run all required repository/condition cases at eight
workers. A queue-criterion failure returns
`WorkerCountIncreaseRequired`; the caller may rerun the entire pilot set once
at ten and then freezes that count globally. There is no other sizing retry.
Each valid pilot reports the exact Normal completion count from its full fixed
window and requires at least one completion in each four-minute half, so every
pre/post throughput value is defined. This is not the superseded historical
12-in-10-minutes gate.

## Analysis and sanitizer hook

`Analyze-SustainedCampaign.ps1` emits raw measured rows, paired values,
formulas, comparisons, and plain-English reporting. Comparisons are directional
within repository and measured block with `n=3`, exactly 10,000 deterministic
whole-block resamples, and all eight exact sign flips. Repositories and
historical campaigns are never pooled.

`Publish-SustainedEvidence.ps1` is the uninvoked packaging hook. When explicitly
run after valid analysis, it accepts only a sanitized summary allowlist and
constrains the destination below
`benchmark-evidence\pr14241\current-vs-final\sustained`. It excludes raw
binlogs, telemetry, debug traces, environment dumps, process output, worktrees,
and compiled scanner files. The campaign does not invoke packaging.
