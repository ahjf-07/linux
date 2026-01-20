#!/bin/sh
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: auto-net-ci.sh [-l] [-s] [-S "subtrees"] [-o outdir] [-t target_ref]
                      [-e to_email] [--reset-baseline] [--force]
                      [--no-test] [--no-build]

必须在 Linux 源码根目录发起调用（git rev-parse --show-toplevel == $PWD）。
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

LLVM=0
SPARSE=0
SPARSE_SUBTREES=""
O=""
TARGET_REF="upstream/master"
TO_EMAIL="${AUTO_NET_EMAIL:-}"
RESET_BASELINE=0
FORCE=0
NO_TEST=0
NO_BUILD=0

# pre-parse long options so getopts won't choke on "--xxx"
# (we only accept our known long options here)
while [ $# -gt 0 ]; do
  case "$1" in
    --reset-baseline) RESET_BASELINE=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-test) NO_TEST=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --) shift; break ;;
    --*) echo "unknown arg: $1" >&2; usage ;;
    *) break ;;
  esac
done

while getopts "lsS:o:t:e:h" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    s) SPARSE=1 ;;
    S) SPARSE_SUBTREES="$OPTARG" ;;
    o) O="$OPTARG" ;;
    t) TARGET_REF="$OPTARG" ;;
    e) TO_EMAIL="$OPTARG" ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))
# auto-pick recipient: -e > AUTO_NET_EMAIL; if still empty, error
[ -n "$TO_EMAIL" ] || { echo "ERROR: missing recipient; use -e or set AUTO_NET_EMAIL" >&2; exit 2; }

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

STATE_DIR="$O/.auto-net"
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

run() { echo "+ $*" >&2; sh -c "$*"; }

# fetch policy:
# - default: fetch upstream only (avoid pulling every remote)
# - if -t is remote/branch: fetch that remote only
# - if -t is not remote/branch: still fetch upstream
if echo "$TARGET_REF" | grep -q '/'; then
  FETCH_REMOTE="${TARGET_REF%%/*}"
else
  FETCH_REMOTE="upstream"
fi

if git remote get-url "$FETCH_REMOTE" >/dev/null 2>&1; then
  run "git fetch --prune \"$FETCH_REMOTE\""
else
  echo "WARN: remote '$FETCH_REMOTE' not found; falling back to 'git fetch --prune'." >&2
  run "git fetch --prune"
fi

old_ref="$(cat "$STATE_DIR/last_ref.$KEY" 2>/dev/null || true)"
new_ref="$(git rev-parse "$TARGET_REF" 2>/dev/null || true)"
head_ref="$(git rev-parse HEAD)"

[ -n "$new_ref" ] || { echo "ERROR: cannot resolve TARGET_REF=$TARGET_REF" >&2; exit 2; }

updated=0
if [ "$FORCE" -eq 1 ]; then
  updated=1
elif [ -z "$old_ref" ]; then
  updated=1
elif [ "$new_ref" != "$old_ref" ]; then
  updated=1
fi

if [ "$updated" -eq 0 ]; then
  echo "[auto] no update: $TARGET_REF still $new_ref; exit." >&2
  exit 0
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
  echo "HEAD=$head_ref"
  echo
  git log -1 --oneline "$new_ref" || true
} >"$RUN_DIR/meta.txt"

echo "$new_ref" >"$STATE_DIR/last_ref.$KEY"

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
  bargs="$bargs -r \"$LINUX_ROOT\" -o \"$O\""
  run "\"$TOOL_DIR/build-net.sh\" $bargs |& tee \"$RUN_DIR/build.all.log\""
else
  echo "[auto] --no-build: skip build" >"$RUN_DIR/build.all.log"
fi

run "\"$TOOL_DIR/scan-nb.sh\" -lw -s -r \"$LINUX_ROOT\" -o \"$O\" >\"$RUN_DIR/scan.txt\" 2>&1 || true"

TEST_LOG_SRC="$LINUX_ROOT/.kselftest-out/net.selftests.log"
TEST_LOG_DST="$RUN_DIR/net.selftests.log"
SUMM_LOG="$RUN_DIR/net.summ.txt"

if [ "$NO_TEST" -eq 0 ]; then
  targs=""
  [ "$LLVM" -eq 1 ] && targs="$targs -l"
  targs="$targs -r \"$LINUX_ROOT\" -o \"$O\" -ff"
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

bundle() {
  out="$1"
  {
    echo "## meta"
    cat "$RUN_DIR/meta.txt" || true
    echo
    echo "## scan"
    cat "$RUN_DIR/scan.txt" || true
    echo
    echo "## net summary"
    cat "$RUN_DIR/net.summ.txt" || true
  } >"$out"
}

THIS_TXT="$RUN_DIR/result.txt"
bundle "$THIS_TXT"

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
if [ "$RESET_BASELINE" -eq 1 ] || [ ! -f "$BASE_TXT" ]; then
  cp -f "$THIS_TXT" "$BASE_TXT"
fi

SUBJ="[auto-net][$KEY] $TARGET_REF updated: ${old_ref:-none} -> $new_ref"
MAIL="$RUN_DIR/mail.mbox"

{
  echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
  echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
  echo "To: $TO_EMAIL"
  echo "Subject: $SUBJ"
  echo
  echo "== META =="
  cat "$RUN_DIR/meta.txt" || true
  echo
  echo "== RESULT (scan + test summary) =="
  cat "$THIS_TXT" || true
  echo
  echo "== DIFF vs PREV =="
  sed -n '1,260p' "$DIFF_PREV" || true
  echo
  echo "== DIFF vs BASELINE =="
  sed -n '1,260p' "$DIFF_BASE" || true
  echo
  echo "Artifacts:"
  echo "  state dir: $STATE_DIR"
  echo "  run dir  : $RUN_DIR"
  echo "  O dir    : $O"
} >"$MAIL"

run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""

echo "[auto] done. run_dir=$RUN_DIR" >&2
