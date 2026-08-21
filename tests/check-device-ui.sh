#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

if sh "$root/scripts/test-kindle-ui.sh" >"$tmpdir/out" 2>"$tmpdir/error"; then
	echo "device UI test without a host unexpectedly succeeded" >&2
	exit 1
fi
grep -q '^Usage:' "$tmpdir/error"

binary=$tmpdir/kual-next
printf '#!/bin/sh\nexit 0\n' >"$binary"
chmod 755 "$binary"

mock_ssh=$tmpdir/ssh
mock_scp=$tmpdir/scp
cat >"$mock_ssh" <<'MOCK'
#!/bin/sh
case "$*" in
	*pidof*)
		[ -z "${DEVICE_UI_TEST_RUNNING:-}" ] || printf '%s\n' "$DEVICE_UI_TEST_RUNNING"
		;;
	*sha256sum*)
		sha256sum "$DEVICE_UI_TEST_UPLOAD" | awk '{print $1}'
		;;
	*'/bin/sh -s'*)
		cat >"$DEVICE_UI_TEST_REMOTE_SCRIPT"
		rm -f "$DEVICE_UI_TEST_UPLOAD"
		;;
esac
MOCK
cat >"$mock_scp" <<'MOCK'
#!/bin/sh
unzip -l "$1" >"$DEVICE_UI_TEST_MANIFEST"
cp "$1" "$DEVICE_UI_TEST_UPLOAD"
MOCK
chmod 755 "$mock_ssh" "$mock_scp"

export DEVICE_UI_TEST_UPLOAD=$tmpdir/upload.zip
export DEVICE_UI_TEST_MANIFEST=$tmpdir/manifest
export DEVICE_UI_TEST_REMOTE_SCRIPT=$tmpdir/remote-script

KUAL_TEST_BINARY="$binary" SSH="$mock_ssh" SCP="$mock_scp" \
	sh "$root/scripts/test-kindle-ui.sh" test@kindle \
	>"$tmpdir/out" 2>"$tmpdir/error"
test ! -e "$DEVICE_UI_TEST_UPLOAD"
test ! -s "$tmpdir/error"
grep -q 'kual-next-ui-test/bin/kual-next' "$DEVICE_UI_TEST_MANIFEST"
grep -q 'kual-next-ui-test/extensions/ui-test/menu.json' \
	"$DEVICE_UI_TEST_MANIFEST"
grep -q 'kual-next-ui-test/extensions/ui-test/bin/log-action.sh' \
	"$DEVICE_UI_TEST_MANIFEST"
grep -q 'KUAL_NEXT_BINARY="$root/bin/kual-next"' \
	"$DEVICE_UI_TEST_REMOTE_SCRIPT"
grep -q 'KUAL_NEXT_EXTENSIONS="$root/extensions"' \
	"$DEVICE_UI_TEST_REMOTE_SCRIPT"
grep -q '^Temporary KUAL Next UI test finished' "$tmpdir/out"

export DEVICE_UI_TEST_RUNNING=123
if KUAL_TEST_BINARY="$binary" SSH="$mock_ssh" SCP="$mock_scp" \
		sh "$root/scripts/test-kindle-ui.sh" test@kindle \
		>"$tmpdir/out" 2>"$tmpdir/error"; then
	echo "device UI test accepted a running launcher" >&2
	exit 1
fi
grep -q 'KUAL Next is running' "$tmpdir/error"
test ! -e "$DEVICE_UI_TEST_UPLOAD"

echo "device UI test runner tests passed"
