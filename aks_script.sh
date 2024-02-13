#!/bin/sh

SUBSCRIPTION="your-subscription"
CLUSTER_NAME="test-gen-purpose"
RG_NAME="aks"
KUBERNETES_VERSION="1.27"
LOCATION="your region"
MY_ACR="your ACR" #must be globally unique
MY_AKV="your Key Vault" #must be globally unique

az account set -s $SUBSCRIPTION

echo -e "Creating Resource Group..."
az group create --name $RG_NAME --location $LOCATION

echo -e "Creating the GP AKS cluster with version $KUBERNETES_VERSION..."
az aks create -g $RG_NAME -n $CLUSTER_NAME \
    -o none \
    -k $KUBERNETES_VERSION \
    --location $LOCATION \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --network-dataplane cilium \
    --enable-cluster-autoscaler \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-managed-identity \
    --enable-vpa \
    --os-sku AzureLinux \
    --node-vm-size Standard_D2s_v3 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --node-count 1 \
    --min-count 1 \
    --max-count 3 \
    --node-os-upgrade-channel NodeImage \
    --auto-upgrade-channel rapid
 #  --assign-identity $(az identity show -g $RG_NAME -n ccp-identity --query id -o tsv) \
 #  --assign-kubelet-identity $(az identity show -g $RG_NAME -n gp-kubelet-identity --query id -o tsv) \

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
echo -e "First up is the general purpose user pool running Azure Linux"
az aks nodepool add -g $RG_NAME --cluster-name $CLUSTER_NAME \
    -o none \
    -n mariner \
    --mode user \
    --os-sku AzureLinux \
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

az aks get-credentials -g $RG_NAME -n $CLUSTER_NAME

#linkerd install --crds | kubectl apply -f - && linkerd install | kubectl apply -f -
#linkerd viz install | kubectl apply -f -
#linkerd jaeger install | kubectl apply -f -

#kubectl apply -f ~/code/test-yamls/ingress-nginx-1.8.1.deploy.yaml
echo -e "Installing the latest version of ingress-nginx..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

echo -e "Creating ACR and attaching to AKS cluster"
az acr create -n $MY_ACR -g $RG_NAME --sku basic

az aks update -n $CLUSTER_NAME -g $RG_NAME --attach-acr $MY_ACR

echo -e "Creating Key Vault, enabling AKS Add-on, and attaching to AKS cluster"

az keyvault create -n $MY_AKV -g $RG_NAME -l eastus2

az aks enable-addons --addons azure-keyvault-secrets-provider --name $CLUSTER_NAME --resource-group $RG_NAME

export ID_NAME="$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)"
export IDENTITY_CLIENT_ID="$(az identity show -g $RG_NAME --name $ID_NAME --query 'clientId' -o tsv)"
export KEYVAULT_SCOPE=$(az keyvault show --name $MY_AKV --query id -o tsv)

az role assignment create --role Key Vault Administrator --assignee $IDENTITY_CLIENT_ID --scope $KEYVAULT_SCOPE