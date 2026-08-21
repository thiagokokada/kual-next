#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

sh -n "$root/assets/KUAL Next.sh"
grep -Fq 'launcher=${KUAL_NEXT_BINARY:-/mnt/us/kual-next/bin/kual-next}' \
	"$root/assets/KUAL Next.sh"
grep -Fq 'extensions=${KUAL_NEXT_EXTENSIONS:-}' "$root/assets/KUAL Next.sh"
grep -Fq 'exec >>"$log" 2>&1' "$root/assets/KUAL Next.sh"

scriptlet_launcher="$tmpdir/scriptlet-launcher"
scriptlet_started="$tmpdir/scriptlet-started"
scriptlet_release="$tmpdir/scriptlet-release"
scriptlet_pipe_closed="$tmpdir/scriptlet-pipe-closed"
cat >"$scriptlet_launcher" <<'MOCK'
#!/bin/sh
touch "$SCRIPTLET_TEST_STARTED"
while [ ! -e "$SCRIPTLET_TEST_RELEASE" ]; do
	sleep 0.05
done
MOCK
chmod 755 "$scriptlet_launcher"
export SCRIPTLET_TEST_STARTED="$scriptlet_started"
export SCRIPTLET_TEST_RELEASE="$scriptlet_release"
KUAL_NEXT_BINARY="$scriptlet_launcher" KUAL_NEXT_LOG="$tmpdir/scriptlet.log" \
	sh "$root/assets/KUAL Next.sh" | {
		cat >/dev/null
		touch "$scriptlet_pipe_closed"
	} &
scriptlet_pid=$!
tries=0
while { [ ! -e "$scriptlet_started" ] || [ ! -e "$scriptlet_pipe_closed" ]; } &&
	[ "$tries" -lt 100 ]; do
	sleep 0.05
	tries=$((tries + 1))
done
test -e "$scriptlet_started"
test -e "$scriptlet_pipe_closed"
touch "$scriptlet_release"
wait "$scriptlet_pid"

if sh "$root/scripts/deploy-kindle.sh" >"$tmpdir/out" 2>"$tmpdir/error"; then
	echo "deployment without arguments unexpectedly succeeded" >&2
	exit 1
fi
grep -q '^Usage:' "$tmpdir/error"

package="$tmpdir/package.zip"
printf 'test package\n' >"$package"
if sh "$root/scripts/deploy-kindle.sh" -invalid "$package" \
		>"$tmpdir/out" 2>"$tmpdir/error"; then
	echo "deployment accepted an option as a host" >&2
	exit 1
fi
grep -q '^Invalid Kindle host:' "$tmpdir/error"

mock_ssh="$tmpdir/ssh"
mock_scp="$tmpdir/scp"
cat >"$mock_ssh" <<'MOCK'
#!/bin/sh
case "$*" in
	*pidof*)
		[ -z "${DEPLOY_TEST_RUNNING:-}" ] || printf '%s\n' "$DEPLOY_TEST_RUNNING"
		;;
	*sha256sum*)
		sha256sum "$DEPLOY_TEST_UPLOAD" | awk '{print $1}'
		;;
	*'/bin/sh -s'*)
		cat >/dev/null
		rm -f "$DEPLOY_TEST_UPLOAD"
		;;
esac
MOCK
cat >"$mock_scp" <<'MOCK'
#!/bin/sh
cp "$1" "$DEPLOY_TEST_UPLOAD"
MOCK
chmod 755 "$mock_ssh" "$mock_scp"
export DEPLOY_TEST_UPLOAD="$tmpdir/upload.zip"

SSH="$mock_ssh" SCP="$mock_scp" \
	sh "$root/scripts/deploy-kindle.sh" test@kindle "$package" \
	>"$tmpdir/out" 2>"$tmpdir/error"
test ! -e "$DEPLOY_TEST_UPLOAD"
grep -q '^Deployed ' "$tmpdir/out"
test ! -s "$tmpdir/error"

export DEPLOY_TEST_RUNNING=123
if SSH="$mock_ssh" SCP="$mock_scp" \
		sh "$root/scripts/deploy-kindle.sh" test@kindle "$package" \
		>"$tmpdir/out" 2>"$tmpdir/error"; then
	echo "deployment over a running launcher unexpectedly succeeded" >&2
	exit 1
fi
grep -q 'KUAL Next is running' "$tmpdir/error"
test ! -e "$DEPLOY_TEST_UPLOAD"

echo "deployment script tests passed"
