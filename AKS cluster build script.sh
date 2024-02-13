#!/bin/bash

CLUSTER_NAME="test-gen-purpose"
RG_NAME="aks"
KUBERNETES_VERSION="1.25.11"
LOCATION="your region"
VNET="LabVnet"
SUBNET1="AKSsubnet"
SUBNET2="AzureFirewallSubnet"
SUB="your-subscription"

az account set -s $SUB

echo -e "Creating Resource Group..."
az group create --name $RG_NAME --location $LOCATION -o none

echo -e "Creating Vnet and Subnets..."
az network vnet create --resource-group $RESOURCEGROUP --name $VNET --address-prefixes 10.1.0.0/16 -o none
az network vnet subnet create -g $RG_NAME --vnet-name $VNET -n $SUBNET1 --address-prefixes 10.1.1.0/24 -o none
az network vnet subnet create -g $RG_NAME --vnet-name $VNET -n $SUBNET2 --address-prefixes 10.1.2.0/24 -o none

echo -e "Creating Azure Firewall and associated rules..."
az network firewall create --name LabFW --resource-group $RG_NAME \
 --sku AZFW_VNet \
 --tier Basic \
 --vnet-name $VNET \
 --public-ip-count 1 \
 --location $LOCATION \
 --no-wait yes\
 --o none
 
az network firewall application-rule create \
 --firewall-name LabFW \
 --resource-group $RESOURCEGROUP \
 --name "Azure Global required FQDN / application rules" \
 --action Allow \
 --priority 200 \
 --protocols https=443 \
 --source-addresses 10.1.1.0/24 10.1.2.0/24 \
 --target-fqdns "*.cdn.mscr.io" "*.azmk8s.io" "management.azure.com" "login.microsoftonline.com" "packages.microsoft.com" "*.data.mcr.microsoft.com" "mcr.microsoft.com" \
 --o none



echo -e "Creating the GP AKS cluster with version $KUBERNETES_VERSION..."
az aks create -g $RG_NAME -n $CLUSTER_NAME \
    -o none \
    -k $KUBERNETES_VERSION \
    --location $LOCATION \
    --network-plugin azure \
    --network-dataplane azure \
    --vnet-subnet-id $(az network vnet subnet show -g $RG_NAME --vnet-name $VNET -n $SUBNET1 --query id -o tsv) \
    --enable-cluster-autoscaler \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-managed-identity \
    --enable-vpa \
    --assign-identity $(az identity show -g $RG_NAME -n ccp-identity --query id -o tsv) \
    --assign-kubelet-identity $(az identity show -g $RG_NAME -n gp-kubelet-identity --query id -o tsv) \
    --os-sku Ubuntu \
    --node-vm-size Standard_D2s_v3 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --node-count 1 \
    --min-count 1 \
    --max-count 3 \
    --outbound-type loadbalancer

echo -e "grabbing FW IP and creating Route Table with routes..."
az network route-table route create --name aksroutetable \
   --resource-group $RG_NAME \
   --location $LOCATION \
   --no-wait yes \
   -o none

az az network route-table route create --name route1
   --resource-group $RG_NAME \
   --route-table-name aksroutetable \
   --address-prefix $SUBNET1 \
   --next-hop-type VirtualAppliance \
   --next-hop-ip-address $(az network firewall show -g $RG_NAME -n LabFW --query private-ip-address -o tsv) \
   --output none

echo -e "Disabling the Azure Defender for Kubernetes to further work on the cluster - this is required for any Ampere nodepools as Defender doesn't support ARM nodes..."
az aks update -g $RG_NAME -n $CLUSTER_NAME \
    --disable-defender \
    -o none

echo -e "Tainting the system nodepool to prevent any workloads from being scheduled on it..."
az aks nodepool update -g $RG_NAME \
    --cluster-name $CLUSTER_NAME \
    -n nodepool1 \
    --node-taints CriticalAddonsOnly=true:NoSchedule \
    -o none

echo -e "Adding the nodepools..."
echo -e "First up is the general purpose user pool running Windows"
az aks nodepool add -g $RG_NAME --cluster-name $CLUSTER_NAME \
    -o none \
    -n windows \
    --mode user \
    --os-sku windows \
    --enable-cluster-autoscaler \
    --min-count 1 \
    --max-count 2 \
    --node-count 1 \
    --node-vm-size Standard_D2s_v3 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30

#az aks nodepool add -g $RG_NAME --cluster-name $CLUSTER_NAME \
#    -n ampere \
#    --node-count 1 \
#    --node-vm-size Standard_D2pds_v5 \
#    --node-osdisk-type Ephemeral \
#    --node-osdisk-size 30
#    --enable-cluster-autoscaler \
#    --min-count 0 \
#    --max-count 3

echo -e "And finally, the Ubuntu node pool"
az aks nodepool add -g $RG_NAME --cluster-name $CLUSTER_NAME \
    -o none \
    -n linux \
    --node-count 1 \
    --node-vm-size Standard_D2s_v3 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --enable-cluster-autoscaler \
    --min-count 0 \
    --max-count 2

az aks upgrade \
    --resource-group $RG_NAME \
    --name $CLUSTER_NAME \
    --kubernetes-version 1.28.0

printf 'y\ny\n' | ./script

#az aks get-credentials -g $RG_NAME -n $CLUSTER_NAME

#linkerd install --crds | kubectl apply -f - && linkerd install | kubectl apply -f -
#linkerd viz install | kubectl apply -f -
#linkerd jaeger install | kubectl apply -f -

#kubectl apply -f ~/code/test-yamls/ingress-nginx-1.8.1.deploy.yaml
#echo -e "Installing the latest version of ingress-nginx..."
#kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml