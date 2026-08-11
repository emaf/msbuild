# Public-repository Coordinator benchmark analysis

- Run root: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319`
- Workload: `solution-propagated`; repositories analyzed separately.
- Valid blocks: 20 primary and 2 discarded warm-up blocks across 2 repositories.
- Effects are geometric paired effects from within-block log ratios. No ratio of independent medians is used.
- Confidence intervals are deterministic descriptive 95% block-resampling intervals (10000 iterations; seed 20260723).
- Exact p-values enumerate all sign flips when there are at most 20 paired blocks.
- Coordinator grant counts remain available through `CoordinatorNodeGrantReceived` messages in each runs.csv binlog.
- Effective auto/manual policy origin is not currently captured in binlogs; this tooling does not change the production protocol.

## Predeclared comparisons

| Repository | Comparison | Blocks | Candidate latency effect (95% CI) | Average Normal cost (95% CI) | Total-wall cost (95% CI) | Exact sign-flip p (candidate / Normal / wall) |
|---|---|---:|---:|---:|---:|---:|
| aspire | `B-vs-C` | 10 | cost -3.8% (-9.1%, +2.1%) | -3.0% (-7.8%, +1.8%) | -2.6% (-7.7%, +2.7%) | 0.2422 / 0.2500 / 0.3887 |
| aspire | `C-vs-D` | 10 | cost -8.2% (-12.7%, -4.0%) | -27.0% (-30.0%, -24.4%) | -8.8% (-12.6%, -5.6%) | 0.0039 / 0.0020 / 0.0020 |
| aspire | `D-vs-E` | 10 | gain +19.5% (+15.8%, +22.6%) | +15.5% (+10.7%, +21.4%) | +3.9% (-0.1%, +8.8%) | 0.0020 / 0.0020 / 0.1367 |
| roslyn | `B-vs-C` | 10 | cost -2.9% (-8.7%, +4.2%) | +0.1% (-3.1%, +3.7%) | +0.1% (-3.7%, +4.1%) | 0.4199 / 0.9434 / 0.9824 |
| roslyn | `C-vs-D` | 10 | cost -13.4% (-18.8%, -9.6%) | -33.6% (-35.5%, -31.6%) | -20.8% (-23.2%, -18.1%) | 0.0020 / 0.0020 / 0.0020 |
| roslyn | `D-vs-E` | 10 | gain +9.1% (+2.3%, +16.3%) | +19.3% (+13.5%, +25.6%) | +7.0% (+1.4%, +12.7%) | 0.0312 / 0.0020 / 0.0508 |

### Interpretation

- `D-vs-E`: positive candidate gain means High reduced delayed-candidate latency; Normal and wall costs must be considered alongside it.
- `B-vs-C`: positive costs indicate overhead from the candidate branch even with compatibility policy.
- `C-vs-D`: positive costs indicate the bundled default reservation/cap policy impact.

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
| all | primary | all | `all` | 84 | 5.024 | 6.475 | 11.829 | 21.234 | 21.234 |
| repository | primary | roslyn | `all` | 44 | 5.024 | 6.186 | 10.441 | 13.160 | 13.160 |
| condition | primary | roslyn | `B-base-coordinator` | 2 | 7.255 | 9.767 | 12.279 | 12.279 | 12.279 |
| condition | primary | roslyn | `A-no-coordinator` | 31 | 5.024 | 6.101 | 10.140 | 10.441 | 10.441 |
| condition | primary | roslyn | `C-candidate-compat` | 1 | 5.549 | 5.549 | 5.549 | 5.549 | 5.549 |
| condition | primary | roslyn | `E-candidate-default-high` | 2 | 6.094 | 6.617 | 7.140 | 7.140 | 7.140 |
| condition | primary | roslyn | `D-candidate-default-normal` | 8 | 5.131 | 6.162 | 13.160 | 13.160 | 13.160 |
| repository | primary | aspire | `all` | 40 | 5.073 | 7.342 | 11.829 | 21.234 | 21.234 |
| condition | primary | aspire | `B-base-coordinator` | 1 | 12.295 | 12.295 | 12.295 | 12.295 | 12.295 |
| condition | primary | aspire | `A-no-coordinator` | 35 | 5.073 | 7.307 | 10.967 | 21.234 | 21.234 |
| condition | primary | aspire | `C-candidate-compat` | 4 | 5.834 | 6.787 | 11.829 | 11.829 | 11.829 |
| condition | primary | aspire | `E-candidate-default-high` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | primary | aspire | `D-candidate-default-normal` | 0 | n/a | n/a | n/a | n/a | n/a |
| all | warmup | all | `all` | 4 | 5.491 | 7.252 | 9.901 | 9.901 | 9.901 |
| repository | warmup | roslyn | `all` | 2 | 5.491 | 7.696 | 9.901 | 9.901 | 9.901 |
| condition | warmup | roslyn | `C-candidate-compat` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `B-base-coordinator` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `D-candidate-default-normal` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | roslyn | `A-no-coordinator` | 2 | 5.491 | 7.696 | 9.901 | 9.901 | 9.901 |
| condition | warmup | roslyn | `E-candidate-default-high` | 0 | n/a | n/a | n/a | n/a | n/a |
| repository | warmup | aspire | `all` | 2 | 6.758 | 7.252 | 7.746 | 7.746 | 7.746 |
| condition | warmup | aspire | `C-candidate-compat` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | aspire | `B-base-coordinator` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | aspire | `D-candidate-default-normal` | 0 | n/a | n/a | n/a | n/a | n/a |
| condition | warmup | aspire | `A-no-coordinator` | 2 | 6.758 | 7.252 | 7.746 | 7.746 | 7.746 |
| condition | warmup | aspire | `E-candidate-default-high` | 0 | n/a | n/a | n/a | n/a | n/a |

## Artifacts

- Scenario metrics: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319\analysis\scenario-metrics.csv`
- System-gap warning events: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319\analysis\system-gap-warnings.csv`
- System-gap warning distribution: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319\analysis\system-gap-warning-summary.csv`
- Paired block log ratios: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319\analysis\paired-block-log-ratios.csv`
- Comparison summary: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319\analysis\comparisons.csv`
- Validation: `C:\perf\results\priority-pr-primary-authoritative-20260723-173319\analysis\validation.json`
