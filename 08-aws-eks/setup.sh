#!/usr/bin/env sh
# Sample 08: HL7 Edge Gateway with NATS JetStream on EKS, across three availability zones.
# Needs the AWS CLI (signed in), eksctl, kubectl, helm and Docker. Creates billable resources;
# ./teardown.sh deletes them.
set -eu
cd "$(dirname "$0")"
[ -f .env ] || { echo "copy .env.example to .env and fill it in"; exit 1; }
set -a; . ./.env; set +a
step() { printf '\n== %s\n' "$*"; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/hl7-edge-gateway"

step "EKS cluster (about 20 minutes)"
eksctl create cluster -f cluster.yaml
aws eks update-kubeconfig --region "$AWS_REGION" --name hl7edge

step "AWS Load Balancer Controller"
VPC=$(aws eks describe-cluster --region "$AWS_REGION" --name hl7edge --query cluster.resourcesVpcConfig.vpcId --output text)
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=hl7edge --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" --set vpcId="$VPC" --wait

step "The gateway image, into ECR"
aws ecr describe-repositories --region "$AWS_REGION" --repository-names hl7-edge-gateway >/dev/null 2>&1 ||
  aws ecr create-repository --region "$AWS_REGION" --repository-name hl7-edge-gateway \
    --image-scanning-configuration scanOnPush=true >/dev/null
docker load -i "$GATEWAY_IMAGE_ARCHIVE"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${REPO%%/*}"
docker tag "lambogenius/hl7-edge-gateway:$GATEWAY_VERSION" "$REPO:$GATEWAY_VERSION"
docker push "$REPO:$GATEWAY_VERSION"
sed -i.bak "s|newName: .*amazonaws.com/hl7-edge-gateway.*|newName: $REPO|; s|newTag: .*|newTag: \"$GATEWAY_VERSION\"|" kustomization.yaml
rm -f kustomization.yaml.bak

step "Storage, namespace and secrets"
kubectl apply -f storageclass-gp3.yaml
kubectl create namespace hl7edge --dry-run=client -o yaml | kubectl apply -f -
kubectl -n hl7edge create secret generic hl7edge-secrets --dry-run=client -o yaml \
  --from-literal=LAMBOGENIUS_LICENSE="$LAMBOGENIUS_LICENSE" --from-literal=HL7EDGE_ADMIN_TOKEN="$HL7EDGE_ADMIN_TOKEN" \
  --from-literal=NATS_TOKEN="$NATS_TOKEN" --from-literal=LAB_API_URL="$LAB_API_URL" --from-literal=LAB_API_TOKEN="$LAB_API_TOKEN" |
  kubectl apply -f -

step "NATS JetStream (3 pods, one per zone, encrypted gp3)"
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
helm repo update nats >/dev/null
helm upgrade --install nats nats/nats --version 2.15.1 -n hl7edge \
  -f ../shared/kubernetes/nats-values.yaml -f nats-aws.yaml --wait --timeout 10m

step "The gateway (2 pods) and its internal NLB"
kubectl apply -k .
kubectl -n hl7edge rollout status deploy/hl7-edge-gateway --timeout=5m
echo "Waiting for the NLB's address..."
for i in $(seq 1 60); do
  host=$(kubectl -n hl7edge get svc hl7edge-mllp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [ -n "$host" ] && break
  sleep 10
done
kubectl -n hl7edge get pods -o wide
echo
echo "MEDITECH connects to ${host:-<pending>}:7890 (an internal NLB: reach it over Direct Connect or a VPN)."
echo "Admin console: kubectl -n hl7edge port-forward svc/hl7edge-admin 8080, then http://localhost:8080"
