# Pairing a Meross device with a private MQTT broker, from a Mac

This folder adds a guided script on top of the `meross` CLI. It takes one
Meross or Refoss device from the vendor cloud to your own MQTT broker, and it
does the parts that are easy to get wrong: the TLS listener, the certificates,
and the account the firmware expects.

No soldering, no reflashing. The device keeps its own firmware; only the broker
it reports to changes.

## Why a script

The CLI already does the hard work. What took a long afternoon was everything
around it:

- the broker needs a TLS listener, because the firmware only speaks `mqtts`;
- the certificate must carry the broker address as its common name, and its
  authority must use a different one, or Mosquitto rejects it;
- the firmware authenticates as its own MAC address, **colons included**, and
  a colon cannot be stored in a mosquitto password file, so the obvious way of
  declaring the account silently never works;
- a device that fails to authenticate wipes its Wi-Fi settings and goes back to
  pairing mode, which looks exactly like a hardware failure;
- pairing mode ends on its own after about ten minutes;
- macOS can no longer scan Wi-Fi from the command line the way guides assume.

Each of those costs a round trip to the device. The script removes them.

## What it does

1. Checks that the tools are present and the CLI is built.
2. Creates one shared signing key per household, stored in
   `~/.meross-local/shared-key`, and reuses it for every later device.
3. Asks for a friendly name for the device.
4. Tests the broker for a TLS listener. If there is none, it offers to create
   a local certificate authority and a server certificate, install them, and
   turn the listener on. This is optional and you can decline.
5. Scans for Wi-Fi networks and lets you pick the one the device should join,
   with signal strength shown. Everything is asked before the Mac leaves the
   network, because it cannot scan while attached to the device.
6. Waits for the device access point to appear, rescanning while you hold the
   button, instead of giving up if the device is not already in pairing mode.
7. Joins the device, reads its identity, writes the Wi-Fi settings, the broker
   address, and the device clock and timezone.
8. Verifies that the device accepted the new key, so you learn immediately
   whether the password you registered will match.
9. Returns the Mac to its usual network.
10. Registers the device account on the broker.
11. Shows a progress bar while waiting for the device to report, and writes a
    report to `~/.meross-local/last-pairing.txt`.

The Wi-Fi password is typed without echo, is never written to disk, and never
appears in the report.

## Requirements

- macOS, with Location Services granted to your terminal. Without it, Wi-Fi
  scanning returns nothing, and the script says so instead of failing oddly.
- `node` 18 or later, `openssl`, `swift`, `nc`. All but Node ship with macOS.
- The CLI built once at the repository root:

      npm install
      npm run build

- An MQTT broker you control, reachable from the device network.
- The device within reach, and its button accessible.

If your broker is the Mosquitto add-on of Home Assistant, the script can do the
TLS setup and the account for you over SSH. For any other broker it prints the
configuration to apply and stops, changing nothing.

## Usage

    ./local-mqtt/pair-device.sh

Answer the questions. Expect the Mac to lose its network for a minute or two
while it talks to the device.

To pair a second device, run it again. The shared key is reused, so every
device ends up with the same one and your integration only needs to know it
once.

## The colon problem

This is the part worth knowing even if you never run the script.

The firmware connects with:

    username = MAC address with colons, for example 48:e1:e9:27:b7:06
    password = "<userId>_" + md5(MAC + shared key)

Mosquitto keeps accounts in a file where the colon separates the name from the
hash. A username containing colons cannot be represented there, so declaring it
through the add-on login list, or with `mosquitto_passwd`, produces an account
that never matches. The broker answers `not authorised` and the log line looks
like a wrong password:

    Client fmware:<uuid>_XXXX [<ip>:<port>] disconnected: not authorised

On Home Assistant the way out is to register the credentials as a Home
Assistant user, which the add-on also validates and which accepts colons. The
script does that. On another broker, use an authentication backend that allows
colons in usernames.

A device refused this way wipes its Wi-Fi configuration after a few attempts
and returns to pairing mode. Nothing is broken; run the script again once the
account is right.

## After pairing

The device now publishes to your broker on
`/appliance/<uuid>/publish`. That topic is derived from the device UUID and
built into the firmware, so it cannot be renamed; the friendly name you chose
is for your home automation to display.

What travels on that topic is not plain MQTT. It is the Meross application
protocol: `Appliance.*` namespaces, MD5 signed messages, and readings that have
to be polled. Home Assistant will not discover a switch on its own. Use
[meross_lan](https://github.com/krahabb/meross_lan), which speaks that protocol
and turns it into a switch plus current, voltage, power and energy. It asks for
a device key: that is the shared key this script generated.

If the readings all sit at zero, including voltage, power cycle the device once.
The metering starts after the clock and timezone have been applied and the
device has restarted.
