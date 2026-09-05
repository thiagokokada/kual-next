#!/bin/sh
set -eu

package=${1:-}
version=${2:-}
manifest_version=$(printf '%s' "$version" | sed 's/\./,/g')

if [ -z "$package" ] || [ -z "$version" ]; then
	echo "usage: $0 PACKAGE VERSION" >&2
	exit 2
fi

test -f "$package"
tar -tzf "$package" | grep -Fx 'manifest.json' >/dev/null
tar -tzf "$package" | grep -Fx 'install.sh' >/dev/null
tar -tzf "$package" | grep -Fx 'uninstall.sh' >/dev/null
tar -tzf "$package" | grep -Fx 'launch.sh' >/dev/null
tar -tzf "$package" | grep -Fx 'payload/kual-next/bin/kual-next' >/dev/null
tar -tzf "$package" | grep -Fx 'payload/documents/KUAL Next.sh' >/dev/null
tar -tzf "$package" | grep -Fx 'payload/koreader/plugins/kualnext.koplugin/main.lua' >/dev/null
tar -xOzf "$package" manifest.json | grep -F '"manifest_version": 2' >/dev/null
tar -xOzf "$package" manifest.json | grep -F '"id": "kual-next"' >/dev/null
tar -xOzf "$package" manifest.json | tr -d '[:space:]' |
	grep -F "\"version\":[$manifest_version]" >/dev/null
tar -xOzf "$package" manifest.json | tr -d '[:space:]' |
	grep -F '"supported_platforms":["kindlehf"]' >/dev/null

echo "KPM package checks passed"
