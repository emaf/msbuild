# Idle-node-burst validation

**Result:** The automatic policy behaves as implemented: exactly one idle 8-node grant, immutable 4-node grants thereafter, and an immediate 4-node High grant from reserved capacity. Under sustained all-Normal contention, however, AUTO was materially slower for Roslyn and modestly slower for Aspire than fixed 4/4. All effects below are **descriptive/directional**: there are four measured paired blocks per repository, so the minimum attainable two-sided exact sign-flip p-value is 0.125.

## Conditions and design

- `F4-N`: explicit cap/reservation 4/4; four initial Normal builds and one delayed Normal candidate.
- `AUTO-N`: automatic policy; four initial Normal builds and one delayed Normal candidate.
- `F4-H`: explicit cap/reservation 4/4; four initial Normal builds and one delayed High candidate.
- `AUTO-H`: automatic policy; four initial Normal builds and one delayed High candidate.
- Workload: propagated Roslyn `Compilers.slnf` and Aspire `Aspire-Core.slnf`; node budget 16; candidate delay 15 seconds.
- One excluded warm-up plus four measured blocks per repository. The four measured rows are the smallest complete Williams cycle and have exact 0/0 position and first-order carryover imbalance.
- Effects use paired within-block log ratios, deterministic 10,000 whole-block resamples (seed 20260808), and exact sign flips.

## Paired duration and wall effects

Positive cost means the numerator was slower.

| Repository | Comparison | Delayed candidate | Average Normal | Total wall | Exact p (candidate / Normal / wall) |
|---|---|---:|---:|---:|---:|
| Roslyn | `AUTO-N` vs `F4-N` | +12.9% (+10.2%, +15.6%) | +15.3% (+11.1%, +19.2%) | +12.2% (+11.1%, +14.1%) | .125 / .125 / .125 |
| Aspire | `AUTO-N` vs `F4-N` | +1.9% (-1.7%, +5.3%) | +7.3% (+2.9%, +10.6%) | +1.7% (-1.5%, +4.7%) | .500 / .125 / .500 |
| Roslyn | `AUTO-H` vs `F4-H` | -30.1% (-33.5%, -25.7%) | +9.0% (+7.2%, +10.9%) | +8.7% (+5.6%, +11.7%) | .125 / .125 / .125 |
| Aspire | `AUTO-H` vs `F4-H` | +6.1% (-1.0%, +12.9%) | +1.1% (+0.1%, +2.0%) | -4.0% (-5.2%, -2.8%) | .250 / .250 / .125 |
| Roslyn | `AUTO-H` vs `AUTO-N` | -43.8% (-46.6%, -40.1%) | +6.3% (+2.1%, +10.9%) | -1.0% (-5.6%, +3.3%) | .125 / .125 / .750 |
| Aspire | `AUTO-H` vs `AUTO-N` | -23.8% (-26.7%, -21.5%) | +6.8% (+4.2%, +8.8%) | -4.5% (-7.3%, -1.6%) | .125 / .125 / .125 |

The High benefit is preserved within AUTO: delayed High was 43.8% faster for Roslyn and 23.8% faster for Aspire than delayed Normal. Relative to fixed 4/4 High, AUTO-H was mixed: 30.1% faster for Roslyn and 6.1% slower for Aspire.

## First grant and queue effects

Across the four measured blocks in each repository:

- Every `F4-N` and `F4-H` scenario had five 4-node grants.
- Every `AUTO-N` and `AUTO-H` scenario had exactly one 8-node grant and four 4-node grants. No queue-drain or subsequent grant received 8.
- Every delayed High in `AUTO-H` received exactly 4 while the 8-node burst build was still active; the burst build had 46.9-99.5 seconds remaining at the High grant timestamp.
- Controlled functional smoke produced `AUTO-N = 8,4,4` with the third Normal queued, `AUTO-H = Normal 8 + High 4`, fixed 4/4 = 4, explicit 0/0 = 16 uncapped, and explicit cap 8 = 8.

Grant-role duration effects against the same fixed-policy label show where the immutable first grant moves time:

| Repository | Comparison | Burst recipient (8) | Immediate Normal (4) | Queued Normals (4) | Delayed candidate (4) |
|---|---|---:|---:|---:|---:|
| Roslyn | `AUTO-N` vs `F4-N` | -3.9% | -18.6% | +41.8% | +12.9% |
| Aspire | `AUTO-N` vs `F4-N` | -40.9% | -34.8% | +72.7% | +1.9% |
| Roslyn | `AUTO-H` vs `F4-H` | +16.2% | -42.1% | +39.4% | -30.1% |
| Aspire | `AUTO-H` vs `F4-H` | -25.1% | -23.2% | +29.0% | +6.1% |

These role effects are also descriptive and scheduling-sensitive, but consistently show that later queued Normals absorb the cost after the immutable 8-node grant.

## Pressure medians

| Repo | Condition | Commit growth MB | Descendant WS MB | Descendant private MB | Processes | Queue p95 | Probe p95 ms |
|---|---|---:|---:|---:|---:|---:|---:|
| Roslyn | `F4-N` | 5221 | 6480 | 5270 | 43.5 | 160.5 | 2941 |
| Roslyn | `AUTO-N` | 4269 | 4961 | 3891 | 33.5 | 119.0 | 2208 |
| Roslyn | `F4-H` | 5581 | 6318 | 4877 | 45.0 | 162.0 | 2657 |
| Roslyn | `AUTO-H` | 4292 | 5100 | 3752 | 43.0 | 98.5 | 1023 |
| Aspire | `F4-N` | 3624 | 4399 | 3168 | 31.0 | 133.0 | 1846 |
| Aspire | `AUTO-N` | 3409 | 4150 | 3035 | 31.0 | 126.0 | 1387 |
| Aspire | `F4-H` | 4344 | 5245 | 3723 | 39.0 | 202.0 | 2334 |
| Aspire | `AUTO-H` | 3148 | 4141 | 2764 | 39.0 | 127.0 | 1714 |

AUTO-N reduced median pressure versus F4-N despite its wall-time cost: Roslyn commit/working-set/private medians fell 18.2%/23.4%/26.2%, and Aspire fell 5.9%/5.6%/4.2%. AUTO-H likewise reduced most pressure measures versus F4-H.

## Isolated and vs-green smoke

- Solo AUTO granted 8 end-to-end for Roslyn (537.65 seconds) and Aspire (357.88 seconds), with successful exits and binlogs. These are smoke timings, not a contemporaneous node-count matrix, and are not pooled with prior roots.
- The prior clean-solution `/m:8` evidence remains context only: it established lower pressure than `/m:16` and substantially better wall time than `/m:4`.
- vs-green also received AUTO grant 8, then failed safely after 18.85 seconds with `NETSDK1045`: candidate SDK 10.0.300 cannot target its pinned .NET 11 graph. Its `global.json`, package graph, repository, and worktree remained unchanged.

## Validation

- 40 scenarios accepted: 8 excluded warm-up and 32 measured; 10 whole blocks accepted; zero invalid attempts or retries.
- All 200 builds had successful exits, valid root PIDs and OS timestamps, nonempty binlogs, and whitespace-only stderr.
- All 200 binlogs replayed (72,231,961 events), each with exactly one grant event.
- Telemetry maxima were 7.170 seconds system, 5.130 seconds process, and 5.482 seconds probe. Three system gaps exceeded the 5-second warning threshold; none approached the 30/15/15 hard limits.
- Coordinator telemetry contained 1,684 samples across 40 Coordinator processes.
- Keep-awake restoration succeeded; all Roslyn, Aspire, and vs-green repositories/worktrees are clean and at pinned commits; no benchmark, monitor, or Coordinator process remains.
- Detached launcher PID 32756 completed successfully. Durable stdout is 107,258 bytes; durable stderr is empty.

## Identity and conclusion

- Candidate commit: `dcf76ee0204f7d94776079b4293c043ccec0ad0c`
- ProductVersion: `18.10.0-dev.26407.1+dcf76ee0204f7d94776079b4293c043ccec0ad0c`
- `MSBuild.dll` SHA-256: `F8B91508ED12DA6C4BFE0CF0125AB9705410D32F93CCCB165B4A95FA5F37166B`
- `dotnet.exe` SHA-256: `CBB1746F9B08DD9825129D451D99869E84E9024E62C804DEDE22C9FB61E0291D`
- Roslyn: `bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b`
- Aspire: `110a63da8357af437a00d9efc5887ffdcbdfbb3c`
- vs-green: `7eaba546bcd220e97afc66159a63c4051a44d4e6`
- Benchmark tooling: `068fcdd37763c595b38898533d31f2ff8329e2b2`

**Policy conclusion:** The implementation is functionally correct and preserves reserved High responsiveness. The idle burst is not free under later Normal contention: Roslyn showed a material 12.2% wall regression and 15.3% average-Normal regression, while Aspire showed a small 1.7% wall regression but a 7.3% average-Normal regression. The policy trades queued-follower throughput for the idle recipient and lower observed pressure. This is a policy tradeoff, not an allocator correctness bug, but the Roslyn result should be weighed explicitly before adopting AUTO as the default.
