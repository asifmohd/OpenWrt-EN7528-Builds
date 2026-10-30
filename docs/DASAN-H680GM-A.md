# DASAN H680GM-A (Airtel) — OpenWrt support

Airtel-supplied **Dasan/DZS H680GM-A** XPON ONT / router running OpenWrt
(EcoNet EN7528). This documents the device, how to build, how to install from
the stock firmware, and how to recover.

> Status: **boots and runs** (LAN switch, both Wi‑Fi radios, UBI overlay).
> The GPON/XPON optics are **not** supported (Huawei/HiSense LTY9775M module,
> no driver). Use it as an Ethernet/Wi‑Fi router/AP.

## Hardware
| | |
|---|---|
| SoC | EcoNet **EN7528** (en751221), MIPS 1004Kc, 4 CPUs |
| RAM | 256 MB |
| Flash | **128 MB** SPI‑NAND (Toshiba TC58CVG0S3H), BMT/BBT |
| Wi‑Fi | MediaTek **MT7603** (2.4 GHz) + **MT7615** (5 GHz), mt76 |
| Switch | MT7530 (DSA), 4× GbE LAN |
| Bootloader | EcoNet **"free bootbase"** v1.4 |

### NAND partition map (verified on-device via /proc/mtd)
```
0x000000000000-0x000000040000  bootloader (ro)
0x000000040000-0x000000080000  dzs            # board data + MAC (mac-base @0xa); A/B boot flag @0x49
0x000000080000-0x000002080000  tclinux        # OS A (kernel @0x80000 + rootfs @0x480000)
0x000002080000-0x000004080000  tclinux_slave  # OS B (stock kept here for recovery)
0x000004080000-0x0000040c0000  romfile        # vendor config
0x0000040c0000-0x0000060c0000  rwfs
0x0000060c0000-0x000006300000  reservearea    # Wi‑Fi EEPROM: 5G @0x40000, 2.4G @0x1c0000
```
OpenWrt uses OS A: kernel in `tclinux_kernel` (0x80000, 4 MB) and a UBI volume on
`tclinux_rootfs` (0x480000, 28 MB). `reservearea` holds the Wi‑Fi calibration;
the MAC comes from `dzs`.

## Build
```
# devices: dasan_h680gm-a-airtel (+ en7528_generic)
CONFIG_TARGET_econet=y
CONFIG_TARGET_econet_en7528=y
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_dasan_h680gm-a-airtel=y
```
The H680 image **must** use the free‑bootbase kernel wrapper, otherwise the
bootloader rejects it ("Bad trx header") and falls back to stock:
```
TRX_LOADADDR := 0x80002000
KERNEL := kernel-bin | append-dtb | tclinux-free-bootbase-jump | lzma | kernel-trx
```
Outputs: `...-dasan_h680gm-a-airtel-squashfs-tclinux.trx` (factory) and
`...-squashfs-sysupgrade.bin` (sysupgrade).

## Unlock (Airtel-locked units)
The stock Airtel firmware is locked. To get root and be able to flash:
1. Serial console on header **J7** (silk labels are host‑perspective — the
   board's TX is the pin marked **RX**): 3.3 V TTL, **115200 8N1**.
   Wire adapter: RX←board‑TX (J7 "RX"/pin 3), TX→board‑RX (J7 "TX"/pin 4), GND. Leave VCC.
2. Power on and spam a key to reach the bootloader `bldr>` (send **CR only**, not CRLF).
3. `customer DASAN` (default is `AIRTEL`), then a factory reset. The WebUI/telnet unlock.
4. `telnet 192.168.1.1` → `admin` / `1234` = root (busybox).

## Install from stock (first time)
With root on stock:
```
# get the factory trx onto the device (e.g. wget from a LAN HTTP server)
# write to OS A; vendor trx check rejects OpenWrt's header, so force (-f):
/userfs/bin/mtd -f -v write openwrt-...-tclinux.trx tclinux
# power-cycle (cold boot). The free bootbase boots OS A = OpenWrt.
```
After first boot, commit the boot slot so it is not reverted:
```
en75_chboot openwrt
```
Stock remains on OS B (`tclinux_slave`) for recovery.

## Later upgrades
`sysupgrade` from OpenWrt (keeps config): `sysupgrade openwrt-...-sysupgrade.bin`

## Networking note
The LAN bridge must contain the DSA user ports (`lan1 lan2 lan3 lan4`), not the
CPU port `eth0`.

## Recovery
- `en75_chboot factory` (or bootloader boot flag) → boot stock OS B.
- Bootloader TFTP recovery is also available.
