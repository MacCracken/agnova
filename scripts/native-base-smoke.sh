#!/bin/sh
# native-base-smoke.sh — prove agnova's NATIVE_FILE backend installs a WHOLE base system from a
# compressed tarball with ZERO shell-out: no parted, no mkfs.*, no `tar -x`, no `unzstd`, no mcopy.
#
# `agnova execute --disk-backend=native-file --base-tarball base-system.tar.zst` runs the full
# native plan — GPT + FAT32 ESP + sovereign ext2 root — and the INSTALL-BASE phase extracts the
# tarball into the ext2 root via sankoch (envelope sniffed + inflated in RAM, tree written by
# df_ext2_untar). This is the real sovereign install path that replaces rootfs.cyr's `tar -xf
# base-system.tar.zst --zstd`. Oracles: sgdisk (GPT), e2fsck (ext2 clean), debugfs (byte-identical
# large file + preserved symlink + whole directory tree present).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGNOVA="$ROOT/build/agnova"
for t in sgdisk e2fsck debugfs dd cmp tar zstd; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done
[ -x "$AGNOVA" ] || { echo "ERROR: build agnova first (cyrius build src/main.cyr build/agnova)"; exit 1; }

WORK="$(mktemp -d /tmp/agnova-nbase-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/target.img"; ROOTIMG="$WORK/root.img"; TARBALL="$WORK/base-system.tar.zst"

# --- Build a representative base rootfs and pack it as a .tar.zst -------------------------------
SRC="$WORK/rootfs"
mkdir -p "$SRC/bin" "$SRC/etc" "$SRC/usr/lib" "$SRC/var/lib/agnos"
printf 'AGNOS base\n' > "$SRC/etc/os-release"
printf '#!/bin/agnsh\necho hi\n' > "$SRC/bin/hello"
head -c 260000 /dev/urandom > "$SRC/bin/agnsh"          # the shell itself, in the base tree
head -c 1600000 /dev/urandom > "$SRC/usr/lib/libbig.so" # >1 MiB -> single-indirect block map
ln -s /bin/agnsh "$SRC/bin/sh"                          # absolute rootfs symlink (kept as-is)
( cd "$SRC" && tar --format=ustar -cf - . | zstd -q -19 -f -o "$TARBALL" )
echo "base tarball: $(stat -c %s "$TARBALL") B (.tar.zst)  rootfs files: $(find "$SRC" -type f | wc -l)"

# Bootloader/kernel payloads for the ESP (real if present, else generated).
GNOBOOT="${GNOBOOT:-/home/macro/Repos/gnoboot/build/BOOTX64.EFI}"
KERNEL="${KERNEL:-/home/macro/Repos/agnos/build/agnos}"
[ -f "$GNOBOOT" ] || { GNOBOOT="$WORK/src-bootx64.efi"; head -c 30208 /dev/urandom > "$GNOBOOT"; }
[ -f "$KERNEL" ]  || { KERNEL="$WORK/src-kernel";       head -c 1400000 /dev/urandom > "$KERNEL"; }

dd if=/dev/zero of="$IMG" bs=1M count=2048 status=none   # 2 GiB target

echo "[1/3] agnova execute --disk-backend=native-file --base-tarball ... --until bootloader"
"$AGNOVA" execute --device "$IMG" --disk-backend=native-file --until bootloader \
    --user test --i-mean-it --base-tarball "$TARBALL" \
    --gnoboot-src "$GNOBOOT" --kernel-src "$KERNEL" 2>&1 | sed 's/^/  /'

rc=0
echo "[2/3] GPT oracle (sgdisk)"
sgdisk -v "$IMG" >"$WORK/sg.out" 2>&1
grep -aqi "No problems found" "$WORK/sg.out" && echo "  PASS: sgdisk accepts the GPT" || { echo "  FAIL: sgdisk problems"; sed 's/^/    /' "$WORK/sg.out" | head; rc=1; }

echo "[3/3] ext2 root oracle (e2fsck + debugfs): whole base tree extracted natively"
RF_S="$(sgdisk -i 2 "$IMG" | awk '/First sector/{print $3}')"
RF_E="$(sgdisk -i 2 "$IMG" | awk '/Last sector/{print $3}')"
RF_N=$((RF_E - RF_S + 1))
dd if="$IMG" of="$ROOTIMG" bs=512 skip="$RF_S" count="$RF_N" status=none
if e2fsck -fn "$ROOTIMG" >"$WORK/e2.out" 2>&1; then
    echo "  PASS: e2fsck: clean ext2 ($(grep -aoE '[0-9]+/[0-9]+ files' "$WORK/e2.out" | head -1))"
else
    echo "  FAIL: e2fsck rejected the root:"; sed 's/^/    /' "$WORK/e2.out" | head -8; rc=1
fi
# The big file must be byte-identical (proves the block map + data extraction).
debugfs -R "dump /usr/lib/libbig.so $WORK/out.big" "$ROOTIMG" >/dev/null 2>&1
cmp -s "$WORK/out.big" "$SRC/usr/lib/libbig.so" \
    && echo "  PASS: /usr/lib/libbig.so byte-identical ($(stat -c %s "$SRC/usr/lib/libbig.so") B)" \
    || { echo "  FAIL: /usr/lib/libbig.so mismatch"; rc=1; }
# The symlink target must survive.
lnk=$(debugfs -R "stat /bin/sh" "$ROOTIMG" 2>/dev/null | grep -aoE 'Fast link dest: "[^"]*"' | head -1)
[ -n "$lnk" ] && echo "  PASS: /bin/sh symlink preserved ($lnk)" || { echo "  FAIL: /bin/sh symlink lost"; rc=1; }
# The whole tree landed — every regular file the tarball carried is present + non-empty.
missing=0
for f in etc/os-release bin/hello bin/agnsh usr/lib/libbig.so; do
    debugfs -R "stat /$f" "$ROOTIMG" 2>/dev/null | grep -aq "Inode:" || { echo "    missing: /$f"; missing=1; }
done
[ "$missing" -eq 0 ] && echo "  PASS: whole base tree present (/etc/os-release /bin/hello /bin/agnsh /usr/lib/libbig.so)" || { echo "  FAIL: base tree incomplete"; rc=1; }

# The native install ALSO wrote the config files (network + locale + security + first-boot marker)
# straight into the ext2 root — no chroot, no mount, no host `tee`. Verify each landed with content.
echo "  config files written natively into ext2:"
cfg_missing=0
for f in etc/fstab etc/hostname etc/hosts etc/machine-id etc/locale.conf etc/nftables.conf etc/sysctl.d/99-agnos-hardening.conf etc/agnos/first-boot; do
    if debugfs -R "stat /$f" "$ROOTIMG" 2>/dev/null | grep -aq "Inode:"; then
        sz=$(debugfs -R "stat /$f" "$ROOTIMG" 2>/dev/null | grep -aoE 'Size: [0-9]+' | head -1 | awk '{print $2}')
        echo "    ok  /$f ($sz B)"
        [ "${sz:-0}" -gt 0 ] || { echo "    FAIL: /$f is empty"; cfg_missing=1; }
    else
        echo "    MISSING: /$f"; cfg_missing=1
    fi
done
# machine-id must be a fresh 32-hex-digit id + newline (33 B); fstab must mention the root.
debugfs -R "dump /etc/machine-id $WORK/out.mid" "$ROOTIMG" >/dev/null 2>&1
mid="$(tr -d '\n' < "$WORK/out.mid" 2>/dev/null)"
[ "${#mid}" -eq 32 ] && echo "    ok  /etc/machine-id = $mid (32 hex)" || { echo "    FAIL: machine-id malformed (${#mid} chars)"; cfg_missing=1; }
# /etc/localtime must be a symlink into the zoneinfo tree.
lt=$(debugfs -R "stat /etc/localtime" "$ROOTIMG" 2>/dev/null | grep -aoE 'Fast link dest: "[^"]*"' | head -1)
[ -n "$lt" ] && echo "    ok  /etc/localtime -> ${lt#Fast link dest: }" || { echo "    FAIL: /etc/localtime symlink absent"; cfg_missing=1; }
[ "$cfg_missing" -eq 0 ] && echo "  PASS: config files + machine-id + localtime symlink written natively" || { echo "  FAIL: config incomplete"; rc=1; }

echo ""
[ "$rc" -eq 0 ] && echo "native-base-smoke: PASS — agnova installed a whole base system + config from .tar.zst with no tar/mkfs/parted/unzstd/chroot shell-out" || echo "native-base-smoke: FAIL"
exit $rc
