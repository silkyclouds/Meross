#!/bin/zsh
# MQTT broker preparation.
#
# Two things have to be true before a device can report to a private broker:
# the broker must accept TLS, because the firmware only speaks mqtts, and it
# must accept the credentials the firmware sends. Both are handled here, with
# the Home Assistant Mosquitto add-on as the automated path and printed
# instructions for every other broker.

# Reports whether a TLS listener answers.
# $1 host, $2 port
broker_tls_is_open() {
  nc -z -G 5 "$1" "$2" >/dev/null 2>&1
}

# Derives the password the firmware will present.
#
# The firmware authenticates as username = MAC address with colons, and
# password = "<userId>_" + md5(MAC + shared key). Verified against the values
# the device itself reports.
# $1 mac, $2 key, $3 user id
broker_expected_password() {
  local mac="$1" key="$2" user="${3:-0}"
  printf '%s_%s' "$user" "$(printf '%s%s' "$mac" "$key" | md5 -q 2>/dev/null || printf '%s%s' "$mac" "$key" | md5sum | cut -d' ' -f1)"
}

# Creates a local certificate authority and a server certificate.
#
# Mosquitto refuses a server certificate whose subject matches its authority,
# so the two common names differ. The address clients connect to must be the
# server common name, and is repeated as a subject alternative name because
# modern TLS stacks ignore the common name.
# $1 output directory, $2 broker address
broker_create_certificates() {
  local directory="$1" address="$2"
  mkdir -p "$directory"

  openssl genrsa -out "$directory/ca.key" 2048 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$directory/ca.key" -out "$directory/ca.crt" \
    -subj "/O=Local MQTT/CN=Local MQTT CA" 2>/dev/null

  openssl genrsa -out "$directory/server.key" 2048 2>/dev/null
  openssl req -new -key "$directory/server.key" -out "$directory/server.csr" \
    -subj "/O=Local MQTT/CN=$address" 2>/dev/null

  printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$address" \
    > "$directory/server.ext"

  openssl x509 -req -in "$directory/server.csr" \
    -CA "$directory/ca.crt" -CAkey "$directory/ca.key" -CAcreateserial \
    -out "$directory/server.crt" -days 3650 -extfile "$directory/server.ext" 2>/dev/null

  chmod 600 "$directory/ca.key" "$directory/server.key"
  openssl verify -CAfile "$directory/ca.crt" "$directory/server.crt" >/dev/null 2>&1
}

# Installs the certificates on a Home Assistant host and turns on the TLS
# listener of the Mosquitto add-on. The add-on always writes the plain
# listeners and only adds the TLS ones when the certificate options are set,
# so this is additive and existing clients keep working.
# $1 ssh target, $2 certificate directory
broker_enable_tls_homeassistant() {
  local target="$1" directory="$2"

  ssh -o ConnectTimeout=25 "$target" 'cat > /ssl/ca.crt'     < "$directory/ca.crt"     || return 1
  ssh -o ConnectTimeout=25 "$target" 'cat > /ssl/server.crt' < "$directory/server.crt" || return 1
  ssh -o ConnectTimeout=25 "$target" 'cat > /ssl/server.key' < "$directory/server.key" || return 1
  ssh -o ConnectTimeout=25 "$target" 'chmod 644 /ssl/ca.crt /ssl/server.crt; chmod 600 /ssl/server.key' || return 1

  ssh -o ConnectTimeout=60 "$target" '
    options=$(ha addons info core_mosquitto --raw-json 2>/dev/null \
      | jq -c ".data.options | .certfile=\"server.crt\" | .keyfile=\"server.key\" | .cafile=\"ca.crt\"")
    printf "{\"options\":%s}" "$options" > /tmp/mqtt-options.json
    curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
      -H "Content-Type: application/json" -d @/tmp/mqtt-options.json \
      http://supervisor/addons/core_mosquitto/options >/dev/null
    rm -f /tmp/mqtt-options.json
    ha addons restart core_mosquitto >/dev/null 2>&1
  ' || return 1
}

# Registers the device credentials as a Home Assistant user.
#
# This is the one step that cannot be skipped: Mosquitto stores accounts in a
# file where the colon separates the name from the hash, so a username like
# 48:e1:e9:27:b7:06 can never be added through the add-on login list. The
# add-on also validates Home Assistant accounts, and that path accepts colons.
#
# $1 ssh target, $2 gateway url, $3 username, $4 password, $5 label
broker_register_homeassistant_user() {
  local gateway="$2" username="$3" password="$4" label="$5"
  local user_id

  user_id=$(curl -s --max-time 40 -X POST "$gateway" -H 'Content-Type: application/json' \
    -d "{\"commandes\":[{\"type\":\"config/auth/create\",\"name\":\"$label\",\"group_ids\":[\"system-read-only\"],\"local_only\":true}]}" \
    2>/dev/null | sed -n 's/.*"user":{"id":"\([^"]*\)".*/\1/p')

  [[ -z "$user_id" ]] && return 1

  curl -s --max-time 40 -X POST "$gateway" -H 'Content-Type: application/json' \
    -d "{\"commandes\":[{\"type\":\"config/auth_provider/homeassistant/create\",\"user_id\":\"$user_id\",\"username\":\"$username\",\"password\":\"$password\"}]}" \
    2>/dev/null | grep -q '"ok":true'
}

# Prints what to do when the broker is not a Home Assistant add-on.
# $1 certificate directory, $2 username
broker_print_manual_instructions() {
  local directory="$1" username="$2"
  cat <<INSTRUCTIONS

   Certificates are in $directory

   1. Copy ca.crt, server.crt and server.key to the broker, then add a TLS
      listener to mosquitto.conf:

        listener 8883
        cafile   /path/to/ca.crt
        certfile /path/to/server.crt
        keyfile  /path/to/server.key

      Keep the existing plain listener so current clients stay connected.

   2. Add an account for the device. Its username contains colons, which
      mosquitto_passwd cannot store, so use an authentication plugin or a
      broker that allows them. The username will be:

        $username

   3. Restart the broker and run this script again.

INSTRUCTIONS
}
