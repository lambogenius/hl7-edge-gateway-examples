# Runs every step of sample 02 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
function Ready { try { (Invoke-WebRequest http://localhost:8080/ready -UseBasicParsing).StatusCode -eq 200 } catch { $false } }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2] }

$response = Join-Path $PSScriptRoot '.response.ps1demo'
# --ssl-no-revoke: Windows curl cannot check revocation for a test CA that publishes no revocation list.
function Rest($key, $file) {
    curl.exe -s --cacert certs/ca.crt --ssl-no-revoke -H "X-API-Key: $key" -H 'Content-Type: x-application/hl7-v2+er7' `
        --data-binary "@$file" -o $response -w '%{http_code}' https://localhost:8443/hl7/results
}
function Soap($file) {
    curl.exe -s --cacert certs/ca.crt --ssl-no-revoke -u "lakeside-clinic:$($envFile.CLINIC_SOAP_PASSWORD)" `
        -H 'Content-Type: text/xml; charset=utf-8' -H 'SOAPAction: "urn:lakeside-clinic:hl7/SubmitHL7"' `
        --data-binary "@$file" -o $response -w '%{http_code}' https://localhost:8443/Hl7Service
}
function Body { Get-Content -Raw $response }
function Filed($pattern) { @(docker compose logs meditech | Select-String $pattern).Count }

try {
    Step 'Starting: test certificates, the gateway, and a stand-in MEDITECH'
    docker compose --progress quiet up -d
    foreach ($i in 1..30) { if (Ready) { break }; Start-Sleep 1 }
    if (-not (Ready)) { Fail 'the gateway is not ready; see: docker compose logs gateway' }

    Step '1. Two reference labs post results over HTTPS, each with its own API key'
    if ((Rest $envFile.NORTHSIDE_LAB_API_KEY messages/oru-r01-ref-1.hl7) -ne '200') { Fail "Northside's result should be accepted" }; Body
    if ((Rest $envFile.VALLEY_PATHOLOGY_API_KEY messages/oru-r01-ref-2.hl7) -ne '200') { Fail "Valley's result should be accepted" }; Body
    Write-Host 'A wrong key is refused:'
    if ((Rest 'wrong-key' messages/oru-r01-ref-2.hl7) -ne '401') { Fail 'a wrong API key should get 401' }; Body
    foreach ($i in 1..10) { if ((Filed 'AA REF-300[12]') -ge 2) { break }; Start-Sleep 1 }
    if ((Filed 'AA REF-300[12]') -ne 2) { Fail 'MEDITECH should have filed REF-3001 and REF-3002' }
    docker compose logs meditech | Select-String 'REF-300'

    Step "2. The clinic registers patients over SOAP (pass-through: MEDITECH's ACK comes back)"
    if ((Soap messages/soap-adt-a04.xml) -ne '200') { Fail 'the SOAP call should succeed' }
    if ((Body) -notmatch 'MSA\|AA\|CLN-4001\|filed') { Fail "the SOAP response should carry MEDITECH's AA" }; $Matches[0]
    if ((Soap messages/soap-adt-a04-unknown-patient.xml) -ne '200') { Fail 'the SOAP call should succeed' }
    if ((Body) -notmatch 'MSA\|AR\|CLN-4099\|[^&]*') { Fail "the SOAP response should carry MEDITECH's AR" }; $Matches[0]

    Step '3. MEDITECH goes down'
    docker compose --progress quiet stop meditech
    if ((Rest $envFile.NORTHSIDE_LAB_API_KEY messages/oru-r01-ref-3.hl7) -ne '200') { Fail 'results should still be accepted (stored)' }
    if ((Rest $envFile.NORTHSIDE_LAB_API_KEY messages/oru-r01-ref-4.hl7) -ne '200') { Fail 'results should still be accepted (stored)' }
    Write-Host 'Results REF-3003 and REF-3004 are stored and acknowledged. A SOAP registration cannot be:'
    if ((Soap messages/soap-adt-a04.xml) -ne '200') { Fail 'the SOAP call should still get a response' }
    if ((Body) -notmatch 'MSA\|AE\|CLN-4001\|[^&]*') { Fail 'pass-through SOAP should get AE while MEDITECH is down' }; $Matches[0]
    Write-Host 'Open http://localhost:8080: reference-lab-results is retrying with 2 queued. Waiting 10 s...'
    Start-Sleep 10

    Step '4. MEDITECH comes back'
    docker compose --progress quiet start meditech
    foreach ($i in 1..45) { if ((Filed 'AA REF-300[34]') -ge 2) { break }; Start-Sleep 1 }
    if ((Filed 'AA REF-300[34]') -ne 2) { Fail 'the queued results were not delivered' }
    Write-Host "Delivered after ${i}s, in order:"
    docker compose logs meditech | Select-String 'REF-300[34]'

    Step '5. A result for a patient MEDITECH does not know'
    if ((Rest $envFile.NORTHSIDE_LAB_API_KEY messages/oru-r01-ref-unknown-patient.hl7) -ne '200') { Fail 'the result should be stored' }
    Start-Sleep 3
    docker compose logs meditech | Select-String 'REF-3099'
    Write-Host 'MEDITECH answered AR, so REF-3099 is in dead letters: open reference-lab-results -> Dead letters.'

    Step 'Done. Clean up with: docker compose down -v'
} finally {
    Remove-Item -ErrorAction SilentlyContinue $response
}
