#!/bin/sh
# Build an OpenWrt RAM-only (initramfs) image for the Nokia G-2425G-A
# (Airtel XStream Fiber) EN7528 ONT, plus the HDR2 tclinux container that the
# TcBoot bootloader can load from flash.
#
# Two devices are built from the same kernel: the RAM profile (every partition
# read-only, the image that has been proven over UART) and the flash profile
# (identical except that flag/flagback are writable, so OpenWrt can keep the
# bootloader's boot_fail_num counter clear). Only the flash profile's container
# may ever be written to NAND - see the tail of this script.
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
# Two devices, one kernel, two device trees: the RAM profile (every partition
# read-only) and the flash profile (flag/flagback writable + nokia-flagreset).
DEVICES="nokia_g2425g-a nokia_g2425g-a-flash"

# Absolute paths, because the build chdir()s into openwrt/ below.
B_DIR="$(cd "$(dirname "$0")" && pwd)/board"

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

echo ">>> Adding board support: $DEVICE (+ the flash profile)"
cp ../board/en7528_nokia_g2425g-a.dts target/linux/econet/dts/
cp ../board/en7528_nokia_g2425g-a-flash.dts target/linux/econet/dts/
# 5 GHz calibration, embedded into the DTB via /incbin/ on &slot1.
# dtc resolves /incbin/ against the DTS directory (-i $(DTS_DIR)), so the
# blob has to sit next to the .dts.
cp ../board/nokia-mt7663-eeprom.bin target/linux/econet/dts/
# The checkout is reused between builds, so the profile block is regenerated
# from board/nokia_g2425g-a.mk on every run: drop whatever an earlier run left
# behind (the sentinel-delimited block, or the pre-sentinel block that older
# trees carry) and append the current one. Without this the profile is
# duplicated once per run (seen 4x deep in the volume), and a device added later
# - like the flash profile - would never be picked up at all.
EMK=target/linux/econet/image/en7528.mk
awk '
	/# >>> nokia_g2425g-a/ { skip = 1 }
	skip && /# <<< nokia_g2425g-a/ { skip = 0; next }
	skip { next }
	$0 == "# Nokia G-2425G-A (Airtel XStream Fiber)" { legacy = 1 }
	legacy { if ($0 ~ /^TARGET_DEVICES \+= nokia_g2425g-a$/) legacy = 0; next }
	{ print }
' "$EMK" > "$EMK.new"
mv "$EMK.new" "$EMK"
cat ../board/nokia_g2425g-a.mk >> "$EMK"
for d in $DEVICES; do
	if [ "$(grep -c "^define Device/${d}\$" "$EMK")" != 1 ]; then
		echo "ERROR: $d is not defined exactly once in $EMK" >&2
		grep -n 'define Device/' "$EMK" >&2
		exit 1
	fi
done

# nokia-flagreset: keeps the bootloader's boot_fail_num below the failover
# point. Only the flash profile's DEVICE_PACKAGES pulls it in, so the RAM image
# does not ship it (and could not use it anyway - every MTD is read-only there).
echo ">>> Adding the nokia-flagreset package (flash profile only)"
rm -rf package/nokia-flagreset
mkdir -p package/nokia-flagreset
cp ../board/nokia-flagreset/Makefile package/nokia-flagreset/
cp -R ../board/nokia-flagreset/files package/nokia-flagreset/
chmod 0755 package/nokia-flagreset/files/nokia-flagreset.init
# Off-device check of the reset logic (fake /proc/mtd + fake mtd). Skipped where
# hexdump is unavailable (the script itself needs busybox hexdump *on the
# device*, where it is always present).
if [ -f "$B_DIR/nokia-flagreset/selftest.sh" ] && command -v hexdump >/dev/null 2>&1; then
	if sh "$B_DIR/nokia-flagreset/selftest.sh" >/dev/null; then
		echo "    nokia-flagreset selftest passed"
	else
		echo "ERROR: nokia-flagreset selftest failed" >&2
		sh "$B_DIR/nokia-flagreset/selftest.sh" >&2 || true
		exit 1
	fi
fi

# Board defaults that only add keys to /etc/board.json (regulatory country and
# the LAN socket LED triggers).  Additive on purpose - see the file header.
cp ../board/03_nokia-board target/linux/econet/base-files/etc/board.d/
chmod 0755 target/linux/econet/base-files/etc/board.d/03_nokia-board

# Post-config defaults (DHCP pool for the 192.168.100.0/24 LAN, enable the
# default APs).  uci-defaults run from /etc/init.d/boot, after config_generate.
mkdir -p package/base-files/files/etc/uci-defaults
cp ../board/99_nokia-settings package/base-files/files/etc/uci-defaults/
chmod 0755 package/base-files/files/etc/uci-defaults/99_nokia-settings

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

echo ">>> Waiting for switch ports before the LED service runs"
# PHYLIB registers the switch PHY LED classdevs (mt7530-0:09:green:lan, ...)
# before the DSA user ports they are attached to are registered as netdevs.
# When /etc/init.d/led activates the "netdev" trigger inside that window, the
# trigger takes its hw-control path and calls strlen(dev_name(attached_dev));
# the net_device exists but has no name yet, so strlen(NULL) panics the kernel.
# Reproduced on the v5 RAM boot:
#   Comm: led   epc: strlen+0x0   ra: netdev_trig_activate+0x128
#   lan1 (uninitialized): PHY [mt7530-0:09] ... -> Oops -> Kernel panic
# v4 only escaped because its boot timing fell outside that window.  Wait for
# the last switch port before letting the LED service touch any trigger.
LED_D="package/base-files/files/etc/init.d/led"
if ! grep -q 'nokia-led-wait' "$LED_D"; then
	awk '
		{ print }
		/^start\(\) \{/ && !added {
			print "\t# nokia-led-wait: the switch PHY LED classdevs are"
			print "\t# registered before their DSA netdevs exist.  Activating"
			print "\t# the netdev trigger in that window dereferences a NULL"
			print "\t# device name in netdev_trig_activate() -> kernel panic."
			print "\t_i=0"
			print "\twhile [ $_i -lt 20 ] && [ ! -e /sys/class/net/lan4 ]; do"
			print "\t\tsleep 1"
			print "\t\t_i=$((_i + 1))"
			print "\tdone"
			added=1
		}
	' "$LED_D" > "$LED_D.new"
	mv "$LED_D.new" "$LED_D"
fi
# The rewrite above loses the executable bit (default umask 022 -> 0644),
# which makes /etc/init.d/led unrunnable and leaves every trigger at "none".
# v6 shipped with that bug.  This must run unconditionally: on a second build
# the file already contains the marker, so the block above is skipped.
chmod 0755 "$LED_D"
if ! grep -q 'nokia-led-wait' "$LED_D"; then
	echo "ERROR: could not patch $LED_D (upstream layout changed?)"
	sed -n '/^start()/,/^}/p' "$LED_D"
	exit 1
fi
echo "--- led start() now waits for lan4:"
sed -n '/^start()/,/^}/p' "$LED_D" | sed -n '1,12p'
# Make sure the changed overlay file is reinstalled into the rootfs.
touch package/base-files/Makefile

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
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_nokia_g2425g-a-flash=y
CONFIG_TARGET_DEVICE_PACKAGES_econet_en7528_DEVICE_nokia_g2425g-a-flash=""
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

echo ">>> Sanity check: are the devices enabled?"
for d in $DEVICES; do
	if grep -q "CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_${d}=y" .config; then
		echo "    $d"
	else
		echo "ERROR: $d was not enabled - board files probably failed to apply."
		grep -i 'CONFIG_TARGET_econet' .config || true
		exit 1
	fi
done

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

# ---------------------------------------------------------------------------
# The flashable image: wrap the initramfs kernel in an HDR2 tclinux container
# with the vendor bootram trailer.  Nothing here is flashed - it only produces
# the file that `flash` / the bootloader's `httpd` upload page would write.
#
# Why the initramfs kernel and not kernel+squashfs yet: this container boots the
# exact userspace that is already proven from RAM (v8), with no new variables.
# It needs no rootfs partition, no cmdline, so the only new thing on the first
# flash test is the container itself.  A kernel+squashfs image is the follow-up;
# nokia-tclinux.py already takes --rootfs and --pad-kernel-to for it (kernel
# region padded to 4 MiB so the rootfs lands at a fixed slot offset).
#
# Header length must be 0x118 and the trailer must be the stock bootram - see
# board/nokia-tclinux.py.
#
# One container per profile, because the DTB is the difference: the flash
# profile's kernel is the one whose flag/flagback are writable, and the only one
# that may ever be written to NAND.  The DTB is checked in the shipped file with
# board/nokia-verify-dtb.py, so "the right tree got in" is asserted, not assumed.
# ---------------------------------------------------------------------------
TC_REV="$(cat version.buildinfo 2>/dev/null || echo snapshot)"
TC_LZMA="$PWD/../../../../staging_dir/host/bin/lzma"
if [ -x "$TC_LZMA" ]; then
	echo "    using $TC_LZMA (LZMA 4.65, same encoder the vendor image used)"
	TC_LZMA_ARG="--lzma-tool $TC_LZMA"
else
	echo "    WARNING: no host lzma binary, falling back to python liblzma"
	TC_LZMA_ARG=""
fi
for d in $DEVICES; do
	echo ">>> Building the flashable HDR2 tclinux container ($d)"
	TC_KERNEL="openwrt-econet-en7528-${d}-initramfs-kernel.bin"
	TC_OUT="openwrt-econet-en7528-${d}-tclinux.bin"
	case "$d" in
	nokia_g2425g-a)
		DTB_ARGS="--read-only 15" ;;
	nokia_g2425g-a-flash)
		DTB_ARGS="--read-only 13 --writable flag,flagback" ;;
	*)
		DTB_ARGS="" ;;
	esac
	if [ -n "$DTB_ARGS" ]; then
		# shellcheck disable=SC2086
		python3 "$B_DIR/nokia-verify-dtb.py" "$TC_KERNEL" \
			--compatible nokia,g2425g-a $DTB_ARGS
	fi
	# shellcheck disable=SC2086
	python3 "$B_DIR/nokia-tclinux.py" build "$TC_KERNEL" \
		--trailer "$B_DIR/nokia_bootram.lzma" \
		--version "OpenWrt-${TC_REV}" \
		--out "$TC_OUT" $TC_LZMA_ARG
	python3 "$B_DIR/nokia-tclinux.py" verify "$TC_OUT"
done

# Checksums must be written *after* the container exists, or the entry is stale.
# OpenWrt's own `sha256sums` is generated by `make` - i.e. before this container
# is assembled, and, in a reused build tree, it can even list the previous run's
# container.  Drop both names first: the glob below is expanded before the
# redirection creates the new file, so a leftover SHA256SUMS would otherwise be
# hashed (and then truncated), leaving a bad line in the file.
rm -f sha256sums SHA256SUMS .sha256sums.tmp
find . -maxdepth 1 -type f ! -name 'SHA256SUMS' ! -name '.sha256sums.tmp' -print0 \
	| sort -z | xargs -0 sha256sum > .sha256sums.tmp
mv -f .sha256sums.tmp SHA256SUMS
sha256sum -c SHA256SUMS >/dev/null 2>&1 && echo "    SHA256SUMS verified" \
	|| { echo "ERROR: SHA256SUMS did not verify" >&2; exit 1; }
ls -l

echo ">>> Done"
echo
echo "    RAM profile    : openwrt-econet-en7528-nokia_g2425g-a-tclinux.bin"
echo "                     (every partition read-only; never write it to NAND)"
echo "    FLASH profile  : openwrt-econet-en7528-nokia_g2425g-a-flash-tclinux.bin"
echo "                     (the only image that may be flashed; see"
echo "                      FLASH_INSTALL_RUNBOOK.md in the parent repository)"
