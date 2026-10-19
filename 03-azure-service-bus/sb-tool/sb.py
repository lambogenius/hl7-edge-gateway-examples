"""Sends to and reads from Service Bus, standing in for the cloud applications in sample 03.

  sb.py send <queue> <file>...                  send HL7 files (MessageId = MSH-10, like the gateway)
  sb.py receive <topic> <subscription>          receive and complete what is waiting, print each one
  sb.py dead-letters <queue>                    print the queue's dead-lettered messages and why

The connection string comes from SERVICE_BUS_CONNECTION_STRING.
"""
import os
import sys

from azure.servicebus import ServiceBusClient, ServiceBusMessage, ServiceBusSubQueue

conn = os.environ["SERVICE_BUS_CONNECTION_STRING"]


def control_id(message: str) -> str:
    fields = message.split("\r")[0].split("|")
    return fields[9] if len(fields) > 9 else ""


def show(msg) -> None:
    body = b"".join(msg.body).decode("utf-8", "replace")
    props = {k.decode() if isinstance(k, bytes) else k: (v.decode() if isinstance(v, bytes) else v)
             for k, v in (msg.application_properties or {}).items()}
    props = {k: v for k, v in props.items() if not k.startswith("DeadLetter")}  # printed below
    print(f"  message_id={msg.message_id}  content_type={msg.content_type}")
    if props:
        print("  properties: " + ", ".join(f"{k}={v}" for k, v in sorted(props.items())))
    if msg.dead_letter_reason:
        print(f"  dead-letter reason: {msg.dead_letter_reason}")
        print(f"  dead-letter description: {msg.dead_letter_error_description}")
    for segment in body.split("\r"):
        if segment:
            print(f"    {segment}")


with ServiceBusClient.from_connection_string(conn) as client:
    command, args = sys.argv[1], sys.argv[2:]
    if command == "send":
        queue, files = args[0], args[1:]
        with client.get_queue_sender(queue) as sender:
            for path in files:
                text = open(path, newline="").read()
                sender.send_messages(ServiceBusMessage(text, message_id=control_id(text), content_type="x-application/hl7-v2+er7"))
                print(f"sent {control_id(text)} to {queue}")
    elif command in ("receive", "dead-letters"):
        if command == "receive":
            receiver = client.get_subscription_receiver(args[0], args[1], max_wait_time=5)
            where = f"{args[0]}/subscriptions/{args[1]}"
        else:
            receiver = client.get_queue_receiver(args[0], sub_queue=ServiceBusSubQueue.DEAD_LETTER, max_wait_time=5)
            where = f"{args[0]}/$deadletterqueue"
        count = 0
        with receiver:
            for msg in receiver:
                count += 1
                print(f"{where}: #{count}")
                show(msg)
                receiver.complete_message(msg)
        print(f"{where}: {count} message(s)")
    else:
        sys.exit(__doc__)
