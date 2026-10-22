#!/bin/zsh
# Wi-Fi scanning and joining on macOS.
#
# The `airport` binary was removed from macOS, and `system_profiler` redacts
# network names unless Location Services are granted, so scanning goes through
# CoreWLAN via a small Swift program. The device access point can only be
# reached by leaving the home network, which is why the caller must gather
# every answer it needs before switching.

WIFI_INTERFACE="${WIFI_INTERFACE:-en0}"

# Scans once. Prints "rssi<TAB>ssid" per line, strongest first.
wifi_scan() {
  local scanner="$1"
  timeout 60 /usr/bin/swift "$scanner" 2>/dev/null
}

# Scans until at least $2 networks are visible, because macOS returns partial
# results when scans run back to back.
# $1 scanner path, $2 minimum count, $3 attempts
wifi_scan_until() {
  local scanner="$1" minimum="${2:-2}" attempts="${3:-8}"
  local result count attempt

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    result=$(wifi_scan "$scanner")
    count=$(print -r -- "$result" | grep -c . )
    if (( count >= minimum )); then
      print -r -- "$result"
      return 0
    fi
    sleep 5
  done

  print -r -- "$result"
  return 1
}

# Looks for an access point whose name matches a pattern, rescanning until it
# shows up. Devices leave pairing mode on their own after about ten minutes,
# so the user often has to press the button while this runs.
# $1 scanner, $2 pattern, $3 attempts, $4 seconds between attempts
wifi_find_access_point() {
  local scanner="$1" pattern="$2" attempts="${3:-30}" delay="${4:-6}"
  local attempt found

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    found=$(wifi_scan "$scanner" | awk -F'\t' '{print $2}' | grep -iE "$pattern" | head -1)
    if [[ -n "$found" ]]; then
      print -r -- "$found"
      return 0
    fi
    printf "\r   scanning, attempt %d of %d..." "$attempt" "$attempts" >&2
    sleep "$delay"
  done

  print -r -- "" >&2
  return 1
}

# Joins a network and waits for an address in the expected range.
# $1 ssid, $2 address prefix to wait for, $3 password (optional)
wifi_join() {
  local ssid="$1" expect="$2" password="${3:-}" attempt address

  if [[ -n "$password" ]]; then
    /usr/sbin/networksetup -setairportnetwork "$WIFI_INTERFACE" "$ssid" "$password" >/dev/null 2>&1
  else
    /usr/sbin/networksetup -setairportnetwork "$WIFI_INTERFACE" "$ssid" >/dev/null 2>&1
  fi

  for (( attempt = 1; attempt <= 20; attempt++ )); do
    address=$(/usr/sbin/ipconfig getifaddr "$WIFI_INTERFACE" 2>/dev/null)
    [[ "$address" == ${~expect}* ]] && { print -r -- "$address"; return 0; }
    sleep 2
  done

  print -r -- "${address:-}"
  return 1
}

# Returns to the usual network. Cycling the radio is more reliable than asking
# for a specific network, because macOS reconnects to its preferred one and we
# never hold the home Wi-Fi password.
# $1 address prefix that marks a successful return
wifi_restore() {
  local expect="$1" attempt address

  /usr/sbin/networksetup -setairportpower "$WIFI_INTERFACE" off >/dev/null 2>&1
  sleep 3
  /usr/sbin/networksetup -setairportpower "$WIFI_INTERFACE" on >/dev/null 2>&1

  for (( attempt = 1; attempt <= 30; attempt++ )); do
    address=$(/usr/sbin/ipconfig getifaddr "$WIFI_INTERFACE" 2>/dev/null)
    [[ "$address" == ${~expect}* ]] && { print -r -- "$address"; return 0; }
    sleep 2
  done

  print -r -- "${address:-none}"
  return 1
}
