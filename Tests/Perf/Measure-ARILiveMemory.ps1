<#
.SYNOPSIS
Live memory trace: extraction plus resource processing against a real tenant, read-only.

.DESCRIPTION
Run in a fresh pwsh with an Az login. Imports ARI through the .psd1 (as users do), samples every
500 ms the main process and all child job processes (what Task Manager groups under pwsh), and
reports each peak with the step running at the time. Context autosave is disabled for the process,
so the saved default subscription is untouched. Writes a temporary cache under $env:TEMP.

.EXAMPLE
./Tests/Perf/Measure-ARILiveMemory.ps1 -TenantId <tenant-guid> -Side new
#>
param([Parameter(Mandatory)][string]$TenantId, [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path, [string]$Side = 'run')
$ProgressPreference = 'SilentlyContinue'
$null = Disable-AzContextAutosave -Scope Process
$Mod = Import-Module (Join-Path $RepoRoot 'AzureResourceInventory.psd1') -Force -PassThru -DisableNameChecking

$State = [hashtable]::Synchronized(@{ Run = $true; Step = 'start'; MainPeak = 0L; MainStep = ''; TotalPeak = 0L; TotalStep = ''; JobsAtPeak = 0; Samples = [System.Collections.ArrayList]::new() })
$Sampler = Start-ThreadJob -ArgumentList $State, $PID -ScriptBlock {
    param($S, $ProcId)
    while ($S.Run) {
        $Main = (Get-Process -Id $ProcId).WorkingSet64
        $Kids = @(Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Id -eq $ProcId })
        $KidSum = [long]($Kids | Measure-Object WorkingSet64 -Sum).Sum
        if ($Main -gt $S.MainPeak) { $S.MainPeak = $Main; $S.MainStep = $S.Step }
        if (($Main + $KidSum) -gt $S.TotalPeak) { $S.TotalPeak = $Main + $KidSum; $S.TotalStep = $S.Step; $S.JobsAtPeak = $Kids.Count }
        Start-Sleep -Milliseconds 500
    }
}

& $Mod {
    param($State, $TenantId)
    $Subs = Get-ARISubscriptions -TenantID $TenantId -PlatOS 'PowerShell Desktop' 6>$null
    $DebugPreference = 'Continue'
    $Data = $null
    Start-ARIExtractionOrchestration -Subscriptions $Subs -SkipPolicy $false -AzureEnvironment 'AzureCloud' 6>$null 5>&1 |
        ForEach-Object { if ($_ -is [System.Management.Automation.DebugRecord]) { $State.Step = 'extract: ' + ($_.Message -replace '^\S+ - ', '') } else { $Data = $_ } }
    $State.Step = 'processing'
    $Cache = Join-Path ([IO.Path]::GetTempPath()) 'ARIPerf\memtrace'
    $null = New-Item -ItemType Directory -Force (Join-Path $Cache 'ReportCache')
    Start-ARIProcessOrchestration -Subscriptions $Subs -Resources $Data.Resources -Retirements $Data.Retirements -DefaultPath $Cache -Heavy $false -InTag $false -Automation $false 6>$null 5>&1 |
        ForEach-Object { if ($_ -is [System.Management.Automation.DebugRecord]) { $State.Step = 'process: ' + ($_.Message -replace '^\S+ - ', '') } }
    Remove-Item -Recurse -Force $Cache
} $State $TenantId

$State.Run = $false; $Sampler | Wait-Job | Remove-Job
"{0}: main peak {1:N0} MB during [{2}]" -f $Side, ($State.MainPeak / 1MB), $State.MainStep
"{0}: main+jobs peak {1:N0} MB with {2} job processes during [{3}]" -f $Side, ($State.TotalPeak / 1MB), $State.JobsAtPeak, $State.TotalStep
