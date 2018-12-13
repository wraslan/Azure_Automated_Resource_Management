# Microsoft Azure Cloud Automated Resource Management
Microsoft PowerShell solutions to automate Azure cloud resource management

**Azure VM Resource Saver removes below resources from a given subscription:**

1- Any VM not tagged with one of the following tags:

{Keep, keep, KEEP, do not delete}

2- Boot diagnostics storage container

3- All associated NICs

4- All associated Public IPs

5- OS disk with the disk status blob

6- All managed/unmanaged data disks

**VM resources preserved:**

1- Network Security Group (NSG)

2- Virtual Network (VNET)

3- Resource group
