# vs-green clean server node-count benchmark

**Result:** Twelve measured paired blocks compare no-Coordinator `/m:4`, `/m:8`, and `/m:16` for the full clean Debug `server\dirs.proj` traversal.

## Conclusion

`/m:8` had the lowest median duration at 139.5 seconds. Paired effects were +5.0% for N4-vs-N8, -0.5% for N16-vs-N8, and +5.5% for N4-vs-N16; positive values mean the numerator was slower.

- vs-green, `/m:8` vs `/m:16`: median commit growth fell by 334 MB (13.0%), descendant working set by 1024 MB (26.2%), and descendant private bytes by 473 MB (17.4%); relevant process peak fell from 43.0 to 27.0, queue p95 from 27.5 to 14.0, and probe p95 from 280 ms to 224 ms.
- vs-green, `/m:4` vs `/m:8`: median commit growth fell by 141 MB (6.3%), descendant working set by 473 MB (16.4%), and descendant private bytes by 206 MB (9.2%); relevant process peak fell from 27.0 to 15.0, queue p95 from 14.0 to 10.0, and probe p95 from 224 ms to 209 ms.

These are instantaneous pressure reductions from lower concurrency, not evidence that lower node counts perform the same work more efficiently.

## Paired duration and wall effects

Positive values mean the numerator condition was slower. Duration and wall are equal by design because every scenario contains one root build.

| Repository | Comparison | Blocks | Duration effect (descriptive 95% CI) | Wall effect (descriptive 95% CI) | Exact sign-flip p |
|---|---|---:|---:|---:|---:|
| vs-green | `N16-vs-N8` | 12 | -0.5% (-4.6%, +3.6%) | -0.5% (-4.4%, +3.5%) | 0.876953125 |
| vs-green | `N4-vs-N16` | 12 | +5.5% (+0.0%, +11.2%) | +5.5% (-0.1%, +11.2%) | 0.08935546875 |
| vs-green | `N4-vs-N8` | 12 | +5.0% (-0.6%, +11.1%) | +5.0% (-0.5%, +11.2%) | 0.130859375 |

The exact two-sided sign-flip test has 4,096 assignments at n=12 (minimum attainable two-sided p is 0.00048828125). The deterministic 10,000-resample intervals are descriptive whole-block resampling intervals, not high-confidence population guarantees.

## All measured block effects

| Repository | Comparison | Block | Denominator sec | Numerator sec | Duration effect |
|---|---|---:|---:|---:|---:|
| vs-green | `N16-vs-N8` | 1 | 137.50 | 138.52 | +0.7% |
| vs-green | `N16-vs-N8` | 2 | 136.77 | 140.71 | +2.9% |
| vs-green | `N16-vs-N8` | 3 | 140.86 | 139.43 | -1.0% |
| vs-green | `N16-vs-N8` | 4 | 137.34 | 139.76 | +1.8% |
| vs-green | `N16-vs-N8` | 5 | 140.35 | 138.59 | -1.3% |
| vs-green | `N16-vs-N8` | 6 | 162.76 | 138.02 | -15.2% |
| vs-green | `N16-vs-N8` | 7 | 159.02 | 145.14 | -8.7% |
| vs-green | `N16-vs-N8` | 8 | 139.75 | 137.62 | -1.5% |
| vs-green | `N16-vs-N8` | 9 | 139.34 | 162.34 | +16.5% |
| vs-green | `N16-vs-N8` | 10 | 141.51 | 141.68 | +0.1% |
| vs-green | `N16-vs-N8` | 11 | 136.87 | 138.86 | +1.5% |
| vs-green | `N16-vs-N8` | 12 | 137.93 | 140.02 | +1.5% |
| vs-green | `N4-vs-N16` | 1 | 138.52 | 149.89 | +8.2% |
| vs-green | `N4-vs-N16` | 2 | 140.71 | 160.40 | +14.0% |
| vs-green | `N4-vs-N16` | 3 | 139.43 | 134.81 | -3.3% |
| vs-green | `N4-vs-N16` | 4 | 139.76 | 149.11 | +6.7% |
| vs-green | `N4-vs-N16` | 5 | 138.59 | 135.05 | -2.6% |
| vs-green | `N4-vs-N16` | 6 | 138.02 | 148.67 | +7.7% |
| vs-green | `N4-vs-N16` | 7 | 145.14 | 148.12 | +2.1% |
| vs-green | `N4-vs-N16` | 8 | 137.62 | 150.50 | +9.4% |
| vs-green | `N4-vs-N16` | 9 | 162.34 | 140.65 | -13.4% |
| vs-green | `N4-vs-N16` | 10 | 141.68 | 178.13 | +25.7% |
| vs-green | `N4-vs-N16` | 11 | 138.86 | 138.27 | -0.4% |
| vs-green | `N4-vs-N16` | 12 | 140.02 | 165.40 | +18.1% |
| vs-green | `N4-vs-N8` | 1 | 137.50 | 149.89 | +9.0% |
| vs-green | `N4-vs-N8` | 2 | 136.77 | 160.40 | +17.3% |
| vs-green | `N4-vs-N8` | 3 | 140.86 | 134.81 | -4.3% |
| vs-green | `N4-vs-N8` | 4 | 137.34 | 149.11 | +8.6% |
| vs-green | `N4-vs-N8` | 5 | 140.35 | 135.05 | -3.8% |
| vs-green | `N4-vs-N8` | 6 | 162.76 | 148.67 | -8.7% |
| vs-green | `N4-vs-N8` | 7 | 159.02 | 148.12 | -6.9% |
| vs-green | `N4-vs-N8` | 8 | 139.75 | 150.50 | +7.7% |
| vs-green | `N4-vs-N8` | 9 | 139.34 | 140.65 | +0.9% |
| vs-green | `N4-vs-N8` | 10 | 141.51 | 178.13 | +25.9% |
| vs-green | `N4-vs-N8` | 11 | 136.87 | 138.27 | +1.0% |
| vs-green | `N4-vs-N8` | 12 | 137.93 | 165.40 | +19.9% |

## Duration and pressure by node count

Values are medians across 12 measured scenarios; duration and committed/working-set/private columns include the observed scenario range.

| Repo | Nodes | Duration sec (range) | Commit growth MB (range) | Descendant WS MB (range) | Descendant private MB (range) | Processes (range) | CPU median / p95 | Queue p95 | Probe p95 ms | Disk p95 MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| vs-green | 4 | 148.9 (134.8-178.1) | 2099 (1966-2218) | 2414 (2351-4225) | 2045 (1984-2530) | 15 (15-48) | 28.0% / 97.2% | 10.0 | 208.9 | 41.4 |
| vs-green | 8 | 139.5 (136.8-162.8) | 2240 (2051-2644) | 2887 (2840-7352) | 2251 (2204-6693) | 27 (25-213) | 29.9% / 97.6% | 14.0 | 223.6 | 40.0 |
| vs-green | 16 | 139.6 (137.6-162.3) | 2574 (2446-2733) | 3911 (3784-3976) | 2723 (2636-2821) | 43 (42-47) | 31.3% / 100.0% | 27.5 | 279.6 | 39.3 |

Lower node counts reduce concurrency and therefore can reduce instantaneous pressure; that does not establish greater intrinsic work efficiency. Disk telemetry is retained in `pressure-summary.csv`; it is descriptive and potentially sensitive to cache and background I/O.

## Validation

- Accepted exactly **39 scenarios**: 3 excluded warm-up and 36 measured.
- Accepted exactly **13 whole blocks**: 1 warm-up and 12 measured.
- Preserved invalid whole-block attempts: **0**.
- Replayed all **39 accepted binlogs** and found zero `CoordinatorNodeGrantReceived` events; accepted stdout and process telemetry also contain zero grant messages and zero Coordinator process samples.
- Accepted continuity maxima: system 2.016s, process 5.050s, probe 5.063s. System warning gaps above 5s: 0.
- Measured order balance is exactly **0/0** for position/carryover imbalance.
- All accepted build exits, root PIDs, OS timestamps, binlogs, whitespace-only stderr, restore-only setup placeholders, clean post-restore statuses, hashes, preparation smokes, keep-awake restoration, final worktrees, and process cleanup validated.

## Context only: larger repositories

The separate Roslyn/Aspire node-count run found `/m:16` fastest, with `/m:8` trading 5.8%-13.2% wall time for lower pressure and `/m:4` costing substantially more. Those roots are contextual only and are not pooled with this vs-green analysis.

## Identities

- Repository SDK MSBuild: `18.8.0-preview-26302-115+f7b4c5716faaee8fb8a289aed29118cad955c45f`
- Repository SDK `MSBuild.dll` SHA256: `EF3F5C82A9269A479AAB3A394CC23849B324B408867270FA2408FF9AD59450D1`
- Repository SDK `dotnet.exe` SHA256: `D4C9086DCE1DC81BBE7F0DCCB0B96BB3E980CC375E059A731B7F7962220AA19E`
- vs-green: `7eaba546bcd220e97afc66159a63c4051a44d4e6`
- Run root: `C:\perf\results\vs-green-node-count-clean-server-20260806-111702`
