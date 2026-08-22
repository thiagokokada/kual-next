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
grep -Fq "KUAL Next $version; model=KindlePaperWhite5; extensions=2; entries=3" "$tmpdir/tree"
grep -q '^> KUAL$' "$tmpdir/tree"
grep -q '  - Sort menu ABC => ' "$tmpdir/tree"
grep -q '  - × Quit => :' "$tmpdir/tree"
test "$(grep -n 'Beta action' "$tmpdir/tree" | cut -d: -f1)" -lt "$(grep -n '> Alpha' "$tmpdir/tree" | cut -d: -f1)"
grep -q 'Run Unicode ✓ => bin/run.sh one two' "$tmpdir/tree"
grep -q 'Model match => :' "$tmpdir/tree"
grep -q 'Model mismatch => :' "$tmpdir/tree"
grep -q 'Configured => :' "$tmpdir/tree"
! grep -q Invisible "$tmpdir/tree"
test "$(grep -c '> Shared+$' "$tmpdir/tree")" -eq 1
grep -q -- '- First => :' "$tmpdir/tree"
grep -q -- '- Second => :' "$tmpdir/tree"
grep -q -- '- Third => :' "$tmpdir/tree"

cp -R "$fixture" "$tmpdir/no-buttons"
printf '%s\n' 'KUAL_show_KUAL_buttons="0"' > "$tmpdir/no-buttons/KUAL.cfg"
"$binary" --validate --extensions "$tmpdir/no-buttons" \
    > "$tmpdir/no-buttons.tree" 2> "$tmpdir/no-buttons.errors"
test ! -s "$tmpdir/no-buttons.errors"
! grep -q '^> KUAL$' "$tmpdir/no-buttons.tree"

cp -R "$fixture" "$tmpdir/no-collation"
printf '%s\n' 'KUAL_collate="false"' > "$tmpdir/no-collation/KUAL.cfg"
"$binary" --validate --extensions "$tmpdir/no-collation" \
    > "$tmpdir/no-collation.tree" 2> "$tmpdir/no-collation.errors"
test ! -s "$tmpdir/no-collation.errors"
test "$(grep -c '> Shared$' "$tmpdir/no-collation.tree")" -eq 3
! grep -q '> Shared+$' "$tmpdir/no-collation.tree"

device_fixture="$root/device-fixtures/extensions"
"$binary" --validate --extensions "$device_fixture" --model KindlePaperWhite5 \
    > "$tmpdir/device-tree" 2> "$tmpdir/device-errors"
test ! -s "$tmpdir/device-errors"
grep -Fq "KUAL Next $version; model=KindlePaperWhite5; extensions=1; entries=4" \
    "$tmpdir/device-tree"
grep -q '^> Zeta Section (Priority -10)$' "$tmpdir/device-tree"
grep -q '^> Device UI Test$' "$tmpdir/device-tree"
grep -q '^> Alpha Section (Priority 10)$' "$tmpdir/device-tree"
grep -q '^  > Collated section+$' "$tmpdir/device-tree"
test "$(grep -c '^  \(-\|>\) [0-9][0-9] ' "$tmpdir/device-tree")" -eq 15
test "$(grep -c '^    - Nested [0-9][0-9] =>' "$tmpdir/device-tree")" -eq 12
grep -q '^> KUAL$' "$tmpdir/device-tree"
grep -q '  - Sort menu ABC => ' "$tmpdir/device-tree"
grep -q '  - × Quit => :' "$tmpdir/device-tree"
test "$(grep -n '> Zeta Section' "$tmpdir/device-tree" | cut -d: -f1)" -lt "$(grep -n '> Device UI Test' "$tmpdir/device-tree" | cut -d: -f1)"
test "$(grep -n '> Device UI Test' "$tmpdir/device-tree" | cut -d: -f1)" -lt "$(grep -n '> Alpha Section' "$tmpdir/device-tree" | cut -d: -f1)"
test "$(grep -n 'Gamma \[Author' "$tmpdir/device-tree" | cut -d: -f1)" -lt "$(grep -n 'Beta \[Author' "$tmpdir/device-tree" | cut -d: -f1)"
test "$(grep -n 'Beta \[Author' "$tmpdir/device-tree" | cut -d: -f1)" -lt "$(grep -n 'Alpha \[Author' "$tmpdir/device-tree" | cut -d: -f1)"

cp -R "$device_fixture" "$tmpdir/device-abc"
printf '%s\n' 'KUAL_sort_mode="ABC"' > "$tmpdir/device-abc/KUAL.cfg"
"$binary" --validate --extensions "$tmpdir/device-abc" \
    > "$tmpdir/device-abc-tree" 2> "$tmpdir/device-abc-errors"
test ! -s "$tmpdir/device-abc-errors"
grep -q '  - Sort menu 123 => ' "$tmpdir/device-abc-tree"
test "$(grep -n '> Alpha Section' "$tmpdir/device-abc-tree" | cut -d: -f1)" -lt "$(grep -n '> Device UI Test' "$tmpdir/device-abc-tree" | cut -d: -f1)"
test "$(grep -n '> Device UI Test' "$tmpdir/device-abc-tree" | cut -d: -f1)" -lt "$(grep -n '> Zeta Section' "$tmpdir/device-abc-tree" | cut -d: -f1)"
test "$(grep -n 'Gamma \[Author' "$tmpdir/device-abc-tree" | cut -d: -f1)" -lt "$(grep -n 'Alpha \[Author' "$tmpdir/device-abc-tree" | cut -d: -f1)"
test "$(grep -n 'Alpha \[Author' "$tmpdir/device-abc-tree" | cut -d: -f1)" -lt "$(grep -n 'Beta \[Author' "$tmpdir/device-abc-tree" | cut -d: -f1)"

cp -R "$device_fixture" "$tmpdir/device-bang"
printf '%s\n' 'KUAL_sort_mode="ABC!"' > "$tmpdir/device-bang/KUAL.cfg"
"$binary" --validate --extensions "$tmpdir/device-bang" \
    > "$tmpdir/device-bang-tree" 2> "$tmpdir/device-bang-errors"
test ! -s "$tmpdir/device-bang-errors"
grep -q '  - Sort menu 123 => ' "$tmpdir/device-bang-tree"
test "$(grep -n '> Alpha Section' "$tmpdir/device-bang-tree" | cut -d: -f1)" -lt "$(grep -n '> Device UI Test' "$tmpdir/device-bang-tree" | cut -d: -f1)"
test "$(grep -n '> Device UI Test' "$tmpdir/device-bang-tree" | cut -d: -f1)" -lt "$(grep -n '> Zeta Section' "$tmpdir/device-bang-tree" | cut -d: -f1)"
test "$(grep -n 'Alpha \[Author' "$tmpdir/device-bang-tree" | cut -d: -f1)" -lt "$(grep -n 'Beta \[Author' "$tmpdir/device-bang-tree" | cut -d: -f1)"
test "$(grep -n 'Beta \[Author' "$tmpdir/device-bang-tree" | cut -d: -f1)" -lt "$(grep -n 'Gamma \[Author' "$tmpdir/device-bang-tree" | cut -d: -f1)"

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
grep -Fq "KUAL Next $version; model=Unknown; extensions=1; entries=2" "$tmpdir/xml/tree"
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
