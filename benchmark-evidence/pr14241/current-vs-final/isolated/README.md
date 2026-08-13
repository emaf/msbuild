# Contemporaneous isolated current-vs-final benchmark

This directory contains the completed contemporaneous isolated-build comparison:

- Current Coordinator: `ff5b281f0c5828dec0d092fcd1b682019de7d1ca`
- Final candidate: `9aa319701cc70713e5f017a1a8e0cc88b1813ae1`
- Conditions: `BASE`, explicit `COMPAT` 0/0, and computed-default `FINAL-N`
- One excluded warm-up plus six measured balanced blocks per repository
- Representative propagated Roslyn C# compiler and Aspire.Hosting projects

Start with [`validated-report.md`](validated-report.md).

`grant-summary.csv` is derived by replaying all 42 accepted binlogs. Raw binlogs and full telemetry remain outside git. The included scenario metrics intentionally omit machine-local file paths.

The sustained-contention campaign did not produce valid results because its worker-reuse harness falsely retained stale process identities. Those invalid pilots are not included or interpreted as product results.

Exact execution and analysis scripts are preserved under [`tooling/`](tooling/).
