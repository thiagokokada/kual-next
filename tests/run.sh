#!/bin/sh
set -eu

binary=${1:?host validator path required}
version=${KUAL_TEST_VERSION:?KUAL_TEST_VERSION is required}
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture="$root/fixtures/extensions"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

test "$("$binary" --version)" = "kual-next $version"
"$binary" --validate --extensions "$fixture" --model KindlePaperWhite5 > "$tmpdir/tree" 2> "$tmpdir/errors"
test ! -s "$tmpdir/errors"
grep -Fq "KUAL Next $version; model=KindlePaperWhite5; extensions=2; entries=2" "$tmpdir/tree"
test "$(grep -n 'Beta action' "$tmpdir/tree" | cut -d: -f1)" -lt "$(grep -n '> Alpha' "$tmpdir/tree" | cut -d: -f1)"
grep -q 'Run Unicode ✓ => bin/run.sh one two' "$tmpdir/tree"
grep -q 'Model match => :' "$tmpdir/tree"
grep -q 'Model mismatch => :' "$tmpdir/tree"
grep -q 'Configured => :' "$tmpdir/tree"
! grep -q Invisible "$tmpdir/tree"

mkdir -p "$tmpdir/xml/extensions/proper"
printf '%s\n' '<?xml version="1.0"?>' \
    '<extension>' \
    '  <!-- Attribute order, whitespace, CDATA, and numeric entities are intentional. -->' \
    '  <information><id>xml&#x2d;proper</id></information>' \
    "  <menus><menu dynamic=\"true\" type = 'json'><![CDATA[ menu.json ]]></menu></menus>" \
    '</extension>' > "$tmpdir/xml/extensions/proper/config.xml"
printf '%s\n' '{"items":[{"name":"Proper XML","action":":","if":"\"xml-proper\" -ext"}]}' \
    > "$tmpdir/xml/extensions/proper/menu.json"
"$binary" --validate --extensions "$tmpdir/xml/extensions" \
    > "$tmpdir/xml/tree" 2> "$tmpdir/xml/errors"
test ! -s "$tmpdir/xml/errors"
grep -Fq "KUAL Next $version; model=Unknown; extensions=1; entries=1" "$tmpdir/xml/tree"
grep -q 'Proper XML => :' "$tmpdir/xml/tree"

mkdir -p "$tmpdir/xml-broken/extensions/broken"
printf '%s\n' '<extension><information><id>broken</information></id></extension>' \
    > "$tmpdir/xml-broken/extensions/broken/config.xml"
if "$binary" --validate --extensions "$tmpdir/xml-broken/extensions" \
    > "$tmpdir/xml-broken/tree" 2> "$tmpdir/xml-broken/errors"; then
    echo "invalid XML unexpectedly passed validation" >&2
    exit 1
fi
grep -q 'mismatched closing element' "$tmpdir/xml-broken/errors"

mkdir -p "$tmpdir/extensions/broken"
cp "$fixture/alpha/config.xml" "$tmpdir/extensions/broken/config.xml"
printf '%s\n' '{"items": [' > "$tmpdir/extensions/broken/menu.json"
mkdir -p "$tmpdir/extensions/dependent"
printf '%s\n' '<extension><information><id>dependent</id></information>' \
	'<menus><menu type="json">menu.json</menu></menus></extension>' \
	> "$tmpdir/extensions/dependent/config.xml"
printf '%s\n' \
	'{"items":[{"name":"Broken dependency","action":":","if":"\"broken\" -ext"}]}' \
	> "$tmpdir/extensions/dependent/menu.json"
if "$binary" --validate --extensions "$tmpdir/extensions" > "$tmpdir/broken.out" 2> "$tmpdir/broken.err"; then
    echo "invalid JSON unexpectedly passed validation" >&2
    exit 1
fi
grep -q 'invalid JSON menu' "$tmpdir/broken.err"
! grep -q 'Broken dependency' "$tmpdir/broken.out"

echo "host parser tests passed"
