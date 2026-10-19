#!/usr/bin/env sh
# Deletes what setup.sh created. The load balancer goes with the Service, so the namespace is deleted first.
set -eu
cd "$(dirname "$0")"
set -a; . ./.env; set +a
kubectl delete namespace hl7edge --wait=true || true
gcloud container clusters delete hl7edge --region "$GCP_REGION" --quiet
gcloud artifacts repositories delete hl7edge --location "$GCP_REGION" --quiet
echo "Deleted."
