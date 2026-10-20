#!/usr/bin/env python3
"""Verify the device tree OpenWrt appended to an econet/en7528 kernel image.

The initramfs kernel .bin is a flat MIPS image with a DTB appended at the end.
This reads that DTB out of the shipped file - no assumptions, no recompiling -
and reports which fixed-partitions are marked read-only, so a build can assert
that the RAM profile kept all 15 partitions protected and the flash profile
freed exactly "flag" and "flagback".

Usage:
    nokia-verify-dtb.py KERNEL.bin --read-only 15
    nokia-verify-dtb.py KERNEL.bin --read-only 13 --writable flag,flagback
    nokia-verify-dtb.py KERNEL.bin --compatible nokia,g2425g-a --verbose

Exit status 0 on success, 1 on any mismatch (so build.sh -e stops).
"""

import argparse
import struct
import sys

MAGIC = b"\xd0\x0d\xfe\xed"
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def extract(data):
    """Return (offset, dtb) for the DTB appended at the very end of the file."""
    off = data.rfind(MAGIC)
    if off < 0:
        raise SystemExit("no FDT magic found in the image")
    total = struct.unpack(">I", data[off + 4:off + 8])[0]
    if off + total > len(data):
        raise SystemExit(
            "DTB header at 0x%x claims %d bytes, past the end of the file (%d)"
            % (off, total, len(data)))
    slack = len(data) - (off + total)
    if slack > 3:
        raise SystemExit(
            "DTB at 0x%x ends %d bytes before the end of the file - not the "
            "appended DTB" % (off, slack))
    return off, data[off:off + total]


def parse(dtb):
    """Return [(path, {prop: bytes})] in tree order."""
    if dtb[:4] != MAGIC:
        raise SystemExit("bad FDT magic")
    off_struct, off_strings = struct.unpack(">II", dtb[8:16])
    nodes = []
    stack = []
    pos = off_struct
    while True:
        tag = struct.unpack(">I", dtb[pos:pos + 4])[0]
        pos += 4
        if tag == FDT_BEGIN_NODE:
            end = dtb.index(b"\0", pos)
            name = dtb[pos:end].decode("latin-1")
            pos = (end + 4) & ~3
            stack.append(name)
            nodes.append(("/" + "/".join(n for n in stack if n), {}))
        elif tag == FDT_END_NODE:
            stack.pop()
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack(">II", dtb[pos:pos + 8])
            pos += 8
            value = dtb[pos:pos + length]
            pos = (pos + length + 3) & ~3
            end = dtb.index(b"\0", off_strings + nameoff)
            pname = dtb[off_strings + nameoff:end].decode("latin-1")
            nodes[-1][1][pname] = value
        elif tag == FDT_NOP:
            pass
        elif tag == FDT_END:
            break
        else:
            raise SystemExit("unknown FDT tag %d at 0x%x" % (tag, pos - 4))
    return nodes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--read-only", type=int, default=None,
                    help="expected number of read-only partitions")
    ap.add_argument("--writable", default=None,
                    help="comma-separated partition labels that must NOT be read-only")
    ap.add_argument("--compatible", default=None,
                    help="expected first string of the root compatible property")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        data = f.read()
    off, dtb = extract(data)
    nodes = parse(dtb)

    root = nodes[0][1]
    compatible = root.get("compatible", b"").split(b"\0")
    compatible = [c.decode("latin-1") for c in compatible if c]

    def label(props):
        # fixed-partitions labels are NUL-terminated strings
        return props["label"].split(b"\0")[0].decode("latin-1")

    # Only the mtd fixed-partitions, not the DSA user ports (which also carry
    # a "label" + "reg" pair).
    partitions = [(path, props) for path, props in nodes
                  if "/partitions/" in path and "label" in props and "reg" in props]
    readonly = [label(props) for _, props in partitions if "read-only" in props]
    writable = [label(props) for _, props in partitions if "read-only" not in props]

    print("DTB at 0x%x, %d bytes, %d partitions" % (off, len(dtb), len(partitions)))
    print("  compatible: %s" % " ".join(compatible))
    if args.verbose:
        for label in readonly:
            print("  read-only: %s" % label)
        for label in writable:
            print("  writable : %s" % label)

    failed = False
    if args.compatible and (not compatible or compatible[0] != args.compatible):
        print("FAIL: compatible[0] is %r, want %r"
              % (compatible[0] if compatible else None, args.compatible))
        failed = True
    if args.read_only is not None and len(readonly) != args.read_only:
        print("FAIL: %d read-only partitions, want %d (%s)"
              % (len(readonly), args.read_only, ", ".join(sorted(readonly))))
        failed = True
    if args.writable:
        want = [w for w in args.writable.split(",") if w]
        for label in want:
            if label not in writable:
                print("FAIL: %r is not writable" % label)
                failed = True
        extra = sorted(set(writable) - set(want))
        if extra:
            print("FAIL: unexpected writable partitions: %s" % ", ".join(extra))
            failed = True

    if failed:
        return 1
    print("  OK: %d read-only, writable: %s"
          % (len(readonly), ", ".join(writable) if writable else "(none)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
