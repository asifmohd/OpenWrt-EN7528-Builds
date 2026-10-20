
# ---------------------------------------------------------------------------
# Nokia G-2425G-A (Airtel XStream Fiber)
#
# This profile still defines NO IMAGES, so nothing here is a sysupgrade or
# factory artefact and no OpenWrt image machinery can produce something that
# gets written to NAND by accident.  The only thing `make` builds for this
# device is the flat kernel + appended-DTB initramfs image
# (openwrt-econet-en7528-nokia_g2425g-a-initramfs-kernel.bin), which is loaded
# into RAM and jumped to:
#
#     xmdm 80020000 <len>  then  jump 80020000
#
# Free bootbase: the loader decompresses to 0x80002000, the OpenWrt kernel is
# linked at 0x80020000, hence the 0x1E000 jump stub inside the flash container.
#
# The flashable image is assembled by build.sh *after* `make`, from that same
# initramfs kernel, by board/nokia-tclinux.py:
#
#     openwrt-econet-en7528-nokia_g2425g-a-tclinux.bin
#         HDR2 tclinux container: 0x118 header + LZMA kernel + vendor bootram
#         trailer (board/nokia_bootram.lzma, byte-identical to the stock slot 1
#         trailer).  This is the only file the TcBoot `flash`/`httpd` path can
#         consume; a bare kernel is not loadable from flash on this board
#         because stage-2 loads the *trailer*, not the kernel.
#
# Building it does not flash anything.  See FLASH_IMAGE.md in the parent
# repository for the layout, the verification and the remaining prerequisites.
# ---------------------------------------------------------------------------
define Device/nokia_g2425g-a
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := G-2425G-A
  DEVICE_DTS := en7528_nokia_g2425g-a
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7603 kmod-mt7615e kmod-mt7663-firmware-ap
endef
TARGET_DEVICES += nokia_g2425g-a
