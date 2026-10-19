# Runs every step of sample 10 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2] }
$token = $envFile['HL7EDGE_ADMIN_TOKEN']

function Send-Hl7 { docker compose --progress quiet run --rm -T send --to gateway:7890 @args }
# The lab drops a file in its outbox: copied under a temporary name, then renamed, as SFTP uploads are.
function Lab-Drop($name) {
  # docker compose cp reports its progress on stderr, which Windows PowerShell 5.1 would treat as an error.
  $ErrorActionPreference = 'Continue'
  docker compose cp "messages/$name" "sftp:/home/hospital/outbox/$name.tmp" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "could not copy $name to the SFTP server" }
  docker compose exec -T sftp sh -c "chown 1001:100 /home/hospital/outbox/$name.tmp && mv /home/hospital/outbox/$name.tmp /home/hospital/outbox/$name"
}
function Lab-Ls($dir) { @(docker compose exec -T sftp sh -c "ls -1 /home/hospital/$dir" | Where-Object { $_ -notin 'processed', 'errors' }) }
function Lab-Cat($path) { (docker compose exec -T sftp cat "/home/hospital/$path") -replace "`r", '' }
function Has-File($path) { docker compose exec -T sftp test -f "/home/hospital/$path"; $LASTEXITCODE -eq 0 }
function Meditech { @(docker compose logs meditech | Select-String 'meditech results:' | ForEach-Object { ($_ -split '\| ', 2)[-1] }) }
function Count($pattern) { @(Meditech | Select-String $pattern).Count }
function Dead-Letters {
  $dlq = Invoke-RestMethod -Headers @{ Authorization = "Bearer $token" } http://localhost:8080/api/routes/lab-results-from-sftp/messages/dlq
  @($dlq).Count
}
function Closed-Batches { @(Lab-Ls inbox | Where-Object { $_ -match '^orders_.*\.hl7$' }).Count }
function Wait-Until([int]$seconds, [scriptblock]$condition) {
  foreach ($i in 1..$seconds) { if (& $condition) { return $true }; Start-Sleep 1 }
  return $false
}
function Ready { try { (Invoke-WebRequest -UseBasicParsing http://localhost:8080/ready).StatusCode -eq 200 } catch { $false } }

Step "Starting the lab's SFTP server, the gateway and a stand-in MEDITECH"
docker compose --progress quiet up -d
if (-not (Wait-Until 60 { Ready })) { Fail 'the gateway is not ready; see: docker compose logs gateway' }
docker compose logs keys | Select-String 'SHA256' | Select-Object -Last 1
Write-Host "The gateway polls the lab's outbox every 5 s."

Step '1. The lab drops an HL7 batch file with three results'
Lab-Drop results-batch.hl7
if (-not (Wait-Until 30 { (Count 'AA LAB-700[123]') -eq 3 })) { Fail 'MEDITECH should file LAB-7001 to LAB-7003' }
Meditech | Select-String 'LAB-700[123]'
$order = (Meditech | Select-String -AllMatches 'LAB-700[123]' | ForEach-Object { $_.Matches.Value }) -join ' '
if ($order -ne 'LAB-7001 LAB-7002 LAB-7003') { Fail 'the results should arrive in file order' }
if (-not (Wait-Until 15 { Has-File outbox/processed/results-batch.hl7 })) { Fail 'the file should be moved to outbox/processed' }
Write-Host 'Filed in order; results-batch.hl7 is now in outbox/processed.'

Step "2. A file with a stray line, and a result for a patient MEDITECH doesn't know"
Lab-Drop results-mixed.hl7
if (-not (Wait-Until 30 { Has-File outbox/errors/results-mixed.hl7.txt })) { Fail 'the stray line should go to outbox/errors' }
if (-not (Wait-Until 30 { (Count 'LAB-700[45]') -eq 2 })) { Fail 'MEDITECH should see LAB-7004 and LAB-7005' }
Meditech | Select-String 'LAB-700[45]'
Write-Host 'outbox/errors/results-mixed.hl7.txt:'
Lab-Cat outbox/errors/results-mixed.hl7.txt
if (-not (Wait-Until 10 { (Dead-Letters) -eq 1 })) { Fail "LAB-7005 (AR from MEDITECH) should be in the gateway's dead letters" }
Write-Host "LAB-7005 is in the gateway's dead letters: see the console, http://localhost:8080."

Step '3. MEDITECH sends orders; the gateway writes them to the lab''s inbox as HL7 batch files'
Send-Hl7 /messages/orm-o01-1.hl7 /messages/orm-o01-2.hl7 /messages/orm-o01-3.hl7
if (-not (Wait-Until 30 { (Closed-Batches) -ge 1 })) { Fail 'three orders should close a batch file' }
$first = Lab-Ls inbox | Where-Object { $_ -match '^orders_' } | Select-Object -First 1
Write-Host "inbox/${first}:"
$content = Lab-Cat "inbox/$first"; $content
if (-not ($content -match '^BTS\|3$')) { Fail 'the batch file should end with BTS|3' }
Send-Hl7 /messages/orm-o01-4.hl7
Write-Host 'One more order: its batch file is closed 20 s after it, by max_wait.'
if (-not (Wait-Until 45 { (Closed-Batches) -ge 2 })) { Fail 'max_wait should close the second batch file' }
Lab-Ls inbox

Step "4. MEDITECH goes down; the lab's result waits in the gateway"
docker compose --progress quiet stop meditech
Lab-Drop result-single.hl7
if (-not (Wait-Until 30 { Has-File outbox/processed/result-single.hl7 })) { Fail 'the file should be taken (the result is queued)' }
Write-Host 'result-single.hl7 is processed: LAB-7006 is queued in the gateway. Waiting 10 s...'
Start-Sleep 10
docker compose --progress quiet start meditech
if (-not (Wait-Until 45 { (Count 'AA LAB-7006') -eq 1 })) { Fail 'LAB-7006 should be filed once MEDITECH is back' }
Write-Host 'MEDITECH is back; LAB-7006 filed.'

Step "5. The lab's SFTP server goes down; orders wait in the gateway"
docker compose --progress quiet stop sftp
Send-Hl7 /messages/orm-o01-5.hl7
Write-Host 'MEDITECH got AA. The console shows orders-to-lab-sftp retrying. Waiting 10 s...'
Start-Sleep 10
docker compose --progress quiet start sftp
if (-not (Wait-Until 60 { (Closed-Batches) -ge 3 })) { Fail 'ORD-8005 should reach the lab once its server is back' }
$last = Lab-Ls inbox | Where-Object { $_ -match '^orders_' } | Select-Object -Last 1
if (-not ((Lab-Cat "inbox/$last") -match 'ORD-8005')) { Fail 'the newest batch file should hold ORD-8005' }
Write-Host 'The server is back; ORD-8005 is in a batch file in the inbox.'

Step '6. The host key the gateway trusts'
docker compose --progress quiet run --rm -T gateway-cli host-key --to sftp 2>$null | Select-Object -First 1
Write-Host 'Matches the fingerprint the keys container printed at the start: the gateway refuses any other server.'

Write-Host "`nDone. Results in order, a stray line set aside, orders batched, and both outages ridden out."
