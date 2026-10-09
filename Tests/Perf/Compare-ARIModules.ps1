<#
.SYNOPSIS
Runs every inventory module changed since a git ref, old vs new, and checks the output rows are identical.

.DESCRIPTION
Each changed module runs in Processing mode from the git ref and from the working tree, against the same
fixture plus synthetic retirements (every 2nd resource, two on every 6th, upper-cased id on every 10th).
Prints one line per module and a total. Exits 1 if any module's rows differ.

.EXAMPLE
./Tests/Perf/Compare-ARIModules.ps1 -OldRef upstream/main
#>
param([string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path, [string]$OldRef = 'upstream/main', [int]$Size = 10000, [switch]$InTag)
$ErrorActionPreference = 'Stop'
# Without this, git output is decoded with the console code page: a BOM becomes 'ï»¿' and the old code fails to parse
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# No Az login inside the run: modules that call Azure fail fast instead of making real requests
$EmptyProfile = Join-Path ([IO.Path]::GetTempPath()) 'ARIPerf\EmptyProfile'
$null = New-Item -ItemType Directory -Force -Path $EmptyProfile
$env:USERPROFILE = $EmptyProfile
$env:HOME = $EmptyProfile

function Get-RowKey($Row) {
    ($Row.Keys | Sort-Object | ForEach-Object { "$_=" + (($Row[$_] | ForEach-Object { [string]$_ }) -join ';') }) -join '|'
}

$Fixture = [IO.File]::ReadAllText("$env:TEMP\ARIPerf\fixture-$Size.json") | ConvertFrom-Json
$Resources = [System.Collections.Generic.List[object]]::new()
foreach ($r in $Fixture.Resources) { $Resources.Add($r) }

$Retirements = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $Resources.Count; $i += 2) {
    $id = [string]$Resources[$i].id; if (-not $id) { continue }
    if ($i % 10 -eq 0) { $id = $id.ToUpper() }
    $Retirements.Add([pscustomobject]@{ id = $id; ServiceID = 'svc1' })
    if ($i % 6 -eq 0) { $Retirements.Add([pscustomobject]@{ id = $Resources[$i].id; ServiceID = 'svc2' }) }
}
$Unsupported = @([pscustomobject]@{ Id = 'svc1'; RetiringFeature = 'Feature A'; RetirementDate = '2028-05-01' }, [pscustomobject]@{ Id = 'svc2'; RetiringFeature = 'Feature B'; RetirementDate = '2025-09-30' })
"resources $($Resources.Count), retirements $($Retirements.Count)"

$Changed = git -C $Repo diff --name-only $OldRef -- Modules/Public/InventoryModules
$Total = @{ old = 0.0; new = 0.0 }; $Bad = 0
foreach ($Path in $Changed) {
    $OldCode = ((git -C $Repo show "${OldRef}:$Path") -join "`n").TrimStart([char]0xFEFF)
    $NewCode = [IO.File]::ReadAllText((Join-Path $Repo $Path)).TrimStart([char]0xFEFF)
    $Out = @{}
    foreach ($Side in 'old', 'new') {
        $Code = if ($Side -eq 'old') { $OldCode } else { $NewCode }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ps = [PowerShell]::Create().AddScript($Code).AddArgument($null).AddArgument($Fixture.Subscriptions).AddArgument([bool]$InTag).AddArgument($Resources).AddArgument($Retirements.ToArray()).AddArgument('Processing').AddArgument($null).AddArgument($null).AddArgument($null).AddArgument($Unsupported)
        $Rows = $ps.Invoke(); $Errors = $ps.Streams.Error.Count; $ps.Dispose()
        $Out[$Side] = [pscustomobject]@{ Seconds = $sw.Elapsed.TotalSeconds; Keys = @($Rows | ForEach-Object { Get-RowKey $_ }); Errors = $Errors
            Retired = @($Rows | Where-Object { $r = $_; @($r.Keys | Where-Object { $_ -match 'Retir' -and $r[$_] }).Count }).Count }
        $Total[$Side] += $Out[$Side].Seconds
    }
    $Same = ($Out.old.Keys.Count -eq $Out.new.Keys.Count) -and -not (Compare-Object $Out.old.Keys $Out.new.Keys -SyncWindow 0)
    if (-not $Same) { $Bad++ }
    "{0,-45} old {1,6:N1} s  new {2,5:N1} s | rows {3} retired {4}/{5} | err {6}/{7} | {8}" -f (Split-Path $Path -Leaf), $Out.old.Seconds, $Out.new.Seconds, $Out.new.Keys.Count, $Out.old.Retired, $Out.new.Retired, $Out.old.Errors, $Out.new.Errors, $(if ($Same) { 'same' } else { 'DIFF' })
}
"TOTAL old {0:N1} s, new {1:N1} s; modules differing: {2}" -f $Total.old, $Total.new, $Bad
if ($Bad) { exit 1 }
