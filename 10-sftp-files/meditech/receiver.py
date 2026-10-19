"""A stand-in for MEDITECH's inbound results interface over MLLP (Python standard library only).

  :6661  results (ORU^R01)

Answers each message with an HL7 ACK: AA, or AR "patient not found" when the patient ID (PID-3.1) is
not one MEDITECH knows (this sample knows 100101 to 100199). Prints one line per message.
"""
import socketserver
import threading

VT, FS, CR = b"\x0b", b"\x1c", b"\x0d"


def field(message: str, segment: str, index: int) -> str:
    for line in message.replace("\n", "\r").split("\r"):
        parts = line.split("|")
        if parts[0] == segment:
            i = index - 1 if segment == "MSH" else index
            return parts[i] if len(parts) > i else ""
    return ""


def known_patient(patient_id: str) -> bool:
    return patient_id.isdigit() and 100101 <= int(patient_id) <= 100199


def handler(interface: str):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            buf = b""
            while chunk := self.request.recv(65536):
                buf += chunk
                while FS + CR in buf:
                    frame, buf = buf.split(FS + CR, 1)
                    message = frame.split(VT, 1)[-1].decode("utf-8", "replace")
                    control_id, msg_type = field(message, "MSH", 10), field(message, "MSH", 9)
                    patient = field(message, "PID", 3).split("^")[0]
                    if known_patient(patient):
                        code, text = "AA", "filed"
                    else:
                        code, text = "AR", f"patient not found: {patient or '(none)'}"
                    print(f"meditech {interface}: {code} {control_id} {msg_type} patient {patient or '-'} ({text})", flush=True)
                    ack = (f"MSH|^~\\&|MEDITECH|GENERAL_HOSPITAL|HL7EDGE|GATEWAY|20261019||ACK|A{control_id}|P|2.5.1\r"
                           f"MSA|{code}|{control_id}|{text}\r")
                    self.request.sendall(VT + ack.encode() + FS + CR)
    return Handler


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


for interface, port in (("results", 6661),):
    server = Server(("0.0.0.0", port), handler(interface))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"meditech: {interface} interface listening on :{port}", flush=True)
threading.Event().wait()
