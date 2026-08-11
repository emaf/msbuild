# MSBuild Coordinator priority and node-policy evidence

This package consolidates the accepted benchmark evidence for dotnet/msbuild PR #14241. It does not contain or modify the product branch. All package links are relative. Historical launch records and source CSVs are preserved byte-for-byte, so fields inside those original records retain the absolute paths that were recorded on the benchmark machine.

## Executive summary

The evidence supports four separate conclusions:

1. **The priority protocol itself did not measurably regress compatibility mode.** With reservation and cap explicitly set to `0/0`, the priority candidate was within the paired uncertainty interval of the pre-priority Coordinator for delayed-build latency, average Normal latency, and total wall time in both repositories.
2. **High priority makes the delayed build complete sooner under fixed 4/4.** In the ten-block primary matrix, the delayed High build completed 9.1% sooner for Roslyn and 19.5% sooner for Aspire than the delayed Normal control. Normal builds completed later, and total wall time increased.
3. **Eight nodes are the useful solo-build compromise on this 16-logical-processor machine.** Relative to 16 nodes, eight nodes completed 6.2% later for Roslyn and 15.2% later for Aspire, while using 19-30% less median memory. Four nodes completed another 19.8-34.4% later than eight.
4. **Idle-8 is functionally correct but has a first-recipient tradeoff under immediate Normal contention.** It always produced one initial 8-node grant and later 4-node grants, and delayed High always received 4 while the burst Normal was still active. Compared with fixed 4/4, however, all-Normal wall time was 12.2% slower for Roslyn and 1.7% slower for Aspire.

The idle matrix contains **four measured balanced blocks per repository**. Four is the smallest complete Williams cycle for four conditions. Its minimum attainable two-sided exact sign-flip p-value is **0.125**, so its effects are **descriptive and directional, not statistically significant**.

## Conditions

### Primary priority matrix

| Key | Binary | Coordinator policy | Delayed build |
|---|---|---|---|
| A | priority candidate | disabled | Normal |
| B | pre-priority base | enabled, uncapped, no reservation | Normal |
| C | priority candidate | explicit compatibility `0/0` | Normal |
| D | priority candidate | explicit fixed cap/reservation `4/4` | Normal |
| E | priority candidate | explicit fixed cap/reservation `4/4` | High |

### Idle-burst matrix

| Key | Policy | Delayed build |
|---|---|---|
| F4-N | explicit fixed cap/reservation `4/4` | Normal |
| AUTO-N | computed defaults: 4-node slice, 4-node High reserve, idle ceiling 8 | Normal |
| F4-H | explicit fixed cap/reservation `4/4` | High |
| AUTO-H | computed defaults: 4-node slice, 4-node High reserve, idle ceiling 8 | High |

## Methodology

- Repositories were pinned to exact commits and built from detached worktrees.
- Base and candidate bootstraps were built with the same command, checked by ProductVersion and SHA-256, then copied to short, immutable, content-addressed paths.
- Each scenario used four initial Normal builds plus one build started after 15 seconds. In High conditions only the delayed build's priority changed.
- `solution-propagated` touched one tracked source file's timestamp before launching the builds:
  - Roslyn: `src/Compilers/Core/Portable/Diagnostic/Diagnostic.cs`
  - Aspire: `src/Aspire.Hosting/DistributedApplication.cs`
- Restore and warm-up ran before measured scenarios. Timed builds used `--no-restore` semantics through direct `dotnet MSBuild.dll` invocation.
- Conditions were ordered with Williams designs. Accepted measured orders have exact zero position imbalance and zero first-order carryover imbalance.
- Whole blocks, not individual scenarios, were retried or excluded.
- System counters were sampled every 1 second. Full process snapshots and responsiveness probes were sampled every 5 seconds.
- A system gap above 5 seconds was retained as a warning. A system gap above 30 seconds, process-snapshot gap above 15 seconds, or probe gap above 15 seconds invalidated the whole block.
- Duration effects use the mean of paired within-block log ratios. Displayed baseline and candidate values are geometric means of the corresponding measured block values.
- Intervals are deterministic 10,000-resample whole-block descriptive intervals:
  - Primary priority matrix seed: `20260723`
  - Node-count matrix seed: `20260805`
  - Idle-burst matrix seed: `20260808`
- Exact two-sided p-values enumerate all sign flips.
- Memory comparisons use medians across measured scenarios and are descriptive; no inferential interval is attached to those median ratios.

## Machine

| Property | Value |
|---|---|
| CPU | AMD EPYC 7763 64-Core Processor |
| Physical cores presented to VM | 8 |
| Logical processors | 16 |
| Sockets | 1 |
| Installed RAM | 68,665,831,424 bytes (63.950 GiB) |
| OS | Microsoft Windows 11 Enterprise, 64-bit |
| OS version/build | 10.0.26200 / 26200 |
| Power plan | High performance; AC minimum and maximum processor state both 100% |
| Storage | Microsoft virtual disk, SAS bus, 2 TiB; media type reported as `Unspecified`, so SSD/HDD is unknown |
| Virtualization | Yes. Microsoft Corporation `Virtual Machine`; hypervisor present |
| PowerShell | 7.6.4 Core |

Full machine, power, PowerShell, and `dotnet --info` captures are under [`machine/`](machine/).

## Source and binary identities

### Priority matrix

| Role | Commit | `MSBuild.dll` SHA-256 | `dotnet.exe` SHA-256 |
|---|---|---|---|
| Pre-priority base | `a6ed776c8af17d3ba790a30e2d171a7191abae55` | `447628A8D2F0186DA89C073BAD32ED80CA30171289E6A0781ED1F7112A220ED5` | `C9223FD508FA6707F3E78F7174CF481402B93B325B35D56CA711BB7D5D921F18` |
| Priority candidate | `8fe6721c8d5899c330b247918c46fb7359193981` | `1F456A53A870607963D61FBA9B80709B34EDF82EA60DB093DF8AF7C6C76A9409` | `C9223FD508FA6707F3E78F7174CF481402B93B325B35D56CA711BB7D5D921F18` |

Both used SDK `11.0.100-preview.7.26360.111`, host `11.0.0-preview.7.26360.111`, x64.

### Idle-burst matrix

| Role | Commit | `MSBuild.dll` SHA-256 | `dotnet.exe` SHA-256 |
|---|---|---|---|
| Idle-burst candidate | `dcf76ee0204f7d94776079b4293c043ccec0ad0c` | `F8B91508ED12DA6C4BFE0CF0125AB9705410D32F93CCCB165B4A95FA5F37166B` | `CBB1746F9B08DD9825129D451D99869E84E9024E62C804DEDE22C9FB61E0291D` |

It used SDK `10.0.300`, host `10.0.8`, x64.

### Workloads

| Repository | URL | Commit | Workload |
|---|---|---|---|
| Roslyn | https://github.com/dotnet/roslyn | `bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b` | `Compilers.slnf` |
| Aspire | https://github.com/dotnet/aspire | `110a63da8357af437a00d9efc5887ffdcbdfbb3c` | `Aspire-Core.slnf` |

Aspire always included `/p:InstallBrowsersForPlaywright=false`. No source patch was applied. Propagated builds changed only the `LastWriteTimeUtc` of the touched files listed in the methodology. Clean node-count scenarios ran `git reset --hard <commit>` and `git clean -xdf -q` before restore.

The machine-readable identity record is [`identities/source-and-binary-identities.json`](identities/source-and-binary-identities.json).

## Results with baselines, candidates, and denominators

Every percentage below uses:

```text
100 * (candidate value / baseline value - 1)
```

For paired duration rows, the values shown are geometric means and the percentage is exactly the paired block-log-ratio estimate. For memory rows, values are measured-scenario medians.

### AUTO-H relative to AUTO-N

Baseline is automatic policy with a delayed Normal build. Candidate is automatic policy with a delayed High build.

| Repo | Metric | Baseline | Candidate | Result | Descriptive 95% interval | Exact p |
|---|---|---:|---:|---|---|---:|
| Roslyn | delayed build | 160.319 s | 90.061 s | High completed **43.8% sooner** | 40.1-46.6% sooner | .125 |
| Roslyn | average Normal | 124.798 s | 132.682 s | Normals completed **6.3% later** | 2.1-10.9% later | .125 |
| Roslyn | total wall | 177.364 s | 175.526 s | scenario finished **1.0% sooner** | 5.6% sooner to 3.3% later | .750 |
| Aspire | delayed build | 121.490 s | 92.565 s | High completed **23.8% sooner** | 21.5-26.7% sooner | .125 |
| Aspire | average Normal | 96.301 s | 102.867 s | Normals completed **6.8% later** | 4.2-8.8% later | .125 |
| Aspire | total wall | 136.874 s | 130.673 s | scenario finished **4.5% sooner** | 1.6-7.3% sooner | .125 |

These are directional because `n=4`; no row can attain a two-sided exact p-value below .125.

### AUTO-N relative to fixed F4-N

Baseline is fixed 4/4 with all Normal builds. Candidate is computed idle-8 with all Normal builds.

| Repo | Metric | Baseline | Candidate | Result | Descriptive 95% interval | Exact p |
|---|---|---:|---:|---|---|---:|
| Roslyn | total wall | 158.052 s | 177.364 s | AUTO-N finished **12.2% later** | 11.1-14.1% later | .125 |
| Roslyn | average Normal | 108.209 s | 124.798 s | Normals completed **15.3% later** | 11.1-19.2% later | .125 |
| Aspire | total wall | 134.590 s | 136.874 s | AUTO-N finished **1.7% later** | 1.5% sooner to 4.7% later | .500 |
| Aspire | average Normal | 89.779 s | 96.301 s | Normals completed **7.3% later** | 2.9-10.6% later | .125 |

| Repo | Median memory metric | Fixed F4-N | AUTO-N | Result |
|---|---|---:|---:|---|
| Roslyn | commit growth | 5221.141 MiB | 4269.410 MiB | AUTO-N used **18.2% less** |
| Roslyn | descendant working set | 6480.057 MiB | 4960.830 MiB | AUTO-N used **23.4% less** |
| Roslyn | descendant private memory | 5269.992 MiB | 3891.469 MiB | AUTO-N used **26.2% less** |
| Aspire | commit growth | 3623.836 MiB | 3408.943 MiB | AUTO-N used **5.9% less** |
| Aspire | descendant working set | 4398.670 MiB | 4150.293 MiB | AUTO-N used **5.6% less** |
| Aspire | descendant private memory | 3168.455 MiB | 3034.949 MiB | AUTO-N used **4.2% less** |

### Four nodes relative to eight for isolated clean solutions

Baseline is `/m:8`; candidate is `/m:4`. Each repository has six measured paired blocks.

| Repo | Baseline | Candidate | Result | Descriptive 95% interval | Exact p |
|---|---:|---:|---|---|---:|
| Roslyn | 456.216 s | 613.343 s | four nodes finished **34.4% later** | 27.5-41.8% later | .03125 |
| Aspire | 300.943 s | 360.577 s | four nodes finished **19.8% later** | 15.6-24.6% later | .03125 |
| vs-green (supplementary) | 142.268 s | 149.430 s | four nodes finished **5.0% later** | 0.5% sooner to 11.2% later | .13086 |

### Eight nodes relative to sixteen for isolated clean solutions

Baseline is `/m:16`; candidate is `/m:8`. The wall percentages below are the reciprocal orientation of the source `N16-vs-N8` paired estimates.

| Repo | Baseline | Candidate | Result | Descriptive 95% interval | Exact p |
|---|---:|---:|---|---|---:|
| Roslyn | 429.636 s | 456.216 s | eight nodes finished **6.2% later** | 1.9-11.5% later | .0625 |
| Aspire | 261.332 s | 300.943 s | eight nodes finished **15.2% later** | 7.4-23.1% later | .0625 |
| vs-green (supplementary) | 141.585 s | 142.268 s | eight nodes finished **0.5% later** | 3.4% sooner to 4.6% later | .87695 |

| Repo | Median memory metric | N16 | N8 | Result |
|---|---|---:|---:|---|
| Roslyn | commit growth | 5975.271 MiB | 4576.408 MiB | N8 used **23.4% less** |
| Roslyn | descendant working set | 7181.359 MiB | 5017.680 MiB | N8 used **30.1% less** |
| Roslyn | descendant private memory | 5595.982 MiB | 4238.643 MiB | N8 used **24.3% less** |
| Aspire | commit growth | 3777.443 MiB | 2882.934 MiB | N8 used **23.7% less** |
| Aspire | descendant working set | 5016.578 MiB | 3736.211 MiB | N8 used **25.5% less** |
| Aspire | descendant private memory | 3210.703 MiB | 2612.338 MiB | N8 used **18.6% less** |
| vs-green | commit growth | 2574.254 MiB | 2240.217 MiB | N8 used **13.0% less** |
| vs-green | descendant working set | 3911.201 MiB | 2887.400 MiB | N8 used **26.2% less** |
| vs-green | descendant private memory | 2723.455 MiB | 2250.768 MiB | N8 used **17.4% less** |

### Explicit compatibility 0/0 candidate relative to pre-priority Coordinator

Baseline B is the pre-priority Coordinator. Candidate C is the priority candidate with explicit reservation/cap `0/0`. Each repository has ten measured paired blocks.

| Repo | Metric | Baseline | Candidate | Result | 95% interval | Exact p |
|---|---|---:|---:|---|---|---:|
| Roslyn | delayed build | 170.218 s | 165.222 s | candidate completed **2.9% sooner** | 8.7% sooner to 4.2% later | .420 |
| Roslyn | average Normal | 162.645 s | 162.854 s | Normals completed **0.1% later** | 3.1% sooner to 3.7% later | .943 |
| Roslyn | total wall | 201.531 s | 201.642 s | scenario finished **0.1% later** | 3.7% sooner to 4.1% later | .982 |
| Aspire | delayed build | 126.839 s | 122.007 s | candidate completed **3.8% sooner** | 9.1% sooner to 2.1% later | .242 |
| Aspire | average Normal | 119.427 s | 115.874 s | Normals completed **3.0% sooner** | 7.8% sooner to 1.8% later | .250 |
| Aspire | total wall | 143.748 s | 140.011 s | scenario finished **2.6% sooner** | 7.7% sooner to 2.7% later | .389 |

All intervals cross no change. The evidence does not detect protocol/branch overhead in explicit compatibility mode.

### Fixed 4/4 delayed High relative to fixed 4/4 all-Normal

The ten-block original priority matrix gives the stronger estimate:

| Repo | Metric | Baseline D | Candidate E | Result | 95% interval | Exact p |
|---|---|---:|---:|---|---|---:|
| Roslyn | delayed build | 143.142 s | 130.165 s | High completed **9.1% sooner** | 2.3-16.3% sooner | .031 |
| Roslyn | average Normal | 108.091 s | 128.961 s | Normals completed **19.3% later** | 13.5-25.6% later | .002 |
| Roslyn | total wall | 159.693 s | 170.850 s | scenario finished **7.0% later** | 1.4-12.7% later | .051 |
| Aspire | delayed build | 111.963 s | 90.176 s | High completed **19.5% sooner** | 15.8-22.6% sooner | .002 |
| Aspire | average Normal | 84.597 s | 97.670 s | Normals completed **15.5% later** | 10.7-21.4% later | .002 |
| Aspire | total wall | 127.623 s | 132.593 s | scenario finished **3.9% later** | 0.1% sooner to 8.8% later | .137 |

The contemporaneous four-block F4 matrix independently reproduced the direction:

| Repo | Metric | F4-N | F4-H | Result | Directional interval | Exact p |
|---|---|---:|---:|---|---|---:|
| Roslyn | delayed build | 142.049 s | 128.783 s | High completed **9.3% sooner** | 4.7-16.5% sooner | .125 |
| Roslyn | average Normal | 108.209 s | 121.687 s | Normals completed **12.5% later** | 11.4-13.6% later | .125 |
| Roslyn | total wall | 158.052 s | 161.487 s | scenario finished **2.2% later** | 1.1-3.3% later | .125 |
| Aspire | delayed build | 119.205 s | 87.284 s | High completed **26.8% sooner** | 20.8-31.0% sooner | .125 |
| Aspire | average Normal | 89.779 s | 101.791 s | Normals completed **13.4% later** | 9.9-17.2% later | .125 |
| Aspire | total wall | 134.590 s | 136.120 s | scenario finished **1.1% later** | 0.6% sooner to 2.9% later | .500 |

The package-local [`recomputed-comparisons.csv`](recomputed-comparisons.csv) and [`scripts/Recompute-PortableComparisons.ps1`](scripts/Recompute-PortableComparisons.ps1) regenerate these values from the accepted source CSVs.

## Binlog grant verification

The idle-burst analyzer replayed all 200 accepted binlogs, covering 72,231,961 events:

- Every accepted build had exactly one `CoordinatorNodeGrantReceived` event.
- Every measured AUTO scenario had exactly one initial 8-node grant and four 4-node grants.
- Every fixed F4 scenario had five 4-node grants and no 8-node grant.
- All eight measured AUTO-H delayed High builds received 4 while the initial 8-node Normal remained active. Their grant delays were 1.681-8.875 seconds; "immediate" here means before any initial Normal completed, not zero scheduling delay.
- The burst Normal had 46.9-99.5 seconds remaining when High received its grant.
- Using a predeclared grant-delay threshold of at least 20 seconds to identify queue-drained requests, all 80 queue-drained grants were 4 and none were 8.

The compact validation outputs are:

- [`evidence/idle-burst/grant-validation.json`](evidence/idle-burst/grant-validation.json)
- [`evidence/idle-burst/grant-sequences.csv`](evidence/idle-burst/grant-sequences.csv)
- [`evidence/idle-burst/grant-events.csv`](evidence/idle-burst/grant-events.csv)
- [`evidence/idle-burst/grant-scan.json`](evidence/idle-burst/grant-scan.json)

The short smoke's eight small raw binlogs are included under [`raw/functional-smoke/`](raw/functional-smoke/). Full accepted benchmark binlogs total approximately 4.91 GiB before compression and are indexed separately rather than embedded in the compact package.

## Exact execution details

### Common build commands

Base and priority-candidate bootstraps:

```powershell
.\build.cmd -configuration Release -msbuildEngine dotnet -verbosity quiet /p:CreateTlb=false /p:RuntimeOutputTargetFrameworks=net11.0
```

Restore outside timing:

```powershell
& $DotNet $MSBuildDll $BuildPath /t:Restore /v:q /nodeReuse:false /p:UseSharedCompilation=false @AdditionalBuildArguments
```

Warm-up:

```powershell
& $DotNet $MSBuildDll $BuildPath /m:16 /v:q /nodeReuse:false /p:UseSharedCompilation=false @AdditionalBuildArguments
```

Timed build:

```powershell
& $DotNet $MSBuildDll $BuildPath /m:16 /v:q /nodeReuse:false /p:UseSharedCompilation=false "/bl:$Binlog;ProjectImports=None" @AdditionalBuildArguments
```

### Primary priority matrix

The exact execution scripts are under [`scripts/priority-execution-tooling/`](scripts/priority-execution-tooling/). No durable wrapper artifact survived for this older run. The following complete orchestrator invocation is reconstructed from immutable `run-metadata.json` plus the approved session launch record:

```powershell
& .\scripts\priority-execution-tooling\Run-PublicRepoCoordinatorMatrix.ps1 `
  -BaseBootstrapRoot $BaseBootstrap `
  -BaseExpectedCommit a6ed776c8af17d3ba790a30e2d171a7191abae55 `
  -CandidateBootstrapRoot $CandidateBootstrap `
  -CandidateExpectedCommit 8fe6721c8d5899c330b247918c46fb7359193981 `
  -RoslynRoot $RoslynRoot `
  -RoslynExpectedCommit bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b `
  -RoslynWorkRoot $RoslynWorkRoot `
  -AspireRoot $AspireRoot `
  -AspireExpectedCommit 110a63da8357af437a00d9efc5887ffdcbdfbb3c `
  -AspireWorkRoot $AspireWorkRoot `
  -OutputRoot $OutputRoot `
  -BootstrapStagingRoot $StagingRoot `
  -Workload solution-propagated `
  -ConditionKeys A-no-coordinator,B-base-coordinator,C-candidate-compat,D-candidate-default-normal,E-candidate-default-high `
  -WarmupBlocks 1 `
  -PrimaryBlocks 10 `
  -NodeBudget 16 `
  -NormalBuildCount 4 `
  -CandidateBuildCount 1 `
  -CandidateDelaySeconds 15 `
  -CandidateOffsetMinimumSeconds 14 `
  -CandidateOffsetMaximumSeconds 18 `
  -SystemGapWarningThresholdSeconds 5 `
  -MaxSystemCounterGapSeconds 30 `
  -MaxProcessSnapshotGapSeconds 15 `
  -MaxProbeGapSeconds 15 `
  -MaximumBlockAttempts 3 `
  -CooldownSeconds 30
```

The run used one excluded warm-up and ten measured blocks per repository. It completed the matrix in 15.26 hours and analysis in 15.34 hours from launch. There were zero invalid attempts or retries.

### Idle-burst matrix

The exact launcher is [`scripts/idle-tooling/Launch-AuthoritativeMatrix.ps1`](scripts/idle-tooling/Launch-AuthoritativeMatrix.ps1), and its durable records are under [`launch-records/idle-burst/`](launch-records/idle-burst/). The invocation was:

```powershell
pwsh -NoProfile -File .\scripts\idle-tooling\Launch-AuthoritativeMatrix.ps1
```

The inner parameter set is preserved in the launcher and `launch-records/idle-burst/start.json`. It used one excluded warm-up and four measured blocks per repository, delay 15 seconds, 5/30/15/15 continuity limits, maximum three attempts, and 30 seconds cooldown. The run completed in 3.65 hours with zero invalid attempts or retries.

### Node-count matrix

The exact specialized runner and unchanged harness/monitor copies are under [`scripts/node-count-tooling/`](scripts/node-count-tooling/). The accepted invocation used:

```powershell
& .\scripts\node-count-tooling\Run-NodeCountCleanSolutionMatrix.ps1 `
  -BaseBootstrapRoot $CandidateBootstrap `
  -BaseExpectedCommit 8fe6721c8d5899c330b247918c46fb7359193981 `
  -CandidateBootstrapRoot $CandidateBootstrap `
  -CandidateExpectedCommit 8fe6721c8d5899c330b247918c46fb7359193981 `
  -RoslynRoot $RoslynRoot `
  -RoslynExpectedCommit bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b `
  -RoslynWorkRoot $RoslynWorkRoot `
  -AspireRoot $AspireRoot `
  -AspireExpectedCommit 110a63da8357af437a00d9efc5887ffdcbdfbb3c `
  -AspireWorkRoot $AspireWorkRoot `
  -OutputRoot $OutputRoot `
  -BootstrapStagingRoot $StagingRoot `
  -Workload solution-clean `
  -ConditionKeys N4,N8,N16 `
  -WarmupBlocks 1 `
  -PrimaryBlocks 6 `
  -NormalBuildCount 1 `
  -CandidateBuildCount 0 `
  -BuildConfiguration Release `
  -SystemGapWarningThresholdSeconds 5 `
  -MaxSystemCounterGapSeconds 30 `
  -MaxProcessSnapshotGapSeconds 15 `
  -MaxProbeGapSeconds 15 `
  -MaximumBlockAttempts 3
```

Before every timed build, it hard-reset and cleaned the worktree, restored at the condition's node count, verified clean status, and shut down build servers. The matrix took 14.47 hours. Aspire measured block 3 attempt 1 was excluded as a whole because machine sleep produced system/process/probe gaps of 31,519.038/31,523.759/31,523.797 seconds. Attempt 2 was accepted in full.

**Recorded configuration inconsistency:** `run-metadata.json` records `BuildConfiguration=Release`, but the specialized runner did not pass `/p:Configuration=Release`; preparation-smoke properties show `Configuration=Debug`. Treat the accepted node-count workloads as Debug builds. The node-count timing and pressure comparisons remain internally consistent because every condition used the same effective configuration.

### Environment variables

The harness first removes all Coordinator variables from each child environment:

```text
MSBUILDUSECOORDINATOR
MSBUILDCOORDINATORPIPENAME
MSBUILDCOORDINATORNODEBUDGET
MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES
MSBUILDCOORDINATORMAXNODESPERBUILD
MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD
MSBUILDCOORDINATORBUILDREQUESTPRIORITY
```

Coordinator conditions then set:

```text
MSBUILDUSECOORDINATOR=1
MSBUILDCOORDINATORPIPENAME=<unique per scenario>
MSBUILDCOORDINATORNODEBUDGET=16
MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD=3
MSBUILDCOORDINATORBUILDREQUESTPRIORITY=Normal|High
DOTNET_ROOT=<staged bootstrap>
DOTNET_ROOT_X64=<staged bootstrap>
DOTNET_CLI_TELEMETRY_OPTOUT=1
```

Explicit fixed conditions additionally set:

```text
MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES=4
MSBUILDCOORDINATORMAXNODESPERBUILD=4
```

Explicit compatibility conditions set both values to `0`. AUTO conditions deliberately leave both variables absent so the computed defaults are exercised.

## Short reproduction

[`scripts/short-reproduction/Run-GrantSmoke.ps1`](scripts/short-reproduction/Run-GrantSmoke.ps1) is the exact functional smoke used for the reported grant sequence. It needs a built idle-burst bootstrap and runs in approximately **4 minutes 23 seconds** on the benchmark VM:

```powershell
dotnet build .\scripts\short-reproduction\GrantScan\GrantScan.csproj -c Release

pwsh .\scripts\short-reproduction\Run-GrantSmoke.ps1 `
  -BootstrapRoot C:\path\to\idle-burst\bootstrap\core `
  -OutputRoot (Join-Path $PWD 'short-reproduction-output')
```

Expected `grant-summary.csv`:

```text
AUTO three Normal: 8, 4, queued -> 4
AUTO delayed High: Normal 8, High 4
fixed 4/4: 4
explicit 0/0: 16
explicit cap 8/reserve 4: 8
```

Validation requires exit code zero, exactly one grant event per binlog, whitespace-only stderr, High grant timestamp before the initial Normal exits, and the queued third Normal's grant timestamp after the burst grant is released.

This smoke validates policy and queue transitions, not performance. The multi-hour matrices remain the performance evidence; reviewers do not need to rerun them.

## Scripts and differences from the product branch

- Priority execution used commit `47bcf317a145dcf04cf76d889da9d580a89142e7`; exact files are in [`scripts/priority-execution-tooling/`](scripts/priority-execution-tooling/).
- Primary analysis was regenerated with commit `3029d6fe65db84b4c31064c7f69f2f1a5acd7814`; exact files are in [`scripts/priority-analysis-tooling/`](scripts/priority-analysis-tooling/).
- Idle execution used benchmark-tooling commit `068fcdd37763c595b38898533d31f2ff8329e2b2`; exact files and the custom launcher/analyzer are in [`scripts/idle-tooling/`](scripts/idle-tooling/).
- Node-count execution used the preserved specialized runner in [`scripts/node-count-tooling/`](scripts/node-count-tooling/).
- The product-branch harness and machine-generated no-index diffs are in [`scripts/product-branch/`](scripts/product-branch/).

The benchmark-only versions add or refine restore-only preparation, root PID and OS timestamps, per-build binlogs, split system/process/probe telemetry, short immutable bootstrap staging, Williams-balanced orchestration, whole-block retries, clean-workload reset/restore, automatic-policy omission of explicit cap/reservation variables, and paired analysis. They are preserved here and are not assumed to be committed in the product PR.

## Validity, exclusions, and limitations

- Primary priority matrix: 110 scenarios, 550 successful builds/binlogs, 22 valid blocks including two excluded warm-ups, zero invalid attempts or retries.
- Idle-burst matrix: 40 scenarios, 200 successful builds/binlogs, ten valid blocks including two excluded warm-ups, zero invalid attempts or retries.
- Node-count matrix: 42 accepted scenarios and 14 accepted blocks; one sleep-contaminated whole-block attempt excluded and retried.
- vs-green supplementary matrix: 39 accepted scenarios, 13 valid blocks, zero invalid attempts. It is included as small-repository context but not pooled into Roslyn/Aspire estimates.
- Results come from one virtualized Windows machine and two large public repositories. They do not establish effects on every graph, OS, CPU topology, or storage device.
- Disk media type was not reported, and the VM's physical host topology is unknown.
- Four-block idle estimates are directional and scheduling-sensitive.
- Six-block node-count exact tests are highly discrete.
- The original PR branch tip observed during packaging was `1804bcddbb8d5252c535834f66d0192de0bc5953`; the tested priority and idle-burst binaries are the explicitly identified historical/follow-up commits above, not that branch tip.
- Source comparison labels such as `B-vs-C` and `D-vs-E` are historical names. Their denominator/numerator fields and the baseline/candidate orientation in this report are authoritative.
- The package contains compact raw smoke binlogs and complete derived grant scans. Full benchmark binlogs are separately indexed because they total approximately 4.91 GiB uncompressed.

## Package contents

- [`recomputed-comparisons.csv`](recomputed-comparisons.csv): all requested baseline/candidate/formula rows.
- [`evidence/priority/`](evidence/priority/): primary summaries, paired rows, process-tree memory metrics, and validation.
- [`evidence/idle-burst/`](evidence/idle-burst/): duration, pressure, grant replay, sequence, and validation summaries.
- [`evidence/node-count/`](evidence/node-count/): no-Coordinator node-count report and source summaries.
- [`evidence/vs-green/`](evidence/vs-green/): small-repository supplemental evidence.
- [`launch-records/`](launch-records/): durable launch records.
- [`scripts/`](scripts/): exact execution, analysis, scanner, and short-reproduction files.
- [`manifest.csv`](manifest.csv): every included file, byte length, SHA-256, and relative path.
- [`SHA256SUMS.txt`](SHA256SUMS.txt): conventional checksum list.
