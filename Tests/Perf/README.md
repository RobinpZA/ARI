# Performance tests

Offline timing of ARI's processing and reporting phases. No Azure login needed.

## Generate a fixture

```powershell
./Tests/Perf/New-ARIPerfFixture.ps1 -ResourceCount 10000
```

Synthetic and deterministic (`-Seed`, default 42). VM-heavy mix: each VM has a NIC, an OS and data disk, two extensions and sometimes a public IP. Every 50 VMs add a VNet, an NSG, storage, web apps, key vaults and SQL. Every resource has 4 tags. Written to `$env:TEMP/ARIPerf/fixture-<count>.json`.

To test with real resource shapes, pass `-SeedFile` with a JSON array of resources exported from Resource Graph. The file is cloned with new subscription IDs until it reaches the count. Keep seed files out of the repo.

## Measure

```powershell
./Tests/Perf/Measure-ARIPerf.ps1 -FixturePath $env:TEMP/ARIPerf/fixture-10000.json -Label baseline -OutputPath $env:TEMP/ARIPerf/baseline-10000
```

Reports processing time, report time, time per category job, peak memory (this process and the job processes), cache size, and a fingerprint (row count and hash) of every sheet. Results are written to `results.json` and `fingerprint.json` in the output folder.

## Prove output is unchanged

```powershell
./Tests/Perf/Measure-ARIPerf.ps1 -FixturePath $env:TEMP/ARIPerf/fixture-10000.json -Label after -CompareTo $env:TEMP/ARIPerf/baseline-10000
```

Throws if any sheet differs from the earlier run.

The extraction phase is not covered because it needs a tenant. Use the phase times `Invoke-ARI` prints at the end of a live run.
