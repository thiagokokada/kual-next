#!/bin/sh

set -eu

host=${1:-}
ssh_bin=${SSH:-ssh}
scp_bin=${SCP:-scp}
ssh_args=${SSH_ARGS:-}
scp_args=${SCP_ARGS:-}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary=${KUAL_TEST_BINARY:-$root/build/kindle/kual-next}
supervisor=$root/assets/KUAL\ Next.sh
fixture=$root/tests/device-fixtures/extensions
remote_root=/tmp/kual-next-ui-test
remote_archive=/tmp/kual-next-ui-test.zip
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

run_ssh() {
	"$ssh_bin" $ssh_args "$@"
}

run_scp() {
	"$scp_bin" $scp_args "$@"
}

if [ -z "$host" ]; then
	printf 'Usage: %s USER@HOST\n' "$0" >&2
	exit 2
fi
case "$host" in
	-*)
		printf 'Invalid Kindle host: %s\n' "$host" >&2
		exit 2
		;;
esac
if [ ! -x "$binary" ]; then
	printf 'Kindle binary not found: %s (run make kindle first)\n' "$binary" >&2
	exit 2
fi

running=$(
	run_ssh "$host" \
		'pidof kual-next 2>/dev/null || true'
)
if [ -n "$running" ]; then
	printf 'KUAL Next is running on %s (PID%s %s). Quit it before testing.\n' \
		"$host" "$(printf '%s' "$running" | grep -q ' ' && printf 's' || true)" \
		"$running" >&2
	exit 1
fi

stage=$tmpdir/kual-next-ui-test
mkdir -p "$stage/bin"
cp "$binary" "$stage/bin/kual-next"
cp "$supervisor" "$stage/KUAL Next.sh"
cp -R "$fixture" "$stage/extensions"
(cd "$tmpdir" && zip -X -q -r "$tmpdir/kual-next-ui-test.zip" kual-next-ui-test)

archive=$tmpdir/kual-next-ui-test.zip
local_hash=$(sha256sum "$archive" | awk '{print $1}')
run_scp "$archive" "${host}:${remote_archive}"
remote_checksum=$(
	run_ssh "$host" "sha256sum '$remote_archive'"
)
remote_hash=${remote_checksum%% *}
if [ "$local_hash" != "$remote_hash" ]; then
	printf 'Upload checksum mismatch: local=%s remote=%s\n' \
		"$local_hash" "$remote_hash" >&2
	exit 1
fi

printf 'Opening temporary KUAL Next UI test on %s.\n' "$host"
printf 'Quit the launcher to end this command and remove %s.\n' "$remote_root"
printf 'Action log: /var/tmp/kual-next-ui-test.log\n'

run_ssh "$host" /bin/sh -s <<'REMOTE'
set -eu

root=/tmp/kual-next-ui-test
archive=/tmp/kual-next-ui-test.zip

cleanup() {
	rm -rf "$root"
	rm -f "$archive"
}
trap cleanup EXIT HUP INT TERM

running=$(pidof kual-next 2>/dev/null || true)
if [ -n "$running" ]; then
	printf 'KUAL Next started before the UI test (PID%s). Aborting.\n' "$running" >&2
	exit 1
fi

rm -rf "$root"
unzip -oq "$archive" -d /tmp
rm -f "$archive"
chmod 755 "$root/bin/kual-next" "$root/KUAL Next.sh" \
	"$root/extensions/ui-test/bin/log-action.sh"
: >/var/tmp/kual-next-ui-test.log

KUAL_NEXT_BINARY="$root/bin/kual-next" \
KUAL_NEXT_EXTENSIONS="$root/extensions" \
	/bin/sh "$root/KUAL Next.sh"
REMOTE

printf 'Temporary KUAL Next UI test finished and staged files were removed.\n'
