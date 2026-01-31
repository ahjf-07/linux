#!/bin/sh
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: auto-bpf-ci.sh [-l] [-s] [-S "subtrees"] [-o outdir] [-t remote/branch] [-e to_email]
                      [-c] [-m] [-F] [-U] [-f N] [-P cpus] [-M mem]
                      [-K] [-T]
                      [--ff] [--full] [--reset-baseline] [--force] [--update]
                      [--no-test] [--no-build]

Defaults:
  track  : upstream/master
  switch : master (fast-forward only)
  update : off (build current HEAD)

Options:
  -l  LLVM=1 (clang). default clang
  -s  enable sparse (passed to build-bpf.sh)
  -S  sparse subtrees list (passed to build-bpf.sh)
  -o  outdir (default: ../out/full-clang)
  -t  tracked ref (default: upstream/master)
  -e  recipient (or env AUTO_EMAIL)

  -c  clean rebuild: remove $O (out dir) before build
  -m  mrproper-ish: remove $O and also remove $O/.config (forces re-config)
  -F  force-run: run even if no update after fetch; uses incremental build when possible
  -U  update: fetch + switch master + pull --ff-only TARGET_REF
  -f  fast tests: run N subtests (default: 30)
  -P  vng guest cpus (passed to run-bpf.sh)
  -M  vng guest memory (passed to run-bpf.sh, e.g. 2G)
  -K  build kernel only (pass -K to build-bpf.sh)
  -T  build tests only (pass -T to build-bpf.sh)

Long:
  --ff             faster tests (run 10 subtests)
  --full           full test_progs run
  --json           enable test_progs json summary (default)
  --no-json        disable test_progs json summary
  --update         same as -U
  --force          same as -F
  --no-test        skip vng tests
  --no-build       skip build
  --reset-baseline overwrite pinned baseline with this run
  --cpu N          same as -P
  --mem  SIZE      same as -M
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

need_exec config-bpf.sh
need_exec build-bpf.sh
need_exec scan-nb.sh
need_exec run-bpf.sh
need_exec summ-bpf.sh

LLVM=1
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
NO_SCAN=0
BUILD_SKIPPED=0
TEST_SKIPPED=0
SPARSE_SKIPPED=0

CLEAN=0
MRPROPER=0
UPDATE=0
TEST_FAST=1
TEST_FFAST=0
DRY_RUN=0
CPUS=2
MEM=2G
FAST_COUNT=30
JSON_SUMMARY=1
KERNEL_ONLY=0
TESTS_ONLY=0

_keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reset-baseline) RESET_BASELINE=1 ;;
    --force) FORCE=1 ;;
    --update) UPDATE=1 ;;
    --no-test) NO_TEST=1 ;;
    --no-build) NO_BUILD=1 ;;
    --ff) TEST_FFAST=1; TEST_FAST=0 ;;
    --full) TEST_FAST=0; TEST_FFAST=0 ;;
    --json) JSON_SUMMARY=1 ;;
    --no-json) JSON_SUMMARY=0 ;;
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

while getopts "lsS:o:t:e:cmFUf:P:M:KT" opt; do
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
    f)
      TEST_FAST=1
      TEST_FFAST=0
      FAST_COUNT="$OPTARG"
      ;;
    P) CPUS="$OPTARG" ;;
    M) MEM="$OPTARG" ;;
    K) KERNEL_ONLY=1; FORCE=1 ;;
    T) TESTS_ONLY=1; FORCE=1 ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))

[ -n "$TO_EMAIL" ] || { echo "ERROR: missing recipient; use -e or set AUTO_EMAIL" >&2; exit 2; }

LINUX_ROOT="$(pwd)"

if [ "$KERNEL_ONLY" -eq 1 ]; then
  echo "[auto] ONLY_KERNEL: disabling tests and scan" >&2
  NO_TEST=1
  NO_SCAN=1
fi

if [ "$NO_BUILD" -eq 1 ] && [ "$NO_TEST" -eq 1 ]; then
  echo "ERROR: --no-build and --no-test cannot be used together" >&2
  exit 2
fi

if [ "$NO_BUILD" -eq 1 ]; then
  BUILD_SKIPPED=1
  NO_SCAN=1
fi
if [ "$NO_TEST" -eq 1 ]; then
  TEST_SKIPPED=1
fi
if [ "$SPARSE" -eq 0 ] || [ "$NO_SCAN" -eq 1 ]; then
  SPARSE_SKIPPED=1
fi

if [ -z "$O" ]; then
  O="$LINUX_ROOT/../out/full-clang"
fi
O="$(realpath -m "$O")"
mkdir -p "$O"

STATE_DIR="${AUTO_BPF_STATE_DIR:-$LINUX_ROOT/../out/auto-bpf-state}"
mkdir -p "$STATE_DIR"

ARCH="$(uname -m)"
KEY="${ARCH}.clang"

PREV_DIR="$STATE_DIR/prev/$KEY"
BASE_DIR="$STATE_DIR/baseline/$KEY"
RUNS_DIR="$STATE_DIR/runs/$KEY"
mkdir -p "$PREV_DIR" "$BASE_DIR" "$RUNS_DIR"

now="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$RUNS_DIR/$now"
mkdir -p "$RUN_DIR"

BUILD_LOGS="build.olddefconfig.log build.kernel.log build.headers.log build.selftests.bpf.log build.clean.log build.mrproper.log"
PREV_BUILD_DIR="$PREV_DIR/build-logs"
PREV_BUILD_ALL="$PREV_DIR/build.all.log"
RUN_BUILD_DIR="$RUN_DIR/build-logs"
mkdir -p "$RUN_BUILD_DIR"

run() { echo "+ $*" >&2; bash -lc "set -o pipefail; $*"; }

FETCH_REMOTE="upstream"
TARGET_BRANCH="$SWITCH_BRANCH"

if [ "${DRY_RUN:-0}" -eq 1 ]; then
  targs=""
  [ "$LLVM" -eq 1 ] && targs="$targs -l"
  targs="$targs -r \"$LINUX_ROOT\" -o \"$O\""
  if [ "${TEST_FFAST:-0}" -eq 1 ]; then
    targs="$targs --ff"
  elif [ "${TEST_FAST:-0}" -eq 1 ]; then
    targs="$targs -f \"$FAST_COUNT\""
  fi
  targs="$targs -p \"$CPUS\" -m \"$MEM\""
  if [ "$JSON_SUMMARY" -eq 1 ]; then
    targs="$targs -j"
  fi
  echo "[dry-run] run-bpf args: $targs" >&2
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
if [ -z "$old_ref" ] || [ "$new_ref" != "$old_ref" ]; then
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
  echo "NO_SCAN=$NO_SCAN"
  echo "KERNEL_ONLY=$KERNEL_ONLY"
  echo "TESTS_ONLY=$TESTS_ONLY"
  echo "CPUS=$CPUS"
  echo "MEM=$MEM"
  echo "FAST_COUNT=$FAST_COUNT"
  echo "JSON_SUMMARY=$JSON_SUMMARY"
  echo
  git log -1 --oneline "$new_ref" || true
} >"$RUN_DIR/meta.txt"

if [ "$ref_updated" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ "$CLEAN" -eq 0 ] && [ "$MRPROPER" -eq 0 ]; then
  SUBJ="[auto-bpf][$KEY] no updates: $REF_LABEL still $new_ref"
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

echo "$new_ref" >"$STATE_DIR/last_ref.$KEY"

if [ "$MRPROPER" -eq 1 ]; then
  CLEAN=1
fi
if [ "$CLEAN" -eq 1 ]; then
  echo "[auto] CLEAN=1: wiping O=$O" >&2
  rm -rf "$O"
  rm -rf "$LINUX_ROOT/.kselftest-out/selftests-bpf" 2>/dev/null || true
  mkdir -p "$O"
fi
if [ "$MRPROPER" -eq 1 ]; then
  echo "[auto] MRPROPER=1: remove $O/.config (force re-config)" >&2
  rm -f "$O/.config"
fi

if [ "$UPDATE" -eq 1 ]; then
  git diff --quiet && git diff --cached --quiet || {
    SUBJ="[auto-bpf][$KEY] update/force but REFUSE switch: dirty tree"
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
    SUBJ="[auto-bpf][$KEY] update/force but FF-only failed: $SWITCH_BRANCH <- $TARGET_REF"
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
fi
if [ "$UPDATE" -eq 0 ]; then
  echo "NOTE: update disabled; building current HEAD" >>"$RUN_DIR/meta.txt"
fi
head_after="$(git rev-parse HEAD)"

if [ "$NO_BUILD" -eq 0 ]; then
  if [ ! -f "$O/.config" ]; then
    cargs="-l"
    [ "$CLEAN" -eq 1 ] && cargs="$cargs -c"
    [ "$MRPROPER" -eq 1 ] && cargs="$cargs -m"
    run "\"$TOOL_DIR/config-bpf.sh\" $cargs -r \"$LINUX_ROOT\" -o \"$O\" |& tee \"$RUN_DIR/config.log\""
  fi

  bargs="-l"
  [ "$SPARSE" -eq 1 ] && bargs="$bargs -s"
  [ -n "$SPARSE_SUBTREES" ] && bargs="$bargs -S \"$SPARSE_SUBTREES\""
# build-bpf.sh: -c/-m 互斥；-m 在 auto 里已经做了 rm -rf O + rm -f O/.config + 重新 config
if [ "$MRPROPER" -eq 1 ]; then
  :  # do not pass -c/-m to build-bpf.sh
elif [ "$CLEAN" -eq 1 ]; then
  bargs="$bargs -c"
fi
  if [ "$force_incremental" -eq 1 ]; then
    bargs="$bargs -i"
  fi
  if [ "$KERNEL_ONLY" -eq 1 ] && [ "$TESTS_ONLY" -eq 0 ]; then
    bargs="$bargs -K"
  elif [ "$TESTS_ONLY" -eq 1 ] && [ "$KERNEL_ONLY" -eq 0 ]; then
    bargs="$bargs -T"
  fi
  bargs="$bargs -r \"$LINUX_ROOT\" -o \"$O\""
  run "bash \"$TOOL_DIR/build-bpf.sh\" $bargs |& tee \"$RUN_DIR/build.all.log\""
else
  echo "[auto] --no-build: skip build" >"$RUN_DIR/build.all.log"
fi

incremental_skipped=0
if [ "$NO_BUILD" -eq 0 ] && [ "$force_incremental" -eq 1 ]; then
  if [ -f "$O/build.olddefconfig.log" ] && grep -q "up to date: skip olddefconfig" "$O/build.olddefconfig.log" \
    && [ -f "$O/build.kernel.log" ] && grep -q "up to date: skip kernel build" "$O/build.kernel.log" \
    && [ -f "$O/build.headers.log" ] && grep -q "up to date: skip headers_install" "$O/build.headers.log" \
    && [ -f "$O/build.selftests.bpf.log" ] && grep -q "up to date: skip selftests/bpf" "$O/build.selftests.bpf.log"; then
    incremental_skipped=1
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
      if [ -f "$O/build.selftests.bpf.log" ] && grep -q "up to date: skip selftests/bpf" "$O/build.selftests.bpf.log"; then
        [ -f "$PREV_BUILD_DIR/build.selftests.bpf.log" ] && cp -f "$PREV_BUILD_DIR/build.selftests.bpf.log" "$O/build.selftests.bpf.log"
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
if [ "$NO_SCAN" -eq 0 ]; then
  if [ "$incremental_skipped" -eq 1 ] && [ -f "$RUN_DIR/scan.txt" ]; then
    echo "[auto] incremental build skipped; reuse scan.txt" >&2
  else
    run "\"$TOOL_DIR/scan-nb.sh\" -e -w -s -n 120 -k bpf -r \"$LINUX_ROOT\" -o \"$O\" >\"$RUN_DIR/scan.txt\" 2>&1 || true"
  fi
else
  echo "[auto] --no-scan: skip scan" >"$RUN_DIR/scan.txt"
fi

WARN_LIST="$RUN_DIR/scan.warnings.txt"
ERR_LIST="$RUN_DIR/scan.errors.txt"
SPARSE_LIST="$RUN_DIR/scan.sparse.txt"
if [ "$NO_SCAN" -eq 0 ]; then
  awk '
    function normalize(line) {
      sub(/^[0-9]+:/, "", line);
      gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
      return line;
    }
    /^==== warnings \(first / { in=1; next }
    /^====/ { if (in) in=0 }
    in && /^[0-9]+:/ { print normalize($0) }
  ' "$RUN_DIR/scan.txt" >"$WARN_LIST" 2>/dev/null || true
  awk '
    function normalize(line) {
      sub(/^[0-9]+:/, "", line);
      gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
      return line;
    }
    /^==== errors \(first / { in=1; next }
    /^====/ { if (in) in=0 }
    in && /^[0-9]+:/ { print normalize($0) }
  ' "$RUN_DIR/scan.txt" >"$ERR_LIST" 2>/dev/null || true
  awk '
    function normalize(line) {
      sub(/^[0-9]+:/, "", line);
      gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
      return line;
    }
    /^==== sparse diagnostics \(first / { in=1; next }
    /^====/ { if (in) in=0 }
    in && /^[0-9]+:/ { print normalize($0) }
  ' "$RUN_DIR/scan.txt" >"$SPARSE_LIST" 2>/dev/null || true
fi

TEST_LOG_SRC="$LINUX_ROOT/.kselftest-out/bpf.selftests.log"
TEST_LOG_DST="$RUN_DIR/bpf.selftests.log"
TEST_JSON_SRC="$LINUX_ROOT/.kselftest-out/bpf-json"
TEST_JSON_DST="$RUN_DIR/bpf-json"
SUMM_LOG="$RUN_DIR/bpf.summ.txt"

if [ "$NO_TEST" -eq 0 ]; then
  targs=""
  [ "$LLVM" -eq 1 ] && targs="$targs -l"
  targs="$targs -r \"$LINUX_ROOT\" -o \"$O\""
  if [ "${TEST_FFAST:-0}" -eq 1 ]; then
    targs="$targs --ff"
  elif [ "${TEST_FAST:-0}" -eq 1 ]; then
    targs="$targs -f \"$FAST_COUNT\""
  fi
  targs="$targs -p \"$CPUS\" -m \"$MEM\""
  if [ "$JSON_SUMMARY" -eq 1 ]; then
    targs="$targs -j"
  fi
  run "\"$TOOL_DIR/run-bpf.sh\" $targs |& tee \"$RUN_DIR/run-bpf.host.log\""

  if [ -f "$TEST_LOG_SRC" ]; then
    cp -f "$TEST_LOG_SRC" "$TEST_LOG_DST"
    if [ -d "$TEST_JSON_SRC" ]; then
      rm -rf "$TEST_JSON_DST"
      cp -a "$TEST_JSON_SRC" "$TEST_JSON_DST"
    fi
    run "\"$TOOL_DIR/summ-bpf.sh\" \"$TEST_LOG_DST\" >\"$SUMM_LOG\""
  else
    echo "ERROR: missing $TEST_LOG_SRC" >"$SUMM_LOG"
  fi
else
  echo "[auto] --no-test: skip tests" >"$SUMM_LOG"
fi

build_essentials() {
  out="$1"
  scan="$RUN_DIR/scan.txt"
  topn="${AUTO_BPF_TOPN:-50}"

  {
    echo "## build (filtered)"

    awk '
      function reset_counts() {
        err=0; warn=0;
      }
      function flush_summary() {
        if (sum != "") {
          if ((err + warn) > 0) {
            printf "%s\n", sum;
          }
          sum="";
        }
        reset_counts();
      }
      function normalize_line(line) {
        sub(/^[0-9]+:/, "", line);
        gsub(/:[0-9]+(:[0-9]+)?:/, ":", line);
        return line;
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
        if ($0 ~ /^sparse_effective[[:space:]]*:/) { next }
        if ($0 ~ /^sparse[[:space:]]*:/) { next }
        sum = sum $0 "\n";
        if ($0 ~ /^errors_effective[[:space:]]*:/) { err=$NF + 0; }
        else if ($0 ~ /^errors[[:space:]]*:/) { err=$NF + 0; }
        else if ($0 ~ /^warnings[[:space:]]*:/) { warn=$NF + 0; }
        if ($0 ~ /^$/) { in_sum=0; flush_summary(); }
        next
      }

      /^==== errors \(first /           { flush_list(sec, list); sec="errors"; list=""; next }
      /^==== warnings \(first /         { flush_list(sec, list); sec=""; list=""; next }
      (sec!="") && ($0 ~ /^[0-9]+:/) { list = list normalize_line($0) "\n"; next }

      END{
        flush_list(sec, list);
        flush_summary();
      }
    ' "$scan" 2>/dev/null || true

    echo
    echo "## current errors (top ${topn})"
    if [ -s "$ERR_LIST" ]; then
      awk -v topn="$topn" '
        { counts[$0]++ }
        END {
          for (line in counts) {
            printf "%6d  %s\n", counts[line], line
          }
        }
      ' "$ERR_LIST" | sort -rn | head -n "$topn"
    else
      echo "(none)"
    fi

    echo
    echo "## current warnings (top ${topn})"
    if [ -s "$WARN_LIST" ]; then
      awk -v topn="$topn" '
        { counts[$0]++ }
        END {
          for (line in counts) {
            printf "%6d  %s\n", counts[line], line
          }
        }
      ' "$WARN_LIST" | sort -rn | head -n "$topn"
    else
      echo "(none)"
    fi

    if [ -f "$BASE_DIR/scan.warnings.txt" ] && [ -f "$WARN_LIST" ]; then
      diff -u "$BASE_DIR/scan.warnings.txt" "$WARN_LIST" >"$RUN_DIR/diff.warnings.vs-baseline.txt" || true
      if [ -s "$RUN_DIR/diff.warnings.vs-baseline.txt" ]; then
        echo
        echo "## warnings delta vs baseline"
        sed -n '1,200p' "$RUN_DIR/diff.warnings.vs-baseline.txt" || true
      fi
    fi

  } >"$out"
}

sparses_essentials() {
  out="$1"
  topn="${AUTO_BPF_TOPN:-50}"
  {
    echo "## sparse diagnostics"
    cat "$SPARSE_LIST" 2>/dev/null || true

    echo
    echo "## sparse diagnostics (top ${topn})"
    if [ -s "$SPARSE_LIST" ]; then
      awk -v topn="$topn" '
        { counts[$0]++ }
        END {
          for (line in counts) {
            printf "%6d  %s\n", counts[line], line
          }
        }
      ' "$SPARSE_LIST" | sort -rn | head -n "$topn"
    else
      echo "(none)"
    fi

    if [ -f "$BASE_DIR/scan.sparse.txt" ] && [ -f "$SPARSE_LIST" ]; then
      diff -u "$BASE_DIR/scan.sparse.txt" "$SPARSE_LIST" >"$RUN_DIR/diff.sparse.vs-baseline.txt" || true
      if [ -s "$RUN_DIR/diff.sparse.vs-baseline.txt" ]; then
        echo
        echo "## sparse delta vs baseline"
        sed -n '1,200p' "$RUN_DIR/diff.sparse.vs-baseline.txt" || true
      fi
    fi
  } >"$out"
}

tests_essentials() {
  out="$1"
  {
    echo "## selftests (bpf)"
    cat "$SUMM_LOG" 2>/dev/null || true
  } >"$out"
}

bundle_build() {
  out="$1"
  {
    echo "## meta"
    cat "$RUN_DIR/meta.txt" || true
    echo
    echo "## build"
    cat "$RUN_DIR/build.all.log" || true
    echo
    echo "## warnings"
    cat "$WARN_LIST" 2>/dev/null || true
  } >"$out"
}

bundle_sparse() {
  out="$1"
  {
    echo "## meta"
    cat "$RUN_DIR/meta.txt" || true
    echo
    echo "## scan"
    cat "$RUN_DIR/scan.txt" 2>/dev/null || true
    echo
    echo "## sparse diagnostics"
    cat "$SPARSE_LIST" 2>/dev/null || true
  } >"$out"
}

bundle_tests() {
  out="$1"
  {
    echo "## meta"
    cat "$RUN_DIR/meta.txt" || true
    echo
    echo "## bpf summary"
    cat "$RUN_DIR/bpf.summ.txt" || true
  } >"$out"
}

BUILD_TXT="$RUN_DIR/result.build.txt"
SPARSE_TXT="$RUN_DIR/result.sparse.txt"
TESTS_TXT="$RUN_DIR/result.tests.txt"
bundle_build "$BUILD_TXT"
bundle_sparse "$SPARSE_TXT"
bundle_tests "$TESTS_TXT"

BUILD_ESS="$RUN_DIR/build.essentials.txt"
SPARSE_ESS="$RUN_DIR/sparse.essentials.txt"
TESTS_ESS="$RUN_DIR/tests.essentials.txt"
if [ "$BUILD_SKIPPED" -eq 0 ]; then
  build_essentials "$BUILD_ESS"
else
  echo "(build skipped)" >"$BUILD_ESS"
fi
if [ "$SPARSE_SKIPPED" -eq 0 ]; then
  sparses_essentials "$SPARSE_ESS"
else
  echo "(sparse skipped)" >"$SPARSE_ESS"
fi
if [ "$TEST_SKIPPED" -eq 0 ]; then
  tests_essentials "$TESTS_ESS"
else
  echo "(tests skipped)" >"$TESTS_ESS"
fi

PREV_BUILD_ESS="$PREV_DIR/build.essentials.txt"
BASE_BUILD_ESS="$BASE_DIR/build.essentials.txt"
DIFF_PREV_BUILD_ESS="$RUN_DIR/diff.build.vs-prev.txt"
DIFF_BASE_BUILD_ESS="$RUN_DIR/diff.build.vs-baseline.txt"

if [ "$BUILD_SKIPPED" -eq 0 ]; then
  if [ -f "$PREV_BUILD_ESS" ]; then
    diff -u "$PREV_BUILD_ESS" "$BUILD_ESS" >"$DIFF_PREV_BUILD_ESS" || true
    [ -s "$DIFF_PREV_BUILD_ESS" ] || echo "(no substantive diff vs prev)" >"$DIFF_PREV_BUILD_ESS"
  else
    echo "(no previous build summary)" >"$DIFF_PREV_BUILD_ESS"
  fi

  if [ -f "$BASE_BUILD_ESS" ]; then
    diff -u "$BASE_BUILD_ESS" "$BUILD_ESS" >"$DIFF_BASE_BUILD_ESS" || true
    [ -s "$DIFF_BASE_BUILD_ESS" ] || echo "(no substantive diff vs baseline)" >"$DIFF_BASE_BUILD_ESS"
  else
    echo "(no build baseline yet)" >"$DIFF_BASE_BUILD_ESS"
  fi
else
  echo "(build skipped)" >"$DIFF_PREV_BUILD_ESS"
  echo "(build skipped)" >"$DIFF_BASE_BUILD_ESS"
fi

PREV_TESTS_ESS="$PREV_DIR/tests.essentials.txt"
BASE_TESTS_ESS="$BASE_DIR/tests.essentials.txt"
DIFF_PREV_TESTS_ESS="$RUN_DIR/diff.tests.vs-prev.txt"
DIFF_BASE_TESTS_ESS="$RUN_DIR/diff.tests.vs-baseline.txt"

PREV_SPARSE_ESS="$PREV_DIR/sparse.essentials.txt"
BASE_SPARSE_ESS="$BASE_DIR/sparse.essentials.txt"
DIFF_PREV_SPARSE_ESS="$RUN_DIR/diff.sparse.vs-prev.txt"
DIFF_BASE_SPARSE_ESS="$RUN_DIR/diff.sparse.vs-baseline.txt"

if [ "$SPARSE_SKIPPED" -eq 0 ]; then
  if [ -f "$PREV_SPARSE_ESS" ]; then
    diff -u "$PREV_SPARSE_ESS" "$SPARSE_ESS" >"$DIFF_PREV_SPARSE_ESS" || true
    [ -s "$DIFF_PREV_SPARSE_ESS" ] || echo "(no substantive diff vs prev)" >"$DIFF_PREV_SPARSE_ESS"
  else
    echo "(no previous sparse summary)" >"$DIFF_PREV_SPARSE_ESS"
  fi

  if [ -f "$BASE_SPARSE_ESS" ]; then
    diff -u "$BASE_SPARSE_ESS" "$SPARSE_ESS" >"$DIFF_BASE_SPARSE_ESS" || true
    [ -s "$DIFF_BASE_SPARSE_ESS" ] || echo "(no substantive diff vs baseline)" >"$DIFF_BASE_SPARSE_ESS"
  else
    echo "(no sparse baseline yet)" >"$DIFF_BASE_SPARSE_ESS"
  fi
else
  echo "(sparse skipped)" >"$DIFF_PREV_SPARSE_ESS"
  echo "(sparse skipped)" >"$DIFF_BASE_SPARSE_ESS"
fi

if [ "$TEST_SKIPPED" -eq 0 ]; then
  if [ -f "$PREV_TESTS_ESS" ]; then
    diff -u "$PREV_TESTS_ESS" "$TESTS_ESS" >"$DIFF_PREV_TESTS_ESS" || true
    [ -s "$DIFF_PREV_TESTS_ESS" ] || echo "(no substantive diff vs prev)" >"$DIFF_PREV_TESTS_ESS"
  else
    echo "(no previous test summary)" >"$DIFF_PREV_TESTS_ESS"
  fi

  if [ -f "$BASE_TESTS_ESS" ]; then
    diff -u "$BASE_TESTS_ESS" "$TESTS_ESS" >"$DIFF_BASE_TESTS_ESS" || true
    [ -s "$DIFF_BASE_TESTS_ESS" ] || echo "(no substantive diff vs baseline)" >"$DIFF_BASE_TESTS_ESS"
  else
    echo "(no tests baseline yet)" >"$DIFF_BASE_TESTS_ESS"
  fi
else
  echo "(tests skipped)" >"$DIFF_PREV_TESTS_ESS"
  echo "(tests skipped)" >"$DIFF_BASE_TESTS_ESS"
fi

PREV_BUILD_TXT="$PREV_DIR/result.build.txt"
BASE_BUILD_TXT="$BASE_DIR/result.build.txt"
DIFF_PREV_BUILD="$RUN_DIR/diff.build.full.vs-prev.txt"
DIFF_BASE_BUILD="$RUN_DIR/diff.build.full.vs-baseline.txt"

if [ "$BUILD_SKIPPED" -eq 0 ]; then
  if [ -f "$PREV_BUILD_TXT" ]; then
    diff -u "$PREV_BUILD_TXT" "$BUILD_TXT" >"$DIFF_PREV_BUILD" || true
  else
    echo "(no previous build result)" >"$DIFF_PREV_BUILD"
  fi

  if [ -f "$BASE_BUILD_TXT" ]; then
    diff -u "$BASE_BUILD_TXT" "$BUILD_TXT" >"$DIFF_BASE_BUILD" || true
  else
    echo "(no build baseline yet)" >"$DIFF_BASE_BUILD"
  fi
else
  echo "(build skipped)" >"$DIFF_PREV_BUILD"
  echo "(build skipped)" >"$DIFF_BASE_BUILD"
fi

PREV_TESTS_TXT="$PREV_DIR/result.tests.txt"
BASE_TESTS_TXT="$BASE_DIR/result.tests.txt"
DIFF_PREV_TESTS="$RUN_DIR/diff.tests.full.vs-prev.txt"
DIFF_BASE_TESTS="$RUN_DIR/diff.tests.full.vs-baseline.txt"

PREV_SPARSE_TXT="$PREV_DIR/result.sparse.txt"
BASE_SPARSE_TXT="$BASE_DIR/result.sparse.txt"
DIFF_PREV_SPARSE="$RUN_DIR/diff.sparse.full.vs-prev.txt"
DIFF_BASE_SPARSE="$RUN_DIR/diff.sparse.full.vs-baseline.txt"

if [ "$SPARSE_SKIPPED" -eq 0 ]; then
  if [ -f "$PREV_SPARSE_TXT" ]; then
    diff -u "$PREV_SPARSE_TXT" "$SPARSE_TXT" >"$DIFF_PREV_SPARSE" || true
  else
    echo "(no previous sparse result)" >"$DIFF_PREV_SPARSE"
  fi

  if [ -f "$BASE_SPARSE_TXT" ]; then
    diff -u "$BASE_SPARSE_TXT" "$SPARSE_TXT" >"$DIFF_BASE_SPARSE" || true
  else
    echo "(no sparse baseline yet)" >"$DIFF_BASE_SPARSE"
  fi
else
  echo "(sparse skipped)" >"$DIFF_PREV_SPARSE"
  echo "(sparse skipped)" >"$DIFF_BASE_SPARSE"
fi

if [ "$TEST_SKIPPED" -eq 0 ]; then
  if [ -f "$PREV_TESTS_TXT" ]; then
    diff -u "$PREV_TESTS_TXT" "$TESTS_TXT" >"$DIFF_PREV_TESTS" || true
  else
    echo "(no previous tests result)" >"$DIFF_PREV_TESTS"
  fi

  if [ -f "$BASE_TESTS_TXT" ]; then
    diff -u "$BASE_TESTS_TXT" "$TESTS_TXT" >"$DIFF_BASE_TESTS" || true
  else
    echo "(no tests baseline yet)" >"$DIFF_BASE_TESTS"
  fi
else
  echo "(tests skipped)" >"$DIFF_PREV_TESTS"
  echo "(tests skipped)" >"$DIFF_BASE_TESTS"
fi

if [ "$BUILD_SKIPPED" -eq 0 ]; then
  cp -f "$BUILD_TXT" "$PREV_BUILD_TXT"
  cp -f "$BUILD_ESS" "$PREV_BUILD_ESS"
  cp -f "$RUN_DIR/scan.txt" "$PREV_DIR/scan.txt" 2>/dev/null || true
  cp -f "$WARN_LIST" "$PREV_DIR/scan.warnings.txt" 2>/dev/null || true
  if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_BUILD_TXT" ]; then
    cp -f "$BUILD_TXT" "$BASE_BUILD_TXT"
    cp -f "$BUILD_ESS" "$BASE_BUILD_ESS"
    cp -f "$WARN_LIST" "$BASE_DIR/scan.warnings.txt" 2>/dev/null || true
  fi
fi

if [ "$SPARSE_SKIPPED" -eq 0 ]; then
  cp -f "$SPARSE_TXT" "$PREV_SPARSE_TXT"
  cp -f "$SPARSE_ESS" "$PREV_SPARSE_ESS"
  cp -f "$SPARSE_LIST" "$PREV_DIR/scan.sparse.txt" 2>/dev/null || true
  if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_SPARSE_TXT" ]; then
    cp -f "$SPARSE_TXT" "$BASE_SPARSE_TXT"
    cp -f "$SPARSE_ESS" "$BASE_SPARSE_ESS"
    cp -f "$SPARSE_LIST" "$BASE_DIR/scan.sparse.txt" 2>/dev/null || true
  fi
fi

if [ "$TEST_SKIPPED" -eq 0 ]; then
  cp -f "$TESTS_TXT" "$PREV_TESTS_TXT"
  cp -f "$TESTS_ESS" "$PREV_TESTS_ESS"
  if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_TESTS_TXT" ]; then
    cp -f "$TESTS_TXT" "$BASE_TESTS_TXT"
    cp -f "$TESTS_ESS" "$BASE_TESTS_ESS"
  fi
fi

SUBJ="[auto-bpf][$KEY] run done: ref_updated=$ref_updated force=$FORCE HEAD=$head_after"
MAIL="$RUN_DIR/mail.result.mbox"
{
  echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
  echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
  echo "To: $TO_EMAIL"
  echo "Subject: $SUBJ"
  echo
  echo "== BUILD SUMMARY =="
  if [ "$BUILD_SKIPPED" -eq 1 ]; then
    echo "build skipped"
  else
    echo
    echo "-- diff (substantive) vs PREV --"
    sed -n '1,260p' "$DIFF_PREV_BUILD_ESS" || true
    echo
    echo "-- diff (substantive) vs BASELINE --"
    sed -n '1,260p' "$DIFF_BASE_BUILD_ESS" || true
    echo
    echo "-- current (substantive summary) --"
    cat "$BUILD_ESS" || true
    echo
    echo "-- build artifacts (no full logs in email) --"
    echo "build summary : $BUILD_ESS"
    echo "build bundle  : $BUILD_TXT"
  fi
  echo
  echo "== TEST SUMMARY =="
  if [ "$TEST_SKIPPED" -eq 1 ]; then
    echo "tests skipped"
  else
    echo
    echo "-- diff (substantive) vs PREV --"
    sed -n '1,260p' "$DIFF_PREV_TESTS_ESS" || true
    echo
    echo "-- diff (substantive) vs BASELINE --"
    sed -n '1,260p' "$DIFF_BASE_TESTS_ESS" || true
    echo
    echo "-- current (substantive summary) --"
    cat "$TESTS_ESS" || true
    echo
    echo "-- test artifacts (no full logs in email) --"
    echo "tests summary : $TESTS_ESS"
    echo "tests bundle  : $TESTS_TXT"
    echo "tests json    : $TEST_JSON_DST"
    echo "tests log     : $TEST_LOG_DST"
  fi
  echo
  echo "== SPARSE SUMMARY =="
  if [ "$SPARSE_SKIPPED" -eq 1 ]; then
    echo "sparse skipped"
  else
    echo
    echo "-- diff (substantive) vs PREV --"
    sed -n '1,260p' "$DIFF_PREV_SPARSE_ESS" || true
    echo
    echo "-- diff (substantive) vs BASELINE --"
    sed -n '1,260p' "$DIFF_BASE_SPARSE_ESS" || true
    echo
    echo "-- current (substantive summary) --"
    cat "$SPARSE_ESS" || true
    echo
    echo "-- sparse artifacts (no full logs in email) --"
    echo "sparse summary: $SPARSE_ESS"
    echo "sparse bundle : $SPARSE_TXT"
  fi
  echo
  echo "Artifacts:"
  echo "  state dir: $STATE_DIR"
  echo "  run dir  : $RUN_DIR"
  echo "  O dir    : $O"
} >"$MAIL"

run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""

echo "[auto] done. run_dir=$RUN_DIR" >&2
