param (
	[parameter(Mandatory = $false)]
    [string]$resourceGroupName,

    [Parameter(Mandatory=$false)] 
    [string] $databaseServerName,

    [Parameter(Mandatory=$false)] 
    [string] $databaseName
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
        [string] $dbServerName,

        [Parameter(Mandatory=$true)] 
        [string] $dbName,

        [Parameter(Mandatory=$true)] 
        [object] $job,

        [Parameter(Mandatory=$true)] 
        [string] $name
    )

    Write-Output "--- --- --- --- --- Getting Automation Variable '$targetResourceGroupname.$dbServerName.$dbName.$name'..."

    return Get-AzAutomationVariable -Name "$targetResourceGroupname.$dbServerName.$dbName.$name" `
        -AutomationAccountName $job.AutomationAccountName `
        -ResourceGroupName $job.ResourceGroupName `
        -ErrorAction SilentlyContinue
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

    $databaseServerNames = @()

    if ($databaseServerName.Length -ne 0) {  
        $databaseServerNames += $databaseServerName
    }
    # get all app databases
    else{
        $databaseServers = Get-AzSqlServer -ResourceGroupName $rgName
        
        $databaseServers | ForEach-Object{
            $databaseServerNames += $_.ServerName    
        }
    }

    $numberOfDatabaseServers = $databaseServerNames.Length
    Write-Output "--- Processing $numberOfDatabaseServers Database Servers"

    foreach($dbServerName in $databaseServerNames){
        Write-Output "--- --- Processing '$dbServerName' Database Server..."

        $currentDatabaseServer = Get-AzSqlServer -ResourceGroupName $rgName -Name $dbServerName

        $databaseNames = @()

        if ($databaseName.Length -ne 0) {  
            $databaseNames += $databaseName
        }
        # get all databases
        else{
            $databases = Get-AzSqlDatabase -ResourceGroupName $rgName -ServerName $currentDatabaseServer.ServerName
            
            $databases | ForEach-Object{
                $databaseNames += $_.DatabaseName    
            }
        }

        foreach($dbName in $databaseNames){

            if($dbName -eq "master"){
                continue
            }

            Write-Output "--- --- --- Processing '$dbName' Database..."

            Write-Output "--- --- --- --- Getting Automation Variables..."

            $edition = GetAutomationVariable -targetResourceGroupname $rgName `
                -dbServerName $dbServerName `
                -dbName $dbName `
                -job $jobInfo `
                -name "Edition" `

            $serviceObjectiveName = GetAutomationVariable -targetResourceGroupname $rgName `
                -dbServerName $dbServerName `
                -dbName $dbName `
                -job $jobInfo `
                -name "CurrentServiceObjectiveName" `

            $maxSizeBytes = GetAutomationVariable -targetResourceGroupname $rgName `
                -dbServerName $dbServerName `
                -dbName $dbName `
                -job $jobInfo `
                -name "MaxSizeBytes" `

            Write-Output "--- --- --- --- Finished getting Automation Variables"
            
            $editionValue = $edition.Value
            $serviceObjectiveNameValue = $serviceObjectiveName.Value
            $maxSizeBytesValue = $maxSizeBytes.Value

            Write-Output "--- --- --- --- Converting '$dbName' to '$editionValue' Edition at Size '$serviceObjectiveNameValue'..."

            Set-AzSqlDatabase -ResourceGroupName $rgName `
                -DatabaseName $dbName `
                -ServerName $dbServerName `
                -Edition $editionValue `
                -MaxSizeBytes $maxSizeBytesValue `
                -RequestedServiceObjectiveName $serviceObjectiveNameValue `
                | out-null
            
            Write-Output "--- --- --- --- Finished converting '$dbName' to '$editionValue' Edition at Size '$serviceObjectiveNameValue'"

            Write-Output "--- --- --- Finished processing '$dbName' Database"
        }
        Write-Output "--- --- Finished processing '$dbServerName' Database Server"
    }
    Write-Output "--- Finished processing '$rgName' Resource Group"
}
