#Requires -Modules Az.Accounts, Az.Resources, Az.Storage, Az.Network, Az.DataFactory

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [ValidateSet('Daily', 'Monthly', 'All')]
    [string]$Test,

    [switch]$GenerateExport
)

# Checks a costmgmt-deploy resource group after a deployment.
# Read only unless you pass one of:
#   -GenerateExport  runs the daily cost export now and waits for it (up to 10 min)
#   -Test            kicks off a real pipeline run and waits on it
#
#   ./Deployment-Validation.ps1 -ResourceGroupName rg-contoso-costmgmt
#   ./Deployment-Validation.ps1 -ResourceGroupName rg-contoso-costmgmt -GenerateExport
#   ./Deployment-Validation.ps1 -ResourceGroupName rg-contoso-costmgmt -Test Daily

$ErrorActionPreference = 'Stop'

# the test run needs the export to have landed first, so one at a time
if ($Test -and $GenerateExport) {
    throw "Don't use -Test and -GenerateExport together. Run -GenerateExport first, then -Test once the export exists."
}

$results = @()
$runParameters = [ordered]@{}
$exports = @()

function Add-Check {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail')] [string]$Status,
        [string]$Detail
    )
    $check = New-Object psobject
    $check | Add-Member -MemberType NoteProperty -Name Check -Value $Name
    $check | Add-Member -MemberType NoteProperty -Name Status -Value $Status
    $check | Add-Member -MemberType NoteProperty -Name Detail -Value $Detail
    $script:results += $check

    $color = switch ($Status) { 'Pass' { 'Green' } 'Warn' { 'Yellow' } 'Fail' { 'Red' } }
    Write-Host ("  [{0}] {1} - {2}" -f $Status.ToUpper(), $Name, $Detail) -ForegroundColor $color
}

$context = Get-AzContext
if (-not $context) {
    throw "Not signed in. Run Connect-AzAccount first."
}
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    throw "Resource group '$ResourceGroupName' not found in subscription '$($context.Subscription.Name)'. Set-AzContext to the right one."
}
Write-Host "Validating $ResourceGroupName in $($context.Subscription.Name)" -ForegroundColor Cyan

# ---- the deployment itself ----
Write-Host "`nDeployment" -ForegroundColor Cyan

# newest deployment that came from our template
$deployment = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.Outputs -and $_.Outputs.Keys -contains 'templateVersion' } |
    Sort-Object Timestamp -Descending |
    Select-Object -First 1

function Get-OutputValue {
    param([Parameter(Mandatory)] [string]$Name)
    if (-not $deployment) { return $null }
    $key = $deployment.Outputs.Keys | Where-Object { $_ -eq $Name }
    if ($key) { return $deployment.Outputs[$key].Value }
}

if ($deployment) {
    $status = if ($deployment.ProvisioningState -eq 'Succeeded') { 'Pass' } else { 'Fail' }
    Add-Check -Name 'Deployment' -Status $status -Detail "$($deployment.DeploymentName) $($deployment.ProvisioningState), template version $(Get-OutputValue -Name 'templateVersion'), $($deployment.Timestamp.ToString('u'))"
} else {
    Add-Check -Name 'Deployment' -Status Warn -Detail 'No finished deployment from this template in the history. Still running, or it failed.'
}

# the scripts hang around for a few hours after the deploy, then get cleaned up
foreach ($scriptName in 'create-focus-exports', 'stop-adf-triggers', 'finalize-adf') {
    $deployScript = Get-AzDeploymentScript -ResourceGroupName $ResourceGroupName -Name $scriptName -ErrorAction SilentlyContinue
    if (-not $deployScript) {
        Add-Check -Name "Script $scriptName" -Status Warn -Detail 'Not found. Probably cleaned up already.'
        continue
    }
    if ($deployScript.ProvisioningState -ne 'Succeeded') {
        Add-Check -Name "Script $scriptName" -Status Fail -Detail $deployScript.ProvisioningState
        continue
    }

    # finalize only warns on some stuff (results upload), so read its log
    $warnings = @()
    try {
        $log = (Get-AzDeploymentScriptLog -ResourceGroupName $ResourceGroupName -Name $scriptName).Log
        $warnings = @($log -split "`n" | Where-Object { $_ -match 'WARNING:' })
    } catch {
        # log is gone once the container is cleaned up, not a problem
    }
    if ($warnings) {
        Add-Check -Name "Script $scriptName" -Status Warn -Detail ($warnings -join ' | ').Trim()
    } else {
        Add-Check -Name "Script $scriptName" -Status Pass -Detail 'Succeeded'
    }
}

# ---- export storage ----
Write-Host "`nExport storage" -ForegroundColor Cyan

$storageName = Get-OutputValue -Name 'storageAccountName'
if ($storageName) {
    $storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageName -ErrorAction SilentlyContinue
} else {
    # skip the temp accounts deployment scripts leave behind
    $storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName |
        Where-Object { $_.StorageAccountName -notlike '*azscripts' } |
        Select-Object -First 1
}

if (-not $storage) {
    Add-Check -Name 'Storage account' -Status Fail -Detail 'No export storage account in the resource group'
} else {
    $firewall = $storage.NetworkRuleSet.DefaultAction
    Add-Check -Name 'Storage account' -Status Pass -Detail "$($storage.StorageAccountName), firewall default $firewall"

    $connections = @(Get-AzPrivateEndpointConnection -PrivateLinkResourceId $storage.Id)
    if (-not $connections -and $firewall -eq 'Deny') {
        Add-Check -Name 'Private endpoint connections' -Status Fail -Detail 'Firewall is Deny but there are no private endpoint connections'
    }
    foreach ($connection in $connections) {
        $state = $connection.PrivateLinkServiceConnectionState.Status
        $endpointName = ($connection.PrivateEndpoint.Id -split '/')[-1]
        $status = if ($state -eq 'Approved') { 'Pass' } else { 'Fail' }
        Add-Check -Name "Storage connection $endpointName" -Status $status -Detail $state
    }
}

# ---- data factory ----
Write-Host "`nData Factory" -ForegroundColor Cyan

$factory = Get-AzDataFactoryV2 -ResourceGroupName $ResourceGroupName | Select-Object -First 1
if (-not $factory) {
    Add-Check -Name 'Data Factory' -Status Fail -Detail 'No Data Factory in the resource group'
} else {
    $adf = @{
        ResourceGroupName = $ResourceGroupName
        DataFactoryName   = $factory.DataFactoryName
    }
    Add-Check -Name 'Data Factory' -Status Pass -Detail $factory.DataFactoryName

    # factory identity has to be able to read the exports
    if ($storage) {
        $roles = @((Get-AzRoleAssignment -ObjectId $factory.Identity.PrincipalId -Scope $storage.Id).RoleDefinitionName)
        $status = if ($roles -contains 'Storage Blob Data Reader') { 'Pass' } else { 'Fail' }
        Add-Check -Name 'Factory access to storage' -Status $status -Detail ($roles -join ', ')
    }

    # no cmdlet for managed private endpoints so go to the api
    $response = Invoke-AzRestMethod -Method GET -Path "$($factory.DataFactoryId)/managedVirtualNetworks/default/managedPrivateEndpoints?api-version=2018-06-01"
    $managedEndpoints = @()
    if ($response.StatusCode -eq 200) {
        $managedEndpoints = @(($response.Content | ConvertFrom-Json).value)
    }
    if (-not $managedEndpoints) {
        $status = if ($storage -and $storage.NetworkRuleSet.DefaultAction -eq 'Deny') { 'Fail' } else { 'Pass' }
        Add-Check -Name 'Managed private endpoint' -Status $status -Detail 'None on the factory'
    }
    foreach ($endpoint in $managedEndpoints) {
        $state = $endpoint.properties.connectionState.status
        $status = if ($state -eq 'Approved') { 'Pass' } else { 'Fail' }
        Add-Check -Name "Managed private endpoint $($endpoint.name)" -Status $status -Detail $state
    }

    $linkedServices = @((Get-AzDataFactoryV2LinkedService @adf).Name)
    foreach ($name in 'SourceStorage', 'DestStorage') {
        $status = if ($linkedServices -contains $name) { 'Pass' } else { 'Fail' }
        Add-Check -Name "Linked service $name" -Status $status -Detail $(if ($status -eq 'Pass') { 'Present' } else { 'Missing' })
    }

    $datasets = @((Get-AzDataFactoryV2Dataset @adf).Name)
    foreach ($name in 'SourceBlobs', 'DestBlobs') {
        $status = if ($datasets -contains $name) { 'Pass' } else { 'Fail' }
        Add-Check -Name "Dataset $name" -Status $status -Detail $(if ($status -eq 'Pass') { 'Present' } else { 'Missing' })
    }

    $pipeline = Get-AzDataFactoryV2Pipeline @adf | Where-Object { $_.Name -like '*-DataMoverPipeline' } | Select-Object -First 1
    if ($pipeline) {
        Add-Check -Name 'Pipeline' -Status Pass -Detail $pipeline.Name
    } else {
        Add-Check -Name 'Pipeline' -Status Fail -Detail 'No *-DataMoverPipeline on the factory'
    }

    # both triggers should exist and be running
    $triggers = @(Get-AzDataFactoryV2Trigger @adf)
    foreach ($suffix in 'DailyTrigger', 'MonthlyTrigger') {
        $trigger = $triggers | Where-Object { $_.Name -like "*-$suffix" } | Select-Object -First 1
        if (-not $trigger) {
            Add-Check -Name "Trigger $suffix" -Status Fail -Detail 'Missing'
            continue
        }
        $recurrence = $trigger.Properties.Recurrence
        $when = "{0} at {1:00}:{2:00} {3}" -f $recurrence.Frequency, $recurrence.Schedule.Hours[0], $recurrence.Schedule.Minutes[0], $recurrence.TimeZone
        $status = if ($trigger.RuntimeState -eq 'Started') { 'Pass' } else { 'Fail' }
        Add-Check -Name "Trigger $($trigger.Name)" -Status $status -Detail "$($trigger.RuntimeState), $when"

        # hang on to what the trigger passes the pipeline, manual runs reuse it
        $parameters = [ordered]@{}
        $triggerParameters = $trigger.Properties.Pipelines[0].Parameters
        foreach ($key in $triggerParameters.Keys) {
            $value = "$($triggerParameters[$key])"
            $parameters[$key] = if ($value -match '^\d+$') { [int]$value } else { $value }
        }
        $runParameters[$suffix -replace 'Trigger'] = $parameters
    }

    # last weeks runs. a brand new deploy wont have any till the first schedule fires
    $runWindow = @{
        LastUpdatedAfter  = (Get-Date).AddDays(-7)
        LastUpdatedBefore = (Get-Date).AddMinutes(5)
    }
    $runs = @(Get-AzDataFactoryV2PipelineRun @adf @runWindow | Sort-Object RunStart -Descending)
    if (-not $runs) {
        Add-Check -Name 'Pipeline runs' -Status Warn -Detail 'No runs in the last 7 days. Normal if the first schedule has not fired yet.'
    } else {
        $last = $runs[0]
        $summary = ($runs | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        $status = switch ($last.Status) { 'Succeeded' { 'Pass' } 'Failed' { 'Fail' } default { 'Warn' } }
        $detail = "Last run $($last.Status) at $($last.RunStart.ToString('u')). Past 7 days: $summary."
        if ($last.Status -eq 'Failed') { $detail += " $($last.Message)" }
        Add-Check -Name 'Pipeline runs' -Status $status -Detail $detail
    }
}

# ---- cost exports ----
Write-Host "`nCost exports" -ForegroundColor Cyan

# these live on the billing profile, so this part needs a billing role to read
$billingScope = Get-OutputValue -Name 'billingProfileScopeId'
if (-not $billingScope -or -not $storage) {
    Add-Check -Name 'Cost exports' -Status Warn -Detail 'Skipped, could not work out the billing scope from the deployment outputs'
} else {
    $response = Invoke-AzRestMethod -Method GET -Path "$billingScope/providers/Microsoft.CostManagement/exports?api-version=2025-03-01&`$expand=runHistory"
    if ($response.StatusCode -ne 200) {
        Add-Check -Name 'Cost exports' -Status Warn -Detail "Could not read exports on the billing profile (HTTP $($response.StatusCode)). Needs a billing role."
    } else {
        # only the ones that write to our storage account
        $exports = @(($response.Content | ConvertFrom-Json).value |
            Where-Object { $_.properties.deliveryInfo.destination.resourceId -eq $storage.Id })
        if (-not $exports) {
            Add-Check -Name 'Cost exports' -Status Fail -Detail "No exports deliver to $($storage.StorageAccountName)"
        }
        foreach ($export in $exports) {
            $schedule = $export.properties.schedule
            $lastRun = @($export.properties.runHistory.value)[0]
            $lastRunText = if ($lastRun) { "last run $($lastRun.properties.status) $($lastRun.properties.processingStartTime)" } else { 'no runs yet' }

            # the one-time export is meant to be Inactive
            $status = 'Pass'
            if ($schedule.recurrence -and $schedule.status -ne 'Active') { $status = 'Fail' }
            if ($lastRun -and $lastRun.properties.status -eq 'Failed') { $status = 'Fail' }
            if ($status -eq 'Pass' -and $schedule.recurrence -and -not $lastRun) { $status = 'Warn' }
            Add-Check -Name "Export $($export.name)" -Status $status -Detail "$($schedule.status), $lastRunText"
        }
    }
}

# ---- generate the daily export ----
if ($GenerateExport) {
    Write-Host "`nGenerate export" -ForegroundColor Cyan

    # daily only. monthly is last months data and not much use for a test
    $daily = $exports | Where-Object { $_.name -like '*-focus-daily' } | Select-Object -First 1
    if (-not $daily) {
        Add-Check -Name 'Generate export' -Status Fail -Detail 'No daily export to run. See the Cost exports checks above.'
    } else {
        $exportPath = "$billingScope/providers/Microsoft.CostManagement/exports/$($daily.name)"
        $destination = $daily.properties.deliveryInfo.destination
        $landingPath = "$($storage.StorageAccountName)/$($destination.container)/$($destination.rootFolderPath)/$($daily.name)/"
        $whereToLook = "Check Cost Management > Exports (billing profile scope) > $($daily.name) > run history, or re-run this script and read the Export line. Files land in $landingPath<yyyyMMdd-yyyyMMdd>/<guid>/"

        # so we can tell our run from an older one
        $previousRun = @($daily.properties.runHistory.value)[0]
        $previousRunName = if ($previousRun) { $previousRun.name } else { $null }

        $response = Invoke-AzRestMethod -Method POST -Path "$exportPath/run?api-version=2025-03-01"
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            Add-Check -Name 'Generate export' -Status Fail -Detail "Run request for $($daily.name) was refused (HTTP $($response.StatusCode)). $($response.Content)"
        } else {
            Write-Host "  $($daily.name) run requested, waiting up to 10 min..." -ForegroundColor Gray

            $deadline = (Get-Date).AddMinutes(10)
            $run = $null
            do {
                Start-Sleep -Seconds 30
                $history = Invoke-AzRestMethod -Method GET -Path "$exportPath`?api-version=2025-03-01&`$expand=runHistory"
                $latest = @(($history.Content | ConvertFrom-Json).properties.runHistory.value |
                    Sort-Object { $_.properties.submittedTime } -Descending)[0]
                if ($latest -and $latest.name -ne $previousRunName) { $run = $latest }
            } while (((-not $run) -or ($run.properties.status -in 'Queued', 'InProgress')) -and ((Get-Date) -lt $deadline))

            if (-not $run -or $run.properties.status -in 'Queued', 'InProgress') {
                Add-Check -Name 'Generate export' -Status Warn -Detail "Export is still being generated. Run -Test Daily once it exists. $whereToLook"
            } elseif ($run.properties.status -eq 'Completed') {
                Add-Check -Name 'Generate export' -Status Pass -Detail "$($daily.name) completed. Files are under $landingPath - now run -Test Daily."
            } else {
                Add-Check -Name 'Generate export' -Status Fail -Detail "Export run ended $($run.properties.status). $($run.properties.error.message) $whereToLook"
            }
        }
    }
}

# ---- test runs ----
if ($Test -and $pipeline) {
    Write-Host "`nTest runs" -ForegroundColor Cyan

    $modes = if ($Test -eq 'All') { 'Daily', 'Monthly' } else { $Test }
    foreach ($mode in $modes) {
        if (-not $runParameters.Contains($mode)) {
            Add-Check -Name "Test run $mode" -Status Fail -Detail "No $mode trigger to copy the parameters from"
            continue
        }

        $runId = Invoke-AzDataFactoryV2Pipeline @adf -PipelineName $pipeline.Name -Parameter ([hashtable]$runParameters[$mode])
        Write-Host "  $mode run $runId started, waiting on it..." -ForegroundColor Gray

        # first run sits for a few min while the managed runtime spins up
        $deadline = (Get-Date).AddMinutes(30)
        do {
            Start-Sleep -Seconds 20
            $run = Get-AzDataFactoryV2PipelineRun @adf -PipelineRunId $runId
        } while (($run.Status -in 'Queued', 'InProgress', 'Canceling') -and ((Get-Date) -lt $deadline))

        switch ($run.Status) {
            'Succeeded' { Add-Check -Name "Test run $mode" -Status Pass -Detail "Succeeded, run $runId" }
            'Failed'    { Add-Check -Name "Test run $mode" -Status Fail -Detail "Run $runId failed. $($run.Message)" }
            default     { Add-Check -Name "Test run $mode" -Status Warn -Detail "Run $runId still $($run.Status) after 30 min" }
        }
    }
}

# ---- summary ----
$failed = @($results | Where-Object Status -eq 'Fail').Count
$warned = @($results | Where-Object Status -eq 'Warn').Count
$passed = @($results | Where-Object Status -eq 'Pass').Count
$color = if ($failed) { 'Red' } elseif ($warned) { 'Yellow' } else { 'Green' }
Write-Host "`n$passed passed, $warned warnings, $failed failed" -ForegroundColor $color

# ---- manual run commands ----
if ($pipeline -and $runParameters.Count) {
    Write-Host "`nManual runs" -ForegroundColor Cyan
    foreach ($mode in $runParameters.Keys) {
        $pairs = foreach ($key in $runParameters[$mode].Keys) {
            $value = $runParameters[$mode][$key]
            if ($value -is [int]) { "$key = $value" } else { "$key = '$value'" }
        }
        Write-Host "# $mode" -ForegroundColor Gray
        Write-Host "Invoke-AzDataFactoryV2Pipeline -ResourceGroupName `"$ResourceGroupName`" -DataFactoryName `"$($factory.DataFactoryName)`" -PipelineName `"$($pipeline.Name)`" -Parameter @{ $($pairs -join '; ') }"
    }
}
