#!/bin/sh
set -eu

: "${KUAL_TC_ROOT:?KUAL_TC_ROOT must name the project-local toolchain directory}"

release=2026.08
archive_name=kindlehf.tar.zst
archive_sha256=8cc7dfbd71abd78f9e947d6b2e20670288a4402edc7b07176bca791f7eaf87d0
target=arm-kindlehf-linux-gnueabihf
download_url="https://github.com/koreader/koxtoolchain/releases/download/$release/$archive_name"
toolchain_dir="$KUAL_TC_ROOT/$target"
compiler="$toolchain_dir/bin/$target-gcc"
stamp="$toolchain_dir/.kual-next-koxtoolchain"
stamp_value="$release $archive_sha256"

if [ -x "$compiler" ] && [ -f "$stamp" ] &&
    [ "$(cat "$stamp")" = "$stamp_value" ]; then
	"$compiler" --version | head -n 1
	exit 0
fi

if [ -e "$toolchain_dir" ] || [ -L "$toolchain_dir" ]; then
	printf 'Toolchain directory exists but is not the pinned %s release: %s\n' \
		"$release" "$toolchain_dir" >&2
	printf 'Move it aside or choose an empty TC_ROOT, then retry.\n' >&2
	exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/kual-next-toolchain.XXXXXX")
trap 'rm -rf "$stage"' 0 HUP INT TERM
archive="$stage/$archive_name"
extract_dir="$stage/extract"

curl -L --fail --silent --show-error "$download_url" -o "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c -

mkdir -p "$extract_dir"
tar --zstd -xf "$archive" -C "$extract_dir"
staged_toolchain="$extract_dir/x-tools/$target"
staged_compiler="$staged_toolchain/bin/$target-gcc"
if [ ! -x "$staged_compiler" ]; then
	printf 'Archive does not contain the expected compiler: %s\n' \
		"x-tools/$target/bin/$target-gcc" >&2
	exit 1
fi

printf '%s\n' "$stamp_value" >"$staged_toolchain/.kual-next-koxtoolchain"
mkdir -p "$KUAL_TC_ROOT"
mv "$staged_toolchain" "$toolchain_dir"
"$compiler" --version | head -n 1
