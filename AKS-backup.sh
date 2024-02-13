#!/bin/bash

RG_NAME="aks cluster resource group"
RG2_NAME="Managed resource group for you aks cluster"
AKS="your cluster"
FWNAME="Firewall"
RT="your-route-table"
LOCATION="your-region"
VNET="FW-Vnet"
VNET2="your-vnet"
SUBNET2="AzureFirewallSubnet"
SUB="your-subscription"
FWPubIP="FWPubIP"
STORAGEACCT="aks-backup"
CONTAINER="aks-blob"
backupvault="aks-backup-vault"

az account set -s $SUB

az network vnet create --resource-group $RG_NAME --name $VNET --address-prefixes 10.224.0.0/12 -o none
az network vnet subnet create -g $RG_NAME --vnet-name $VNET -n $SUBNET2 --address-prefixes 10.224.0.0/24  -o none

sleep 300

az network vnet peering create -g $RG_NAME -n AKS-FW --vnet-name $VNET --remote-vnet $VNET2 --allow-vnet-access yes --allow-forwarded-traffic yes --no-wait yes -o none
 
 az network firewall create --name $FWNAME --resource-group $RG_NAME \
 --enable-dns-proxy true \
 --location $LOCATION \
 -o none \

az network firewall ip-config create -g $RG_NAME \
 -f $FWNAME \
 -n publicIpConfig \
 --public-ip-address $FWPubIP \
 --vnet-name $VNET \
 -o none \

FWPUBLIC_IP=$(az network public-ip show -g $RG_NAME -n $FWPubIP --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG_NAME -n $FWNAME --query "ipConfigurations[0].privateIPAddress" -o tsv)

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' \
 -n 'apiudp' --protocols 'UDP' --source-addresses '*' --destination-addresses "*" \
 --destination-ports 1194 --action allow --priority 100 -o none

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'apitcp' \
 --protocols 'TCP' --source-addresses '*' --destination-addresses "*" --destination-ports 9000 -o none

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'DNS' \
 --protocols 'UDP' --source-addresses '*'  --destination-addresses "8.8.8.8 8.8.4.4" --destination-ports 53 -o none

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'ghcr' \
 --protocols 'TCP' --source-addresses '*' --destination-fqdns ghcr.io pkg-containers.githubusercontent.com --destination-ports '443' -o none

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'docker' \
 --protocols 'TCP' --source-addresses '*' --destination-fqdns docker.io registry-1.docker.io production.cloudflare.docker.com --destination-ports '443' -o none
 
az network firewall application-rule create \
 --firewall-name $FWNAME \
 --collection-name "aksfwar" \
 --resource-group $RG_NAME \
 --name "Azure Global required FQDN / application rules" \
 --action Allow \
 --priority 200 \
 --protocols https=443 http=80 \
 --source-addresses 10.224.0.0/16 10.225.0.0/24 \
 --target-fqdns "*.cdn.mscr.io" "*.azmk8s.io" "*.azure.net" "login.microsoftonline.com" "*.microsoft.com" "acs-mirror.azureedge.net" "*.azmk8s.io"  "*.azure.com" "*.core.windows.net" "*.ubuntu.com" "*.digicert.com" "*.digicert.cn" "*.geotrust.com" "*.msocsp.com" \
 -o none 

az network route-table route create --name "to firewall" \
  --resource-group $RG2_NAME \
  --route-table-name $RT \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address $FWPRIVATE_IP \
  --output none

az network route-table route create -g $RG2_NAME \
 --name "to internet" \
 --route-table-name $RT \
 --address-prefix $FWPUBLIC_IP/32 \
 --next-hop-type Internet \
 --output none 

az storage account create \
  --name $STORAGEACCT \
  --resource-group $RG2_NAME \
  --location eastus \
  --sku Standard_ZRS \
  --encryption-services blob 

sleep 600

az ad signed-in-user show --query id -o tsv | az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee @- \
  --scope "/subscriptions/$SUB/resourceGroups/$RG2_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGEACCT"

sleep 600    

az storage container create \
  --account-name $STORAGEACCT \
  --name $CONTAINER \
  --auth-mode login

sleep 300

az k8s-extension create --name azure-aks-backup \
 --extension-type microsoft.dataprotection.kubernetes --scope cluster --cluster-type managedClusters \
 --cluster-name $AKS --resource-group $RG_NAME --release-train stable \
 --configuration-settings blobContainer=$CONTAINER storageAccount=$STORAGEACCT storageAccountResourceGroup=$RG2_NAME storageAccountSubscriptionId=$SUB

sleep 600

az dataprotection backup-vault create --resource-group $RG2_NAME \
 --vault-name $backupvault --location $LOCATION --type SystemAssigned \
 --storage-settings datastore-type="VaultStore" type="LocallyRedundant"

sleep 600

 az role assignment create --assignee-object-id \
 $(az k8s-extension show --name azure-aks-backup --cluster-name $AKS --resource-group $RG_NAME --cluster-type managedClusters --query aksAssignedIdentity.principalId --output tsv) \
 --role 'Storage Account Contributor' --scope "/subscriptions/$SUB/resourceGroups/$RG2_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGEACCT"

sleep 600

az aks trustedaccess rolebinding create --cluster-name $AKS --name backuprolebinding --resource-group $RG_NAME \
 --roles Microsoft.DataProtection/backupVaults/backup-operator \
 --source-resource-id /subscriptions/$SUB/resourceGroups/$RG2_NAME/providers/Microsoft.DataProtection/BackupVaults/$backupvault

 




