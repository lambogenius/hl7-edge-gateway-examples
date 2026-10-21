"""A stand-in for the lab system (LIS) that takes ADT over MLLP (Python standard library only).

  :6661  ADT events

Answers each message with an AA ACK and prints it as received, one segment per line, so
`docker compose logs lis` shows what the gateway's transform made of it.
"""
import socketserver

VT, FS, CR = b"\x0b", b"\x1c", b"\x0d"


def field(message: str, segment: str, index: int) -> str:
    for line in message.split("\r"):
        parts = line.split("|")
        if parts[0] == segment:
            i = index - 1 if segment == "MSH" else index
            return parts[i] if len(parts) > i else ""
    return ""


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        buf = b""
        while chunk := self.request.recv(65536):
            buf += chunk
            while FS + CR in buf:
                frame, buf = buf.split(FS + CR, 1)
                message = frame.split(VT, 1)[-1].decode("utf-8", "replace")
                control_id = field(message, "MSH", 10)
                print(f"lis: AA {control_id}", flush=True)
                for segment in filter(None, message.split("\r")):
                    print(f"lis:   {segment}", flush=True)
                ack = (f"MSH|^~\\&|LIS|LAB|HL7EDGE|GATEWAY|20261021||ACK|A{control_id}|P|2.5.1\r"
                       f"MSA|AA|{control_id}|filed\r")
                self.request.sendall(VT + ack.encode() + FS + CR)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


print("lis: listening on :6661", flush=True)
Server(("0.0.0.0", 6661), Handler).serve_forever()
