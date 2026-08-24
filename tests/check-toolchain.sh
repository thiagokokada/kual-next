#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kual-toolchain-test.XXXXXX")
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM
mock_bin="$tmpdir/bin"
log="$tmpdir/curl.log"
mkdir -p "$mock_bin"

cat >"$mock_bin/curl" <<'EOF'
#!/bin/sh
set -eu
printf 'curl\n' >>"$TOOLCHAIN_TEST_LOG"
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then
		printf 'mock archive\n' >"$2"
		exit 0
	fi
	shift
done
exit 2
EOF

cat >"$mock_bin/sha256sum" <<'EOF'
#!/bin/sh
exit "${TOOLCHAIN_TEST_SHA_EXIT:-0}"
EOF

cat >"$mock_bin/tar" <<'EOF'
#!/bin/sh
set -eu
extract_dir=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -C ]; then
		extract_dir=$2
		break
	fi
	shift
done
test -n "$extract_dir"
target=arm-kindlehf-linux-gnueabihf
compiler="$extract_dir/x-tools/$target/bin/$target-gcc"
mkdir -p "$(dirname -- "$compiler")"
cat >"$compiler" <<'COMPILER'
#!/bin/sh
printf 'mock kindlehf compiler\n'
COMPILER
chmod 755 "$compiler"
chmod -R a-w "$extract_dir/x-tools"
EOF

chmod 755 "$mock_bin/curl" "$mock_bin/sha256sum" "$mock_bin/tar"

toolchains="$tmpdir/toolchains"
PATH="$mock_bin:$PATH" TOOLCHAIN_TEST_LOG="$log" KUAL_TC_ROOT="$toolchains" \
	sh "$root/scripts/install-prebuilt-toolchain.sh" >/dev/null
compiler="$toolchains/arm-kindlehf-linux-gnueabihf/bin/arm-kindlehf-linux-gnueabihf-gcc"
test -x "$compiler"
test "$(wc -l <"$log")" -eq 1

PATH="$mock_bin:$PATH" TOOLCHAIN_TEST_LOG="$log" KUAL_TC_ROOT="$toolchains" \
	sh "$root/scripts/install-prebuilt-toolchain.sh" >/dev/null
test "$(wc -l <"$log")" -eq 1

bad_root="$tmpdir/bad-checksum"
if PATH="$mock_bin:$PATH" TOOLCHAIN_TEST_LOG="$log" TOOLCHAIN_TEST_SHA_EXIT=1 \
	KUAL_TC_ROOT="$bad_root" sh "$root/scripts/install-prebuilt-toolchain.sh" \
	>/dev/null 2>&1; then
	echo "toolchain installer accepted a bad checksum" >&2
	exit 1
fi
test ! -e "$bad_root/arm-kindlehf-linux-gnueabihf"

partial_root="$tmpdir/partial"
mkdir -p "$partial_root/arm-kindlehf-linux-gnueabihf"
if PATH="$mock_bin:$PATH" TOOLCHAIN_TEST_LOG="$log" KUAL_TC_ROOT="$partial_root" \
	sh "$root/scripts/install-prebuilt-toolchain.sh" >/dev/null 2>&1; then
	echo "toolchain installer accepted an incomplete destination" >&2
	exit 1
fi

echo "prebuilt toolchain installer tests passed"
