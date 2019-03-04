# Microsoft Azure Cloud Automated Resource Management
Microsoft PowerShell solutions to automate Azure cloud resource management

**CAUTION: This solution automatically removes resources from Azure subscriptions so it is not intended to be used on production subscriptions, the author is not responsible for any missuse of this solution.
You need to confirm you fully understand that this solution will remove resources from your subscription before execution**

**Azure VM Resources Saver removes below VM resources from Azure subscriptions in parallel using Microsoft PowerShell Workflow technology:**

1- Any VM not tagged with one of the following tags in 'untagged' removal mode: {keep, do not remove}
Or Any VM tagged with one of the following tags in 'tagged' removal mode: {remove}.

2- Boot diagnostics storage container of the removed VMs

3- All NICs associated with the removed VMs

4- All Public IPs associated with the removed VMs

5- Managed & unmanaged OS disks of the removed VMs and their VHD & status blobs

6- All managed data disks attached to the removed VMs

**VM resources preserved**:
1- Network Security Group (NSG)

2- Virtual Network (VNET)

3- Resource group

4- Storage accounts of boot diagnostics and unmanaged disks
