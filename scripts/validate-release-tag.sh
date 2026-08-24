#!/bin/sh
set -eu

tag=${1:-}
main_ref=${2:-origin/main}
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if ! printf '%s\n' "$tag" |
    grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
	printf 'Release tag must be stable SemVer in the form vMAJOR.MINOR.PATCH: %s\n' \
		"$tag" >&2
	exit 1
fi

tag_ref="refs/tags/$tag"
if ! git -C "$root" rev-parse --verify "$main_ref^{commit}" >/dev/null 2>&1; then
	printf 'Main reference does not exist: %s\n' "$main_ref" >&2
	exit 1
fi

release_ref="$tag_ref"
if ! git -C "$root" rev-parse --verify "$tag_ref^{commit}" >/dev/null 2>&1; then
	release_ref="$main_ref"
fi

version=$(git -C "$root" show "$release_ref:VERSION")
if [ "$tag" != "v$version" ]; then
	printf 'Release tag %s does not match VERSION %s at %s.\n' \
		"$tag" "$version" "$release_ref" >&2
	exit 1
fi

if [ "$release_ref" = "$tag_ref" ] &&
    ! git -C "$root" merge-base --is-ancestor "$tag_ref^{commit}" \
        "$main_ref^{commit}"; then
	printf 'Release tag is not contained in %s: %s\n' "$main_ref" "$tag" >&2
	exit 1
fi

printf '%s\n' "$version"
