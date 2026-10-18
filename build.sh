#!/bin/sh
# Build an OpenWrt RAM-only (initramfs) image for the Nokia G-2425G-A
# (Airtel XStream Fiber) EN7528 ONT.
#
# The build is done against upstream OpenWrt (the econet/en7528 target is
# merged there), with this repository's board files overlaid on top.
#
# Environment overrides:
#   OPENWRT_REPO   git URL to build from   (default: upstream openwrt)
#   OPENWRT_REF    branch/tag to build     (default: main)
#   OPENWRT_FRESH  set to 1 to discard an existing ./openwrt checkout and reclone
#
set -e

OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_REF="${OPENWRT_REF:-main}"
DEVICE="nokia_g2425g-a"

# Reuse an existing checkout if one is present. This keeps dl/ and build_dir/
# (and therefore ccache/toolchain state) across runs, which matters a lot when
# building inside a container. CI starts with a clean workspace, so it clones.
if [ -d openwrt/.git ] && [ "${OPENWRT_FRESH:-0}" != "1" ]; then
	echo ">>> Reusing existing ./openwrt checkout (OPENWRT_FRESH=1 to reclone)"
else
	echo ">>> Cloning $OPENWRT_REPO ($OPENWRT_REF)"
	rm -rf openwrt
	git clone --depth 1 --branch "$OPENWRT_REF" "$OPENWRT_REPO" openwrt
fi
cd openwrt

echo ">>> Adding board support: $DEVICE"
cp ../board/en7528_nokia_g2425g-a.dts target/linux/econet/dts/
# 5 GHz calibration, embedded into the DTB via /incbin/ on &slot1.
# dtc resolves /incbin/ against the DTS directory (-i $(DTS_DIR)), so the
# blob has to sit next to the .dts.
cp ../board/nokia-mt7663-eeprom.bin target/linux/econet/dts/
cat ../board/nokia_g2425g-a.mk >> target/linux/econet/image/en7528.mk

# Board defaults that only add keys to /etc/board.json (regulatory country and
# the LAN socket LED triggers).  Additive on purpose - see the file header.
cp ../board/03_nokia-board target/linux/econet/base-files/etc/board.d/
chmod 0755 target/linux/econet/base-files/etc/board.d/03_nokia-board

echo ">>> Putting $DEVICE on the switch ports (DSA) instead of eth0"
# The target's 02_network only lists the DASAN/JioFiber boards in the branch that
# bridges the switch user ports (lan1..lan4); every other board gets
# ucidef_set_interface_lan "eth0". On this box eth0 is the switch *conduit*, so
# br-lan ended up with no usable member and DHCP never reached a socket.
# Patch the board into that branch.  Verified below - a moved anchor fails the
# build instead of silently shipping a broken network config.
NET_D="/etc/board.d/02_network"
NET_D="target/linux/econet/base-files${NET_D}"
if ! grep -q 'nokia,g2425g-a' "$NET_D"; then
	awk '{ if ($0 == "\tjiofiber,jcow414)") print "\tnokia,g2425g-a|\\"; print }' \
		"$NET_D" > "$NET_D.new"
	mv "$NET_D.new" "$NET_D"
fi
if ! grep -q 'nokia,g2425g-a|\\' "$NET_D"; then
	echo "ERROR: could not patch $NET_D (upstream layout changed?)"
	sed -n '1,30p' "$NET_D"
	exit 1
fi
echo "--- econet_setup_interfaces now reads:"
sed -n '/^econet_setup_interfaces/,/^}/p' "$NET_D"

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
# ccache. DEVEL only controls the menu visibility of CCACHE; without it the
# symbol is hidden and `make defconfig` would drop CONFIG_CCACHE again. ccache
# stores its cache in ./.ccache (i.e. inside openwrt/), so with the Docker
# named volume it survives across builds and makes rebuilds much faster.
CONFIG_DEVEL=y
CONFIG_CCACHE=y
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
# kexec: reload the next kernel into RAM from the running (RAM-booted) OpenWrt
# over Ethernet, instead of re-XMODEMing it over the 115200 console (~15 min).
# The `kexec` package depends on @KERNEL_KEXEC, so both must be on.
# See ../../KEXEC_PLAN.md (in the parent repo) for why this is the fast path and
# for the device-tree handoff that still has to be settled.
CONFIG_KERNEL_KEXEC=y
CONFIG_PACKAGE_kexec=y
EOF

echo ">>> make defconfig"
make defconfig

echo ">>> Sanity check: is $DEVICE enabled?"
if ! grep -q "CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_${DEVICE}=y" .config; then
	echo "ERROR: $DEVICE was not enabled - board files probably failed to apply."
	grep -i 'CONFIG_TARGET_econet' .config || true
	exit 1
fi

echo ">>> Sanity check: is ccache enabled?"
if grep -q '^CONFIG_CCACHE=y' .config; then
	echo "    ccache on, cache dir: ${CCACHE_DIR:-./.ccache (relative to openwrt/)}"
else
	echo "    WARNING: CONFIG_CCACHE was dropped by defconfig; ccache will not be used."
fi

echo ">>> Sanity check: is kexec enabled (fast in-RAM reload)?"
for sym in CONFIG_KERNEL_KEXEC CONFIG_PACKAGE_kexec; do
	if grep -q "^${sym}=y" .config; then
		echo "    ${sym}=y"
	else
		echo "    WARNING: ${sym} is not set - kexec reload will be unavailable."
	fi
done

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
