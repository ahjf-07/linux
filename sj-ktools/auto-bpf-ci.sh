#!/bin/sh
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: auto-bpf-ci.sh [-l] [-s] [-S "subtrees"] [-o outdir] [-t remote/branch] [-e to_email]
                      [-c] [-m] [-N] [-F] [-f N] [-P cpus] [-M mem]
                      [--ff] [--full] [--reset-baseline] [--force] [--no-fetch] [--no-test] [--no-build]

Defaults:
  track  : upstream/master
  switch : master (fast-forward only)

Options:
  -l  LLVM=1 (clang). default clang
  -g  LLVM=0 (gcc)
  -s  enable sparse (passed to build-bpf.sh)
  -S  sparse subtrees list (passed to build-bpf.sh)
  -o  outdir (default: ../out/full-clang)
  -t  tracked ref (default: upstream/master)
  -e  recipient (or env AUTO_EMAIL)

  -c  clean rebuild: remove $O (out dir) before build
  -m  mrproper-ish: remove $O and also remove $O/.config (forces re-config)
  -N  no-merge: skip git switch/ff-only merge, build current HEAD (dirty OK)
  -F  force-run: run even if no update after fetch; uses incremental build when possible
  -f  fast tests: run N subtests (default: 30)
  -P  vng guest cpus (passed to run-bpf.sh)
  -M  vng guest memory (passed to run-bpf.sh, e.g. 2G)

Long:
  --ff             faster tests (run 10 subtests)
  --full           full test_progs run
  --json           enable test_progs json summary (default)
  --no-json        disable test_progs json summary
  --no-fetch       skip git fetch
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
NO_FETCH=0
NO_TEST=0
NO_BUILD=0

CLEAN=0
MRPROPER=0
NO_MERGE=0
TEST_FAST=1
TEST_FFAST=0
DRY_RUN=0
CPUS=2
MEM=2G
FAST_COUNT=30
JSON_SUMMARY=1

_keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reset-baseline) RESET_BASELINE=1 ;;
    --force) FORCE=1 ;;
    --no-fetch) NO_FETCH=1 ;;
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

while getopts "lgsS:o:t:e:cmNFf:P:M:" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    g) LLVM=0 ;;
    s) SPARSE=1 ;;
    S) SPARSE_SUBTREES="$OPTARG" ;;
    o) O="$OPTARG" ;;
    t) TARGET_REF="$OPTARG" ;;
    e) TO_EMAIL="$OPTARG" ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    N) NO_MERGE=1 ;;
    F) FORCE=1 ;;
    f)
      TEST_FAST=1
      TEST_FFAST=0
      FAST_COUNT="$OPTARG"
      ;;
    P) CPUS="$OPTARG" ;;
    M) MEM="$OPTARG" ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))

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

STATE_DIR="${AUTO_BPF_STATE_DIR:-$LINUX_ROOT/../out/auto-bpf-state}"
mkdir -p "$STATE_DIR"

ARCH="$(uname -m)"
KEY="${ARCH}.$([ "$LLVM" -eq 1 ] && echo clang || echo gcc)"

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

if echo "$TARGET_REF" | grep -q '/'; then
  FETCH_REMOTE="${TARGET_REF%%/*}"
else
  FETCH_REMOTE="upstream"
fi

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

if [ "$NO_FETCH" -eq 0 ]; then
  if git remote get-url "$FETCH_REMOTE" >/dev/null 2>&1; then
    run "git fetch --prune \"$FETCH_REMOTE\""
  else
    echo "WARN: remote '$FETCH_REMOTE' not found; falling back to 'git fetch --prune'." >&2
    run "git fetch --prune"
  fi
else
  echo "[auto] --no-fetch: skip git fetch" >&2
fi

old_ref="$(cat "$STATE_DIR/last_ref.$KEY" 2>/dev/null || true)"
new_ref="$(git rev-parse "$TARGET_REF" 2>/dev/null || true)"
head_before="$(git rev-parse HEAD)"

[ -n "$new_ref" ] || { echo "ERROR: cannot resolve TARGET_REF=$TARGET_REF" >&2; exit 2; }

ref_updated=0
if [ -z "$old_ref" ] || [ "$new_ref" != "$old_ref" ]; then
  ref_updated=1
fi
force_incremental=0
if [ "$FORCE" -eq 1 ] && [ "$CLEAN" -eq 0 ] && [ "$MRPROPER" -eq 0 ]; then
  if [ "$ref_updated" -eq 0 ] || [ "$NO_FETCH" -eq 1 ]; then
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
  echo "NO_MERGE=$NO_MERGE"
  echo "CLEAN=$CLEAN"
  echo "MRPROPER=$MRPROPER"
  echo "NO_BUILD=$NO_BUILD"
  echo "NO_TEST=$NO_TEST"
  echo "CPUS=$CPUS"
  echo "MEM=$MEM"
  echo "FAST_COUNT=$FAST_COUNT"
  echo "JSON_SUMMARY=$JSON_SUMMARY"
  echo
  git log -1 --oneline "$new_ref" || true
} >"$RUN_DIR/meta.txt"

if [ "$ref_updated" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ "$CLEAN" -eq 0 ] && [ "$MRPROPER" -eq 0 ]; then
  SUBJ="[auto-bpf][$KEY] no updates: $TARGET_REF still $new_ref"
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

if [ "$NO_MERGE" -eq 0 ]; then
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
      echo "Use -N to skip merge, or stash/commit changes."
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

  if ! git merge --ff-only "$TARGET_REF" >/dev/null 2>&1; then
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
head_after="$(git rev-parse HEAD)"

if [ "$NO_BUILD" -eq 0 ]; then
  if [ ! -f "$O/.config" ]; then
    cargs=""
    [ "$LLVM" -eq 1 ] && cargs="$cargs -l" || cargs="$cargs -g"
    [ "$CLEAN" -eq 1 ] && cargs="$cargs -c"
    [ "$MRPROPER" -eq 1 ] && cargs="$cargs -m"
    run "\"$TOOL_DIR/config-bpf.sh\" $cargs -r \"$LINUX_ROOT\" -o \"$O\" |& tee \"$RUN_DIR/config.log\""
  fi

  bargs=""
  [ "$LLVM" -eq 1 ] && bargs="$bargs -l" || bargs="$bargs"   # build 没 -g 就不传
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
  bargs="$bargs -r \"$LINUX_ROOT\" -o \"$O\""
  run "\"$TOOL_DIR/build-bpf.sh\" $bargs |& tee \"$RUN_DIR/build.all.log\""
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
run "\"$TOOL_DIR/scan-nb.sh\" -e -w -s -n 120 -k bpf -r \"$LINUX_ROOT\" -o \"$O\" >\"$RUN_DIR/scan.txt\" 2>&1 || true"

WARN_LIST="$RUN_DIR/scan.warnings.txt"
SPARSE_LIST="$RUN_DIR/scan.sparse.txt"
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
  /^==== sparse diagnostics \(first / { in=1; next }
  /^====/ { if (in) in=0 }
  in && /^[0-9]+:/ { print normalize($0) }
' "$RUN_DIR/scan.txt" >"$SPARSE_LIST" 2>/dev/null || true

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

essentials() {
  out="$1"
  scan="$RUN_DIR/scan.txt"
  summ="$RUN_DIR/bpf.summ.txt"

  {
    echo "== SUBSTANTIVE SUMMARY =="
    echo

    echo "## build + sparse (filtered)"

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
        sum = sum $0 "\n";
        if ($0 ~ /^errors_effective[[:space:]]*:/) { err=$NF + 0; }
        else if ($0 ~ /^errors[[:space:]]*:/) { err=$NF + 0; }
        else if ($0 ~ /^warnings[[:space:]]*:/) { warn=$NF + 0; }
        else if ($0 ~ /^sparse_effective[[:space:]]*:/) { sp=$NF + 0; }
        else if ($0 ~ /^sparse[[:space:]]*:/) { sp=$NF + 0; }
        if ($0 ~ /^$/) { in_sum=0; flush_summary(); }
        next
      }

      /^==== errors \(first /           { flush_list(sec, list); sec="errors"; list=""; next }
      /^==== warnings \(first /         { flush_list(sec, list); sec=""; list=""; next }
      /^==== sparse diagnostics \(first /{ flush_list(sec, list); sec=""; list=""; next }
      /^==== sparse diagnostics \(top messages\) ====$/ { flush_list(sec, list); sec=""; list=""; next }

      (sec!="") && ($0 ~ /^[0-9]+:/) { list = list normalize_line($0) "\n"; next }

      END{
        flush_list(sec, list);
        flush_summary();
      }
    ' "$scan" 2>/dev/null || true

    if [ -f "$BASE_DIR/scan.warnings.txt" ] && [ -f "$WARN_LIST" ]; then
      diff -u "$BASE_DIR/scan.warnings.txt" "$WARN_LIST" >"$RUN_DIR/diff.warnings.vs-baseline.txt" || true
      if [ -s "$RUN_DIR/diff.warnings.vs-baseline.txt" ]; then
        echo
        echo "## warnings delta vs baseline"
        sed -n '1,200p' "$RUN_DIR/diff.warnings.vs-baseline.txt" || true
      fi
    fi

    if [ -f "$BASE_DIR/scan.sparse.txt" ] && [ -f "$SPARSE_LIST" ]; then
      diff -u "$BASE_DIR/scan.sparse.txt" "$SPARSE_LIST" >"$RUN_DIR/diff.sparse.vs-baseline.txt" || true
      if [ -s "$RUN_DIR/diff.sparse.vs-baseline.txt" ]; then
        echo
        echo "## sparse delta vs baseline"
        sed -n '1,200p' "$RUN_DIR/diff.sparse.vs-baseline.txt" || true
      fi
    fi

    echo
    echo "## selftests (bpf)"
    cat "$summ" 2>/dev/null || true
  } >"$out"
}
bundle() {
  out="$1"
  {
    echo "## meta"
    cat "$RUN_DIR/meta.txt" || true
    echo
    echo "## scan"
    cat "$RUN_DIR/scan.txt" || true
    echo
    echo "## bpf summary"
    cat "$RUN_DIR/bpf.summ.txt" || true
  } >"$out"
}

THIS_TXT="$RUN_DIR/result.txt"
bundle "$THIS_TXT"

THIS_ESS="$RUN_DIR/essentials.txt"
essentials "$THIS_ESS"

PREV_ESS="$PREV_DIR/essentials.txt"
BASE_ESS="$BASE_DIR/essentials.txt"
DIFF_PREV_ESS="$RUN_DIR/diff.substantive.vs-prev.txt"
DIFF_BASE_ESS="$RUN_DIR/diff.substantive.vs-baseline.txt"

if [ -f "$PREV_ESS" ]; then
  diff -u "$PREV_ESS" "$THIS_ESS" >"$DIFF_PREV_ESS" || true; [ -s "$DIFF_PREV_ESS" ] || echo "(no substantive diff vs prev)" >"$DIFF_PREV_ESS"
else
  echo "(no previous substantive summary)" >"$DIFF_PREV_ESS"
fi

if [ -f "$BASE_ESS" ]; then
  diff -u "$BASE_ESS" "$THIS_ESS" >"$DIFF_BASE_ESS" || true; [ -s "$DIFF_BASE_ESS" ] || echo "(no substantive diff vs baseline)" >"$DIFF_BASE_ESS"
else
  echo "(no baseline yet)" >"$DIFF_BASE_ESS"
fi

PREV_TXT="$PREV_DIR/result.txt"
BASE_TXT="$BASE_DIR/result.txt"
DIFF_PREV="$RUN_DIR/diff.vs-prev.txt"
DIFF_BASE="$RUN_DIR/diff.vs-baseline.txt"

if [ -f "$PREV_TXT" ]; then
  diff -u "$PREV_TXT" "$THIS_TXT" >"$DIFF_PREV" || true
else
  echo "(no previous result)" >"$DIFF_PREV"
fi

if [ -f "$BASE_TXT" ]; then
  diff -u "$BASE_TXT" "$THIS_TXT" >"$DIFF_BASE" || true
else
  echo "(no pinned baseline yet)" >"$DIFF_BASE"
fi

cp -f "$THIS_TXT" "$PREV_TXT"
cp -f "$THIS_ESS" "$PREV_ESS"
cp -f "$WARN_LIST" "$PREV_DIR/scan.warnings.txt" 2>/dev/null || true
cp -f "$SPARSE_LIST" "$PREV_DIR/scan.sparse.txt" 2>/dev/null || true
if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_TXT" ]; then
  cp -f "$THIS_TXT" "$BASE_TXT"
  cp -f "$THIS_ESS" "$BASE_ESS"
  cp -f "$WARN_LIST" "$BASE_DIR/scan.warnings.txt" 2>/dev/null || true
  cp -f "$SPARSE_LIST" "$BASE_DIR/scan.sparse.txt" 2>/dev/null || true
fi

SUBJ="[auto-bpf][$KEY] run done: ref_updated=$ref_updated force=$FORCE HEAD=$head_after"
MAIL="$RUN_DIR/mail.result.mbox"
{
  echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
  echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
  echo "To: $TO_EMAIL"
  echo "Subject: $SUBJ"
  echo
  echo "== DIFF (substantive) vs PREV =="
  sed -n '1,260p' "$DIFF_PREV_ESS" || true
  echo
  echo "== DIFF (substantive) vs BASELINE =="
  sed -n '1,260p' "$DIFF_BASE_ESS" || true
  echo
  echo "== CURRENT (substantive summary) =="
  cat "$THIS_ESS" || true
  echo
  echo "== FULL RESULT (meta + scan + test) =="
  cat "$THIS_TXT" || true
  echo
  echo "Artifacts:"
  echo "  state dir: $STATE_DIR"
  echo "  run dir  : $RUN_DIR"
  echo "  O dir    : $O"
} >"$MAIL"

run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""

echo "[auto] done. run_dir=$RUN_DIR" >&2
