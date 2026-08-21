#!/bin/sh
set -eu

binary=${1:?host validator path required}
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture="$root/fixtures/extensions"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

"$binary" --version | grep -q '^kual-next 0.1.0$'
"$binary" --validate --extensions "$fixture" --model KindlePaperWhite5 > "$tmpdir/tree" 2> "$tmpdir/errors"
test ! -s "$tmpdir/errors"
grep -q '^KUAL Next 0.1.0; model=KindlePaperWhite5; extensions=2; entries=2$' "$tmpdir/tree"
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
grep -q '^KUAL Next 0.1.0; model=Unknown; extensions=1; entries=1$' "$tmpdir/xml/tree"
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
if "$binary" --validate --extensions "$tmpdir/extensions" > "$tmpdir/broken.out" 2> "$tmpdir/broken.err"; then
    echo "invalid JSON unexpectedly passed validation" >&2
    exit 1
fi
grep -q 'invalid JSON menu' "$tmpdir/broken.err"

echo "host parser tests passed"
