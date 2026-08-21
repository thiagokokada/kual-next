#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/kual-release-test.XXXXXX")
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM
repo="$tmpdir/repo"
mkdir -p "$repo/scripts"
cp "$root/scripts/validate-release-tag.sh" "$repo/scripts/"

git -C "$repo" init -q -b main
git -C "$repo" config user.name "KUAL Next tests"
git -C "$repo" config user.email "tests@kual-next.invalid"
printf '1.2.3\n' >"$repo/VERSION"
git -C "$repo" add VERSION
git -C "$repo" commit -q -m "Release 1.2.3"
git -C "$repo" tag v1.2.3

version=$(sh "$repo/scripts/validate-release-tag.sh" v1.2.3 refs/heads/main)
test "$version" = 1.2.3

git -C "$repo" tag v1.2.4
if sh "$repo/scripts/validate-release-tag.sh" v1.2.4 refs/heads/main \
	>/dev/null 2>&1; then
	echo "release validation accepted a VERSION mismatch" >&2
	exit 1
fi

if sh "$repo/scripts/validate-release-tag.sh" release-1.2.3 refs/heads/main \
	>/dev/null 2>&1; then
	echo "release validation accepted a malformed tag" >&2
	exit 1
fi

if sh "$repo/scripts/validate-release-tag.sh" v9.9.9 refs/heads/main \
	>/dev/null 2>&1; then
	echo "release validation accepted a missing tag" >&2
	exit 1
fi

git -C "$repo" checkout -q -b side
printf '2.0.0\n' >"$repo/VERSION"
git -C "$repo" commit -q -am "Side release"
git -C "$repo" tag v2.0.0
git -C "$repo" checkout -q main
if sh "$repo/scripts/validate-release-tag.sh" v2.0.0 refs/heads/main \
	>/dev/null 2>&1; then
	echo "release validation accepted a tag outside main" >&2
	exit 1
fi

echo "release tag validation tests passed"
