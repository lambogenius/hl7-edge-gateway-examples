#!/usr/bin/env sh
# Sample 07: HL7 Edge Gateway with NATS JetStream on AKS, across three availability zones.
# Needs the Azure CLI (az login), kubectl, helm and Docker. Creates billable resources; ./teardown.sh
# deletes them.
set -eu
cd "$(dirname "$0")"
[ -f .env ] || { echo "copy .env.example to .env and fill it in"; exit 1; }
set -a; . ./.env; set +a
step() { printf '\n== %s\n' "$*"; }

step "Resource group, container registry and AKS cluster (3 nodes, one per zone)"
az group create -n "$AZ_RESOURCE_GROUP" -l "$AZ_LOCATION" -o none
az acr create -g "$AZ_RESOURCE_GROUP" -n "$AZ_ACR_NAME" --sku Standard -o none
az aks create -g "$AZ_RESOURCE_GROUP" -n "$AZ_AKS_NAME" \
  --node-count 3 --zones 1 2 3 --node-vm-size Standard_D2s_v5 \
  --network-plugin azure --enable-managed-identity --attach-acr "$AZ_ACR_NAME" \
  --generate-ssh-keys -o none
az aks get-credentials -g "$AZ_RESOURCE_GROUP" -n "$AZ_AKS_NAME" --overwrite-existing

step "The gateway image, into the registry"
docker load -i "$GATEWAY_IMAGE_ARCHIVE"
az acr login -n "$AZ_ACR_NAME"
docker tag "lambogenius/hl7-edge-gateway:$GATEWAY_VERSION" "$AZ_ACR_NAME.azurecr.io/hl7-edge-gateway:$GATEWAY_VERSION"
docker push "$AZ_ACR_NAME.azurecr.io/hl7-edge-gateway:$GATEWAY_VERSION"
sed -i.bak "s|newName: .*azurecr.io/hl7-edge-gateway.*|newName: $AZ_ACR_NAME.azurecr.io/hl7-edge-gateway|; s|newTag: .*|newTag: \"$GATEWAY_VERSION\"|" kustomization.yaml && rm -f kustomization.yaml.bak

step "Namespace and secrets"
kubectl create namespace hl7edge --dry-run=client -o yaml | kubectl apply -f -
kubectl -n hl7edge create secret generic hl7edge-secrets --dry-run=client -o yaml \
  --from-literal=LAMBOGENIUS_LICENSE="$LAMBOGENIUS_LICENSE" --from-literal=HL7EDGE_ADMIN_TOKEN="$HL7EDGE_ADMIN_TOKEN" \
  --from-literal=NATS_TOKEN="$NATS_TOKEN" --from-literal=LAB_API_URL="$LAB_API_URL" --from-literal=LAB_API_TOKEN="$LAB_API_TOKEN" |
  kubectl apply -f -

step "NATS JetStream (3 pods, one per zone, Premium SSD)"
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
helm repo update nats >/dev/null
helm upgrade --install nats nats/nats --version 2.15.1 -n hl7edge \
  -f ../shared/kubernetes/nats-values.yaml -f nats-azure.yaml --wait --timeout 10m

step "The gateway (2 pods) and its internal load balancer"
kubectl apply -k .
kubectl -n hl7edge rollout status deploy/hl7-edge-gateway --timeout=5m
echo "Waiting for the internal load balancer's address..."
for i in $(seq 1 60); do
  ip=$(kubectl -n hl7edge get svc hl7edge-mllp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$ip" ] && break; sleep 5
done
kubectl -n hl7edge get pods -o wide
echo
echo "MEDITECH connects to ${ip:-<pending>}:7890 (a private address in the AKS virtual network)."
echo "Admin console: kubectl -n hl7edge port-forward svc/hl7edge-admin 8080, then http://localhost:8080"
