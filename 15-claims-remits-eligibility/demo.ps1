# Runs every step of sample 15 and checks the result. Needs .env (see README.md).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }
if (-not (Test-Path .env)) { Fail 'copy .env.example to .env and put your license in it' }
$envFile = @{}
Get-Content .env | Where-Object { $_ -match '^([A-Z0-9_]+)=(.*)$' } | ForEach-Object { $envFile[$Matches[1]] = $Matches[2].Trim("'") }
if (-not $envFile['HL7EDGE_STORE_KEY']) { Fail 'put a store key in .env (HL7EDGE_STORE_KEY; see .env.example)' }
if (-not "$($envFile['BILLING_OPS_PASSWORD_HASH'])".StartsWith('$argon2id$')) { Fail "put billing-ops's password hash in .env (see .env.example)" }
# The console has a self-signed certificate: curl.exe -k talks to it (Windows PowerShell can't skip the check).
$console = 'https://localhost:8080'
function Https([string[]]$curlArgs) { curl.exe -sk @curlArgs }

function Tool { docker compose --progress quiet run --rm -T tool @args }
# Drop ACCOUNT FOLDER FILE: a file from files\ into an SFTP folder, written under a temporary name and then
# renamed, as SFTP uploads are.
function Drop($account, $folder, $file) {
  Get-Content -Raw "files/$file" | docker compose exec -T sftp sh -c 'f=/home/$1/$2/$3; cat > "$f.tmp" && chown "$1:users" "$f.tmp" && mv "$f.tmp" "$f"' sh $account $folder $file
}
function OnSftp($command) { docker compose exec -T sftp sh -c $command }
function HasFile($path) { docker compose exec -T sftp test -f "/home/$path"; $LASTEXITCODE -eq 0 }
function FilesIn($folder) { @(OnSftp "ls -1 /home/$folder 2>/dev/null" | Where-Object { $_ -like '*.x12' }).Count }
function Revenue { @(docker compose logs revenue | Select-String 'revenue: EFT' | ForEach-Object { ($_ -split '\| ', 2)[1] }) }
function RemitsAre($trace, $count) { @(Revenue | Where-Object { $_ -like "*$trace *" }).Count -eq $count }
function Ask($file) {
  $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://localhost:8081/eligibility -InFile "files/$file" `
    -ContentType 'application/edi-x12' -Headers @{ 'X-API-Key' = $envFile['REGISTRATION_API_KEY'] }
  [Text.Encoding]::UTF8.GetString($r.Content)
}
function Ready { (Https @('-o', 'NUL', '-w', '%{http_code}', "$console/ready")) -eq '200' }
function Metrics($prefix) { (Https @("$console/metrics")) -split "`n" | Where-Object { $_ -like "$prefix*" } }
function Wait-Until([int]$seconds, [scriptblock]$condition) {
  foreach ($i in 1..$seconds) { if (& $condition) { return $true }; Start-Sleep 1 }
  return $false
}

Step "Starting the SFTP server, the gateway, a revenue API and the payer's CORE server"
docker compose --progress quiet up -d
if (-not (Wait-Until 60 { Ready })) { Fail 'the gateway is not ready; see: docker compose logs gateway' }
Write-Host 'Four X12 routes: claims-to-clearinghouse, reports-to-billing, eligibility and remits-from-payer.'
$encrypted = docker compose logs gateway | Select-String 'stored messages are encrypted' | Select-Object -First 1
if (-not $encrypted) { Fail 'stored messages should be encrypted' }
Write-Host 'stored messages are encrypted'

Step '0. Check the claim files first, as billing would'
Tool x12 /files/1-claims.x12
if ($LASTEXITCODE -ne 0) { Fail 'the claims should be accepted' }
Tool x12 /files/2-claim-missing-subscriber.x12
if ($LASTEXITCODE -ne 3) { Fail 'the claim without a subscriber should be rejected (exit 3)' }
Write-Host '(x12 exits 3 when something is rejected)'

Step '1. Billing drops two claims (837P), and one without its subscriber'
Drop billing outbox 1-claims.x12
Drop billing outbox 2-claim-missing-subscriber.x12
if (-not (Wait-Until 30 { HasFile billing/outbox/acks/1-claims.x12.ack.x12 })) { Fail 'the gateway should write the answers to outbox/acks' }
if (-not (Wait-Until 30 { HasFile billing/outbox/acks/2-claim-missing-subscriber.x12.ack.x12 })) { Fail 'the rejected claim should be answered too' }
$acks = (OnSftp 'cat /home/billing/outbox/acks/1-claims.x12.ack.x12') -join "`n"
if ([regex]::Matches($acks, 'TA1\*00000010[12]\*\d*\*\d*\*A').Count -ne 2) { Fail 'both interchanges should get a TA1 (A)' }
if ([regex]::Matches($acks, 'AK9\*A\*1\*1\*1').Count -ne 2) { Fail 'both should get a 999 that accepts them' }
Write-Host 'outbox/acks/1-claims.x12.ack.x12: a TA1 and an accepting 999 for each interchange'
$rejected = (OnSftp 'cat /home/billing/outbox/acks/2-claim-missing-subscriber.x12.ack.x12') -join "`n"
if ($rejected -notmatch 'AK9\*R\*1\*1\*0') { Fail 'the claim without a subscriber should get a rejecting 999' }
if ($rejected -notmatch 'IK3\*NM1\*\d*\*2010BA\*3') { Fail 'the 999 should say the subscriber (2010BA NM1) is missing' }
Write-Host 'outbox/acks/2-claim-missing-subscriber.x12.ack.x12: IK3*NM1…2010BA*3 (required segment missing), AK9*R'
if (-not (Wait-Until 30 { HasFile billing/outbox/errors/2-claim-missing-subscriber.x12.txt })) { Fail 'the rejected interchange should go to outbox/errors' }
OnSftp 'cat /home/billing/outbox/errors/2-claim-missing-subscriber.x12.txt'

Step "2. The clearinghouse gets each accepted claim in the gateway's envelope"
if (-not (Wait-Until 30 { (FilesIn northside/inbound) -eq 2 })) { Fail "two claim files should be in the clearinghouse's inbound folder" }
OnSftp 'ls -1 /home/northside/inbound'
$sent = (OnSftp 'cat /home/northside/inbound/claims_NSBILLING_000000101.x12') -join "`n"
if (-not $sent.StartsWith('ISA*00*          *00*          *ZZ*NORTHSIDE      *ZZ*ACMECLEAR      *')) { Fail 'the claim should be sent as NORTHSIDE, not as the billing system' }
if ($sent -notmatch 'CLM\*PAT1001\*150') { Fail 'the claim should be as billing sent it' }
Write-Host "ISA: $($sent.Substring(0, 106))"
Write-Host "The billing system's own ISA/GS (NSBILLING) became the hospital's (NORTHSIDE), with the gateway's control numbers."

Step '3. The clearinghouse drops a remittance (835) and a claim acknowledgment (277CA)'
Drop northside reports 3-remittance-835.x12
Drop northside reports 4-claim-acknowledgment-277ca.x12
if (-not (Wait-Until 30 { RemitsAre EFT20261030 2 })) { Fail 'the revenue API should get both claims of the remittance' }
Revenue
if (-not (Revenue | Where-Object { $_ -like '*PAT1001 billed 150 paid 120 patient owes 30' })) { Fail 'PAT1001: paid 120, patient owes 30' }
if (-not (Wait-Until 30 { (FilesIn billing/inbox) -eq 1 })) { Fail "the 277CA should go to billing's inbox" }
Write-Host "billing/inbox: $(OnSftp 'ls -1 /home/billing/inbox')"
Metrics hl7edge_x12_acks_total

Step '4. Registration asks the payer about two patients (270), in real time over CAQH CORE'
$out = Ask 5-eligibility-270.x12
if ($out -notmatch '(?m)^EB\*1\*IND\*30\*\*GOLD PLAN~') { Fail 'Ana Rivera should be covered (EB*1)' }
$out -split "`n" | Where-Object { $_ -match '^(ST|NM1\*IL|EB|MSG)\*' }
$out = Ask 6-eligibility-270-not-covered.x12
if ($out -notmatch '(?m)^AAA\*Y\*\*75\*C~') { Fail "the second patient should be 'subscriber not found' (AAA 75)" }
$out -split "`n" | Where-Object { $_ -match '^(NM1\*IL|AAA)\*' }
docker compose logs payer | Select-String 'payer: Success' | ForEach-Object { ($_ -split '\| ', 2)[1] }
try {
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://localhost:8081/eligibility -InFile files/5-eligibility-270.x12 | Out-Null
  Fail 'a request without the API key should get 401'
} catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
  if ([int]$_.Exception.Response.StatusCode -ne 401) { Fail "a request without the API key should get 401, got $($_.Exception.Response.StatusCode)" }
}
Write-Host 'Without X-API-Key: HTTP 401'
if (-not (Metrics hl7edge_core_requests_total)) { Fail 'the CORE requests should be counted' }
Metrics hl7edge_core_requests_total

Step '5. See the remittance as JSON, as the revenue API got it'
$json = Tool x12 --json /files/3-remittance-835.x12
$start = [array]::IndexOf($json, '{')
$json[$start..($start + 39)]
Write-Host '…'

Step "6. The payer's own remittance, picked up from its CORE server"
if (-not (Wait-Until 30 { RemitsAre EFT20261106 1 })) { Fail "the revenue API should get the payer's remittance (PAT1003)" }
Revenue | Where-Object { $_ -like '*EFT20261106*' }
docker compose logs payer | Select-String 'payer: remittance' | ForEach-Object { ($_ -split '\| ', 2)[1] }
if (-not (Wait-Until 30 { docker compose logs payer | Select-String 'payer: 999 received' })) { Fail "the payer should get the gateway's 999" }
docker compose logs payer | Select-String 'payer: 999 received' | ForEach-Object { ($_ -split '\| ', 2)[1] }
if (-not (Metrics hl7edge_core_retrievals_total)) { Fail 'the retrievals should be counted' }
Metrics hl7edge_core_retrievals_total

Step '7. The console: billing-ops signs in, and everything is in the audit trail'
if ($envFile['BILLING_OPS_PASSWORD']) {
  $login = @{ name = 'billing-ops'; password = $envFile['BILLING_OPS_PASSWORD'] } | ConvertTo-Json -Compress
  $login | Set-Content -NoNewline -Encoding ascii login.json
  $headers = Https @('-D', '-', '-o', 'NUL', '-H', 'X-Requested-With: demo', '-H', 'Content-Type: application/json', '--data', '@login.json', "$console/auth/login")
  Remove-Item login.json
  $cookie = $headers | Where-Object { $_ -match '^set-cookie: (hl7edge_session=[^;]*)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1
  if (-not $cookie) { Fail 'billing-ops should sign in with BILLING_OPS_PASSWORD' }
  if ((Https @('-H', "Cookie: $cookie", "$console/auth/me")) -notmatch '"role":"operator"') { Fail 'billing-ops is an operator' }
  $code = Https @('-o', 'NUL', '-w', '%{http_code}', '-X', 'POST', '-H', "Cookie: $cookie", '-H', 'X-Requested-With: demo', "$console/api/routes/claims-to-clearinghouse/pause")
  if ($code -ne '204') { Fail "an operator pauses a route, got $code" }
  Https @('-o', 'NUL', '-X', 'POST', '-H', "Cookie: $cookie", '-H', 'X-Requested-With: demo', "$console/api/routes/claims-to-clearinghouse/resume")
  Write-Host 'billing-ops paused and resumed claims-to-clearinghouse'
  $code = Https @('-o', 'NUL', '-w', '%{http_code}', '-H', "Cookie: $cookie", "$console/api/audit")
  if ($code -ne '403') { Fail "an operator may not read the audit trail, got $code" }
  Write-Host 'billing-ops may not read the audit trail: HTTP 403'
  Https @('-o', 'NUL', '-X', 'POST', '-H', "Cookie: $cookie", '-H', 'X-Requested-With: demo', "$console/auth/logout")
} else {
  Write-Host "(BILLING_OPS_PASSWORD isn't set in .env: skipping the sign-in)"
}
Write-Host 'The audit trail, newest first:'
(Https @('-H', "Authorization: Bearer $($envFile['HL7EDGE_ADMIN_TOKEN'])", "$console/api/audit?limit=8")) | ConvertFrom-Json |
  ForEach-Object { '  {0}  {1}  {2}  {3}' -f $_.time, $_.actor.name, $_.action, $_.outcome }

Write-Host ''
Write-Host "Done. Claims checked and acknowledged for billing, sent on in the hospital's envelope; the remittances as JSON"
Write-Host "for the revenue API, from the clearinghouse and from the payer's CORE server; the 277CA for billing; eligibility"
Write-Host 'from the payer in real time. Stored messages are encrypted. Console: https://localhost:8080 (sign in as billing-ops).'
