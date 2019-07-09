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

function CreateIfNotExistsAutomationVariable{
    param(
        [Parameter(Mandatory=$true)] 
        [string] $targetResourceGroupname,

        [Parameter(Mandatory=$true)] 
        [string] $appServicePlanName,

        [Parameter(Mandatory=$true)] 
        [object] $job,

        [Parameter(Mandatory=$true)] 
        [string] $name,

        [Parameter(Mandatory=$true)] 
        [object] $value
    )

    $variable = Get-AzAutomationVariable -Name "$targetResourceGroupname.$appServicePlanName.$name" `
        -AutomationAccountName $job.AutomationAccountName `
        -ResourceGroupName $job.ResourceGroupName `
        -ErrorAction SilentlyContinue

    if($variable -eq $null){
        Write-Output "--- --- --- --- --- Creating new variable '$targetResourceGroupname.$appServicePlanName.$name' with value '$value'..."

        New-AzAutomationVariable -Name "$targetResourceGroupname.$appServicePlanName.$name" `
            -AutomationAccountName $job.AutomationAccountName `
            -ResourceGroupName $job.ResourceGroupName `
            -Value $value `
            -Encrypted $false `
            | out-null

        Write-Output "--- --- --- --- --- Finished creating new variable '$targetResourceGroupname.$appServicePlanName.$name'"
    }else{
        $currentValue = $variable.Value
        Write-Output "--- --- --- --- --- Not creating variable '$targetResourceGroupname.$appServicePlanName.$name'. It already exists with value '$currentValue'"
    }
}

Write-Output "Getting Automation Run-As Account 'AzureRunAsConnection'"
$conn = Get-AutomationConnection -Name "AzureRunAsConnection"

Connect-AzAccount -ServicePrincipal -Tenant $conn.TenantID -ApplicationId $conn.ApplicationID -CertificateThumbprint $conn.CertificateThumbprint | out-null
Write-Output "Connected with Run-As Account 'AzureRunAsConnection'"

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
Write-Output "Processing $numberOfresourceGroupNames Resource Groups:"

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
    Write-Output "--- --- Processing $numberOfAppServicePlans App Service Plans"

    foreach($aSPName in $appServicePlanNames){
        Write-Output "--- --- --- Processing '$aSPName' App Service Plan..."

        $currentAppServicePlan = Get-AzAppServicePlan -ResourceGroupName "$rgName" -Name $aSPName
        
        Write-Output "--- --- --- --- Saving current App Service Plan state to Automation Variables..."

        CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
            -appServicePlanName $aSPName `
            -job $jobInfo `
            -name "Sku.Name" `
            -value $currentAppServicePlan.Sku.Name

        CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
            -appServicePlanName $aSPName `
            -job $jobInfo `
            -name "Sku.Tier" `
            -value $currentAppServicePlan.Sku.Tier

        CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
            -appServicePlanName $aSPName `
            -job $jobInfo `
            -name "Sku.Size" `
            -value $currentAppServicePlan.Sku.Size

        Write-Output "--- --- --- --- Finished saving current App Service Plan state to Automation Variables"

        Write-Output "--- --- --- Checking for App Services with Tier-specific settings..."

        $webApps = Get-AzWebApp -AppServicePlan $currentAppServicePlan

        foreach($webApp in $webApps){
            # need to re-get web app to get more verbose object
            $webApp = Get-AzWebApp -ResourceGroupName $rgName -Name $webApp.Name
            
            $webAppName = $webApp.Name
            Write-Output "--- --- --- --- Checking '$webAppName'..."
            $foundSetting = $false

            if($webApp.SiteConfig.AlwaysOn){
                $foundSetting = $true
                Write-Output "--- --- --- --- Found 'AlwaysOn' setting..."

                CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
                    -appServicePlanName $aSPName `
                    -job $jobInfo `
                    -name "$webAppName.AlwaysOn" `
                    -value $true

                Write-Output "--- --- --- --- Modifying 'AlwaysOn'..."

                $webApp.SiteConfig.AlwaysOn = $false
                
                Write-Output "--- --- --- --- Finished modifying 'AlwaysOn'"
            }

            if(!$webApp.SiteConfig.Use32BitWorkerProcess){
                $foundSetting = $true
                Write-Output "--- --- --- --- Found 'Use32BitWorkerProcess' setting..."

                CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
                    -appServicePlanName $aSPName `
                    -job $jobInfo `
                    -name "$webAppName.Use32BitWorkerProcess" `
                    -value $false

                Write-Output "--- --- --- --- Modifying 'Use32BitWorkerProcess''..."

                $webApp.SiteConfig.Use32BitWorkerProcess = $true
                
                Write-Output "--- --- --- --- Finished modifying 'Use32BitWorkerProcess''"
            }

            if($webApp.ClientCertEnabled){
                $foundSetting = $true
                Write-Output "--- --- --- --- Found 'ClientCertEnabled' setting..."

                CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
                    -appServicePlanName $aSPName `
                    -job $jobInfo `
                    -name "$webAppName.ClientCertEnabled" `
                    -value $true

                Write-Output "--- --- --- --- Modifying 'ClientCertEnabled''..."

                $webApp.ClientCertEnabled = $false
                
                Write-Output "--- --- --- --- Finished modifying 'ClientCertEnabled''"
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

        Write-Output "--- --- --- Finished checking for App Services with Tier-specific settings"

        Write-Output "--- --- --- Converting '$aSPName' to Free Tier..."
        Set-AzAppServicePlan -ResourceGroupName "$rgName" -Name $aSPName -Tier "Free" | out-null
        Write-Output "--- --- --- Finished converting '$aSPName' App Service Plan to Free Tier"
    }

    Write-Output "--- Finished processing '$rgName' Resource Group"
}


