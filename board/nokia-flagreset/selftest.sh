#!/bin/sh
# Off-device selftest for files/nokia-flagreset.init.
#
# Everything here runs on the build machine: a fake /proc/mtd, fake /dev nodes
# holding a real 0x38-byte boot-flag block, and a fake `mtd` that records what
# it was asked to do. No device, no flash, no U-Boot.
#
#   ./selftest.sh          (exit 0 = all cases behave)
#
set -u

INIT="$(cd "$(dirname "$0")" && pwd)/files/nokia-flagreset.init"
SB="$(mktemp -d)"
export SB   # the fake mtd below reads $SB from the environment
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/dev" "$SB/bin" "$SB/tmp"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok() { echo "  ok: $*"; }

# --- fixtures -------------------------------------------------------------

# little-endian u32, values in 0..255 are all this test needs
u32() { printf "\\$(printf '%03o' "$1")\\000\\000\\000"; }

# mkflag <file> <commit> <next_active> <image0> <image1> <boot_fail_num> <active>
mkflag() {
	f=$1
	{
		u32 "$2"; u32 "$3"; u32 "$4"; u32 "$5"; u32 "$6"; u32 "$7"
		i=0
		while [ $i -lt 32 ]; do printf '\377'; i=$((i + 1)); done
	} > "$f"
}

field_hex() { hexdump -v -s "$2" -n 4 -e '4/1 "%02x"' "$1"; }

# /proc/mtd with flag as mtd11 and flagback as mtd12 (the RAM-boot numbering,
# which is also what a flashed slot 1 should produce)
mkmtd() {
	{
		echo "dev:    size   erasesize  name"
		echo 'mtd0: 00040000 00020000 "bootloader"'
		echo 'mtd1: 00040000 00020000 "romfile"'
		echo 'mtd2: 02200000 00020000 "image0"'
		echo 'mtd3: 02200000 00020000 "linux"'
		echo 'mtd4: 01defb8 00020000 "rootfs"'
		echo 'mtd10: 00040000 00020000 "log"'
		if [ "${1:-yes}" = yes ]; then
			echo 'mtd11: 00040000 00020000 "flag"'
		fi
		echo 'mtd12: 00040000 00020000 "flagback"'
		echo 'mtd13: 00040000 00020000 "data"'
	} > "$SB/proc_mtd"
}

cat > "$SB/bin/mtd" <<'FAKE'
#!/bin/sh
# fake `mtd write <file> <partition>`: record it, simulate erase+program
printf '%s\n' "$*" >> "$SB/calls"
[ "${1:-}" = write ] || exit 2
part="$3"
if [ -e "$SB/ro_$part" ]; then
	echo "mtd: cannot open $part for writing: Read-only file system" >&2
	exit 1
fi
cp "$2" "$SB/dev/part_$part.bin"
FAKE
chmod 0755 "$SB/bin/mtd"

# run_init: run the script's start() against the sandbox
run_init() {
	(
		PROC_MTD="$SB/proc_mtd" DEV_DIR="$SB/dev" MTD_BIN="$SB/bin/mtd" \
			TMPDIR="$SB/tmp" LOGGER_BIN=true
		export PROC_MTD DEV_DIR MTD_BIN TMPDIR LOGGER_BIN
		. "$INIT"
		start
	) > "$SB/out" 2>&1
	return $?
}

reset_sandbox() {
	rm -f "$SB/calls" "$SB/out" "$SB/dev"/mtd* "$SB/dev"/part_*.bin "$SB/ro_"*
	mkmtd
}

# --- case 1: counter below the threshold -> no writes ---------------------
reset_sandbox
mkflag "$SB/dev/mtd11ro" 1 1 0 1 2 1
run_init && ok "bfn=2: exit 0" || fail "bfn=2: non-zero exit"
[ -s "$SB/calls" ] && fail "bfn=2: wrote something ($(cat "$SB/calls"))" || ok "bfn=2: no writes"

# --- case 2: counter at the threshold -> both copies rewritten ------------
reset_sandbox
mkflag "$SB/dev/mtd11ro" 1 1 0 1 4 1
run_init && ok "bfn=4: exit 0" || fail "bfn=4: non-zero exit"
if [ "$(sed -n 1p "$SB/calls" 2>/dev/null | awk '{print $1, $3}')" = "write flag" ] &&
	[ "$(sed -n 2p "$SB/calls" 2>/dev/null | awk '{print $1, $3}')" = "write flagback" ]; then
	ok "bfn=4: flag written first, then flagback"
else
	fail "bfn=4: unexpected writes: $(cat "$SB/calls" 2>/dev/null | tr '\n' '|')"
fi
for p in flag flagback; do
	if [ ! -f "$SB/dev/part_$p.bin" ]; then
		fail "bfn=4: $p was not written"
		continue
	fi
	[ "$(field_hex "$SB/dev/part_$p.bin" 16)" = 00000000 ] ||
		fail "bfn=4: $p boot_fail_num is $(field_hex "$SB/dev/part_$p.bin" 16), want 00000000"
	[ "$(field_hex "$SB/dev/part_$p.bin" 0)" = 01000000 ] || fail "bfn=4: $p commit changed"
	[ "$(field_hex "$SB/dev/part_$p.bin" 4)" = 01000000 ] || fail "bfn=4: $p next_active changed"
	[ "$(field_hex "$SB/dev/part_$p.bin" 8)" = 00000000 ] || fail "bfn=4: $p image0_is_valid changed"
	[ "$(field_hex "$SB/dev/part_$p.bin" 12)" = 01000000 ] || fail "bfn=4: $p image1_is_valid changed"
	[ "$(field_hex "$SB/dev/part_$p.bin" 20)" = 01000000 ] || fail "bfn=4: $p active changed"
	[ "$(wc -c < "$SB/dev/part_$p.bin" | tr -d ' ')" = 56 ] || fail "bfn=4: $p file is not 56 bytes"
done
[ -s "$SB/calls" ] && ok "bfn=4: boot_fail_num cleared in both copies, other fields intact"

# --- case 3: counter at 9 (one boot from failover) -------------------------
reset_sandbox
mkflag "$SB/dev/mtd11ro" 1 1 0 1 9 1
run_init && ok "bfn=9: exit 0" || fail "bfn=9: non-zero exit"
[ "$(field_hex "$SB/dev/part_flag.bin" 16 2>/dev/null)" = 00000000 ] &&
	ok "bfn=9: cleared" || fail "bfn=9: not cleared"

# --- case 4: blank/garbage block -> nothing written ------------------------
reset_sandbox
head -c 56 /dev/zero | tr '\0' '\377' > "$SB/dev/mtd11ro"
run_init || fail "garbage: non-zero exit"
[ -s "$SB/calls" ] && fail "garbage: wrote something" || ok "garbage: no writes"

# --- case 5: sane-looking block with a nonsense field ---------------------
reset_sandbox
mkflag "$SB/dev/mtd11ro" 5 1 0 1 7 1
run_init || fail "commit=5: non-zero exit"
[ -s "$SB/calls" ] && fail "commit=5: wrote something" || ok "commit=5: no writes"

# --- case 6: no "flag" partition -----------------------------------------
reset_sandbox
mkmtd no
mkflag "$SB/dev/mtd11ro" 1 1 0 1 7 1
run_init || fail "no flag mtd: non-zero exit"
[ -s "$SB/calls" ] && fail "no flag mtd: wrote something" || ok "no flag mtd: no writes"

# --- case 7: read-only flag (the RAM profile) ----------------------------
reset_sandbox
mkflag "$SB/dev/mtd11ro" 1 1 0 1 7 1
: > "$SB/ro_flag"
run_init || fail "ro flag: non-zero exit"
[ "$(sed -n 1p "$SB/calls" 2>/dev/null | awk '{print $1, $3}')" = "write flag" ] ||
	fail "ro flag: expected one attempt on flag"
[ -f "$SB/dev/part_flagback.bin" ] && fail "ro flag: flagback written anyway" ||
	ok "ro flag: flag refused, flagback not touched"

# --- case 8: the ro node is preferred even when a rw node exists ----------
reset_sandbox
mkflag "$SB/dev/mtd11" 1 1 0 1 5 1 # sane rw node ...
: > "$SB/dev/mtd11ro"              # ... but the ro node wins and is empty
run_init || fail "short read: non-zero exit"
[ -s "$SB/calls" ] && fail "short read: wrote something" || ok "short read: no writes (ro node preferred)"

echo
if [ "$FAILED" = 0 ]; then
	echo "ALL CASES PASSED"
	exit 0
fi
echo "SELFTEST FAILED" >&2
exit 1
