#!/bin/zsh
# Home Assistant follow-up, so a freshly paired device actually reports over
# MQTT instead of looking like it does.
#
# meross_lan defaults its connection protocol to "auto", and auto prefers HTTP
# whenever it knows the device address. The device then authenticates against
# the broker, shows up as a connected client, and publishes nothing, while the
# entities still update over HTTP. Everything looks healthy and the broker is
# unused. Forcing the protocol to mqtt is what closes the loop.
#
# Everything here needs a long lived access token, created under your Home
# Assistant profile. It is optional: without one the script prints the manual
# steps instead.

# Calls the REST API. $1 method, $2 path, $3 body (optional).
ha_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -s --max-time 30 -X "$method" "$HA_URL$path" \
      -H "Authorization: Bearer $HA_TOKEN" \
      -H 'Content-Type: application/json' -d "$body" 2>/dev/null
  else
    curl -s --max-time 30 -X "$method" "$HA_URL$path" \
      -H "Authorization: Bearer $HA_TOKEN" 2>/dev/null
  fi
}

ha_is_reachable() {
  ha_api GET /api/ | grep -q 'API running'
}

# Finds the meross_lan entry for a device UUID. Prints the entry id.
ha_find_entry() {
  local uuid="$1"
  ha_api GET /api/config/config_entries/entry | python3 -c '
import json, sys
uuid = sys.argv[1]
try:
    entries = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for entry in entries:
    if entry.get("domain") != "meross_lan":
        continue
    if entry.get("source") == "ignore":
        continue
    haystack = f'"'"'{entry.get("unique_id")} {entry.get("title")}'"'"'
    if uuid in haystack or uuid[-12:] in haystack:
        print(entry["entry_id"])
        break
' "$uuid"
}

# Walks the options flow of an entry and sets the connection protocol to mqtt.
#
# The flow starts on a menu, so the step that holds the device settings has to
# be selected first. Existing values are read from the form and sent back
# unchanged, because the flow rejects a partial payload.
ha_force_mqtt_protocol() {
  local entry_id="$1"
  local flow flow_id step payload

  flow=$(ha_api POST /api/config/config_entries/options/flow "{\"handler\":\"$entry_id\"}")
  flow_id=$(print -r -- "$flow" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("flow_id",""))' 2>/dev/null)
  [[ -z "$flow_id" ]] && return 1

  step=$(print -r -- "$flow" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("type",""), d.get("step_id",""))' 2>/dev/null)

  # A menu step needs an explicit choice before the form appears.
  if [[ "$step" == menu* ]]; then
    flow=$(ha_api POST "/api/config/config_entries/options/flow/$flow_id" '{"next_step_id":"device"}')
  fi

  payload=$(print -r -- "$flow" | python3 -c '
import json, sys
try:
    form = json.load(sys.stdin)
except Exception:
    sys.exit(1)
values = dict(form.get("data_schema_defaults") or {})
for field in form.get("data_schema") or []:
    name = field.get("name")
    if name and name not in values and field.get("default") is not None:
        values[name] = field["default"]
values["protocol"] = "mqtt"
print(json.dumps(values))
' 2>/dev/null)

  [[ -z "$payload" ]] && return 1

  ha_api POST "/api/config/config_entries/options/flow/$flow_id" "$payload" \
    | grep -q '"type": *"create_entry"'
}

ha_print_manual_steps() {
  cat <<'STEPS'

   In Home Assistant, open Settings, Devices and services, Meross LAN, then
   the gear icon next to your device, and choose Configure.

   Set Connection protocol to mqtt and submit.

   Left on auto, the integration polls the device over HTTP whenever it knows
   its address. The device still connects to your broker and still publishes
   nothing, which is easy to mistake for a working setup.

STEPS
}
