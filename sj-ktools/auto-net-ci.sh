#!/usr/bin/env bash
set -eu
set -o pipefail

usage() {
  cat >&2 <<'USAGE'
usage: auto-net-ci.sh [-l] [-s] [-S "subtrees"] [-o outdir] [-t remote/branch] [-e to_email]
                      [-c] [-m] [-F] [-U] [-K] [-T] [-P cpus] [-M mem]
                      [--reset-baseline] [--force] [--update] [--no-test] [--no-build]
                      [--cpu N] [--mem SIZE]

Defaults:
  track  : upstream/master
  switch : master (fast-forward only)
  update : off (build current HEAD)
  state  : $O/.auto-net/

Options:
  -l  LLVM=1 (clang). default gcc
  -s  enable sparse (passed to build-net.sh)
  -S  sparse subtrees list (passed to build-net.sh)
  -o  outdir (default: ../out/full-{clang|gcc})
  -t  tracked ref (default: upstream/master)
  -e  recipient (or env AUTO_EMAIL)

  -c  clean rebuild: remove $O (out dir) before build
  -m  mrproper-ish: remove $O and also remove $O/.config (forces re-config)
  -F  force-run: run even if no update after fetch; uses incremental build when possible
  -U  update: fetch + switch master + pull --ff-only TARGET_REF
  -K  build kernel only (pass -K to build-net.sh)
  -T  build tests only (pass -T to build-net.sh)
  -P  vng guest cpus (passed to run-net.sh)
  -M  vng guest memory (passed to run-net.sh, e.g. 2G)

Long:
  --full           force full net selftests (override default fast)
  --force          same as -F
  --update         same as -U
  --no-test        skip vng tests
  --no-build       skip build
  --reset-baseline overwrite pinned baseline with this run
  --cpu N          same as -P
  --mem  SIZE      same as -M

Behavior:
  - If no update AND not forced: send "no updates" mail and exit (no build/test).
  - -c/-m imply forced run (rebuild even when ref unchanged).
  - If update OR forced:
      * default: build/test current HEAD (dirty OK)
      * with -U: require clean tree, switch to master, pull --ff-only TARGET_REF, then build/test
USAGE
  exit 1
}

require_git_toplevel_cwd() {
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || { echo "ERROR: not a git repo" >&2; exit 2; }
  top="$(cd "$top" && pwd)"
  cwd="$(pwd)"
  [ "$top" = "$cwd" ] || { echo "ERROR: must run from git top-level: $top" >&2; exit 2; }
}

require_git_toplevel_cwd
TOOL_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

need_exec() {
  f="$TOOL_DIR/$1"
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 2; }
  [ -x "$f" ] || { echo "ERROR: $f not executable; chmod +x \"$f\"" >&2; exit 2; }
}

need_exec config-net.sh
need_exec build-net.sh
need_exec scan-nb.sh
need_exec run-net.sh
need_exec summ-net.sh

# defaults
LLVM=0
SPARSE=0
SPARSE_SUBTREES=""
O=""
TARGET_REF="upstream/master"
SWITCH_BRANCH="master"
TO_EMAIL="${AUTO_EMAIL:-}"

RESET_BASELINE=0
FORCE=0
NO_TEST=0
NO_BUILD=0

CLEAN=0
MRPROPER=0
UPDATE=0
TEST_FAST=1
TEST_FFAST=0
DRY_RUN=0
KERNEL_ONLY=0
TESTS_ONLY=0
CPUS=2
MEM=2G

# --- strip long options anywhere so getopts won't choke on "--xxx" ---
_keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reset-baseline) RESET_BASELINE=1 ;;
    --force) FORCE=1 ;;
    --update) UPDATE=1 ;;
    --no-test) NO_TEST=1 ;;
    --no-build) NO_BUILD=1 ;;
    --ff) TEST_FFAST=1 ;;
    --full) TEST_FAST=0; TEST_FFAST=0 ;;
    --cpu) CPUS="$2"; shift ;;
    --mem) MEM="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --) shift; break ;;
    --*) echo "unknown arg: $1" >&2; usage ;;
    *) _keep="$_keep $1" ;;
  esac
  shift
done
set -- $_keep "$@"

while getopts "lsS:o:t:e:cmFUfhKTP:M:" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    s) SPARSE=1 ;;
    S) SPARSE_SUBTREES="$OPTARG" ;;
    o) O="$OPTARG" ;;
    t) TARGET_REF="$OPTARG" ;;
    e) TO_EMAIL="$OPTARG" ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    F) FORCE=1 ;;
    U) UPDATE=1 ;;
    f) TEST_FAST=1 ;;
    K) KERNEL_ONLY=1 ;;
    T) TESTS_ONLY=1 ;;
    P) CPUS="$OPTARG" ;;
    M) MEM="$OPTARG" ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))

[ "$KERNEL_ONLY" -eq 1 ] && [ "$TESTS_ONLY" -eq 1 ] && KERNEL_ONLY=0 && TESTS_ONLY=0

[ "$NO_BUILD" -eq 1 ] && [ "$NO_TEST" -eq 1 ] && {
  echo "ERROR: --no-build and --no-test cannot both be set" >&2
  exit 2
}

[ "$CLEAN" -eq 1 ] || [ "$MRPROPER" -eq 1 ] && FORCE=1

[ -n "$TO_EMAIL" ] || { echo "ERROR: missing recipient; use -e or set AUTO_EMAIL" >&2; exit 2; }

LINUX_ROOT="$(pwd)"

if [ -z "$O" ]; then
  if [ "$LLVM" -eq 1 ]; then
    O="$LINUX_ROOT/../out/full-clang"
  else
    O="$LINUX_ROOT/../out/full-gcc"
  fi
fi
O="$(realpath -m "$O")"
mkdir -p "$O"

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

STATE_DIR="${AUTO_NET_STATE_DIR:-$LINUX_ROOT/../out/auto-net-state}"
mkdir -p "$STATE_DIR"

ARCH="$(uname -m)"
KEY="${ARCH}.$([ "$LLVM" -eq 1 ] && echo clang || echo gcc)"

PREV_DIR="$STATE_DIR/prev/$KEY"
BASE_DIR="$STATE_DIR/baseline/$KEY"
RUNS_DIR="$STATE_DIR/runs/$KEY"
mkdir -p "$STATE_DIR/prev/$KEY" "$STATE_DIR/baseline/$KEY" "$STATE_DIR/runs/$KEY"

now="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$RUNS_DIR/$now"
mkdir -p "$RUN_DIR"

BUILD_LOGS="build.olddefconfig.log build.kernel.log build.headers.log build.selftests.net.log build.clean.log build.mrproper.log"
PREV_BUILD_DIR="$PREV_DIR/build-logs"
PREV_BUILD_ALL="$PREV_DIR/build.all.log"
RUN_BUILD_DIR="$RUN_DIR/build-logs"
mkdir -p "$RUN_BUILD_DIR"

run() { echo "+ $*" >&2; bash -lc "set -o pipefail; $*"; }

FETCH_REMOTE="upstream"
TARGET_BRANCH="$SWITCH_BRANCH"

# --dry-run: only compute run-net args and exit (no fetch/build/scan/test)
if [ "${DRY_RUN:-0}" -eq 1 ]; then
  targs=""
  [ "$LLVM" -eq 1 ] && targs="$targs -l"
  targs="$targs -r \"$LINUX_ROOT\" -o \"$O\""
  if [ "${TEST_FFAST:-0}" -eq 1 ]; then
    targs="$targs -ff"
  elif [ "${TEST_FAST:-0}" -eq 1 ]; then
    targs="$targs -f"
  fi
  targs="$targs -p \"$CPUS\" -m \"$MEM\""
  echo "[dry-run] run-net args: $targs" >&2
  exit 0
fi

if [ "$UPDATE" -eq 1 ]; then
  if echo "$TARGET_REF" | grep -q '/'; then
    FETCH_REMOTE="${TARGET_REF%%/*}"
    TARGET_BRANCH="${TARGET_REF#*/}"
  fi
  if git remote get-url "$FETCH_REMOTE" >/dev/null 2>&1; then
    run "git fetch --prune \"$FETCH_REMOTE\""
  else
    echo "WARN: remote '$FETCH_REMOTE' not found; falling back to 'git fetch --prune'." >&2
    run "git fetch --prune"
  fi
else
  echo "[auto] update skipped; building current HEAD" >&2
fi

old_ref="$(cat "$STATE_DIR/last_ref.$KEY" 2>/dev/null || true)"
head_before="$(git rev-parse HEAD)"
if [ "$UPDATE" -eq 1 ]; then
  new_ref="$(git rev-parse "$TARGET_REF" 2>/dev/null || true)"
  [ -n "$new_ref" ] || { echo "ERROR: cannot resolve TARGET_REF=$TARGET_REF" >&2; exit 2; }
else
  new_ref="$head_before"
fi
REF_LABEL="$TARGET_REF"
if [ "$UPDATE" -eq 0 ]; then
  REF_LABEL="HEAD"
fi

ref_updated=0
if [ -z "$old_ref" ]; then
  ref_updated=1
elif [ "$new_ref" != "$old_ref" ]; then
  ref_updated=1
fi
force_incremental=0
if [ "$FORCE" -eq 1 ] && [ "$CLEAN" -eq 0 ] && [ "$MRPROPER" -eq 0 ]; then
  if [ "$ref_updated" -eq 0 ] || [ "$UPDATE" -eq 0 ]; then
    force_incremental=1
  fi
fi

{
  echo "TIME_UTC=$now"
  echo "LINUX_ROOT=$LINUX_ROOT"
  echo "O=$O"
  echo "ARCH=$ARCH"
  echo "KEY=$KEY"
  echo "TARGET_REF=$TARGET_REF"
  echo "SWITCH_BRANCH=$SWITCH_BRANCH"
  echo "OLD_REF=${old_ref:-<none>}"
  echo "NEW_REF=$new_ref"
  echo "HEAD_BEFORE=$head_before"
  echo "FORCE=$FORCE"
  echo "FORCE_INCREMENTAL=$force_incremental"
  echo "UPDATE=$UPDATE"
  echo "CLEAN=$CLEAN"
  echo "MRPROPER=$MRPROPER"
  echo "NO_BUILD=$NO_BUILD"
  echo "NO_TEST=$NO_TEST"
  echo "KERNEL_ONLY=$KERNEL_ONLY"
  echo "TESTS_ONLY=$TESTS_ONLY"
  echo "CPUS=$CPUS"
  echo "MEM=$MEM"
  echo
  git log -1 --oneline "$new_ref" || true
} >"$RUN_DIR/meta.txt"

# no update AND not forced -> mail and exit
if [ "$ref_updated" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  SUBJ="[auto-net][$KEY] no updates: $REF_LABEL still $new_ref"
  MAIL="$RUN_DIR/mail.no-updates.mbox"
  {
    echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
    echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
    echo "To: $TO_EMAIL"
    echo "Subject: $SUBJ"
    echo
    echo "No updates."
    echo
    cat "$RUN_DIR/meta.txt" || true
    echo
    echo "Artifacts:"
    echo "  run dir  : $RUN_DIR"
    echo "  state dir: $STATE_DIR"
  } >"$MAIL"
  run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""
  echo "[auto] no update; mailed." >&2
  exit 0
fi

# record last seen ref for next run (even if forced, we want stable ref tracking)
echo "$new_ref" >"$STATE_DIR/last_ref.$KEY"

# cleaning (only affects out dir)
if [ "$MRPROPER" -eq 1 ]; then
  CLEAN=1
fi
if [ "$CLEAN" -eq 1 ]; then
  echo "[auto] CLEAN=1: wiping O=$O" >&2
  rm -rf "$O"
  mkdir -p "$O"
  mkdir -p "$STATE_DIR/prev/$KEY" "$STATE_DIR/baseline/$KEY" "$STATE_DIR/runs/$KEY"
fi
if [ "$MRPROPER" -eq 1 ]; then
  echo "[auto] MRPROPER=1: remove $O/.config (force re-config)" >&2
  rm -f "$O/.config"
fi

# switch/merge only when update is requested
if [ "$UPDATE" -eq 1 ]; then
  # refuse if dirty
  git diff --quiet && git diff --cached --quiet || {
    SUBJ="[auto-net][$KEY] update/force but REFUSE switch: dirty tree"
    MAIL="$RUN_DIR/mail.dirty-tree.mbox"
    {
      echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
      echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
      echo "To: $TO_EMAIL"
      echo "Subject: $SUBJ"
      echo
      echo "Work tree dirty; refusing to switch/fast-forward."
      echo "Retry without -U/--update, or stash/commit changes."
      echo
      cat "$RUN_DIR/meta.txt" || true
    } >"$MAIL"
    run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""
    exit 2
  }

  if git show-ref --verify --quiet "refs/heads/$SWITCH_BRANCH"; then
    run "git switch \"$SWITCH_BRANCH\""
  else
    run "git switch -c \"$SWITCH_BRANCH\""
  fi

  if ! git pull --ff-only "$FETCH_REMOTE" "$TARGET_BRANCH" >/dev/null 2>&1; then
    SUBJ="[auto-net][$KEY] update/force but FF-only failed: $SWITCH_BRANCH <- $TARGET_REF"
    MAIL="$RUN_DIR/mail.ff-failed.mbox"
    {
      echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
      echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
      echo "To: $TO_EMAIL"
      echo "Subject: $SUBJ"
      echo
      echo "Fast-forward failed. Local '$SWITCH_BRANCH' likely diverged."
      echo
      cat "$RUN_DIR/meta.txt" || true
    } >"$MAIL"
    run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""
    exit 2
  fi
else
  echo "NOTE: update disabled; building current HEAD" >>"$RUN_DIR/meta.txt"
fi

head_after="$(git rev-parse HEAD)"
echo "HEAD_AFTER=$head_after" >>"$RUN_DIR/meta.txt"

# build + scan
if [ "$NO_BUILD" -eq 0 ]; then
  if [ ! -f "$O/.config" ]; then
    cargs=""
    [ "$LLVM" -eq 1 ] && cargs="$cargs -l"
    run "\"$TOOL_DIR/config-net.sh\" $cargs -r \"$LINUX_ROOT\" -o \"$O\" |& tee \"$RUN_DIR/config.log\""
  fi

  bargs=""
  [ "$LLVM" -eq 1 ] && bargs="$bargs -l"
  [ "$SPARSE" -eq 1 ] && bargs="$bargs -s"
  [ -n "$SPARSE_SUBTREES" ] && bargs="$bargs -S \"$SPARSE_SUBTREES\""
  if [ "$force_incremental" -eq 1 ]; then
    bargs="$bargs -i"
  fi
  if [ "$KERNEL_ONLY" -eq 1 ] && [ "$TESTS_ONLY" -eq 0 ]; then
    bargs="$bargs -K"
  elif [ "$TESTS_ONLY" -eq 1 ] && [ "$KERNEL_ONLY" -eq 0 ]; then
    bargs="$bargs -T"
  fi
  bargs="$bargs -r \"$LINUX_ROOT\" -o \"$O\""
  run "\"$TOOL_DIR/build-net.sh\" $bargs |& tee \"$RUN_DIR/build.all.log\""
else
  echo "[auto] --no-build: skip build" >"$RUN_DIR/build.all.log"
fi

incremental_skipped=0
if [ "$NO_BUILD" -eq 0 ] && [ "$force_incremental" -eq 1 ]; then
  need_kernel=1
  need_tests=1
  [ "$TESTS_ONLY" -eq 1 ] && need_kernel=0
  [ "$KERNEL_ONLY" -eq 1 ] && need_tests=0
  if [ -f "$O/build.olddefconfig.log" ] && grep -q "up to date: skip olddefconfig" "$O/build.olddefconfig.log"; then
    if [ "$need_kernel" -eq 1 ]; then
      if [ -f "$O/build.kernel.log" ] && grep -q "up to date: skip kernel build" "$O/build.kernel.log" \
        && [ -f "$O/build.headers.log" ] && grep -q "up to date: skip headers_install" "$O/build.headers.log"; then
        kernel_ok=1
      else
        kernel_ok=0
      fi
    else
      kernel_ok=1
    fi
    if [ "$need_tests" -eq 1 ]; then
      if [ -f "$O/build.selftests.net.log" ] && grep -q "up to date: skip selftests/net" "$O/build.selftests.net.log"; then
        tests_ok=1
      else
        tests_ok=0
      fi
    else
      tests_ok=1
    fi
    if [ "$kernel_ok" -eq 1 ] && [ "$tests_ok" -eq 1 ]; then
      incremental_skipped=1
    fi
  fi
fi

if [ "$NO_BUILD" -eq 0 ]; then
  if [ "$incremental_skipped" -eq 1 ] && [ -d "$PREV_BUILD_DIR" ]; then
    echo "[auto] incremental build skipped; reusing previous build logs" >&2
    if [ -f "$PREV_DIR/scan.txt" ]; then
      cp -f "$PREV_DIR/scan.txt" "$RUN_DIR/scan.txt"
    fi
    for log in $BUILD_LOGS; do
      if [ -f "$PREV_BUILD_DIR/$log" ]; then
        cp -f "$PREV_BUILD_DIR/$log" "$O/$log"
        cp -f "$PREV_BUILD_DIR/$log" "$RUN_BUILD_DIR/$log"
      fi
    done
    if [ -f "$PREV_BUILD_ALL" ]; then
      {
        echo "[auto] incremental build skipped; reused $PREV_BUILD_ALL"
        echo
        cat "$PREV_BUILD_ALL"
      } >"$RUN_DIR/build.all.log"
    fi
  else
    if [ "$force_incremental" -eq 1 ] && [ -d "$PREV_BUILD_DIR" ]; then
      if [ -f "$O/build.olddefconfig.log" ] && grep -q "up to date: skip olddefconfig" "$O/build.olddefconfig.log"; then
        [ -f "$PREV_BUILD_DIR/build.olddefconfig.log" ] && cp -f "$PREV_BUILD_DIR/build.olddefconfig.log" "$O/build.olddefconfig.log"
      fi
      if [ -f "$O/build.kernel.log" ] && grep -q "up to date: skip kernel build" "$O/build.kernel.log"; then
        [ -f "$PREV_BUILD_DIR/build.kernel.log" ] && cp -f "$PREV_BUILD_DIR/build.kernel.log" "$O/build.kernel.log"
      fi
      if [ -f "$O/build.headers.log" ] && grep -q "up to date: skip headers_install" "$O/build.headers.log"; then
        [ -f "$PREV_BUILD_DIR/build.headers.log" ] && cp -f "$PREV_BUILD_DIR/build.headers.log" "$O/build.headers.log"
      fi
      if [ -f "$O/build.selftests.net.log" ] && grep -q "up to date: skip selftests/net" "$O/build.selftests.net.log"; then
        [ -f "$PREV_BUILD_DIR/build.selftests.net.log" ] && cp -f "$PREV_BUILD_DIR/build.selftests.net.log" "$O/build.selftests.net.log"
      fi
    fi
    mkdir -p "$PREV_BUILD_DIR"
    for log in $BUILD_LOGS; do
      [ -f "$O/$log" ] && cp -f "$O/$log" "$RUN_BUILD_DIR/$log"
      [ -f "$O/$log" ] && cp -f "$O/$log" "$PREV_BUILD_DIR/$log"
    done
    [ -f "$RUN_DIR/build.all.log" ] && cp -f "$RUN_DIR/build.all.log" "$PREV_BUILD_ALL"
  fi
fi

if [ "$NO_BUILD" -eq 0 ]; then
  if [ "$incremental_skipped" -eq 1 ] && [ -f "$RUN_DIR/scan.txt" ]; then
    echo "[auto] incremental build skipped; reuse scan.txt" >&2
  else
    run "\"$TOOL_DIR/scan-nb.sh\" -e -w -s -n 50 -k net -r \"$LINUX_ROOT\" -o \"$O\" \"$RUN_DIR/build.all.log\" >\"$RUN_DIR/scan.txt\" 2>&1 || true"
  fi
fi

# [fix] collect sparse logs into run_dir and make sparse diagnostics visible in scan/mail
SPARSE_SCAN_TXT="$RUN_DIR/scan.sparse.scan.txt"
SPARSE_NORM_LOG="$RUN_DIR/build-logs/build.sparse.norm.log"
if [ "$NO_BUILD" -eq 0 ] && [ "$incremental_skipped" -eq 0 ] && [ -f "$RUN_DIR/build.all.log" ]; then
  mkdir -p "$RUN_DIR/build-logs"
  : >"$SPARSE_NORM_LOG"

  # build.all.log contains lines like:
  #   49666:[sparse] M=net/core -> /path/to/build.sparse.net_core.log
  grep -aE '\[sparse\].*-> ' "$RUN_DIR/build.all.log" | sed -n 's/.*-> //p' | while read -r f; do
    [ -f "$f" ] || continue
    cp -af "$f" "$RUN_DIR/build-logs/" 2>/dev/null || true
    # normalize so scan-nb.sh matches P_SPARSE_DIAG ("sparse: warning|error:")
    sed -E 's/: (warning|error): /: sparse: \1: /' "$f" >>"$SPARSE_NORM_LOG" 2>/dev/null || true
  done

  if [ -s "$SPARSE_NORM_LOG" ]; then
    run "\"$TOOL_DIR/scan-nb.sh\" -s -n 120 -k net -r \"$LINUX_ROOT\" -o \"$O\" \"$SPARSE_NORM_LOG\" >\"$SPARSE_SCAN_TXT\" 2>&1 || true"
    # append sparse-only scan output so summarize_scan/mail can pick it up
    [ -f "$SPARSE_SCAN_TXT" ] && cat "$SPARSE_SCAN_TXT" >>"$RUN_DIR/scan.txt" || true
  fi
fi

# [fix] extract lists from scan.txt for stable diffs (warnings/errors/sparse)
WARN_LIST="$RUN_DIR/scan.warnings.txt"
ERR_LIST="$RUN_DIR/scan.errors.txt"
SPARSE_LIST="$RUN_DIR/scan.sparse.txt"

if [ -f "$RUN_DIR/scan.txt" ]; then
  # warnings list
  awk '
    function normalize(line) {
      sub(/^[0-9]+:/, "", line);
      gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
      return line;
    }
    /^==== warnings \(first / { flag=1; next }
    /^====/ { if (flag) flag=0 }
    flag && /warning:/ { print normalize($0) }
  ' "$RUN_DIR/scan.txt" >"$WARN_LIST" 2>/dev/null || true

  # errors list
  awk '
    function normalize(line) {
      sub(/^[0-9]+:/, "", line);
      gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
      return line;
    }
    /^==== errors \(first / { flag=1; next }
    /^====/ { if (flag) flag=0 }
    flag && /error:/ { print normalize($0) }
  ' "$RUN_DIR/scan.txt" >"$ERR_LIST" 2>/dev/null || true

  # sparse list (first N section)
  awk '
    function normalize(line) {
      sub(/^[0-9]+:/, "", line);
      gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
      return line;
    }
    /^==== sparse diagnostics \(first / { flag=1; next }
    /^====/ { if (flag) flag=0 }
    flag && /(warning|error):/ { print normalize($0) }
  ' "$RUN_DIR/scan.txt" >"$SPARSE_LIST" 2>/dev/null || true

  # normalize all lists for stable diffs
  for f in "$WARN_LIST" "$ERR_LIST" "$SPARSE_LIST"; do
    [ -f "$f" ] || continue
    sed -i 's/^[[:space:]]\+//' "$f" 2>/dev/null || true
    LC_ALL=C sort -u "$f" -o "$f" 2>/dev/null || true
  done
fi

# diffs vs prev/baseline (best-effort; files may not exist yet)
BASE_DIR="$STATE_DIR/baseline/$KEY"
PREV_DIR="$STATE_DIR/prev/$KEY"

DIFF_WARN_PREV="$RUN_DIR/diff.warnings.vs-prev.txt"
DIFF_WARN_BASE="$RUN_DIR/diff.warnings.vs-baseline.txt"
DIFF_ERR_PREV="$RUN_DIR/diff.errors.vs-prev.txt"
DIFF_ERR_BASE="$RUN_DIR/diff.errors.vs-baseline.txt"
DIFF_SPARSE_PREV="$RUN_DIR/diff.sparse.vs-prev.txt"
DIFF_SPARSE_BASE="$RUN_DIR/diff.sparse.vs-baseline.txt"

[ -f "$PREV_DIR/scan.warnings.txt" ] && diff -u "$PREV_DIR/scan.warnings.txt" "$WARN_LIST" >"$DIFF_WARN_PREV" || true
[ -f "$BASE_DIR/scan.warnings.txt" ] && diff -u "$BASE_DIR/scan.warnings.txt" "$WARN_LIST" >"$DIFF_WARN_BASE" || true
[ -f "$PREV_DIR/scan.errors.txt" ] && diff -u "$PREV_DIR/scan.errors.txt" "$ERR_LIST" >"$DIFF_ERR_PREV" || true
[ -f "$BASE_DIR/scan.errors.txt" ] && diff -u "$BASE_DIR/scan.errors.txt" "$ERR_LIST" >"$DIFF_ERR_BASE" || true
[ -f "$PREV_DIR/scan.sparse.txt" ] && diff -u "$PREV_DIR/scan.sparse.txt" "$SPARSE_LIST" >"$DIFF_SPARSE_PREV" || true
[ -f "$BASE_DIR/scan.sparse.txt" ] && diff -u "$BASE_DIR/scan.sparse.txt" "$SPARSE_LIST" >"$DIFF_SPARSE_BASE" || true

# tests (方案A): read source-root .kselftest-out then copy to RUN_DIR
TEST_LOG_SRC="$LINUX_ROOT/.kselftest-out/net.selftests.log"
TEST_LOG_DST="$RUN_DIR/net.selftests.log"
SUMM_LOG="$RUN_DIR/net.summ.txt"

if [ "$NO_TEST" -eq 0 ]; then
  targs=""
  [ "$LLVM" -eq 1 ] && targs="$targs -l"
  targs="$targs -r \"$LINUX_ROOT\" -o \"$O\""
  # default: full net selftests; speed up only if requested
  if [ "${TEST_FFAST:-0}" -eq 1 ]; then
    targs="$targs -ff"
  elif [ "${TEST_FAST:-0}" -eq 1 ]; then
    targs="$targs -f"
  fi
  targs="$targs -p \"$CPUS\" -m \"$MEM\""
  run "\"$TOOL_DIR/run-net.sh\" $targs |& tee \"$RUN_DIR/run-net.host.log\""

  if [ -f "$TEST_LOG_SRC" ]; then
    cp -f "$TEST_LOG_SRC" "$TEST_LOG_DST"
    run "\"$TOOL_DIR/summ-net.sh\" \"$TEST_LOG_DST\" >\"$SUMM_LOG\""
  else
    echo "ERROR: missing $TEST_LOG_SRC" >"$SUMM_LOG"
  fi
else
  echo "[auto] --no-test: skip tests" >"$SUMM_LOG"
fi

BUILD_RAN=0
SCAN_RAN=0
TESTS_RAN=0

if [ "$NO_BUILD" -eq 0 ] && [ "$incremental_skipped" -eq 0 ]; then
  BUILD_RAN=1
fi

if [ "$BUILD_RAN" -eq 1 ] && [ -f "$RUN_DIR/scan.txt" ]; then
  SCAN_RAN=1
fi

if [ "$NO_TEST" -eq 0 ] && [ -f "$TEST_LOG_DST" ]; then
  TESTS_RAN=1
fi

summarize_scan() {
  scan="$1"
  out="$2"

  {
    echo "== build + sparse summary (filtered) =="
    echo
    # Keep only:
    # - per-log summary block (==== build scan summary ==== ... sparse_effective ...)
    # - non-empty errors/warnings/sparse lists
    # Drop: "top messages" and any empty section headers.
    awk '
      function reset_counts() {
        err=0; warn=0; sp=0;
      }
      function flush_summary() {
        if (sum != "") {
          if ((err + warn + sp) > 0) {
            printf "%s\n", sum;
          }
          sum="";
        }
        reset_counts();
      }
      function flush_list(title, list) {
        if (list != "") {
          printf "==== %s ====\n%s\n", title, list;
        }
      }
      BEGIN{
        sum=""; in_sum=0;
        sec=""; list="";
        reset_counts();
      }

      /^==== build scan summary ====$/ {
        flush_list(sec, list);
        sec=""; list="";
        flush_summary();
        in_sum=1;
        sum = $0 "\n";
        next
      }

      in_sum==1 {
        sum = sum $0 "\n";
        if ($0 ~ /^errors_effective[[:space:]]*:/) { err=$NF + 0; }
        else if ($0 ~ /^errors[[:space:]]*:/) { err=$NF + 0; }
        else if ($0 ~ /^warnings[[:space:]]*:/) { warn=$NF + 0; }
        else if ($0 ~ /^sparse_effective[[:space:]]*:/) { sp=$NF + 0; }
        else if ($0 ~ /^sparse[[:space:]]*:/) { sp=$NF + 0; }
        # end of summary block: blank line
        if ($0 ~ /^$/) { in_sum=0; flush_summary(); }
        next
      }

      /^==== errors \(first /           { flush_list(sec, list); sec="errors"; list=""; next }
      /^==== warnings \(first /         { flush_list(sec, list); sec="warnings"; list=""; next }
      /^==== sparse diagnostics \(first /{ flush_list(sec, list); sec="sparse diagnostics"; list=""; next }

      # explicitly ignore "top messages" section and anything after its header until next summary
      /^==== sparse diagnostics \(top messages\) ====$/ { flush_list(sec, list); sec=""; list=""; next }

      # collect only actual diagnostic lines (scan-nb prefixes with N:)
      (sec!="") && ($0 ~ /^[0-9]+:/) { list = list $0 "\n"; next }

      END{
        flush_list(sec, list);
        flush_summary();
      }
    ' "$scan" 2>/dev/null || true
  } >"$out"
}

RUN_BUILD_SUMM="$RUN_DIR/build.summ.txt"
RUN_TEST_SUMM="$RUN_DIR/test.summ.txt"
PREV_BUILD_SUMM="$PREV_DIR/build.summ.txt"
BASE_BUILD_SUMM="$BASE_DIR/build.summ.txt"
PREV_TEST_SUMM="$PREV_DIR/test.summ.txt"
BASE_TEST_SUMM="$BASE_DIR/test.summ.txt"
DIFF_PREV_BUILD="$RUN_DIR/diff.build.vs-prev.txt"
DIFF_BASE_BUILD="$RUN_DIR/diff.build.vs-baseline.txt"
DIFF_PREV_TEST="$RUN_DIR/diff.test.vs-prev.txt"
DIFF_BASE_TEST="$RUN_DIR/diff.test.vs-baseline.txt"

if [ "$BUILD_RAN" -eq 1 ] && [ "$SCAN_RAN" -eq 1 ]; then
  summarize_scan "$RUN_DIR/scan.txt" "$RUN_BUILD_SUMM"
  if [ -f "$PREV_BUILD_SUMM" ]; then
    diff -u "$PREV_BUILD_SUMM" "$RUN_BUILD_SUMM" >"$DIFF_PREV_BUILD" || true
    [ -s "$DIFF_PREV_BUILD" ] || echo "(no build summary diff vs prev)" >"$DIFF_PREV_BUILD"
  else
    echo "(no previous build summary)" >"$DIFF_PREV_BUILD"
  fi

  if [ -f "$BASE_BUILD_SUMM" ]; then
    diff -u "$BASE_BUILD_SUMM" "$RUN_BUILD_SUMM" >"$DIFF_BASE_BUILD" || true
    [ -s "$DIFF_BASE_BUILD" ] || echo "(no build summary diff vs baseline)" >"$DIFF_BASE_BUILD"
  else
    echo "(no baseline build summary yet)" >"$DIFF_BASE_BUILD"
  fi

  cp -f "$RUN_BUILD_SUMM" "$PREV_BUILD_SUMM"
  cp -f "$RUN_DIR/scan.txt" "$PREV_DIR/scan.txt" 2>/dev/null || true
  if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_BUILD_SUMM" ]; then
    cp -f "$RUN_BUILD_SUMM" "$BASE_BUILD_SUMM"
# 复制相关的 list 文件到 baseline 目录
    cp -f "$WARN_LIST" "$BASE_DIR/scan.warnings.txt" 2>/dev/null || true
    cp -f "$ERR_LIST" "$BASE_DIR/scan.errors.txt" 2>/dev/null || true
    cp -f "$SPARSE_LIST" "$BASE_DIR/scan.sparse.txt" 2>/dev/null || true
  fi
else
  echo "build skipped (no compile this run)" >"$RUN_BUILD_SUMM"
fi

if [ "$TESTS_RAN" -eq 1 ]; then
  cp -f "$SUMM_LOG" "$RUN_TEST_SUMM"
  if [ -f "$PREV_TEST_SUMM" ]; then
    diff -u "$PREV_TEST_SUMM" "$RUN_TEST_SUMM" >"$DIFF_PREV_TEST" || true
    [ -s "$DIFF_PREV_TEST" ] || echo "(no test summary diff vs prev)" >"$DIFF_PREV_TEST"
  else
    echo "(no previous test summary)" >"$DIFF_PREV_TEST"
  fi

  if [ -f "$BASE_TEST_SUMM" ]; then
    diff -u "$BASE_TEST_SUMM" "$RUN_TEST_SUMM" >"$DIFF_BASE_TEST" || true
    [ -s "$DIFF_BASE_TEST" ] || echo "(no test summary diff vs baseline)" >"$DIFF_BASE_TEST"
  else
    echo "(no baseline test summary yet)" >"$DIFF_BASE_TEST"
  fi

  cp -f "$RUN_TEST_SUMM" "$PREV_TEST_SUMM"
  if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_TEST_SUMM" ]; then
    cp -f "$RUN_TEST_SUMM" "$BASE_TEST_SUMM"
  fi
else
  echo "tests skipped (no tests this run)" >"$RUN_TEST_SUMM"
fi

SUBJ="[auto-net][$KEY] run done: ref_updated=$ref_updated force=$FORCE HEAD=$head_after"
MAIL="$RUN_DIR/mail.mbox"

{
  echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
  echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
  echo "To: $TO_EMAIL"
  echo "Subject: $SUBJ"
  echo
  echo "== DIFF vs PREV =="
  if [ "$BUILD_RAN" -eq 1 ] && [ "$SCAN_RAN" -eq 1 ]; then
    echo "-- build + sparse --"
    sed -n '1,260p' "$DIFF_PREV_BUILD" || true
  else
    echo "-- build + sparse --"
    echo "build skipped (no diff/output)"
  fi
  echo
  if [ "$TESTS_RAN" -eq 1 ]; then
    echo "-- tests --"
    sed -n '1,260p' "$DIFF_PREV_TEST" || true
  else
    echo "-- tests --"
    echo "tests skipped (no diff/output)"
  fi
  echo
  echo "== DIFF vs BASELINE =="
  if [ "$BUILD_RAN" -eq 1 ] && [ "$SCAN_RAN" -eq 1 ]; then
    echo "-- build + sparse --"
    sed -n '1,260p' "$DIFF_BASE_BUILD" || true
  else
    echo "-- build + sparse --"
    echo "build skipped (no diff/output)"
  fi
  echo
  if [ "$TESTS_RAN" -eq 1 ]; then
    echo "-- tests --"
    sed -n '1,260p' "$DIFF_BASE_TEST" || true
  else
    echo "-- tests --"
    echo "tests skipped (no diff/output)"
  fi
  echo
  echo "== CURRENT SUMMARY =="
  if [ "$BUILD_RAN" -eq 1 ] && [ "$SCAN_RAN" -eq 1 ]; then
    echo "-- build + sparse --"
    cat "$RUN_BUILD_SUMM" || true
  else
    echo "-- build + sparse --"
    echo "build skipped (no summary output)"
  fi
  echo
  if [ "$TESTS_RAN" -eq 1 ]; then
    echo "-- tests --"
    cat "$RUN_TEST_SUMM" || true
  else
    echo "-- tests --"
    echo "tests skipped (no summary output)"
  fi
  echo
  echo "Artifacts:"
  echo "  state dir: $STATE_DIR"
  echo "  run dir  : $RUN_DIR"
  echo "  O dir    : $O"
  echo "  meta     : $RUN_DIR/meta.txt"
  echo "  scan     : $RUN_DIR/scan.txt"
  echo "  build sum: $RUN_BUILD_SUMM"
  echo "  test sum : $RUN_TEST_SUMM"
  echo "  build log: $RUN_DIR/build.all.log"
  echo "  test log : $RUN_DIR/run-net.host.log"
} >"$MAIL"

run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""

echo "[auto] done. run_dir=$RUN_DIR" >&2
