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
                -name "MaxSizeBytes" `
                -value $database.MaxSizeBytes

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

            # automatic allocation = of 30% current consumed size
            # get single value for past hour
            $allocationMetric = Get-AzMetric -ResourceID $database.ResourceId `
                -MetricName allocated_data_storage `
                -AggregationType Maximum `
                -TimeGrain (New-TimeSpan -Hours 1)

            # detects current allocation size in bytes
            $currentAllocation = $allocationMetric.Data.Maximum 

            Write-Output "--- --- --- Current allocation in bytes: $currentAllocation"

            # Basic, < 2GB
            if($currentAllocation -lt 2147483648){
                Write-Output "--- --- --- --- Allocation less than 2GB, converting '$dbName' Database to Basic Edition..."

                Set-AzSqlDatabase -ResourceGroupName $rgName `
                -DatabaseName $dbName `
                -ServerName $dbServerName `
                -Edition "Basic" `
                | out-null

                Write-Output "--- --- --- --- Finished converting '$dbName' Database to Basic Edition"
            }
            #Standard S0, < 250GB
            elseif($currentAllocation -lt 268435456000){
                Write-Output "--- --- --- --- Allocation less than 250GB, converting '$dbName' Database to Standard Edition (S0)..."

                Set-AzSqlDatabase -ResourceGroupName $rgName `
                -DatabaseName $dbName `
                -ServerName $dbServerName `
                -Edition "Standard" `
                -RequestedServiceObjectiveName "S0" `
                | out-null

                Write-Output "--- --- --- --- Finished converting '$dbName' Database to Standard Edition (S0)"
            }
            #Premium P1, < 1TB
            elseif($currentAllocation -lt 1099511627776){
                Write-Output "--- --- --- --- Allocation less than 1TB, converting '$dbName' Database to Premium Edition (P1)..."

                Set-AzSqlDatabase -ResourceGroupName $rgName `
                -DatabaseName $dbName `
                -ServerName $dbServerName `
                -Edition "Premium" `
                -RequestedServiceObjectiveName "P1" `
                | out-null

                Write-Output "--- --- --- --- Finished converting '$dbName' Database to Premium Edition (P1)"
            }
            else{
                Write-Output "--- --- --- --- No action performed on '$dbName' Database as allocation is too big, ($currentAllocation) bytes"
            }

            Write-Output "--- --- --- Finished processing '$dbName' Database"
        }
        Write-Output "--- --- Finished processing '$dbServerName' Database Server"
    }
    Write-Output "--- Finished processing '$rgName' Resource Group"
}
