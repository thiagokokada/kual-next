#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

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
