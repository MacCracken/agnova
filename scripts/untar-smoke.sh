#!/bin/sh
# untar-smoke.sh — prove agnova's sovereign ext2 writer can POPULATE a root by extracting a ustar
# tarball (df_ext2_untar): regular files (direct + indirect), nested directories, and symlinks.
# The extracted tree is validated by e2fsck + debugfs against the original, byte-for-byte. No
# mkfs.ext2 and no `tar -x` into the image — agnova parses the tar and writes ext2 itself.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/build/untar_proof"
for t in tar e2fsck debugfs dd cmp; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done

( cd "$ROOT" && cyrius build tests/untar_proof.cyr build/untar_proof ) >/dev/null 2>&1 || { echo "ERROR: driver build failed"; exit 1; }
[ -x "$DRIVER" ] || { echo "ERROR: driver not built"; exit 1; }

WORK="$(mktemp -d /tmp/agnova-untar-XXXXXX)"
IMG="/tmp/agnova-untar.img"
TAR="/tmp/agnova-rootfs.tar"
trap 'rm -rf "$WORK" "$IMG" "$TAR" /tmp/agnova-untar-out.*' EXIT

# Build a small rootfs tree: nested dirs, a text file, a >1 MiB indirect file, and a symlink.
SRC="$WORK/rootfs"
mkdir -p "$SRC/bin" "$SRC/etc" "$SRC/usr/lib"
printf 'AGNOS base\n' > "$SRC/etc/os-release"
printf '#!/bin/agnsh\necho hi\n' > "$SRC/bin/hello"
head -c 1300000 /dev/urandom > "$SRC/usr/lib/libbig.so"     # >1 MiB -> single-indirect
ln -s /bin/agnsh "$SRC/bin/sh"                              # symlink

# ustar format, deterministic, no leading "./" surprises beyond what tar emits.
( cd "$SRC" && tar --format=ustar -cf "$TAR" . )
echo "tarball: $(stat -c %s "$TAR") B, $(tar -tf "$TAR" | wc -l) members"

dd if=/dev/zero of="$IMG" bs=1M count=256 status=none

echo "[1/4] agnova sovereign ext2 mkfs + UNTAR (no mkfs.ext2, no tar -x) ..."
"$DRIVER"; rc=$?
[ "$rc" -eq 0 ] || { echo "  FAIL: driver exit $rc"; exit 1; }
echo "  driver OK"

rc=0
echo "[2/4] e2fsck -fn — extracted tree consistency"
if e2fsck -fn "$IMG" >/tmp/agnova-untar-out.e2 2>&1; then
    echo "  PASS: $(grep -aoE '[0-9]+/[0-9]+ files' /tmp/agnova-untar-out.e2 | head -1)"
else
    echo "  FAIL: e2fsck rejected the fs:"; sed 's/^/    /' /tmp/agnova-untar-out.e2 | head -20; rc=1
fi

echo "[3/4] debugfs — tree shape + symlink"
for p in /bin/hello /etc/os-release /usr/lib/libbig.so; do
    debugfs -R "stat $p" "$IMG" 2>/dev/null | grep -aqE "Type: regular" \
        && echo "  PASS: $p is a regular file" || { echo "  FAIL: $p missing"; rc=1; }
done
LNK=$(debugfs -R "stat /bin/sh" "$IMG" 2>/dev/null)
echo "$LNK" | grep -aqE "Type: symlink|Fast link dest" \
    && echo "  PASS: /bin/sh is a symlink ($(echo "$LNK" | grep -aoE 'Fast link dest: .*' | head -1))" \
    || { echo "  FAIL: /bin/sh not a symlink"; rc=1; }

echo "[4/4] byte-identical extraction (debugfs dump)"
debugfs -R "dump /usr/lib/libbig.so /tmp/agnova-untar-out.big" "$IMG" >/dev/null 2>&1
debugfs -R "dump /etc/os-release /tmp/agnova-untar-out.rel" "$IMG" >/dev/null 2>&1
cmp -s /tmp/agnova-untar-out.big "$SRC/usr/lib/libbig.so" && echo "  PASS: /usr/lib/libbig.so byte-identical (indirect, from tar)" || { echo "  FAIL: libbig mismatch"; rc=1; }
cmp -s /tmp/agnova-untar-out.rel "$SRC/etc/os-release" && echo "  PASS: /etc/os-release byte-identical" || { echo "  FAIL: os-release mismatch"; rc=1; }

echo ""
[ "$rc" -eq 0 ] && echo "untar-smoke: PASS — agnova extracted a ustar rootfs into a sovereign ext2 (files/dirs/symlinks), e2fsck-clean" || echo "untar-smoke: FAIL"
exit $rc
