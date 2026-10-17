
# ---------------------------------------------------------------------------
# Nokia G-2425G-A (Airtel XStream Fiber) - RAM-only profile
#
# This device intentionally defines NO IMAGES. The only artifact produced is
# the flat kernel + appended-DTB initramfs image
# (openwrt-econet-en7528-nokia_g2425g-a-initramfs-kernel.bin), which is meant
# to be loaded into RAM and jumped to. Nothing here can be flashed by accident.
#
# The bootloader decompresses/loads the kernel at KERNEL_LOADADDR (0x80020000),
# so a RAM boot is:  xmdm 0x80020000 <len>  then  jump 0x80020000.
# ---------------------------------------------------------------------------
define Device/nokia_g2425g-a
  DEVICE_VENDOR := Nokia
  DEVICE_MODEL := G-2425G-A
  DEVICE_DTS := en7528_nokia_g2425g-a
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7603 kmod-mt7615e kmod-mt7663-firmware-ap
endef
TARGET_DEVICES += nokia_g2425g-a
