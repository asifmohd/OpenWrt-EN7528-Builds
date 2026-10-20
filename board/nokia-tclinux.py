#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
nokia-tclinux.py - wrap an OpenWrt kernel in a Nokia/EcoNet "HDR2" tclinux
container with a working bootram trailer, i.e. an image this board's TcBoot
can actually load from flash.

Why a container at all
----------------------
On a free-bootbase EN7528 (this board: "version 1.1 free bootbase"), the
stage-2 bootloader does not load the kernel.  It reads the flag block, picks
the A/B slot, then:

    #######bootram_size 80610
    #######kernel_size 4058784
    #######rootfs_size 23332542
    Uncompressing [LZMA] ...  done.        <- decompresses the *trailer*

and jumps into the decompressed trailer.  That trailer ("bootram", a build of
the vendor's tcboot.bin) is what reads the HDR2 header, decompresses the kernel
to the load address and jumps to it.  See FLAG_DECODE.md section 2 and the
boot.txt trace in the parent repository.

So a flashable slot must be:  header + LZMA kernel + [rootfs] + LZMA bootram.

Format details that matter (all verified against the stock mtd3 "linux" image)
-----------------------------------------------------------------------------
  * header length is **0x118**, and that exact value is baked into the vendor
    bootram (it reads the kernel at image_base + 0x118, it does not use the
    header field).  0x100 - what upstream's tclinux-trx.sh writes for the
    DASAN/JioFiber boards - would put the kernel 0x18 bytes early here.
  * CRC is JAMCRC (~zlib.crc32) over the whole payload
    (kernel + padding + rootfs + trailer).
  * `loadaddr` in the header is 0x80002000 (free bootbase).  Our kernel is
    linked at 0x80020000, so the compressed kernel must start with a jump:

        08008000 = j 0x80020000          (first word at 0x80002000)

    followed by 0x1E000-4 zero bytes so the kernel itself decompresses to
    exactly 0x80020000.  This is upstream's `tclinux-free-bootbase-jump`,
    reproduced here so the container can be assembled (and verified) without
    the OpenWrt image machinery.
  * the kernel LZMA stream is "LZMA alone": 13-byte header + data, with the
    real uncompressed size in the header (0x5d 00 00 80 00 = lc3 lp0 pb2,
    8 MiB dictionary, exactly what LZMA 4.65 `lzma e` emits by default).

Commands
--------
  build   <kernel> --out <image> [options]   assemble a container
  verify  <image> [options]                  check one, print PASS/FAIL

This script never touches a device and never writes flash.  It only reads and
writes local files.
"""

from __future__ import annotations

import argparse
import hashlib
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import zlib

# ---------------------------------------------------------------- constants ---

MAGIC = b"HDR2"

# 0x118 is not a style choice: the vendor bootram hardcodes it.
HDRLEN = 0x118

OFF = {
    "hdrlen": 0x04,
    "total_len": 0x08,
    "crc": 0x0C,
    "version": 0x10,
    "custom": 0x30,
    "kernel_len": 0x50,
    "rootfs_len": 0x54,
    "romfile_len": 0x58,
    "model": 0x5C,
    "loadaddr": 0x7C,
    "trailer_len": 0x9C,
}

# Free-bootbase boards decompress to 0x80002000; the OpenWrt kernel is linked
# at 0x80020000, which is 0x20000 further up.
LOADADDR = 0x80002000
KERNEL_LINK = 0x80020000

# j 0x80020000, little endian.
JUMP_STUB = struct.pack("<I", 0x08008000)
STUB_PAD = KERNEL_LINK - LOADADDR - len(JUMP_STUB)   # 0x1DFFC zero bytes

# The vendor bootram trailer, kept byte-identical to the one in the stock
# "linux" slot (mtd3, version 3FE49362IJHK33) this unit actually boots.
#   board/nokia_bootram.lzma   80610 bytes   LZMA alone
#   decompresses to 258048 bytes, the tcboot build dated 2020-12-30.
BOOTRAM_LZMA_SHA256 = \
    "7f9ffda1dfb7d0c48c96dfac723ea2ebe4c95ab08595f0f521f96e8c0603e2ef"
BOOTRAM_BIN_SHA256 = \
    "f07e40a0bef231f326eaa1ea504264190f6eb03c01a37ee276f1075445382f66"
BOOTRAM_BIN_SIZE = 258048

# A/B slot geometry (kernel partition table, confirmed against boot.txt).
SLOT0_OFFSET = 0x0080000
SLOT1_OFFSET = 0x2280000
SLOT_SIZE = 0x2200000

# LZMA parameters: identical to the stock kernel stream's header.
LZMA_PROPS = {"lc": 3, "lp": 0, "pb": 2, "dict_size": 0x800000}


# ------------------------------------------------------------------ helpers ---

def jamcrc(data: bytes) -> int:
    """This format's CRC: bitwise-NOT of the standard zlib CRC-32."""
    return (~zlib.crc32(data)) & 0xFFFFFFFF


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def put_str(buf: bytearray, off: int, text: str, width: int = 32) -> None:
    raw = text.encode("latin1")[:width - 1]
    buf[off:off + len(raw)] = raw


def get_str(blob: bytes, off: int, width: int = 32) -> str:
    return blob[off:off + width].split(b"\x00", 1)[0].decode("latin1")


def u32(blob: bytes, off: int) -> int:
    return struct.unpack_from("<I", blob, off)[0]


# --------------------------------------------------------------- LZMA encode ---

def lzma_encode(data: bytes, tool: str | None = None) -> bytes:
    """Return an LZMA-alone stream with the real uncompressed size in its header.

    With `tool` (the OpenWrt host LZMA 4.65 binary) this is exactly what the
    vendor bootloader is known to consume: default switches already mean
    lc3/lp0/pb2, an 8 MiB dictionary, known size and no end-of-stream marker.

    Without it, liblzma is used instead.  Same stream format, and the size field
    is patched to match; liblzma also appends an end-of-stream marker, which the
    decoder never reads because it stops at the declared output size.
    """
    if tool:
        with tempfile.TemporaryDirectory(prefix="nokia-lzma-") as td:
            src = os.path.join(td, "in.bin")
            dst = os.path.join(td, "out.lzma")
            with open(src, "wb") as fh:
                fh.write(data)
            subprocess.run([tool, "e", src, dst], check=True,
                           stdout=subprocess.DEVNULL)
            with open(dst, "rb") as fh:
                blob = fh.read()
    else:
        blob = lzma.compress(
            data,
            format=lzma.FORMAT_ALONE,
            filters=[{
                "id": lzma.FILTER_LZMA1,
                "dict_size": LZMA_PROPS["dict_size"],
                "lc": LZMA_PROPS["lc"],
                "lp": LZMA_PROPS["lp"],
                "pb": LZMA_PROPS["pb"],
                "mode": lzma.MODE_NORMAL,
                "nice_len": 128,
                "mf": lzma.MF_BT4,
            }],
        )
        blob = bytearray(blob)
        struct.pack_into("<Q", blob, 5, len(data))
        blob = bytes(blob)

    _check_lzma_header(blob, len(data))
    return blob


def _check_lzma_header(blob: bytes, want_size: int) -> None:
    if len(blob) < 13:
        raise ValueError("LZMA stream shorter than its 13-byte header")
    props = blob[0]
    lc, lp, pb = props % 9, (props // 9) % 5, props // 45
    dict_size = u32(blob, 1)
    size = struct.unpack_from("<Q", blob, 5)[0]
    if (lc, lp, pb) != (LZMA_PROPS["lc"], LZMA_PROPS["lp"], LZMA_PROPS["pb"]):
        raise ValueError(f"unexpected LZMA properties lc={lc} lp={lp} pb={pb}")
    if dict_size != LZMA_PROPS["dict_size"]:
        raise ValueError(f"unexpected LZMA dictionary 0x{dict_size:08x}")
    if size != want_size:
        raise ValueError(f"LZMA header size {size} != payload {want_size}")


def lzma_decode(blob: bytes, expect_size: int | None = None) -> bytes:
    """Decode an LZMA-alone stream, using the declared size when it is known."""
    size = struct.unpack_from("<Q", blob, 5)[0]
    if size != 0xFFFFFFFFFFFFFFFF and expect_size is not None and size != expect_size:
        raise ValueError(f"LZMA header size {size} != expected {expect_size}")
    return lzma.decompress(blob, format=lzma.FORMAT_ALONE)


# ------------------------------------------------------------------- build ---

def build_payload(kernel: bytes) -> bytes:
    """Stub + zero pad + kernel: what the free-bootbase loader decompresses."""
    return JUMP_STUB + b"\x00" * STUB_PAD + kernel


def build_container(kernel_lzma: bytes, trailer_lzma: bytes, *,
                    version: str, model: str = "",
                    rootfs: bytes = b"", pad_kernel_to: int = 0) -> bytes:
    kernel_region = kernel_lzma
    if pad_kernel_to:
        if len(kernel_region) > pad_kernel_to:
            raise ValueError(
                f"compressed kernel {len(kernel_region)} > pad target {pad_kernel_to}")
        kernel_region += b"\xFF" * (pad_kernel_to - len(kernel_region))

    payload = kernel_region + rootfs + trailer_lzma
    total = HDRLEN + len(payload)

    hdr = bytearray(HDRLEN)
    hdr[0:4] = MAGIC
    struct.pack_into("<I", hdr, OFF["hdrlen"], HDRLEN)
    struct.pack_into("<I", hdr, OFF["total_len"], total)
    struct.pack_into("<I", hdr, OFF["crc"], jamcrc(payload))
    put_str(hdr, OFF["version"], version)
    put_str(hdr, OFF["custom"], "")
    struct.pack_into("<I", hdr, OFF["kernel_len"], len(kernel_region))
    struct.pack_into("<I", hdr, OFF["rootfs_len"], len(rootfs))
    struct.pack_into("<I", hdr, OFF["romfile_len"], 0)
    put_str(hdr, OFF["model"], model)
    struct.pack_into("<I", hdr, OFF["loadaddr"], LOADADDR)
    struct.pack_into("<I", hdr, OFF["trailer_len"], len(trailer_lzma))
    return bytes(hdr) + payload


# ------------------------------------------------------------------ verify ---

class Report:
    def __init__(self) -> None:
        self.items: list[tuple[bool, str, str]] = []

    def add(self, ok: bool, what: str, detail: str = "") -> bool:
        self.items.append((bool(ok), what, detail))
        return bool(ok)

    def dump(self) -> None:
        for ok, what, detail in self.items:
            print(f"  [{'PASS' if ok else 'FAIL'}] {what:<44} {detail}")

    @property
    def ok(self) -> bool:
        return all(ok for ok, _, _ in self.items)


def verify(image_path: str, *, expect_bootram: bool = True,
           max_size: int = SLOT_SIZE, quiet: bool = False) -> bool:
    r = Report()
    blob = open(image_path, "rb").read()
    r.add(blob[:4] == MAGIC, "magic is HDR2", blob[:4].decode("latin1", "replace"))

    if blob[:4] != MAGIC:
        r.dump()
        return False

    hdrlen = u32(blob, OFF["hdrlen"])
    total = u32(blob, OFF["total_len"])
    klen = u32(blob, OFF["kernel_len"])
    rlen = u32(blob, OFF["rootfs_len"])
    tlen = u32(blob, OFF["trailer_len"])
    loadaddr = u32(blob, OFF["loadaddr"])

    r.add(hdrlen == HDRLEN, "header length is 0x118 (bootram hardcodes it)",
          f"0x{hdrlen:x}")
    r.add(hdrlen + klen + rlen + tlen == total,
          "declared lengths add up",
          f"{hdrlen}+{klen}+{rlen}+{tlen} == {total}")
    r.add(total <= len(blob), "file holds the declared image",
          f"{total} <= {len(blob)} bytes")
    r.add(loadaddr == LOADADDR, "load address is 0x80002000",
          f"0x{loadaddr:08x}")

    payload = blob[hdrlen:total]
    crc_stored = u32(blob, OFF["crc"])
    crc_calc = jamcrc(payload)
    r.add(crc_stored == crc_calc, "JAMCRC over the payload matches",
          f"0x{crc_stored:08x}")

    # --- kernel ------------------------------------------------------------
    klz = payload[:klen]
    decoded = b""
    try:
        decoded = lzma_decode(klz)
        r.add(True, "kernel LZMA stream decodes", f"{len(decoded)} bytes")
    except Exception as exc:                      # noqa: BLE001 - report only
        r.add(False, "kernel LZMA stream decodes", str(exc))

    if decoded:
        first = struct.unpack_from("<I", decoded, 0)[0]
        r.add(first == 0x08008000,
              "first word is 'j 0x80020000' (free bootbase stub)",
              f"0x{first:08x}")
        r.add(len(decoded) == len(JUMP_STUB) + STUB_PAD + (len(decoded) - STUB_PAD - 4),
              "stub + 0x1DFFC zero pad + kernel",
              f"kernel starts at +0x{STUB_PAD + len(JUMP_STUB):x}")
        pad = decoded[len(JUMP_STUB):STUB_PAD + len(JUMP_STUB)]
        r.add(pad.count(0) == len(pad), "pad between stub and kernel is all zero",
              f"{len(pad)} bytes")
        # The kernel image itself must stay 4-byte aligned.
        r.add((STUB_PAD + len(JUMP_STUB)) % 4 == 0, "kernel offset is 4-byte aligned")

    # --- rootfs ------------------------------------------------------------
    if rlen:
        rs = payload[klen:klen + rlen]
        r.add(rs[:4] == b"hsqs", "rootfs at declared offset is squashfs",
              rs[:4].decode("latin1", "replace"))

    # --- trailer -----------------------------------------------------------
    tlz = payload[klen + rlen:]
    r.add(len(tlz) == tlen, "trailer at declared offset", f"{len(tlz)} bytes")
    r.add(sha256(tlz) == BOOTRAM_LZMA_SHA256, "trailer is the stock vendor bootram",
          sha256(tlz)[:16] + "...")
    try:
        bootram = lzma_decode(tlz)
        r.add(sha256(bootram) == BOOTRAM_BIN_SHA256,
              "bootram decompresses to the known tcboot",
              f"{len(bootram)} bytes")
        if expect_bootram:
            r.add(len(bootram) == BOOTRAM_BIN_SIZE,
                  "bootram decompressed size", str(len(bootram)))
    except Exception as exc:                      # noqa: BLE001 - report only
        r.add(False, "bootram LZMA stream decodes", str(exc))

    # --- slot fit ----------------------------------------------------------
    r.add(total <= max_size, "fits one A/B slot",
          f"{total} <= {max_size} (0x{max_size:x})")

    if not quiet:
        print(f"verify {image_path}")
        print(f"  size {len(blob)} (0x{len(blob):x})  sha256 {sha256(blob)}")
        print(f"  version {get_str(blob, OFF['version'])!r}  "
              f"model {get_str(blob, OFF['model'])!r}")
        r.dump()
    return r.ok


# --------------------------------------------------------------------- CLI ---

def cmd_build(args) -> int:
    kernel = open(args.kernel, "rb").read()
    trailer = open(args.trailer, "rb").read()
    rootfs = open(args.rootfs, "rb").read() if args.rootfs else b""

    got = sha256(trailer)
    if got != BOOTRAM_LZMA_SHA256:
        print(f"ERROR: {args.trailer} is not the stock bootram trailer\n"
              f"       sha256 {got}\n"
              f"       expected {BOOTRAM_LZMA_SHA256}", file=sys.stderr)
        return 2

    payload = build_payload(kernel)
    kernel_lzma = lzma_encode(payload, tool=args.lzma_tool)
    image = build_container(kernel_lzma, trailer,
                            version=args.version, model=args.model,
                            rootfs=rootfs,
                            pad_kernel_to=args.pad_kernel_to)

    with open(args.out, "wb") as fh:
        fh.write(image)

    encoder = args.lzma_tool or "python/lib lzma"
    print(f"built {args.out}")
    print(f"  kernel     {len(kernel)} -> {len(kernel_lzma)} bytes LZMA "
          f"(+0x{len(JUMP_STUB) + STUB_PAD:x} stub/pad, {encoder})")
    if rootfs:
        print(f"  rootfs     {len(rootfs)} bytes")
    print(f"  trailer    {len(trailer)} bytes (stock bootram)")
    print(f"  image      {len(image)} bytes (0x{len(image):x})")
    print(f"  sha256     {sha256(image)}")

    if not verify(args.out):
        print("ERROR: the image just built does not verify", file=sys.stderr)
        return 1
    return 0


def cmd_verify(args) -> int:
    ok = verify(args.image, max_size=args.max_size)
    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="assemble an HDR2 tclinux container")
    b.add_argument("kernel", help="raw MIPS kernel (DTB appended), not compressed")
    b.add_argument("--out", required=True)
    b.add_argument("--trailer", required=True,
                   help="vendor bootram, LZMA alone (board/nokia_bootram.lzma)")
    b.add_argument("--rootfs", default=None,
                   help="optional squashfs; omitted for a kernel-only image")
    b.add_argument("--version", default="OpenWrt",
                   help="version string, max 31 chars")
    # Empty by default: the stock images carry an empty model field, and
    # nothing in the bootram or stage-2 reads it.  Keep it empty to keep the
    # container as close to a known-good stock image as possible.
    b.add_argument("--model", default="")
    b.add_argument("--pad-kernel-to", type=lambda s: int(s, 0), default=0,
                   help="0xFF-pad the compressed kernel region to N bytes so the "
                        "rootfs offset is constant (e.g. 0x400000)")
    b.add_argument("--lzma-tool", default=None,
                   help="LZMA 4.65 binary (openwrt staging_dir/host/bin/lzma); "
                        "defaults to python's liblzma")
    b.set_defaults(func=cmd_build)

    v = sub.add_parser("verify", help="verify an HDR2 tclinux container")
    v.add_argument("image")
    v.add_argument("--max-size", type=lambda s: int(s, 0), default=SLOT_SIZE)
    v.set_defaults(func=cmd_verify)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
