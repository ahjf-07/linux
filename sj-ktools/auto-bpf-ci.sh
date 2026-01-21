#!/bin/sh
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: auto-bpf-ci.sh [-l] [-s] [-S "subtrees"] [-o outdir] [-t remote/branch] [-e to_email]
                      [-c] [-m] [-N] [-F]
                      [--reset-baseline] [--force] [--no-test] [--no-build]

Defaults:
  track  : upstream/master
  switch : master (fast-forward only)

Options:
  -l  LLVM=1 (clang). default gcc
  -s  enable sparse (passed to build-bpf.sh)
  -S  sparse subtrees list (passed to build-bpf.sh)
  -o  outdir (default: ../out/full-{clang|gcc})
  -t  tracked ref (default: upstream/master)
  -e  recipient (or env AUTO_EMAIL)

  -c  clean rebuild: remove $O (out dir) before build
  -m  mrproper-ish: remove $O and also remove $O/.config (forces re-config)
  -N  no-merge: skip git switch/ff-only merge, build current HEAD (dirty OK)
  -F  force-run: run even if no update after fetch (same as --force)

Long:
  --force          same as -F
  --no-test        skip vng tests
  --no-build       skip build
  --reset-baseline overwrite pinned baseline with this run
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
NO_MERGE=0
TEST_FAST=1
TEST_FFAST=0
DRY_RUN=0

_keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reset-baseline) RESET_BASELINE=1 ;;
    --force) FORCE=1 ;;
    --no-test) NO_TEST=1 ;;
    --no-build) NO_BUILD=1 ;;
    --full) TEST_FAST=0; TEST_FFAST=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --) shift; break ;;
    --*) echo "unknown arg: $1" >&2; usage ;;
    *) _keep="$_keep $1" ;;
  esac
  shift
done
set -- $_keep "$@"

while getopts "lsS:o:t:e:cmNFfh" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    s) SPARSE=1 ;;
    S) SPARSE_SUBTREES="$OPTARG" ;;
    o) O="$OPTARG" ;;
    t) TARGET_REF="$OPTARG" ;;
    e) TO_EMAIL="$OPTARG" ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    N) NO_MERGE=1 ;;
    F) FORCE=1 ;;
    f) TEST_FAST=1 ;;
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

run() { echo "+ $*" >&2; bash -lc "$*"; }

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
    targs="$targs -ff"
  elif [ "${TEST_FAST:-0}" -eq 1 ]; then
    targs="$targs -f"
  fi
  echo "[dry-run] run-bpf args: $targs" >&2
  exit 0
fi

if git remote get-url "$FETCH_REMOTE" >/dev/null 2>&1; then
  run "git fetch --prune \"$FETCH_REMOTE\""
else
  echo "WARN: remote '$FETCH_REMOTE' not found; falling back to 'git fetch --prune'." >&2
  run "git fetch --prune"
fi

old_ref="$(cat "$STATE_DIR/last_ref.$KEY" 2>/dev/null || true)"
new_ref="$(git rev-parse "$TARGET_REF" 2>/dev/null || true)"
head_before="$(git rev-parse HEAD)"

[ -n "$new_ref" ] || { echo "ERROR: cannot resolve TARGET_REF=$TARGET_REF" >&2; exit 2; }

ref_updated=0
if [ -z "$old_ref" ] || [ "$new_ref" != "$old_ref" ]; then
  ref_updated=1
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
  echo "NO_MERGE=$NO_MERGE"
  echo "CLEAN=$CLEAN"
  echo "MRPROPER=$MRPROPER"
  echo "NO_BUILD=$NO_BUILD"
  echo "NO_TEST=$NO_TEST"
  echo
  git log -1 --oneline "$new_ref" || true
} >"$RUN_DIR/meta.txt"

if [ "$ref_updated" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
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

if [ "$NO_BUILD" -eq 0 ]; then
  if [ ! -f "$O/.config" ]; then
    cargs=""
    [ "$LLVM" -eq 1 ] && cargs="$cargs -l"
    run "\"$TOOL_DIR/config-bpf.sh\" $cargs -r \"$LINUX_ROOT\" -o \"$O\" |& tee \"$RUN_DIR/config.log\""
  fi

  bargs=""
  [ "$LLVM" -eq 1 ] && bargs="$bargs -l"
  [ "$SPARSE" -eq 1 ] && bargs="$bargs -s"
  [ -n "$SPARSE_SUBTREES" ] && bargs="$bargs -S \"$SPARSE_SUBTREES\""
  bargs="$bargs -r \"$LINUX_ROOT\" -o \"$O\""
  run "\"$TOOL_DIR/build-bpf.sh\" $bargs |& tee \"$RUN_DIR/build.all.log\""
else
  echo "[auto] --no-build: skip build" >"$RUN_DIR/build.all.log"
fi

run "\"$TOOL_DIR/scan-nb.sh\" -e -w -s -n 120 -r \"$LINUX_ROOT\" -o \"$O\" >\"$RUN_DIR/scan.txt\" 2>&1 || true"

TEST_LOG_SRC="$LINUX_ROOT/.kselftest-out/bpf.selftests.log"
TEST_LOG_DST="$RUN_DIR/bpf.selftests.log"
SUMM_LOG="$RUN_DIR/bpf.summ.txt"

if [ "$NO_TEST" -eq 0 ]; then
  targs=""
  [ "$LLVM" -eq 1 ] && targs="$targs -l"
  targs="$targs -r \"$LINUX_ROOT\" -o \"$O\""
  if [ "${TEST_FFAST:-0}" -eq 1 ]; then
    targs="$targs -ff"
  elif [ "${TEST_FAST:-0}" -eq 1 ]; then
    targs="$targs -f"
  fi
  run "\"$TOOL_DIR/run-bpf.sh\" $targs |& tee \"$RUN_DIR/run-bpf.host.log\""

  if [ -f "$TEST_LOG_SRC" ]; then
    cp -f "$TEST_LOG_SRC" "$TEST_LOG_DST"
    run "\"$TOOL_DIR/summ-bpf.sh\" \"$TEST_LOG_DST\" >\"$SUMM_LOG\""
  else
    echo "ERROR: missing $TEST_LOG_SRC" >"$SUMM_LOG"
  fi
else
  echo "[auto] --no-test: skip tests" >"$SUMM_LOG"
fi

SUBJ="[auto-bpf][$KEY] $TARGET_REF -> $new_ref"
MAIL="$RUN_DIR/mail.result.mbox"
{
  echo "From $(git rev-parse --short "$new_ref" 2>/dev/null || echo auto) Mon Sep 17 00:00:00 2001"
  echo "From: $(git config --get sendemail.from 2>/dev/null || echo "$USER@$(hostname)")"
  echo "To: $TO_EMAIL"
  echo "Subject: $SUBJ"
  echo
  echo "== CURRENT (substantive summary) =="
  echo
  sed -n '1,220p' "$RUN_DIR/scan.txt" 2>/dev/null || true
  echo
  echo "== selftests (bpf) =="
  sed -n '1,220p' "$SUMM_LOG" 2>/dev/null || true
  echo
  echo "Artifacts:"
  echo "  run dir  : $RUN_DIR"
  echo "  out dir  : $O"
  echo "  state dir: $STATE_DIR"
} >"$MAIL"

run "git send-email --to \"$TO_EMAIL\" --confirm=never --no-chain-reply-to --suppress-cc=all \"$MAIL\""

echo "[auto] done. run_dir=$RUN_DIR" >&2

