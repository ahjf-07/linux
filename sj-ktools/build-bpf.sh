#!/usr/bin/env bash
set -eu
set -o pipefail

usage() {
  cat <<USAGE
usage: $0 [-l] [-s] [-S "path1 path2 ..."] [-c|-m] [-i] [-j N] [-r linux_root] [-o outdir] [-K|-T]
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
  -K : kernel only (skip selftests/bpf)
  -T : tests only (skip kernel build)
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
ONLY_KERNEL=0
ONLY_TESTS=0

while getopts "lsS:cmij:r:o:KTh" opt; do
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
    K) ONLY_KERNEL=1 ;;
    T) ONLY_TESTS=1 ;;
    h|*) usage ;;
  esac
done

if [ "$CLEAN" -eq 1 ] && [ "$MRPROPER" -eq 1 ]; then
  echo "ERROR: -c and -m are mutually exclusive" >&2
  exit 1
fi
if [ "$ONLY_KERNEL" -eq 1 ] && [ "$ONLY_TESTS" -eq 1 ]; then
  ONLY_KERNEL=0
  ONLY_TESTS=0
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

# ---- toolchain selection (static llvm/clang-20) + non-interactive Kconfig ----
export KCONFIG_NONINTERACTIVE=1

if [ "$LLVM" -eq 1 ]; then
  # 严禁使用动态探测，直接对齐 auto.conf.cmd 的要求
  export LLVM=1
  export CC="/usr/bin/clang-20"
  export LD="/usr/bin/ld.lld-20"
  export NM="/usr/bin/llvm-nm-20"
  export AR="/usr/bin/llvm-ar-20"
  export OBJCOPY="/usr/bin/llvm-objcopy-20"

  CC_BIN="$CC"
  LLD_BIN="$LD"
  AR_BIN="$AR"
  NM_BIN="$NM"
  OBJCOPY_BIN="$OBJCOPY"

  # host tools：默认用 gcc，避免 host link/PIE/环境差异；你要 host clang 自己 export HOSTCC=clang-20
  HOSTCC_BIN="${HOSTCC:-gcc}"
  HOSTCXX_BIN="${HOSTCXX:-g++}"

  echo "[tc] LLVM=1 prefer clang-20 (static paths)"
  echo "[tc] CC=$CC_BIN LD=$LLD_BIN AR=$AR_BIN NM=$NM_BIN"
  echo "[tc] HOSTCC=$HOSTCC_BIN HOSTCXX=$HOSTCXX_BIN"

  MAKE_FULL_ARGS="$MAKE_FULL_ARGS LLVM=1 LLVM_IAS=1"
  MAKE_FULL_ARGS="$MAKE_FULL_ARGS CC=$CC_BIN LD=$LLD_BIN NM=$NM_BIN AR=$AR_BIN OBJCOPY=$OBJCOPY_BIN"
  MAKE_FULL_ARGS="$MAKE_FULL_ARGS HOSTCC=$HOSTCC_BIN HOSTCXX=$HOSTCXX_BIN"
else
  # gcc path
  MAKE_FULL_ARGS="$MAKE_FULL_ARGS CC=${CC:-gcc} HOSTCC=${HOSTCC:-gcc}"
fi

MAKE_SPARSE_ARGS="$MAKE_FULL_ARGS C=1 CHECK=sparse"

echo "[cfg] KCONFIG_NONINTERACTIVE=${KCONFIG_NONINTERACTIVE:-0}" >&2

echo "==================================="

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

if [ "$ONLY_TESTS" -eq 0 ]; then
  echo "[build] kernel ($IMG_TGT + modules)  (no sparse)"
  make -C "$LINUX_ROOT" O="$O" $MAKE_FULL_ARGS -j"$JOBS" "$IMG_TGT" modules 2>&1 | tee "$O/build.kernel.log"

  echo "[build] headers_install"
  make -C "$LINUX_ROOT" O="$O" headers_install \
    INSTALL_HDR_PATH="$O/usr" 2>&1 | tee "$O/build.headers.log"
fi

KHDR="-isystem $(realpath "$O/usr/include")"

OUT_BPF=$(realpath -m "$LINUX_ROOT/.kselftest-out/selftests-bpf")
mkdir -p "$OUT_BPF"
VMLINUX_H="$OUT_BPF/vmlinux.h"

if [ "$ONLY_KERNEL" -eq 0 ]; then
  [ -f "$O/vmlinux" ] || { echo "ERROR: Tests build requires existing $O/vmlinux" >&2; exit 1; }
  if [ -d "$OUT_BPF" ]; then
    echo "[build] forcing fresh vmlinux.h for selftests"
    rm -f "$VMLINUX_H" \
      "$OUT_BPF/tools/include/vmlinux.h" 2>/dev/null || true
    rm -rf "$OUT_BPF/tools/sbin/bpftool" 2>/dev/null || true
    echo "[build] cleaning stale bpf headers to prevent BTF pollution"
    find "$OUT_BPF" -name "vmlinux.h" -delete
    mkdir -p \
      "$OUT_BPF/tools/build/libbpf/staticobjs" \
      "$OUT_BPF/tools/build/libbpf/sharedobjs" \
      "$OUT_BPF/tools/build/bpftool/bootstrap/libbpf/staticobjs" \
      "$OUT_BPF/tools/build/bpftool/bootstrap/bpftool" \
      "$OUT_BPF/tools/include/bpf" \
      "$OUT_BPF/tools/sbin"
  fi
fi

CLANG_ARG=""
if [ "$LLVM" -eq 1 ]; then
  [ -n "${CC_BIN:-}" ] || { echo "ERROR: CC_BIN empty while LLVM=1" >&2; exit 2; }
  CLANG_ARG="CLANG=$CC_BIN"
fi

if [ "$ONLY_KERNEL" -eq 0 ]; then
  orig=$(make -C "$LINUX_ROOT/tools/testing/selftests/bpf" -pn \
    O="$O" OUTPUT="$OUT_BPF" KHDR_INCLUDES="$KHDR" \
    $CLANG_ARG \
    $MAKE_FULL_ARGS \
    | sed -n 's/^BPF_CFLAGS = //p' | head -n 1)

  echo "[build] selftests/bpf (OUTPUT=$OUT_BPF)  (no sparse)"
  make -C "$LINUX_ROOT/tools/testing/selftests/bpf" \
    O="$O" OUTPUT="$OUT_BPF" \
    KHDR_INCLUDES="$KHDR" \
    VMLINUX_BTF="$O/vmlinux" \
    VMLINUX_H="$VMLINUX_H" \
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

if [ "$ONLY_TESTS" -eq 0 ]; then
  echo "[out] kernel image: $IMG_PATH"
  [ -f "$IMG_PATH" ] || echo "[warn] image not found at expected path (check log): $IMG_PATH"
fi
echo "[done] build finished"
