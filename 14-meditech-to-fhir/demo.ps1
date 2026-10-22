# Runs every step of sample 14 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2] }
$headers = @{ Authorization = "Bearer $($envFile['HL7EDGE_ADMIN_TOKEN'])" }
$fhir = 'http://localhost:8090/fhir'
$id = 'https://general-hospital.example/id'

function Send-Hl7 { docker compose --progress quiet run --rm -T send --to gateway:7890 @args }
function Tool { docker compose --progress quiet run --rm -T tool @args }
# Search TYPE QUERY: the matching resources.
function Search($type, $query) { @((Invoke-RestMethod "$fhir/$type`?$query").entry | ForEach-Object { $_.resource }) }
function Total($type, $query) { (Invoke-RestMethod "$fhir/$type`?_summary=count&$query").total }
function Delivered { (Invoke-RestMethod -Headers $headers http://localhost:8080/api/overview).routes[0].status.counters.delivered }
function Ready {
  try { (Invoke-WebRequest -UseBasicParsing http://localhost:8080/ready).StatusCode -eq 200 -and (Invoke-WebRequest -UseBasicParsing "$fhir/metadata").StatusCode -eq 200 }
  catch { $false }
}
function Wait-Until([int]$seconds, [scriptblock]$condition) {
  foreach ($i in 1..$seconds) { if (& $condition) { return $true }; Start-Sleep 1 }
  return $false
}
function Acked($output, [int]$count = 1) { @($output | Select-String -SimpleMatch 'MSA|AA|').Count -eq $count }

Step 'Starting the gateway and the FHIR server (HAPI FHIR takes about a minute the first time)'
docker compose --progress quiet up -d
if (-not (Wait-Until 180 { Ready })) { Fail 'not ready; see: docker compose logs gateway fhir-server' }
Write-Host 'One route, meditech-to-fhir: MLLP in, a FHIR transaction out for each message.'

Step '1. MEDITECH admits a patient (ADT^A01)'
if (-not (Acked (Send-Hl7 /messages/1-adt-a01-admit.hl7))) { Fail 'the admission should be acknowledged with AA' }
if (-not (Wait-Until 30 { (Delivered) -eq 1 })) { Fail 'the gateway should deliver the admission' }
$patient = Search Patient "identifier=$id/GENERAL_HOSPITAL|200301"
if ($patient.Count -ne 1) { Fail 'the FHIR server should have the patient' }
$visit = Search Encounter "identifier=$id/GENERAL_HOSPITAL|V5001"
if ($visit[0].status -ne 'in-progress' -or $visit[0].class.code -ne 'IMP') { Fail 'the visit should be an inpatient visit in progress' }
Write-Host "Patient $($patient[0].name[0].family), $($patient[0].gender), born $($patient[0].birthDate)"
Write-Host "Encounter V5001: in-progress, inpatient (IMP), admitted $($visit[0].period.start)"
Write-Host "Also: RelatedPerson $(Total RelatedPerson), AllergyIntolerance $(Total AllergyIntolerance), Condition $(Total Condition), Practitioner $(Total Practitioner)"

Step '2. The doctor orders a metabolic panel (ORM^O01), and the lab sends the results (ORU^R01)'
if (-not (Acked (Send-Hl7 /messages/2-orm-o01-order.hl7 /messages/3-oru-r01-results.hl7) 2)) { Fail 'both should be acknowledged with AA' }
if (-not (Wait-Until 30 { (Delivered) -eq 3 })) { Fail 'the gateway should deliver both' }
if ((Total Patient) -ne 1) { Fail "results and orders shouldn't make a second patient" }
if ((Total Observation) -ne 3) { Fail 'three results should be three Observations' }
$report = Search DiagnosticReport "identifier=$id/LAB|LAB-55501"
if ($report[0].status -ne 'final') { Fail 'the report should be final' }
$glucose = Search Observation 'code=http://loinc.org|2345-7'
if ($glucose[0].valueQuantity.value -ne 182) { Fail "glucose should be 182, got $($glucose[0].valueQuantity.value)" }
Write-Host "ServiceRequest ORD-1001: $((Search ServiceRequest "identifier=$id/MEDITECH|ORD-1001")[0].status), DiagnosticReport LAB-55501: final"
Write-Host "Observations: $(Total Observation); glucose $($glucose[0].valueQuantity.value) mg/dL ($($glucose[0].status))"

Step '3. The lab corrects the glucose (ORU^R01 again, OBX-11 = C)'
if (-not (Acked (Send-Hl7 /messages/4-oru-r01-corrected.hl7))) { Fail 'the correction should be acknowledged with AA' }
if (-not (Wait-Until 30 { (Delivered) -eq 4 })) { Fail 'the gateway should deliver the correction' }
if ((Total Observation) -ne 3) { Fail 'the correction should replace the results, not add three more' }
$glucose = Search Observation 'code=http://loinc.org|2345-7'
if ($glucose[0].valueQuantity.value -ne 128 -or $glucose[0].status -ne 'corrected') { Fail 'glucose should now be 128, corrected' }
Write-Host "Still $(Total Observation) Observations; glucose 128 mg/dL (corrected); DiagnosticReport $((Search DiagnosticReport "identifier=$id/LAB|LAB-55501")[0].status)"

Step '4. A flu shot (VXU^V04)'
if (-not (Acked (Send-Hl7 /messages/5-vxu-v04-flu-shot.hl7))) { Fail 'the immunization should be acknowledged with AA' }
if (-not (Wait-Until 30 { (Delivered) -eq 5 })) { Fail 'the gateway should deliver the immunization' }
$shot = Search Immunization "patient.identifier=$id/GENERAL_HOSPITAL|200301"
if ($shot[0].status -ne 'completed') { Fail 'the flu shot should be completed' }
Write-Host "Immunization: completed, lot $($shot[0].lotNumber)"

Step '5. MEDITECH discharges the patient (ADT^A03)'
if (-not (Acked (Send-Hl7 /messages/6-adt-a03-discharge.hl7))) { Fail 'the discharge should be acknowledged with AA' }
if (-not (Wait-Until 30 { (Delivered) -eq 6 })) { Fail 'the gateway should deliver the discharge' }
$visit = Search Encounter "identifier=$id/GENERAL_HOSPITAL|V5001"
if ($visit[0].status -ne 'finished') { Fail 'the visit should be finished' }
if ((Total Encounter) -ne 1) { Fail 'the discharge should update the visit, not add one' }
Write-Host "Encounter V5001: finished, ended $($visit[0].period.end)"

Step "6. A recurring visit with MEDITECH's own patient class, RCR (ADT^A04)"
if (-not (Acked (Send-Hl7 /messages/7-adt-a04-recurring.hl7))) { Fail 'the registration should be acknowledged with AA' }
if (-not (Wait-Until 30 { (Delivered) -eq 7 })) { Fail 'the gateway should deliver the registration' }
$recurring = Search Encounter "identifier=$id/GENERAL_HOSPITAL|V5107"
if ($recurring[0].class.code -ne 'AMB') { Fail "RCR should become the AMB class (fhir/tables.toml), got $($recurring[0].class.code)" }
Write-Host "Encounter V5107: ambulatory (AMB), from MEDITECH's RCR through fhir/tables.toml"
(Invoke-WebRequest -UseBasicParsing http://localhost:8080/metrics).Content -split "`n" | Select-String 'hl7edge_fhir_entries_total.*resource="Observation"'

Step '7. See the Bundle a message makes, without sending it'
Tool transform -c /sample/gateway.toml --destination fhir /messages/5-vxu-v04-flu-shot.hl7 | Select-Object -First 40
Write-Host '…'

Write-Host ''
Write-Host 'Done. Seven MEDITECH messages, one patient in FHIR: a visit admitted and discharged, results corrected in place,'
Write-Host "a flu shot, and a recurring visit with MEDITECH's own code. Browse them at http://localhost:8090."
