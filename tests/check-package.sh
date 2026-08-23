#!/bin/sh

set -eu

package=${1:-}
version=${2:-}
expected_name="kual-next-$version-kindlehf.zip"

if [ -z "$package" ] || [ -z "$version" ] || [ "$(basename "$package")" != "$expected_name" ]; then
	printf 'Unexpected package filename: %s\n' "$package" >&2
	exit 1
fi
unzip -tq "$package" >/dev/null
entries=$(unzip -Z1 "$package")
for required in \
	'documents/KUAL Next.sh' \
	'kual-next/bin/kual-next' \
	'kual-next/fonts/NotoSans.ttf' \
	'kual-next/fonts/NotoSansSymbols.ttf' \
	'kual-next/fonts/NotoSansSymbols2-Regular.otf' \
	'kual-next/LICENSES/KUAL-Next-GPL-3.0-or-later.txt' \
	'kual-next/LICENSES/FBInk-GPL-3.0-or-later.txt' \
	'kual-next/LICENSES/zig-xml-0BSD.txt' \
	'kual-next/LICENSES/musl-MIT.txt'
do
	printf '%s\n' "$entries" | grep -Fqx "$required" || {
		printf 'Package is missing %s\n' "$required" >&2
		exit 1
	}
done
if unzip -l "$package" | awk \
	'/^[[:space:]]*[0-9]+[[:space:]]+[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]/ && $2 != "01-01-2000" { exit 1 }'; then
	:
else
	printf 'Package contains a non-deterministic timestamp\n' >&2
	exit 1
fi
mode=$(unzip -Z -v "$package" | awk \
	'/^  kual-next\/bin\/kual-next$/ { found=1 } found && /Unix file attributes/ { print; exit }')
case "$mode" in
	*100755*) ;;
	*) printf 'Packaged executable does not have mode 0755\n' >&2; exit 1 ;;
esac

printf 'package checks passed\n'
