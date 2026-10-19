# Runs every step of sample 04 and checks the result. Needs .env and secrets/salesforce.key (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
function Ready { try { (Invoke-WebRequest http://localhost:8080/ready -UseBasicParsing).StatusCode -eq 200 } catch { $false } }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and fill it in' }
if (-not (Test-Path secrets/salesforce.key)) { Fail 'put the Salesforce private key in secrets/salesforce.key' }
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2] }

$response = Join-Path $PSScriptRoot '.response.ps1demo'
# --ssl-no-revoke: Windows curl cannot check revocation for a test CA that publishes no revocation list.
function Order {
    curl.exe -s --cacert certs/ca.crt --ssl-no-revoke -H 'Content-Type: x-application/hl7-v2+er7' @args `
        -o $response -w '%{http_code}' https://localhost:8443/hl7/orders
}
function Body { Get-Content -Raw $response }
function Route($name) {
    $overview = Invoke-RestMethod http://localhost:8080/api/overview -Headers @{ Authorization = "Bearer $($cfg.HL7EDGE_ADMIN_TOKEN)" }
    $overview.nodes[0].routes | Where-Object name -eq $name
}

try {
    Step 'Starting: test certificate, the gateway, and a stand-in MEDITECH'
    docker compose --progress quiet up -d
    foreach ($i in 1..30) { if (Ready) { break }; Start-Sleep 1 }
    if (-not (Ready)) { Fail 'the gateway is not ready; see: docker compose logs gateway' }

    Step '1. The care app gets an Entra ID access token (client credentials)'
    $token = (Invoke-RestMethod -Method Post "https://login.microsoftonline.com/$($cfg.ENTRA_TENANT_ID)/oauth2/v2.0/token" -Body @{
        grant_type = 'client_credentials'; client_id = $cfg.CARE_APP_CLIENT_ID; client_secret = $cfg.CARE_APP_CLIENT_SECRET
        scope = "$($cfg.GATEWAY_API_APP_ID)/.default" }).access_token
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/'); $payload += '=' * ((4 - $payload.Length % 4) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    Write-Host "  issuer:   $($claims.iss)`n  audience: $($claims.aud)`n  roles:    $($claims.roles -join ', ')"

    Step '2. ... and posts an order with it'
    if ((Order -H "Authorization: Bearer $token" --data-binary '@messages/orm-o01-1.hl7') -ne '200') { Body; Fail 'the order should be accepted' }
    Body
    docker compose logs meditech | Select-String 'CARE-8001'

    Step '3. Requests without a valid token are refused'
    $code = Order --data-binary '@messages/orm-o01-2.hl7'; Write-Host "no token:       HTTP $code $(Body)"
    if ($code -ne '401') { Fail 'expected 401' }
    $code = Order -H "Authorization: Bearer $($token.Substring(0, $token.Length - 5))AAAAA" --data-binary '@messages/orm-o01-2.hl7'
    Write-Host "tampered token: HTTP $code $(Body)"
    if ($code -ne '401') { Fail 'expected 401' }

    Step '4. MEDITECH sends lab results; the gateway posts them to Salesforce'
    docker compose --progress quiet run --rm -T send --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7
    foreach ($i in 1..30) { if ((Route results-to-salesforce).counters.delivered -ge 2) { break }; Start-Sleep 2 }
    $route = Route results-to-salesforce
    if ($route.counters.delivered -lt 2) {
        Write-Host "Not delivered yet. The gateway's last error: $($route.last_error)"
        Fail 'results did not reach Salesforce; see Troubleshooting in README.md (they stay queued and are retried)'
    }
    Write-Host "Delivered. In Salesforce, open Files: you will find 'HL7 SFR-7001' and 'HL7 SFR-7002'."

    Step 'Done. Clean up with: docker compose down -v'
} finally {
    Remove-Item -ErrorAction SilentlyContinue $response
}
