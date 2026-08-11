# Public-repository Coordinator benchmark analysis

- Run root: `C:\perf\results\idle-node-burst-matrix-20260807-181942`
- Workload: `solution-propagated`; repositories analyzed separately.
- Valid blocks: 8 primary and 2 discarded warm-up blocks across 2 repositories.
- Effects are geometric paired effects from within-block log ratios. No ratio of independent medians is used.
- Confidence intervals are deterministic 95% block-resampling intervals (10000 iterations; seed 20260808).
- Exact p-values enumerate all sign flips when there are at most 20 paired blocks.
- Coordinator grant counts remain available through `CoordinatorNodeGrantReceived` messages in each runs.csv binlog.
- Effective auto/manual policy origin is not currently captured in binlogs; this tooling does not change the production protocol.

> **Descriptive/directional evidence:** 8 repository-comparison result(s) have fewer than 10 valid measured paired blocks or no exact sign-flip test.

## Predeclared comparisons

| Repository | Comparison | Blocks | Candidate latency effect (95% CI) | Average Normal cost (95% CI) | Total-wall cost (95% CI) | Exact sign-flip p (candidate / Normal / wall) |
|---|---|---:|---:|---:|---:|---:|
| aspire | `AUTO-H-vs-AUTO-N` | 4 | cost -23.8% (-26.7%, -21.5%) | +6.8% (+4.2%, +8.8%) | -4.5% (-7.3%, -1.6%) | 0.1250 / 0.1250 / 0.1250 |
| aspire | `AUTO-H-vs-F4-H` | 4 | cost +6.1% (-1.0%, +12.9%) | +1.1% (+0.1%, +2.0%) | -4.0% (-5.2%, -2.8%) | 0.2500 / 0.2500 / 0.1250 |
| aspire | `AUTO-N-vs-F4-N` | 4 | cost +1.9% (-1.7%, +5.3%) | +7.3% (+2.9%, +10.6%) | +1.7% (-1.5%, +4.7%) | 0.5000 / 0.1250 / 0.5000 |
| aspire | `F4-H-vs-F4-N` | 4 | cost -26.8% (-31.0%, -20.8%) | +13.4% (+9.9%, +17.2%) | +1.1% (-0.6%, +2.9%) | 0.1250 / 0.1250 / 0.5000 |
| roslyn | `AUTO-H-vs-AUTO-N` | 4 | cost -43.8% (-46.6%, -40.1%) | +6.3% (+2.1%, +10.9%) | -1.0% (-5.6%, +3.3%) | 0.1250 / 0.1250 / 0.7500 |
| roslyn | `AUTO-H-vs-F4-H` | 4 | cost -30.1% (-33.5%, -25.7%) | +9.0% (+7.2%, +10.9%) | +8.7% (+5.6%, +11.7%) | 0.1250 / 0.1250 / 0.1250 |
| roslyn | `AUTO-N-vs-F4-N` | 4 | cost +12.9% (+10.2%, +15.6%) | +15.3% (+11.1%, +19.2%) | +12.2% (+11.1%, +14.1%) | 0.1250 / 0.1250 / 0.1250 |
| roslyn | `F4-H-vs-F4-N` | 4 | cost -9.3% (-16.5%, -4.7%) | +12.5% (+11.4%, +13.6%) | +2.2% (+1.1%, +3.3%) | 0.1250 / 0.1250 / 0.1250 |

### Interpretation


## Validity and diagnostics

- System-counter timestamp gaps above 5 seconds are responsiveness warnings and remain visible without invalidating a scenario. Gaps above the 30 second hard limit invalidate the whole block.
- Process-snapshot and probe timestamp-gap limits are 15 and 15 seconds respectively; they are validated independently from system-counter continuity.
- This protocol was declared after a zero-measured-block pilot produced 5.8-8.25 second system-loop delays under realistic overload with 45/45 successful builds and binlogs and no monitor errors. The 30 second hard limit remains far below previously observed sleep contamination of about 882 seconds and multiple hours.
- Earlier invalid roots remain invalid and are never retroactively accepted under a later protocol.
- Every accepted build recorded a root PID; descendant process peaks were reconstructed from full process/parent snapshots.
- `scenario-metrics.csv` reports known Defender/search/update process peaks so external interference remains diagnosable.

### System-gap warning distribution

| Scope | Block kind | Repository | Condition | Warning gaps | Minimum (s) | Median (s) | P95 (s) | P99 (s) | Maximum (s) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| all | primary | all | `all` | 2 | 5.261 | 6.215 | 7.170 | 7.170 | 7.170 |
| repository | primary | roslyn | `all` | 2 | 5.261 | 6.215 | 7.170 | 7.170 | 7.170 |
| condition | primary | roslyn | `F4-N` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | roslyn | `AUTO-N` | 2 | 5.261 | 6.215 | 7.170 | 7.170 | 7.170 |
| condition | primary | roslyn | `AUTO-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | roslyn | `F4-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| repository | primary | aspire | `all` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | aspire | `F4-N` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | aspire | `AUTO-N` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | aspire | `AUTO-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | aspire | `F4-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| all | warmup | all | `all` | 1 | 5.484 | 5.484 | 5.484 | 5.484 | 5.484 |
| repository | warmup | roslyn | `all` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `AUTO-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `F4-N` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `F4-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `AUTO-N` | 0 | n/a | n/a | n/a | n/a | n/a |
| repository | warmup | aspire | `all` | 1 | 5.484 | 5.484 | 5.484 | 5.484 | 5.484 |
| condition | warmup | aspire | `AUTO-H` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | aspire | `F4-N` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | aspire | `F4-H` | 1 | 5.484 | 5.484 | 5.484 | 5.484 | 5.484 |
| condition | warmup | aspire | `AUTO-N` | 0 | n/a | n/a | n/a | n/a | n/a |

## Artifacts

- Scenario metrics: `C:\perf\results\idle-node-burst-matrix-20260807-181942\analysis\scenario-metrics.csv`
- System-gap warning events: `C:\perf\results\idle-node-burst-matrix-20260807-181942\analysis\system-gap-warnings.csv`
- System-gap warning distribution: `C:\perf\results\idle-node-burst-matrix-20260807-181942\analysis\system-gap-warning-summary.csv`
- Paired block log ratios: `C:\perf\results\idle-node-burst-matrix-20260807-181942\analysis\paired-block-log-ratios.csv`
- Comparison summary: `C:\perf\results\idle-node-burst-matrix-20260807-181942\analysis\comparisons.csv`
- Validation: `C:\perf\results\idle-node-burst-matrix-20260807-181942\analysis\validation.json`
