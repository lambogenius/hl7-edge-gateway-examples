#!/usr/bin/env sh
# Sample 09: HL7 Edge Gateway with NATS JetStream on GKE, a regional cluster across three zones.
# Needs the Google Cloud CLI (gcloud auth login), kubectl, helm and Docker. Creates billable resources;
# ./teardown.sh deletes them.
set -eu
cd "$(dirname "$0")"
[ -f .env ] || { echo "copy .env.example to .env and fill it in"; exit 1; }
set -a; . ./.env; set +a
step() { printf '\n== %s\n' "$*"; }
REPO="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/hl7edge/hl7-edge-gateway"
gcloud config set project "$GCP_PROJECT" >/dev/null

step "APIs, registry and a regional GKE cluster (one node in each of three zones)"
gcloud services enable container.googleapis.com artifactregistry.googleapis.com
gcloud artifacts repositories describe hl7edge --location "$GCP_REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create hl7edge --location "$GCP_REGION" --repository-format docker
gcloud container clusters create hl7edge --region "$GCP_REGION" --num-nodes 1 \
  --machine-type e2-standard-2 --release-channel regular --enable-ip-alias \
  --workload-pool "$GCP_PROJECT.svc.id.goog" --enable-shielded-nodes
gcloud container clusters get-credentials hl7edge --region "$GCP_REGION"

step "The gateway image, into Artifact Registry"
docker load -i "$GATEWAY_IMAGE_ARCHIVE"
gcloud auth configure-docker "$GCP_REGION-docker.pkg.dev" --quiet
docker tag "lambogenius/hl7-edge-gateway:$GATEWAY_VERSION" "$REPO:$GATEWAY_VERSION"
docker push "$REPO:$GATEWAY_VERSION"
sed -i.bak "s|newName: .*docker.pkg.dev/.*hl7-edge-gateway.*|newName: $REPO|; s|newTag: .*|newTag: \"$GATEWAY_VERSION\"|" kustomization.yaml
rm -f kustomization.yaml.bak

step "Namespace and secrets"
kubectl create namespace hl7edge --dry-run=client -o yaml | kubectl apply -f -
kubectl -n hl7edge create secret generic hl7edge-secrets --dry-run=client -o yaml \
  --from-literal=LAMBOGENIUS_LICENSE="$LAMBOGENIUS_LICENSE" --from-literal=HL7EDGE_ADMIN_TOKEN="$HL7EDGE_ADMIN_TOKEN" \
  --from-literal=NATS_TOKEN="$NATS_TOKEN" --from-literal=LAB_API_URL="$LAB_API_URL" --from-literal=LAB_API_TOKEN="$LAB_API_TOKEN" |
  kubectl apply -f -

step "NATS JetStream (3 pods, one per zone, SSD persistent disks)"
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
helm repo update nats >/dev/null
helm upgrade --install nats nats/nats --version 2.15.1 -n hl7edge \
  -f ../shared/kubernetes/nats-values.yaml -f nats-gcp.yaml --wait --timeout 10m

step "The gateway (2 pods) and its internal load balancer"
kubectl apply -k .
kubectl -n hl7edge rollout status deploy/hl7-edge-gateway --timeout=5m
echo "Waiting for the internal load balancer's address..."
for i in $(seq 1 60); do
  ip=$(kubectl -n hl7edge get svc hl7edge-mllp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$ip" ] && break
  sleep 5
done
kubectl -n hl7edge get pods -o wide
echo
echo "MEDITECH connects to ${ip:-<pending>}:7890 (a private address in the VPC: reach it over Interconnect or a VPN)."
echo "Admin console: kubectl -n hl7edge port-forward svc/hl7edge-admin 8080, then http://localhost:8080"
