"""Stand-in for a health plan's CAQH CORE server (connectivity rule C4.0.0), for sample 15.

Takes a real-time eligibility request: a SOAP 1.2 COREEnvelopeRealTimeRequest with the 270 as an MTOM
attachment. It answers with a COREEnvelopeRealTimeResponse whose attachment is a 271 made from the 270: the
plan's members (below) are covered, anyone else is "subscriber not found" (AAA*Y**75). A request whose
envelope is wrong gets the ErrorCode a CORE server would give (PayloadTypeIllegal, VersionMismatch, ...).
Every request is printed as "payer: <ErrorCode> <subscriber> <answer>".

A real payer also wants a client certificate and, often, an OAuth 2.0 token; this one listens on plain HTTP.
"""
import email.parser
import email.policy
import http.server
import itertools
import re
import time
import uuid
import xml.etree.ElementTree as ET

SOAP12 = "http://www.w3.org/2003/05/soap-envelope"
CORE = "http://www.caqh.org/SOAP/WSDL/CORERuleC4.0.0.xsd"
MEMBERS = {"W100200300": ("GOLD PLAN", "20260101", 500, 25)}  # member ID: plan, coverage start, deductible, copay
NUMBERS = itertools.count(7001)  # the payer's interchange control numbers


def parts(content_type, body):
    msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body)
    return [((p.get("Content-ID") or "").strip("<>"), p.get_payload(decode=True)) for p in msg.iter_parts()]


def answer_271(request):
    """A 271 for a 270: the same parties, trace and subscriber, with the subscriber's coverage."""
    d = request[104]  # ISA-16, the component separator; the ISA is 106 characters, its terminator last
    element, terminator = request[3:4].decode(), request[105:106].decode()
    segs = [s.strip() for s in request.decode().split(terminator) if s.strip()]
    get = lambda tag: next((s.split(element) for s in segs if s.startswith(tag + element)), None)
    isa, gs, bht, trn, sub = get("ISA"), get("GS"), get("BHT"), get("TRN"), get("NM1*IL".replace("*", element))
    dmg = get("DMG")
    member = sub[9] if sub and len(sub) > 9 else ""
    now = time.gmtime()
    date, hhmm = time.strftime("%Y%m%d", now), time.strftime("%H%M", now)
    icn = f"{next(NUMBERS):09d}"
    j = element.join
    body = [j(["BHT", "0022", "11", bht[3], date, hhmm]),
            j(["HL", "1", "", "20", "1"]), j(["NM1", "PR", "2", "ACME HEALTH PLAN", "", "", "", "", "PI", "ACME1"]),
            j(["HL", "2", "1", "21", "1"]), j(["NM1", "1P", "2", "NORTHSIDE CLINIC", "", "", "", "", "XX", "1234567893"]),
            j(["HL", "3", "2", "22", "0"]), j(["TRN", "2"] + trn[2:4]), j(sub)]
    if member in MEMBERS:
        plan, start, deductible, copay = MEMBERS[member]
        if dmg:
            body.append(j(dmg))
        body += [j(["DTP", "346", "D8", start]), j(["EB", "1", "IND", "30", "", plan]),
                 j(["EB", "C", "IND", "30", "", "", "23", str(deductible)]), j(["EB", "B", "IND", "98", "", "", "27", str(copay)]),
                 j(["MSG", "COPAY APPLIES TO OFFICE VISITS"])]
        result = f"covered, {plan}"
    else:
        body.append(j(["AAA", "Y", "", "75", "C"]))
        result = "not found (AAA 75)"
    st = [j(["ST", "271", "0001", "005010X279A1"])] + body
    st.append(j(["SE", str(len(st) + 1), "0001"]))
    head = j(["ISA", "00", " " * 10, "00", " " * 10, isa[7], isa[8], isa[5], isa[6], date[2:], hhmm, isa[11], "00501", icn, "0", isa[15], chr(d)])
    lines = [head, j(["GS", "HB", gs[3], gs[2], date, hhmm, str(int(icn)), "X", "005010X279A1"])] + st
    lines += [j(["GE", "1", str(int(icn))]), j(["IEA", "1", icn])]
    return (terminator + "\n").join(lines).encode() + terminator.encode() + b"\n", member, result


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        ct = self.headers.get("Content-Type", "")
        fields, payload, code = {}, None, "Success"
        try:
            found = parts(ct, body)
            root = ET.fromstring(found[0][1])
            req = root.find(f"{{{SOAP12}}}Body")[0]
            for child in req:
                name = child.tag.rsplit("}", 1)[-1]
                if name == "Payload":
                    href = child[0].get("href", "")[4:] if len(child) else ""
                    payload = next((data for cid, data in found[1:] if cid == href), None)
                else:
                    fields[name] = child.text or ""
            if req.tag != f"{{{CORE}}}COREEnvelopeRealTimeRequest" or fields.get("CORERuleVersion") != "C4.0.0":
                code = "VersionMismatch"
            elif 'action="RealTimeTransaction"' not in ct or fields.get("ProcessingMode") != "RealTime":
                code = "ProcessingModeIllegal"
            elif fields.get("PayloadType") != "X12_270_Request_005010X279A1":
                code = "PayloadTypeIllegal"
            elif not payload or not payload.startswith(b"ISA"):
                code = "PayloadRequired"
        except Exception as e:  # not a CORE request at all
            return self.reply(400, "application/soap+xml", (
                f'<env:Envelope xmlns:env="{SOAP12}"><env:Body><env:Fault><env:Code><env:Value>env:Sender</env:Value>'
                f'</env:Code><env:Reason><env:Text xml:lang="en">not a CORE request: {e}</env:Text></env:Reason>'
                "</env:Fault></env:Body></env:Envelope>").encode())
        answer, member, result = (answer_271(payload) if code == "Success" else (None, "-", "-"))
        print(f"payer: {code} {member} {result}", flush=True)
        meta = "".join(f"<{k}>{v}</{k}>" for k, v in [
            ("PayloadType", "X12_271_Response_005010X279A1" if answer else "CoreEnvelopeError"),
            ("ProcessingMode", "RealTime"), ("PayloadID", fields.get("PayloadID", "")),
            ("TimeStamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
            ("SenderID", fields.get("ReceiverID", "")), ("ReceiverID", fields.get("SenderID", "")),
            ("CORERuleVersion", "C4.0.0")])
        include = '<Payload><xop:Include xmlns:xop="http://www.w3.org/2004/08/xop/include" href="cid:payload"/></Payload>' if answer else ""
        message = "" if code == "Success" else f"refused: {code}"
        xml = (f'<soapenv:Envelope xmlns:soapenv="{SOAP12}"><soapenv:Body><ns1:COREEnvelopeRealTimeResponse xmlns:ns1="{CORE}">'
               f"{meta}{include}<ErrorCode>{code}</ErrorCode><ErrorMessage>{message}</ErrorMessage>"
               "</ns1:COREEnvelopeRealTimeResponse></soapenv:Body></soapenv:Envelope>").encode()
        boundary = "uuid:" + str(uuid.uuid4())
        out = (f'--{boundary}\r\nContent-Type: application/xop+xml; charset=UTF-8; type="application/soap+xml"\r\n'
               "Content-ID: <root>\r\n\r\n").encode() + xml + b"\r\n"
        if answer:
            out += f"--{boundary}\r\nContent-Type: application/octet-stream\r\nContent-ID: <payload>\r\n\r\n".encode() + answer + b"\r\n"
        out += f"--{boundary}--\r\n".encode()
        self.reply(200, f'multipart/related; boundary="{boundary}"; type="application/xop+xml"; start="<root>"; '
                        'start-info="application/soap+xml"', out)

    def reply(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print("payer: CORE server on :8000", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
