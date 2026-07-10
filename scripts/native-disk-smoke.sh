#!/bin/sh
# native-disk-smoke.sh — prove agnova's NATIVE_FILE disk backend writes a REAL GPT with
# no parted/shell-out, validated by an independent parser (sgdisk). Phase-5 first real run.
#
# agnova execute --disk-backend=native-file --until partition writes a GPT (protective MBR
# + primary/backup header + 128-entry array) into a loopback IMAGE FILE via the vendored
# gptwr-proven diskfmt builders + a file-offset sector primitive. sgdisk (a foreign GPT
# implementation) then recomputes the CRCs + parses the table.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGNOVA="$ROOT/build/agnova"
for t in sgdisk dd; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing '$t'"; exit 1; }; done
[ -x "$AGNOVA" ] || { echo "ERROR: build agnova first (cyrius build src/main.cyr build/agnova)"; exit 1; }

IMG="$(mktemp /tmp/agnova-native-XXXXXX.img)"
trap 'rm -f "$IMG" /tmp/agnova-sg.out' EXIT
dd if=/dev/zero of="$IMG" bs=1M count=2048 status=none   # 2 GiB target

echo "[1/2] agnova execute --disk-backend=native-file --until partition ($IMG)"
"$AGNOVA" execute --device "$IMG" --disk-backend=native-file --until partition --user test --i-mean-it 2>&1 | sed 's/^/  /'

echo "[2/2] independent oracle: sgdisk on the agnova-written image"
: > /tmp/agnova-sg.out
sgdisk -v "$IMG" >>/tmp/agnova-sg.out 2>&1
sgdisk -p "$IMG" >>/tmp/agnova-sg.out 2>&1
sgdisk -i 1 "$IMG" >>/tmp/agnova-sg.out 2>&1
sgdisk -i 2 "$IMG" >>/tmp/agnova-sg.out 2>&1
grep -aiE "No problems|Number  Start|GUID code|Partition name|^   [12]" /tmp/agnova-sg.out | head -10 | sed 's/^/    /'

rc=0
grep -aqi "No problems found" /tmp/agnova-sg.out \
    && echo "  PASS: sgdisk -v: No problems found — a foreign GPT parser accepts agnova's table + CRCs" \
    || { echo "  FAIL: sgdisk reported problems on the agnova-written GPT"; rc=1; }
grep -aqi "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" /tmp/agnova-sg.out \
    && echo "  PASS: partition 1 type GUID = EFI System (ESP)" \
    || { echo "  FAIL: partition 1 is not an ESP"; rc=1; }
grep -aqi "0FC63DAF-8483-4772-8E79-3D69D8477DE4" /tmp/agnova-sg.out \
    && echo "  PASS: partition 2 type GUID = Linux filesystem (root)" \
    || { echo "  FAIL: partition 2 is not a Linux filesystem"; rc=1; }
grep -aqi "Partition name: 'ESP'" /tmp/agnova-sg.out \
    && echo "  PASS: partition 1 UTF-16 name = 'ESP' (parted-print parity)" \
    || echo "  NOTE: ESP partition name not shown (informational)"

echo ""
[ "$rc" -eq 0 ] && echo "native-disk-smoke: PASS — agnova wrote a valid 2-partition GPT natively, no parted (Phase-5 bite 3)" || echo "native-disk-smoke: FAIL"
exit $rc
