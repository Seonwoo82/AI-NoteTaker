#!/bin/zsh
set -eu

script_name=$0

usage() {
  echo "usage: ${script_name} <absolute-app-path>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 64
fi

app=$1
mode=${MODE-}
seconds=${SECONDS-}
raw_output=${OUTPUT-}
clock=${CLOCK-microphone}

case "${mode}" in
  micOnly|systemOnly|micAndSystem) ;;
  *) echo "Unsupported smoke MODE: ${mode}; expected micOnly, systemOnly, or micAndSystem." >&2; exit 2 ;;
esac
case "${clock}" in
  microphone|output) ;;
  *) echo "Unsupported smoke CLOCK: ${clock}; expected microphone or output." >&2; exit 2 ;;
esac

if [[ -z "${raw_output}" ]]; then
  echo "Unsupported smoke OUTPUT: empty path." >&2
  exit 2
fi

smoke_output=${raw_output:A}
if [[ "${smoke_output}" == "/" ]]; then
  echo "Unsupported smoke OUTPUT: normalized path must not be /." >&2
  exit 2
fi
if [[ -d "${raw_output}" || -d "${smoke_output}" ]]; then
  echo "Unsupported smoke OUTPUT: normalized path is an existing directory: ${smoke_output}" >&2
  exit 2
fi
if [[ -e "${raw_output}" || -L "${raw_output}" || -e "${smoke_output}" || -L "${smoke_output}" ]]; then
  echo "Refusing smoke: output path already exists: ${smoke_output}" >&2
  exit 2
fi

run_token=$(/usr/bin/uuidgen)
export NOTE_TAKER_SMOKE_RUN_TOKEN=${run_token}

claim_sidecar="${smoke_output}.smoke-claim"
request_sidecar="${smoke_output}.probe-request"
muted_sidecar="${smoke_output}.probe-muted"
done_sidecar="${smoke_output}.probe-done"
cancel_sidecar="${smoke_output}.cancel-request"
ack_sidecar="${smoke_output}.cancel-ack"
success_sidecar="${smoke_output}.smoke-success"
fixed_markers=(
  "${claim_sidecar}"
  "${request_sidecar}"
  "${muted_sidecar}"
  "${done_sidecar}"
  "${cancel_sidecar}"
  "${ack_sidecar}"
  "${success_sidecar}"
)
open_pid=""
stimulus_pid=""
app_pid=""
launch_started=0
markers_owned=0
cleanup_publishes_cancel=0
cleanup_failed=0

open_cmd=${SMOKE_OPEN_CMD:-/usr/bin/open}
pgrep_cmd=${SMOKE_PGREP_CMD:-/usr/bin/pgrep}
ps_cmd=${SMOKE_PS_CMD:-/bin/ps}
stimulus_cmd=${SMOKE_STIMULUS_CMD:-scripts/system-audio-stimulus.sh}
audio_stats_cmd=${SMOKE_AUDIO_STATS_CMD:-swift}
ack_timeout_seconds=${SMOKE_CANCEL_ACK_TIMEOUT_SECONDS:-10}
app_name=${SMOKE_APP_PROCESS_NAME:-NoteTaker}
app_process_command=""
app_process_start=""

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

marker_matches() {
  local marker=$1
  [[ -f "${marker}" && ! -L "${marker}" ]] || return 1
  /usr/bin/cmp -s "${marker}" <(/usr/bin/printf '%s' "${run_token}")
}

remove_matching_marker() {
  local marker=$1
  if marker_matches "${marker}"; then
    /bin/rm -f -- "${marker}"
  fi
}

cleanup_owned_artifacts() {
  local marker
  for marker in "${fixed_markers[@]}"; do
    remove_matching_marker "${marker}"
    remove_matching_marker "${marker}.tmp.${run_token}"
  done
}

publish_marker() {
  local marker=$1
  if marker_matches "${marker}"; then
    return 0
  fi
  if path_exists "${marker}"; then
    echo "Refusing smoke: marker is already owned by another run: ${marker}" >&2
    return 1
  fi
  local temporary="${marker}.tmp.${run_token}"
  if path_exists "${temporary}"; then
    echo "Refusing smoke: temporary marker already exists: ${temporary}" >&2
    return 1
  fi
  if ! (set -o noclobber; /usr/bin/printf '%s' "${run_token}" > "${temporary}"); then
    echo "Refusing smoke: failed to create temporary marker without overwrite: ${temporary}" >&2
    return 1
  fi
  if ! /bin/ln "${temporary}" "${marker}" 2>/dev/null; then
    echo "Refusing smoke: failed to publish marker without overwrite: ${marker}" >&2
    return 1
  fi
  remove_matching_marker "${temporary}"
}

publish_cancel_request() {
  publish_marker "${cancel_sidecar}"
}

process_alive() {
  local pid=$1
  [[ -n "${pid}" ]] && /bin/kill -0 "${pid}" 2>/dev/null
}

wait_owned_pid() {
  local pid=$1
  [[ -n "${pid}" ]] || return 0
  set +e
  wait "${pid}" 2>/dev/null
  local child_status=$?
  set -e
  return "${child_status}"
}

terminate_pid() {
  local label=$1
  local pid=$2
  [[ -n "${pid}" ]] || return 0
  if process_alive "${pid}"; then
    echo "Smoke cleanup terminating exact ${label} PID ${pid}." >&2
    /bin/kill "${pid}" 2>/dev/null || true
    local ticks=0
    while process_alive "${pid}" && (( ticks < 100 )); do
      /bin/sleep 0.05
      (( ticks += 1 ))
    done
    if process_alive "${pid}"; then
      /bin/kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi
}

wait_for_matching_ack() {
  local start=$(/bin/date +%s)
  while true; do
    capture_app_pid
    if marker_matches "${ack_sidecar}" || marker_matches "${success_sidecar}"; then
      return 0
    fi
    local now=$(/bin/date +%s)
    if (( now - start >= ack_timeout_seconds )); then
      echo "Smoke cancellation timed out waiting for matching cancel ack or settled success marker." >&2
      return 1
    fi
    /bin/sleep 0.05
  done
}

capture_app_pid() {
  if [[ -n "${app_pid}" ]] && captured_app_identity_is_current; then
    return 0
  fi
  app_pid=""
  app_process_command=""
  app_process_start=""
  set +e
  local pids
  pids=$("${pgrep_cmd}" -x "${app_name}" 2>/dev/null)
  local pgrep_exit=$?
  set -e
  if [[ "${pgrep_exit}" -eq 0 ]]; then
    local words=(${=pids})
    if [[ ${#words[@]} -eq 1 ]]; then
      local candidate=${words[1]}
      local command_name
      local start_identity
      command_name=$("${ps_cmd}" -p "${candidate}" -o comm= 2>/dev/null || true)
      start_identity=$("${ps_cmd}" -p "${candidate}" -o lstart= 2>/dev/null || true)
      if [[ -n "${command_name}" && "${command_name:t}" == "${app_name}" && -n "${start_identity}" ]]; then
        app_pid=${candidate}
        app_process_command=${command_name}
        app_process_start=${start_identity}
      fi
    fi
  fi
}

captured_app_identity_is_current() {
  [[ -n "${app_pid}" && -n "${app_process_command}" && -n "${app_process_start}" ]] || return 1
  process_alive "${app_pid}" || return 1

  local current_pids
  local current_command
  local current_start
  current_pids=$("${pgrep_cmd}" -x "${app_name}" 2>/dev/null || true)
  local words=(${=current_pids})
  [[ ${#words[@]} -eq 1 && "${words[1]}" == "${app_pid}" ]] || return 1
  current_command=$("${ps_cmd}" -p "${app_pid}" -o comm= 2>/dev/null || true)
  current_start=$("${ps_cmd}" -p "${app_pid}" -o lstart= 2>/dev/null || true)
  [[ "${current_command}" == "${app_process_command}" && "${current_start}" == "${app_process_start}" ]]
}

terminate_captured_app() {
  capture_app_pid
  if ! captured_app_identity_is_current; then
    echo "Smoke cleanup could not revalidate the launched app PID; refusing name-only termination." >&2
    return 1
  fi

  local owned_pid=${app_pid}
  echo "Smoke cleanup terminating validated app PID ${owned_pid}." >&2
  /bin/kill "${owned_pid}" 2>/dev/null || true
  local ticks=0
  while process_alive "${owned_pid}" && (( ticks < 100 )); do
    /bin/sleep 0.05
    (( ticks += 1 ))
  done
  if process_alive "${owned_pid}"; then
    if ! captured_app_identity_is_current; then
      echo "Smoke cleanup refused KILL after the captured app identity changed." >&2
      return 1
    fi
    /bin/kill -KILL "${owned_pid}" 2>/dev/null || true
  fi
  app_pid=""
  app_process_command=""
  app_process_start=""
}

stop_stimulus() {
  [[ -n "${stimulus_pid}" ]] || return 0
  local owned_pid=${stimulus_pid}
  stimulus_pid=""
  terminate_pid "stimulus" "${owned_pid}"
  wait_owned_pid "${owned_pid}" || true
}

cleanup() {
  local exit_status=$?
  trap - EXIT
  trap '' HUP INT TERM

  if (( cleanup_publishes_cancel || launch_started )); then
    publish_cancel_request || cleanup_failed=1
    wait_for_matching_ack || {
      cleanup_failed=1
      terminate_captured_app || cleanup_failed=1
      if [[ -n "${open_pid}" ]]; then
        terminate_pid "open" "${open_pid}"
      fi
    }
  fi

  if [[ -n "${open_pid}" ]]; then
    local owned_open_pid=${open_pid}
    open_pid=""
    wait_owned_pid "${owned_open_pid}" || true
  fi

  stop_stimulus || cleanup_failed=1

  if (( markers_owned )); then
    cleanup_owned_artifacts || cleanup_failed=1
  fi

  if (( cleanup_failed && exit_status == 0 )); then
    exit_status=1
  fi
  exit "${exit_status}"
}

exit_for_signal() {
  exit "$1"
}

trap cleanup EXIT
trap 'exit_for_signal 129' HUP
trap 'exit_for_signal 130' INT
trap 'exit_for_signal 143' TERM

set +e
"${pgrep_cmd}" -x "${app_name}" >/dev/null 2>&1
pgrep_status=$?
set -e
if [[ "${pgrep_status}" -eq 0 ]]; then
  echo "Refusing smoke: ${app_name} is already running; quit it before make smoke." >&2
  exit 1
elif [[ "${pgrep_status}" -gt 1 ]]; then
  echo "Refusing smoke: unable to inspect running ${app_name} processes." >&2
  exit 1
fi

for marker in "${fixed_markers[@]}"; do
  if path_exists "${marker}"; then
    echo "Refusing smoke: could not establish sidecar ownership: ${marker}" >&2
    exit 1
  fi
done
markers_owned=1
if ! publish_marker "${claim_sidecar}"; then
  exit 1
fi

if [[ "${mode}" == "systemOnly" || "${mode}" == "micAndSystem" ]]; then
  NOTE_TAKER_SMOKE_RUN_TOKEN="${run_token}" "${stimulus_cmd}" "${smoke_output}" &
  stimulus_pid=$!
fi

launch_started=1
cleanup_publishes_cancel=1
"${open_cmd}" -F -n -W --env "NOTE_TAKER_SMOKE_RUN_TOKEN=${run_token}" "${app}" --args --smoke-record "${seconds}" "${smoke_output}" --mode "${mode}" --clock "${clock}" &
open_pid=$!

local_open_pid=${open_pid}
while process_alive "${local_open_pid}"; do
  capture_app_pid
  /bin/sleep 0.05
done
open_pid=""
set +e
wait "${local_open_pid}" 2>/dev/null
open_status=$?
set -e
if [[ "${open_status}" -ne 0 ]]; then
  echo "NoteTaker LaunchServices smoke exited with status ${open_status}." >&2
  exit "${open_status}"
fi
launch_started=0
cleanup_publishes_cancel=0

if [[ -n "${stimulus_pid}" ]] && ! process_alive "${stimulus_pid}"; then
  owned_stimulus_pid=${stimulus_pid}
  stimulus_pid=""
  set +e
  wait "${owned_stimulus_pid}" 2>/dev/null
  stimulus_status=$?
  set -e
  echo "system audio stimulus exited before smoke cleanup with status ${stimulus_status}." >&2
  if [[ "${stimulus_status}" -eq 0 ]]; then
    stimulus_status=1
  fi
  exit "${stimulus_status}"
fi

test -s "${smoke_output}"
if ! marker_matches "${success_sidecar}"; then
  echo "NoteTaker smoke did not publish a matching success marker: ${success_sidecar}" >&2
  exit 1
fi

if [[ "${audio_stats_cmd}" == "swift" ]]; then
  swift scripts/audio-stats.swift "${smoke_output}" --expect-sample-rate 48000 --expect-channels 2 --expect-duration "${seconds}" --duration-tolerance 1.0 --min-rms-dbfs -50 --min-peak-dbfs -30
else
  "${audio_stats_cmd}" scripts/audio-stats.swift "${smoke_output}" --expect-sample-rate 48000 --expect-channels 2 --expect-duration "${seconds}" --duration-tolerance 1.0 --min-rms-dbfs -50 --min-peak-dbfs -30
fi
