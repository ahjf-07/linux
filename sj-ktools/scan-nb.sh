#!/bin/sh
# Scan build logs for compiler errors/warnings and sparse diagnostics.
# POSIX /bin/sh compatible.
#
# usage:
#   ./scan-nb.sh [-e] [-w] [-s] [-n N] [-l] [-r linux_root] [-o outdir] [-I] [-k kind] [log1 ...]
#     -e : show errors
#     -w : show warnings
#     -s : show sparse diagnostics (warning/error)
#     -n : limit output lines per section (default: 200)
#     -l : use LLVM/clang default outdir (../out/full-clang) when -o not given
#     -r : kernel source tree root (default: pwd)
#     -o : output dir (default: <linux_root>/../out/full-{gcc,clang})
#     -I : include MODULE_INFO sparse flood in counts/output (default: filtered out)
#
# If no log is provided, it will scan common logs under outdir depending on kind:
#   kind=all (default): build.kernel.log build.headers.log build.selftests.net.log build.selftests.bpf.log build.clean.log build.mrproper.log
#   kind=net         : build.kernel.log build.headers.log build.selftests.net.log build.clean.log build.mrproper.log
#   kind=bpf         : build.kernel.log build.headers.log build.selftests.bpf.log build.clean.log build.mrproper.log

set -eu

usage() {
  cat <<USAGE >&2
usage: $0 [-e] [-w] [-s] [-n N] [-l] [-r linux_root] [-o outdir] [-I] [-k kind] [log1 ...]
USAGE
  exit 1
}

SHOW_E=0
SHOW_W=0
SHOW_S=0
LIMIT=200
LLVM=0
LINUX_ROOT=""
O=""
INCLUDE_FLOOD=0
KIND="all"

while getopts "ewsn:lr:o:Ik:h" opt; do
  case "$opt" in
    e) SHOW_E=1 ;;
    w) SHOW_W=1 ;;
    s) SHOW_S=1 ;;
    n) LIMIT="$OPTARG" ;;
    l) LLVM=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    I) INCLUDE_FLOOD=1 ;;
    k) KIND="$OPTARG" ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))

[ -n "$LINUX_ROOT" ] || LINUX_ROOT=$(pwd)
LINUX_ROOT=$(realpath -e "$LINUX_ROOT")

if [ -z "$O" ]; then
  if [ "$LLVM" -eq 1 ]; then
    O="$LINUX_ROOT/../out/full-clang"
  else
    O="$LINUX_ROOT/../out/full-gcc"
  fi
fi
O=$(realpath -m "$O")

DETAIL=0
if [ "$SHOW_E" -eq 1 ] || [ "$SHOW_W" -eq 1 ] || [ "$SHOW_S" -eq 1 ]; then
  DETAIL=1
fi

# patterns
P_ERR='(^|: )error:'
P_WARN='(^|: )warning:'
P_SPARSE_DIAG='\b(sparse: )?(warning|error):'

# Sparse MODULE_INFO flood patterns (line itself is diagnostic line)
P_MODINFO_NUL='static assertion failed: "MODULE_INFO.*embedded NUL byte"'
P_BAD_INT='error: bad integer constant expression'

count_re() { grep -cE "$1" "$2" 2>/dev/null || true; }

# Filter out flood lines, and also filter out "bad integer constant expression"
# when it is adjacent to a MODULE_INFO NUL assertion (typical paired output).
filter_flood() {
  # stdin -> stdout
  # 1) drop MODULE_INFO NUL assertion lines
  # 2) drop bad integer constant expression lines that are immediately
  #    before/after a MODULE_INFO NUL assertion line.
  awk -v re_nul="$P_MODINFO_NUL" -v re_bad="$P_BAD_INT" '
  { a[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      if (a[i] ~ re_nul) {
        drop[i] = 1
        if (i > 1 && a[i-1] ~ re_bad) drop[i-1] = 1
        if (i < NR && a[i+1] ~ re_bad) drop[i+1] = 1
      }
    }
    for (i = 1; i <= NR; i++) if (!drop[i]) print a[i]
  }'
}

scan_one() {
  LOG="$1"
  [ -f "$LOG" ] || { echo "skip (not found): $LOG" >&2; return 0; }

  ERR=$(count_re "$P_ERR" "$LOG")
  WARN=$(count_re "$P_WARN" "$LOG")
  SP=$(count_re "$P_SPARSE_DIAG" "$LOG")

  # flood counts (rough but useful)
  FLOOD_NUL=$(count_re "$P_MODINFO_NUL" "$LOG")
  FLOOD_BAD=$(count_re "$P_BAD_INT" "$LOG")
  # "effective flood" ~= NUL + adjacent bad-int; we report both raw counters.
  # Effective counts: subtract filtered diagnostics from totals when not including flood.
  if [ "$INCLUDE_FLOOD" -eq 1 ]; then
    ERR_EFF="$ERR"
    SP_EFF="$SP"
  else
    # compute filtered counts precisely by streaming + counting
    ERR_EFF=$(grep -nE "$P_ERR" "$LOG" | filter_flood | wc -l | tr -d ' ')
    SP_EFF=$(grep -nE "$P_SPARSE_DIAG" "$LOG" | filter_flood | wc -l | tr -d ' ')
  fi

  echo "==== build scan summary ===="
  echo "file     : $LOG"
  echo "errors   : $ERR"
  echo "warnings : $WARN"
  echo "sparse   : $SP"
  echo "modinfo_flood_nul : $FLOOD_NUL"
  echo "modinfo_flood_bad : $FLOOD_BAD"
  if [ "$INCLUDE_FLOOD" -eq 0 ]; then
    echo "errors_effective  : $ERR_EFF"
    echo "sparse_effective  : $SP_EFF"
  fi

  [ "$DETAIL" -eq 1 ] || return 0
  echo

  if [ "$SHOW_E" -eq 1 ]; then
    echo "==== errors (first $LIMIT) ===="
    if [ "$INCLUDE_FLOOD" -eq 1 ]; then
      grep -nE "$P_ERR" "$LOG" | head -n "$LIMIT" || true
    else
      grep -nE "$P_ERR" "$LOG" | filter_flood | head -n "$LIMIT" || true
    fi
    echo
  fi

  if [ "$SHOW_W" -eq 1 ]; then
    echo "==== warnings (first $LIMIT) ===="
    grep -nE "$P_WARN" "$LOG" | head -n "$LIMIT" || true
    echo
  fi

  if [ "$SHOW_S" -eq 1 ]; then
    echo "==== sparse diagnostics (first $LIMIT) ===="
    if [ "$INCLUDE_FLOOD" -eq 1 ]; then
      grep -nE "$P_SPARSE_DIAG" "$LOG" | head -n "$LIMIT" || true
    else
      grep -nE "$P_SPARSE_DIAG" "$LOG" | filter_flood | head -n "$LIMIT" || true
    fi
    echo
    echo "==== sparse diagnostics (top messages) ===="
    if [ "$INCLUDE_FLOOD" -eq 1 ]; then
      grep -nE "$P_SPARSE_DIAG" "$LOG" \
        | sed -E 's/^[0-9]+:.*: (warning|error): /\1: /' \
        | sed -E 's/[[:space:]]+/ /g' \
        | sort | uniq -c | sort -nr | head -n 50 || true
    else
      grep -nE "$P_SPARSE_DIAG" "$LOG" \
        | filter_flood \
        | sed -E 's/^[0-9]+:.*: (warning|error): /\1: /' \
        | sed -E 's/[[:space:]]+/ /g' \
        | sort | uniq -c | sort -nr | head -n 50 || true
    fi
    echo
  fi
}

if [ $# -ge 1 ]; then
  for f in "$@"; do
    scan_one "$f"
  done
  exit 0
fi

echo "[scan] auto mode: O=$O" >&2
case "$KIND" in
  net)
    logs="build.kernel.log build.headers.log build.selftests.net.log build.clean.log build.mrproper.log"
    ;;
  bpf)
    logs="build.kernel.log build.headers.log build.selftests.bpf.log build.clean.log build.mrproper.log"
    ;;
  all|"")
    logs="build.kernel.log build.headers.log build.selftests.net.log build.selftests.bpf.log build.clean.log build.mrproper.log"
    ;;
  *)
    echo "ERROR: unknown kind '$KIND' (expected: net|bpf|all)" >&2
    exit 2
    ;;
esac

for base in $logs; do
  scan_one "$O/$base"
done
