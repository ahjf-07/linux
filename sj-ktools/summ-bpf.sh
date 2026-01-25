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

grep -E '^\[FAIL\]|^\[EXIT\]' "$log" | while IFS= read -r line; do
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
echo "==== bpf test_progs summary (json) ===="
json_dir="$(dirname "$log")/bpf-json"
json_files=$(ls "$json_dir"/*.json 2>/dev/null || true)
if [ -z "$json_files" ]; then
  echo "(no json summary files found under $json_dir)"
elif command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' $json_files
import json
import sys
from collections import Counter

totals = {"success": 0, "success_subtest": 0, "skipped": 0, "failed": 0}
fail_tests = Counter()
fail_subtests = Counter()

for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        print(f"[warn] failed to parse {path}: {exc}")
        continue

    for key in totals:
        if key in data and isinstance(data[key], int):
            totals[key] += data[key]

    for test in data.get("results", []):
        test_name = test.get("name", "<unknown>")
        if test.get("failed"):
            fail_tests[test_name] += 1
        for sub in test.get("subtests", []):
            if sub.get("failed"):
                sub_name = sub.get("name", "<unknown>")
                fail_subtests[f"{test_name}/{sub_name}"] += 1

print(f"success        : {totals['success']}")
print(f"success_subtest: {totals['success_subtest']}")
print(f"skipped        : {totals['skipped']}")
print(f"failed         : {totals['failed']}")

def dump_top(title, counter, n=20):
    print()
    print(title)
    if not counter:
        print("(none)")
        return
    for name, count in counter.most_common(n):
        print(f"{count:4d}  {name}")

dump_top("==== bpf failed tests (top 20) ====", fail_tests)
dump_top("==== bpf failed subtests (top 20) ====", fail_subtests)
PY
else
  echo "(python3 not found; unable to parse json summaries)"
fi

echo
echo "==== verdict ===="
echo "CHECK failures; some may be environment-related (vng/user net/rootfs/toolchain)"
