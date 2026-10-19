# Runs every step of sample 01 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Send-Hl7 { docker compose --progress quiet run --rm -T send @args }
function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
function Received { $r = Invoke-RestMethod http://localhost:8000/received; $r.Count }
function Ready { try { (Invoke-WebRequest http://localhost:8080/ready -UseBasicParsing).StatusCode -eq 200 } catch { $false } }

if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
Step 'Starting the gateway and the stand-in lab API'
docker compose --progress quiet up -d
foreach ($i in 1..30) { if (Ready) { break }; Start-Sleep 1 }
if (-not (Ready)) { Fail 'the gateway is not ready; see: docker compose logs gateway' }

Step '1. Three lab results (store and forward) and an admission (pass-through)'
Send-Hl7 --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7 /messages/oru-r01-3.hl7
Send-Hl7 --to gateway:7891 /messages/adt-a01.hl7
foreach ($i in 1..10) { if ((Received) -ge 4) { break }; Start-Sleep 1 }
if ((Received) -lt 4) { Fail 'the lab API should have 4 messages' }
Write-Host "The lab API has received $(Received) messages."

Step '2. The lab API goes down'
Invoke-RestMethod -Method Post http://localhost:8000/control/down
$out = Send-Hl7 --to gateway:7890 /messages/oru-r01-4.hl7 /messages/oru-r01-5.hl7
$out
if (-not ($out -match 'MSA\|AA\|LAB-1005')) { Fail 'results should still be acknowledged (AA) while the API is down' }
Write-Host 'Results are acknowledged and queued. Now an admission (pass-through) while the API is down:'
$out = Send-Hl7 --to gateway:7891 /messages/adt-a08.hl7
$out
if (-not ($out -match 'MSA\|AE\|ADT-2002')) { Fail 'a pass-through admission should get AE while the API is down' }
Write-Host 'Open http://localhost:8080: lab-results is retrying with 2 queued. Waiting 10 s...'
Start-Sleep 10

Step '3. The lab API comes back'
Invoke-RestMethod -Method Post http://localhost:8000/control/up
foreach ($i in 1..45) { if ((Received) -ge 6) { break }; Start-Sleep 1 }
if ((Received) -lt 6) { Fail 'the queued results were not delivered' }
Write-Host "Queued results delivered after ${i}s, in order:"
$r = Invoke-RestMethod http://localhost:8000/received; $r[-2, -1].control_id

Step '4. A result without a patient ID'
Send-Hl7 --to gateway:7890 /messages/oru-r01-no-patient-id.hl7
Start-Sleep 3
docker compose logs lab-api | Select-String LAB-1099
Write-Host 'LAB-1099 is in dead letters: open lab-results -> Dead letters in the console.'

Step 'Done. Clean up with: docker compose down -v'
