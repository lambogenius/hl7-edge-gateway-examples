# Runs every step of sample 11 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2] }
$headers = @{ Authorization = "Bearer $($envFile['HL7EDGE_ADMIN_TOKEN'])" }

function Send-Hl7 { docker compose --progress quiet run --rm -T send --to gateway:7890 @args }
function Lab { ((Invoke-RestMethod http://localhost:8000/received) | ForEach-Object { $_.control_id }) -join ' ' }
function His { ((docker compose logs his | Select-String -AllMatches '[A-Z]{2} ADT-9\d+' | ForEach-Object { $_.Matches.Value }) -join ' ') }
function Archive {
  $text = (docker compose exec -T sftp sh -c 'cat /home/hospital/inbox/*.hl7 2>/dev/null') -join "`n"
  (($text -replace "`r", "`n") -split "`n" | Where-Object { $_ -like 'MSH*' } | ForEach-Object { ($_ -split '\|')[9] }) -join ' '
}
function Closed-Files { @(docker compose exec -T sftp sh -c 'ls /home/hospital/inbox' | Where-Object { $_ -match '\.hl7$' }).Count }
function Box($dest, $mailbox) {
  (@(Invoke-RestMethod -Headers $headers "http://localhost:8080/api/routes/adt-feed/messages/$($mailbox)?destination=$dest") | ForEach-Object { $_.control_id }) -join ' '
}
function Ready { try { (Invoke-WebRequest -UseBasicParsing http://localhost:8080/ready).StatusCode -eq 200 } catch { $false } }
function Wait-Until([int]$seconds, [scriptblock]$condition) {
  foreach ($i in 1..$seconds) { if (& $condition) { return $true }; Start-Sleep 1 }
  return $false
}

Step "Starting the gateway, the lab API, the downstream HIS and the archive's SFTP server"
docker compose --progress quiet up -d
if (-not (Wait-Until 60 { Ready })) { Fail 'the gateway is not ready; see: docker compose logs gateway' }
Write-Host 'One route, adt-feed: two sources, three destinations.'

Step '1. MEDITECH sends four ADT events'
Send-Hl7 /messages/adt-a01-inpatient.hl7 /messages/adt-a04-emergency.hl7 /messages/adt-a08-outpatient.hl7 /messages/adt-a03-discharge.hl7
if (-not (Wait-Until 20 { (His) -eq 'AA ADT-9001 AA ADT-9002 AA ADT-9003 AA ADT-9004' })) { Fail "the HIS should get all four, in order: $(His)" }
Write-Host "his (every event):                  $(His)"
if (-not (Wait-Until 20 { (Lab) -eq 'ADT-9001 ADT-9002' })) { Fail "the lab should get only the inpatient A01 and the emergency A04: $(Lab)" }
Write-Host "lab (A01/A04/A08 with PV1-2 I or E): $(Lab)"
Write-Host 'ADT-9003 (an outpatient A08) and ADT-9004 (an A03) are not for the lab.'

Step '2. The partner clinic posts an ADT event over HTTP'
$body = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'messages/adt-a04-partner.hl7'))
$reply = Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://localhost:8443/hl7/adt -Body $body `
  -ContentType 'x-application/hl7-v2+er7' -Headers @{ 'X-API-Key' = $envFile['PARTNER_API_KEY'] }
($reply.Content -split "`r") | Where-Object { $_ -like 'MSA*' }
if (-not (Wait-Until 20 { (Lab) -eq 'ADT-9001 ADT-9002 ADT-9005' })) { Fail "the lab should get the partner's emergency A04" }
if (-not (Wait-Until 30 { (Closed-Files) -eq 1 })) { Fail "the fifth event should close the archive's first batch file" }
Write-Host "his: $(His)"
Write-Host "lab: $(Lab)"
Write-Host "archive, batch file 1 (closed at 5 events): $(Archive)"

Step '3. The lab API goes down; the HIS and the archive keep getting events'
Invoke-RestMethod -Method Post http://localhost:8000/control/down | Out-Null
Send-Hl7 /messages/adt-a01-during-outage.hl7
if (-not (Wait-Until 20 { (His) -like '*AA ADT-9006' })) { Fail 'the HIS should get ADT-9006 while the lab is down' }
if (-not (Wait-Until 15 { (Box lab queue) -eq 'ADT-9006' })) { Fail "ADT-9006 should wait in the lab's own queue" }
Write-Host "The HIS has ADT-9006; it waits in the lab's queue only. Open http://localhost:8080: lab is retrying."
Start-Sleep 5
Invoke-RestMethod -Method Post http://localhost:8000/control/up | Out-Null
if (-not (Wait-Until 45 { (Lab) -eq 'ADT-9001 ADT-9002 ADT-9005 ADT-9006' })) { Fail 'the lab should catch up once it is back' }
Write-Host "The lab is back and has caught up: $(Lab)"

Step "4. A patient the HIS doesn't know: dead letters for the HIS only"
Send-Hl7 /messages/adt-a08-unknown-patient.hl7
if (-not (Wait-Until 20 { (Box his dlq) -eq 'ADT-9007' })) { Fail "ADT-9007 should be in the HIS's dead letters" }
if (-not (Wait-Until 20 { (Lab) -eq 'ADT-9001 ADT-9002 ADT-9005 ADT-9006 ADT-9007' })) { Fail 'the lab should still get ADT-9007' }
Write-Host "his dead letters: $(Box his dlq)  (the lab and the archive got ADT-9007 as usual)"
if (-not (Wait-Until 40 { (Closed-Files) -eq 2 })) { Fail "max_wait should close the archive's second batch file" }
Write-Host "archive, both batch files: $(Archive)"

Write-Host "`nDone. Two senders, one route, three destinations: filtered, independent, and nothing lost."
