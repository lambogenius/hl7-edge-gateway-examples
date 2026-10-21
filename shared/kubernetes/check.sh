#!/usr/bin/env sh
# Checks a cloud deployment of samples 07-09 after its setup.sh, with the current kubectl context:
#   - the 3 NATS pods are in 3 zones;
#   - a stand-in lab API and a MEDITECH pod are started in the cluster (the lab API URL in .env must be
#     http://lab-api:8000/hl7/results for this check);
#   - K8S-1 goes through the hl7edge-mllp Service, K8S-2 to K8S-4 through the internal load balancer;
#   - a gateway pod and a NATS pod are deleted while messages flow, and K8S-1 to K8S-4 must arrive once each, in order.
# Run it from a sample folder:  ../shared/kubernetes/check.sh     (the test pods go away with ./teardown.sh)
set -eu
EX=$(cd "$(dirname "$0")/../.." && { pwd -W 2>/dev/null || pwd; })   # pwd -W: a C:/… path for kubectl.exe in Git Bash
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep /messages/… as it is (set KUBECONFIG as C:/…)
k() { kubectl -n hl7edge "$@"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
retry() { n=$1; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
send() { k exec meditech -- hl7-edge-gateway send --to "$1" "/messages/k8s-$2.hl7" 2>&1 | grep -q 'MSA|AA|'; }
received() {
  k exec deploy/lab-api -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/received').read().decode())" |
    grep -o 'K8S-[0-9]*' | tr '\n' ' '
}
at_least() { [ "$(received | wc -w)" -ge "$1" ]; }

step "Nodes and pods, by zone"
kubectl get nodes -L topology.kubernetes.io/zone --no-headers | awk '{print "  node " $1 "  zone " $NF}'
zone_of() { kubectl get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'; }
for p in $(k get pods -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName}{"\n"}{end}'); do
  echo "  pod ${p%%=*}  zone $(zone_of "${p#*=}")"
done
nats_zones=$(for n in $(k get pods -l app.kubernetes.io/name=nats -o jsonpath='{.items[*].spec.nodeName}'); do zone_of "$n"; echo; done | sort -u | grep -c .)
[ "$nats_zones" -eq 3 ] || fail "the 3 NATS pods should be in 3 zones, are in $nats_zones"
echo "NATS: 3 pods in 3 zones"

step "A stand-in lab API and MEDITECH, in the cluster"
IMAGE=$(k get deploy hl7-edge-gateway -o jsonpath='{.spec.template.spec.containers[0].image}')
k create configmap lab-api --from-file=app.py="$EX/01-meditech-to-rest-api/lab-api/app.py" --dry-run=client -o yaml | k apply -f - >/dev/null
k create configmap messages --from-file="$EX/shared/kubernetes/test/messages" --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: lab-api }
spec:
  selector: { matchLabels: { app: lab-api } }
  template:
    metadata: { labels: { app: lab-api } }
    spec:
      containers:
        - name: lab-api
          image: python:3.12-slim
          command: ["python", "-u", "/app/app.py"]
          env: [{ name: LAB_API_TOKEN, valueFrom: { secretKeyRef: { name: hl7edge-secrets, key: LAB_API_TOKEN } } }]
          volumeMounts: [{ name: app, mountPath: /app }]
      volumes: [{ name: app, configMap: { name: lab-api } }]
---
apiVersion: v1
kind: Service
metadata: { name: lab-api }
spec: { selector: { app: lab-api }, ports: [{ port: 8000 }] }
---
apiVersion: v1
kind: Pod
metadata: { name: meditech }
spec:
  containers:
    - name: meditech
      image: $IMAGE
      command: ["sleep", "infinity"]
      volumeMounts: [{ name: m, mountPath: /messages }]
  volumes: [{ name: m, configMap: { name: messages } }]
EOF
k rollout status deploy/lab-api --timeout=5m >/dev/null || fail "the lab API did not start"
k wait --for=condition=Ready pod/meditech --timeout=5m >/dev/null || fail "the meditech pod did not start"
LB=$(k get svc hl7edge-mllp -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
[ -n "$LB" ] || fail "the MLLP Service has no load balancer address"
echo "MLLP load balancer: $LB"

step "1. K8S-1 through the Service, K8S-2 through the internal load balancer"
retry 30 send hl7edge-mllp:7890 1 || fail "K8S-1 should be accepted through the Service"
retry 60 send "$LB:7890" 2 || fail "K8S-2 should be accepted through the load balancer at $LB"
retry 30 at_least 2 || fail "2 results should be delivered: $(received)"
echo "Received: $(received)"

step "2. A gateway pod is deleted, then a NATS pod"
pod=$(k get pods -l app=hl7-edge-gateway -o jsonpath='{.items[0].metadata.name}')
k delete pod "$pod" --wait=false >/dev/null; echo "deleted $pod"
retry 30 send "$LB:7890" 3 || fail "K8S-3 should be accepted by the remaining gateway pod"
k delete pod nats-1 --wait=false >/dev/null; echo "deleted nats-1"
sleep 3
retry 30 send "$LB:7890" 4 || fail "K8S-4 should be accepted with one NATS pod gone"
retry 60 at_least 4 || fail "4 results should be delivered: $(received)"
ids=$(received); echo "Received: $ids"
[ "$ids" = "K8S-1 K8S-2 K8S-3 K8S-4 " ] || fail "expected K8S-1 to K8S-4 once each, in order"
retry 60 k rollout status statefulset/nats --timeout=5s || fail "nats-1 did not come back"
retry 60 k rollout status deploy/hl7-edge-gateway --timeout=5s || fail "the gateway pod was not replaced"
k get pods -o wide | sed 's/^/  /'

step "Passed"
