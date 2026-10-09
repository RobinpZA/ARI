<#
.SYNOPSIS
Times one inventory module in Processing mode, old (a git ref) vs new (working tree), and checks the rows are identical.

.DESCRIPTION
Faster and less noisy than Measure-ARIPerf.ps1 when only one module changed. Adds placement groups,
retirements and a VM with three data disks to the fixture so those paths run too.

.EXAMPLE
./Tests/Perf/Measure-ARIModule.ps1 -Module Compute/VirtualMachine.ps1 -OldRef upstream/main -Sizes 10000
#>
param([string]$Module = 'Compute/VirtualMachine.ps1', [string]$OldRef = 'upstream/main', [int[]]$Sizes = @(10000, 50000), [switch]$InTag)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)  # else a BOM in git output becomes junk and the old code fails to parse
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$Path = "Modules/Public/InventoryModules/$Module"
$OldCode = ((git -C $Repo show "${OldRef}:$Path") -join "`n").TrimStart([char]0xFEFF)
$NewCode = [IO.File]::ReadAllText((Join-Path $Repo $Path)).TrimStart([char]0xFEFF)

# No Az login inside the run: modules that call Azure fail fast instead of making real requests
$EmptyProfile = Join-Path ([IO.Path]::GetTempPath()) 'ARIPerf\EmptyProfile'
$null = New-Item -ItemType Directory -Force -Path $EmptyProfile
$env:USERPROFILE = $EmptyProfile
$env:HOME = $EmptyProfile

function Get-RowKey($Row) {
    ($Row.Keys | Sort-Object | ForEach-Object { "$_=" + (($Row[$_] | ForEach-Object { [string]$_ }) -join ';') }) -join '|'
}

foreach ($n in $Sizes) {
    $Fixture = [IO.File]::ReadAllText("$env:TEMP\ARIPerf\fixture-$n.json") | ConvertFrom-Json
    $Resources = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Fixture.Resources) { $Resources.Add($r) }

    # Extra paths the fixture lacks: placement groups, retirements, a VM with 3 data disks
    $Vms = @($Resources | Where-Object type -eq 'microsoft.compute/virtualmachines')
    for ($i = 0; $i -lt 20; $i++) {
        $Members = @($Vms[($i * 10)..($i * 10 + 4)] | ForEach-Object { [pscustomobject]@{ id = $_.id } })
        $Resources.Add([pscustomobject]@{ id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/proximityPlacementGroups/ppg$i"; name = "ppg$i"; type = 'microsoft.compute/proximityplacementgroups'; properties = [pscustomobject]@{ virtualMachines = $Members } })
    }
    $Retirements = @(foreach ($v in $Vms[0..99]) { [pscustomobject]@{ id = $v.id; ServiceID = 'svc1' }; [pscustomobject]@{ id = $v.id; ServiceID = 'svc2' } })
    $Unsupported = @([pscustomobject]@{ Id = 'svc1'; RetiringFeature = 'D, Dv2 - Series'; RetirementDate = '2028-05-01' }, [pscustomobject]@{ Id = 'svc2'; RetiringFeature = 'Basic SKU public IP'; RetirementDate = '2025-09-30' })
    $Extra = $Vms[5]
    $Extra.properties.storageProfile.dataDisks = @($Extra.properties.storageProfile.dataDisks) + @(
        [pscustomobject]@{ lun = 1; managedDisk = [pscustomobject]@{ id = ($Extra.properties.storageProfile.osDisk.managedDisk.id -replace 'osdisk$', 'data0') } },
        [pscustomobject]@{ lun = 2; managedDisk = [pscustomobject]@{ id = $Vms[6].properties.storageProfile.osDisk.managedDisk.id } })

    $Out = @{}
    foreach ($Side in 'old', 'new') {
        $Code = if ($Side -eq 'old') { $OldCode } else { $NewCode }
        [GC]::Collect()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ps = [PowerShell]::Create().AddScript($Code).AddArgument($null).AddArgument($Fixture.Subscriptions).AddArgument([bool]$InTag).AddArgument($Resources).AddArgument($Retirements).AddArgument('Processing').AddArgument($null).AddArgument($null).AddArgument($null).AddArgument($Unsupported)
        $Rows = $ps.Invoke()
        $Errors = $ps.Streams.Error.Count
        $ps.Dispose()
        $Out[$Side] = [pscustomobject]@{ Seconds = $sw.Elapsed.TotalSeconds; Rows = $Rows; Errors = $Errors }
    }
    $OldKeys = @($Out.old.Rows | ForEach-Object { Get-RowKey $_ })
    $NewKeys = @($Out.new.Rows | ForEach-Object { Get-RowKey $_ })
    $Same = ($OldKeys.Count -eq $NewKeys.Count) -and -not (Compare-Object $OldKeys $NewKeys -SyncWindow 0)
    "{0} {1}: old {2:N1} s, new {3:N1} s ({4:N0}x) | rows {5}/{6} | errors {7}/{8} | identical: {9}" -f $Module, $n, $Out.old.Seconds, $Out.new.Seconds, ($Out.old.Seconds / [math]::Max($Out.new.Seconds, 0.01)), $OldKeys.Count, $NewKeys.Count, $Out.old.Errors, $Out.new.Errors, $Same
    if (-not $Same) { Compare-Object $OldKeys $NewKeys -SyncWindow 0 | Select-Object -First 2 | ForEach-Object { '  ' + $_.SideIndicator + ' ' + $_.InputObject.Substring(0, [math]::Min(400, $_.InputObject.Length)) } }
}
