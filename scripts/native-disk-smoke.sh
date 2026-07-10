#!/bin/sh
# native-disk-smoke.sh — prove agnova's NATIVE_FILE disk backend does a full ESP install
# slice with NO parted/mkfs.fat/mcopy shell-out, validated by independent parsers. Phase-5.
#
# agnova execute --disk-backend=native-file --until bootloader runs three native ops against
# a loopback IMAGE FILE via the vendored gptwr-proven diskfmt builders + a file-offset sector
# primitive:
#   1. OP_PARTITION_DISK  → a GPT (protective MBR + primary/backup header + entry array)
#   2. OP_FORMAT_FS       → a FAT32 ESP (BPB + FSInfo + dual FAT + \EFI\BOOT + \boot), label ESP
#   3. OP_STAGE_FILE x2   → BOOTX64.EFI + the kernel streamed into the FAT
# Oracles: sgdisk (GPT), fsck.fat + mtools (FAT32 + descendable tree), and byte-identical
# mcopy of BOTH staged files.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGNOVA="$ROOT/build/agnova"
for t in sgdisk fsck.fat mcopy dd; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done
[ -x "$AGNOVA" ] || { echo "ERROR: build agnova first"; exit 1; }

WORK="$(mktemp -d /tmp/agnova-native-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/target.img"; ESPIMG="$WORK/esp.img"

# Staging sources: real gnoboot + kernel if present, else generated test payloads (a small
# single-FAT-sector file + a >1 MB multi-FAT-sector file). Either way mcopy+cmp proves byte-identity.
GNOBOOT="${GNOBOOT:-/home/macro/Repos/gnoboot/build/BOOTX64.EFI}"
KERNEL="${KERNEL:-/home/macro/Repos/agnos/build/agnos}"
[ -f "$GNOBOOT" ] || { GNOBOOT="$WORK/src-bootx64.efi"; head -c 30208 /dev/urandom > "$GNOBOOT"; }
[ -f "$KERNEL" ]  || { KERNEL="$WORK/src-kernel";       head -c 1400000 /dev/urandom > "$KERNEL"; }
echo "staging sources: BOOTX64.EFI=$(stat -c %s "$GNOBOOT") B  kernel=$(stat -c %s "$KERNEL") B"

dd if=/dev/zero of="$IMG" bs=1M count=2048 status=none   # 2 GiB target

echo "[1/3] agnova execute --disk-backend=native-file --until bootloader ..."
"$AGNOVA" execute --device "$IMG" --disk-backend=native-file --until bootloader \
    --user test --i-mean-it --gnoboot-src "$GNOBOOT" --kernel-src "$KERNEL" 2>&1 | sed 's/^/  /'

rc=0
echo "[2/3] GPT oracle (sgdisk)"
sgdisk -v "$IMG" >"$WORK/sg.out" 2>&1; sgdisk -p "$IMG" >>"$WORK/sg.out" 2>&1
grep -aiE "No problems|^   [12] " "$WORK/sg.out" | head -4 | sed 's/^/    /'
grep -aqi "No problems found" "$WORK/sg.out" && echo "  PASS: sgdisk accepts the GPT" || { echo "  FAIL: sgdisk problems"; rc=1; }

echo "[3/3] FAT oracle (fsck.fat + mtools) + byte-identical staged files"
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
    && echo "  PASS: \\boot\\agnos == source byte-for-byte ($(stat -c %s "$KERNEL") B, multi-FAT-sector chain)" \
    || { echo "  FAIL: kernel mismatch"; rc=1; }

echo ""
[ "$rc" -eq 0 ] && echo "native-disk-smoke: PASS — agnova did a full ESP install slice (GPT+FAT32+staging) natively, no parted/mkfs.fat/mcopy (Phase-5 bites 3-5)" || echo "native-disk-smoke: FAIL"
exit $rc
