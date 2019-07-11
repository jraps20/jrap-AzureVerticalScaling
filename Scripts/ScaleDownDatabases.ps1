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

function CreateIfNotExistsAutomationVariable{
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
        [string] $name,

        [Parameter(Mandatory=$true)] 
        [object] $value
    )

    $variable = Get-AzAutomationVariable -Name "$targetResourceGroupname.$dbServerName.$dbName.$name" `
        -AutomationAccountName $job.AutomationAccountName `
        -ResourceGroupName $job.ResourceGroupName `
        -ErrorAction SilentlyContinue

    if($variable -eq $null){
        Write-Output "--- --- --- --- --- --- Creating new variable '$targetResourceGroupname.$dbServerName.$dbName.$name' with value '$value'..."

        New-AzAutomationVariable -Name "$targetResourceGroupname.$dbServerName.$dbName.$name" `
            -AutomationAccountName $job.AutomationAccountName `
            -ResourceGroupName $job.ResourceGroupName `
            -Value $value `
            -Encrypted $false `
            | out-null

        Write-Output "--- --- --- --- --- --- Finished creating new variable '$targetResourceGroupname.$dbServerName.$dbName.$name'"
    }else{
        $currentValue = $variable.Value
        Write-Output "--- --- --- --- --- --- Not creating variable '$targetResourceGroupname.$dbServerName.$dbName.$name'. It already exists with value '$currentValue'"
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

    $databaseServerNames = @()

    if ($databaseServerName.Length -ne 0) {  
        $databaseServerNames += $databaseServerName
    }
    # get all database servers
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

            Write-Output "--- --- --- --- Saving current Database state to Automation Variables..."

            $database = Get-AzSqlDatabase -ResourceGroupName $rgName `
                -ServerName $dbServerName `
                -DatabaseName $dbName

            CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
                -dbServerName $dbServerName `
                -dbName $dbName `
                -job $jobInfo `
                -name "Edition" `
                -value $database.Edition

            CreateIfNotExistsAutomationVariable -targetResourceGroupname $rgName `
                -dbServerName $dbServerName `
                -dbName $dbName `
                -job $jobInfo `
                -name "CurrentServiceObjectiveName" `
                -value $database.CurrentServiceObjectiveName

            Write-Output "--- --- --- --- Finished saving current Database state to Automation Variables"

            # AggregationType 3 = 'Maximum'
            # 00:01:00 to get most recent allocation size
            # automatic allocatin of 30% current consumed size
            $allocationMetric = Get-AzMetric -ResourceID $database.ResourceId `
                -MetricName allocated_data_storage `
                -AggregationType 3

            # detects current allocation size in bytes
            $currentAllocation = $allocationMetric.Data[0].Minimum 

            # Basic, < 2GB
            if($currentAllocation -lt 2147483648){
                Write-Output "--- --- --- --- Converting '$dbName' Database to Basic Edition..."

                Set-AzSqlDatabase -ResourceGroupName $rgName `
                -DatabaseName $dbName `
                -ServerName $dbServerName `
                -Edition "Basic" `
                | out-null

                Write-Output "--- --- --- --- Finished converting '$dbName' Database to Basic Edition"
            }
            #Standard, < 250GB
            elseif($currentAllocation -lt 26843545600000){
                Write-Output "--- --- --- --- Converting '$dbName' Database to Standard Edition (S0)..."

                Set-AzSqlDatabase -ResourceGroupName $rgName `
                -DatabaseName $dbName `
                -ServerName $dbServerName `
                -Edition "Standard" `
                -RequestedServiceObjectiveName "S0" `
                | out-null

                Write-Output "--- --- --- --- Finished converting '$dbName' Database to Standard Edition (S0)"
            }
            else{
                Write-Output "--- --- --- --- No action performed on '$dbName' Database"
            }

            Write-Output "--- --- --- Finished processing '$dbName' Database"
        }
        Write-Output "--- --- Finished processing '$dbServerName' Database Server"
    }
    Write-Output "--- Finished processing '$rgName' Resource Group"
}
