#!/bin/sh
# Name: KUAL Next
# Author: KUAL Next contributors
# Icon: /mnt/us/kual-next/icon.png

set -u

log=/var/tmp/kual-next.log
statusbar_owned=0
child_pid=

log_message() {
    printf '%s\n' "$*" >>"$log"
}

statusbar_running() {
    /sbin/status statusbar 2>/dev/null | grep -q 'start/running'
}

restore_statusbar() {
	if [ "$statusbar_owned" -eq 1 ]; then
		if ! statusbar_running; then
			/sbin/start statusbar >>"$log" 2>&1 ||
				log_message "failed to restore Kindle statusbar"
		fi
		statusbar_owned=0
	fi
}

terminate_child() {
	if [ -n "$child_pid" ]; then
		kill -TERM "$child_pid" 2>/dev/null || :
	fi
}

trap terminate_child HUP INT TERM
trap restore_statusbar EXIT

if [ -f /etc/upstart/statusbar.conf ] && statusbar_running; then
	if /sbin/stop statusbar >>"$log" 2>&1; then
		statusbar_owned=1
		export KUAL_NEXT_STATUSBAR_STOPPED=1
	else
		log_message "failed to stop Kindle statusbar"
	fi
fi

/mnt/us/kual-next/bin/kual-next &
child_pid=$!
run_status=0
while :; do
	wait "$child_pid"
	run_status=$?
	if ! kill -0 "$child_pid" 2>/dev/null; then
		break
	fi
done
child_pid=

restore_statusbar
trap - EXIT
exit "$run_status"
