#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-l|-g] [-c] [-m] [-r linux_root] [-o outdir]
  -l            use LLVM/clang (default)
  -g            use gcc
  -c            wipe O= (rm -rf) before config
  -m            mrproper in O= before config (forces re-config)
  -r linux_root kernel source tree root (default: pwd)
  -o outdir     explicit build output dir (O=)
USAGE
  exit 1
}

LLVM=1
CLEAN=0
MRPROPER=0
LINUX_ROOT=""
O=""

while getopts "lgr:o:cmh" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    g) LLVM=0 ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
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

mkdir -p "$O"
cd "$HOST_LINUX_ROOT"

# ---- optional clean/mrproper before writing .config ----
if [ "$CLEAN" -eq 1 ]; then
  echo "[cfg] -c: wipe O=$O" >&2
  rm -rf "$O"
  mkdir -p "$O"
fi

if [ "$MRPROPER" -eq 1 ]; then
  echo "[cfg] -m: make mrproper (O=$O)" >&2
  make -C "$HOST_LINUX_ROOT" O="$O" mrproper
fi

[ -x ./scripts/config ] || {
  echo "ERROR: scripts/config not found or not executable (are you in kernel tree?)" >&2
  exit 1
}

kver="$(uname -r)"
if [ -r "/boot/config-$kver" ]; then
  base_cfg="/boot/config-$kver"
elif [ -r /proc/config.gz ]; then
  base_cfg="/proc/config.gz"
else
  echo "ERROR: cannot find base config (/boot/config-$kver or /proc/config.gz)" >&2
  exit 1
fi

echo "[cfg] arch=$ARCH (KARCH=$KARCH)"
echo "[cfg] LINUX_ROOT=$HOST_LINUX_ROOT"
echo "[cfg] O=$O"
echo "[cfg] base config: $base_cfg"

# ---- LLVM toolchain guard (>= 20) ----
if [ "$LLVM" -eq 1 ]; then
  CLANG_VER="${CLANG_VER:-20}"
  if [ "$CLANG_VER" -lt 20 ]; then
    echo "ERROR: LLVM toolchain must be >= 20 (CLANG_VER=$CLANG_VER)" >&2
    exit 2
  fi
  if [ -n "${CC:-}" ]; then
    _cc_ver=$(echo "$CC" | sed -n 's/.*clang-*\([0-9][0-9]*\)$/\1/p')
    if [ -z "$_cc_ver" ] || [ "$_cc_ver" -lt 20 ]; then
      echo "ERROR: CC must be clang-20+ (got: $CC)" >&2
      exit 2
    fi
  fi
  if [ -n "${LD:-}" ]; then
    _lld_ver=$(echo "$LD" | sed -n 's/.*ld.lld-*\([0-9][0-9]*\)$/\1/p')
    if [ -z "$_lld_ver" ] || [ "$_lld_ver" -lt 20 ]; then
      echo "ERROR: LD must be ld.lld-20+ (got: $LD)" >&2
      exit 2
    fi
  fi
fi

TMP_CFG="$O/.config.tmp"
if [ "$base_cfg" = "/proc/config.gz" ]; then
  zcat "$base_cfg" > "$TMP_CFG"
else
  cp -f "$base_cfg" "$TMP_CFG"
fi

mv -f "$TMP_CFG" "$O/.config"

cfg() { ./scripts/config --file "$O/.config" "$@"; }

# ---- avoid Ubuntu certs/pem build pitfall ----
cfg -d MODULE_SIG
cfg --set-str SYSTEM_TRUSTED_KEYS ""
cfg --set-str SYSTEM_REVOCATION_KEYS ""

# make /proc/config.gz available in guest
cfg -e IKCONFIG
cfg -e IKCONFIG_PROC

# ---- virtme-ng boot essentials ----
cfg -e DEVTMPFS
cfg -e DEVTMPFS_MOUNT
cfg -e TMPFS
cfg -e PROC_FS
cfg -e SYSFS
cfg -e UNIX98_PTYS
cfg -e TTY

case "$KARCH" in
  x86)
    cfg -e SERIAL_8250
    cfg -e SERIAL_8250_CONSOLE
    ;;
  arm64)
    cfg -e SERIAL_AMBA_PL011        || true
    cfg -e SERIAL_AMBA_PL011_CONSOLE|| true
    cfg -e SERIAL_8250              || true
    cfg -e SERIAL_8250_CONSOLE      || true
    ;;
esac

# virtio + 9p rootfs
cfg -e VIRTIO
cfg -e VIRTIO_PCI     || true
cfg -e PCI            || true
cfg -e VIRTIO_BLK     || true
cfg -e VIRTIO_NET     || true
cfg -e VIRTIO_CONSOLE || true

cfg -e NET_9P
cfg -e NET_9P_VIRTIO
cfg -e 9P_FS
cfg -e 9P_FS_POSIX_ACL || true
cfg -e 9P_FS_SECURITY  || true

# overlays
cfg -e OVERLAY_FS

# ---- BPF selftests essentials ----
# namespaces help some tests; keep safe baseline
cfg -e NAMESPACES
cfg -e NET_NS     || true
cfg -e UTS_NS     || true
cfg -e IPC_NS     || true
cfg -e PID_NS     || true

# networking: 很多 bpf selftests 会碰到 socket / tc / xdp
cfg -e NET
cfg -e INET
cfg -e IPV6 || true

# cgroup/bpf
cfg -e CGROUPS
cfg -e CGROUP_BPF

# bpf core
cfg -e BPF
cfg -e BPF_SYSCALL
cfg -e BPF_JIT           || true
cfg -e BPF_JIT_ALWAYS_ON || true
cfg -e BPF_EVENTS        || true

cfg --enable NET_SCH_BPF || true
cfg --set-val NET_SCH_BPF y

# verifier / tracing helpers (常见依赖，失败也无所谓)
cfg -e KPROBES    || true
cfg -e KRETPROBES || true
cfg -e TRACEPOINTS|| true
cfg -e FTRACE     || true
cfg -e PERF_EVENTS|| true

# BTF (关键：否则很多 bpf selftests 价值很低)
cfg -e DEBUG_INFO        || true
cfg -e DEBUG_INFO_DWARF4 || true
cfg -e DEBUG_INFO_BTF    || true

# bpffs + debugfs（guest 中会 mount）
cfg -e BPF_FS || true
cfg -e DEBUG_FS || true

# ---- merge upstream bpf selftests config fragment (maximize coverage) ----
FRAG="$HOST_LINUX_ROOT/tools/testing/selftests/bpf/config"
if [ -r "$FRAG" ] && [ -x "$HOST_LINUX_ROOT/scripts/kconfig/merge_config.sh" ]; then
  echo "[cfg] merge fragment: $FRAG"
  KCONFIG_CONFIG="$O/.config" \
    "$HOST_LINUX_ROOT/scripts/kconfig/merge_config.sh" -m -r \
    "$O/.config" "$FRAG" >/dev/null
else
  echo "[cfg][warn] skip merge fragment (missing $FRAG or merge_config.sh)" >&2
fi

# require pahole >= v1.31 (from PATH)
need_pahole=131

pahole_num() {
  pahole --version 2>/dev/null | head -n1 \
    | sed -n 's/^v\([0-9]\+\)\.\([0-9]\+\).*$/\1\2/p'
}

p="$(command -v pahole 2>/dev/null || true)"
[ -z "$p" ] && echo "[err] pahole not found in PATH (need >= v1.31)" >&2 && exit 2

pv="$(pahole_num)"
case "$pv" in
  ''|*[!0-9]*) echo "[err] cannot parse pahole version: $(pahole --version 2>/dev/null | head -n1)" >&2; exit 2 ;;
esac

if [ "$pv" -lt "$need_pahole" ]; then
  echo "[err] pahole too old: $p ($(pahole --version | head -n1)), need >= v1.31" >&2
  echo "[hint] run with PATH=/usr/local/bin:\$PATH ..." >&2
  exit 2
fi

echo "[cfg] pahole=$p ver=$(pahole --version | head -n1)" >&2

if [ "$LLVM" -eq 1 ]; then
  cfg -d LTO_CLANG_FULL || true
  cfg -d LTO_CLANG_THIN || true
  cfg -e LTO_NONE       || true
fi

export KCONFIG_NONINTERACTIVE=1
KCONFIG_CONFIG="$O/.config" \
  make -C "$HOST_LINUX_ROOT" O="$O" olddefconfig </dev/null
echo "[cfg] OK: wrote $O/.config (olddefconfig done)"
