#!/bin/sh
set -eu

: "${KUAL_TC_ROOT:?KUAL_TC_ROOT must name the project-local toolchain directory}"
: "${KOXTOOLCHAIN_SRC:?Run this command inside 'nix develop'}"

target=arm-kindlehf-linux-gnueabihf
compiler="$KUAL_TC_ROOT/$target/bin/$target-gcc"
if [ -x "$compiler" ]; then
    "$compiler" --version | head -n 1
    exit 0
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage="$project_root/build/koxtoolchain"
if [ ! -d "$stage" ]; then
    mkdir -p "$stage"
    cp -R "$KOXTOOLCHAIN_SRC"/. "$stage"/
    chmod -R u+w "$stage"
fi

# Do not let native compiler selection or Nix wrapper hardening leak into the
# compiler being bootstrapped. In particular, format-security turns warnings
# in GCC's own sources into errors.
unset CC CXX LD AR AS RANLIB STRIP OBJCOPY OBJDUMP READELF NM
unset NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS
unset NIX_HARDENING_ENABLE NIX_ENFORCE_NO_NATIVE

# Follow koxtoolchain's pinned build recipe without modifying its sources.
# CT_PREFIX_DIR is a normal generated crosstool-ng configuration value; setting
# it keeps the installation project-local without repurposing HOME.
ctng_repository=https://github.com/benoit-pierre/crosstool-ng.git
ctng_revision=34844bc8e985ad1ba26b072a5b58264967072e19
build_root="$stage/build"
ctng_source="$build_root/CT-NG"
ctng_prefix="$build_root/CT_NG_BUILD"

if [ ! -x "$ctng_prefix/bin/ct-ng" ]; then
    mkdir -p "$build_root"
    if [ ! -d "$ctng_source/.git" ]; then
        git clone "$ctng_repository" "$ctng_source"
    fi
    git -C "$ctng_source" fetch "$ctng_repository" "$ctng_revision"
    git -C "$ctng_source" checkout --detach "$ctng_revision"
    git -C "$ctng_source" clean -fxdq
    (
        cd "$ctng_source"
        ./bootstrap
        ./configure --prefix="$ctng_prefix"
        make -j"$(getconf _NPROCESSORS_ONLN)"
        make install
    )
fi

config_dir="$build_root/kindlehf"
mkdir -p "$config_dir"
(
    cd "$config_dir"
    ctng="$ctng_prefix/bin/ct-ng"
    "$ctng" curl_silent_opt= wget_silent_opt=--progress=dot:mega distclean
    "$ctng" curl_silent_opt= wget_silent_opt=--progress=dot:mega "$target"
    "$ctng" curl_silent_opt= wget_silent_opt=--progress=dot:mega oldconfig
    "$ctng" curl_silent_opt= wget_silent_opt=--progress=dot:mega upgradeconfig
    sed -i "s|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR=\"$KUAL_TC_ROOT/\${CT_TARGET}\"|" .config
    nice "$ctng" curl_silent_opt= wget_silent_opt=--progress=dot:mega build
)

test -x "$compiler"
"$compiler" --version | head -n 1
