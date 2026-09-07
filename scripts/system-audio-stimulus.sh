#!/bin/zsh
set -eu
script_name=$0

usage() {
  echo "usage: ${script_name} <absolute-output>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 64
fi

output=$1
run_token=${NOTE_TAKER_SMOKE_RUN_TOKEN-}
if [[ -z "$run_token" ]]; then
  echo "system-audio-stimulus: missing NOTE_TAKER_SMOKE_RUN_TOKEN env var" >&2
  exit 64
fi
uuid_pattern='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
if [[ ! "$run_token" =~ $uuid_pattern ]]; then
  echo "system-audio-stimulus: invalid NOTE_TAKER_SMOKE_RUN_TOKEN env var" >&2
  exit 64
fi
if [[ $output != /* ]]; then
  echo "system-audio-stimulus: output path must be absolute: $output" >&2
  exit 64
fi
if [[ -d $output ]]; then
  echo "system-audio-stimulus: output path must not be a directory: $output" >&2
  exit 64
fi

request_sidecar="${output}.probe-request"
muted_sidecar="${output}.probe-muted"
done_sidecar="${output}.probe-done"
cancellation_sidecar="${output}.cancel-request"
cancel_ack_sidecar="${output}.cancel-ack"
request_temporary="${output}.probe-request.tmp.${run_token}"
muted_temporary="${output}.probe-muted.tmp.${run_token}"
done_temporary="${output}.probe-done.tmp.${run_token}"
cancellation_temporary="${output}.cancel-request.tmp.${run_token}"

speech_pid=""
carrier_pid=""
artifacts_owned=0
request_wait_limit=${STIMULUS_REQUEST_TIMEOUT_SECONDS:-90}
done_wait_limit=${STIMULUS_DONE_TIMEOUT_SECONDS:-30}
speech_cycle_seconds=${STIMULUS_SPEECH_CYCLE_SECONDS:-3}
carrier_sound="/System/Library/Sounds/Glass.aiff"
carrier_rate=${STIMULUS_SILENT_CARRIER_RATE:-0.1}
start_epoch=$(/bin/date +%s)
probe_completed=0

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

marker_token_matches() {
  local marker=$1
  local token=$2

  if [[ ! -f "$marker" || -L "$marker" ]]; then
    return 1
  fi

  /usr/bin/cmp -s "$marker" <(/usr/bin/printf '%s' "$token")
}

remove_marker_if_owned() {
  local marker=$1

  if marker_token_matches "$marker" "$run_token"; then
    /bin/rm -f -- "$marker"
  fi
}

remove_owned_probe_artifacts() {
  remove_marker_if_owned "$request_sidecar"
  remove_marker_if_owned "$muted_sidecar"
  remove_marker_if_owned "$done_sidecar"
  remove_marker_if_owned "$request_temporary"
  remove_marker_if_owned "$muted_temporary"
  remove_marker_if_owned "$done_temporary"
}

stop_speech() {
  if [[ -n "$speech_pid" ]]; then
    local owned_pid=$speech_pid
    speech_pid=""
    /bin/kill "$owned_pid" 2>/dev/null || true
    wait "$owned_pid" 2>/dev/null || true
  fi
}

stop_silent_carrier() {
  if [[ -n "$carrier_pid" ]]; then
    local owned_pid=$carrier_pid
    carrier_pid=""
    /bin/kill "$owned_pid" 2>/dev/null || true
    wait "$owned_pid" 2>/dev/null || true
  fi
}

cleanup() {
  local exit_code=$?
  trap - EXIT
  trap '' HUP INT TERM

  stop_speech
  stop_silent_carrier
  if (( artifacts_owned )); then
    remove_owned_probe_artifacts
  fi

  exit "$exit_code"
}

exit_for_signal() {
  exit "$1"
}

trap cleanup EXIT
trap 'exit_for_signal 129' HUP
trap 'exit_for_signal 130' INT
trap 'exit_for_signal 143' TERM

# Make establishes an empty namespace before launching either participant. A
# request may legitimately win the startup race, so never pre-delete it here.
# Reject stale acknowledgements and temporary markers before starting a child.
if path_exists "$cancel_ack_sidecar" || path_exists "$cancellation_temporary"; then
  exit 0
fi
for artifact in \
  "$muted_sidecar" \
  "$done_sidecar" \
  "$muted_temporary" \
  "$done_temporary" \
  "$cancellation_temporary"; do
  if path_exists "$artifact"; then
    echo "system-audio-stimulus: stale sidecar prevents ownership: ${artifact}" >&2
    exit 5
  fi
done
artifacts_owned=1

if marker_token_matches "$cancellation_sidecar" "$run_token"; then
  exit 0
fi

atomic_touch() {
  local target=$1
  local temporary=$2

  if path_exists "$target" || path_exists "$temporary"; then
    if marker_token_matches "$target" "$run_token"; then
      return 0
    fi
    echo "system-audio-stimulus: refusing stale sidecar publication: ${target}" >&2
    return 1
  fi

  if ! (set -o noclobber; /usr/bin/printf '%s' "$run_token" > "$temporary"); then
    echo "system-audio-stimulus: failed to create temporary sidecar: ${temporary}" >&2
    return 1
  fi
  if /bin/ln "$temporary" "$target"; then
    remove_marker_if_owned "$temporary"
    return 0
  fi

  remove_marker_if_owned "$temporary"
  echo "system-audio-stimulus: failed to publish sidecar: ${target}" >&2
  return 1
}

start_speech() {
  if [[ -n "$speech_pid" || -n "$carrier_pid" ]]; then
    echo "system-audio-stimulus: refusing overlapping audio children." >&2
    exit 4
  fi
  /usr/bin/say "system audio test" &
  speech_pid=$!
}

start_silent_carrier() {
  if [[ -n "$speech_pid" || -n "$carrier_pid" ]]; then
    echo "system-audio-stimulus: refusing overlapping silent carrier." >&2
    exit 4
  fi
  /usr/bin/afplay -v 0 -r "$carrier_rate" "$carrier_sound" &
  carrier_pid=$!
  verify_silent_carrier_alive
}

fail_silent_carrier_exited() {
  local owned_pid=$carrier_pid
  carrier_pid=""
  set +e
  wait "$owned_pid"
  local carrier_status=$?
  set -e

  echo "system-audio-stimulus: silent carrier exited before probe done with status ${carrier_status}." >&2
  if [[ "$carrier_status" -eq 0 ]]; then
    carrier_status=4
  fi
  exit "$carrier_status"
}

verify_silent_carrier_alive() {
  if [[ -z "$carrier_pid" ]]; then
    echo "system-audio-stimulus: silent carrier PID is missing during probe." >&2
    exit 4
  fi
  if ! /bin/kill -0 "$carrier_pid" 2>/dev/null; then
    fail_silent_carrier_exited
  fi
}

speech_deadline=0
start_speech
speech_deadline=$(( $(/bin/date +%s) + speech_cycle_seconds ))

while true; do
  now=$(/bin/date +%s)

  if marker_token_matches "$cancellation_sidecar" "$run_token"; then
    exit 0
  elif (( ! probe_completed )) && marker_token_matches "$request_sidecar" "$run_token"; then
    stop_speech
    start_silent_carrier
    atomic_touch "$muted_sidecar" "$muted_temporary"

    done_start=$(/bin/date +%s)
    while ! marker_token_matches "$done_sidecar" "$run_token"; do
      if marker_token_matches "$cancellation_sidecar" "$run_token"; then
        exit 0
      fi
      verify_silent_carrier_alive
      now=$(/bin/date +%s)
      if (( now - done_start >= done_wait_limit )); then
        echo "system-audio-stimulus: timed out waiting for probe done sidecar: ${done_sidecar}" >&2
        exit 3
      fi
      /bin/sleep 0.05
    done

    stop_silent_carrier
    remove_marker_if_owned "$request_sidecar"
    remove_marker_if_owned "$muted_sidecar"
    remove_marker_if_owned "$done_sidecar"
    remove_marker_if_owned "$request_temporary"
    remove_marker_if_owned "$muted_temporary"
    remove_marker_if_owned "$done_temporary"
    probe_completed=1
    start_speech
    speech_deadline=$(( $(/bin/date +%s) + speech_cycle_seconds ))
  elif (( ! probe_completed && now - start_epoch >= request_wait_limit )); then
    echo "system-audio-stimulus: timed out waiting for probe request sidecar: ${request_sidecar}" >&2
    exit 2
  elif (( now >= speech_deadline )); then
    stop_speech
    start_speech
    speech_deadline=$(( $(/bin/date +%s) + speech_cycle_seconds ))
  fi

  /bin/sleep 0.05
done
