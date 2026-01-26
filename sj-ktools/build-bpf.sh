#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-l] [-s] [-S "path1 path2 ..."] [-c|-m] [-i] [-j N] [-r linux_root] [-o outdir]
  -l : use LLVM/clang (LLVM=1)
  -s : run sparse (C=1) for selected subtrees ONLY
  -S : subtree list for sparse (space-separated paths under linux root)
       e.g. -S "kernel/bpf net/core"
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

O=$(realpath -m "$O")
mkdir -p "$O"

echo "[cfg] LINUX_ROOT=$LINUX_ROOT"
echo "[cfg] O=$O LLVM=$LLVM SPARSE=$SPARSE CLEAN=$CLEAN MRPROPER=$MRPROPER INCREMENTAL=$INCREMENTAL JOBS=$JOBS ARCH=$ARCH (KARCH=$KARCH)"

MAKE_FULL_ARGS=""

# ---- toolchain selection (prefer llvm/clang-20) + non-interactive Kconfig ----
export KCONFIG_NONINTERACTIVE=1

pick_llvm_tool() {
  # usage: pick_llvm_tool base [ver]
  _base="$1"
  _ver="${2:-20}"
  if command -v "${_base}-${_ver}" >/dev/null 2>&1; then
    echo "${_base}-${_ver}"
  elif command -v "${_base}${_ver}" >/dev/null 2>&1; then
    echo "${_base}${_ver}"
  elif command -v "${_base}" >/dev/null 2>&1; then
    echo "${_base}"
  else
    echo ""
  fi
}

if [ "$LLVM" -eq 1 ]; then
  CLANG_VER="${CLANG_VER:-20}"

  CC_BIN="$(pick_llvm_tool clang "$CLANG_VER")"
  LLD_BIN="$(pick_llvm_tool ld.lld "$CLANG_VER")"
  AR_BIN="$(pick_llvm_tool llvm-ar "$CLANG_VER")"
  NM_BIN="$(pick_llvm_tool llvm-nm "$CLANG_VER")"
  OBJCOPY_BIN="$(pick_llvm_tool llvm-objcopy "$CLANG_VER")"
  OBJDUMP_BIN="$(pick_llvm_tool llvm-objdump "$CLANG_VER")"
  STRIP_BIN="$(pick_llvm_tool llvm-strip "$CLANG_VER")"
  READELF_BIN="$(pick_llvm_tool llvm-readelf "$CLANG_VER")"

  # host tools：默认用 gcc，避免 host link/PIE/环境差异；你要 host clang 自己 export HOSTCC=clang-20
  HOSTCC_BIN="${HOSTCC:-gcc}"
  HOSTCXX_BIN="${HOSTCXX:-g++}"

  [ -n "$CC_BIN" ] || { echo "ERROR: clang not found (wanted clang-$CLANG_VER)" >&2; exit 2; }
  [ -n "$LLD_BIN" ] || { echo "ERROR: ld.lld not found (wanted ld.lld-$CLANG_VER)" >&2; exit 2; }
  [ -n "$AR_BIN" ] || { echo "ERROR: llvm-ar not found (wanted llvm-ar-$CLANG_VER)" >&2; exit 2; }

  echo "[tc] LLVM=1 prefer clang-$CLANG_VER"
  echo "[tc] CC=$CC_BIN LD=$LLD_BIN AR=$AR_BIN NM=${NM_BIN:-<auto>}"
  echo "[tc] HOSTCC=$HOSTCC_BIN HOSTCXX=$HOSTCXX_BIN"

  MAKE_FULL_ARGS="$MAKE_FULL_ARGS LLVM=1 LLVM_IAS=1"
  MAKE_FULL_ARGS="$MAKE_FULL_ARGS CC=$CC_BIN LD=$LLD_BIN"
  MAKE_FULL_ARGS="$MAKE_FULL_ARGS AR=$AR_BIN"
  [ -n "$NM_BIN" ] && MAKE_FULL_ARGS="$MAKE_FULL_ARGS NM=$NM_BIN"
  [ -n "$OBJCOPY_BIN" ] && MAKE_FULL_ARGS="$MAKE_FULL_ARGS OBJCOPY=$OBJCOPY_BIN"
  [ -n "$OBJDUMP_BIN" ] && MAKE_FULL_ARGS="$MAKE_FULL_ARGS OBJDUMP=$OBJDUMP_BIN"
  [ -n "$STRIP_BIN" ] && MAKE_FULL_ARGS="$MAKE_FULL_ARGS STRIP=$STRIP_BIN"
  [ -n "$READELF_BIN" ] && MAKE_FULL_ARGS="$MAKE_FULL_ARGS READELF=$READELF_BIN"

  MAKE_FULL_ARGS="$MAKE_FULL_ARGS HOSTCC=$HOSTCC_BIN HOSTCXX=$HOSTCXX_BIN"
else
  # gcc path
  MAKE_FULL_ARGS="$MAKE_FULL_ARGS CC=${CC:-gcc} HOSTCC=${HOSTCC:-gcc}"
fi

MAKE_SPARSE_ARGS="$MAKE_FULL_ARGS C=1 CHECK=sparse"

echo "[cfg] KCONFIG_NONINTERACTIVE=${KCONFIG_NONINTERACTIVE:-0}" >&2

echo "==================================="

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
  echo "ERROR: $O/.config missing. Run ./config-bpf.sh first." >&2
  exit 1
fi

if [ "$INCREMENTAL" -eq 1 ] && [ -f "$O/.config" ]; then
  echo "[build] incremental mode: skip olddefconfig to protect timestamps" | tee "$O/build.olddefconfig.log"
else
  echo "[build] olddefconfig (non-interactive)"
  make -C "$LINUX_ROOT" O="$O" $MAKE_FULL_ARGS olddefconfig 2>&1 | tee "$O/build.olddefconfig.log"
fi

case "$KARCH" in
  x86)   IMG_TGT="bzImage"; IMG_PATH="$O/arch/x86/boot/bzImage" ;;
  arm64) IMG_TGT="Image";  IMG_PATH="$O/arch/arm64/boot/Image" ;;
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

OUT_BPF=$(realpath -m "$LINUX_ROOT/.kselftest-out/selftests-bpf")
mkdir -p "$OUT_BPF"

CLANG_ARG=""
if [ "$LLVM" -eq 1 ]; then
  [ -n "${CC_BIN:-}" ] || { echo "ERROR: CC_BIN empty while LLVM=1" >&2; exit 2; }
  CLANG_ARG="CLANG=$CC_BIN"
fi

orig=$(make -C "$LINUX_ROOT/tools/testing/selftests/bpf" -pn \
  O="$O" OUTPUT="$OUT_BPF" KHDR_INCLUDES="$KHDR" \
  $CLANG_ARG \
  $MAKE_FULL_ARGS \
  | sed -n 's/^BPF_CFLAGS = //p' | head -n 1)

echo "[build] selftests/bpf (OUTPUT=$OUT_BPF)  (no sparse)"
if [ "$INCREMENTAL" -eq 1 ]; then
  if make_q_check "$O/build.selftests.bpf.q.log" \
    make -C "$LINUX_ROOT/tools/testing/selftests/bpf" \
    O="$O" OUTPUT="$OUT_BPF" \
    KHDR_INCLUDES="$KHDR" \
    VMLINUX_BTF="$O/vmlinux" \
    BPFTOOL="$OUT_BPF/tools/sbin/bpftool" \
    $CLANG_ARG \
    BPF_CFLAGS="$orig" \
    $MAKE_FULL_ARGS; then
    echo "[build] up to date: skip selftests/bpf" | tee "$O/build.selftests.bpf.log"
  else
    make -C "$LINUX_ROOT/tools/testing/selftests/bpf" \
      O="$O" OUTPUT="$OUT_BPF" \
      KHDR_INCLUDES="$KHDR" \
      VMLINUX_BTF="$O/vmlinux" \
      BPFTOOL="$OUT_BPF/tools/sbin/bpftool" \
      $CLANG_ARG \
      BPF_CFLAGS="$orig" \
      $MAKE_FULL_ARGS -j"$JOBS" 2>&1 | tee "$O/build.selftests.bpf.log"
  fi
else
  make -C "$LINUX_ROOT/tools/testing/selftests/bpf" \
    O="$O" OUTPUT="$OUT_BPF" \
    KHDR_INCLUDES="$KHDR" \
    VMLINUX_BTF="$O/vmlinux" \
    BPFTOOL="$OUT_BPF/tools/sbin/bpftool" \
    $CLANG_ARG \
    BPF_CFLAGS="$orig" \
    $MAKE_FULL_ARGS -j"$JOBS" 2>&1 | tee "$O/build.selftests.bpf.log"
fi

if [ "$SPARSE" -eq 1 ]; then
  if [ -z "$SPARSE_SUBTREES" ]; then
    SPARSE_SUBTREES="kernel/bpf"
  fi

  echo "[sparse] subtree checks enabled"
  echo "[sparse] subtrees: $SPARSE_SUBTREES"

  for d in $SPARSE_SUBTREES; do
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
