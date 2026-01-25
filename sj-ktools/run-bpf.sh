#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-f N] [--ff] [-l] [-r linux_root] [-o outdir] [-p cpus] [-m mem] [-j]
  -f N          fast mode: run N subtests from test_progs list (default: 30)
  --ff          faster mode: run 10 subtests from test_progs list
  -l            use LLVM build output default (../out/full-clang)
  -r linux_root kernel source tree root (default: pwd)
  -o outdir     explicit build output dir
  -p cpus       guest cpus (default: 2)
  -m mem        guest memory (default: 2G)
  -j            enable test_progs json summary
USAGE
  exit 1
}

FAST_LEVEL=0
FAST_COUNT=30
FASTER_COUNT=10
LLVM=0
LINUX_ROOT=""
O=""
CPUS=2
MEM=2G
JSON_ENABLE=0

_keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ff) FAST_LEVEL=2 ;;
    --full) FAST_LEVEL=0 ;;
    --) shift; break ;;
    --*) echo "unknown arg: $1" >&2; usage ;;
    *) _keep="$_keep $1" ;;
  esac
  shift
done
set -- $_keep "$@"

while getopts "f:lr:o:p:m:jh" opt; do
  case "$opt" in
    f)
      FAST_LEVEL=1
      FAST_COUNT="$OPTARG"
      ;;
    l) LLVM=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    p) CPUS="$OPTARG" ;;
    m) MEM="$OPTARG" ;;
    j) JSON_ENABLE=1 ;;
    h|*) usage ;;
  esac
done

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
JSON_DIR="$OUT/bpf-json"
GUEST="$OUT/guest-bpf.sh"

echo "[host] arch=$ARCH"
echo "[host] kernel=$KERNEL_IMAGE"
echo "[host] O=$O"
echo "[host] fast_level=$FAST_LEVEL"
[ -f "$KERNEL_IMAGE" ] || { echo "ERROR: kernel image not found: $KERNEL_IMAGE" >&2; exit 1; }

mkdir -p "$OUT"
if [ "$JSON_ENABLE" -eq 1 ]; then
  rm -rf "$JSON_DIR"
  mkdir -p "$JSON_DIR"
fi
: >"$LOG"

cat <<'GEOF' >"$GUEST"
#!/bin/sh
set +e

MODE=${MODE:-full}
JSON_ENABLE=${JSON_ENABLE:-0}
FAST_COUNT=${FAST_COUNT:-30}
FASTER_COUNT=${FASTER_COUNT:-10}

ROOT=$(pwd)
OUT="$ROOT/.kselftest-out"
LOG="$OUT/bpf.selftests.log"
JSON_DIR="$OUT/bpf-json"

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
  cmd="$1"; shift
  if [ "$JSON_ENABLE" -eq 1 ] && [ "$cmd" = "./test_progs" ]; then
    safe=$(echo "$name" | tr -cs 'A-Za-z0-9_.-' '_')
    json="$JSON_DIR/$safe.json"
    rm -f "$json"
    "$cmd" --json-summary "$json" "$@" >>"$LOG" 2>&1
  else
    "$cmd" "$@" >>"$LOG" 2>&1
  fi
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

cd "$ROOT/.kselftest-out/selftests-bpf" || exit 1
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
    # 极快：跑 N 个子用例（如果无法列出就退化为跑一遍 test_progs）
    t=$(pick_tests "$FASTER_COUNT")
    if [ -n "$t" ]; then
      run_cmd "test_progs -t $t" ./test_progs -t "$t"
    else
      run_cmd "test_progs (fallback)" ./test_progs
    fi
    echo "=== done (faster) ===" >>"$LOG"
    exit 0
    ;;
  fast)
    # 快：跑 N 个子用例（如果无法列出就跑一遍 test_progs）
    tests=$(pick_tests "$FAST_COUNT")
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
  2) EXEC="sh -c 'MODE=faster JSON_ENABLE=$JSON_ENABLE FASTER_COUNT=$FASTER_COUNT exec sh .kselftest-out/guest-bpf.sh'" ;;
  1) EXEC="sh -c 'MODE=fast   JSON_ENABLE=$JSON_ENABLE FAST_COUNT=$FAST_COUNT exec sh .kselftest-out/guest-bpf.sh'" ;;
  0) EXEC="sh -c 'JSON_ENABLE=$JSON_ENABLE exec sh .kselftest-out/guest-bpf.sh'" ;;
esac

vng --run "$KERNEL_IMAGE" \
  --user root --cpus "$CPUS" --memory "$MEM" --network user \
  --rw \
  --cwd "$HOST_LINUX_ROOT" \
  --exec "$EXEC"

echo "[host] done: $LOG"
