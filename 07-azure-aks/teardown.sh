#!/usr/bin/env sh
# Deletes everything setup.sh created (the whole resource group).
set -eu
cd "$(dirname "$0")"
set -a; . ./.env; set +a
az group delete -n "$AZ_RESOURCE_GROUP" --yes --no-wait
echo "Deleting resource group $AZ_RESOURCE_GROUP (takes a few minutes)."
