#!/usr/bin/env bash
#
# test.sh - dependency-free tests for wt.sh. No bats, no frameworks.
#
# Fixtures a throwaway git repo (bare + several worktrees) in a tmpdir, sources
# wt.sh, and asserts the switcher behaves per the spec. Runs the whole suite
# under BOTH bash and zsh - that dual run is the real guard on the bash-3.2 /
# zsh portability promise.
#
#   ./test.sh          # drives bash then zsh
#   bash test.sh       # same (driver re-execs both)
#   zsh  test.sh       # same
#
# Written in the common bash/zsh subset: no arrays, no top-level `local`, quote
# everything, feed the picker with here-strings so its `cd` lands in our shell.

# --------------------------------------------------------------------------
# Driver: unless we're the inner run, execute this same file under each shell.
# --------------------------------------------------------------------------
if [ -z "${WT_TEST_INNER:-}" ]; then
  overall=0
  for sh in bash zsh; do
    if command -v "$sh" >/dev/null 2>&1; then
      printf '\n=== wt tests under %s ===\n' "$sh"
      WT_TEST_INNER=1 "$sh" "$0" || overall=1
    else
      printf '\nSKIP: %s not installed\n' "$sh"
    fi
  done
  exit "$overall"
fi

HERE=$(cd "$(dirname "$0")" && pwd)
WT_SH="$HERE/wt.sh"

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

eq() { # got want name
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want [$2] got [$1])"; fi
}
has() { # haystack needle name
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing [$2])" ;; esac
}
lacks() { # haystack needle name
  case "$1" in *"$2"*) bad "$3 (should not contain [$2])" ;; *) ok "$3" ;; esac
}

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

# Move to a worktree before exercising `wt`; a failure here is a test failure.
at() { cd "$1" || bad "cannot cd into $1"; }

# Given captured picker output and a worktree path, return the menu number
# printed beside that path. Lets the picker tests select by identity rather
# than by a hard-coded, order-dependent index.
rownum_for() { # menu path
  row=$(printf '%s\n' "$1" | grep -F "$2")
  printf '%s' "${row%%)*}" | tr -dc '0-9'
}

# Show the picker menu without choosing anything (empty reply => "invalid
# selection" on stderr, no cd), so we can inspect it in a subshell cleanly.
menu_from() { # startdir args...
  at "$1"; shift
  wt "$@" <<< "" 2>/dev/null
}

# shellcheck disable=SC2317  # invoked indirectly via the EXIT trap below
cleanup() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }
trap cleanup EXIT

# --------------------------------------------------------------------------
# Fixture: a bare clone with five non-bare worktrees + a lone single-worktree
# repo. Paths are captured straight from git (`rev-parse --show-toplevel`) so
# expectations equal exactly what `wt` will cd to - no symlink surprises.
# --------------------------------------------------------------------------
build_fixture() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wttest.XXXXXX")

  seed="$ROOT/seed"
  git init -q "$seed"
  (
    cd "$seed" || exit 1
    git config user.email t@example.com
    git config user.name  tester
    # --no-verify: a dev's *global* git-good-commit hook would otherwise fire
    # in this throwaway repo and infinite-loop on a /dev/tty that isn't here.
    git commit -q --no-verify --allow-empty -m init
    git branch feature-alpha
    git branch feature-beta
    git branch sidebranch
  )

  DEF=$(git -C "$seed" symbolic-ref --short HEAD)   # main or master, whichever

  BARE="$ROOT/repo.git"
  git clone -q --bare "$seed" "$BARE"
  (
    cd "$BARE" || exit 1
    git worktree add -q "$ROOT/wt-main"  "$DEF"
    git worktree add -q "$ROOT/wt-alpha" feature-alpha
    git worktree add -q "$ROOT/wt-beta"  feature-beta
    git worktree add -q "$ROOT/quxpath"  sidebranch
    git worktree add -q --detach "$ROOT/wt-detached"
  ) >/dev/null 2>&1

  P_MAIN=$(git -C "$ROOT/wt-main"  rev-parse --show-toplevel)
  P_ALPHA=$(git -C "$ROOT/wt-alpha" rev-parse --show-toplevel)
  P_BETA=$(git -C "$ROOT/wt-beta"  rev-parse --show-toplevel)
  P_QUX=$(git -C "$ROOT/quxpath"   rev-parse --show-toplevel)

  SOLO="$ROOT/solo"
  git init -q "$SOLO"
  (
    cd "$SOLO" || exit 1
    git config user.email t@example.com
    git config user.name  tester
    git commit -q --no-verify --allow-empty -m init
  )

  # shellcheck disable=SC1090
  . "$WT_SH"
}

# --------------------------------------------------------------------------
# Tests (one behaviour each; the run list at the bottom reads as a checklist)
# --------------------------------------------------------------------------

test_single_match_is_branch_first() {
  at "$P_MAIN"; wt alpha
  eq "$PWD" "$P_ALPHA" "single-match query auto-jumps, matching branch first ('alpha')"
}

test_matching_is_case_insensitive() {
  at "$P_MAIN"; wt ALPHA
  eq "$PWD" "$P_ALPHA" "matching is case-insensitive ('ALPHA')"
}

test_falls_back_to_path_match() {
  at "$P_MAIN"; wt quxpath
  eq "$PWD" "$P_QUX" "falls back to a path match when no branch matches ('quxpath')"
}

test_multi_match_shows_picker() {
  menu=$(menu_from "$P_MAIN" feature)
  rows=$(printf '%s\n' "$menu" | grep -c ')')
  eq "$rows" "2" "multiple matches show a picker of exactly the 2 matches ('feature')"

  at "$P_MAIN"; wt feature <<< "$(rownum_for "$menu" "$P_BETA")"
  eq "$PWD" "$P_BETA" "picking feature-beta's row from the filtered picker jumps there"
}

test_no_arg_picker_lists_everything() {
  nb=$(git -C "$BARE" worktree list | grep -vc '(bare)')
  menu=$(menu_from "$P_ALPHA")
  rows=$(printf '%s\n' "$menu" | grep -c ')')
  eq    "$rows" "$nb"        "no-arg picker lists all $nb non-bare worktrees"
  has   "$menu" "(detached)" "no-arg picker shows the detached worktree"
  lacks "$menu" "$BARE"      "no-arg picker skips the bare repo"

  at "$P_ALPHA"; wt <<< "$(rownum_for "$menu" "$P_BETA")"
  eq "$PWD" "$P_BETA" "picking feature-beta's row from the no-arg picker jumps there"
}

test_picker_columns_align() {
  # Labels differ in width (sidebranch, feature-alpha, (detached), main), so
  # this only passes if the label column is padded and every path lines up.
  menu=$(menu_from "$P_ALPHA")
  widths=$(printf '%s\n' "$menu" | grep '/' | while IFS= read -r line; do
    prefix="${line%%/*}"   # everything before the path's leading '/'
    printf '%s\n' "${#prefix}"
  done | sort -u | grep -c .)
  eq "$widths" "1" "no-arg picker aligns every path into one column"
}

test_one_worktree_is_a_noop() {
  at "$SOLO"; before="$PWD"
  wt > "$ROOT/msg" 2>&1
  msg=$(cat "$ROOT/msg")
  eq  "$PWD" "$before"           "one worktree: does not move"
  has "$msg" "only one worktree" "one worktree: prints the no-op message"
}

test_dash_returns_to_previous() {
  at "$P_ALPHA"; wt feature-beta
  eq "$PWD" "$P_BETA" "jump to feature-beta (arming the toggle)"
  wt -
  eq "$PWD" "$P_ALPHA" "'wt -' returns to the previous worktree"
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
build_fixture

test_single_match_is_branch_first
test_matching_is_case_insensitive
test_falls_back_to_path_match
test_multi_match_shows_picker
test_no_arg_picker_lists_everything
test_picker_columns_align
test_one_worktree_is_a_noop
test_dash_returns_to_previous

printf '\n%s under %s: %d passed, %d failed\n' \
  "$(basename "$0")" "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash}" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
