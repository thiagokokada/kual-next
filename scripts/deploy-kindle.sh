#!/bin/sh

set -eu

host=${1:-}
package=${2:-}
ssh_bin=${SSH:-ssh}
scp_bin=${SCP:-scp}
remote_package=/tmp/kual-next-deploy.zip

if [ -z "$host" ] || [ -z "$package" ]; then
	printf 'Usage: %s USER@HOST PACKAGE\n' "$0" >&2
	exit 2
fi
case "$host" in
	-*)
		printf 'Invalid Kindle host: %s\n' "$host" >&2
		exit 2
		;;
esac
if [ ! -f "$package" ]; then
	printf 'Package not found: %s\n' "$package" >&2
	exit 2
fi

running=$(
	"$ssh_bin" "$host" \
		'pidof kual-next 2>/dev/null || true'
)
if [ -n "$running" ]; then
	printf 'KUAL Next is running on %s (PID%s %s). Quit it before deploying.\n' \
		"$host" "$(printf '%s' "$running" | grep -q ' ' && printf 's' || true)" \
		"$running" >&2
	exit 1
fi

local_hash=$(sha256sum "$package" | awk '{print $1}')
"$scp_bin" "$package" "${host}:${remote_package}"
remote_checksum=$(
	"$ssh_bin" "$host" \
		"sha256sum '$remote_package'"
)
remote_hash=${remote_checksum%% *}
if [ "$local_hash" != "$remote_hash" ]; then
	printf 'Upload checksum mismatch: local=%s remote=%s\n' \
		"$local_hash" "$remote_hash" >&2
	exit 1
fi

"$ssh_bin" "$host" /bin/sh -s <<'REMOTE'
set -eu
archive=/tmp/kual-next-deploy.zip
unzip -oq "$archive" -d /mnt/us
chmod 755 "/mnt/us/documents/KUAL Next.sh" /mnt/us/kual-next/bin/kual-next
sha256sum /mnt/us/kual-next/bin/kual-next "/mnt/us/documents/KUAL Next.sh"
rm -f "$archive"
REMOTE

printf 'Deployed %s to %s (SHA-256 %s).\n' "$package" "$host" "$local_hash"
