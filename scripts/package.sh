#!/bin/sh

set -eu

version=${1:-}
binary=${2:-}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package="$root/dist/kual-next-$version-kindlehf.zip"
stage=$(mktemp -d "${TMPDIR:-/tmp}/kual-next-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

if [ -z "$version" ] || [ -z "$binary" ]; then
	printf 'Usage: %s VERSION KINDLE_BINARY\n' "$0" >&2
	exit 2
fi
if [ ! -x "$binary" ]; then
	printf 'Kindle binary not found or not executable: %s\n' "$binary" >&2
	exit 2
fi

mkdir -p "$stage/kual-next/bin" "$stage/kual-next/fonts" \
	"$stage/kual-next/LICENSES" "$stage/documents" "$root/dist"
cp "$binary" "$stage/kual-next/bin/kual-next"
cp "$root/LICENSE" "$stage/kual-next/LICENSES/KUAL-Next-GPL-3.0-or-later.txt"
cp "$root/third_party/YXML-LICENSE" "$stage/kual-next/LICENSES/yxml-MIT.txt"
cp "$root/third_party/MUSL-COPYRIGHT" "$stage/kual-next/LICENSES/musl-MIT.txt"
cp "$root/assets/fonts/OFL.txt" "$stage/kual-next/LICENSES/Noto-SIL-OFL-1.1.txt"
cp "$root/third_party/FBInk/LICENSE" "$stage/kual-next/LICENSES/FBInk-GPL-3.0-or-later.txt"
cp "$root/assets/fonts/NotoSans.ttf" "$stage/kual-next/fonts/NotoSans.ttf"
cp "$root/assets/fonts/NotoSansSymbols.ttf" "$stage/kual-next/fonts/NotoSansSymbols.ttf"
cp "$root/assets/fonts/NotoSansSymbols2-Regular.otf" "$stage/kual-next/fonts/NotoSansSymbols2-Regular.otf"
cp "$root/assets/icons/kual-next.png" "$stage/kual-next/icon.png"
cp "$root/assets/KUAL Next.sh" "$stage/documents/KUAL Next.sh"
chmod 755 "$stage/kual-next/bin/kual-next" "$stage/documents/KUAL Next.sh"
find "$stage" -exec touch -d '2000-01-01 00:00:00 UTC' {} +
rm -f "$package"
(cd "$stage" && find . -type f -print | LC_ALL=C sort | zip -X -q "$package" -@)

sh "$root/tests/check-package.sh" "$package" "$version"
printf 'Created %s\n' "$package"
