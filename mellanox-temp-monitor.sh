#!/usr/bin/env bash

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/default/mellanox-temp-monitor}"
CHECK_ONCE=0

for arg in "$@"; do
    case "$arg" in
        --check-once)
            CHECK_ONCE=1
            ;;
        *)
            printf 'Unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# Snapshot caller-provided env vars so they survive config-file sourcing.
# ${VAR+x} is non-empty only when VAR is set, which avoids tripping set -u.
declare -A _env_snapshot=()
for _v in MGET_TEMP_BIN MST_BIN DEVICES THRESHOLD_C POLL_INTERVAL_SEC \
         REMINDER_INTERVAL_SEC SYSLOG_TAG SYSLOG_FACILITY MST_AUTOSTART \
         DEBUG_STDERR; do
    [[ -n "${!_v+x}" ]] && _env_snapshot[$_v]="${!_v}"
done

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Restore: env vars take precedence over config-file values.
for _v in "${!_env_snapshot[@]}"; do
    printf -v "$_v" '%s' "${_env_snapshot[$_v]}"
done
unset _env_snapshot _v

MGET_TEMP_BIN="${MGET_TEMP_BIN:-mget_temp}"
MST_BIN="${MST_BIN:-mst}"
DEVICES="${DEVICES:-${MST_DEVICE:-}}"
THRESHOLD_C="${THRESHOLD_C:-80}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-60}"
REMINDER_INTERVAL_SEC="${REMINDER_INTERVAL_SEC:-900}"
SYSLOG_TAG="${SYSLOG_TAG:-mellanox-temp-monitor}"
SYSLOG_FACILITY="${SYSLOG_FACILITY:-daemon}"
MST_AUTOSTART="${MST_AUTOSTART:-1}"
DEBUG_STDERR="${DEBUG_STDERR:-0}"

declare -A ALERT_ACTIVE=()
declare -A LAST_ALERT_EPOCH=()
declare -A READ_FAILURE_ACTIVE=()

log_message() {
    local priority="$1"
    local message="$2"

    logger -p "${SYSLOG_FACILITY}.${priority}" -t "$SYSLOG_TAG" -- "$message"
    if [[ "$DEBUG_STDERR" == "1" ]]; then
        printf '[%s] %s\n' "$priority" "$message" >&2
    fi
}

require_integer() {
    local name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        printf '%s must be an integer. Got: %s\n' "$name" "$value" >&2
        exit 1
    fi
}

require_integer_at_least() {
    local name="$1"
    local value="$2"
    local minimum="$3"

    require_integer "$name" "$value"

    if (( value < minimum )); then
        printf '%s must be >= %s. Got: %s\n' "$name" "$minimum" "$value" >&2
        exit 1
    fi
}

require_number() {
    local name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s must be numeric. Got: %s\n' "$name" "$value" >&2
        exit 1
    fi
}

ensure_prerequisites() {
    require_number "THRESHOLD_C" "$THRESHOLD_C"
    require_integer_at_least "POLL_INTERVAL_SEC" "$POLL_INTERVAL_SEC" 1
    require_integer "REMINDER_INTERVAL_SEC" "$REMINDER_INTERVAL_SEC"

    if [[ -z "$DEVICES" ]]; then
        printf 'Set DEVICES in %s to one or more /dev/mst/* device paths.\n' "$CONFIG_FILE" >&2
        exit 1
    fi

    if ! command -v "$MGET_TEMP_BIN" >/dev/null 2>&1; then
        printf 'Unable to find %s in PATH.\n' "$MGET_TEMP_BIN" >&2
        exit 1
    fi
}

start_mst_if_needed() {
    if [[ "$MST_AUTOSTART" != "1" ]]; then
        return 0
    fi

    if ! command -v "$MST_BIN" >/dev/null 2>&1; then
        log_message err "MST_AUTOSTART=1 but '${MST_BIN}' is not available"
        return 1
    fi

    if "$MST_BIN" start >/dev/null 2>&1; then
        log_message info "Started Mellanox MST service"
        return 0
    fi

    log_message err "Failed to start Mellanox MST service with '${MST_BIN} start'"
    return 1
}

parse_temperature() {
    local output="$1"
    local normalized
    local -a matches=()

    normalized="$(printf '%s' "$output" | tr -d '[:space:]')"

    if [[ "$normalized" =~ ^-?[0-9]+$ ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi

    while IFS= read -r line; do
        matches+=("$line")
    done < <(printf '%s\n' "$output" | grep -Eo '(-?[0-9]+)[[:space:]]*[Cc]([^[:alpha:]]|$)' | grep -Eo '^-?[0-9]+' || true)

    if (( ${#matches[@]} == 1 )); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi

    return 1
}

temperature_at_or_above_threshold() {
    local current="$1"
    awk -v current="$current" -v threshold="$THRESHOLD_C" 'BEGIN { exit !(current >= threshold) }'
}

read_temperature() {
    local device="$1"
    local command_output
    local parsed_temperature

    if ! command_output="$($MGET_TEMP_BIN -d "$device" 2>&1)"; then
        printf 'command failed: %s\n' "$command_output" >&2
        return 1
    fi

    if ! parsed_temperature="$(parse_temperature "$command_output")"; then
        printf 'unable to parse temperature from output: %s\n' "$command_output" >&2
        return 1
    fi

    printf '%s\n' "$parsed_temperature"
}

handle_read_failure() {
    local device="$1"
    local reason="$2"

    if [[ "${READ_FAILURE_ACTIVE[$device]:-0}" == "0" ]]; then
        log_message err "Unable to read Mellanox temperature for ${device}: ${reason}"
        READ_FAILURE_ACTIVE[$device]=1
    fi
}

handle_read_recovery() {
    local device="$1"
    if [[ "${READ_FAILURE_ACTIVE[$device]:-0}" == "1" ]]; then
        log_message info "Recovered temperature reads for ${device}"
        READ_FAILURE_ACTIVE[$device]=0
    fi
}

check_device() {
    local device="$1"
    local current_temp
    local now_epoch

    if ! current_temp="$(read_temperature "$device" 2>&1)"; then
        handle_read_failure "$device" "$current_temp"
        return 0
    fi

    handle_read_recovery "$device"

    if temperature_at_or_above_threshold "$current_temp"; then
        now_epoch="$(date +%s)"
        if [[ "${ALERT_ACTIVE[$device]:-0}" == "0" ]]; then
            log_message warning "Mellanox device ${device} temperature is ${current_temp}C (threshold ${THRESHOLD_C}C)"
            ALERT_ACTIVE[$device]=1
            LAST_ALERT_EPOCH[$device]="$now_epoch"
            return 0
        fi

        if (( REMINDER_INTERVAL_SEC > 0 )) && (( now_epoch - ${LAST_ALERT_EPOCH[$device]:-0} >= REMINDER_INTERVAL_SEC )); then
            log_message warning "Mellanox device ${device} temperature remains high at ${current_temp}C (threshold ${THRESHOLD_C}C)"
            LAST_ALERT_EPOCH[$device]="$now_epoch"
        fi
        return 0
    fi

    if [[ "${ALERT_ACTIVE[$device]:-0}" == "1" ]]; then
        log_message notice "Mellanox device ${device} temperature recovered to ${current_temp}C (threshold ${THRESHOLD_C}C)"
    fi

    ALERT_ACTIVE[$device]=0
    LAST_ALERT_EPOCH[$device]=0
}

main() {
    local device
    local mst_ready=0
    local mst_retry_after=0
    local now_epoch

    ensure_prerequisites

    if [[ "$MST_AUTOSTART" == "1" ]]; then
        if start_mst_if_needed; then
            mst_ready=1
        fi
    fi

    local -a devices_array=()
    read -r -a devices_array <<< "$DEVICES"

    while true; do
        now_epoch="$(date +%s)"
        for device in "${devices_array[@]}"; do
            if [[ ! -e "$device" && "$MST_AUTOSTART" == "1" && "$now_epoch" -ge "$mst_retry_after" ]]; then
                if start_mst_if_needed; then
                    mst_ready=1
                    mst_retry_after=0
                else
                    mst_ready=0
                    mst_retry_after=$(( now_epoch + POLL_INTERVAL_SEC ))
                fi
            fi
            check_device "$device"
        done

        if (( CHECK_ONCE == 1 )); then
            break
        fi

        sleep "$POLL_INTERVAL_SEC"
    done
}

main
