<#
Licensed under the MIT License.

Author:    Waleed Raslan
Created:   10.02.2019

CAUTION: This solution automatically removes resources from Azure subscriptions so it is not intended to be used on production subscriptions, the author is not responsible for any missuse of this solution.
You need to confirm you fully understand that this solution will remove resources from your subscription by using this input (i understand the risks) for parameter (caution_resources_will_be_removed_from_subscription)

Azure VM Resources Saver removes below VM resources from Azure subscriptions in parallel using Microsoft PowerShell Workflow technology:
1- Any VM not tagged with one of the following tags in 'untagged' removal mode: {keep, do not remove}
Or Any VM tagged with one of the following tags in 'tagged' removal mode: {remove}.
2- Boot diagnostics storage container of the removed VMs
3- All NICs associated with the removed VMs
4- All Public IPs associated with the removed VMs
5- Managed & unmanaged OS disks of the removed VMs and their VHD & status blobs
6- All managed data disks attached to the removed VMs

VM resources preserved:
1- Network Security Group (NSG)
2- Virtual Network (VNET)
3- Resource group
4- Storage accounts of boot diagnostics and unmanaged disks

Compatibility: Tested on Azure Automation with AzureRM modules updated to latest available versions as of this date 26.02.2019
Azure Automation modules that may need to be re-imported in Azure Automation Account:
AzureRM.Compute
AzureRM.Network
#>
Workflow  VMResourcesSaverAutomation {
    Param(
        [Parameter(mandatory = $true)][ValidateNotNullOrEmpty()][string]$caution_resources_will_be_removed_from_subscription,
        [Parameter(mandatory = $true)][ValidateNotNullOrEmpty()][string]$removal_Mode,
        [int]$Throttle_Limit = 20,
        [string]$show_Warnings = 'yes',
        [string]$connection_Name = "AzureRunAsConnection"
    )
    $ErrorActionPreference = "Stop"
    $WarningPreference = @("SilentlyContinue", "Continue")[$show_Warnings -ieq "yes"]
    $VerbosePreference = "Continue"
    if ($caution_resources_will_be_removed_from_subscription -ine "i understand the risks") {
        Write-Output "You need to confirm you fully understand that this solution will remove resources from your subscription by using this input (i understand the risks) for parameter (caution_resources_will_be_removed_from_subscription)"
        exit
    }
    try {
        # Get the connection
        Write-Output "Obtaining service principal connection..."
        $servicePrincipalConnection = Get-AutomationConnection -Name $connection_Name
        Write-Output "Logging in to Azure..."
        Add-AzureRmAccount -ServicePrincipal -TenantId $servicePrincipalConnection.TenantId -ApplicationId $servicePrincipalConnection.ApplicationId -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
        Select-AzureRmSubscription -SubscriptionId $servicePrincipalConnection.SubscriptionID
        $Start = Get-Date
        $checkTime = Get-Date -Format F
        if (($removal_Mode -ieq "untagged") -or ($removal_Mode -ieq "tagged")) {
            $VMList = InlineScript {
                $VMList = @()
                if ($Using:removal_Mode -ieq "untagged") {
                    $VMs = Get-AzureRMVM | Where-Object {!(($_.Tags).ContainsKey('keep')) -and !(($_.Tags).ContainsKey('do not remove'))}
                }
                else {
                    $VMs = Get-AzureRmVM | Where-Object {(($_.Tags).ContainsKey('remove'))}
                }
                foreach ($VM in $VMs) {
                    $VMList += @{"resourceGroup" = $VM.resourceGroupName; "Name" = $VM.Name; "id" = $VM.id; "VmId" = $VM.VmId; "BootDiag" = $VM.DiagnosticsProfile.bootDiagnostics.StorageUri; "nics" = $VM.NetworkProfile.NetworkInterfaces; "OSDisk" = $VM.StorageProfile.OSDisk.Name; "OSDiskVHD" = $VM.StorageProfile.OSDisk.Vhd.Uri}
                }
                $VMList
            }
        }
        else {
            Write-Output "Invalid removal Mode specified, valid options 'untagged' or 'tagged'"
            exit
        }
    }
    Catch {
        Write-Output "Failed to obtain service principal, login to Azure and Get VMs: " $_
        exit
    }
    if ($VMList) {
        Write-Output "`nStarting parallel complete removal of $removal_Mode VM resources..."
        foreach -parallel -ThrottleLimit $Throttle_Limit ($virtualmachine in $VMList) {
            try {
                $VMName = $virtualmachine["Name"]
                $VMRG = $virtualmachine["resourceGroup"]
                Write-Output "Started removal of VM ($VMName) in resource group ($VMRG)..."
                $VMDisks = InlineScript {
                    $VMDisks = @()
                    $VMDiskList = Get-AzureRmDisk | Where-Object {$_.ManagedBy -eq $Using:virtualmachine["id"]}
                    foreach ($Disk in $VMDiskList) {
                        $VMDisks += @{"resourceGroup" = $Disk.resourceGroupName; "Name" = $Disk.Name; "SourceUri" = $Disk.CreationData.SourceUri}
                    }
                    $VMDisks
                }
                if ($virtualmachine["BootDiag"]) {
                    $diagSa = [regex]::match($virtualmachine["BootDiag"], '^http[s]?://(.+?)\.').groups[1].value
                    $VMdiagname = $VMName -replace '[^a-zA-Z0-9]', ''
                    if ($VMdiagname.Length -gt 9) {$i = 9}else {$i = $VMdiagname.Length}
                    $diagContainerName = ('bootdiagnostics-{0}-{1}' -f $VMdiagname.ToLower().Substring(0, $i), $virtualmachine["VmId"])
                    $diagSaRg = (Get-AzureRmStorageAccount | Where-Object -FilterScript { $_.StorageAccountName -eq $diagSa }).ResourceGroupName
                    $saParams = @{'ResourceGroupName' = $diagSaRg; 'Name' = $diagSa}
                    Write-Output "($VMName) Step-1: Removing boot diagnostics storage container ($diagContainerName) in storage account ($diagSa)."
                    InlineScript {
                        Get-AzureRmStorageAccount @Using:saParams | Get-AzureStorageContainer | Where-Object -FilterScript { $_.Name -eq $Using:diagContainerName } | Remove-AzureStorageContainer -Force
                    }
                }
                # Remove VM
                Write-Output "($VMName) Step-2: Removing the VM."
                Remove-AzureRmVM -Name $VMName -ResourceGroupName $VMRG -Force
                # Remove NICs
                Write-Output "($VMName) Step-3: Removing NICs & PublicIPs..."
                foreach -parallel -ThrottleLimit $Throttle_Limit ($nicUri in $virtualmachine["nics"]) {
                    $nicName = $nicUri.Id.Split('/')[-1]
                    $nicRG = $nicUri.Id.Split('/')[4]
                    $nicIPIds = InlineScript {
                        $nic = Get-AzureRmNetworkInterface -ResourceGroupName $Using:nicRG -Name $Using:nicName
                        $nicIPIds = $nic.IpConfigurations.PublicIpAddress.Id
                        $nicIPIds
                    }
                    Write-Output "($VMName) Removing NIC ($nicName)."
                    Remove-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $nicRG -Force
                    # Remove PublicIPs
                    foreach -parallel -ThrottleLimit $Throttle_Limit ($ipId in $nicIPIds) {
                        $IPName = $ipId.Split('/')[-1]
                        $IPRG = $ipId.Split('/')[4]
                        Write-Output "($VMName) Removing PublicIP Address ($IPName) of NIC ($nicName)."
                        Remove-AzureRmPublicIpAddress -ResourceGroupName $IPRG -Name $IPName -Force
                    }
                }
                # Remove managed OS & Data disks
                Write-Output "($VMName) Step-4: Removing OS & Data disks..."
                if ($VMDisks.Count -gt 0) {
                    foreach -parallel -ThrottleLimit $Throttle_Limit ($VMDisk in $VMDisks) {
                        #$DiskSourceUri = $VMDisk["SourceUri"]
                        $diskType = @("Data disk", "OS disk")[$VMDisk["Name"] -ieq $virtualmachine["OSDisk"]]
                        Write-Output "($VMName) Removing managed $diskType ($($VMDisk["Name"]))."
                        Remove-AzureRmDisk -DiskName $VMDisk["Name"] -ResourceGroupName $VMDisk["ResourceGroup"] -Force
                    }
                }
                # Remove VHD blob of unmanaged OS disk
                if ($virtualmachine["OSDiskVHD"]) {
                    $VHDUri = $virtualmachine["OSDiskVHD"]
                    $VHDSAName = $VHDUri.Split('/')[2].Split('.')[0]
                    $VHDContainerName = $VHDUri.Split('/')[-2]
                    $UnmanagedVMDiskBlob = $VHDUri.Split('/')[-1]
                    Write-Output "($VMName) Removing VHD blob ($VHDUri) of unmanaged OS Disk ($($virtualmachine["OSDisk"]))."
                    InlineScript {
                        $VHDSA = Get-AzureRmStorageAccount | Where-Object -FilterScript {$_.StorageAccountName -eq $Using:VHDSAName}
                        $VHDSA | Remove-AzureStorageBlob -Container $Using:VHDContainerName -Blob $Using:UnmanagedVMDiskBlob
                        # Remove status blob of unmanaged OS disk
                        Write-Output "($Using:VMName) Removing unmanaged OS disk status blob."
                        $VHDSA | Get-AzureStorageBlob -Container $Using:VHDContainerName -Blob "$($Using:VMName)*.status" | Remove-AzureStorageBlob
                    }
                }
                Write-Output "($VMName) VM completely removed successfully!"
            }
            Catch {
                $ErrorMessage = $_
                Write-Output "Failed to completely Remove VM ($VMName) with error message: `n$ErrorMessage"
            }
        }
    }
    else {
        Write-Output "`nNo $removal_Mode VMs to remove in subscription $($servicePrincipalConnection.SubscriptionID). `nValid at this particular point of time: $checkTime"
    }
    $Endtime = Get-Date
    $executionTime = New-TimeSpan -Start $Start -End $Endtime
    $executionTimeSeconds = $executionTime.TotalSeconds
    Write-Output "`nTotal execution time $executionTimeSeconds seconds.`n"
}
