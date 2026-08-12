# PR #14241 current-vs-final campaign tooling

This directory contains the benchmark-only, resumable Windows campaign for the
contemporaneous BASE (`ff5b281f…`) versus FINAL (`9aa31970…`) comparison. It
does not modify either tested revision. Raw runs stay outside git under
`C:\perf\results`; durable launch metadata stays under
`C:\perf\benchmark-launches`.

Entry points:

- `Run-Campaign.ps1 -PlanOnly`: emit and validate the exact matrix without
  requiring bootstraps or workload checkouts.
- `Launch-Campaign.ps1`: create one durable detached campaign process.
- `Run-Campaign.ps1 -ResumeRoot <root>`: resume from atomic shape/block
  checkpoints without replacing prior invalid attempts.
- `Analyze-Campaign.ps1`: validate and compute deterministic paired estimates.
- `Publish-Evidence.ps1`: copy a sanitized allowlist into a public evidence
  package; raw traces, telemetry, binlogs, and scanner binaries are excluded.
- `Test-Tooling.ps1`: deterministic parser, controller, schedule, environment,
  analysis, and sanitization checks.
- `Run-ProjectTimingGate.ps1`: run excluded actual sustained pilots for BASE,
  FINAL-N, and FINAL-H per repository and enforce the conservative four-hour
  and sustained-ability gates.
- `Run-DirectProjectSmoke.ps1`: validate one excluded direct FINAL-N isolated
  project build per repository before the sustained pilots.
- `Get-CampaignStatus.ps1 -LaunchRoot <root>`: verify the durable PID/start
  identity and show the current checkpoint.

The production sequence builds exact detached revisions with the validated
dotnet-engine Release command (`-msbuildEngine dotnet`, `/p:CreateTlb=false`,
`/p:RuntimeOutputTargetFrameworks=net11.0`), stages immutable content-addressed
bootstraps, runs exactly-once BASE and FINAL functional grant
smokes plus short controller/trace smokes against both binaries, prepares 19
pinned project worktrees per repository, and measures the first warm project
worktree for a strict disk projection. It then validates one excluded direct
isolated project per repository. Before measured scenarios it runs the actual
18-outstanding sustained controller, including injection after completion 6,
ending at completion 12, and drain, for BASE, FINAL-N, and FINAL-H in each
repository. These six excluded pilots cover BASE one-node saturation and both
FINAL priority modes. Their observed full wall times, multiplied by a
predeclared 1.25 safety factor, are conservative condition-specific upper
bounds for every planned scenario; COMPAT uses the slowest factored pilot.
Setup elapsed time and every cooldown are also counted.
Projected total time must be at most four hours, and every pilot must complete
12 measured Normal builds within 10 minutes after onset. Either gate stops the
campaign without reducing scope.

The contemporaneous matrix contains only isolated and sustained shapes.
Historical evidence supplies other finite-contention coverage and is not
scheduled, analyzed, or reported by this tooling.

All measured shapes use representative propagated projects:

- Roslyn
  `src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj`, touching
  `src\Compilers\CSharp\Portable\CSharpCompilationOptions.cs`.
- Aspire `src\Aspire.Hosting\Aspire.Hosting.csproj`, touching
  `src\Aspire.Hosting\DistributedApplication.cs`, always with
  `/p:InstallBrowsersForPlaywright=false`.

This limited project deviation exists to control reviewer and runtime cost.
Historical full-solution and node-count matrices remain supporting evidence
only and are never pooled with this campaign.

Sustained onset means 30 continuous semantic seconds at the expected
allocation with queue depth at least two. A release followed only by
same-clock deferred grants may bridge the interval when full allocation is
restored within the predeclared one-second handoff tolerance and the queue
never drops below two; longer shortfalls or queue drain reset the clock.

## Deterministic local validation

This does not build either tested revision or start a public workload:

```powershell
pwsh -NoProfile -File .\Test-Tooling.ps1
pwsh -NoProfile -File .\Run-Campaign.ps1 `
  -PlanOnly `
  -PlanOutputRoot C:\perf\results\current-vs-final-plan-check
```

The exact contemporaneous plan has 82 condition rows. Per repository, isolated
has 3 warm-up plus 18 measured rows and sustained has 4 warm-up plus 16
measured rows. Each shape is exactly one complete Williams cycle; every
measured design has position and carryover imbalance `0/0`.

## Authoritative launch and resume

```powershell
pwsh -NoProfile -File .\Launch-Campaign.ps1

# If the detached process is interrupted, resume only with unchanged tooling:
pwsh -NoProfile -File .\Run-Campaign.ps1 `
  -ResumeRoot C:\perf\results\current-vs-final-<id>
```

The launcher creates metadata first under
`C:\perf\benchmark-launches\current-vs-final-*`, while `Run-Campaign.ps1`
exclusively creates the fresh result root. Launch verification requires a live
PID/start identity, one matching process, an existing result root and
stdout/stderr files, and empty stderr. A failed launch kills only the exact
child PID and records `launch-failure.json`.

Resume never overwrites attempts. An interrupted attempt is preserved and
declared invalid before the next whole-block attempt. A tested-condition build
failure is a non-retriable policy outcome; only predeclared external/harness
invalidity can consume one of the three attempts. Failure to produce 12
sustained completions within 10 minutes is also non-retriable. Before any
retry, affected worktrees are checked for overlap, explicit untracked
`bin`/`obj`/`artifacts` outputs are removed only after proving they contain no
tracked files, and restore/warm recreates the recorded baseline. `git clean`
is not used for retry restoration. The regenerated output file-count, byte
count, and aggregate SHA-256 must match that worktree's recorded prepared
baseline; retouching remains inside the next scenario.

## Analysis and public package

```powershell
pwsh -NoProfile -File .\Analyze-Campaign.ps1 -RunRoot <result-root>
pwsh -NoProfile -File .\Publish-Evidence.ps1 `
  -RunRoot <result-root> `
  -DestinationRoot <empty-public-evidence-root>
```

Analysis uses repository-local block pairs, 10,000 whole-block resamples, and
exact sign flips with the predeclared shape seeds. Inference is directional:
the minimum attainable two-sided exact p-value is 0.03125 for isolated n=6 and
0.125 for sustained n=4. BASE one-node saturation is reported as a
measured mechanism, not excluded. The public packager copies
only summaries and parsed control-plane timelines. It excludes raw binlogs,
telemetry, debug traces, stdout/stderr, generated worktrees, and compiled grant
scanner output, and never mutates the private raw result.
