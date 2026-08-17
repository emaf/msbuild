# PR #14241 current-vs-final evidence

The [sustained contention report](sustained/report.md) contains the completed
three-block Roslyn and Aspire comparison for BASE, FINAL-N, and FINAL-H.

The original campaign completed all Roslyn blocks and Aspire block 1. A host
suspension invalidated the partial Aspire block 2 scenario. The authorized
supplemental campaign reran complete Aspire block rows 2 and 3 with identical
binaries, workload revision, worker count, condition order, and acceptance
criteria. The partial scenario remains listed in
[`invalid-attempts.json`](sustained/invalid-attempts.json) and is not analyzed.

Raw binlogs remain local. Their identities are recorded in
[`binlog-hash-index.json`](sustained/binlog-hash-index.json).
