#!/usr/bin/env sh
# Gets an access token for the gateway's API as the care application (OAuth2 client credentials),
# the way the real care application would. Prints only the token.
#   TOKEN=$(./get-token.sh)
set -eu
cd "$(dirname "$0")"
. ./.env
curl -s -X POST "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$CARE_APP_CLIENT_ID" \
  --data-urlencode "client_secret=$CARE_APP_CLIENT_SECRET" \
  --data-urlencode "scope=$GATEWAY_API_APP_ID/.default" |
  sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
