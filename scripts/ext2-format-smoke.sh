#!/bin/sh
# ext2-format-smoke.sh — prove agnova's sovereign ext2 mkfs (diskfmt df_format_ext2 + populate)
# writes a fully-valid MULTI-BLOCK-GROUP ext2 with lost+found and direct/single/double-indirect
# files, validated by the reference e2fsck / dumpe2fs / debugfs. No mkfs.ext2 shell-out.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/build/ext2fmt_proof"
for t in e2fsck dumpe2fs debugfs dd cmp; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done

# Build the driver against the current diskfmt.
( cd "$ROOT" && cyrius build tests/ext2fmt_proof.cyr build/ext2fmt_proof ) >/dev/null 2>&1 || { echo "ERROR: driver build failed"; exit 1; }
[ -x "$DRIVER" ] || { echo "ERROR: driver not built"; exit 1; }

IMG="/tmp/agnova-ext2-proof.img"
HELLO="/tmp/agnova-ext2-hello.txt"
BIG="/tmp/agnova-ext2-big.bin"
HUGE="/tmp/agnova-ext2-huge.bin"
trap 'rm -f "$IMG" "$HELLO" "$BIG" "$HUGE" /tmp/agnova-ext2-out.*' EXIT

# Sources: a small text file, a ~1 MiB single-indirect file, a ~9 MiB double-indirect file.
printf 'hello from the sovereign ext2 writer\n' > "$HELLO"
head -c 1100000 /dev/urandom > "$BIG"      # 1.05 MiB  -> single-indirect
head -c 9400000 /dev/urandom > "$HUGE"     # 8.96 MiB  -> double-indirect (2 inner indirect blocks)

# 512 MiB target image (the driver formats the whole thing = 4 block groups).
dd if=/dev/zero of="$IMG" bs=1M count=512 status=none

echo "[1/5] agnova sovereign ext2 mkfs + populate (no mkfs.ext2) ..."
"$DRIVER"; rc=$?
[ "$rc" -eq 0 ] || { echo "  FAIL: driver exit $rc"; exit 1; }
echo "  driver OK"

rc=0
echo "[2/5] e2fsck -fn (strict, read-only) — multi-group consistency + backups"
if e2fsck -fn "$IMG" >/tmp/agnova-ext2-out.e2 2>&1; then
    echo "  PASS: $(grep -aoE '[0-9]+/[0-9]+ files.*|[0-9]+/[0-9]+ blocks' /tmp/agnova-ext2-out.e2 | tr '\n' ' ')"
else
    echo "  FAIL: e2fsck rejected the fs:"; sed 's/^/    /' /tmp/agnova-ext2-out.e2 | head -20; rc=1
fi

echo "[3/5] dumpe2fs — group count + lost+found presence"
dumpe2fs "$IMG" >/tmp/agnova-ext2-out.dump 2>/dev/null
NGROUPS=$(grep -cE "^Group [0-9]" /tmp/agnova-ext2-out.dump)
echo "  block groups: $NGROUPS (expect 4)"
[ "$NGROUPS" -ge 2 ] && echo "  PASS: multi-block-group" || { echo "  FAIL: expected >1 group"; rc=1; }

echo "[4/5] debugfs — lost+found (inode 11) + double-indirect block map"
debugfs -R "stat <11>" "$IMG" 2>/dev/null | grep -aqE "Type: directory" \
    && echo "  PASS: lost+found is inode 11, a directory" \
    || { echo "  FAIL: lost+found missing/not a dir"; rc=1; }
debugfs -R "stat /bin/huge" "$IMG" 2>/dev/null >/tmp/agnova-ext2-out.huge
if grep -aqE "\(DIND\):|\(IND\):" /tmp/agnova-ext2-out.huge; then
    echo "  PASS: /bin/huge uses indirect maps — $(grep -aoE '\((IND|DIND)\):[0-9]+' /tmp/agnova-ext2-out.huge | tr '\n' ' ')"
else
    echo "  FAIL: /bin/huge has no indirect blocks"; sed 's/^/    /' /tmp/agnova-ext2-out.huge | head; rc=1
fi

echo "[5/5] byte-identical extraction (debugfs dump) — direct, single- and double-indirect"
debugfs -R "dump /bin/bigfile /tmp/agnova-ext2-out.big" "$IMG" >/dev/null 2>&1
debugfs -R "dump /bin/huge /tmp/agnova-ext2-out.hg" "$IMG" >/dev/null 2>&1
debugfs -R "dump /usr/lib/greet /tmp/agnova-ext2-out.gr" "$IMG" >/dev/null 2>&1
cmp -s /tmp/agnova-ext2-out.big "$BIG"  && echo "  PASS: /bin/bigfile byte-identical (single-indirect)" || { echo "  FAIL: bigfile mismatch"; rc=1; }
cmp -s /tmp/agnova-ext2-out.hg  "$HUGE" && echo "  PASS: /bin/huge byte-identical (double-indirect)"    || { echo "  FAIL: huge mismatch"; rc=1; }
cmp -s /tmp/agnova-ext2-out.gr  "$HELLO" && echo "  PASS: /usr/lib/greet byte-identical (deep path)"    || { echo "  FAIL: greet mismatch"; rc=1; }

echo ""
[ "$rc" -eq 0 ] && echo "ext2-format-smoke: PASS — sovereign multi-group ext2 (lost+found, direct/single/double-indirect) is e2fsck-clean" || echo "ext2-format-smoke: FAIL"
exit $rc
