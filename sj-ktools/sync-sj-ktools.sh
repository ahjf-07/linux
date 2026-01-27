#!/usr/bin/env bash
set -euo pipefail

repo_root="$(pwd)"

if ! git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: must run from a git repository root" >&2
  exit 1
fi

if ! git -C "$repo_root" sw sj-ktools 2>/dev/null; then
  git -C "$repo_root" switch sj-ktools
fi
git -C "$repo_root" fetch origin -pt
git -C "$repo_root" status
git -C "$repo_root" pull origin --ff-only

cp "$repo_root"/sj-ktools/*.sh "$repo_root"/../sj-ktools/
