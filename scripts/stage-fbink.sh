#!/bin/sh

set -eu

source_dir=$1
revision=$2
destination=$3

test -d "$source_dir/.git"
resolved_revision=$(git -C "$source_dir" rev-parse "$revision^{commit}")
test "$resolved_revision" = "$revision"
test ! -e "$destination"

destination_parent=$(dirname "$destination")
mkdir -p "$destination_parent"
temporary_dir=$(mktemp -d "$destination_parent/.fbink-stage.XXXXXX")

cleanup() {
	rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

# Keep the parent checkout local, but materialize its pinned submodules.  A Git
# checkout is required because FBInk derives its version from Git metadata.
git clone --quiet --no-checkout --shared "$source_dir" "$temporary_dir"
git -C "$temporary_dir" checkout --quiet --detach "$revision"
git -C "$temporary_dir" submodule update --init --recursive
touch "$temporary_dir/.staged"
mv "$temporary_dir" "$destination"

trap - EXIT HUP INT TERM
