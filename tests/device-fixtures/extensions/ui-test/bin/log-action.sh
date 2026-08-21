#!/bin/sh

log=/var/tmp/kual-next-ui-test.log
timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)
printf '%s cwd=%s action=%s\n' "$timestamp" "$PWD" "$*" >>"$log"
printf 'KUAL Next UI test stderr: %s\n' "$*" >&2
