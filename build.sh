#!/bin/sh
# Build an OpenWrt RAM-only (initramfs) image for the Nokia G-2425G-A
# (Airtel XStream Fiber) EN7528 ONT.
#
# The build is done against upstream OpenWrt (the econet/en7528 target is
# merged there), with this repository's board files overlaid on top.
#
# Environment overrides:
#   OPENWRT_REPO  git URL to build from   (default: upstream openwrt)
#   OPENWRT_REF   branch/tag to build     (default: main)
#
set -e

OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_REF="${OPENWRT_REF:-main}"
DEVICE="nokia_g2425g-a"

echo ">>> Cloning $OPENWRT_REPO ($OPENWRT_REF)"
git clone --depth 1 --branch "$OPENWRT_REF" "$OPENWRT_REPO" openwrt
cd openwrt

echo ">>> Adding board support: $DEVICE"
cp ../board/en7528_nokia_g2425g-a.dts target/linux/econet/dts/
cat ../board/nokia_g2425g-a.mk >> target/linux/econet/image/en7528.mk

echo ">>> Updating feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo ">>> Writing .config"
# Target / device selection. CONFIG_TARGET_MULTI_PROFILE switches OpenWrt to the
# per-device symbol naming used below.
cat > .config <<'EOF'
CONFIG_TARGET_econet=y
CONFIG_TARGET_econet_en7528=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_nokia_g2425g-a=y
CONFIG_TARGET_DEVICE_PACKAGES_econet_en7528_DEVICE_nokia_g2425g-a=""
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_en7528_generic=y
CONFIG_TARGET_DEVICE_PACKAGES_econet_en7528_DEVICE_en7528_generic=""
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE=y
CONFIG_PACKAGE_kmod-mt76-core=y
CONFIG_PACKAGE_kmod-mt76-connac=y
CONFIG_PACKAGE_kmod-mt7603=y
CONFIG_PACKAGE_kmod-mt7615-common=y
CONFIG_PACKAGE_kmod-mt7615e=y
CONFIG_PACKAGE_kmod-mt7663-firmware-ap=y
CONFIG_PACKAGE_kmod-cfg80211=y
CONFIG_PACKAGE_kmod-mac80211=y
CONFIG_PACKAGE_wpad-basic-mbedtls=y
CONFIG_PACKAGE_iperf3=y
EOF

echo ">>> make defconfig"
make defconfig

echo ">>> Sanity check: is $DEVICE enabled?"
if ! grep -q "CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_${DEVICE}=y" .config; then
	echo "ERROR: $DEVICE was not enabled - board files probably failed to apply."
	grep -i 'CONFIG_TARGET_econet' .config || true
	exit 1
fi

echo ">>> make -j$(nproc)  (first build takes roughly an hour)"
make -j"$(nproc)" || make -j1 V=s

echo ">>> Normalising output file names"
cd bin/targets/econet/en7528
for f in *-econet-en7528-*; do
	[ -e "$f" ] || continue
	case "$f" in
	openwrt-econet-en7528-*) continue ;;
	esac
	mv -f "$f" "openwrt-econet-en7528-${f##*-econet-en7528-}"
done

sha256sum ./* 2>/dev/null | tee SHA256SUMS || true
ls -l

echo ">>> Done"
