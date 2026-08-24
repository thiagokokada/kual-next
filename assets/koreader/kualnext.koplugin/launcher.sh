#!/bin/sh

set -u

log=/var/tmp/kual-next.log
koreader_dir=${KUAL_NEXT_KOREADER_DIR:-/mnt/us/koreader}
kual_launcher=${KUAL_NEXT_DOCUMENT_LAUNCHER:-/mnt/us/documents/KUAL Next.sh}

log_message() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log"
}

# reader.lua exits before KOReader's Kindle wrapper has resumed Awesome and
# Pillow. Wait for the wrapper too, otherwise those late framework redraws can
# overwrite KUAL Next after it has already opened.
while pidof reader.lua >/dev/null 2>&1 || pidof koreader.sh >/dev/null 2>&1; do
	sleep 1
done

# The wrapper starts Home asynchronously while restoring Pillow. Give that
# repaint time to settle, then clear it with a flashing full-screen refresh.
sleep 2
if [ -x "$koreader_dir/fbink" ]; then
	"$koreader_dir/fbink" -q -c -f >>"$log" 2>&1 ||
		log_message "failed to clear the screen before KUAL Next"
fi

log_message "KOReader stopped; opening KUAL Next"
if [ -x "$kual_launcher" ]; then
	"$kual_launcher" >>"$log" 2>&1
	launch_status=$?
else
	log_message "KUAL Next launcher is missing: $kual_launcher"
	launch_status=127
fi
log_message "KUAL Next stopped; relaunching KOReader"

if [ ! -x "$koreader_dir/koreader.sh" ]; then
	log_message "KOReader launcher is missing: $koreader_dir/koreader.sh"
	exit "$launch_status"
fi

cd "$koreader_dir" || exit "$launch_status"
exec "$koreader_dir/koreader.sh"
