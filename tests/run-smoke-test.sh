#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash -n "${PROJECT_DIR}/mellanox-temp-monitor.sh"

run_case() {
    local devices="$1"
    local threshold="$2"
    local expected="$3"
    local should_contain="$4"
    local output
    local status
    local expected_exit="${5:-0}"

    set +e
    output="$({
        CONFIG_FILE=/dev/null \
        DEVICES="$devices" \
        THRESHOLD_C="$threshold" \
        POLL_INTERVAL_SEC=1 \
        REMINDER_INTERVAL_SEC=0 \
        MST_AUTOSTART=0 \
        DEBUG_STDERR=1 \
        MGET_TEMP_BIN="${SCRIPT_DIR}/fake-mget_temp.sh" \
        bash "${PROJECT_DIR}/mellanox-temp-monitor.sh" --check-once
    } 2>&1)"
    status=$?
    set -e

    if [[ "$status" != "$expected_exit" ]]; then
        printf 'Expected exit code %s but got %s with output:\n%s\n' "$expected_exit" "$status" "$output" >&2
        exit 1
    fi

    if [[ "$should_contain" == "1" && "$output" != *"$expected"* ]]; then
        printf 'Expected output to contain %s but got:\n%s\n' "$expected" "$output" >&2
        exit 1
    fi

    if [[ "$should_contain" == "0" && -n "$expected" && "$output" == *"$expected"* ]]; then
        printf 'Expected output not to contain %s but got:\n%s\n' "$expected" "$output" >&2
        exit 1
    fi
}

run_case "/dev/mst/hot0" 60 "temperature is 68C" 1
run_case "/dev/mst/cool0" 60 "temperature is" 0
run_case "/dev/mst/text0" 80 "temperature is 83C" 1
run_case "/dev/mst/ambiguous0" 80 "unable to parse temperature" 1

printf 'Smoke tests passed.\n'
