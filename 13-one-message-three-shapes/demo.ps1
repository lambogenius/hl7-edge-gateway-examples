# Runs every step of sample 13 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2] }
$headers = @{ Authorization = "Bearer $($envFile['HL7EDGE_ADMIN_TOKEN'])" }
$table = 'transforms/tables/patient-class.csv'
$tableText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $table))

function Send-Hl7 { docker compose --progress quiet run --rm -T send --to gateway:7890 @args }
function Tool { docker compose --progress quiet run --rm -T tool @args }
function Lis { (docker compose logs --no-log-prefix lis) -join "`n" }
function Lis-Ids { ((Lis | Select-String -AllMatches 'lis: AA ([A-Z0-9-]+)' | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }) -join ' ') }
# Invoke-RestMethod returns a JSON array as one object; ForEach-Object unrolls it.
function Received { Invoke-RestMethod http://localhost:8000/received | ForEach-Object { $_ } }
function Lis-Dead { Invoke-RestMethod -Headers $headers 'http://localhost:8080/api/routes/adt-out/messages/dlq?destination=lis' | ForEach-Object { $_ } }
function Count($system) { @(Received | Where-Object { $_.system -eq $system }).Count }
function Dead-Letters { (@(Lis-Dead) | ForEach-Object { $_.control_id }) -join ' ' }
function Ready { try { (Invoke-WebRequest -UseBasicParsing http://localhost:8080/ready).StatusCode -eq 200 } catch { $false } }
function Wait-Until([int]$seconds, [scriptblock]$condition) {
  foreach ($i in 1..$seconds) { if (& $condition) { return $true }; Start-Sleep 1 }
  return $false
}

try {
  Step "Starting the gateway, the LIS, the patient portal's API and the research registry"
  docker compose --progress quiet up -d
  if (-not (Wait-Until 60 { Ready })) { Fail 'the gateway is not ready; see: docker compose logs gateway' }
  Write-Host 'One route, adt-out: three destinations, each with its own transform.'

  Step '1. MEDITECH sends an inpatient admission and an emergency registration'
  $acks = (Send-Hl7 /messages/adt-a01-inpatient.hl7 /messages/adt-a04-emergency.hl7) -join "`n"
  if ($acks -notmatch 'MSA\|AA\|') { Fail 'both should be acknowledged with AA' }
  if (-not (Wait-Until 20 { (Lis-Ids) -eq 'ADT-1301 ADT-1302' })) { Fail "the LIS should get both: $(Lis-Ids)" }
  if (-not (Wait-Until 20 { (Count 'patient-api') -eq 2 })) { Fail 'the portal API should get both' }
  if (-not (Wait-Until 20 { (Count 'research') -eq 2 })) { Fail 'the research registry should get both' }
  $lis = Lis
  if ($lis -notmatch 'PV1\|1\|INPT\|') { Fail 'the LIS should get its own patient class, INPT' }
  if ($lis -notmatch 'ZLB\|ED\|STAT') { Fail 'the LIS should get the ED flag for the emergency registration' }
  if ($lis -match 'lis:   NK1') { Fail "the LIS shouldn't get next of kin" }
  Write-Host 'LIS (HL7, its codes):'
  ($lis -split "`n") | Select-String -Context 0, 6 'lis: AA ADT-1302' | ForEach-Object { $_.Line; $_.Context.PostContext } | ForEach-Object { '  ' + ($_ -replace '^lis: *', '') }
  $portal = @(Received | Where-Object { $_.system -eq 'patient-api' })
  if ($portal[0].content_type -notlike 'application/json*') { Fail 'the portal should get JSON, as application/json' }
  if ($portal[0].body.visit.class -ne 'inpatient') { Fail "the portal's JSON should have the visit class" }
  Write-Host "Patient portal API (JSON): $(($portal | ForEach-Object { $_.body.event }) -join ' ')"
  $researchPid = (Received | Where-Object { $_.system -eq 'research' } | Select-Object -First 1).body | Where-Object { $_ -like 'PID|*' }
  if ($researchPid -match '200301|OKAFOR') { Fail "the research registry should get no MRN or name: $researchPid" }
  Write-Host "Research registry (de-identified): $researchPid"

  Step "2. A patient class the LIS doesn't have: dead letters for the LIS only"
  $acks = (Send-Hl7 /messages/adt-a08-boarder.hl7) -join "`n"
  if ($acks -notmatch 'MSA\|AA\|') { Fail 'ADT-1303 should be acknowledged: it is stored for every destination' }
  if (-not (Wait-Until 20 { (Dead-Letters) -eq 'ADT-1303' })) { Fail "ADT-1303 should be in the LIS's dead letters" }
  if (-not (Wait-Until 20 { (Count 'patient-api') -eq 3 })) { Fail 'the portal should still get ADT-1303' }
  if (-not (Wait-Until 20 { (Count 'research') -eq 3 })) { Fail 'the research registry should still get ADT-1303' }
  $dead = @(Lis-Dead)[0]
  Write-Host "LIS dead letter: $($dead.reason)"
  if ($dead.reason -notmatch 'step 4 \(map PV1-2\)') { Fail 'the reason should name the failing step' }
  $view = Invoke-RestMethod -Headers $headers "http://localhost:8080/api/routes/adt-out/messages/dlq/$($dead.seq)?destination=lis&transformed=true"
  if (-not $view.transform_error) { Fail 'the as-sent view should say why' }
  Write-Host "The dead letter is the event as MEDITECH sent it; the console shows it as received, and why it can't be sent."

  Step "3. Add the code to the LIS's table, restart, requeue"
  [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot $table), "B,BOARDER`n")
  if (((Tool check -c /sample/gateway.toml) -join "`n") -notmatch '3 transform') { Fail 'check should load the three transforms' }
  docker compose --progress quiet restart gateway
  if (-not (Wait-Until 60 { Ready })) { Fail 'the gateway is not ready after the restart' }
  Invoke-RestMethod -Method Post -Headers $headers "http://localhost:8080/api/routes/adt-out/messages/dlq/$($dead.seq)/requeue?destination=lis" | Out-Null
  if (-not (Wait-Until 20 { (Lis-Ids) -eq 'ADT-1301 ADT-1302 ADT-1303' })) { Fail "the LIS should get ADT-1303 now: $(Lis-Ids)" }
  if ((Lis) -notmatch 'PV1\|1\|BOARDER\|') { Fail 'ADT-1303 should reach the LIS with the new code' }
  Write-Host 'The LIS has ADT-1303, transformed with the new table entry: PV1|1|BOARDER'

  Step '4. See what a transform does, without sending anything'
  Tool transform -c /sample/gateway.toml --destination lis --diff /messages/adt-a04-emergency.hl7

  Write-Host "`nDone. One feed, three shapes; a transform that can't map a code holds that event for that system only."
} finally {
  [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot $table), $tableText)
}
