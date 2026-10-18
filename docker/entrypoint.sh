#!/usr/bin/env bash
# Container entrypoint: stage the repository into a persistent build tree and
# run the OpenWrt build, then publish the artifacts to the mounted output dir.
#
# Layout inside the container:
#   /src            mounted repository (read-only)  -> compose ".:/src:ro"
#   /build/work     persistent case-sensitive build tree (named volume)
#   /build/artifacts  firmware copied out here (bind-mounted to ./artifacts)
#
# The OpenWrt source tree must live on a case-sensitive filesystem; a bind
# mount of a macOS working copy is not. Keeping it in a volume under the Linux
# VM also makes the build dramatically faster.
set -euo pipefail

SRC="${SRC_DIR:-/src}"
WORK="${WORK_DIR:-/build/work}"
ART="${ARTIFACT_DIR:-/build/artifacts}"

if [ ! -f "$SRC/build.sh" ]; then
	echo "ERROR: $SRC/build.sh not found - is the repository mounted at $SRC ?" >&2
	exit 1
fi

mkdir -p "$WORK" "$ART"

echo ">>> Staging sources: $SRC -> $WORK"
# Mirror the repo into the build tree, but never touch the cloned upstream tree
# (./openwrt) or the git metadata. --delete keeps the two in sync; excluded
# paths are preserved by rsync.
if [ "${FRESH_TREE:-0}" = "1" ]; then
	echo ">>> FRESH_TREE=1: wiping $WORK"
	rm -rf "${WORK:?}/"*
fi

rsync -a --delete \
	--exclude '.git/' \
	--exclude 'openwrt/' \
	--exclude 'artifacts/' \
	--exclude '.dockerignore' \
	"$SRC"/ "$WORK"/

cd "$WORK"
chmod +x ./build.sh

echo ">>> Running build.sh (OPENWRT_REPO=${OPENWRT_REPO:-default} OPENWRT_REF=${OPENWRT_REF:-default})"
./build.sh

echo ">>> Publishing artifacts to $ART"
mkdir -p "$ART"
shopt -s nullglob
found=0
for f in "$WORK"/openwrt/bin/targets/econet/en7528/*; do
	cp -v "$f" "$ART"/
	found=1
done
shopt -u nullglob

if [ "$found" = "0" ]; then
	echo "WARNING: no files under $WORK/openwrt/bin/targets/econet/en7528" >&2
	exit 1
fi

echo ">>> Done. Artifacts:"
ls -l "$ART"
