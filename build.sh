#!/bin/sh
set -e
BRANCH="e7528-gphy-pr"
WS="$(pwd)"

git clone https://github.com/naseef/openwrt.git
cd openwrt || exit 1
git checkout "$BRANCH"
git --no-pager log -1 --oneline

# --- Add DASAN H680GM-A (Airtel) 128MB port ---
cp "$WS/files/en7528_dasan_h680gm-a.dts" target/linux/econet/dts/en7528_dasan_h680gm-a.dts

# Add H680GM-A (Airtel) to the A/B boot-flag tool so OpenWrt commits its boot slot.
# H680 uses the same dzs@0x49 scheme as H660 (0000 = OS A/OpenWrt, 0101 = OS B/factory).
CHBOOT=target/linux/econet/base-files/sbin/en75_chboot
if ! grep -q "dasan,h680gm-a-airtel" "$CHBOOT"; then
  sed -i '/dasan,h660gm-a-airtel|\\/i\    dasan,h680gm-a-airtel|\\' "$CHBOOT"
fi
grep -n "h680gm-a" "$CHBOOT" || true

cat >> target/linux/econet/image/en7528.mk <<'MK'

define Device/dasan_h680gm-a-airtel
  $(call Device/tclinux-ubi)
  DEVICE_VENDOR := DASAN
  DEVICE_MODEL := H680GM-A
  DEVICE_VARIANT := Airtel
  FACTORY_SIZE := 32m
  TRX_LOADADDR := 0x80002000
  KERNEL := kernel-bin | append-dtb | tclinux-free-bootbase-jump | lzma | kernel-trx
  DEVICE_DTS := en7528_dasan_h680gm-a
  DEVICE_PACKAGES := kmod-usb2 kmod-mt7603 kmod-mt7615e kmod-mt7663-firmware-ap
endef
TARGET_DEVICES += dasan_h680gm-a-airtel
MK
echo "=== en7528.mk tail ==="; tail -12 target/linux/econet/image/en7528.mk

./scripts/feeds update -a
./scripts/feeds install -a

cat > .config <<'CFG'
CONFIG_TARGET_econet=y
CONFIG_TARGET_econet_en7528=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_dasan_h680gm-a-airtel=y
CONFIG_TARGET_DEVICE_PACKAGES_econet_en7528_DEVICE_dasan_h680gm-a-airtel=""
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_en7528_generic=y
CONFIG_TARGET_DEVICE_PACKAGES_econet_en7528_DEVICE_en7528_generic=""
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
CONFIG_IMAGEOPT=y
CONFIG_PACKAGE_kmod-cfg80211=y
CONFIG_PACKAGE_kmod-mac80211=y
CONFIG_PACKAGE_kmod-mt76-core=y
CONFIG_PACKAGE_kmod-mt76-connac=y
CONFIG_PACKAGE_kmod-mt7603=y
CONFIG_PACKAGE_kmod-mt7615-common=y
CONFIG_PACKAGE_kmod-mt7615e=y
CONFIG_PACKAGE_kmod-mt7663-firmware-ap=y
CONFIG_PACKAGE_hostapd-common=y
CONFIG_PACKAGE_wpad-basic-mbedtls=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_uhttpd-mod-ubus=y
# --- USB storage / NAS ---
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-storage-uas=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-fs-exfat=y
CONFIG_PACKAGE_kmod-fs-ntfs3=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_dosfstools=y
CONFIG_PACKAGE_ksmbd-server=y
CONFIG_PACKAGE_luci-app-ksmbd=y
CONFIG_PACKAGE_kmod-usb2=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE=y
CFG

make defconfig
echo "=== selected econet devices ==="; grep -E 'DEVICE_(dasan_h680|en7528_generic)' .config || true
make "-j$(nproc)" V=s 2>&1 | tail -n 120 || { echo BUILD_FAILED; exit 1; }
echo "=== OUTPUTS ==="; ls -la ./bin/targets/econet/en7528/ || true
