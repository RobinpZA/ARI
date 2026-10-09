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

## One module, old vs new

```powershell
./Tests/Perf/Measure-ARIModule.ps1 -Module Compute/VirtualMachine.ps1 -OldRef upstream/main -Sizes 10000, 50000
```

Runs a single inventory module in Processing mode from a git ref and from the working tree, against the same fixture, and checks every output row is identical. Faster and less noisy than a full run when only one module changed. Adds placement groups, retirements and a VM with three data disks so those paths run too.

## Live memory

```powershell
./Tests/Perf/Measure-ARILiveMemory.ps1 -TenantId <tenant-guid> -Side new
```

Needs an Az login and makes read-only calls. Imports ARI through the `.psd1`, runs extraction and resource processing, and reports the peak memory of the main process and of main plus job processes (what Task Manager groups under `pwsh`), with the step running at each peak. Run it in a fresh `pwsh` each time: the process peak covers the whole life of the process.

## All changed modules, old vs new

```powershell
./Tests/Perf/Compare-ARIModules.ps1 -OldRef upstream/main
```

Runs every inventory module changed since `-OldRef` from that ref and from the working tree, with synthetic retirements added, and checks the rows are identical. Exits 1 if any module differs. `-Repo` points it at another checkout (for example a rebase worktree).
