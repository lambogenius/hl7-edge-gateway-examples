# Runs every step of sample 12 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2] }
$headers = @{ Authorization = "Bearer $($envFile['HL7EDGE_ADMIN_TOKEN'])" }

# Sends as the LIS and returns the ACK codes it gets back, e.g. "AA RES-1201".
function Send-Hl7 {
  $out = docker compose --progress quiet run --rm -T send --to gateway:7890 @args 2>&1
  (($out | Select-String -AllMatches 'MSA\|([A-Z]{2})\|([^|\r\n]*)').Matches | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" }) -join ' '
}
function Filter-Check { docker compose --progress quiet run --rm -T --entrypoint hl7-edge-gateway send filter @args }
function Alerts($port) { (@(Invoke-RestMethod "http://localhost:$port/received") | ForEach-Object { $_.control_id }) -join ' ' }
function Pager { Alerts 8001 }
function Infection-Control { Alerts 8002 }
function Queued($dest) {
  (@(Invoke-RestMethod -Headers $headers "http://localhost:8080/api/routes/results/messages/queue?destination=$dest") | ForEach-Object { $_.control_id }) -join ' '
}
function Ready { try { (Invoke-WebRequest -UseBasicParsing http://localhost:8080/ready).StatusCode -eq 200 } catch { $false } }
function Wait-Until([int]$seconds, [scriptblock]$condition) {
  foreach ($i in 1..$seconds) { if (& $condition) { return $true }; Start-Sleep 1 }
  return $false
}
function Expect($got, $want, $what) { if ($got -ne $want) { Fail "${what}: got `"$got`"" }; Write-Host "LIS got: $got" }

Step 'Starting the gateway, the EHR, the pager and infection control'
docker compose --progress quiet up -d
if (-not (Wait-Until 60 { Ready })) { Fail 'the gateway is not ready; see: docker compose logs gateway' }
Write-Host 'One route, results: pass-through to the EHR; copies to the pager and infection control.'

Step "1. The LIS sends four results; each ACK is the EHR's own"
Expect (Send-Hl7 /messages/oru-normal.hl7 /messages/oru-critical-potassium.hl7 /messages/oru-positive-culture.hl7 /messages/oru-negative-culture-abnormal-urine.hl7) `
  'AA RES-1201 AA RES-1202 AA RES-1203 AA RES-1204' 'the EHR should file all four'
if (-not (Wait-Until 20 { (Pager) -eq 'RES-1202' })) { Fail "the pager should get the critical potassium only: $(Pager)" }
if (-not (Wait-Until 20 { (Infection-Control) -eq 'RES-1203' })) { Fail "infection control should get the positive blood culture only: $(Infection-Control)" }
docker compose logs --no-log-prefix pager infection-control | Select-String 'RES-'
Write-Host 'RES-1201 is normal. RES-1204 has a negative blood culture and an abnormal urinalysis: not a positive culture.'

Step '2. Why not RES-1204: the same conditions without a group, then with one'
Filter-Check -f '@/filters/positive-culture-flat.toml' /messages/oru-negative-culture-abnormal-urine.hl7
Filter-Check -f '@/filters/positive-culture-group.toml' /messages/oru-negative-culture-abnormal-urine.hl7

Step "3. A critical result for a patient the EHR doesn't know"
Expect (Send-Hl7 /messages/oru-critical-unknown-patient.hl7) 'AR RES-1205' 'the EHR should reject RES-1205'
Start-Sleep 3
if ((Pager) -ne 'RES-1202') { Fail "RES-1205 should not be copied: the EHR didn't accept it" }
Write-Host "The LIS has the EHR's AR to act on; nothing was copied, so nobody is paged for a result that isn't filed."

Step '4. The EHR is down: the LIS gets AE and resends'
docker compose --progress quiet stop ehr
Expect (Send-Hl7 /messages/oru-critical-glucose.hl7) 'AE RES-1206' 'with the EHR down, the LIS should get AE'
if ((Pager) -ne 'RES-1202') { Fail "RES-1206 should not be copied while the EHR hasn't filed it" }
docker compose --progress quiet start ehr
Start-Sleep 2
Expect (Send-Hl7 /messages/oru-critical-glucose.hl7) 'AA RES-1206' 'the resend should be filed'
if (-not (Wait-Until 20 { (Pager) -eq 'RES-1202 RES-1206' })) { Fail "the pager should get RES-1206 once the EHR filed it: $(Pager)" }
Write-Host "pager: $(Pager)"

Step "5. The pager is down: the LIS isn't held up, and the page waits in the pager's queue"
Invoke-RestMethod -Method Post http://localhost:8001/control/down | Out-Null
Expect (Send-Hl7 /messages/oru-critical-during-pager-outage.hl7) 'AA RES-1207' 'the EHR should file RES-1207 while the pager is down'
if (-not (Wait-Until 20 { (Infection-Control) -eq 'RES-1203 RES-1207' })) { Fail "infection control should get the positive urine culture: $(Infection-Control)" }
if (-not (Wait-Until 15 { (Queued pager) -eq 'RES-1207' })) { Fail "RES-1207 should wait in the pager's queue" }
Write-Host "Infection control has RES-1207; it waits in the pager's queue. Open http://localhost:8080: pager is retrying."
Start-Sleep 5
Invoke-RestMethod -Method Post http://localhost:8001/control/up | Out-Null
if (-not (Wait-Until 45 { (Pager) -eq 'RES-1202 RES-1206 RES-1207' })) { Fail "the pager should catch up once it is back: $(Pager)" }
Write-Host "The pager is back and has caught up: $(Pager)"

Write-Host ''
Write-Host 'Done. The LIS hears from the EHR itself; the pager and infection control get what the EHR filed, per order.'
