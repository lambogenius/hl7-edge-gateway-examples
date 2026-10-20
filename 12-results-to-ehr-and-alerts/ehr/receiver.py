"""A stand-in for the EHR's results interface over MLLP (Python standard library only).

  :6661  ORU^R01 results

Answers each message with an HL7 ACK: AA ("filed"), or AR "patient not found" when the patient ID
(PID-3.1) is not one the EHR knows (this sample knows 100101 to 100199). Prints one line per message.
"""
import socketserver

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
                print(f"ehr: {code} {control_id} {msg_type} patient {patient or '-'} ({text})", flush=True)
                ack = (f"MSH|^~\\&|EHR|GENERAL_HOSPITAL|LIS|LAB|20261020||ACK^R01|A{control_id}|T|2.5.1\r"
                       f"MSA|{code}|{control_id}|{text}\r")
                self.request.sendall(VT + ack.encode() + FS + CR)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


print("ehr: results interface listening on :6661", flush=True)
Server(("0.0.0.0", 6661), Handler).serve_forever()
