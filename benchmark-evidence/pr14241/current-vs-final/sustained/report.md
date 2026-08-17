# PR #14241 sustained contention results

The combined accepted set contains three complete measured blocks for each repository and condition. Roslyn and Aspire block 1 come from the original campaign; Aspire blocks 2 and 3 come from the preauthorized supplemental campaign. The host-suspended partial Aspire block 2 is excluded.

Effects use `100 * (exp(mean(log(candidate / baseline))) - 1)` over three paired whole blocks. Intervals use 10,000 deterministic whole-block resamples; p-values use exact two-sided sign flips. With n=3, estimates are directional.

## Headline findings

- **FINAL-N vs BASE reduced Normal throughput:** Roslyn -16.74% (1.75 to 1.458 builds/min) and Aspire -25.45% (5.083 to 3.792 builds/min).
- **FINAL-N reduced pressure:** average system CPU fell 30.84% for Roslyn and 29.42% for Aspire; peak descendant working set fell 52.65% and 49.33%, respectively.
- **FINAL-N left about four nodes unused on average:** allocation averaged 12.0 of 16 nodes, versus approximately 16 for BASE.
- **FINAL-H made the injected probe responsive:** request-to-grant time fell 99.64% for Roslyn and 98.58% for Aspire relative to FINAL-N.
- **FINAL-H throughput relative to FINAL-N was workload-dependent:** Roslyn -8.59%; Aspire +3.20%.

These are directional n=3 estimates. The minimum attainable two-sided exact sign-flip p-value is 0.25.

## roslyn

| Comparison | Metric | Baseline mean | Candidate mean | Effect | 95% interval | Exact p |
|---|---|---:|---:|---:|---:|---:|
| FINAL-N-vs-BASE | MeasuredNormalCompletionCount | 14 | 11.6667 | -16.74% | [-21.43%, -14.29%] | 0.25 |
| FINAL-N-vs-BASE | NormalThroughputPerMinute | 1.75 | 1.4583 | -16.74% | [-21.43%, -14.29%] | 0.25 |
| FINAL-N-vs-BASE | AverageCompletedNormalLatencySeconds | 275.9223 | 293.4508 | 6.3% | [2.78%, 11.79%] | 0.25 |
| FINAL-N-vs-BASE | InjectedRequestToGrantSeconds | 124.0812 | 223.7027 | 80.31% | [69.77%, 86.61%] | 0.25 |
| FINAL-N-vs-BASE | InjectedRequestToCompletionSeconds | 343.4075 | 339.6763 | -1.11% | [-3.35%, 1.06%] | 0.75 |
| FINAL-N-vs-BASE | QueueDepthP95 | 2 | 6 | 200% | [200%, 200%] | 0.25 |
| FINAL-N-vs-BASE | AverageAllocatedNodes | 15.9967 | 11.9999 | -24.99% | [-25%, -24.97%] | 0.25 |
| FINAL-N-vs-BASE | AverageUnusedNodes | 0.0033 | 4.0001 | 316927.39% | [53968.98%, 3580936.85%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.AverageSystemCpuPercent | 92.7104 | 64.1152 | -30.84% | [-31.59%, -29.94%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakCommittedBytes | 24635959978.6667 | 18356191232 | -25.49% | [-27.23%, -24.57%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakDescendantWorkingSetBytes | 12122230784 | 5743153152 | -52.65% | [-53.63%, -50.9%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakDescendantPrivateBytes | 10670353066.6667 | 5004566528 | -53.1% | [-55.07%, -51.62%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakDescendantProcessCount | 55 | 40 | -27.96% | [-34.78%, -23.91%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.DescendantCpuSeconds | 5397.3953 | 3875.934 | -28.19% | [-30.09%, -26.11%] | 0.25 |
| FINAL-H-vs-FINAL-N | MeasuredNormalCompletionCount | 11.6667 | 10.6667 | -8.59% | [-16.67%, 0%] | 0.5 |
| FINAL-H-vs-FINAL-N | NormalThroughputPerMinute | 1.4583 | 1.3333 | -8.59% | [-16.67%, 0%] | 0.5 |
| FINAL-H-vs-FINAL-N | AverageCompletedNormalLatencySeconds | 293.4508 | 286.7254 | -2.24% | [-5.86%, 0.68%] | 0.5 |
| FINAL-H-vs-FINAL-N | InjectedRequestToGrantSeconds | 223.7027 | 0.8717 | -99.64% | [-99.75%, -99.35%] | 0.25 |
| FINAL-H-vs-FINAL-N | InjectedRequestToCompletionSeconds | 339.6763 | 136.434 | -59.84% | [-61.58%, -57.27%] | 0.25 |
| FINAL-H-vs-FINAL-N | QueueDepthP95 | 6 | 5 | -16.67% | [-16.67%, -16.67%] | 0.25 |
| FINAL-H-vs-FINAL-N | AverageAllocatedNodes | 11.9999 | 13.1294 | 9.41% | [9.22%, 9.75%] | 0.25 |
| FINAL-H-vs-FINAL-N | AverageUnusedNodes | 4.0001 | 2.8706 | -28.24% | [-29.24%, -27.65%] | 0.25 |
| FINAL-H-vs-FINAL-N | SteadyResource.AverageSystemCpuPercent | 64.1152 | 66.2801 | 3.37% | [1.19%, 5.24%] | 0.25 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakCommittedBytes | 18356191232 | 18883493888 | 2.82% | [-0.82%, 7.72%] | 0.5 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakDescendantWorkingSetBytes | 5743153152 | 6319319722.6667 | 10.02% | [8.12%, 12.39%] | 0.25 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakDescendantPrivateBytes | 5004566528 | 5479766698.6667 | 9.34% | [-0.04%, 19.1%] | 0.5 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakDescendantProcessCount | 40 | 34 | -12.04% | [-38.18%, 13.33%] | 0.75 |
| FINAL-H-vs-FINAL-N | SteadyResource.DescendantCpuSeconds | 3875.934 | 4043.7737 | 4.33% | [2.9%, 5.09%] | 0.25 |
| FINAL-H-vs-BASE | MeasuredNormalCompletionCount | 14 | 10.6667 | -23.89% | [-28.57%, -21.43%] | 0.25 |
| FINAL-H-vs-BASE | NormalThroughputPerMinute | 1.75 | 1.3333 | -23.89% | [-28.57%, -21.43%] | 0.25 |
| FINAL-H-vs-BASE | AverageCompletedNormalLatencySeconds | 275.9223 | 286.7254 | 3.91% | [3.03%, 5.25%] | 0.25 |
| FINAL-H-vs-BASE | InjectedRequestToGrantSeconds | 124.0812 | 0.8717 | -99.36% | [-99.55%, -98.9%] | 0.25 |
| FINAL-H-vs-BASE | InjectedRequestToCompletionSeconds | 343.4075 | 136.434 | -60.29% | [-61.17%, -58.7%] | 0.25 |
| FINAL-H-vs-BASE | QueueDepthP95 | 2 | 5 | 150% | [150%, 150%] | 0.25 |
| FINAL-H-vs-BASE | AverageAllocatedNodes | 15.9967 | 13.1294 | -17.92% | [-18.09%, -17.68%] | 0.25 |
| FINAL-H-vs-BASE | AverageUnusedNodes | 0.0033 | 2.8706 | 227399.64% | [38929.14%, 2590677.75%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.AverageSystemCpuPercent | 92.7104 | 66.2801 | -28.51% | [-30.17%, -27.33%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakCommittedBytes | 24635959978.6667 | 18883493888 | -23.38% | [-25.26%, -21.62%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakDescendantWorkingSetBytes | 12122230784 | 6319319722.6667 | -47.91% | [-49.86%, -46.19%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakDescendantPrivateBytes | 10670353066.6667 | 5479766698.6667 | -48.72% | [-51.64%, -46.49%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakDescendantProcessCount | 55 | 34 | -36.63% | [-53.42%, -26.09%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.DescendantCpuSeconds | 5397.3953 | 4043.7737 | -25.08% | [-26.59%, -22.35%] | 0.25 |

## aspire

| Comparison | Metric | Baseline mean | Candidate mean | Effect | 95% interval | Exact p |
|---|---|---:|---:|---:|---:|---:|
| FINAL-N-vs-BASE | MeasuredNormalCompletionCount | 40.6667 | 30.3333 | -25.45% | [-30.95%, -20%] | 0.25 |
| FINAL-N-vs-BASE | NormalThroughputPerMinute | 5.0833 | 3.7917 | -25.45% | [-30.95%, -20%] | 0.25 |
| FINAL-N-vs-BASE | AverageCompletedNormalLatencySeconds | 94.8118 | 122.9842 | 29.7% | [25.9%, 34.94%] | 0.25 |
| FINAL-N-vs-BASE | InjectedRequestToGrantSeconds | 31.1837 | 81.8388 | 173.86% | [125.33%, 263.13%] | 0.25 |
| FINAL-N-vs-BASE | InjectedRequestToCompletionSeconds | 121.1855 | 127.5902 | 5.39% | [1.04%, 8.95%] | 0.25 |
| FINAL-N-vs-BASE | QueueDepthP95 | 2.3333 | 6 | 162.07% | [100%, 200%] | 0.25 |
| FINAL-N-vs-BASE | AverageAllocatedNodes | 15.961 | 11.9997 | -24.82% | [-24.86%, -24.79%] | 0.25 |
| FINAL-N-vs-BASE | AverageUnusedNodes | 0.039 | 4.0003 | 10279.04% | [8899.95%, 12907.92%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.AverageSystemCpuPercent | 86.095 | 60.8012 | -29.42% | [-31.35%, -28.44%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakCommittedBytes | 20329497941.3333 | 16946976085.3333 | -16.74% | [-19.14%, -15.11%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakDescendantWorkingSetBytes | 6560742058.6667 | 3373876565.3333 | -49.33% | [-56.6%, -41.71%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakDescendantPrivateBytes | 5262375594.6667 | 2520129536 | -53.03% | [-58.64%, -44.7%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.PeakDescendantProcessCount | 46 | 35.6667 | -21.48% | [-29.41%, -5.88%] | 0.25 |
| FINAL-N-vs-BASE | SteadyResource.DescendantCpuSeconds | 4739.1197 | 3391.0607 | -28.43% | [-32.44%, -24.62%] | 0.25 |
| FINAL-H-vs-FINAL-N | MeasuredNormalCompletionCount | 30.3333 | 31.3333 | 3.2% | [0%, 6.25%] | 0.5 |
| FINAL-H-vs-FINAL-N | NormalThroughputPerMinute | 3.7917 | 3.9167 | 3.2% | [0%, 6.25%] | 0.5 |
| FINAL-H-vs-FINAL-N | AverageCompletedNormalLatencySeconds | 122.9842 | 118.4233 | -3.74% | [-5.34%, -1.4%] | 0.25 |
| FINAL-H-vs-FINAL-N | InjectedRequestToGrantSeconds | 81.8388 | 1.5304 | -98.58% | [-99.46%, -95.43%] | 0.25 |
| FINAL-H-vs-FINAL-N | InjectedRequestToCompletionSeconds | 127.5902 | 52.1216 | -58.97% | [-61.69%, -53.79%] | 0.25 |
| FINAL-H-vs-FINAL-N | QueueDepthP95 | 6 | 5 | -16.67% | [-16.67%, -16.67%] | 0.25 |
| FINAL-H-vs-FINAL-N | AverageAllocatedNodes | 11.9997 | 12.4208 | 3.51% | [3.34%, 3.59%] | 0.25 |
| FINAL-H-vs-FINAL-N | AverageUnusedNodes | 4.0003 | 3.5792 | -10.53% | [-10.78%, -10.02%] | 0.25 |
| FINAL-H-vs-FINAL-N | SteadyResource.AverageSystemCpuPercent | 60.8012 | 60.736 | -0.05% | [-3.43%, 3.37%] | 1 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakCommittedBytes | 16946976085.3333 | 17120758442.6667 | 1% | [-1.23%, 3.9%] | 0.75 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakDescendantWorkingSetBytes | 3373876565.3333 | 3016497834.6667 | -9.1% | [-33.51%, 9.6%] | 1 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakDescendantPrivateBytes | 2520129536 | 2274562048 | -7.59% | [-36.07%, 18.12%] | 1 |
| FINAL-H-vs-FINAL-N | SteadyResource.PeakDescendantProcessCount | 35.6667 | 28.3333 | -16.92% | [-49.02%, 12.5%] | 1 |
| FINAL-H-vs-FINAL-N | SteadyResource.DescendantCpuSeconds | 3391.0607 | 3418.6943 | 0.82% | [-2.09%, 2.72%] | 0.75 |
| FINAL-H-vs-BASE | MeasuredNormalCompletionCount | 40.6667 | 31.3333 | -23.07% | [-28.57%, -15%] | 0.25 |
| FINAL-H-vs-BASE | NormalThroughputPerMinute | 5.0833 | 3.9167 | -23.07% | [-28.57%, -15%] | 0.25 |
| FINAL-H-vs-BASE | AverageCompletedNormalLatencySeconds | 94.8118 | 118.4233 | 24.85% | [21.57%, 28.94%] | 0.25 |
| FINAL-H-vs-BASE | InjectedRequestToGrantSeconds | 31.1837 | 1.5304 | -96.12% | [-98.77%, -83.41%] | 0.25 |
| FINAL-H-vs-BASE | InjectedRequestToCompletionSeconds | 121.1855 | 52.1216 | -56.76% | [-60.58%, -50.86%] | 0.25 |
| FINAL-H-vs-BASE | QueueDepthP95 | 2.3333 | 5 | 118.4% | [66.67%, 150%] | 0.25 |
| FINAL-H-vs-BASE | AverageAllocatedNodes | 15.961 | 12.4208 | -22.18% | [-22.29%, -22.09%] | 0.25 |
| FINAL-H-vs-BASE | AverageUnusedNodes | 0.039 | 3.5792 | 9186.43% | [7929.61%, 11505.93%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.AverageSystemCpuPercent | 86.095 | 60.736 | -29.46% | [-30.9%, -28.41%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakCommittedBytes | 20329497941.3333 | 17120758442.6667 | -15.92% | [-18.83%, -12.64%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakDescendantWorkingSetBytes | 6560742058.6667 | 3016497834.6667 | -53.94% | [-61.25%, -43.64%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakDescendantPrivateBytes | 5262375594.6667 | 2274562048 | -56.59% | [-64.65%, -46.48%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.PeakDescendantProcessCount | 46 | 28.3333 | -34.77% | [-62.86%, -5.88%] | 0.25 |
| FINAL-H-vs-BASE | SteadyResource.DescendantCpuSeconds | 4739.1197 | 3418.6943 | -27.84% | [-31.15%, -26.05%] | 0.25 |

## Validity limitation

The original run experienced a roughly 36,182-second telemetry discontinuity caused by host suspension during Aspire block 2. That partial scenario was never reused. A fresh supplemental root reran the complete original rows for Aspire blocks 2 and 3 under the same immutable binaries, workload commit, eight-worker design, fixed window, injection timing, and validity criteria.
