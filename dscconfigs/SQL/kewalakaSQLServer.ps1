Configuration SQLServer
{
    param
    (
        [Parameter(Mandatory)]
        [pscredential]$domainAdminCred,

        [Parameter(Mandatory)]
        [pscredential]$storageAccount,

        [Parameter(Mandatory)]
        [pscredential]$sqlserviceaccount,

        [Parameter(Mandatory)]
        [pscredential]$sqlagentaccount        
    )

    Import-DscResource -ModuleName xComputerManagement, xFailovercluster, xActiveDirectory, xSQLServer
    Import-DSCResource -ModuleName kewalakaServerConfig

    Node $AllNodes.Nodename
    {

        kewalakaBaseServerConfig basebuild
        {
            DomainName = $Node.DomainName
            domainAdminCred = $domainAdminCred
        } 

        WindowsFeature FailoverClustering
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature RSATClusteringMgmt 
        { 
            Ensure = "Present" 
            Name = "RSAT-Clustering-Mgmt"
            DependsOn = "[WindowsFeature]FailoverClustering"
        } 

        WindowsFeature RSATClusteringPowerShell
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

       WindowsFeature RSATClusteringCmdInterface
       {
           Ensure = "Present"
           Name   = "RSAT-Clustering-CmdInterface"
       }

        If ($node.Role -eq "PrimaryServerNode")
        {
            xCluster FailoverCluster
            {
                DependsOn = @(
                    "[WindowsFeature]RSATClusteringMgmt",
                    "[WindowsFeature]RSATClusteringPowerShell"
                )
                Name = $Node.ClusterName
                StaticIPAddress = $Node.ClusterIPAddress
                DomainAdministratorCredential = $domainAdminCred
            }

            Script CloudWitness
            {
                SetScript = "Set-ClusterQuorum -CloudWitness -AccountName $($storageAccount.GetNetworkCredential().UserName) -AccessKey $($storageAccount.GetNetworkCredential().Password)"
                TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
                GetScript = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
                DependsOn = "[xCluster]FailoverCluster"
            }

            Script IncreaseClusterTimeouts
            {
                SetScript = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
                TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
                GetScript = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
                DependsOn = "[Script]CloudWitness"
            }

            WaitForAll OtherNode
            {
                NodeName = $AllNodes.Where{$_.Role -eq "ReplicaServerNode"}.NodeName
                ResourceName = "[xCluster]joinCluster"
                RetryIntervalSec = 30
                RetryCount = 5
                PsDscRunAsCredential = $domainAdminCred
                DependsOn = "[Script]IncreaseClusterTimeouts"                
            }

            Script EnableS2D
            {
                SetScript = "Enable-ClusterS2D -Confirm:0; New-Volume -StoragePoolFriendlyName S2D* -FriendlyName VDisk01 -FileSystem CSVFS_REFS -UseMaximumSize"
                TestScript = "(Get-ClusterSharedVolume).State -eq 'Online'"
                GetScript = "@{Ensure = if ((Get-ClusterSharedVolume).State -eq 'Online') {'Present'} Else {'Absent'}}"
                DependsOn = "[WaitForAll]OtherNode"
            }

        }

        If ($node.Role -eq "ReplicaServerNode" )
        {

            xWaitForCluster waitForCluster 
            { 
                Name = $Node.ClusterName 
                RetryIntervalSec = 10 
                RetryCount = 20
            } 
      
            xCluster joinCluster 
            { 
                Name = $Node.ClusterName 
                StaticIPAddress = $Node.ClusterIPAddress 
                DomainAdministratorCredential = $domainAdminCred
            
                DependsOn = "[xWaitForCluster]waitForCluster" 
            }
        }        

        If ($node.Role -eq "PrimaryServerNode")
        {
            xSQLServerSetup "InstallSQLServerCluster"
            {
                DependsOn = @(
                    "[Script]EnableS2D"
                )
                Action = 'InstallFailoverCluster'
                ForceReboot = $false

                SourcePath = $Node.SourcePath
                UpdateEnabled = 'False'

                SourceCredential = $storageAccount
                SetupCredential = $domainAdminCred

                InstanceName = $Node.InstanceName
                Features = $Node.Features

                InstallSharedDir = 'C:\Program Files\Microsoft SQL Server'
                InstallSharedWOWDir = 'C:\Program Files (x86)\Microsoft SQL Server'
                InstanceDir = 'C:\Program Files\Microsoft SQL Server'

                SQLSvcAccount  = $sqlserviceaccount
                AgtSvcAccount = $sqlagentaccount
                SQLSysAdminAccounts = $Node.AdminAccounts               

                InstallSQLDataDir = 'C:\ClusterStorage\Volume1\Data'
                SQLUserDBDir = 'C:\ClusterStorage\Volume1\Data'
                SQLUserDBLogDir = 'C:\ClusterStorage\Volume1\Log'
                SQLTempDBDir = 'C:\ClusterStorage\Volume1\Temp'
                SQLTempDBLogDir = 'C:\ClusterStorage\Volume1\Temp'
                SQLBackupDir = 'C:\ClusterStorage\Volume1\Backup'

                FailoverClusterNetworkName = $Node.FailoverClusterNetworkName
                FailoverClusterIPAddress = $Node.FailoverClusterIPAddress

            }
        
            xSqlServerFirewall "FirewallMSSQLSERVER"
            {
                DependsOn = "[xSQLServerSetup]InstallSQLServerCluster"
                SourcePath = $Node.SourcePath
                InstanceName = $Node.InstanceName
                Features = $Node.Features
            }
        }
<#
        xFirewall Firewall-SQL-tcp1433
        {
            Name                  = ""
            Ensure                = "Present"
            Enabled               = "True"
            Profile               = ("Domain")
        }

        xFirewall Firewall-LoadBalancer-tcp59999
        {
            Name                  = ""
            Ensure                = "Present"
            Enabled               = "True"
            Profile               = ("Domain")
        }
    #>

    }       
}
