#!/bin/sh
# native-disk-smoke.sh — prove agnova's NATIVE_FILE disk backend does a FULL native install
# (ESP + sovereign ext2 root) with NO parted/mkfs.fat/mkfs.ext2/mcopy shell-out, validated by
# independent parsers. Phase-5 + the ext2 rootfs arc.
#
# agnova execute --disk-backend=native-file --until bootloader runs the whole native plan against
# a loopback IMAGE FILE via the vendored gptwr-proven diskfmt builders + a file-offset sector
# primitive:
#   1. OP_PARTITION_DISK  → a GPT (protective MBR + primary/backup header + entry array)
#   2. OP_FORMAT_FS x2    → a FAT32 ESP (label ESP) + a journal-less ext2 root
#   3. OP_STAGE_FILE      → /bin/agnsh streamed into the ext2 root (dirs auto-created)
#   4. OP_STAGE_FILE x2   → BOOTX64.EFI + the kernel streamed into the FAT
# Oracles: sgdisk (GPT), fsck.fat + mtools (FAT32 + descendable tree) with byte-identical mcopy
# of both staged files, and e2fsck + debugfs (ext2 clean + byte-identical /bin/agnsh).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGNOVA="$ROOT/build/agnova"
for t in sgdisk fsck.fat mcopy dd e2fsck debugfs; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done
[ -x "$AGNOVA" ] || { echo "ERROR: build agnova first"; exit 1; }

WORK="$(mktemp -d /tmp/agnova-native-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/target.img"; ESPIMG="$WORK/esp.img"; ROOTIMG="$WORK/root.img"

# Staging sources: real gnoboot + kernel + agnsh if present, else generated test payloads (a small
# single-FAT-sector file + a >1 MB multi-sector file). Either way the parsers + cmp prove byte-identity.
GNOBOOT="${GNOBOOT:-/home/macro/Repos/gnoboot/build/BOOTX64.EFI}"
KERNEL="${KERNEL:-/home/macro/Repos/agnos/build/agnos}"
AGNSH="${AGNSH:-/home/macro/Repos/agnos/build/agnsh}"
[ -f "$GNOBOOT" ] || { GNOBOOT="$WORK/src-bootx64.efi"; head -c 30208 /dev/urandom > "$GNOBOOT"; }
[ -f "$KERNEL" ]  || { KERNEL="$WORK/src-kernel";       head -c 1400000 /dev/urandom > "$KERNEL"; }
[ -f "$AGNSH" ]   || { AGNSH="$WORK/src-agnsh";         head -c 260000 /dev/urandom > "$AGNSH"; }
echo "staging sources: BOOTX64.EFI=$(stat -c %s "$GNOBOOT") B  kernel=$(stat -c %s "$KERNEL") B  agnsh=$(stat -c %s "$AGNSH") B"

dd if=/dev/zero of="$IMG" bs=1M count=2048 status=none   # 2 GiB target

echo "[1/4] agnova execute --disk-backend=native-file --until bootloader ..."
"$AGNOVA" execute --device "$IMG" --disk-backend=native-file --until bootloader \
    --user test --i-mean-it --gnoboot-src "$GNOBOOT" --kernel-src "$KERNEL" --agnsh-src "$AGNSH" 2>&1 | sed 's/^/  /'

rc=0
echo "[2/4] GPT oracle (sgdisk)"
sgdisk -v "$IMG" >"$WORK/sg.out" 2>&1; sgdisk -p "$IMG" >>"$WORK/sg.out" 2>&1
grep -aiE "No problems|^   [12] " "$WORK/sg.out" | head -4 | sed 's/^/    /'
grep -aqi "No problems found" "$WORK/sg.out" && echo "  PASS: sgdisk accepts the GPT" || { echo "  FAIL: sgdisk problems"; rc=1; }

echo "[3/4] FAT oracle (fsck.fat + mtools) + byte-identical staged files"
# The ESP is partition 1: LBA 2048, 512 MiB (1048576 sectors).
dd if="$IMG" of="$ESPIMG" bs=512 skip=2048 count=1048576 status=none
if fsck.fat -n "$ESPIMG" >"$WORK/fsck.out" 2>&1; then
    echo "  PASS: fsck.fat: clean FAT32 ($(grep -aoE '[0-9]+ files' "$WORK/fsck.out" | head -1))"
else
    echo "  FAIL: fsck.fat rejected the ESP:"; sed 's/^/    /' "$WORK/fsck.out" | head -5; rc=1
fi
mcopy -i "$ESPIMG" ::/EFI/BOOT/BOOTX64.EFI "$WORK/out.efi" 2>/dev/null && cmp -s "$WORK/out.efi" "$GNOBOOT" \
    && echo "  PASS: \\EFI\\BOOT\\BOOTX64.EFI == source byte-for-byte ($(stat -c %s "$GNOBOOT") B)" \
    || { echo "  FAIL: BOOTX64.EFI mismatch"; rc=1; }
mcopy -i "$ESPIMG" ::/boot/agnos "$WORK/out.krn" 2>/dev/null && cmp -s "$WORK/out.krn" "$KERNEL" \
    && echo "  PASS: \\boot\\agnos == source byte-for-byte ($(stat -c %s "$KERNEL") B, multi-sector chain)" \
    || { echo "  FAIL: kernel mismatch"; rc=1; }

echo "[4/4] ext2 root oracle (e2fsck + debugfs) + byte-identical /bin/agnsh"
# The root is partition 2 — derive its LBA range from the GPT the installer just wrote.
RF_S="$(sgdisk -i 2 "$IMG" | awk '/First sector/{print $3}')"
RF_E="$(sgdisk -i 2 "$IMG" | awk '/Last sector/{print $3}')"
RF_N=$((RF_E - RF_S + 1))
dd if="$IMG" of="$ROOTIMG" bs=512 skip="$RF_S" count="$RF_N" status=none
if e2fsck -fn "$ROOTIMG" >"$WORK/e2.out" 2>&1; then
    echo "  PASS: e2fsck: clean ext2 ($(grep -aoE '[0-9]+/[0-9]+ files' "$WORK/e2.out" | head -1))"
else
    echo "  FAIL: e2fsck rejected the root:"; sed 's/^/    /' "$WORK/e2.out" | head -8; rc=1
fi
debugfs -R "dump /bin/agnsh $WORK/out.agnsh" "$ROOTIMG" >/dev/null 2>&1
if [ -f "$WORK/out.agnsh" ] && cmp -s "$WORK/out.agnsh" "$AGNSH"; then
    echo "  PASS: /bin/agnsh == source byte-for-byte ($(stat -c %s "$AGNSH") B, ext2 dir auto-created)"
else
    echo "  FAIL: /bin/agnsh mismatch or absent"; rc=1
fi

echo ""
[ "$rc" -eq 0 ] && echo "native-disk-smoke: PASS — agnova did a full native install (GPT+FAT32-ESP+ext2-root+staging), no parted/mkfs.fat/mkfs.ext2/mcopy" || echo "native-disk-smoke: FAIL"
exit $rc
