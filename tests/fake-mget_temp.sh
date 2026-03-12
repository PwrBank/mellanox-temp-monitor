#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" != "-d" || -z "${2:-}" ]]; then
    printf 'usage: fake-mget_temp.sh -d <device>\n' >&2
    exit 1
fi

case "$2" in
    /dev/mst/hot0)
        printf '68\n'
        ;;
    /dev/mst/cool0)
        printf '41\n'
        ;;
    /dev/mst/text0)
        printf 'Device temperature: 83 C\n'
        ;;
    /dev/mst/ambiguous0)
        printf '71 C\n83 C\n'
        ;;
    *)
        printf 'Unknown device %s\n' "$2" >&2
        exit 1
        ;;
esac
