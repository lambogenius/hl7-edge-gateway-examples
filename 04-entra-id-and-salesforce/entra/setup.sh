#!/usr/bin/env sh
# Creates the two Entra ID app registrations sample 04 needs, with the Azure CLI (az login first):
#   "<prefix> API"       the gateway's API: app role Hl7.Send, v2 access tokens
#   "<prefix> care app"  a caller: a client secret, and the Hl7.Send role
# and fills in ENTRA_TENANT_ID, GATEWAY_API_APP_ID, CARE_APP_CLIENT_ID and CARE_APP_CLIENT_SECRET in ../.env.
#   ./setup.sh ["HL7 Edge Gateway"]
set -eu
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep the Graph URLs as they are
PREFIX=${1:-HL7 Edge Gateway}
[ -f ../.env ] || cp ../.env.example ../.env

TENANT=$(az account show --query tenantId -o tsv)
echo "Tenant: $TENANT"

API=$(az ad app create --display-name "$PREFIX API" --app-roles @app-roles.json --query appId -o tsv)
# v2 tokens: issuer https://login.microsoftonline.com/<tenant>/v2.0, audience = the API's app ID.
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications(appId='$API')" \
  --headers Content-Type=application/json --body '{"api":{"requestedAccessTokenVersion":2}}'
API_SP=$(az ad sp create --id "$API" --query id -o tsv)
ROLE=$(az ad app show --id "$API" --query "appRoles[?value=='Hl7.Send'].id" -o tsv)
echo "API app:  $API (app role Hl7.Send)"

CARE=$(az ad app create --display-name "$PREFIX care app" --query appId -o tsv)
CARE_SP=$(az ad sp create --id "$CARE" --query id -o tsv)
SECRET=$(az ad app credential reset --id "$CARE" --display-name "hl7-edge-gateway sample" --years 1 --query password -o tsv 2>/dev/null)
az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$API_SP/appRoleAssignedTo" \
  --headers Content-Type=application/json \
  --body "{\"principalId\":\"$CARE_SP\",\"resourceId\":\"$API_SP\",\"appRoleId\":\"$ROLE\"}" -o none
echo "Care app: $CARE (has Hl7.Send; client secret valid for 1 year)"

set_env() { sed -i.bak "s|^$1=.*|$1=$2|" ../.env && rm -f ../.env.bak; }
set_env ENTRA_TENANT_ID "$TENANT"
set_env GATEWAY_API_APP_ID "$API"
set_env CARE_APP_CLIENT_ID "$CARE"
set_env CARE_APP_CLIENT_SECRET "$SECRET"
echo "Wrote ENTRA_TENANT_ID, GATEWAY_API_APP_ID, CARE_APP_CLIENT_ID and CARE_APP_CLIENT_SECRET to .env."
echo "A new role assignment can take a minute to show up in tokens."
