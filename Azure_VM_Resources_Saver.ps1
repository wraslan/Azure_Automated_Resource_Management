<#
Licensed under the MIT License.

Author:    Waleed Raslan
Created:   14.08.2018

Azure VM Resource Saver removes below resources from a given subscription and this needs to be confirmed before any action is taken:
<<<CAUTION>>>
1- Any VM not tagged with one of the following tags: {Keep, keep, KEEP, do not delete}.
2- Boot diagnostics storage container
3- All associated NICs
4- All associated Public IPs
5- OS disk with the disk status blob
6- All managed/unmanaged data disks

VM resources preserved:
1- Network Security Group (NSG)
2- Virtual Network (VNET)
3- Resource group

#########################
Requirements:
#########################
Windows PowerShell >= 5.1
#########################
PS C:\WINDOWS\system32> $PSVersionTable

Name                           Value                                                                                                              
----                           -----                                                                                                              
PSVersion                      5.1.17763.134  
#######################
Azure PowerShell >= 6.3
#######################
PS C:\WINDOWS\system32> Get-InstalledModule -Name AzureRM

Version    Name                                Repository           Description                                                                   
-------    ----                                ----------           -----------                                                                   
6.13.1     AzureRM                             PSGallery            Azure Resource Manager Module  
###################################
Azure PowerShell (Az) >= 0.7.0
###################################
PS C:\Users\waraslan> Get-InstalledModule -Name Az

Version    Name                                Repository           Description
-------    ----                                ----------           -----------
0.7.0      Az                                  PSGallery            Azure Re...
###################################
#>
param(
    [Parameter(mandatory = $true)][ValidateNotNullOrEmpty()][string] $subscriptionID,
    [Parameter(mandatory = $false)][ValidateNotNullOrEmpty()][string] $showwarnings = 'no'
)
<#Requires -Modules @{ ModuleName="AzureRM"; ModuleVersion="6.3" }#>
Enable-AzureRMAlias
#Requires -Version 5.1
$DeleteVMroutine = {
    param($VM, $subID)
    try {
        Enable-AzureRMAlias
        $ErrorActionPreference = "Stop"
        $WarningPreference = @("SilentlyContinue", "Continue")[$showwarnings -ieq "yes"]
        Select-AzureRmSubscription -SubscriptionId $subID | Out-Null
        $VMName = $VM.Name
        $VM = Get-AzureRmVM -Name $VMName -ResourceGroupName $VM.ResourceGroupName
        # Delete boot diagnostics disk
        if ($VM.DiagnosticsProfile.bootDiagnostics) {
            Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName) Step-1: Deleting boot diagnostics storage container."
            $diagSa = [regex]::match($VM.DiagnosticsProfile.bootDiagnostics.storageUri, '^http[s]?://(.+?)\.').groups[1].value
            if ($VM.Name.Length -gt 9) {
                $i = 9
            }
            else {
                $i = $VM.Name.Length - 1
            }
            $diagContainerName = ('bootdiagnostics-{0}-{1}' -f $VM.Name.ToLower().Substring(0, $i), $VM.Id)
            $diagSaRg = (Get-AzureRmStorageAccount | Where-Object { $_.StorageAccountName -eq $diagSa }).ResourceGroupName
            $saParams = @{
                'ResourceGroupName' = $diagSaRg
                'Name'              = $diagSa
            }
            Get-AzureRmStorageAccount @saParams | Get-AzureStorageContainer | Where-Object { $_.Name -eq $diagContainerName } | Remove-AzureStorageContainer -Force
        }
        # Delete VM
        Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName) Step-2: Deleting the VM."
        Remove-AzureRmVM -Name $VMName -ResourceGroupName $VM.ResourceGroupName -Force
        # Delete NICs
        Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName) Step-3: Deleting NICs & PublicIPs."
        foreach ($nicUri in $VM.NetworkProfile.NetworkInterfaces) {
            $nic = Get-AzureRmNetworkInterface -ResourceGroupName $VM.ResourceGroupName -Name $nicUri.Id.Split('/')[-1]
            Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName): Deleting NIC ($($nic.name)."
            Remove-AzureRmNetworkInterface -Name $nic.Name -ResourceGroupName $VM.ResourceGroupName -Force
            # Delete PublicIPs
            foreach ($ipConfig in $nic.IpConfigurations) {
                if ($ipConfig.PublicIpAddress -ne $null) {
                    $IPName = $ipConfig.PublicIpAddress.Id.Split('/')[-1]
                    Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName): Deleting PublicIP Address ($IPName)."
                    Remove-AzureRmPublicIpAddress -ResourceGroupName $VM.ResourceGroupName -Name $IPName -Force
                }
            }
        }
        # Delete disks
        Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName) Step-4: Deleting disks." 
        $DataDisks = if ($VM.StorageProfile.DataDisks) {@($VM.StorageProfile.DataDisks.Name)}else {@()}
        $OSDisk = @($VM.StorageProfile.OSDisk.Name)
        if ($VM.StorageProfile.OsDisk.ManagedDisk ) {
            ($OSDisk + $DataDisks) | ForEach-Object {
                Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName): Deleting managed disk: $_" 
                Get-AzureRmDisk -ResourceGroupName $VM.ResourceGroupName -DiskName $_ | Remove-AzureRmDisk -Force 
            }
        }
        else {
            # Delete OS disk
            Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName): Deleting unmanaged OS disk."
            $osDiskUri = $VM.StorageProfile.OSDisk.Vhd.Uri
            $osDiskContainerName = $osDiskUri.Split('/')[-2]
            $osDiskStorageAcct = Get-AzureRmStorageAccount | Where-Object { $_.StorageAccountName -eq $osDiskUri.Split('/')[2].Split('.')[0] }
            $osDiskStorageAcct | Remove-AzureStorageBlob -Container $osDiskContainerName -Blob $osDiskUri.Split('/')[-1] -ea Ignore
            # Delete status blob
            Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName): Deleting OS disk status blob."
            $osDiskStorageAcct | Get-AzureStorageBlob -Container $osDiskContainerName -Blob "$($VM.Name)*.status" | Remove-AzureStorageBlob
            # Delete any other attached disks
            if ($DataDisks.Count -gt 0) {
                Write-Host -BackgroundColor Green -ForegroundColor Black "VM ($VMName): Deleting unmanaged data disks."
                foreach ($uri in $VM.StorageProfile.DataDisks.Vhd.Uri) {
                    $dataDiskStorageAcct = Get-AzureRmStorageAccount -Name $uri.Split('/')[2].Split('.')[0]
                    $dataDiskStorageAcct | Remove-AzureStorageBlob -Container $uri.Split('/')[-2] -Blob $uri.Split('/')[-1] -ea Ignore
                }
            }
        }
        Write-Host -BackgroundColor Green -ForegroundColor Black "Complete deletion of VM ($VMName) succeeded."
    }
    Catch {
        $ErrorMEssage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-Host -BackgroundColor Red "Failed to completely delete VM ($VMName) on step ($ErrorLine) with error message: `n$ErrorMessage"
    }
}

try {
    $ErrorActionPreference = "Stop"
    $WarningPreference = @("SilentlyContinue", "Continue")[$showwarnings -ieq "yes"]
    $Start = Get-Date
    $currentlocalPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($currentlocalPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script doesn't run under administrator privileges to protect your system."
        exit
    }
    Enable-AzureRmContextAutosave
    if ([string]::IsNullOrEmpty($(Get-AzureRmContext).Account)) {Write-Host -BackgroundColor Blue "Your user login session has expired, You need to login again as (current user)."; Connect-AzureRmAccount -WarningAction "Continue"}
    Write-Host -BackgroundColor Blue "Selecting provided Azure subscription with ID ($subscriptionID):"
    Select-AzureRmSubscription -SubscriptionId $subscriptionID | Format-List
    $checkTime = Get-Date -Format F
    $VMs = Get-AzureRmVM | Where-Object {($_.Tags['keep'] -eq $null) -and ($_.Tags['Keep'] -eq $null) -and ($_.Tags['KEEP'] -eq $null) -and ($_.Tags['do not delete'] -eq $null)}

    if ($VMs) {
        $Title = "Action Confirmation:"
        $message = "Starting parallel complete deletion of untagged VMs in Azure subscription ($subscriptionID). `nIf you want to keep any VMs, make sure they have any of the following tags set with any value and NOT EMPTY: `nKeep`nkeep`nKEEP`ndo not delete`n`nThis action cannot be undone, Are you sure you want to continue?"
        $options = [System.Management.Automation.Host.ChoiceDescription[]] @("Roger that", "Exit")
        [int]$defaultchoice = 1
        $opt = $host.UI.PromptForChoice($Title , $message , $Options, $defaultchoice)
        switch ($opt) {
            0 {continue} 
            1 {exit}
        }
        $DeleteVM_Jobs = @()
        foreach ($VM in $VMs) {
            $VMName = $VM.Name
            $RG = $VM.ResourceGroupName
            Write-Host -BackgroundColor Blue "Started deletion of VM ($VMName) in resource group ($RG)."
            $DeleteVM_Job = Start-Job -ScriptBlock $DeleteVMroutine -ArgumentList $VM,$subscriptionID
            $DeleteVM_Jobs += $DeleteVM_Job.Id
        }
        Receive-Job -Id $DeleteVM_Jobs -Wait -ErrorAction "Continue"

        # Clean all jobs in this session
        $CurrentJobs = Get-Job
        $CurrentJobsIds = $CurrentJobs.Id
        Remove-Job -id $CurrentJobsIds -Force -ErrorAction "SilentlyContinue"
    }
    else {
        Write-Host -BackgroundColor Green -ForegroundColor black "No untagged VMs to delete in the provided subscription ($subscriptionID). `nValid at this particular point of time: $checkTime"
    }
    $End = Get-Date
    $executionTime = New-TimeSpan -Start $Start -End $End
    $executionTimeSeconds = $executionTime.TotalSeconds
    Write-Host "`nTotal execution time $executionTimeSeconds seconds. `n"
}
Catch {
    $ErrorMEssage = $_.Exception.Message
    $ErrorLine = $_.InvocationInfo.ScriptLineNumber
    Write-Host -BackgroundColor Red $ErrorMessage
}
