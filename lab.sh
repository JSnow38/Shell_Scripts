#!/bin/bash

CLUSTER_NAME="challenge-cluster-1"
RG_NAME="challenge"
KUBERNETES_VERSION="1.25.11"
FWNAME="Firewall"
RT="routetable"
LOCATION="eastus2"
VNET="challenge-vnet"
SUBNET1="AKSsubnet"
SUBNET2="AzureFirewallSubnet"
SUB="your-subscription"
FWPubIP=FirewallPublicIP

az account set -s $SUB

echo -e "Creating Resource Group..."
az group create --name $RG_NAME --location $LOCATION -o none

echo -e "Creating Vnet, Subnets, and public IPs..."
az network vnet create --resource-group $RG_NAME --name $VNET --address-prefixes 10.1.0.0/16 -o none
az network vnet subnet create -g $RG_NAME --vnet-name $VNET -n $SUBNET1 --address-prefixes 10.1.1.0/24 -o none
az network vnet subnet create -g $RG_NAME --vnet-name $VNET -n $SUBNET2 --address-prefixes 10.1.2.0/24 -o none
az network public-ip create -g $RG_NAME -n $FWPubIP -l $LOCATION --sku "Standard" -o none

echo -e "Creating Azure Firewall and associated rules...grab a snack, it's going to take awhile..."
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

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'time' \
 --protocols 'UDP' --source-addresses '*' --destination-fqdns 'ntp.ubuntu.com' --destination-ports 123 -o none

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'ghcr' \
 --protocols 'TCP' --source-addresses '*' --destination-fqdns ghcr.io pkg-containers.githubusercontent.com --destination-ports '443' -o none

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'aksfwnr' -n 'docker' \
 --protocols 'TCP' --source-addresses '*' --destination-fqdns docker.io registry-1.docker.io production.cloudflare.docker.com --destination-ports '443' -o none
 
az network firewall application-rule create \
 --firewall-name $FWNAME \
 --collection-name "required" \
 --resource-group $RG_NAME \
 --name "Azure Global required FQDN / application rules" \
 --action Allow \
 --priority 200 \
 --protocols https=443 http=80 \
 --source-addresses 10.1.1.0/24 10.1.2.0/24 \
 --target-fqdns "*.cdn.mscr.io" "*.azmk8s.io" "management.azure.com" "login.microsoftonline.com" "packages.microsoft.com" "*.data.mcr.microsoft.com" "mcr.microsoft.com" "acs-mirror.azureedge.net" "*.hcp.eastus2.azmk8s.io"\
 -o none

echo -e "grabbing public IP and creating Route Table with routes..."
az network route-table create --name $RT \
   --resource-group $RG_NAME \
   --location $LOCATION \
   --no-wait \
   -o none

az network route-table route create --name route1 \
   --resource-group $RG_NAME \
   --route-table-name $RT \
   --address-prefix 0.0.0.0/0 \
   --next-hop-type VirtualAppliance \
   --next-hop-ip-address $FWPRIVATE_IP \
   --output none

az network route-table route create -g $RG_NAME \
 --name route2 \
 --route-table-name $RT \
 --address-prefix $FWPUBLIC_IP/32 \
 --next-hop-type Internet \
 --output none 

az network vnet subnet update -g $RG_NAME --vnet-name $VNET --name $SUBNET1 --route-table $RT -o none

echo -e "Creating the cluster with version $KUBERNETES_VERSION..."
az aks create -g $RG_NAME -n $CLUSTER_NAME \
    -o none \
    -k $KUBERNETES_VERSION \
    --location $LOCATION \
    --network-plugin azure \
    --network-dataplane azure \
    --vnet-subnet-id $(az network vnet subnet show -g $RG_NAME --vnet-name $VNET -n $SUBNET1 --query id -o tsv) \
    --enable-cluster-autoscaler \
    --enable-oidc-issuer \
    --os-sku Ubuntu \
    --node-vm-size Standard_D2s_v3 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --node-count 1 \
    --min-count 1 \
    --max-count 3 \
    --outbound-type userDefinedRouting \
    --no-wait

echo -e "Tainting the system nodepool to prevent any workloads from being scheduled on it..."
az aks nodepool update -g $RG_NAME \
    --cluster-name $CLUSTER_NAME \
    -n nodepool1 \
    --node-taints CriticalAddonsOnly=true:NoSchedule \
    -o none

echo -e "Adding the nodepools..."
echo -e "Adding the Ubuntu node pool"
az aks nodepool add -g $RG_NAME --cluster-name $CLUSTER_NAME \
    -o none \
    -n linux \
    --node-count 1 \
    --node-vm-size Standard_D2s_v3 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --enable-cluster-autoscaler \
    --min-count 1 \
    --max-count 2 \
    --no-wait

az network firewall network-rule create -g $RG_NAME -f $FWNAME --collection-name 'refuser' \
 -n 'deny' --protocols 'any' --source-addresses '*' --destination-addresses "*" \
 --destination-ports "*" --action deny --priority 101 -o none    

echo -e "Adding the Windows node pool"
az aks nodepool add -g $RG_NAME --cluster-name $CLUSTER_NAME \
    -o none \
    -n win \
    --mode User \
    --node-count 1 \
    --node-vm-size Standard_D2s_v3 \
    --os-type Windows \
    --os-sku Windows2022 \
    --aks-custom-headers WindowsContainerRuntime=containerd \
    --enable-cluster-autoscaler \
    --min-count 1 \
    --max-count 2 \
    --no-wait   

echo -e "alright, that's it, good luck and happy troubleshooting!!!"