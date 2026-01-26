#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-l] [-s] [-S "path1 path2 ..."] [-c|-m] [-i] [-j N] [-r linux_root] [-o outdir]
  -l : use LLVM/clang (LLVM=1)
  -s : run sparse (C=1) for selected subtrees ONLY (default set if -S not given)
  -S : subtree list for sparse (space-separated paths under linux root)
       e.g. -S "net net/netfilter kernel/bpf"
  -c : clean (make clean, keeps .config)
  -m : mrproper (make mrproper, removes .config)
  -i : incremental (skip build steps if targets are up to date)
  -j : jobs (default: nproc)
  -r : kernel source tree root (default: pwd)
  -o : output dir (default: <linux_root>/../out/full-{gcc,clang})
USAGE
  exit 1
}

LLVM=0
SPARSE=0
SPARSE_SUBTREES=""
CLEAN=0
MRPROPER=0
INCREMENTAL=0
JOBS=$(nproc)
LINUX_ROOT=""
O=""

while getopts "lsS:cmij:r:o:h" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    s) SPARSE=1 ;;
    S) SPARSE_SUBTREES="$OPTARG" ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    i) INCREMENTAL=1 ;;
    j) JOBS="$OPTARG" ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    h|*) usage ;;
  esac
done

if [ "$CLEAN" -eq 1 ] && [ "$MRPROPER" -eq 1 ]; then
  echo "ERROR: -c and -m are mutually exclusive" >&2
  exit 1
fi

[ -n "$LINUX_ROOT" ] || LINUX_ROOT=$(pwd)
LINUX_ROOT=$(realpath -e "$LINUX_ROOT")

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KARCH=x86 ;;
  aarch64|arm64) KARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

if [ -z "$O" ]; then
  if [ "$LLVM" -eq 1 ]; then
    O="$LINUX_ROOT/../out/full-clang"
  else
    O="$LINUX_ROOT/../out/full-gcc"
  fi
fi

# IMPORTANT: canonicalize to eliminate ".." so kselftests OUTPUT won't become ".out/..."
O=$(realpath -m "$O")
mkdir -p "$O"

echo "[cfg] LINUX_ROOT=$LINUX_ROOT"
echo "[cfg] O=$O LLVM=$LLVM SPARSE=$SPARSE CLEAN=$CLEAN MRPROPER=$MRPROPER INCREMENTAL=$INCREMENTAL JOBS=$JOBS ARCH=$ARCH (KARCH=$KARCH)"

# Full build args: NO sparse here by design.
MAKE_FULL_ARGS=""
[ "$LLVM" -eq 1 ] && MAKE_FULL_ARGS="$MAKE_FULL_ARGS LLVM=1"

# Sparse args: used only for subtree sparse runs.
MAKE_SPARSE_ARGS="$MAKE_FULL_ARGS C=1 CHECK=sparse"

make_q_check() {
  local log=$1
  shift
  if "$@" -q >"$log" 2>&1; then
    return 0
  fi
  local rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "[build][error] make -q failed (see $log)" >&2
    sed -n '1,120p' "$log" >&2
    exit 2
  fi
  echo "[build] make -q reports not up to date (see $log)"
  return 1
}

if [ "$MRPROPER" -eq 1 ]; then
  echo "[build] mrproper (will remove .config)"
  make -C "$LINUX_ROOT" O="$O" mrproper 2>&1 | tee "$O/build.mrproper.log"
elif [ "$CLEAN" -eq 1 ]; then
  echo "[build] clean (keeps .config)"
  make -C "$LINUX_ROOT" O="$O" clean 2>&1 | tee "$O/build.clean.log"
fi

if [ ! -f "$O/.config" ]; then
  echo "ERROR: $O/.config missing. Run ./config-net.sh first." >&2
  echo "  e.g. ./config-net.sh -r \"$LINUX_ROOT\" -o \"$O\" $( [ "$LLVM" -eq 1 ] && echo "-l" )" >&2
  exit 1
fi

if [ "$INCREMENTAL" -eq 1 ] && [ -f "$O/.config" ]; then
  echo "[build] incremental mode: skip olddefconfig to protect timestamps" | tee "$O/build.olddefconfig.log"
else
  echo "[build] olddefconfig (non-interactive)"
  make -C "$LINUX_ROOT" O="$O" $MAKE_FULL_ARGS olddefconfig 2>&1 | tee "$O/build.olddefconfig.log"
fi

case "$KARCH" in
  x86)
    IMG_TGT="bzImage"
    IMG_PATH="$O/arch/x86/boot/bzImage"
    ;;
  arm64)
    IMG_TGT="Image"
    IMG_PATH="$O/arch/arm64/boot/Image"
    ;;
esac

echo "[build] kernel ($IMG_TGT + modules)  (no sparse)"
if [ "$INCREMENTAL" -eq 1 ]; then
  if make_q_check "$O/build.kernel.q.log" make -C "$LINUX_ROOT" O="$O" $MAKE_FULL_ARGS "$IMG_TGT" modules; then
    echo "[build] up to date: skip kernel build" | tee "$O/build.kernel.log"
  else
    make -C "$LINUX_ROOT" O="$O" $MAKE_FULL_ARGS -j"$JOBS" "$IMG_TGT" modules 2>&1 | tee "$O/build.kernel.log"
  fi
else
  make -C "$LINUX_ROOT" O="$O" $MAKE_FULL_ARGS -j"$JOBS" "$IMG_TGT" modules 2>&1 | tee "$O/build.kernel.log"
fi

echo "[build] headers_install"
if [ "$INCREMENTAL" -eq 1 ]; then
  if make_q_check "$O/build.headers.q.log" make -C "$LINUX_ROOT" O="$O" \
    headers_install INSTALL_HDR_PATH="$O/usr"; then
    echo "[build] up to date: skip headers_install" | tee "$O/build.headers.log"
  else
    make -C "$LINUX_ROOT" O="$O" headers_install \
      INSTALL_HDR_PATH="$O/usr" 2>&1 | tee "$O/build.headers.log"
  fi
else
  make -C "$LINUX_ROOT" O="$O" headers_install \
    INSTALL_HDR_PATH="$O/usr" 2>&1 | tee "$O/build.headers.log"
fi

KHDR="-isystem $(realpath "$O/usr/include")"

# Canonical OUTPUT for selftests to avoid ".out" path confusion
OUT_NET=$(realpath -m "$O/selftests-net")
mkdir -p "$OUT_NET"

echo "[build] selftests/net (OUTPUT=$OUT_NET)  (no sparse)"
if [ "$INCREMENTAL" -eq 1 ]; then
  if make_q_check "$O/build.selftests.net.q.log" \
    make -C "$LINUX_ROOT/tools/testing/selftests/net" \
    OUTPUT="$OUT_NET" \
    KHDR_INCLUDES="$KHDR" \
    $MAKE_FULL_ARGS; then
    echo "[build] up to date: skip selftests/net" | tee "$O/build.selftests.net.log"
  else
    make -C "$LINUX_ROOT/tools/testing/selftests/net" \
      OUTPUT="$OUT_NET" \
      KHDR_INCLUDES="$KHDR" \
      $MAKE_FULL_ARGS -j"$JOBS" 2>&1 | tee "$O/build.selftests.net.log"
  fi
else
  make -C "$LINUX_ROOT/tools/testing/selftests/net" \
    OUTPUT="$OUT_NET" \
    KHDR_INCLUDES="$KHDR" \
    $MAKE_FULL_ARGS -j"$JOBS" 2>&1 | tee "$O/build.selftests.net.log"
fi

# Sparse: subtree-only (do NOT mix into full build)
if [ "$SPARSE" -eq 1 ]; then
  if [ -z "$SPARSE_SUBTREES" ]; then
    # default set (tunable)
    SPARSE_SUBTREES="net net/netfilter kernel/bpf"
  fi

  echo "[sparse] subtree checks enabled"
  echo "[sparse] subtrees: $SPARSE_SUBTREES"

  # one log per subtree for grep/scan convenience
  for d in $SPARSE_SUBTREES; do
    # allow user to pass leading "./"
    d=${d#./}
    if [ ! -d "$LINUX_ROOT/$d" ]; then
      echo "[sparse][skip] not a directory: $d" >&2
      continue
    fi
    tag=$(echo "$d" | tr '/.' '__')
    log="$O/build.sparse.$tag.log"
    echo "[sparse] M=$d -> $log"
    make -C "$LINUX_ROOT" O="$O" $MAKE_SPARSE_ARGS -j"$JOBS" M="$d" 2>&1 | tee "$log"
  done
fi

echo "[out] kernel image: $IMG_PATH"
[ -f "$IMG_PATH" ] || echo "[warn] image not found at expected path (check log): $IMG_PATH"
echo "[done] build finished"
