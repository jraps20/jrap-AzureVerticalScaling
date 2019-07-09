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

$variables = Get-AzAutomationVariable -AutomationAccountName $jobInfo.AutomationAccountName -ResourceGroupName $jobInfo.ResourceGroupName
Write-Output "variables"
$varLength = $variables.$varLength

Write-Output "Found $varLength variables, deleting..."

foreach($variable in $variables){
    $varName = $variable.Name
    Write-Output " --- Deleting variable: $varName ..."

    Remove-AzAutomationVariable -AutomationAccountName $jobInfo.AutomationAccountName `
        -Name $varName `
        -ResourceGroupName $jobInfo.ResourceGroupName | out-null
    
    Write-Output " --- Finished deleting variable: $varName"
}

Write-Output "Finished deleting variables"