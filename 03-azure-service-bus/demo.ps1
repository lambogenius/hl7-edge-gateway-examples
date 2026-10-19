# Runs every step of sample 03 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
function Send-Hl7 { docker compose --progress quiet run --rm -T send @args }
function Sb { docker compose --progress quiet run --rm -T sb @args }
function Filed($pattern) { @(docker compose logs meditech | Select-String $pattern).Count }
function EmulatorStarts { @(docker compose logs servicebus 2>&1 | Select-String 'Successfully Up').Count }
function Connected { [bool](docker compose logs gateway | Select-String 'connected to sb://') }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }

Step 'Starting the gateway, a stand-in MEDITECH and the Service Bus emulator'
docker compose --progress quiet --profile tools build sb
docker compose --progress quiet up -d
Write-Host 'Waiting for the emulator (a minute or two)...'
foreach ($i in 1..100) { if ((EmulatorStarts) -ge 1) { break }; Start-Sleep 3 }
if ((EmulatorStarts) -lt 1) { Fail 'the emulator did not start; see: docker compose logs servicebus' }
foreach ($i in 1..90) { if (Connected) { break }; Start-Sleep 2 }
if (-not (Connected)) { Fail 'the gateway did not connect to Service Bus' }
Write-Host 'The gateway is connected to Service Bus.'

Step '1. MEDITECH sends lab results; the gateway publishes them to the topic lab-results'
Send-Hl7 --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7
Start-Sleep 2
$out = Sb receive lab-results analytics; $out
if (-not ($out -match 'analytics: 2 message')) { Fail 'the analytics subscription should have 2 results' }
$out = Sb receive lab-results archive; $out
if (-not ($out -match 'archive: 2 message')) { Fail 'the archive subscription should have its own copy of both' }

Step '2. A cloud application puts orders on the queue orders-inbound; the gateway sends them to MEDITECH'
Sb send orders-inbound /messages/orm-o01-1.hl7 /messages/orm-o01-2.hl7 /messages/orm-o01-unknown-patient.hl7
foreach ($i in 1..20) { if ((Filed 'ORD-60[09][129]') -ge 3) { break }; Start-Sleep 1 }
docker compose logs meditech | Select-String 'ORD-60'
if ((Filed 'AA ORD-600[12]') -ne 2) { Fail 'MEDITECH should have filed ORD-6001 and ORD-6002' }
Write-Host "ORD-6099 was rejected by MEDITECH (AR): it is in the gateway's dead letters."

Step '3. MEDITECH goes down; orders wait in the gateway, not in Service Bus'
docker compose --progress quiet stop meditech
Sb send orders-inbound /messages/orm-o01-3.hl7
Write-Host 'Open http://localhost:8080: orders-from-service-bus is retrying with 1 queued. Waiting 10 s...'
Start-Sleep 10
docker compose --progress quiet start meditech
foreach ($i in 1..45) { if ((Filed 'AA ORD-6003') -eq 1) { break }; Start-Sleep 1 }
if ((Filed 'AA ORD-6003') -ne 1) { Fail 'ORD-6003 should be filed once MEDITECH is back' }
Write-Host "MEDITECH is back; ORD-6003 filed after ${i}s."

Step '4. Service Bus is unreachable; results wait in the gateway'
docker compose --progress quiet stop servicebus
Send-Hl7 --to gateway:7890 /messages/oru-r01-3.hl7
Write-Host 'MEDITECH got AA. Open http://localhost:8080: results-to-service-bus is retrying with 1 queued.'
Start-Sleep 10
docker compose --progress quiet start servicebus
Write-Host 'Waiting for the emulator to come back...'
foreach ($i in 1..100) { if ((EmulatorStarts) -ge 2) { break }; Start-Sleep 3 }
foreach ($i in 1..60) { $out = Sb receive lab-results analytics; if ($out -match 'RES-5003') { break }; Start-Sleep 5 }
if (-not ($out -match 'RES-5003')) { Fail 'RES-5003 should be published once Service Bus is back' }
$out

Step 'Done. Clean up with: docker compose down -v'
