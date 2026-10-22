#!/bin/zsh
# Direct queries to a device over its local HTTP endpoint.
#
# Used to confirm the metering actually woke up, which is the one thing a
# paired device will not tell you by itself.

# Reads the instantaneous voltage, in volts, from a metering device.
# Prints nothing when the device does not answer or reports no voltage.
# $1 address, $2 shared key
device_read_voltage() {
  python3 - "$1" "$2" <<'PYTHON' 2>/dev/null
import hashlib, json, random, socket, string, sys, time

host, key = sys.argv[1], sys.argv[2]
message_id = ''.join(random.choices(string.hexdigits.lower(), k=32))
stamp = int(time.time())
header = {
    "method": "GET",
    "namespace": "Appliance.Control.Electricity",
    "payloadVersion": 1,
    "from": "/app/0-local/subscribe",
    "messageId": message_id,
    "timestamp": stamp,
    "sign": hashlib.md5((message_id + key + str(stamp)).encode()).hexdigest(),
}
body = json.dumps({"header": header, "payload": {}})
request = (
    f"POST /config HTTP/1.1\r\nHost: {host}\r\n"
    f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
    f"Connection: close\r\n\r\n{body}"
)

try:
    sock = socket.create_connection((host, 80), timeout=10)
    sock.sendall(request.encode())
    raw = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        raw += chunk
    sock.close()
except OSError:
    sys.exit(1)

text = raw.decode("utf-8", "replace")
start = text.find("{", text.find("\r\n\r\n") if "\r\n\r\n" in text else text.find("\n\n"))
if start < 0:
    sys.exit(1)

try:
    electricity = json.loads(text[start:])["payload"]["electricity"]
except (ValueError, KeyError):
    sys.exit(1)

# Readings come in tenths of a volt and milliamps.
voltage = electricity.get("voltage")
if not voltage:
    sys.exit(1)
print(f"{voltage / 10:.1f}")
PYTHON
}

# True when the device reports a plausible mains voltage.
device_metering_is_live() {
  local voltage
  voltage=$(device_read_voltage "$1" "$2")
  [[ -n "$voltage" ]] && (( ${voltage%.*} > 80 ))
}
