#!/usr/bin/env sh
# Tests the shared Kubernetes base on a throwaway single-node k3s cluster in Docker: the NATS chart with
# nats-values.yaml, the gateway with `kubectl apply -k`, a stand-in lab API, and a failover test
# (a gateway pod and a NATS pod deleted while messages flow).
#   LAMBOGENIUS_LICENSE=... ./run.sh            needs Docker and the gateway image loaded locally
set -eu
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
K3S=hl7edge-examples-k3s
KUBE=hl7edge-examples-kube
VERSION=${GATEWAY_VERSION:-0.3.0}
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
k() { docker exec -i "$K3S" kubectl "$@"; }
retry() { n=$1; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
# send <n>: MEDITECH (a pod in the cluster) sends messages/k8s-<n>.hl7 to the MLLP Service
send() { k -n hl7edge exec meditech -- hl7-edge-gateway send --to hl7edge-mllp:7890 "/messages/k8s-$1.hl7"; }
received() {
  k -n hl7edge exec deploy/lab-api -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/received').read().decode())" |
    grep -o 'K8S-[0-9]*' | tr '\n' ' '
}
at_least() { [ "$(received | wc -w)" -ge "$1" ]; }
cleanup() { docker rm -f "$K3S" >/dev/null 2>&1 || true; docker volume rm "$KUBE" >/dev/null 2>&1 || true; }
[ -n "${LAMBOGENIUS_LICENSE:-}" ] || fail "set LAMBOGENIUS_LICENSE"
cleanup; trap cleanup EXIT

step "Starting k3s"
docker run -d --name "$K3S" --privileged --tmpfs /run --tmpfs /var/run rancher/k3s:v1.31.4-k3s1 server --disable traefik >/dev/null
retry 60 sh -c "docker exec $K3S kubectl get nodes | grep -q ' Ready'" || fail "k3s did not start"
docker exec "$K3S" cat /etc/rancher/k3s/k3s.yaml | docker run --rm -i -v "$KUBE:/k" alpine:3.20 sh -c 'cat > /k/config'
docker save "lambogenius/hl7-edge-gateway:$VERSION" | docker exec -i "$K3S" ctr -n k8s.io images import - >/dev/null
docker cp .. "$K3S:/base"
docker cp ../../../01-meditech-to-rest-api/lab-api/app.py "$K3S:/app.py"

step "Secrets, NATS (chart 2.15.1), the gateway (kubectl apply -k), a stand-in lab API and MEDITECH"
k create namespace hl7edge >/dev/null
k -n hl7edge create secret generic hl7edge-secrets --from-literal=LAMBOGENIUS_LICENSE="$LAMBOGENIUS_LICENSE" \
  --from-literal=HL7EDGE_ADMIN_TOKEN=test-admin-token --from-literal=NATS_TOKEN=test-nats-token \
  --from-literal=LAB_API_URL=http://lab-api:8000/hl7/results --from-literal=LAB_API_TOKEN=sample-lab-api-token >/dev/null
docker run --rm --network "container:$K3S" -v "$KUBE:/root/.kube" -v "$(pwd)/..:/base:ro" --entrypoint sh alpine/helm:3.16.2 -c \
  'helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null && helm install nats nats/nats --version 2.15.1 -n hl7edge -f /base/nats-values.yaml >/dev/null'
k -n hl7edge create configmap lab-api --from-file=/app.py >/dev/null
k -n hl7edge create deployment lab-api --image=python:3.12-slim --port=8000 -- python -u /app/app.py >/dev/null
k -n hl7edge set env deploy/lab-api --from=secret/hl7edge-secrets --keys=LAB_API_TOKEN >/dev/null
k -n hl7edge patch deploy lab-api --type=json -p '[{"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"app","configMap":{"name":"lab-api"}}]},{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"app","mountPath":"/app"}]}]' >/dev/null
k -n hl7edge expose deploy lab-api --port=8000 >/dev/null
k apply -k /base >/dev/null
k -n hl7edge set image deploy/hl7-edge-gateway "gateway=lambogenius/hl7-edge-gateway:$VERSION" >/dev/null
k -n hl7edge patch deploy hl7-edge-gateway -p '{"spec":{"template":{"spec":{"containers":[{"name":"gateway","imagePullPolicy":"Never"}]}}}}' >/dev/null
k -n hl7edge create configmap messages --from-file=/base/test/messages >/dev/null
k -n hl7edge run meditech --image="lambogenius/hl7-edge-gateway:$VERSION" \
  --overrides='{"spec":{"containers":[{"name":"meditech","image":"lambogenius/hl7-edge-gateway:'"$VERSION"'","imagePullPolicy":"Never","command":["sleep","infinity"],"volumeMounts":[{"name":"m","mountPath":"/messages"}]}],"volumes":[{"name":"m","configMap":{"name":"messages"}}]}}' >/dev/null
retry 120 k -n hl7edge rollout status statefulset/nats --timeout=5s || fail "NATS did not start: kubectl -n hl7edge get pods"
retry 120 k -n hl7edge rollout status deploy/hl7-edge-gateway --timeout=5s || { k -n hl7edge logs deploy/hl7-edge-gateway | tail -5; fail "the gateway did not become ready"; }
retry 60 k -n hl7edge rollout status deploy/lab-api --timeout=5s || fail "the lab API did not start"
retry 60 k -n hl7edge wait --for=condition=Ready pod/meditech --timeout=5s || fail "the meditech pod did not start"
k -n hl7edge get pods | sed 's/^/  /'

step "1. Two results through the hl7edge-mllp Service"
send 1; send 2
retry 15 at_least 2 || fail "2 results should be delivered"
echo "Received: $(received)"

step "2. A gateway pod is deleted, then a NATS pod"
pod=$(k -n hl7edge get pods -l app=hl7-edge-gateway -o jsonpath='{.items[0].metadata.name}')
k -n hl7edge delete pod "$pod" --wait=false >/dev/null; echo "deleted $pod"
retry 15 send 3 || fail "K8S-3 should be accepted by the remaining gateway pod"
k -n hl7edge delete pod nats-1 --wait=false >/dev/null; echo "deleted nats-1"
sleep 3
retry 15 send 4 || fail "K8S-4 should be accepted with one NATS pod gone"
retry 60 at_least 4 || fail "4 results should be delivered"
ids=$(received); echo "Received: $ids"
[ "$ids" = "K8S-1 K8S-2 K8S-3 K8S-4 " ] || fail "expected K8S-1 to K8S-4 once each, in order"

step "Passed"
