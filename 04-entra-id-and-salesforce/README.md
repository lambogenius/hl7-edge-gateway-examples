# 04 · Entra ID callers in, Salesforce out

Two common cloud integrations, with no shared passwords in either direction:

- **Inbound, Entra ID.** A care application in Azure sends orders to MEDITECH through the gateway's HTTPS
  endpoint. The gateway accepts only Entra ID access tokens that were issued for its API and carry the app
  role `Hl7.Send`.
- **Outbound, Salesforce.** MEDITECH's lab results go to an Apex REST service in Salesforce. The gateway
  signs in with the OAuth 2.0 JWT bearer flow: a connected app, a certificate, and an integration user.

```
care app ──(1) client credentials──▶ Entra ID
   │  ◀── access token (aud = gateway API, roles = [Hl7.Send]) ──
   │
   └─(2) POST /hl7/orders + Bearer token─▶ ┌──────────────────────┐ ──MLLP :6661──▶ MEDITECH
                                           │   HL7 Edge Gateway   │
MEDITECH ──MLLP :7890 (results)──────────▶ │   console :8080      │ ──(3) JWT bearer sign-in──▶ Salesforce
                                           └──────────────────────┘ ──(4) POST /services/apexrest/Hl7Inbound──▶
```

| Route | From → to | Security | Mode |
|---|---|---|---|
| `care-app-orders` | HTTPS `POST /hl7/orders` → MLLP | Entra ID JWT: signature checked against the tenant's published keys; issuer, audience, expiry, and the `Hl7.Send` role | pass-through: the care app gets MEDITECH's ACK |
| `results-to-salesforce` | MLLP → Salesforce Apex REST | OAuth 2.0 JWT bearer: the gateway signs an assertion with its private key; tokens are cached and renewed | store and forward |

Step-by-step guide with screenshots: <https://docs.lambogenius.com/hl7-edge-gateway/example-entra-id-and-salesforce>

## Files

| File | What it is |
|---|---|
| `gateway.toml` | The gateway configuration |
| `compose.yaml` | Creates a test certificate, then starts the gateway and a stand-in MEDITECH |
| `entra/setup.sh`, `entra/app-roles.json` | Creates the two Entra ID app registrations with the Azure CLI and writes their IDs to `.env` |
| `salesforce/Hl7Inbound.cls` | The Apex REST class that receives the results: it keeps each message as a file and answers with an HL7 ACK |
| `get-token.sh` | Gets an access token the way the care app does |
| `meditech/receiver.py` | Stand-in for MEDITECH's inbound orders interface |
| `messages/` | Two orders and two lab results |
| `.env.example` | Everything the sample needs; copy it to `.env` |
| `secrets/` | Put the Salesforce private key here; ignored by git |
| `demo.sh`, `demo.ps1` | Runs every step and checks the result |

## 1. Entra ID

You need an Entra ID tenant where you can create app registrations. A free tenant works.

**With the script** (Azure CLI):

```sh
az login --tenant <your-tenant-id> --allow-no-subscriptions
cp .env.example .env
./entra/setup.sh
```

**Or in the Azure portal** (Microsoft Entra ID → App registrations):

1. **New registration** `HL7 Edge Gateway API`. Note its **Application (client) ID**: this is
   `GATEWAY_API_APP_ID`. The **Directory (tenant) ID** is `ENTRA_TENANT_ID`.
2. In that app, open **App roles → Create app role**. Display name and value `Hl7.Send`, allowed member types
   **Applications**.
3. Open **Manifest** and set `"requestedAccessTokenVersion": 2` (in the `api` section). The gateway expects
   v2 tokens: the issuer is `https://login.microsoftonline.com/<tenant>/v2.0`, and the audience is the
   API's application ID.
4. **New registration** `HL7 Edge Gateway care app`. Its application ID is `CARE_APP_CLIENT_ID`. Under
   **Certificates & secrets**, add a client secret: `CARE_APP_CLIENT_SECRET`.
5. In the care app, open **API permissions → Add a permission → My APIs → HL7 Edge Gateway API →
   Application permissions → Hl7.Send**. Then click **Grant admin consent**.

Check it: `./get-token.sh` prints a token. Paste it into <https://jwt.ms> (it is decoded in your browser) to
see `aud` and `roles`.

## 2. Salesforce

You need a Salesforce org with API access. A free
[Developer Edition](https://developer.salesforce.com/signup) works.

1. **The Apex class.** Open **Developer Console → File → New → Apex Class** `Hl7Inbound`, paste
   `salesforce/Hl7Inbound.cls`, and save.
2. **A key and certificate for the gateway:**
   ```sh
   openssl req -x509 -newkey rsa:2048 -nodes -days 730 -subj "/CN=hl7-edge-gateway" \
     -keyout secrets/salesforce.key -out secrets/salesforce.crt
   ```
3. **A connected app.** Go to **Setup → External Client App Manager → New External Client App**:
   - **Enable OAuth**, with callback URL `http://localhost:1717/OauthRedirect` (not used, but required).
   - OAuth scopes **Manage user data via APIs (api)** and **Perform requests at any time
     (refresh_token, offline_access)**.
   - **Enable JWT Bearer Flow**, and upload `secrets/salesforce.crt`.
   - Save. Under **Settings → OAuth Settings → Consumer Key and Secret**, copy the consumer key into
     `SF_CLIENT_ID`.
4. **Who may use it.** On the app's **Policies** tab, choose **Edit**:
   - set **Permitted Users** to **Admin approved users are pre-authorized**;
   - under **Select Profiles**, add the integration user's profile (or use a permission set);
   - save.

   Without this step the sign-in fails (see [Troubleshooting](#troubleshooting)).
5. In `.env`, set `SF_USERNAME` to that user and `SF_LOGIN_URL` to `https://login.salesforce.com`. Use
   `https://test.salesforce.com` for a sandbox, or your My Domain URL.

## 3. Run it

```sh
docker compose up -d
./demo.sh            # or ./demo.ps1 on Windows
```

The demo:
1. gets a token as the care app;
2. posts an order (`200`, `MSA|AA|CARE-8001|filed` from MEDITECH);
3. shows that a request without a token, or with a tampered one, gets `401`;
4. sends two lab results to Salesforce.

A token without the `Hl7.Send` role gets `403` with `client <id> lacks role Hl7.Send`.

In Salesforce, **Files** now holds `HL7 SFR-7001` and `HL7 SFR-7002`, and the console shows
`results-to-salesforce` with 2 delivered.

**Clean up:** `docker compose down -v`. In Entra ID, delete the two app registrations. In Salesforce, delete
the files, the class and the app.

## Troubleshooting

A failed sign-in to Salesforce never loses results. They stay queued, and the route shows **retrying**
with Salesforce's answer as the last error. Fix the cause, then click **Retry now**.

| Last error | Cause |
|---|---|
| `app_not_found External client app is not installed in this org` | The consumer key is wrong, or the app is not enabled for this org. With `login.salesforce.com`, a new app can take a few minutes to become available. |
| `invalid_grant user hasn't approved this consumer` | The user is not pre-authorized: step 2.4 (Policies → Permitted Users, plus the user's profile or permission set). |
| `invalid_grant invalid assertion` | The certificate in the app does not match `secrets/salesforce.key`, or `SF_LOGIN_URL` is the wrong one for the org. |
| `invalid_client invalid client credentials` | `SF_CLIENT_ID` is not the consumer key of the app that has your certificate. |
| `HTTP 404` | The Apex class `Hl7Inbound` is not saved in the org. |

On the Entra ID side:
- `401 invalid token: …` names what failed (signature, issuer, audience, or expiry).
- `403 … lacks role Hl7.Send` means the role was not granted, or admin consent is missing.

## Calling an API that is protected by Entra ID

The same building blocks work outbound. To post to an API that expects Entra ID tokens, give the
destination `auth = oauth2`. The gateway then gets, caches, and renews the token itself:

```toml
[route.destination]
type = "http"
url = "https://api.contoso.com/hl7"

[route.destination.auth]
type = "oauth2"
token_url = "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token"
client_id = "${GATEWAY_CLIENT_ID}"
client_secret = "${GATEWAY_CLIENT_SECRET}"     # or private_key = "…" for a certificate (private_key_jwt)
scope = "api://contoso-hl7-api/.default"
```
