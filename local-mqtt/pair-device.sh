#!/bin/zsh
# Moves one Meross or Refoss device from the vendor cloud to a private MQTT
# broker, from a Mac, without soldering or reflashing.
#
# Run it with no arguments and answer the questions. See README.md for what it
# needs and what it changes.

set -u

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/wifi.sh"
source "$SCRIPT_DIR/lib/broker.sh"

CLI="$SCRIPT_DIR/../packages/cli/dist/meross.js"
SCANNER="$SCRIPT_DIR/scan-networks.swift"
STATE_DIR="${MEROSS_STATE_DIR:-$HOME/.meross-local}"
KEY_FILE="$STATE_DIR/shared-key"
CERT_DIR="$STATE_DIR/certificates"
REPORT="$STATE_DIR/last-pairing.txt"

DEVICE_AP_PATTERN='^(meross|refoss)'
DEVICE_AP_ADDRESS='10.10.10.1'
USER_ID=0

check_requirements() {
  local missing=0
  for tool in node openssl swift nc; do
    command -v "$tool" >/dev/null 2>&1 || { ui_error "$tool is required"; missing=1; }
  done
  if [[ ! -f "$CLI" ]]; then
    ui_error "CLI not built. Run 'npm install && npm run build' at the repository root."
    missing=1
  fi
  (( missing )) && exit 1
}

# One shared key per household, so every device ends up with the same one and
# the integration only has to be told about it once.
load_or_create_key() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [[ -f "$KEY_FILE" ]]; then
    ui_info "Reusing the shared key from $KEY_FILE"
  else
    openssl rand -hex 16 > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    ui_ok "Generated a new shared key in $KEY_FILE"
  fi
  SHARED_KEY=$(cat "$KEY_FILE")
}

prepare_broker() {
  ui_section "Broker"
  printf "Broker address the device should report to (IP): "
  read BROKER_HOST
  printf "TLS port [8883]: "
  read BROKER_PORT
  BROKER_PORT="${BROKER_PORT:-8883}"

  if broker_tls_is_open "$BROKER_HOST" "$BROKER_PORT"; then
    ui_ok "TLS listener reachable on $BROKER_HOST:$BROKER_PORT"
    return 0
  fi

  ui_warn "No TLS listener on $BROKER_HOST:$BROKER_PORT. The firmware only speaks mqtts."
  if ! ui_confirm "Set it up now?" y; then
    ui_info "Nothing changed. Enable TLS yourself and run this again."
    exit 0
  fi

  broker_create_certificates "$CERT_DIR" "$BROKER_HOST" \
    && ui_ok "Certificates created in $CERT_DIR" \
    || { ui_error "Certificate creation failed"; exit 1; }

  if ui_confirm "Is the broker the Mosquitto add-on of Home Assistant?" y; then
    printf "SSH target for Home Assistant [root@%s]: " "$BROKER_HOST"
    read HA_SSH
    HA_SSH="${HA_SSH:-root@$BROKER_HOST}"
    ui_info "Installing certificates and restarting the add-on..."
    if broker_enable_tls_homeassistant "$HA_SSH" "$CERT_DIR"; then
      ui_wait_for 60 "waiting for the TLS listener" broker_tls_is_open "$BROKER_HOST" "$BROKER_PORT" \
        && ui_ok "TLS is now active" \
        || { ui_error "The listener did not come up. Check the add-on log."; exit 1; }
    else
      ui_error "Could not configure the add-on over SSH"
      exit 1
    fi
  else
    broker_print_manual_instructions "$CERT_DIR" "<device MAC with colons>"
    exit 0
  fi
}

# The firmware authenticates with its MAC address as the username, and colons
# cannot be stored in a mosquitto password file. On Home Assistant the account
# goes in as a Home Assistant user instead, which the add-on also accepts.
register_credentials() {
  local mac="$1" name="$2"
  local password
  password=$(broker_expected_password "$mac" "$SHARED_KEY" "$USER_ID")

  ui_section "Credentials"
  ui_info "The device will authenticate as $mac"

  if [[ -z "${HA_SSH:-}" ]]; then
    printf "Home Assistant WebSocket gateway URL (blank to skip): "
    read HA_GATEWAY
  else
    HA_GATEWAY="${HA_GATEWAY:-http://$BROKER_HOST:9600/ha/ws}"
  fi

  if [[ -z "${HA_GATEWAY:-}" ]]; then
    ui_warn "Skipped. Create an account named $mac on your broker before it connects."
    return 0
  fi

  if broker_register_homeassistant_user "${HA_SSH:-}" "$HA_GATEWAY" "$mac" "$password" "$name"; then
    ui_ok "Account created for $mac"
  else
    ui_warn "Could not create the account automatically. Create it manually for $mac."
  fi
}

configure_device() {
  local ssid="$1" wifi_password="$2" friendly_name="$3"

  {
    print -r -- "Pairing report, $(date '+%Y-%m-%d %H:%M')"
    print -r -- "Target network: $ssid    Broker: $BROKER_HOST:$BROKER_PORT"
    print -r -- ""
    print -r -- "-- Device --"
    node "$CLI" info --ip "$DEVICE_AP_ADDRESS" 2>&1
    print -r -- ""
    print -r -- "-- Applying configuration --"
    node "$CLI" setup --ip "$DEVICE_AP_ADDRESS" \
      --wifi-ssid "$ssid" --wifi-pass "$wifi_password" \
      --mqtt "mqtts://$BROKER_HOST:$BROKER_PORT" \
      --key "$SHARED_KEY" --user "$USER_ID" --set-time --quiet 2>&1
    print -r -- "Exit code: $?"
    print -r -- ""
    print -r -- "-- Key check --"
    if node "$CLI" info --ip "$DEVICE_AP_ADDRESS" --key "$SHARED_KEY" >/dev/null 2>&1; then
      print -r -- "The device answers to the new key, so the registered password matches."
    else
      print -r -- "The device no longer answers, which is expected once it reboots."
    fi
    print -r -- ""
    print -r -- "Name chosen for this device: $friendly_name"
  } | tee "$REPORT"
}

main() {
  print -r -- "Meross local MQTT pairing"
  check_requirements
  load_or_create_key

  ui_section "Device"
  printf "Friendly name for this device (used in your home automation): "
  read FRIENDLY_NAME
  FRIENDLY_NAME="${FRIENDLY_NAME:-Meross device}"

  prepare_broker

  ui_section "Wi-Fi"
  ui_info "Scanning. Everything is asked now, because the Mac has to leave this network later."
  local networks
  networks=$(wifi_scan_until "$SCANNER" 2 8)
  [[ -z "$networks" ]] && { ui_error "Scan returned nothing. Grant Location Services to your terminal."; exit 1; }

  local -a entries
  entries=("${(@f)$(print -r -- "$networks" | awk -F'\t' '{printf "%s\t%s dBm\n", $2, $1}')}")

  local target_ssid wifi_password
  target_ssid=$(ui_choose "Which network should the device join? It must be 2.4 GHz." "${entries[@]}") || exit 1
  ui_info "Chosen: $target_ssid"
  wifi_password=$(ui_read_secret "Password for $target_ssid (hidden):")
  (( ${#wifi_password} < 8 )) && { ui_error "A Wi-Fi password is at least 8 characters"; exit 1; }

  ui_section "Pairing"
  ui_info "Hold the device button until it blinks amber and green."
  local access_point
  access_point=$(wifi_find_access_point "$SCANNER" "$DEVICE_AP_PATTERN" 30 6) \
    || { ui_error "No device access point appeared"; exit 1; }
  ui_ok "Found $access_point"

  local home_prefix
  home_prefix=$(/usr/sbin/ipconfig getifaddr "$WIFI_INTERFACE" 2>/dev/null | cut -d. -f1-2)

  ui_info "Joining $access_point. This machine loses internet for a minute."
  wifi_join "$access_point" "10.10.10" >/dev/null \
    || { ui_error "Could not get an address from the device"; wifi_restore "$home_prefix" >/dev/null; exit 1; }

  local mac
  mac=$(node "$CLI" info --ip "$DEVICE_AP_ADDRESS" 2>/dev/null \
        | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)

  configure_device "$target_ssid" "$wifi_password" "$FRIENDLY_NAME"

  ui_info "Returning to the usual network..."
  wifi_restore "$home_prefix" >/dev/null

  [[ -n "$mac" ]] && register_credentials "$mac" "$FRIENDLY_NAME"

  ui_section "Result"
  ui_wait_for 120 "waiting for the device to report" \
    nc -z -G 3 "$BROKER_HOST" "$BROKER_PORT" >/dev/null 2>&1

  ui_info "Report written to $REPORT"
  ui_info "Shared key for your integration is in $KEY_FILE"
  print -r -- ""
}

main "$@"
