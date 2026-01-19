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
LOG="$OUT/net.selftests.log"
GUEST="$OUT/guest-net.sh"

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
LOG="$OUT/net.selftests.log"

{
  echo "=== mode ==="
  echo "$MODE"
  echo "=== uname ==="
  uname -a
  echo "=== id ==="
  id
} >>"$LOG" 2>&1

cd "$ROOT/tools/testing/selftests/net" || exit 1

run_bash() {
  f="$1"
  echo "=== RUN bash $f ===" >>"$LOG"
  [ -f "$f" ] || { echo "[SKIP] $f" >>"$LOG"; return; }
  bash "$f" >>"$LOG" 2>&1
  rc=$?
  [ $rc -eq 4 ] && echo "[SKIP] bash $f (KSFT_SKIP)" >>"$LOG"
  [ $rc -ne 0 ] && [ $rc -ne 4 ] && echo "[EXIT] bash $f $rc" >>"$LOG"
}

run_exec() {
  f="$1"
  echo "=== RUN $f ===" >>"$LOG"
  [ -x "$f" ] || { echo "[SKIP] $f" >>"$LOG"; return; }
  "$f" >>"$LOG" 2>&1
  rc=$?
  [ $rc -eq 4 ] && echo "[SKIP] $f (KSFT_SKIP)" >>"$LOG"
  [ $rc -ne 0 ] && [ $rc -ne 4 ] && echo "[EXIT] $f $rc" >>"$LOG"
}

case "$MODE" in
  faster)
    # 极快：只验证最核心的二进制用例能跑通
    run_exec ./run_netsocktests
    echo "=== done (faster) ===" >>"$LOG"
    exit 0
    ;;
  fast)
    # 快：核心二进制 + 一个稳定脚本
    run_exec ./run_netsocktests
    run_exec ./run_afpackettests
    run_bash ./fcnal-test.sh
    echo "=== done (fast) ===" >>"$LOG"
    exit 0
    ;;
esac

# full：尽量覆盖（slirp/user 网络下 pmtu 可能慢且不稳）
run_exec ./run_netsocktests
run_exec ./run_afpackettests
run_bash ./fcnal-test.sh
run_bash ./fib_tests.sh
run_bash ./fib_nexthops.sh
run_bash ./rtnetlink.sh
run_bash ./netdevice.sh
run_bash ./pmtu.sh

echo "=== done (full) ===" >>"$LOG"
GEOF

chmod +x "$GUEST"

case "$FAST_LEVEL" in
  2) EXEC="sh -c 'MODE=faster exec sh .kselftest-out/guest-net.sh'" ;;
  1) EXEC="sh -c 'MODE=fast   exec sh .kselftest-out/guest-net.sh'" ;;
  0) EXEC="sh -c 'exec sh .kselftest-out/guest-net.sh'" ;;
esac

vng --run "$KERNEL_IMAGE" \
  --user root --cpus "$CPUS" --memory "$MEM" --network user \
  --rw \
  --cwd "$HOST_LINUX_ROOT" \
  --exec "$EXEC"

echo "[host] done: $LOG"
