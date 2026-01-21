#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-l] [-r linux_root] [-o outdir]
  -l            use LLVM/clang output default (../out/full-clang)
  -r linux_root kernel source tree root (default: pwd)
  -o outdir     explicit build output dir (O=)
USAGE
  exit 1
}

LLVM=0
LINUX_ROOT=""
O=""

while getopts "lr:o:h" opt; do
  case "$opt" in
    l) LLVM=1 ;;
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

if [ "$base_cfg" = "/proc/config.gz" ]; then
  zcat "$base_cfg" > "$O/.config"
else
  cp -f "$base_cfg" "$O/.config"
fi

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

make O="$O" olddefconfig
echo "[cfg] OK: wrote $O/.config (olddefconfig done)"

