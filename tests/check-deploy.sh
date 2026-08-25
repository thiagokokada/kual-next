#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

sh -n "$root/assets/KUAL Next.sh"
grep -Fq 'launcher=${KUAL_NEXT_BINARY:-/mnt/us/kual-next/bin/kual-next}' \
	"$root/assets/KUAL Next.sh"
grep -Fq 'extensions=${KUAL_NEXT_EXTENSIONS:-}' "$root/assets/KUAL Next.sh"
grep -Fxq '# DontUseFBInk' "$root/assets/KUAL Next.sh"
grep -Fq 'return_marker=/var/tmp/kual-next-return-to-koreader' "$root/assets/KUAL Next.sh"
grep -Fq 'exec /mnt/us/koreader/koreader.sh --asap' "$root/assets/KUAL Next.sh"
grep -Fq 'KUAL_NEXT_PILLOW_DISABLED=1' "$root/assets/KUAL Next.sh"
grep -Fq 'KUAL_NEXT_AWESOME_STOPPED=1' "$root/assets/KUAL Next.sh"

lifecycle="$tmpdir/lifecycle"
mkdir -p "$lifecycle/proc/321"
touch "$lifecycle/statusbar.conf"
printf 'running\n' >"$lifecycle/statusbar"
printf '321 (awesome) S 0 0 0\n' >"$lifecycle/proc/321/stat"
: >"$lifecycle/events"

cat >"$lifecycle/status" <<'MOCK'
#!/bin/sh
if [ "$(cat "$KUAL_LIFECYCLE_STATE/statusbar")" = running ]; then
	printf '%s\n' 'statusbar start/running'
else
	printf '%s\n' 'statusbar stop/waiting'
fi
MOCK
cat >"$lifecycle/start" <<'MOCK'
#!/bin/sh
printf 'running\n' >"$KUAL_LIFECYCLE_STATE/statusbar"
printf '%s\n' 'statusbar:start' >>"$KUAL_LIFECYCLE_STATE/events"
MOCK
cat >"$lifecycle/stop" <<'MOCK'
#!/bin/sh
printf 'stopped\n' >"$KUAL_LIFECYCLE_STATE/statusbar"
printf '%s\n' 'statusbar:stop' >>"$KUAL_LIFECYCLE_STATE/events"
MOCK
cat >"$lifecycle/lipc-set-prop" <<'MOCK'
#!/bin/sh
test "$1" = com.lab126.pillow
test "$2" = disableEnablePillow
printf 'pillow:%s\n' "$3" >>"$KUAL_LIFECYCLE_STATE/events"
MOCK
cat >"$lifecycle/killall" <<'MOCK'
#!/bin/sh
test "$2" = awesome
case "$1" in
	-STOP) state=T ;;
	-CONT) state=S ;;
	*) exit 2 ;;
esac
printf '321 (awesome) %s 0 0 0\n' "$state" \
	>"$KUAL_LIFECYCLE_STATE/proc/321/stat"
printf 'awesome:%s\n' "$1" >>"$KUAL_LIFECYCLE_STATE/events"
MOCK
cat >"$lifecycle/pidof" <<'MOCK'
#!/bin/sh
test "$1" = awesome
printf '%s\n' 321
MOCK
cat >"$lifecycle/launcher" <<'MOCK'
#!/bin/sh
printf 'launcher:%s:%s:%s\n' "${KUAL_NEXT_STATUSBAR_STOPPED:-}" \
	"${KUAL_NEXT_PILLOW_DISABLED:-}" "${KUAL_NEXT_AWESOME_STOPPED:-}" \
	>>"$KUAL_LIFECYCLE_STATE/events"
[ "${KUAL_LIFECYCLE_CRASH:-0}" -eq 0 ] || kill -KILL "$$"
MOCK
chmod 755 "$lifecycle/status" "$lifecycle/start" "$lifecycle/stop" \
	"$lifecycle/lipc-set-prop" "$lifecycle/killall" "$lifecycle/pidof" \
	"$lifecycle/launcher"

KUAL_LIFECYCLE_STATE="$lifecycle" \
	KUAL_NEXT_BINARY="$lifecycle/launcher" \
	KUAL_NEXT_LOG="$lifecycle/kual-next.log" \
	KUAL_NEXT_STATUSBAR_CONF="$lifecycle/statusbar.conf" \
	KUAL_NEXT_STATUS_COMMAND="$lifecycle/status" \
	KUAL_NEXT_START_COMMAND="$lifecycle/start" \
	KUAL_NEXT_STOP_COMMAND="$lifecycle/stop" \
	KUAL_NEXT_LIPC_SET_PROP="$lifecycle/lipc-set-prop" \
	KUAL_NEXT_KILLALL="$lifecycle/killall" \
	KUAL_NEXT_PIDOF="$lifecycle/pidof" \
	KUAL_NEXT_PROC_ROOT="$lifecycle/proc" \
	sh "$root/assets/KUAL Next.sh"

cat >"$lifecycle/expected" <<'EOF'
statusbar:stop
pillow:disable
awesome:-STOP
launcher:1:1:1
awesome:-CONT
pillow:enable
statusbar:start
EOF
cmp "$lifecycle/expected" "$lifecycle/events"
test "$(cat "$lifecycle/statusbar")" = running
grep -q ') S ' "$lifecycle/proc/321/stat"

# Preserve a framework that was already suppressed by another owner.
printf 'stopped\n' >"$lifecycle/statusbar"
printf '321 (awesome) T 0 0 0\n' >"$lifecycle/proc/321/stat"
: >"$lifecycle/events"
KUAL_LIFECYCLE_STATE="$lifecycle" \
	KUAL_NEXT_BINARY="$lifecycle/launcher" \
	KUAL_NEXT_LOG="$lifecycle/kual-next.log" \
	KUAL_NEXT_STATUSBAR_CONF="$lifecycle/statusbar.conf" \
	KUAL_NEXT_STATUS_COMMAND="$lifecycle/status" \
	KUAL_NEXT_START_COMMAND="$lifecycle/start" \
	KUAL_NEXT_STOP_COMMAND="$lifecycle/stop" \
	KUAL_NEXT_LIPC_SET_PROP="$lifecycle/lipc-set-prop" \
	KUAL_NEXT_KILLALL="$lifecycle/killall" \
	KUAL_NEXT_PIDOF="$lifecycle/pidof" \
	KUAL_NEXT_PROC_ROOT="$lifecycle/proc" \
	sh "$root/assets/KUAL Next.sh"
printf '%s\n' 'launcher:::' >"$lifecycle/expected-idle"
cmp "$lifecycle/expected-idle" "$lifecycle/events"
test "$(cat "$lifecycle/statusbar")" = stopped
grep -q ') T ' "$lifecycle/proc/321/stat"

# A launcher crash still returns every component to its original state.
printf 'running\n' >"$lifecycle/statusbar"
printf '321 (awesome) S 0 0 0\n' >"$lifecycle/proc/321/stat"
: >"$lifecycle/events"
if KUAL_LIFECYCLE_STATE="$lifecycle" KUAL_LIFECYCLE_CRASH=1 \
	KUAL_NEXT_BINARY="$lifecycle/launcher" \
	KUAL_NEXT_LOG="$lifecycle/kual-next.log" \
	KUAL_NEXT_STATUSBAR_CONF="$lifecycle/statusbar.conf" \
	KUAL_NEXT_STATUS_COMMAND="$lifecycle/status" \
	KUAL_NEXT_START_COMMAND="$lifecycle/start" \
	KUAL_NEXT_STOP_COMMAND="$lifecycle/stop" \
	KUAL_NEXT_LIPC_SET_PROP="$lifecycle/lipc-set-prop" \
	KUAL_NEXT_KILLALL="$lifecycle/killall" \
	KUAL_NEXT_PIDOF="$lifecycle/pidof" \
	KUAL_NEXT_PROC_ROOT="$lifecycle/proc" \
	sh "$root/assets/KUAL Next.sh" 2>/dev/null; then
	echo "crashed launcher unexpectedly succeeded" >&2
	exit 1
fi
cmp "$lifecycle/expected" "$lifecycle/events"
test "$(cat "$lifecycle/statusbar")" = running
grep -q ') S ' "$lifecycle/proc/321/stat"

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
