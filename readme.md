# OpenWrt snapshot builds for EN7528 devices

GitHub Actions that build OpenWrt for EcoNet EN7528 devices:

* **Nokia G-2425G-A** (Airtel XStream Fiber) - **RAM-only initramfs profile** (this fork)
* Generic EN7528 initramfs image

## Nokia G-2425G-A

The board file (`board/en7528_nokia_g2425g-a.dts`) is written for a device that
runs **entirely from RAM** and never writes flash. It produces a single artifact:

```
openwrt-econet-en7528-nokia_g2425g-a-initramfs-kernel.bin
```

That file is a flat MIPS kernel with the DTB and the whole root filesystem
(initramfs) appended, linked to load at **`0x80020000`**.

### Why there is no flash image

Installing to flash on this unit is gated by the vendor bootloader and the A/B
slot scheme, and the stock userland enforces image signatures. The RAM-only
image sidesteps all of that, which is exactly what we want for a first port.

The `&nand` node is kept enabled only so the real per-unit MAC addresses can be
read from the `ri` partition, and it deliberately omits
`econet,can-write-factory-bbt` and `econet,enable-remap`. With those omitted the
`en75_bmt` driver refuses to write the bad-block table, so NAND handling is
strictly read-only.

On top of that, **all 15 partitions in `&nand` are marked `read-only`**, so even a
stray `mtd write` / `flashcp` from an interactive shell is refused at the MTD
layer (`ofpart` turns the property into `mask_flags |= MTD_WRITEABLE`, clearing
the write permission). With the whole flash read-only, a power cycle is always a
clean return to stock.

`rootfs` intentionally does **not** carry `linux,rootfs`: `add_mtd_device()`
(`drivers/mtd/mtdcore.c`) reads that property and sets the kernel's `ROOT_DEV` to
the partition, i.e. "mount and boot user space from" it - the opposite of what
this RAM-only profile wants.

### Booting it from RAM

The EN7528 bootloader has a command menu (`Press any key in 3 secs to enter boot
command mode`) reachable over **UART**. To run this image without touching flash:

```
xmdm 0x80020000 <len>      # Xmodem the .bin into RAM
jump 0x80020000            # jump to the kernel entry
```

There is no kexec in the stock kernel, no netboot/TFTP command in the bootloader
(TFTP only exists inside the flash-writing multiupgrade path), and the NAND
"backdoor" is disabled, so UART is the only route for a true RAM-only boot.

### Known TODOs

* Wi-Fi calibration EEPROM is a per-unit file (`/configs/bin_ac/RT30xxEEPROM.bin`)
  on this board, not a raw flash region, so the mt76 radios start on chip
  defaults.
* LED / button GPIO map is only partly known; the keys node ships disabled.

## Generic EN7528

`en7528_generic-initramfs-kernel.bin` is the upstream generic image. It is a
useful fallback for a smoke test but does not drive this board's LAN/Wi-Fi/LEDs.

## Building

Push to `main` or to the `nokia-g2425g-a` branch, or run the workflow manually
(`workflow_dispatch`). Artifacts are attached to the workflow run; pushing a
`v*` tag also creates a release.

The build targets upstream OpenWrt (`openwrt/openwrt`, branch `main`).

## Building locally with Docker

Everything the build needs is baked into `Dockerfile`, so there is no need to
install the OpenWrt host toolchain on your machine.

```sh
# From this directory...
docker compose run --rm --build builder

# ...or from the repository root, via the wrapper:
../docker-build-firmware.sh
```

Finished firmware is copied to `artifacts/`
(`openwrt-econet-en7528-nokia_g2425g-a-initramfs-kernel.bin` and the generic
image). The first build takes a while (roughly an hour on CI); later builds are
much faster because the upstream checkout, `dl/`, `build_dir/` and ccache are
kept in the `openwrt-build` volume.

How it is wired:

* `./` is mounted **read-only** at `/src`; `docker/entrypoint.sh` rsyncs it into
  `/build/work` and runs `build.sh` there.
* The upstream OpenWrt tree and all build state live in the named volume
  `openwrt-build`, i.e. on a case-sensitive Linux filesystem inside the Docker
  VM. This matters: OpenWrt will not build on a case-insensitive bind mount
  (the default for a macOS working copy), and a volume is also far faster.
* `./artifacts` is bind-mounted out so the `.bin` files are easy to grab.

Useful commands:

```sh
../docker-build-firmware.sh shell     # interactive shell in the build tree
../docker-build-firmware.sh fresh     # wipe tree, reclone upstream, rebuild
../docker-build-firmware.sh clean     # remove container + build-volume
```

Override the upstream source with environment variables:

```sh
OPENWRT_REF=main OPENWRT_REPO=https://github.com/openwrt/openwrt.git \
  docker compose run --rm --build builder
```

Notes:

* On Apple Silicon the image builds natively as arm64 (no emulation); the target
  is still mipsel. `gcc-multilib` is only installed on amd64.
* Give Docker plenty of disk (an OpenWrt tree plus toolchain is tens of GB) and
  several CPUs for a reasonable build time.
