#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-f|-ff] [-l] [-r linux_root] [-o outdir] [-p cpus] [-m mem]
  -f            fast mode (small subset)
  -ff           faster mode (tiny subset)
  -l            use LLVM build output default (../out/full-clang)
  -r linux_root kernel source tree root (default: pwd)
  -o outdir     explicit build output dir
  -p cpus       guest cpus (default: 2)
  -m mem        guest memory (default: 2G)
USAGE
  exit 1
}

FAST_LEVEL=0
LLVM=0
LINUX_ROOT=""
O=""
CPUS=2
MEM=2G

# NOTE: -ff works because getopts sees it as -f -f
while getopts "flr:o:p:m:h" opt; do
  case "$opt" in
    f) FAST_LEVEL=$((FAST_LEVEL + 1)) ;;
    l) LLVM=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    p) CPUS="$OPTARG" ;;
    m) MEM="$OPTARG" ;;
    h|*) usage ;;
  esac
done
[ "$FAST_LEVEL" -gt 2 ] && FAST_LEVEL=2

[ -n "$LINUX_ROOT" ] || LINUX_ROOT=$(pwd)
HOST_LINUX_ROOT=$(realpath -e "$LINUX_ROOT")

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KARCH=x86 ;;
  aarch64|arm64) KARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

if [ -z "$O" ]; then
  if [ "$LLVM" -eq 1 ]; then
    O="$HOST_LINUX_ROOT/../out/full-clang"
  else
    O="$HOST_LINUX_ROOT/../out/full-gcc"
  fi
fi

if [ "$KARCH" = x86 ]; then
  KERNEL_IMAGE="$O/arch/x86/boot/bzImage"
else
  KERNEL_IMAGE="$O/arch/arm64/boot/Image"
fi

OUT="$HOST_LINUX_ROOT/.kselftest-out"
LOG="$OUT/bpf.selftests.log"
GUEST="$OUT/guest-bpf.sh"

echo "[host] arch=$ARCH"
echo "[host] kernel=$KERNEL_IMAGE"
echo "[host] O=$O"
echo "[host] fast_level=$FAST_LEVEL"
[ -f "$KERNEL_IMAGE" ] || { echo "ERROR: kernel image not found: $KERNEL_IMAGE" >&2; exit 1; }

mkdir -p "$OUT"
: >"$LOG"

cat <<'GEOF' >"$GUEST"
#!/bin/sh
set +e

MODE=${MODE:-full}

ROOT=$(pwd)
OUT="$ROOT/.kselftest-out"
LOG="$OUT/bpf.selftests.log"

append_hdr() {
  {
    echo "=== mode ==="
    echo "$MODE"
    echo "=== uname ==="
    uname -a
    echo "=== id ==="
    id
    echo "=== mounts ==="
    mount | sed -n '1,120p'
    echo "=== /sys/kernel/btf/vmlinux ==="
    ls -l /sys/kernel/btf/vmlinux 2>/dev/null || true
  } >>"$LOG" 2>&1
}

ensure_mounts() {
  mkdir -p /sys/fs/bpf /sys/kernel/debug
  mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf >>"$LOG" 2>&1 || true
  mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug >>"$LOG" 2>&1 || true
}

run_cmd() {
  name="$1"; shift
  echo "=== RUN $name ===" >>"$LOG"
  "$@" >>"$LOG" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "[PASS] $name" >>"$LOG"
  elif [ $rc -eq 4 ]; then
    echo "[SKIP] $name (KSFT_SKIP)" >>"$LOG"
  else
    echo "[EXIT] $name $rc" >>"$LOG"
    echo "[FAIL] $name" >>"$LOG"
  fi
  return 0
}

cd "$ROOT/tools/testing/selftests/bpf" || exit 1
ensure_mounts
append_hdr

# helper: pick first N tests if list supported
pick_tests() {
  n="$1"
  if ./test_progs -l >/dev/null 2>&1; then
    ./test_progs -l 2>/dev/null | awk 'NF{print $1}' | head -n "$n"
    return
  fi
  if ./test_progs --list >/dev/null 2>&1; then
    ./test_progs --list 2>/dev/null | awk 'NF{print $1}' | head -n "$n"
    return
  fi
  echo ""
}

case "$MODE" in
  faster)
    # 极快：跑 1 个子用例（如果无法列出就退化为跑一遍 test_progs）
    t=$(pick_tests 1)
    if [ -n "$t" ]; then
      run_cmd "test_progs -t $t" ./test_progs -t "$t"
    else
      run_cmd "test_progs (fallback)" ./test_progs
    fi
    echo "=== done (faster) ===" >>"$LOG"
    exit 0
    ;;
  fast)
    # 快：跑 3 个子用例（如果无法列出就跑一遍 test_progs）
    tests=$(pick_tests 3)
    if [ -n "$tests" ]; then
      for t in $tests; do
        run_cmd "test_progs -t $t" ./test_progs -t "$t"
      done
    else
      run_cmd "test_progs (fallback)" ./test_progs
    fi
    echo "=== done (fast) ===" >>"$LOG"
    exit 0
    ;;
esac

# full：跑全量（环境不支持会 SKIP/EXIT，交给 summ 分类）
run_cmd "test_progs" ./test_progs

echo "=== done (full) ===" >>"$LOG"
GEOF

chmod +x "$GUEST"

case "$FAST_LEVEL" in
  2) EXEC="sh -c 'MODE=faster exec sh .kselftest-out/guest-bpf.sh'" ;;
  1) EXEC="sh -c 'MODE=fast   exec sh .kselftest-out/guest-bpf.sh'" ;;
  0) EXEC="sh -c 'exec sh .kselftest-out/guest-bpf.sh'" ;;
esac

vng --run "$KERNEL_IMAGE" \
  --user root --cpus "$CPUS" --memory "$MEM" --network user \
  --rw \
  --cwd "$HOST_LINUX_ROOT" \
  --exec "$EXEC"

echo "[host] done: $LOG"

