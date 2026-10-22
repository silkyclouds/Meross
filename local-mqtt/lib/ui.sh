#!/bin/zsh
# Terminal prompts and progress reporting.
#
# The upstream CLI draws progress with terminal-kit, which aborts with
# "Terminal is not capable" in terminals it does not recognise. Everything here
# sticks to plain escape-free output so the script runs anywhere.

# Prints a section heading.
ui_section() {
  print -r -- ""
  print -r -- "== $1"
}

ui_info()    { print -r -- "   $1"; }
ui_ok()      { print -r -- "   OK: $1"; }
ui_warn()    { print -r -- "   Warning: $1"; }
ui_error()   { print -r -- "   Error: $1" >&2; }

# Asks the user to pick one entry from a list.
#
# $1    prompt shown above the list
# $2..  entries, each formatted as "label<TAB>detail"
#
# Prints the chosen label on stdout. Everything else goes to stderr so the
# caller can capture the result with a command substitution.
ui_choose() {
  local prompt="$1"; shift
  local -a entries=("$@")
  local index=1 entry label detail reply

  if (( ${#entries[@]} == 0 )); then
    ui_error "nothing to choose from" >&2
    return 1
  fi

  print -r -- "" >&2
  print -r -- "$prompt" >&2
  for entry in "${entries[@]}"; do
    label="${entry%%	*}"
    detail="${entry#*	}"
    [[ "$detail" == "$entry" ]] && detail=""
    printf "  %2d) %-32s %s\n" "$index" "$label" "$detail" >&2
    (( index++ ))
  done

  printf "Number: " >&2
  read reply
  if [[ -z "${entries[$reply]:-}" ]]; then
    ui_error "invalid choice" >&2
    return 1
  fi

  entry="${entries[$reply]}"
  print -r -- "${entry%%	*}"
}

# Asks a yes or no question. Returns 0 for yes.
# $1 question, $2 default answer ("y" or "n")
ui_confirm() {
  local question="$1" default="${2:-n}" reply hint
  [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  printf "%s %s " "$question" "$hint"
  read reply
  reply="${reply:-$default}"
  [[ "${reply:l}" == y* ]]
}

# Reads a value without echoing it, so secrets never reach the screen,
# the shell history or the script output.
ui_read_secret() {
  local prompt="$1" value
  printf "%s " "$prompt"
  read -s value
  print -r -- "" >&2
  print -r -- "$value"
}

# Runs a command in the background while drawing a progress bar.
#
# $1    seconds to wait at most
# $2    label shown next to the bar
# $3..  condition command; the wait stops as soon as it succeeds
#
# Returns 0 if the condition succeeded, 1 on timeout.
ui_wait_for() {
  local timeout="$1" label="$2"; shift 2
  local width=32 elapsed=0 filled percent

  while (( elapsed < timeout )); do
    if "$@" >/dev/null 2>&1; then
      printf "\r   %s [%s] done%*s\n" "$label" "$(printf '#%.0s' {1..$width})" 8 ""
      return 0
    fi
    (( elapsed += 2 ))
    percent=$(( elapsed * 100 / timeout ))
    filled=$(( elapsed * width / timeout ))
    printf "\r   %s [%-*s] %3d%%" "$label" "$width" "$(printf '#%.0s' {1..$filled} 2>/dev/null)" "$percent"
    sleep 2
  done

  printf "\r   %s [%-*s] timed out%*s\n" "$label" "$width" "" 8 ""
  return 1
}
