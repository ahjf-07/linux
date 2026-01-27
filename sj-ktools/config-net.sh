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

# scripts/config must exist (from kconfig tools)
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

# ---- LLVM toolchain selection (static clang-20) ----
if [ "$LLVM" -eq 1 ]; then
  # 严禁使用动态探测，直接对齐 auto.conf.cmd 的要求
  export LLVM=1
  export CC="/usr/bin/clang-20"
  export LD="/usr/bin/ld.lld-20"
  export NM="/usr/bin/llvm-nm-20"
  export AR="/usr/bin/llvm-ar-20"
  export OBJCOPY="/usr/bin/llvm-objcopy-20"
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

# ---- net selftests essentials ----
cfg -e NAMESPACES
cfg -e NET_NS
cfg -e UTS_NS
cfg -e IPC_NS
cfg -e PID_NS
cfg -e NET
cfg -e INET
cfg -e IPV6

# link kinds required by common scripts
cfg -e DUMMY
cfg -e VETH
cfg -e VRF
cfg -e VXLAN
cfg -e GENEVE

# common netdev/tunnel helpers
cfg -e BRIDGE
cfg -e VLAN_8021Q
cfg -e MACVLAN
cfg -e IPVLAN
cfg -e TUN
cfg -e TAP

# routing features
cfg -e IP_ADVANCED_ROUTER
cfg -e IP_MULTIPLE_TABLES
cfg -e IP_ROUTE_MULTIPATH
cfg -e IPV6_MULTIPLE_TABLES

# minimal netfilter baseline (safe; scripts may probe/skip)
cfg -e NETFILTER    || true
cfg -e NF_CONNTRACK || true
cfg -e NF_TABLES    || true

# bpf baseline (safe)
cfg -e BPF
cfg -e BPF_SYSCALL
cfg -e BPF_JIT           || true
cfg -e BPF_JIT_ALWAYS_ON || true
cfg -e BPF_EVENTS        || true

# ---- virtme-ng boot essentials (rootfs via 9p/virtio) ----
cfg -e DEVTMPFS
cfg -e DEVTMPFS_MOUNT
cfg -e TMPFS
cfg -e TMPFS_POSIX_ACL || true

# virtio stack (keep PCI as "try enable"; some virt setups may differ)
cfg -e VIRTIO
cfg -e VIRTIO_PCI     || true
cfg -e PCI           || true
cfg -e VIRTIO_BLK     || true
cfg -e VIRTIO_NET     || true
cfg -e VIRTIO_CONSOLE || true

# 9p rootfs support
cfg -e NET_9P
cfg -e NET_9P_VIRTIO
cfg -e 9P_FS
cfg -e 9P_FS_POSIX_ACL || true
cfg -e 9P_FS_SECURITY  || true

# console: x86 usually 8250; arm64 usually PL011 (QEMU virt)
cfg -e TTY
cfg -e UNIX98_PTYS

case "$KARCH" in
  x86)
    cfg -e SERIAL_8250
    cfg -e SERIAL_8250_CONSOLE
    ;;
  arm64)
    cfg -e SERIAL_AMBA_PL011        || true
    cfg -e SERIAL_AMBA_PL011_CONSOLE|| true
    # keep 8250 as optional fallback (some firmwares expose it)
    cfg -e SERIAL_8250              || true
    cfg -e SERIAL_8250_CONSOLE      || true
    ;;
esac

# basic proc/sysfs (usually already on)
cfg -e PROC_FS
cfg -e SYSFS

# misc used by various net scripts
cfg -e MPLS
cfg -e MPLS_ROUTING
cfg -e MPLS_IPTUNNEL || true

cfg -e NET_SCHED
cfg -e NET_SCH_HTB
cfg -e NET_SCH_INGRESS || true
cfg -e NET_CLS_U32      || true
cfg -e NET_CLS_BASIC    || true
cfg -e NET_CLS_ACT      || true
cfg -e NET_ACT_MIRRED   || true

cfg -e BRIDGE
cfg -e BRIDGE_VLAN_FILTERING || true
cfg -e BRIDGE_NETFILTER      || true
cfg -e VXLAN
cfg -e GENEVE

# GRE / ERSPAN
cfg -e NET_IPGRE
cfg -e NET_IPGRE_DEMUX || true
cfg -e IP6_GRE         || true

# IPsec / XFRM
cfg -e XFRM
cfg -e XFRM_USER
cfg -e XFRM_INTERFACE || true
cfg -e NET_KEY        || true

# MACsec / bonding (optional)
cfg -e MACSEC  || true
cfg -e BONDING || true

# virtme-ng overlays need overlayfs
cfg -e OVERLAY_FS

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
  cfg --disable LTO_CLANG_FULL || true
  cfg --disable LTO_CLANG_THIN || true
  cfg --enable  LTO_NONE       || true
fi

make O="$O" olddefconfig
echo "[cfg] OK: wrote $O/.config (olddefconfig done)"
