<#
.SYNOPSIS
Generates a synthetic Azure Resource Graph extract for ARI performance testing.

.DESCRIPTION
Builds a deterministic set of resources shaped like Search-AzGraph output, plus the
ARI/VM/SKU and ARI/VM/Quotas pseudo-resources that the extraction phase adds.
The mix is VM-heavy (VM, NIC, disks, extensions, public IPs) with shared network and
PaaS resources every 50 VMs, spread over subscriptions of 500 VMs each.

With -SeedFile, a real extract (a JSON array of resources) is cloned instead: each copy
gets new subscription IDs so cross-references (VM -> disk -> NIC) stay intact.
Keep seed files outside the repo and outside OneDrive; they contain tenant data.

.EXAMPLE
./New-ARIPerfFixture.ps1 -ResourceCount 50000

.EXAMPLE
./New-ARIPerfFixture.ps1 -ResourceCount 150000 -SeedFile D:\ARIPerf\tenant-extract.json
#>
param(
    [Parameter(Mandatory)]
    [ValidateRange(100, 2000000)]
    [int]$ResourceCount,

    [int]$Seed = 42,

    [string]$SeedFile,

    [string]$OutFile = (Join-Path ([System.IO.Path]::GetTempPath()) 'ARIPerf' "fixture-$ResourceCount.json")
)

$ErrorActionPreference = 'Stop'
$Random = [System.Random]::new($Seed)

function New-Guid2 {
    $Bytes = [byte[]]::new(16)
    $Random.NextBytes($Bytes)
    [guid]::new($Bytes).ToString()
}

function Get-Pick ($Items) { $Items[$Random.Next($Items.Count)] }

$Locations = 'westeurope', 'northeurope', 'southafricanorth'
$VmSizes = 'Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_E8s_v5', 'Standard_B2ms', 'Standard_F4s_v2'
$CreatedDate = '2025-03-01T08:00:00.0000000Z'

$Resources = [System.Collections.Generic.List[object]]::new()
$Subscriptions = [System.Collections.Generic.List[object]]::new()

function New-Resource ($SubId, $Rg, $Type, $Name, $Location, $Properties, $Extra) {
    $Id = "/subscriptions/$SubId/resourceGroups/$Rg/providers/$Type/$Name"
    $Res = [ordered]@{
        id             = $Id
        name           = $Name
        type           = $Type.ToLower()
        tenantId       = '00000000-0000-0000-0000-000000000000'
        kind           = ''
        location       = $Location
        resourceGroup  = $Rg
        subscriptionId = $SubId
        managedBy      = ''
        sku            = $null
        plan           = $null
        properties     = $Properties
        tags           = [ordered]@{ env = (Get-Pick 'prod', 'dev', 'test'); owner = "team$($Random.Next(20))"; costcenter = "cc$($Random.Next(100))"; app = "app$($Random.Next(200))" }
        zones          = $null
        extendedLocation = $null
    }
    if ($Extra) { foreach ($Key in $Extra.Keys) { $Res[$Key] = $Extra[$Key] } }
    $Res
}

if ($SeedFile) {
    $SeedText = [System.IO.File]::ReadAllText($SeedFile)
    $SeedSubs = [regex]::Matches($SeedText, '/subscriptions/([0-9a-fA-F-]{36})') | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique
    $Copy = 0
    while ($Resources.Count -lt $ResourceCount) {
        $Text = $SeedText
        foreach ($Sub in $SeedSubs) {
            $NewSub = New-Guid2
            $Text = $Text -ireplace [regex]::Escape($Sub), $NewSub
            $Subscriptions.Add([ordered]@{ id = $NewSub; name = "perf-sub-$Copy-$($Subscriptions.Count)"; tenantId = '00000000-0000-0000-0000-000000000000' })
        }
        foreach ($Res in ($Text | ConvertFrom-Json)) {
            if ($Resources.Count -ge $ResourceCount) { break }
            $Resources.Add($Res)
        }
        $Copy++
    }
}
else {
    $VmIndex = 0
    $Sub = $null
    while ($Resources.Count -lt $ResourceCount) {
        if ($VmIndex % 500 -eq 0) {
            $Sub = New-Guid2
            $Subscriptions.Add([ordered]@{ id = $Sub; name = "perf-sub-$($Subscriptions.Count)"; tenantId = '00000000-0000-0000-0000-000000000000' })
        }

        # Shared network and PaaS resources every 50 VMs
        if ($VmIndex % 50 -eq 0) {
            $Loc = Get-Pick $Locations
            $NetRg = "rg-net-$VmIndex"
            $VnetName = "vnet-$VmIndex"
            $VnetId = "/subscriptions/$Sub/resourceGroups/$NetRg/providers/Microsoft.Network/virtualNetworks/$VnetName"
            $Subnets = foreach ($s in 0..3) {
                [ordered]@{ id = "$VnetId/subnets/snet-$s"; name = "snet-$s"; properties = [ordered]@{ addressPrefix = "10.$($VmIndex % 250).$s.0/24"; provisioningState = 'Succeeded' } }
            }
            $Resources.Add((New-Resource $Sub $NetRg 'Microsoft.Network/virtualNetworks' $VnetName $Loc ([ordered]@{
                addressSpace = @{ addressPrefixes = @("10.$($VmIndex % 250).0.0/16") }
                subnets = @($Subnets)
                virtualNetworkPeerings = @()
                enableDdosProtection = $false
                provisioningState = 'Succeeded'
            })))
            $Resources.Add((New-Resource $Sub $NetRg 'Microsoft.Network/networkSecurityGroups' "nsg-$VmIndex" $Loc ([ordered]@{
                securityRules = @(foreach ($r in 0..9) { [ordered]@{ name = "rule-$r"; properties = [ordered]@{ priority = 100 + $r; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; sourceAddressPrefix = '*'; destinationPortRange = "$(1000 + $r)"; destinationAddressPrefix = '*'; sourcePortRange = '*' } } })
                provisioningState = 'Succeeded'
            })))
            $AppRg = "rg-app-$VmIndex"
            foreach ($i in 0..1) {
                $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.Storage/storageAccounts' "st$VmIndex$i" $Loc ([ordered]@{
                    accessTier = 'Hot'; supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false
                    creationTime = $CreatedDate; primaryEndpoints = @{ blob = "https://st$VmIndex$i.blob.core.windows.net/" }
                    networkAcls = @{ defaultAction = 'Allow'; virtualNetworkRules = @(); ipRules = @() }
                }) @{ kind = 'StorageV2'; sku = @{ name = 'Standard_LRS'; tier = 'Standard' } }))
            }
            $PlanId = "/subscriptions/$Sub/resourceGroups/$AppRg/providers/Microsoft.Web/serverfarms/plan-$VmIndex"
            $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.Web/serverfarms' "plan-$VmIndex" $Loc ([ordered]@{ numberOfSites = 3; status = 'Ready' }) @{ kind = 'app'; sku = @{ name = 'P1v3'; tier = 'PremiumV3'; capacity = 1 } }))
            foreach ($i in 0..2) {
                $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.Web/sites' "app-$VmIndex-$i" $Loc ([ordered]@{
                    serverFarmId = $PlanId; state = 'Running'; httpsOnly = $true; enabled = $true
                    defaultHostName = "app-$VmIndex-$i.azurewebsites.net"; siteConfig = @{ minTlsVersion = '1.2'; ftpsState = 'Disabled' }
                }) @{ kind = 'app' }))
            }
            foreach ($i in 0..1) {
                $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.KeyVault/vaults' "kv-$VmIndex-$i" $Loc ([ordered]@{
                    enableSoftDelete = $true; enablePurgeProtection = $true; enableRbacAuthorization = $true; sku = @{ name = 'standard' }; accessPolicies = @()
                })))
            }
            $SqlName = "sql-$VmIndex"
            $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.Sql/servers' $SqlName $Loc ([ordered]@{ version = '12.0'; state = 'Ready'; publicNetworkAccess = 'Disabled'; minimalTlsVersion = '1.2' })))
            foreach ($i in 0..2) {
                $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.Sql/servers/databases' "$SqlName/db$i" $Loc ([ordered]@{
                    status = 'Online'; maxSizeBytes = 34359738368; zoneRedundant = $false; currentServiceObjectiveName = 'S1'
                }) @{ id = "/subscriptions/$Sub/resourceGroups/$AppRg/providers/Microsoft.Sql/servers/$SqlName/databases/db$i"; sku = @{ name = 'Standard'; tier = 'Standard'; capacity = 20 } }))
            }
            $Resources.Add((New-Resource $Sub $AppRg 'Microsoft.Insights/components' "appi-$VmIndex" $Loc ([ordered]@{ ApplicationId = "appi-$VmIndex"; Retention = 90; IngestionMode = 'LogAnalytics' }) @{ kind = 'web' }))
        }

        # One VM workload: VM, NIC, OS + data disk, 2 extensions, sometimes a public IP
        $Rg = "rg-vm-$([math]::Floor($VmIndex / 25))"
        $Loc = Get-Pick $Locations
        $VmName = "vm-$VmIndex"
        $Base = "/subscriptions/$Sub/resourceGroups/$Rg/providers"
        $VmId = "$Base/Microsoft.Compute/virtualMachines/$VmName"
        $NicId = "$Base/Microsoft.Network/networkInterfaces/$VmName-nic"
        $OsDiskId = "$Base/Microsoft.Compute/disks/$VmName-osdisk"
        $DataDiskId = "$Base/Microsoft.Compute/disks/$VmName-data0"
        $IsWinVm = ($Random.Next(2) -eq 0)
        $Size = Get-Pick $VmSizes

        $Pip = $null
        if ($Random.Next(10) -lt 3) {
            $Pip = "$Base/Microsoft.Network/publicIPAddresses/$VmName-pip"
            $Resources.Add((New-Resource $Sub $Rg 'Microsoft.Network/publicIPAddresses' "$VmName-pip" $Loc ([ordered]@{
                ipAddress = "20.$($Random.Next(255)).$($Random.Next(255)).$($Random.Next(255))"; publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'
                ipConfiguration = @{ id = "$NicId/ipConfigurations/ipconfig1" }
            }) @{ sku = @{ name = 'Standard'; tier = 'Regional' } }))
        }

        $Resources.Add((New-Resource $Sub $Rg 'Microsoft.Compute/virtualMachines' $VmName $Loc ([ordered]@{
            vmId = (New-Guid2); timeCreated = $CreatedDate; provisioningState = 'Succeeded'
            hardwareProfile = @{ vmSize = $Size }
            licenseType = if ($IsWinVm) { 'Windows_Server' } else { $null }
            storageProfile = [ordered]@{
                imageReference = if ($IsWinVm) { @{ publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'; sku = '2022-datacenter-azure-edition' } } else { @{ publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2' } }
                osDisk = @{ osType = if ($IsWinVm) { 'Windows' } else { 'Linux' }; name = "$VmName-osdisk"; diskSizeGB = 128; managedDisk = @{ id = $OsDiskId; storageAccountType = 'Premium_LRS' } }
                dataDisks = @(@{ lun = 0; name = "$VmName-data0"; diskSizeGB = 256; managedDisk = @{ id = $DataDiskId; storageAccountType = 'Premium_LRS' } })
            }
            osProfile = if ($IsWinVm) { @{ computerName = $VmName; windowsConfiguration = @{ enableAutomaticUpdates = $true } } } else { @{ computerName = $VmName; linuxConfiguration = @{ patchSettings = @{ patchMode = 'AutomaticByPlatform' } } } }
            networkProfile = @{ networkInterfaces = @(@{ id = $NicId; properties = @{ primary = $true } }) }
            diagnosticsProfile = @{ bootDiagnostics = @{ enabled = $true } }
            extended = @{ instanceView = @{ powerState = @{ code = 'PowerState/running'; displayStatus = 'VM running' }; osName = if ($IsWinVm) { 'Windows Server 2022 Datacenter' } else { 'ubuntu' }; osVersion = if ($IsWinVm) { '10.0.20348' } else { '22.04' } } }
        }) @{ zones = @("$($Random.Next(1, 4))") }))

        $Resources.Add((New-Resource $Sub $Rg 'Microsoft.Network/networkInterfaces' "$VmName-nic" $Loc ([ordered]@{
            virtualMachine = @{ id = $VmId }
            networkSecurityGroup = @{ id = "/subscriptions/$Sub/resourceGroups/rg-net-$($VmIndex - ($VmIndex % 50))/providers/Microsoft.Network/networkSecurityGroups/nsg-$($VmIndex - ($VmIndex % 50))" }
            enableAcceleratedNetworking = $true; enableIPForwarding = $false; primary = $true
            ipConfigurations = @(@{ id = "$NicId/ipConfigurations/ipconfig1"; name = 'ipconfig1'; properties = [ordered]@{
                privateIPAddress = "10.$($VmIndex % 250).$($Random.Next(4)).$($Random.Next(4, 250))"; privateIPAllocationMethod = 'Dynamic'; primary = $true
                subnet = @{ id = "/subscriptions/$Sub/resourceGroups/rg-net-$($VmIndex - ($VmIndex % 50))/providers/Microsoft.Network/virtualNetworks/vnet-$($VmIndex - ($VmIndex % 50))/subnets/snet-$($Random.Next(4))" }
                publicIPAddress = if ($Pip) { @{ id = $Pip } } else { $null }
            } })
            dnsSettings = @{ dnsServers = @() }
        })))

        foreach ($Disk in @(@{ Id = $OsDiskId; Name = "$VmName-osdisk"; Size = 128 }, @{ Id = $DataDiskId; Name = "$VmName-data0"; Size = 256 })) {
            $Resources.Add((New-Resource $Sub $Rg 'Microsoft.Compute/disks' $Disk.Name $Loc ([ordered]@{
                diskSizeGB = $Disk.Size; diskState = 'Attached'; timeCreated = $CreatedDate; diskIOPSReadWrite = 500; diskMBpsReadWrite = 100
                encryption = @{ type = 'EncryptionAtRestWithPlatformKey' }; networkAccessPolicy = 'AllowAll'; publicNetworkAccess = 'Enabled'
                osType = if ($Disk.Name -like '*osdisk') { if ($IsWinVm) { 'Windows' } else { 'Linux' } } else { $null }
            }) @{ managedBy = $VmId; sku = @{ name = 'Premium_LRS'; tier = 'Premium' } }))
        }

        $ExtPublishers = if ($IsWinVm) { 'Microsoft.Azure.Monitor', 'Microsoft.Azure.Security' } else { 'Microsoft.Azure.Monitor', 'Microsoft.EnterpriseCloud.Monitoring' }
        foreach ($Publisher in $ExtPublishers) {
            $ExtName = ($Publisher -split '\.')[-1]
            $Resources.Add((New-Resource $Sub $Rg 'Microsoft.Compute/virtualMachines/extensions' "$VmName/$ExtName" $Loc ([ordered]@{
                publisher = $Publisher; type = "$($ExtName)Agent"; typeHandlerVersion = '1.0'; provisioningState = 'Succeeded'; autoUpgradeMinorVersion = $true
            }) @{ id = "$VmId/extensions/$ExtName" }))
        }

        $VmIndex++
    }
    if ($Resources.Count -gt $ResourceCount) { $Resources.RemoveRange($ResourceCount, $Resources.Count - $ResourceCount) }
}

# Pseudo-resources added by the extraction phase (Get-ARIVMSkuDetails / Get-ARIVMQuotas)
$SkuData = foreach ($Loc in $Locations) {
    [ordered]@{
        Location = $Loc
        SKUs = @(foreach ($Size in $VmSizes) {
            [ordered]@{
                Name = $Size; ResourceType = 'virtualMachines'; Family = ($Size -replace '^Standard_([A-Za-z]+)\d+.*$', 'standard$1Family')
                Capabilities = @(
                    @{ Name = 'vCPUs'; Value = '4' }, @{ Name = 'vCPUsPerCore'; Value = '2' }, @{ Name = 'MemoryGB'; Value = '16' },
                    @{ Name = 'MaxDataDiskCount'; Value = '8' }, @{ Name = 'UncachedDiskIOPS'; Value = '6400' },
                    @{ Name = 'UncachedDiskBytesPerSecond'; Value = '153600000' }, @{ Name = 'MaxNetworkInterfaces'; Value = '2' }
                )
            }
        })
    }
}
$QuotaData = foreach ($Sub in $Subscriptions) {
    foreach ($Loc in $Locations) {
        [ordered]@{
            Location = $Loc; SubId = $Sub.id; Subscription = $Sub.name
            Data = @(foreach ($Size in $VmSizes) { [ordered]@{ Name = @{ Value = ($Size -replace '^Standard_([A-Za-z]+)\d+.*$', 'standard$1Family'); LocalizedValue = $Size }; Limit = 350; CurrentValue = $Random.Next(1, 300) } })
        }
    }
}
$Resources.Add([ordered]@{ type = 'ARI/VM/SKU'; properties = @($SkuData) })
$Resources.Add([ordered]@{ type = 'ARI/VM/Quotas'; properties = @($QuotaData) })

$null = New-Item -ItemType Directory -Force -Path (Split-Path $OutFile)
$Fixture = [ordered]@{
    Generated     = (Get-Date).ToString('s')
    Seed          = $Seed
    Source        = if ($SeedFile) { 'seed-clone' } else { 'synthetic' }
    Subscriptions = $Subscriptions
    Resources     = $Resources
}
[System.IO.File]::WriteAllText($OutFile, ($Fixture | ConvertTo-Json -Depth 20 -Compress))

$TypeCounts = $Resources | Group-Object { $_.type } | Sort-Object Count -Descending | Select-Object -First 8 Count, Name
Write-Host "Fixture: $OutFile"
Write-Host "Resources: $($Resources.Count)  Subscriptions: $($Subscriptions.Count)  Size: $([math]::Round((Get-Item $OutFile).Length / 1MB, 1)) MB"
$TypeCounts | Format-Table -AutoSize | Out-String | Write-Host
