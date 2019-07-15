param (
	[parameter(Mandatory = $false)]
    [string]$resourceGroupName,

    [Parameter(Mandatory=$false)] 
    [string] $appServicePlanName
)

function Custom-Get-AzAutomationAccount{

    $AutomationResource = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts

    foreach ($Automation in $AutomationResource)
    {
        $Job = Get-AzAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
        if (!([string]::IsNullOrEmpty($Job)))
        {
            return $Job
        }
    }

    Write-Output "ERROR: Unable to find current Automation Account"
    exit
}

function GetAutomationVariable{
    param(
        [Parameter(Mandatory=$true)] 
        [string] $targetResourceGroupname,

        [Parameter(Mandatory=$true)] 
        [string] $appServicePlanName,

        [Parameter(Mandatory=$true)] 
        [object] $job,

        [Parameter(Mandatory=$true)] 
        [string] $name
    )

    Write-Output "--- --- --- --- --- Getting Automation Variable '$targetResourceGroupname.$appServicePlanName.$name'..."

    return Get-AzAutomationVariable -Name "$targetResourceGroupname.$appServicePlanName.$name" `
        -AutomationAccountName $job.AutomationAccountName `
        -ResourceGroupName $job.ResourceGroupName `
        -ErrorAction SilentlyContinue
}

Write-Output "Getting Automation Run-As Account 'AzureRunAsConnection'"
$conn = Get-AutomationConnection -Name "AzureRunAsConnection"

Connect-AzAccount -ServicePrincipal -Tenant $conn.TenantID -ApplicationId $conn.ApplicationID -CertificateThumbprint $conn.CertificateThumbprint | out-null
Write-Output "Connected with Run-As Account '$automationConnName'"

$jobInfo = Custom-Get-AzAutomationAccount
Write-Output "Automation Account Name: "
Write-Output $jobInfo.AutomationAccountName
Write-Output "Automation Resource Group: "
Write-Output $jobInfo.ResourceGroupName

$resourceGroupNames = @()

if ($resourceGroupName.Length -ne 0) {  
    $resourceGroupNames += $resourceGroupName
}
# get all resource groups
else{
    $resourceGroups = Get-AzResourceGroup
    
    $resourceGroups | ForEach-Object{
        $resourceGroupNames += $_.ResourceGroupName    
    }
}

$numberOfresourceGroupNames = $resourceGroupNames.Length
Write-Output "Processing $numberOfresourceGroupNames Resource Groups"

foreach($rgName in $resourceGroupNames){
    Write-Output "--- Processing '$rgName' Resource Group..."

    $appServicePlanNames = @()

    if ($appServicePlanName.Length -ne 0) {  
        $appServicePlanNames += $appServicePlanName
    }
    # get all app services
    else{
        $appServicePlans = Get-AzAppServicePlan -ResourceGroupName $rgName
        
        $appServicePlans | ForEach-Object{
            $appServicePlanNames += $_.Name    
        }
    }
    $numberOfAppServicePlans = $appServicePlanNames.Length
    Write-Output "--- --- Processing $numberOfAppServicePlans App Service Plans:"

    foreach($aSPName in $appServicePlanNames){
        Write-Output "--- --- --- Processing '$aSPName' App Service Plan..."

        $currentAppServicePlan = Get-AzAppServicePlan -ResourceGroupName "$rgName" -Name $aSPName
        
        Write-Output "--- --- --- --- Getting App Service Plan Automation Variables..."

        $skuName = GetAutomationVariable -targetResourceGroupname $rgName `
            -appServicePlanName $aSPName `
            -job $jobInfo `
            -name "Sku.Name"

        $skuTier = GetAutomationVariable -targetResourceGroupname $rgName `
            -appServicePlanName $aSPName `
            -job $jobInfo `
            -name "Sku.Tier"

        $skuSize = GetAutomationVariable -targetResourceGroupname $rgName `
            -appServicePlanName $aSPName `
            -job $jobInfo `
            -name "Sku.Size"

        Write-Output "--- --- --- --- Finished getting App Service Plan  Automation Variables"

        $tierValue = $skuTier.Value
        $sizeValue = $skuSize.Value
        Write-Output "--- --- --- Converting '$aSPName' to $tierValue Tier at Size '$sizeValue'..."

        $modifiedAppServicePlan = $currentAppServicePlan

        $modifiedAppServicePlan.Sku.Name = $skuName.Value
        $modifiedAppServicePlan.Sku.Tier = $skuTier.Value
        $modifiedAppServicePlan.Sku.Size = $skuSize.Value

        Set-AzAppServicePlan -AppServicePlan $modifiedAppServicePlan | out-null

        Write-Output "--- --- --- Finished converting '$aSPName' App Service Plan to '$tierValue' Tier at Size '$sizeValue'"

        Write-Output "--- --- --- Processing Tier-specific App Services, if present..."

        $webApps = Get-AzWebApp -AppServicePlan $modifiedAppServicePlan

        foreach($webApp in $webApps){
            # need to re-get web app to get more verbose object
            $webApp = Get-AzWebApp -ResourceGroupName $rgName -Name $webApp.Name
            
            $webAppName = $webApp.Name
            Write-Output "--- --- --- --- Checking '$webAppName'..."
            $foundSetting = $false
            
            $alwaysOnVariable = GetAutomationVariable -targetResourceGroupname $rgName `
                -appServicePlanName $aSPName `
                -job $jobInfo `
                -name "$webAppName.AlwaysOn"
            
            if($alwaysOnVariable -ne $null){
                $foundSetting = $true
                Write-Output "--- --- --- --- Found 'AlwaysOn' setting..."
                Write-Output "--- --- --- --- Modifying 'AlwaysOn'..."
                $webApp.SiteConfig.AlwaysOn = $alwaysOnVariable.Value
                Write-Output "--- --- --- --- Finished modifying 'AlwaysOn'"
            }

            $use32BitWorkerProcessVariable = GetAutomationVariable -targetResourceGroupname $rgName `
                -appServicePlanName $aSPName `
                -job $jobInfo `
                -name "$webAppName.Use32BitWorkerProcess"
            
            if($use32BitWorkerProcessVariable -ne $null){
                $foundSetting = $true
                Write-Output "--- --- --- --- Found 'Use32BitWorkerProcess' setting..."
                Write-Output "--- --- --- --- Modifying 'Use32BitWorkerProcess'..."
                $webApp.SiteConfig.Use32BitWorkerProcess = $use32BitWorkerProcessVariable.Value
                Write-Output "--- --- --- --- Finished modifying 'Use32BitWorkerProcess'"
            }

            $clientCertEnabledVariable = GetAutomationVariable -targetResourceGroupname $rgName `
                -appServicePlanName $aSPName `
                -job $jobInfo `
                -name "$webAppName.ClientCertEnabled"
            
            if($clientCertEnabledVariable -ne $null){
                $foundSetting = $true
                Write-Output "--- --- --- --- Found 'ClientCertEnabled' setting..."
                Write-Output "--- --- --- --- Modifying 'ClientCertEnabled'..."
                $webApp.ClientCertEnabled = $clientCertEnabledVariable.Value
                Write-Output "--- --- --- --- Finished modifying 'ClientCertEnabled'"
            }

            if($foundSetting){
                Write-Output "--- --- --- --- Saving modified App Service: '$webAppName'..."
                Set-AzWebApp -WebApp $webApp | out-null
                Write-Output "--- --- --- --- Finished saving modified App Service: '$webAppName'"
            }
            else{
                Write-Output "--- --- --- --- Found zero Tier-specific settings to modify on '$webAppName'"
            }
        }

        Write-Output "--- --- --- Finished processing Tier-specific App Services"
    }

    Write-Output "--- Finished processing '$rgName' Resource Group"
}



