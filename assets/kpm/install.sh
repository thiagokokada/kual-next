#!/bin/sh
set -eu

mkdir -p /mnt/us/documents
cp "payload/documents/KUAL Next.sh" "/mnt/us/documents/KUAL Next.sh"
cp -R payload/kual-next /mnt/us/

if [ -d /mnt/us/koreader/plugins ]; then
	echo "KOReader detected; installing KOReader plugin"
	cp -R payload/koreader/plugins/kualnext.koplugin /mnt/us/koreader/plugins/
fi
