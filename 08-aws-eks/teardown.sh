#!/usr/bin/env sh
# Deletes what setup.sh created. The NLB goes with the Service, so the namespace is deleted first.
set -eu
cd "$(dirname "$0")"
set -a; . ./.env; set +a
kubectl delete namespace hl7edge --wait=true || true
eksctl delete cluster -f cluster.yaml --wait
aws ecr delete-repository --region "$AWS_REGION" --repository-name hl7-edge-gateway --force >/dev/null
echo "Deleted. The gp3 volumes have reclaimPolicy Retain: delete any that are left in the EC2 console"
echo "(Volumes with the tag kubernetes.io/created-for/pvc/namespace = hl7edge)."
