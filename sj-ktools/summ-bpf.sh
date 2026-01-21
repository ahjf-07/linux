#!/bin/sh
set -eu

log=${1:-}
[ -n "$log" ] && [ -f "$log" ] || { echo "usage: $0 <bpf.selftests.log>" >&2; exit 1; }

EXIT_REAL=$(grep -c '^\[EXIT\]' "$log" || true)
EXIT_SKIP=$(grep -c '^\[EXIT\].*[[:space:]]4$' "$log" || true)
EXIT=$((EXIT_REAL - EXIT_SKIP))

PASS=$(grep -c '^\[PASS\]' "$log" || true)
FAIL=$(grep -c '^\[FAIL\]' "$log" || true)
SKIP=$(grep -c '^\[SKIP\]' "$log" || true)
SKIP=$((SKIP + EXIT_SKIP))

echo "==== bpf kselftest summary ===="
echo "PASS  : $PASS"
echo "FAIL  : $FAIL"
echo "SKIP  : $SKIP"
echo "EXIT  : $EXIT"

echo
echo "==== FAIL / EXIT details (rough classify) ===="

grep -nE '^\[FAIL\]|^\[EXIT\]' "$log" | while IFS= read -r line; do
  case "$line" in
    *"[EXIT]"*" 4")
      echo "[SKIP] $line (KSFT_SKIP=4)"
      ;;
    *"No such file or directory"*"/sys/kernel/btf/vmlinux"*|*"BTF"*|*"btf"*)
      echo "[ENV:BTF] $line"
      ;;
    *"mount"*"/sys/fs/bpf"*|*"bpffs"*|*"/sys/fs/bpf"*)
      echo "[ENV:bpffs] $line"
      ;;
    *"permission denied"*|*"Operation not permitted"*|*"EPERM"*)
      echo "[ENV:perm] $line"
      ;;
    *)
      echo "[CHECK] $line"
      ;;
  esac
done

echo
echo "==== verdict ===="
echo "CHECK failures; some may be environment-related (vng/user net/rootfs/toolchain)"

