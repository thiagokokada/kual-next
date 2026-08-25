#!/bin/sh
# Name: KUAL Next
# Author: KUAL Next contributors
# Icon: /mnt/us/kual-next/icon.png
# DontUseFBInk

set -u

log=${KUAL_NEXT_LOG:-/var/tmp/kual-next.log}
launcher=${KUAL_NEXT_BINARY:-/mnt/us/kual-next/bin/kual-next}
extensions=${KUAL_NEXT_EXTENSIONS:-}
return_marker=/var/tmp/kual-next-return-to-koreader
statusbar_conf=${KUAL_NEXT_STATUSBAR_CONF:-/etc/upstart/statusbar.conf}
status_command=${KUAL_NEXT_STATUS_COMMAND:-/sbin/status}
start_command=${KUAL_NEXT_START_COMMAND:-/sbin/start}
stop_command=${KUAL_NEXT_STOP_COMMAND:-/sbin/stop}
lipc_set_prop=${KUAL_NEXT_LIPC_SET_PROP:-/usr/bin/lipc-set-prop}
killall_command=${KUAL_NEXT_KILLALL:-/usr/bin/killall}
pidof_command=${KUAL_NEXT_PIDOF:-/usr/bin/pidof}
proc_root=${KUAL_NEXT_PROC_ROOT:-/proc}
return_to_koreader=0
statusbar_owned=0
pillow_owned=0
awesome_owned=0
child_pid=

log_message() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log"
}

statusbar_running() {
	"$status_command" statusbar 2>/dev/null | grep -q 'start/running'
}

restore_statusbar() {
	if [ "$statusbar_owned" -eq 1 ]; then
		if statusbar_running ||
			"$start_command" statusbar >>"$log" 2>&1; then
			statusbar_owned=0
		else
			log_message "failed to restore Kindle statusbar"
		fi
	fi
}

awesome_running() {
	for pid in $("$pidof_command" awesome 2>/dev/null); do
		case "$pid" in
			*[!0-9]*) continue ;;
		esac
		state=$(awk '{ print $3 }' "$proc_root/$pid/stat" 2>/dev/null || :)
		case "$state" in
			T | t) ;;
			*) return 0 ;;
		esac
	done
	return 1
}

restore_framework() {
	if [ "$awesome_owned" -eq 1 ]; then
		if "$killall_command" -CONT awesome >>"$log" 2>&1; then
			awesome_owned=0
		else
			log_message "failed to resume Kindle Awesome window manager"
		fi
	fi
	if [ "$pillow_owned" -eq 1 ]; then
		if "$lipc_set_prop" com.lab126.pillow disableEnablePillow enable \
			>>"$log" 2>&1; then
			pillow_owned=0
		else
			log_message "failed to restore Kindle Pillow"
		fi
	fi
	restore_statusbar
}

# Invoked indirectly by the EXIT/HUP/INT/TERM trap below.
# shellcheck disable=SC2329
terminate_child() {
	if [ -n "$child_pid" ]; then
		kill -TERM "$child_pid" 2>/dev/null || :
	fi
}

trap terminate_child HUP INT TERM
trap restore_framework EXIT

if [ -f "$return_marker" ]; then
	rm -f "$return_marker"
	return_to_koreader=1
fi

if [ -f "$statusbar_conf" ] && statusbar_running; then
	if "$stop_command" statusbar >>"$log" 2>&1; then
		statusbar_owned=1
		export KUAL_NEXT_STATUSBAR_STOPPED=1
	else
		log_message "failed to stop Kindle statusbar"
	fi
fi

# On supported firmware Pillow owns Amazon chrome while Awesome manages the
# framework's X11 windows. Only claim their lifecycle when Awesome was running
# when the scriptlet started, so an already-paused framework remains untouched.
if awesome_running; then
	if "$lipc_set_prop" com.lab126.pillow disableEnablePillow disable \
		>>"$log" 2>&1; then
		pillow_owned=1
		export KUAL_NEXT_PILLOW_DISABLED=1
	else
		log_message "failed to disable Kindle Pillow"
	fi
	if "$killall_command" -STOP awesome >>"$log" 2>&1; then
		awesome_owned=1
		export KUAL_NEXT_AWESOME_STOPPED=1
	else
		log_message "failed to pause Kindle Awesome window manager"
	fi
fi

if [ -n "$extensions" ]; then
	"$launcher" --extensions "$extensions" &
else
	"$launcher" &
fi
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

restore_framework
if [ "$awesome_owned" -ne 0 ] || [ "$pillow_owned" -ne 0 ] ||
	[ "$statusbar_owned" -ne 0 ]; then
	log_message "Kindle framework restoration incomplete; aborting handoff"
	exit 125
fi
trap - EXIT

if [ "$return_to_koreader" -eq 1 ]; then
	if [ -x /mnt/us/koreader/koreader.sh ]; then
		log_message "KUAL Next stopped; relaunching KOReader"
		cd /mnt/us/koreader || exit "$run_status"
		exec /mnt/us/koreader/koreader.sh --asap
	fi
	log_message "cannot relaunch KOReader: launcher is missing"
fi

exit "$run_status"
