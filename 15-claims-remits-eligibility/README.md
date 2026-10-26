# 15 · Claims, remittances and eligibility (X12)

A clinic's billing system makes **837 claims**; the clearinghouse wants them from the clinic, checked, in the
clinic's own envelope, and sends **835 remittances** and **277CA claim acknowledgments** back. Registration wants to
know, while the patient is at the desk, whether the health plan covers them: a **270** to the payer's **CAQH CORE**
server, a **271** back. With HL7 Edge Gateway 0.8, all of it runs through X12 routes, with the same queues, retries
and console as HL7.

```
Billing ──837 files (SFTP outbox)──▶ claims-to-clearinghouse ──837, envelope NORTHSIDE──▶ Clearinghouse (SFTP inbound)
        ◀──999 + TA1 (outbox/acks)──   checks every interchange
                                                                    ┌──835 as JSON──▶ Revenue-cycle API
Clearinghouse ──835, 277CA (SFTP reports)──▶ reports-to-billing ────┤
                                                                    └──277CA file───▶ Billing (SFTP inbox)
Registration ──270 (HTTPS, X-API-Key)──▶ eligibility ──CAQH CORE C4.0.0 (SOAP + MTOM)──▶ Payer
             ◀──────────271────────────              ◀────────────271──────────────────
```

| Route | What it shows |
|---|---|
| `claims-to-clearinghouse` | An SFTP source reading X12 files; every interchange checked and answered with a 999 (and a TA1, as ISA-14 asks) in `ack_directory`; a rejected interchange to `error_directory` with the reason; accepted claims sent on under the gateway's own ISA/GS (`envelope`) |
| `reports-to-billing` | `split = "transaction"`: each set on its own, so `filter = { transaction_set = … }` sends 835s to the revenue API as JSON (`x12 = "json"`) and 277CAs to billing |
| `eligibility` | Pass-through to a `caqh_core` destination: the payer's 271 straight back to registration |

The people, organizations and IDs in the files are made up. Step-by-step guide with screenshots:
<https://docs.lambogenius.com/hl7-edge-gateway/example-claims-remits-eligibility>

## Diagrams

**Architecture.** What runs where.

![Architecture](diagrams/architecture.png)

**Data flow.** What happens to an interchange, from arrival to its destinations.

![Data flow](diagrams/data-flow.png)

**Sequence.** One run of the sample, file by file.

![Sequence](diagrams/sequence.png)

The Mermaid sources are in [diagrams/](diagrams). After editing one, re-export the PNGs with
`../render-diagrams.sh 15-claims-remits-eligibility`.

## Files

| File | What it is |
|---|---|
| `gateway.toml` | The gateway configuration: three X12 routes |
| `compose.yaml` | The gateway, one SFTP server standing in for the hospital's file server and the clearinghouse's, the revenue API, the payer's CORE server, and the `tool` command |
| `files/` | Two claims, a claim without its subscriber, a remittance (835), a claim acknowledgment (277CA), two eligibility requests (270) |
| `payer/core_payer.py` | Stand-in for the payer's CAQH CORE server: answers each 270 with a 271 (covered, or subscriber not found) |
| `revenue/revenue_api.py` | Stand-in for the revenue-cycle API: takes remittances as JSON |
| `sftp/` | Makes the SFTP server's host keys and the gateway's key, and lets the key in |
| `.env.example` | License, admin token, registration's API key, SFTP password; copy it to `.env` |
| `demo.sh`, `demo.ps1` | Runs every step below and checks the result |

## Run it

You need Docker, the gateway image **0.8.0 or later**, and a license. See
[the prerequisites](../README.md#prerequisites). The files are test interchanges (ISA-15 = `T`), so the free
Developer license works.

```sh
cp .env.example .env          # then put your license in LAMBOGENIUS_LICENSE
docker compose up -d
```

The console is at <http://localhost:8080>: three routes, each marked **X12**. To look at the SFTP folders yourself,
sign in to `localhost:2222` as `billing` or `northside` with `SFTP_PASSWORD`.

**0. Check the claim files first.** The `x12` command checks files as the gateway will, and exits 3 when something
is rejected:

```sh
docker compose run --rm tool x12 /files/1-claims.x12 /files/2-claim-missing-subscriber.x12
```

```
/files/2-claim-missing-subscriber.x12: 837P from NSBILLING to ACMECLEAR (ISA-13 000000103, ISA-15 T)
  rejected: 837P 0001: N3 (2000B) at 13: unexpected segment (and 3 more)
  set 0001 837P 005010X222A1: rejected
    …
    NM1 (2010BA) at 16: required segment missing
```

Add `--ack` to see the 999 the gateway would answer, and `--json` to see the JSON a transform makes.

**1. Billing drops the claims.** Put `files/1-claims.x12` (two interchanges back to back) and
`files/2-claim-missing-subscriber.x12` in the `billing` account's `outbox`. Within a few seconds:

- `outbox/acks/1-claims.x12.ack.x12` has a TA1 (`A`) and a 999 accepting each interchange;
- `outbox/acks/2-claim-missing-subscriber.x12.ack.x12` has a 999 that rejects the claim, with
  `IK3*NM1*16*2010BA*3`: the subscriber's name (loop 2010BA) is missing;
- `outbox/errors/` has the rejected interchange and a `.txt` with the reason; both files are in `outbox/done`.

**2. The clearinghouse gets the accepted claims.** The `northside` account's `inbound` folder has
`claims_NSBILLING_000000101.x12` and `…102.x12`. Each starts
`ISA*00*          *00*          *ZZ*NORTHSIDE      *ZZ*ACMECLEAR      *`: the billing system's own ID (NSBILLING)
became the clinic's, with control numbers the gateway keeps and never repeats.

**3. Remittance and acknowledgment come back.** Put `files/3-remittance-835.x12` and
`files/4-claim-acknowledgment-277ca.x12` in `northside`'s `reports`. The revenue API logs the 835, which it got as
JSON:

```sh
docker compose logs revenue
```

```
revenue: EFT20261030 PAT1001 billed 150 paid 120 patient owes 30
revenue: EFT20261030 PAT1002 billed 95 paid 72 patient owes 0
```

and the 277CA is in `billing`'s `inbox`.

**4. Eligibility, in real time.**

```sh
curl -H "X-API-Key: <REGISTRATION_API_KEY>" -H "Content-Type: application/edi-x12" \
  --data-binary @files/5-eligibility-270.x12 http://localhost:8081/eligibility
```

The answer is the payer's 271: `EB*1*IND*30**GOLD PLAN~`, a $500 deductible and a $25 copay. For
`files/6-eligibility-270-not-covered.x12` it is `AAA*Y**75*C~`, subscriber not found. The gateway sent each 270 to
the payer's CORE server as a SOAP 1.2 `COREEnvelopeRealTimeRequest` with the 270 as an MTOM attachment, and
`hl7edge_core_requests_total` on <http://localhost:8080/metrics> counts the answers by ErrorCode. Without the
API key the gateway answers 401.

`./demo.sh` (or `.\demo.ps1`) runs all of this and checks each result.

## Clean up

```sh
docker compose down -v
```

## Make it yours

- **Your clearinghouse.** Point the SFTP source and destination at your file server and the clearinghouse's, with
  the host key fingerprints they give you (`hl7-edge-gateway host-key --to <host>`), and set the `envelope` IDs to
  the ones in your trading partner agreement.
- **Your payer.** Set `url`, `sender_id` and `receiver_id` from the payer's connectivity guide, and the client
  certificate (`tls`) and OAuth 2.0 client (`auth`) they enroll you with; the lines are in `gateway.toml`. For a
  server on CORE 2.2.0, set `rule_version = "2.2.0"` with `username` and `password`.
- **Production.** Production interchanges (ISA-15 = `P`) need the paid license.
- The guides: <https://docs.lambogenius.com/hl7-edge-gateway/x12> and
  <https://docs.lambogenius.com/hl7-edge-gateway/caqh-core>
