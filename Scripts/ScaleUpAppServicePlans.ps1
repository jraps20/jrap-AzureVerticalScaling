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
        
        Write-Output "--- --- --- --- Getting Automation Variables..."

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

        Write-Output "--- --- --- --- Finished getting Automation Variables"

        $tierValue = $skuTier.Value
        $sizeValue = $skuSize.Value
        Write-Output "--- --- --- Converting '$aSPName' to $tierValue Tier at Size '$sizeValue'..."

        $modifiedAppServicePlan = $currentAppServicePlan

        $modifiedAppServicePlan.Sku.Name = $skuName.Value
        $modifiedAppServicePlan.Sku.Tier = $skuTier.Value
        $modifiedAppServicePlan.Sku.Size = $skuSize.Value

        Set-AzAppServicePlan -AppServicePlan $modifiedAppServicePlan | out-null

        Write-Output "--- --- --- Finished converting '$aSPName' App Service Plan to '$tierValue' Tier at Size '$sizeValue'"

        Write-Output "--- --- --- Processing 'AlwaysOn' App Services, if present..."

        $webApps = Get-AzWebApp -AppServicePlan $modifiedAppServicePlan

        foreach($webApp in $webApps){
            # need to re-get web app to get more verbose object
            $webApp = Get-AzWebApp -ResourceGroupName $rgName -Name $webApp.Name
            $webAppName = $webApp.Name
            
            $alwaysOnVariable = GetAutomationVariable -targetResourceGroupname $rgName `
                -appServicePlanName $aSPName `
                -job $jobInfo `
                -name "$webAppName.AlwaysOn"
            
            if($alwaysOnVariable -ne $null){
                Write-Output "--- --- --- --- Found 'AlwaysOn' App Service '$webAppName'"
                Write-Output "--- --- --- --- Applying 'AlwaysOn' to App Service '$webAppName'..."
                $modifiedWebApp = $webApp
                $modifiedWebApp.SiteConfig.AlwaysOn = $alwaysOnVariable.Value
                Set-AzWebApp -WebApp $modifiedWebApp | out-null
                Write-Output "--- --- --- --- Finished applying 'AlwaysOn' to App Service '$webAppName'"
            }
        }

        Write-Output "--- --- --- Finished processing 'AlwaysOn' App Services"
    }

    Write-Output "--- Finished processing '$rgName' Resource Group"
}



