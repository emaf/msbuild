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
- `Run-PhaseOneDisposablePreflight.ps1`: synchronously run the disposable
  Phase 1 end-to-end preflight below in one caller-selected root.
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

## Disposable synchronous Phase 1 preflight

This is a separate, explicitly invoked gate. It does not launch or resume the
public campaign:

```powershell
pwsh -NoProfile -File .\Run-PhaseOneDisposablePreflight.ps1 `
  -BootstrapIdentityPath C:\perf\results\<exact-build>\bootstrap-identities.json `
  -OutputRoot C:\perf\preflight\pr14241-phase-one
```

Both arguments are mandatory and fully qualified. Before its first write, the
entry point parses the identity and physically canonicalizes paths. It rejects
an `OutputRoot` inside any git worktree or overlapping the tooling/repository,
identity file/directory, BASE/FINAL bootstrap, or source-worktree roots. The
command runs in the foreground and never calls `Launch-Campaign.ps1` or creates
a detached campaign. A root-local
exclusive file lock plus a path-derived named mutex refuse concurrent
invocations. Each successful invocation also launches the same exact command
as a short child while it owns the lock and records the expected duplicate
refusal in `attempt-NNNN\duplicate-refusal.json`.

Every run allocates the next `attempt-NNNN` below the same top-level root.
Failed attempts and their raw evidence are retained; rerunning allocates the
next number. Each attempt writes its source identity bytes once with
`CreateNew` to a read-only `inputs\bootstrap-identities.json` snapshot and uses
only that snapshot. Completion binds both the snapshot and original source
path/hash; source mutation or immutable-stage revalidation failure prevents
promotion. A valid existing root `completion.json` may return only when those
bindings, the attempt completion hash, synchronous contract, and every required
component still validate. No root-level failure or success-shaped fallback is
written.

One passing attempt records all of the following:

- fresh immutable-stage manifests and exact BASE/FINAL source commit,
  `ProductVersion`, `dotnet.exe`, `MSBuild.dll`, framework, and Coordinator
  binary identities;
- the unchanged `Run-PreflightValidation.ps1` BASE/FINAL functional-grant and
  both-binary controller traces, strict parsing, and net11 GrantReplay scanners
  compiled against the corresponding exact assemblies with intermediates
  below the attempt's external `_tooling` root;
- a real synchronous `controller-lifecycle-smoke` using
  `Start-ScenarioBuild`: exactly 18 initial full-budget Normal synthetic
  processes and unique worktrees, real queue/deferred behavior, one-second
  semantic onset, a successful quiescent replacement, injection after
  completion 1, end after completion 2, replacement stop, and complete drain.
  This deliberately abbreviates only the production 30-second onset,
  completion-6 injection, and completion-12 end; strict controller events,
  grant replay matched by run/PID/start identity to each strict trace root
  (including injection), one Coordinator trace, no overlap, and zero final
  active/queue/allocation remain mandatory;
- real monitor ready/stop/process-exit timestamps, monotonic samples, and
  ready/first, inter-sample, and last/stop gap validation at 30/15/15 seconds
  for the 1/5/5-second system/process/probe streams;
- keep-awake enablement and restoration from `finally`;
- a controlled expected-error `finally` exercise with a real short root/child
  process tree, followed by a persistent start-time identity registry, verified
  tree stop, and strict audit proving every captured command, build, descendant,
  duplicate probe, and monitor identity is absent. Query failures are evidence
  failures, never assumed absence. Early native identities are retained when the
  attempt registry is created. Every scenario root is created suspended with
  redirected handles and a Unicode environment, assigned to a dedicated Windows
  Job Object with `KILL_ON_JOB_CLOSE`, identity-registered, and only then resumed;
  there is no unsuspended fallback. Authoritative membership censuses retain
  persistent children after root ancestry disappears, with
  repeated ancestry sampling as defense in depth. Native and DLL-hosted
  Coordinators are registered globally but excluded from individual build
  quiescence; and
- bounded final BASE and FINAL build-server shutdown. Recorded native commands
  default to a one-hour timeout, while cleanup and grant replay use smaller
  bounds; bootstrap/output probes use bounded in-memory capture with a five-minute
  default. Shutdown, monitor stop, keep-awake restoration, registry audit, and
  lock release are attempted independently and their failures are aggregated.
  After the final process audit, a managed-only final `ProductVersion`, tracked
  binary, and full immutable-stage rehash is bound into both completion records;
  no native command can run between that rehash and atomic promotion.

Raw traces, binlogs, telemetry, scanner outputs, and child logs remain only
under the external `OutputRoot`; this entry point does not publish or copy them
into git. `Test-Tooling.ps1` tests lock refusal, numbered retry/root-completion
contracts, and lifecycle validation with deterministic fixtures only; it does
not invoke this entry point or a public workload.

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
sustained completions within 10 minutes is persisted immediately as a
non-retriable terminal outcome and cannot be downgraded by later cleanup.
Preparation resume requires the authoritative schema, exact bootstrap and
repository identities, all 19 clean pinned worktrees, and unchanged warmed
baseline hashes; `-SkipWarm` output is never authoritative. Before any retry,
affected worktrees are checked for overlap, explicit untracked
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
