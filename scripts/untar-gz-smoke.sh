#!/bin/sh
# untar-gz-smoke.sh — prove agnova extracts a COMPRESSED ustar rootfs into a sovereign ext2 for
# every envelope its tar cursor sniffs: gzip / xz / bzip2 / zstd. sankoch inflates the archive in
# RAM (df_ext2_untar via tar_open_auto), then writes the tree into ext2 — no `gunzip`/`unzstd`,
# no `tar -x`, no mkfs.ext2, no temp file. Validated by e2fsck + debugfs, byte-for-byte. The
# .tar.zst case is the real base-system install path.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/build/untargz_proof"
for t in tar gzip xz bzip2 zstd e2fsck debugfs dd cmp; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done

( cd "$ROOT" && cyrius build tests/untargz_proof.cyr build/untargz_proof ) >/dev/null 2>&1 || { echo "ERROR: driver build failed"; exit 1; }
[ -x "$DRIVER" ] || { echo "ERROR: driver not built"; exit 1; }

WORK="$(mktemp -d /tmp/agnova-untargz-XXXXXX)"
IMG="/tmp/agnova-untargz.img"
TGZ="/tmp/agnova-rootfs.tar.gz"    # the driver reads this fixed path (any envelope; cursor sniffs)
trap 'rm -rf "$WORK" "$IMG" "$TGZ" /tmp/agnova-untargz-out.*' EXIT

SRC="$WORK/rootfs"
mkdir -p "$SRC/bin" "$SRC/etc" "$SRC/usr/lib"
printf 'AGNOS base\n' > "$SRC/etc/os-release"
printf '#!/bin/agnsh\necho hi\n' > "$SRC/bin/hello"
head -c 1600000 /dev/urandom > "$SRC/usr/lib/libbig.so"     # >1 MiB -> single-indirect
ln -s /bin/agnsh "$SRC/bin/sh"

rc=0
for env in gz xz bz2 zst; do
    case "$env" in
        gz)  ( cd "$SRC" && tar --format=ustar -czf "$TGZ" . ) ;;
        xz)  ( cd "$SRC" && tar --format=ustar -cJf "$TGZ" . ) ;;
        bz2) ( cd "$SRC" && tar --format=ustar -cjf "$TGZ" . ) ;;
        zst) ( cd "$SRC" && tar --format=ustar -cf - . | zstd -q -19 -f -o "$TGZ" ) ;;
    esac
    dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
    "$DRIVER"; d=$?
    if [ "$d" -ne 0 ]; then echo "  FAIL [$env]: driver exit $d"; rc=1; continue; fi
    if ! e2fsck -fn "$IMG" >/tmp/agnova-untargz-out.e2 2>&1; then
        echo "  FAIL [$env]: e2fsck rejected the fs:"; sed 's/^/    /' /tmp/agnova-untargz-out.e2 | head -8; rc=1; continue
    fi
    debugfs -R "dump /usr/lib/libbig.so /tmp/agnova-untargz-out.big" "$IMG" >/dev/null 2>&1
    lnk=$(debugfs -R "stat /bin/sh" "$IMG" 2>/dev/null | grep -aoE 'Fast link dest: "[^"]*"' | head -1)
    if cmp -s /tmp/agnova-untargz-out.big "$SRC/usr/lib/libbig.so" && [ -n "$lnk" ]; then
        echo "  PASS [$env]: e2fsck-clean, /usr/lib/libbig.so byte-identical, symlink ($lnk)"
    else
        echo "  FAIL [$env]: libbig mismatch or symlink lost"; rc=1
    fi
done

echo ""
[ "$rc" -eq 0 ] && echo "untar-gz-smoke: PASS — agnova extracts .tar.{gz,xz,bz2,zst} into a sovereign ext2 (sankoch cursor), e2fsck-clean" || echo "untar-gz-smoke: FAIL"
exit $rc
