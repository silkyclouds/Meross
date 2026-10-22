# Meross utilities

Tools to help configure the Meross devices to use private MQTT servers.

## About this fork

This is a fork of [bytespider/Meross](https://github.com/bytespider/Meross) by
Rob Griffiths. All the protocol work, the CLI and the library are his; this
fork only adds what was missing to get a plug running end to end on a private
broker in one go. Upstream remains the reference, and these changes are offered
back to it.

Two additions:

**A tolerant HTTP transport.** Meross firmware terminates its HTTP status line
with a bare line feed instead of CRLF. Node's parser rejects that with
`Parse Error: Missing expected CR after response line`, and
`--insecure-http-parser` does not relax this particular check, so on current
Node releases every request fails before reaching the device. Tested on Node 20
and Node 25, with a MSS310 hardware 2.0.0 running firmware 2.1.17.
`packages/lib/src/transport/lenient-fetch.ts` reads the response off the socket
instead, and is now the default transport. Nothing else in the API changes, and
a caller can still inject its own `fetch`.

**A guided pairing script**, in [`local-mqtt/`](local-mqtt/README.md). It wraps
the CLI and handles the parts around it that are easy to get wrong: creating
the certificates, switching the TLS listener on, registering an account the
firmware can actually use, waiting for the device access point while you hold
the button, and putting the Mac back on its own network afterwards. It asks for
a friendly name, hides the Wi-Fi password, and shows progress instead of a bare
wait. Everything it changes is optional and announced first.

The sharpest trap it works around, documented in that README: the firmware
authenticates with its MAC address **including colons**, and a colon is the
field separator in a mosquitto password file. The account therefore cannot be
declared the obvious way, the broker answers `not authorised`, and the device
responds by wiping its Wi-Fi settings and returning to pairing mode, which
looks like a hardware fault.

Start here: [`local-mqtt/README.md`](local-mqtt/README.md).

## Requirements

NodeJS: ^21.0.0, ^20.10.0, ^18.20.0
NPM: ^10.0.0

## Setup

TODO:
[Devices with WIFI pairing]()

[Devices with Bluetooth pairing]()

## Tools

### Info

```
npx meross-info [options] <options>

Options:
  -V, --version           output the version number
  -a, --ip <ip>           Send command to device with this IP address (default: "10.10.10.1")
  -u, --user <user-id>    Integer id. Used by devices connected to the Meross Cloud
  -k, --key <shared-key>  Shared key for generating signatures (default: "")
  --include-wifi          List WIFI Access Points near the device
  --include-ability       List device ability list
  --include-time          List device time
  -v, --verbose           Show debugging messages
  -h, --help              display help for command
```

### Setup

```
npx meross-setup [options] <options>

Options:
  -V, --version                        output the version number
  -a, --ip <ip>                        Send command to device with this IP address (default: "10.10.10.1")
  --wifi-ssid <wifi-ssid>              WIFI Access Point name
  --wifi-pass <wifi-pass>              WIFI Access Point password
  --wifi-encryption <wifi-encryption>  WIFI Access Point encryption (this can be found using meross info --include-wifi)
  --wifi-cipher <wifi-cipher>          WIFI Access Point cipher (this can be found using meross info --include-wifi)
  --wifi-bssid <wifi-bssid>            WIFI Access Point BSSID (each octet separated by a colon `:`)
  --wifi-channel <wifi-channel>        WIFI Access Point 2.5GHz channel number [1-13] (this can be found using meross info --include-wifi)
  --mqtt <mqtt-server>                 MQTT server address
  -u, --user <user-id>                 Integer id. Used by devices connected to the Meross Cloud (default: 0)
  -k, --key <shared-key>               Shared key for generating signatures (default: "")
  -t, --set-time                       Configure device time with time and timezone of current host
  -v, --verbose                        Show debugging messages (default: "")
  -h, --help                           display help for command
```
