# Clean full-solution node-count benchmark

**Result:** Six measured paired blocks per repository show whether no-Coordinator `/m:8` is faster than `/m:4` and `/m:16`; effects are descriptive/directional because n=6.

## Conclusion

`/m:16`, not `/m:8`, was fastest in both repositories. Relative to `/m:8`, `/m:16` reduced paired wall time by 5.8% for Roslyn and 13.2% for Aspire. `/m:4` was not a modest time tradeoff: it was 34.4% slower than `/m:8` for Roslyn and 19.8% slower for Aspire (42.8% and 38.0% slower than `/m:16`).

- roslyn, `/m:8` vs `/m:16`: median commit growth fell by 1399 MB (23.4%), descendant working set by 2164 MB (30.1%), and descendant private bytes by 1357 MB (24.3%); relevant process peak fell from 53.0 to 31.0, queue p95 from 73.5 to 46.0, and probe p95 from 1669 ms to 1068 ms.
- roslyn, `/m:4` vs `/m:8`: median commit growth fell by 1644 MB (35.9%), descendant working set by 1958 MB (39.0%), and descendant private bytes by 1532 MB (36.1%); relevant process peak fell from 31.0 to 15.0, queue p95 from 46.0 to 17.5, and probe p95 from 1068 ms to 306 ms.
- aspire, `/m:8` vs `/m:16`: median commit growth fell by 895 MB (23.7%), descendant working set by 1280 MB (25.5%), and descendant private bytes by 598 MB (18.6%); relevant process peak fell from 57.5 to 33.0, queue p95 from 82.5 to 54.0, and probe p95 from 1245 ms to 807 ms.
- aspire, `/m:4` vs `/m:8`: median commit growth fell by 610 MB (21.1%), descendant working set by 1079 MB (28.9%), and descendant private bytes by 579 MB (22.2%); relevant process peak fell from 33.0 to 16.0, queue p95 from 54.0 to 29.0, and probe p95 from 807 ms to 426 ms.

These are instantaneous pressure reductions from lower concurrency, not evidence that lower node counts perform the same work more efficiently.

## Paired duration and wall effects

Positive values mean the numerator condition was slower. Duration and wall are equal by design because every scenario contains one root build.

| Repository | Comparison | Blocks | Duration effect (descriptive 95% CI) | Wall effect (descriptive 95% CI) | Exact sign-flip p |
|---|---|---:|---:|---:|---:|
| aspire | `N16-vs-N8` | 6 | -13.2% (-18.7%, -6.7%) | -13.2% (-18.7%, -6.8%) | 0.0625 |
| aspire | `N4-vs-N16` | 6 | +38.0% (+29.1%, +47.6%) | +38.0% (+29.1%, +47.6%) | 0.03125 |
| aspire | `N4-vs-N8` | 6 | +19.8% (+15.6%, +24.6%) | +19.8% (+15.6%, +24.6%) | 0.03125 |
| roslyn | `N16-vs-N8` | 6 | -5.8% (-10.3%, -1.8%) | -5.8% (-10.3%, -1.8%) | 0.0625 |
| roslyn | `N4-vs-N16` | 6 | +42.8% (+37.0%, +49.6%) | +42.8% (+37.0%, +49.6%) | 0.03125 |
| roslyn | `N4-vs-N8` | 6 | +34.4% (+27.5%, +41.8%) | +34.4% (+27.5%, +41.8%) | 0.03125 |

The exact two-sided sign-flip test has only 64 assignments at n=6, so p-values are highly discrete (minimum attainable two-sided p is 0.03125). The deterministic 10,000-resample intervals are descriptive whole-block resampling intervals, not high-confidence population guarantees.

## All measured block effects

| Repository | Comparison | Block | Denominator sec | Numerator sec | Duration effect |
|---|---|---:|---:|---:|---:|
| aspire | `N16-vs-N8` | 1 | 306.63 | 253.30 | -17.4% |
| aspire | `N16-vs-N8` | 2 | 316.06 | 264.70 | -16.3% |
| aspire | `N16-vs-N8` | 3 | 295.14 | 256.49 | -13.1% |
| aspire | `N16-vs-N8` | 4 | 308.92 | 236.87 | -23.3% |
| aspire | `N16-vs-N8` | 5 | 284.16 | 285.97 | +0.6% |
| aspire | `N16-vs-N8` | 6 | 295.86 | 273.44 | -7.6% |
| aspire | `N4-vs-N16` | 1 | 253.30 | 399.11 | +57.6% |
| aspire | `N4-vs-N16` | 2 | 264.70 | 357.01 | +34.9% |
| aspire | `N4-vs-N16` | 3 | 256.49 | 353.57 | +37.8% |
| aspire | `N4-vs-N16` | 4 | 236.87 | 353.81 | +49.4% |
| aspire | `N4-vs-N16` | 5 | 285.97 | 351.04 | +22.8% |
| aspire | `N4-vs-N16` | 6 | 273.44 | 351.25 | +28.5% |
| aspire | `N4-vs-N8` | 1 | 306.63 | 399.11 | +30.2% |
| aspire | `N4-vs-N8` | 2 | 316.06 | 357.01 | +13.0% |
| aspire | `N4-vs-N8` | 3 | 295.14 | 353.57 | +19.8% |
| aspire | `N4-vs-N8` | 4 | 308.92 | 353.81 | +14.5% |
| aspire | `N4-vs-N8` | 5 | 284.16 | 351.04 | +23.5% |
| aspire | `N4-vs-N8` | 6 | 295.86 | 351.25 | +18.7% |
| roslyn | `N16-vs-N8` | 1 | 469.31 | 424.16 | -9.6% |
| roslyn | `N16-vs-N8` | 2 | 448.37 | 448.52 | +0.0% |
| roslyn | `N16-vs-N8` | 3 | 443.57 | 442.28 | -0.3% |
| roslyn | `N16-vs-N8` | 4 | 466.56 | 420.99 | -9.8% |
| roslyn | `N16-vs-N8` | 5 | 427.85 | 425.20 | -0.6% |
| roslyn | `N16-vs-N8` | 6 | 483.91 | 417.57 | -13.7% |
| roslyn | `N4-vs-N16` | 1 | 424.16 | 568.87 | +34.1% |
| roslyn | `N4-vs-N16` | 2 | 448.52 | 610.77 | +36.2% |
| roslyn | `N4-vs-N16` | 3 | 442.28 | 654.80 | +48.1% |
| roslyn | `N4-vs-N16` | 4 | 420.99 | 660.55 | +56.9% |
| roslyn | `N4-vs-N16` | 5 | 425.20 | 583.48 | +37.2% |
| roslyn | `N4-vs-N16` | 6 | 417.57 | 607.14 | +45.4% |
| roslyn | `N4-vs-N8` | 1 | 469.31 | 568.87 | +21.2% |
| roslyn | `N4-vs-N8` | 2 | 448.37 | 610.77 | +36.2% |
| roslyn | `N4-vs-N8` | 3 | 443.57 | 654.80 | +47.6% |
| roslyn | `N4-vs-N8` | 4 | 466.56 | 660.55 | +41.6% |
| roslyn | `N4-vs-N8` | 5 | 427.85 | 583.48 | +36.4% |
| roslyn | `N4-vs-N8` | 6 | 483.91 | 607.14 | +25.5% |

## Duration and pressure by node count

Values are medians across six measured scenarios; duration and committed/working-set/private columns include the observed scenario range.

| Repo | Nodes | Duration sec (range) | Commit growth MB (range) | Descendant WS MB (range) | Descendant private MB (range) | Processes (range) | CPU median / p95 | Queue p95 | Probe p95 ms | Disk p95 MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| aspire | 4 | 353.7 (351.0-399.1) | 2273 (1933-2401) | 2657 (2300-2918) | 2033 (1716-2496) | 16 (16-38) | 27.2% / 98.1% | 29.0 | 425.6 | 28.5 |
| aspire | 8 | 301.2 (284.2-316.1) | 2883 (2660-3043) | 3736 (3237-3973) | 2612 (2286-2897) | 33 (32-34) | 41.5% / 100.0% | 54.0 | 806.8 | 31.5 |
| aspire | 16 | 260.6 (236.9-286.0) | 3777 (3535-4986) | 5017 (4843-6331) | 3211 (3093-4113) | 58 (52-64) | 71.7% / 100.0% | 82.5 | 1244.6 | 34.2 |
| roslyn | 4 | 609.0 (568.9-660.5) | 2933 (2725-3710) | 3060 (2647-7018) | 2707 (2421-6638) | 15 (15-187) | 30.2% / 94.1% | 17.5 | 306.5 | 74.7 |
| roslyn | 8 | 457.5 (427.9-483.9) | 4576 (4226-4867) | 5018 (4690-9229) | 4239 (3977-8327) | 31 (29-202) | 47.3% / 99.7% | 46.0 | 1067.7 | 87.2 |
| roslyn | 16 | 424.7 (417.6-448.5) | 5975 (4600-6794) | 7181 (5869-7948) | 5596 (4259-6041) | 53 (49-55) | 63.5% / 100.0% | 73.5 | 1668.7 | 94.9 |

Lower node counts reduce concurrency and therefore can reduce instantaneous pressure; that does not establish greater intrinsic work efficiency. Disk telemetry is retained in `pressure-summary.csv`; it is descriptive and potentially sensitive to cache and background I/O.

## Validation

- Accepted exactly **42 scenarios**: 6 excluded warm-up and 36 measured.
- Accepted exactly **14 whole blocks**: 2 warm-up and 12 measured.
- Preserved and excluded one invalid whole-block attempt: Aspire block 003 attempt 01. Its first N8 scenario crossed a sleep-sized 31,519-second system gap; attempt 02 was accepted in full.
- Replayed all **42 accepted binlogs** and found zero `CoordinatorNodeGrantReceived` events; accepted stdout and process telemetry also contain zero grant messages and zero Coordinator process samples.
- Accepted continuity maxima: system 8.748s, process 5.182s, probe 5.639s. System warning gaps above 5s: 5.
- Measured order balance is exactly **0/0** for position/carryover imbalance.
- All accepted build exits, root PIDs, OS timestamps, binlogs, whitespace-only stderr, restore-only setup placeholders, clean post-restore statuses, hashes, preparation smokes, keep-awake restoration, final worktrees, and process cleanup validated.

## Context only: prior Coordinator A-vs-D run

The earlier three-block Coordinator clean-solution run reported D-vs-A duration costs of +33.8% for Roslyn and +57.5% for Aspire. That separate root is contextual only and is not pooled with this no-Coordinator node-count analysis.

## Identities

- Candidate MSBuild: `18.10.0-dev.26373.1+8fe6721c8d5899c330b247918c46fb7359193981`
- Candidate `MSBuild.dll` SHA256: `1F456A53A870607963D61FBA9B80709B34EDF82EA60DB093DF8AF7C6C76A9409`
- Candidate `dotnet.exe` SHA256: `C9223FD508FA6707F3E78F7174CF481402B93B325B35D56CA711BB7D5D921F18`
- Roslyn: `bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b`
- Aspire: `110a63da8357af437a00d9efc5887ffdcbdfbb3c`
- Tooling: `3029d6fe65db84b4c31064c7f69f2f1a5acd7814`
- Run root: `C:\perf\results\node-count-clean-solution-20260804-175600`
