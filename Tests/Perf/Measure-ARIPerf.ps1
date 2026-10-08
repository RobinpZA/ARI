<#
.SYNOPSIS
Times ARI's processing and reporting phases against a fixture, offline.

.DESCRIPTION
Loads the module from this repo, feeds a fixture from New-ARIPerfFixture.ps1 into
Start-ARIProcessOrchestration (the resource jobs) and Start-ARIExcelJob (the resource
sheets), and records:
  - wall time per phase, and per category job (from the job's begin/end time)
  - peak memory of this process and of all job processes together
  - size of the processing cache
  - a fingerprint of every sheet (row count + hash), so a later run can prove the
    output is unchanged

Extraction is not covered: it needs a tenant. Use the timings Invoke-ARI prints on a
live run for that phase.

Results go to <OutputPath>/results.json and fingerprint.json.

.EXAMPLE
./Measure-ARIPerf.ps1 -FixturePath $env:TEMP/ARIPerf/fixture-10000.json -Label baseline

.EXAMPLE
./Measure-ARIPerf.ps1 -FixturePath $env:TEMP/ARIPerf/fixture-10000.json -CompareTo $env:TEMP/ARIPerf/baseline-10000
#>
param(
    [Parameter(Mandatory)]
    [string]$FixturePath,

    [string]$Label = 'run',

    [switch]$IncludeTags,

    [switch]$SkipReport,

    [string]$OutputPath,

    # Folder of an earlier run; fails if any sheet fingerprint differs
    [string]$CompareTo
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$FixtureName = [System.IO.Path]::GetFileNameWithoutExtension($FixturePath)
if (-not $OutputPath) {
    $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) 'ARIPerf' ("$Label-$FixtureName-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$ReportCache = Join-Path $OutputPath 'ReportCache'
$null = New-Item -ItemType Directory -Force -Path $ReportCache
$File = Join-Path $OutputPath 'PerfReport.xlsx'

Get-Job -Name 'ResourceJob_*' -ErrorAction SilentlyContinue | Remove-Job -Force
Remove-Module AzureResourceInventory -ErrorAction SilentlyContinue
Import-Module ImportExcel
$Module = Import-Module (Join-Path $RepoRoot 'AzureResourceInventory.psm1') -Force -PassThru

# Memory sampler: peak working set of this process and of the job processes it starts
$Sampler = [hashtable]::Synchronized(@{ Run = $true; SelfPeak = 0L; JobsPeak = 0L })
$SamplerJob = Start-ThreadJob -ArgumentList $Sampler, $PID -ScriptBlock {
    param($State, $ParentId)
    while ($State.Run) {
        $Self = [System.Diagnostics.Process]::GetProcessById($ParentId)
        $Self.Refresh()
        if ($Self.WorkingSet64 -gt $State.SelfPeak) { $State.SelfPeak = $Self.WorkingSet64 }
        $Children = Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Id -eq $ParentId }
        $Sum = ($Children | Measure-Object WorkingSet64 -Sum).Sum
        if ($Sum -gt $State.JobsPeak) { $State.JobsPeak = $Sum }
        Start-Sleep -Milliseconds 500
    }
}

$Timer = [System.Diagnostics.Stopwatch]::StartNew()
$Fixture = [System.IO.File]::ReadAllText((Resolve-Path $FixturePath)) | ConvertFrom-Json
$Resources = $Fixture.Resources
$Subscriptions = $Fixture.Subscriptions
$LoadSeconds = $Timer.Elapsed.TotalSeconds
Write-Host "Loaded $($Resources.Count) resources in $([math]::Round($LoadSeconds, 1)) s"

# Run inside the module scope so private functions are reachable. Build-ARICacheFiles
# is wrapped to capture each job's begin/end time before the job is removed.
$Phase = & $Module {
    param($Resources, $Subscriptions, $DefaultPath, $InTag, $File, $ReportCache, $SkipReport)

    $JobTimes = [System.Collections.Generic.List[object]]::new()
    $Original = ${function:Build-ARICacheFiles}
    ${function:script:Build-ARICacheFiles} = {
        param($DefaultPath, $JobNames)
        foreach ($Name in $JobNames) {
            $Job = Get-Job -Name $Name -ErrorAction SilentlyContinue
            if ($Job -and $Job.PSEndTime) {
                $JobTimes.Add([pscustomobject]@{ Job = ($Name -replace '^ResourceJob_', ''); Seconds = [math]::Round(($Job.PSEndTime - $Job.PSBeginTime).TotalSeconds, 1); State = [string]$Job.State })
            }
        }
        & $Original -DefaultPath $DefaultPath -JobNames $JobNames
    }.GetNewClosure()

    try {
        $Sw = [System.Diagnostics.Stopwatch]::StartNew()
        Start-ARIProcessOrchestration -Subscriptions $Subscriptions -Resources $Resources -Retirements @() -DefaultPath $DefaultPath -Heavy $false -File $File -InTag $InTag -Automation $false
        $ProcessingSeconds = $Sw.Elapsed.TotalSeconds

        $ReportSeconds = $null
        if (-not $SkipReport) {
            $Sw.Restart()
            Start-ARIExcelJob -ReportCache $ReportCache -File $File -TableStyle 'Light19' | Out-Null
            $ReportSeconds = $Sw.Elapsed.TotalSeconds
        }
    }
    finally {
        ${function:script:Build-ARICacheFiles} = $Original
    }

    [pscustomobject]@{ Processing = $ProcessingSeconds; Report = $ReportSeconds; JobTimes = $JobTimes }
} $Resources $Subscriptions $OutputPath ([bool]$IncludeTags) $File $ReportCache ([bool]$SkipReport)

$Sampler.Run = $false
$SamplerJob | Wait-Job | Remove-Job

$CacheMB = (Get-ChildItem $ReportCache -File | Measure-Object Length -Sum).Sum / 1MB

# Sheet fingerprints: row count + SHA256 of the sheet as CSV
$Fingerprint = [ordered]@{}
if (Test-Path $File) {
    foreach ($Sheet in (Get-ExcelSheetInfo -Path $File).Name) {
        $Rows = @(Import-Excel -Path $File -WorksheetName $Sheet)
        $Csv = ($Rows | ConvertTo-Csv -NoTypeInformation) -join "`n"
        $Hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Csv)))
        $Fingerprint[$Sheet] = [ordered]@{ Rows = $Rows.Count; Hash = $Hash }
    }
}

$Result = [ordered]@{
    Label             = $Label
    Date              = (Get-Date).ToString('s')
    Commit            = (git -C $RepoRoot rev-parse --short HEAD)
    Fixture           = $FixtureName
    ResourceCount     = $Resources.Count
    IncludeTags       = [bool]$IncludeTags
    Machine           = [ordered]@{ Cpus = [Environment]::ProcessorCount; Pwsh = $PSVersionTable.PSVersion.ToString(); OS = [Environment]::OSVersion.VersionString }
    LoadSeconds       = [math]::Round($LoadSeconds, 1)
    ProcessingSeconds = [math]::Round($Phase.Processing, 1)
    ReportSeconds     = if ($null -ne $Phase.Report) { [math]::Round($Phase.Report, 1) } else { $null }
    PeakSelfMB        = [math]::Round($Sampler.SelfPeak / 1MB)
    PeakJobsMB        = [math]::Round($Sampler.JobsPeak / 1MB)
    CacheMB           = [math]::Round($CacheMB, 1)
    Sheets            = $Fingerprint.Count
    JobSeconds        = @($Phase.JobTimes | Sort-Object Seconds -Descending)
}
$Result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath 'results.json')
$Fingerprint | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath 'fingerprint.json')

Write-Host ''
Write-Host "Results: $OutputPath"
[pscustomobject]$Result | Select-Object ResourceCount, LoadSeconds, ProcessingSeconds, ReportSeconds, PeakSelfMB, PeakJobsMB, CacheMB, Sheets | Format-List | Out-String | Write-Host
Write-Host 'Slowest jobs:'
$Result.JobSeconds | Select-Object -First 5 | Format-Table -AutoSize | Out-String | Write-Host

if ($CompareTo) {
    $Old = Get-Content (Join-Path $CompareTo 'fingerprint.json') -Raw | ConvertFrom-Json -AsHashtable
    $Diff = foreach ($Sheet in ($Old.Keys + $Fingerprint.Keys | Select-Object -Unique)) {
        $A = $Old[$Sheet]; $B = $Fingerprint[$Sheet]
        if (-not $A -or -not $B -or $A.Hash -ne $B.Hash) {
            [pscustomobject]@{ Sheet = $Sheet; OldRows = $A.Rows; NewRows = $B.Rows }
        }
    }
    if ($Diff) {
        $Diff | Format-Table -AutoSize | Out-String | Write-Host
        throw "Output differs from $CompareTo in $(@($Diff).Count) sheet(s)."
    }
    Write-Host "Output identical to $CompareTo ($($Fingerprint.Count) sheets)." -ForegroundColor Green
}
