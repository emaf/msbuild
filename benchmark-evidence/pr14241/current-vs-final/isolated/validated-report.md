# Current Coordinator vs final candidate: isolated representative projects

## Result

The current Coordinator (`BASE`) granted 16 nodes, explicit final-candidate compatibility mode (`COMPAT`) granted 16, and the final candidate with computed defaults (`FINAL-N`) granted 8. Across six paired measured blocks per repository, the 8-node final candidate had effectively the same duration as the current 16-node Coordinator:

| Repository | BASE geometric mean | FINAL-N geometric mean | FINAL-N relative to BASE | Descriptive 95% CI | Exact sign-flip p |
|---|---:|---:|---:|---:|---:|
| Roslyn C# compiler project | 90.236 s | 90.224 s | 0.0% faster | 1.7% faster to 2.5% slower | 1.000 |
| Aspire.Hosting | 36.257 s | 36.687 s | 1.2% slower | 7.1% faster to 8.5% slower | .781 |

Explicit `0/0` compatibility mode also showed no detectable implementation/protocol overhead:

| Repository | BASE geometric mean | COMPAT geometric mean | COMPAT relative to BASE | Descriptive 95% CI | Exact sign-flip p |
|---|---:|---:|---:|---:|---:|
| Roslyn | 90.236 s | 89.176 s | 1.2% faster | 2.4% faster to 0.3% slower | .188 |
| Aspire | 36.257 s | 36.518 s | 0.7% slower | 9.6% faster to 12.3% slower | .906 |

## Pressure medians

Memory effects were small and not consistent between repositories, so they should not be generalized:

| Repository | Metric | BASE | FINAL-N | Change |
|---|---|---:|---:|---:|
| Roslyn | committed growth | 1648 MiB | 1684 MiB | 2.2% more |
| Roslyn | descendant working set | 1754 MiB | 1794 MiB | 2.3% more |
| Roslyn | descendant private memory | 1636 MiB | 1656 MiB | 1.2% more |
| Aspire | committed growth | 1178 MiB | 1076 MiB | 8.7% less |
| Aspire | descendant working set | 819 MiB | 797 MiB | 2.7% less |
| Aspire | descendant private memory | 668 MiB | 650 MiB | 2.7% less |

Median descendant process counts were unchanged: 7 for Roslyn and 5 for Aspire.

## Methodology and validity

- Exact BASE commit: `ff5b281f0c5828dec0d092fcd1b682019de7d1ca`.
- Exact FINAL commit: `9aa319701cc70713e5f017a1a8e0cc88b1813ae1`.
- Roslyn: `bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b`, `src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj`.
- Aspire: `110a63da8357af437a00d9efc5887ffdcbdfbb3c`, `src\Aspire.Hosting\Aspire.Hosting.csproj`.
- One excluded warm-up plus six measured paired blocks per repository.
- Complete three-condition Williams design; measured position/carryover imbalance `0/0`.
- Paired within-block log ratios, deterministic 10,000 whole-block resamples, and exact two-sided sign flips.
- 42/42 accepted scenarios, 14 accepted blocks, successful exits, valid PIDs/timestamps, nonempty binlogs, and whitespace-only stderr.
- All 42 accepted binlogs replayed: BASE and COMPAT each issued one 16-node grant; FINAL-N issued one 8-node grant.
- Accepted continuity maxima: system 7.266 s, process 5.118 s, probe 5.104 s. One system gap exceeded the 5-second warning threshold; none exceeded hard limits 30/15/15.
- Six attempts were excluded before execution because the machine did not meet the predeclared idle gate within 300 seconds. No measured scenario from those attempts was accepted.
- Worktrees remained clean and pinned; keep-awake was restored; no benchmark or Coordinator process remained.

With six blocks, exact p-values are discrete. Results are directional/descriptive, although the observed timing effects are very close to zero.
