# PR #14241 benchmark evidence

Start with [`validated-report.md`](validated-report.md).

- Recompute all requested comparisons:
  `pwsh ./scripts/Recompute-PortableComparisons.ps1`
- Verify included files:
  `Get-FileHash` against `manifest.csv` or `SHA256SUMS.txt`
- Run the approximately four-minute policy smoke:
  `dotnet build ./scripts/short-reproduction/GrantScan/GrantScan.csproj -c Release`
  then
  `pwsh ./scripts/short-reproduction/Run-GrantSmoke.ps1 -BootstrapRoot <bootstrap> -OutputRoot ./short-reproduction-output`

The 1.3 GB raw-binlog archive is intentionally not committed. `raw-binlog-index.csv` indexes all authoritative priority, node-count, and idle-burst binlogs by relative path and SHA-256. The archive can be supplied on request with SHA-256 `68BDCE1E5DD7830FB3F72219C50110A083434F1A113B3DB2F0CC06A1B331E8BD`.

No benchmark or product test was rerun to create this package.
