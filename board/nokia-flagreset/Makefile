# SPDX-License-Identifier: GPL-2.0-only
#
# nokia-flagreset - keep the Nokia G-2425G-A TcBoot boot_fail_num counter below
# the point where the stage-2 bootloader fails over to the other A/B slot.
#
# Shipped ONLY in the flash profile (DEVICE_nokia_g2425g-a-flash), because it
# needs writable "flag"/"flagback" partitions. See FLAG_DECODE.md in the parent
# repository for the block layout and files/nokia-flagreset.init for the logic.
#
# selftest.sh next to this Makefile exercises the script off-device against a
# fake /proc/mtd and a fake mtd binary; it is not installed into the image.

include $(TOPDIR)/rules.mk

PKG_NAME:=nokia-flagreset
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

# Pure shell package: there is no source tarball to download, configure or
# compile, so both steps are stubbed out. The init script is installed straight
# from ./files below.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/nokia-flagreset
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Keep the Nokia G-2425G-A TcBoot boot_fail_num counter near zero
  DEPENDS:=+mtd
  PKGARCH:=all
endef

define Package/nokia-flagreset/description
  The TcBoot stage-2 bootloader increments flag.boot_fail_num on every start and
  fails over to the other A/B slot on the 9th. The vendor userspace clears the
  counter at boot; this init script does the same for OpenWrt, so a flashed
  install does not silently walk back to the stock image after nine reboots.
  It rewrites both copies (flag and flagback) with boot_fail_num = 0 and leaves
  every other byte of the block alone.
endef

define Package/nokia-flagreset/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/nokia-flagreset.init $(1)/etc/init.d/nokia-flagreset
endef

$(eval $(call BuildPackage,nokia-flagreset))
