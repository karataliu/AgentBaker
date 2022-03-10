#!/bin/bash

set -euxo pipefail

source e2e-helper.sh

log() {
    printf "\\033[1;33m%s\\033[0m\\n" "$*"
}

ok() {
    printf "\\033[1;32m%s\\033[0m\\n" "$*"
}

err() {
    printf "\\033[1;31m%s\\033[0m\\n" "$*"
}

log "Starting e2e tests"

: "${SUBSCRIPTION_ID:=8ecadfc9-d1a3-4ea4-b844-0d9f87e4d7c8}" #Azure Container Service - Test Subscription
: "${RESOURCE_GROUP_NAME:=agentbaker-e2e-tests}"
: "${LOCATION:=eastus}"
: "${CLUSTER_NAME:=agentbaker-e2e-test-cluster}"

globalStartTime=$(date +%s)

# Create a resource group for the cluster
log "Creating resource group"
rgStartTime=$(date +%s)
az group create -l $LOCATION -n $RESOURCE_GROUP_NAME --subscription $SUBSCRIPTION_ID -ojson
rgEndTime=$(date +%s)
log "Created resource group in $((rgEndTime-rgStartTime)) seconds"

# Check if there exists a cluster in the RG. If yes, check if the MC_RG associated with it still exists.
# MC_RG gets deleted due to ACS-Test Garbage Collection but the cluster hangs around
out=$(az aks list -g $RESOURCE_GROUP_NAME -ojson | jq '.[].name')
create_cluster="false"
if [ -n "$out" ]; then
    MC_RG_NAME="MC_${RESOURCE_GROUP_NAME}_${CLUSTER_NAME}_$LOCATION"
    exists=$(az group exists -n $MC_RG_NAME)
    if [ $exists = "false" ]; then
        log "Deleting cluster"
        clusterDeleteStartTime=$(date +%s)
        az aks delete -n $CLUSTER_NAME -g $RESOURCE_GROUP_NAME --yes
        clusterDeleteEndTime=$(date +%s)
        log "Deleted cluster in $((clusterDeleteEndTime-clusterDeleteStartTime)) seconds"
        create_cluster="true"
    fi
else
    create_cluster="true"
fi

# Create the AKS cluster and get the kubeconfig
if [ "$create_cluster" == "true" ]; then
    log "Creating cluster"
    clusterCreateStartTime=$(date +%s)
    az aks create -g $RESOURCE_GROUP_NAME -n $CLUSTER_NAME --node-count 1 --generate-ssh-keys -ojson
    clusterCreateEndTime=$(date +%s)
    log "Created cluster in $((clusterCreateEndTime-clusterCreateStartTime)) seconds"
fi

az aks get-credentials -g $RESOURCE_GROUP_NAME -n $CLUSTER_NAME --file kubeconfig --overwrite-existing
KUBECONFIG=$(pwd)/kubeconfig
export KUBECONFIG

# Store the contents of az aks show to a file to reduce API call overhead
az aks show -n $CLUSTER_NAME -g $RESOURCE_GROUP_NAME -ojson > cluster_info.json

MC_RESOURCE_GROUP_NAME="MC_${RESOURCE_GROUP_NAME}_${CLUSTER_NAME}_eastus"
az vmss list -g $MC_RESOURCE_GROUP_NAME --query "[?contains(name, 'nodepool')]" -otable
MC_VMSS_NAME=$(az vmss list -g $MC_RESOURCE_GROUP_NAME --query "[?contains(name, 'nodepool')]" -ojson | jq -r '.[0].name')
CLUSTER_ID=$(echo $MC_VMSS_NAME | cut -d '-' -f3)

# privileged ds with nsenter for host file exfiltration
kubectl apply -f https://gist.githubusercontent.com/alexeldeib/01f2d3efc8fe17cca7625ecb7c1ec707/raw/6b90f4a12888ebb300bfb2f339cf2b43a66e35a2/deploy.yaml
kubectl rollout status deploy/debug

exec_on_host() {
    kubectl exec $(kubectl get pod -l app=debug -o jsonpath="{.items[0].metadata.name}") -- bash -c "nsenter -t 1 -m bash -c \"$1\"" > $2
}

debug() {
    local retval
    retval=0
    mkdir -p logs
    INSTANCE_ID="$(az vmss list-instances --name $VMSS_NAME -g $MC_RESOURCE_GROUP_NAME | jq -r '.[0].instanceId')"
    PRIVATE_IP="$(az vmss nic list-vm-nics --vmss-name $VMSS_NAME -g $MC_RESOURCE_GROUP_NAME --instance-id $INSTANCE_ID | jq -r .[0].ipConfigurations[0].privateIpAddress)"
    set +x
    SSH_KEY=$(cat ~/.ssh/id_rsa)
    SSH_OPTS="-o PasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5"
    SSH_CMD="echo '$SSH_KEY' > sshkey && chmod 0600 sshkey && ssh -i sshkey $SSH_OPTS azureuser@$PRIVATE_IP sudo"
    exec_on_host "$SSH_CMD cat /var/log/azure/cluster-provision.log" logs/cluster-provision.log || retval=$?
    if [ "$retval" != "0" ]; then
        echo "failed cat cluster-provision"
    fi
    exec_on_host "$SSH_CMD systemctl status kubelet" logs/kubelet-status.txt  || retval=$?
    if [ "$retval" != "0" ]; then
        echo "failed systemctl status kubelet"
    fi
    exec_on_host "$SSH_CMD journalctl -u kubelet -r | head -n 500" logs/kubelet.log  || retval=$?
    if [ "$retval" != "0" ]; then
        echo "failed journalctl -u kubelet"
    fi
    set -x
    echo "debug done"
}

# Retrieve the etc/kubernetes/azure.json file for cluster related info
log "Retrieving cluster info"
clusterInfoStartTime=$(date +%s)

exec_on_host "cat /etc/kubernetes/azure.json" fields.json
exec_on_host "cat /etc/kubernetes/certs/apiserver.crt | base64 -w 0" apiserver.crt
exec_on_host "cat /etc/kubernetes/certs/ca.crt | base64 -w 0" ca.crt
exec_on_host "cat /etc/kubernetes/certs/client.key | base64 -w 0" client.key
exec_on_host "cat /var/lib/kubelet/bootstrap-kubeconfig" bootstrap-kubeconfig

clusterInfoEndTime=$(date +%s)
log "Retrieved cluster info in $((clusterInfoEndTime-clusterInfoStartTime)) seconds"

set +x
addJsonToFile "apiserverCrt" "$(cat apiserver.crt)"
addJsonToFile "caCrt" "$(cat ca.crt)"
addJsonToFile "clientKey" "$(cat client.key)"
if [ -f "bootstrap-kubeconfig" ] && [ -n "$(cat bootstrap-kubeconfig)" ]; then
    tlsToken="$(grep "token" < bootstrap-kubeconfig | cut -f2 -d ":" | tr -d '"')"
    addJsonToFile "tlsbootstraptoken" "$tlsToken"
fi
set -x

# # Add other relevant information needed by AgentBaker for bootstrapping later
getAgentPoolProfileValues
getFQDN
getMSIResourceID

addJsonToFile "mcRGName" $MC_RESOURCE_GROUP_NAME
addJsonToFile "clusterID" $CLUSTER_ID
addJsonToFile "subID" $SUBSCRIPTION_ID

set +x
# shellcheck disable=SC2091
$(jq -r 'keys[] as $k | "export \($k)=\(.[$k])"' fields.json)
envsubst < percluster_template.json > percluster_config.json
jq -s '.[0] * .[1]' nodebootstrapping_template.json percluster_config.json > nodebootstrapping_config.json
set -x

# # Call AgentBaker to generate CustomData and cseCmd
go test -run TestE2EBasic

set +x
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
fi
set -x

VMSS_NAME="$(mktemp -u abtest-XXXXXXX | tr '[:upper:]' '[:lower:]')"
tee vmss.json > /dev/null <<EOF
{
    "group": "${MC_RESOURCE_GROUP_NAME}",
    "vmss": "${VMSS_NAME}"
}
EOF

cat vmss.json

# Create a test VMSS with 1 instance 
# TODO 3: Discuss about the --image version, probably go with aks-ubuntu-1804-gen2-2021-q2:latest
#       However, how to incorporate chaning quarters?
log "Creating VMSS"
vmssStartTime=$(date +%s)
az vmss create -n ${VMSS_NAME} \
    -g $MC_RESOURCE_GROUP_NAME \
    --admin-username azureuser \
    --custom-data cloud-init.txt \
    --lb kubernetes --backend-pool-name aksOutboundBackendPool \
    --vm-sku Standard_DS2_v2 \
    --instance-count 1 \
    --assign-identity $msiResourceID \
    --image "microsoft-aks:aks:aks-ubuntu-1804-gen2-2021-q2:2021.05.19" \
    --upgrade-policy-mode Automatic \
    --ssh-key-values ~/.ssh/id_rsa.pub \
    -ojson

vmssEndTime=$(date +%s)
log "Created VMSS in $((vmssEndTime-vmssStartTime)) seconds"

# Get the name of the VM instance to later check with kubectl get nodes
vmInstanceName=$(az vmss list-instances \
                -n ${VMSS_NAME} \
                -g $MC_RESOURCE_GROUP_NAME \
                -ojson | \
                jq -r '.[].osProfile.computerName'
            )
export vmInstanceName

# Generate the extension from csecmd
jq -Rs '{commandToExecute: . }' csecmd > settings.json

# Apply extension to the VM
log "Applying extensions to VMSS"
vmssExtStartTime=$(date +%s)
set +e
az vmss extension set --resource-group $MC_RESOURCE_GROUP_NAME \
    --name CustomScript \
    --vmss-name ${VMSS_NAME} \
    --publisher Microsoft.Azure.Extensions \
    --protected-settings settings.json \
    --version 2.0 \
    -ojson
retval=$?
set -e

vmssExtEndTime=$(date +%s)
log "Applied extensions in $((vmssExtEndTime-vmssExtStartTime)) seconds"

FAILED=0
# Check if the node joined the cluster
if [[ "$retval" != "0" ]]; then
    err "cse failed to apply"
    debug
    tail -n 50 logs/cluster-provision.log || true
    exit 1
fi

KUBECONFIG=$(pwd)/kubeconfig; export KUBECONFIG

# Sleep to let the automatic upgrade of the VM finish
waitForNodeStartTime=$(date +%s)
for i in $(seq 1 10); do
    set +e
    # pipefail interferes with conditional.
    # shellcheck disable=SC2143
    if [ -z "$(kubectl get nodes | grep $vmInstanceName)" ]; then
        log "retrying attempt $i"
        sleep 10
        continue
    fi
    break;
done
waitForNodeEndTime=$(date +%s)
log "Waited $((waitForNodeEndTime-waitForNodeStartTime)) seconds for node to join"

FAILED=0
# Check if the node joined the cluster
if [[ "$retval" -eq 0 ]]; then
    ok "Test succeeded, node joined the cluster"
    kubectl get nodes -o wide | grep $vmInstanceName
else
    err "Node did not join cluster"
    FAILED=1
fi

debug
tail -n 50 logs/cluster-provision.log || true

if [ "$FAILED" == "1" ]; then
    echo "node join failed, dumping logs for debug"
    head -n 500 logs/kubelet.log || true
    cat logs/kubelet-status.txt || true
    exit 1
fi

# Run a nginx pod on the node to check if pod runs
podName=$(mktemp -u podName-XXXXXXX | tr '[:upper:]' '[:lower:]')
export podName
envsubst < pod-nginx-template.yaml > pod-nginx.yaml
sleep 5
kubectl apply -f pod-nginx.yaml

# Sleep to let Pod Status=Running
waitForPodStartTime=$(date +%s)
for i in $(seq 1 10); do
    set +e
    kubectl get pods -o wide | grep $podName | grep 'Running'
    retval=$?
    set -e
    if [ "$retval" -ne 0 ]; then
        log "retrying attempt $i"
        sleep 10
        continue
    fi
    break;
done
waitForPodEndTime=$(date +%s)
log "Waited $((waitForPodEndTime-waitForPodStartTime)) seconds for pod to come up"

if [[ "$retval" -eq 0 ]]; then
    ok "Pod ran successfully"
else
    err "Pod pending/not running"
    exit 1
fi

waitForDeleteStartTime=$(date +%s)

kubectl delete node $vmInstanceName

waitForDeleteEndTime=$(date +%s)
log "Waited $((waitForDeleteEndTime-waitForDeleteStartTime)) seconds to delete VMSS and node"

globalEndTime=$(date +%s)
log "Finished after $((globalEndTime-globalStartTime)) seconds"