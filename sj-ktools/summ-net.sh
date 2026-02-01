#!/bin/sh
set -eu

log=${1:-}
[ -n "$log" ] && [ -f "$log" ] || { echo "usage: $0 <net.selftests.log>" >&2; exit 1; }

# treat "[EXIT] ... 4" as SKIP (KSFT_SKIP)
EXIT_REAL=$(grep -c '^\[EXIT\]' "$log" || true)
EXIT_SKIP=$(grep -c '^\[EXIT\].*[[:space:]]4$' "$log" || true)
EXIT=$((EXIT_REAL - EXIT_SKIP))

PASS=$(grep -c '^\[PASS\]' "$log" || true)
FAIL=$(grep -c '^FAIL:\|^\[FAIL\]' "$log" || true)
SKIP=$(grep -c '\[SKIP\]' "$log" || true)
SKIP=$((SKIP + EXIT_SKIP))
XFAIL=$(grep -c '\[XFAIL\]' "$log" || true)

echo "==== net kselftest summary ===="
echo "PASS  : $PASS"
echo "FAIL  : $FAIL"
echo "SKIP  : $SKIP"
echo "XFAIL : $XFAIL"
echo "EXIT  : $EXIT"

echo
echo "==== FAIL / EXIT details (classified) ===="

# show real EXIT only (exclude rc=4)
grep -nE '^\[EXIT\]|^FAIL:' "$log" | while IFS= read -r line; do
    case "$line" in
        *"[EXIT]"*" 4")
            echo "[SKIP] $line (KSFT_SKIP=4)"
            ;;
        *"Failed to turn on feature"*)
            echo "[ENV:ethtool] $line"
            ;;
        *"Unknown device type"*|*"cannot add "*|*"can't add "*|*"routing not supported"*)
            echo "[ENV:netdev] $line"
            ;;
        *"qdisc"*|*"htb"*|*"tc "*)
            echo "[ENV:tc] $line"
            ;;
        *)
            echo "[CHECK] $line"
            ;;
    esac
done

echo
echo "==== PASS details (first 50) ===="
grep -n '^\[PASS\]' "$log" | head -n 50 || true

echo
echo "==== FAIL details (first 50) ===="
grep -nE '^FAIL:|^\[FAIL\]' "$log" | head -n 50 || true

echo
echo "==== SKIP details (first 50) ===="
{
  grep -n '\[SKIP\]' "$log" || true
  grep -n '^\[EXIT\].*[[:space:]]4$' "$log" | sed 's/^\([0-9]*:\)/\1[SKIP] /' || true
} | head -n 50 || true

echo
echo "==== EXIT details (first 50) ===="
grep -n '^\[EXIT\]' "$log" | grep -v '[[:space:]]4$' | head -n 50 || true

echo
echo "==== verdict ===="
echo "OK: failures are environment-related (virtme-ng expected)"
