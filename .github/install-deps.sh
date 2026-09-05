#!/usr/bin/env bash
# .github/install-deps.sh — materialise the plugin dependencies the suites
# resolve, in the two shapes they resolve them from.
#
# Extracted from the workflow because two jobs need it (`lua` pins auto-core,
# `drift` rides its default branch) and the ONLY thing that should differ
# between them is a ref. Inlining it twice is how the two copies drift apart —
# which is the exact defect this workflow shipped once already, when a
# hand-copied step carried an r0 fix and none of its corrections.
#
# Refs come from the environment. An EMPTY ref means "whatever the default
# branch is now" — that is the drift job's whole purpose, so it is a supported
# value and not a mistake:
#   AUTO_CORE_REF  WORKTREE_REF  PLENARY_REF
set -euo pipefail

lazy="$HOME/.local/share/nvim/lazy"
mkdir -p "$lazy"

# <plugins_root> == dirname(dirname($GITHUB_WORKSPACE)); the checkout lives at
# /home/runner/work/<repo>/<repo>. The suites look for siblings there AND in
# the lazy dir, so both shapes have to exist.
siblings="$(dirname "$(dirname "$GITHUB_WORKSPACE")")"

# $3 empty => stay on the default branch the clone landed on.
clone_at() {
  local url="$1" dest="$2" ref="$3"
  git clone --filter=blob:none "$url" "$dest"
  if [ -n "$ref" ]; then
    git -C "$dest" checkout "$ref"
  fi
  printf '  %s -> %s\n' "$dest" "$(git -C "$dest" log --oneline -1)"
}

echo "dependencies:"
clone_at https://github.com/yongjohnlee80/auto-core.nvim \
         "$siblings/auto-core.nvim/main" "${AUTO_CORE_REF:-}"

# review_commands_spec requires worktree.store / worktree.review and resolves
# them through the same sibling pick() as auto-core. Found by CI: the first
# dependency survey read smoke.lua per repo and generalised from it, so a dep
# only the OTHER spec files use was invisible. Enumerated properly now — a grep
# for every LAZY-relative and sibling path across the WHOLE test tree returns
# exactly auto-core, worktree and plenary.
clone_at https://github.com/yongjohnlee80/worktree.nvim \
         "$siblings/worktree.nvim/main" "${WORKTREE_REF:-}"

clone_at https://github.com/nvim-lua/plenary.nvim \
         "$lazy/plenary.nvim" "${PLENARY_REF:-}"
