#!/usr/bin/env bash
#
# test.sh - dependency-free tests for wt.sh. No bats, no frameworks.
#
# Fixtures a throwaway git repo in a tmpdir, sources wt.sh, and asserts. Runs
# under BOTH bash and zsh — that dual run is the real guard on the bash-3.2 /
# zsh portability promise.
#
#   ./test.sh    # drives bash then zsh (bash/zsh test.sh do the same)
#
# Written in the common bash/zsh subset: no arrays, no top-level `local`, quote
# everything, feed the picker with here-strings so its `cd` lands in our shell.

# --------------------------------------------------------------------------
# Driver: unless we're the inner run, re-exec this file under each shell.
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

# fd 3 is our report channel: the run block sends stdout/stderr to /dev/null to
# mute the function-under-test's chatter, while ok/bad still reach the terminal.
exec 3>&1

ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1" >&3; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1" >&3; }

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

# Emit each argument as a NUL-terminated field — the wire form of a record. So
# `nul a b c` is one three-field record; `nul a b c d e f` is two.
nul() { printf '%s\0' "$@"; }

# Run a records filter, showing NULs as `|` so a record stream compares as one
# plain string.
piped() { "$@" | tr '\0' '|'; }

# The menu number printed beside a path, so picker tests select by identity, not
# a hard-coded index.
rownum_for() { # menu path
  row=$(printf '%s\n' "$1" | grep -F "$2")
  printf '%s' "${row%%)*}" | tr -dc '0-9'
}

# Show the picker menu without choosing (empty reply => no cd), to inspect it.
menu_from() { # startdir args...
  at "$1"; shift
  wt "$@" <<< "" 2>/dev/null
}

# Source wt.sh in a fresh shell (no leakage from the suite), set WT_CMD as asked
# (empty => unset, exercising the ${WT_CMD:-wt} default), jump, echo where it
# landed. Runs under whichever shell the suite is driving.
jump_in_fresh_shell() { # wt_cmd_value(empty to unset)  command_name
  shbin=bash; [ -n "${ZSH_VERSION:-}" ] && shbin=zsh
  # shellcheck disable=SC2016  # the $vars are for the inner shell, not this one
  WT_CMD_ARG="$1" WT_SH="$WT_SH" DEST="$P_ALPHA" "$shbin" -c '
    if [ -n "$WT_CMD_ARG" ]; then export WT_CMD="$WT_CMD_ARG"; else unset WT_CMD; fi
    cd "$DEST" || exit 1
    . "$WT_SH"
    "$1" feature-beta >/dev/null 2>&1
    printf %s "$PWD"
  ' _ "$2"
}

# shellcheck disable=SC2317,SC2329  # invoked indirectly via the EXIT trap below
cleanup() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }
trap cleanup EXIT

# --------------------------------------------------------------------------
# Fixture: a bare clone with five non-bare worktrees + a lone single-worktree
# repo. Paths come from git (`rev-parse --show-toplevel`), so expectations equal
# exactly what `wt` cd's to — no symlink surprises.
# --------------------------------------------------------------------------
build_fixture() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wttest.XXXXXX")

  seed="$ROOT/seed"
  git init -q "$seed"
  (
    cd "$seed" || exit 1
    git config user.email t@example.com
    git config user.name  tester
    # --no-verify: a dev's global commit hook could fire here and hang on a
    # /dev/tty that isn't present.
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
# Unit tests for the pure filters — records in, records out, no git, no fixture.
# --------------------------------------------------------------------------

test_label_uses_branch_when_present() {
  got=$(nul branch main /p/main | piped _wt_label)
  eq "$got" "main|/p/main|" "_wt_label: a branch record is labelled with its branch"
}

test_label_names_detached() {
  got=$(nul detached "" /p/det | piped _wt_label)
  eq "$got" "(detached)|/p/det|" "_wt_label: a detached record is labelled (detached)"
}

test_label_names_unknown() {
  got=$(nul branch "" /p/unk | piped _wt_label)
  eq "$got" "(unknown)|/p/unk|" "_wt_label: a branchless non-detached record is (unknown)"
}

test_label_drops_bare() {
  got=$(nul bare "" /p/repo.git | piped _wt_label)
  eq "$got" "" "_wt_label: the bare repo is dropped, emitting nothing"
}

test_match_labels_before_paths() {
  # 'main' hits a label, so the path-only record must not come through.
  got=$(nul main /p/x feature /home/main-app | piped _wt_match main)
  eq "$got" "main|/p/x|" "_wt_match: a label hit wins; paths are not consulted"
}

test_match_falls_back_to_path() {
  # 'app' hits no label, so the path pass runs and both path hits come through.
  got=$(nul main /home/app dev /home/apple | piped _wt_match app)
  eq "$got" "main|/home/app|dev|/home/apple|" "_wt_match: no label hit falls back to path matches"
}

test_match_is_case_insensitive() {
  got=$(nul Feature-Beta /p/b | piped _wt_match BETA)
  eq "$got" "Feature-Beta|/p/b|" "_wt_match: matching is case-insensitive"
}

test_match_reports_nothing_on_no_match() {
  got=$(nul main /p/m dev /p/d | piped _wt_match zzz)
  eq "$got" "" "_wt_match: no label or path hit emits nothing"
}

test_match_empty_query_passes_all() {
  got=$(nul main /p/m dev /p/d | piped _wt_match "")
  eq "$got" "main|/p/m|dev|/p/d|" "_wt_match: an empty query passes every record through"
}

test_render_aligns_paths() {
  # Count distinct "text before the first /" widths; alignment means exactly one.
  menu=$(nul short /p/a longbranchname /p/b | _wt_render "" 0)
  widths=$(printf '%s\n' "$menu" | grep '/' | while IFS= read -r line; do
    prefix="${line%%/*}"
    printf '%s\n' "${#prefix}"
  done | sort -u | grep -c .)
  eq "$widths" "1" "_wt_render: labels of differing widths still align every path"
}

test_render_marks_the_current_row() {
  # The marker is a literal `*` (a glob metacharacter), so match it with
  # `grep -F`, not the case-glob `has`/`lacks` where `*` matches anything.
  menu=$(nul main /p/main dev /p/dev | _wt_render /p/dev 0)
  if printf '%s\n' "$menu" | grep -F /p/dev | grep -qF ') *'; then
    ok "_wt_render: the current worktree's row is marked with *"
  else
    bad "_wt_render: the current worktree's row is marked with *"
  fi
  if printf '%s\n' "$menu" | grep -F /p/main | grep -qF ') *'; then
    bad "_wt_render: other rows carry no marker"
  else
    ok "_wt_render: other rows carry no marker"
  fi
}

test_render_colour_is_off_by_default() {
  menu=$(nul main /p/main | _wt_render /p/main 0)
  lacks "$menu" "[1;32m" "_wt_render: colour flag 0 emits no ANSI escapes"
}

test_render_colour_wraps_current_row() {
  menu=$(nul main /p/main | _wt_render /p/main 1)
  has "$menu" "[1;32m" "_wt_render: colour flag 1 wraps the current row in ANSI"
}

# --------------------------------------------------------------------------
# Tests (one behaviour each; the run list at the bottom reads as a checklist)
# --------------------------------------------------------------------------

test_single_match_is_branch_first() {
  at "$P_MAIN"; wt alpha
  eq "$PWD" "$P_ALPHA" "single-match query auto-jumps, matching branch first ('alpha')"
}

test_falls_back_to_path_match() {
  at "$P_MAIN"; wt quxpath
  eq "$PWD" "$P_QUX" "falls back to a path match when no branch matches ('quxpath')"
}

test_multi_match_shows_picker() {
  menu=$(menu_from "$P_MAIN" feature)
  rows=$(printf '%s\n' "$menu" | grep -cE '^ *[0-9]+\)')
  eq "$rows" "2" "multiple matches show a picker of exactly the 2 matches ('feature')"

  at "$P_MAIN"; wt feature <<< "$(rownum_for "$menu" "$P_BETA")"
  eq "$PWD" "$P_BETA" "picking feature-beta's row from the filtered picker jumps there"
}

test_no_arg_picker_lists_everything() {
  nb=$(git -C "$BARE" worktree list | grep -vc '(bare)')
  menu=$(menu_from "$P_ALPHA")
  rows=$(printf '%s\n' "$menu" | grep -cE '^ *[0-9]+\)')
  eq    "$rows" "$nb"        "no-arg picker lists all $nb non-bare worktrees"
  has   "$menu" "(detached)" "no-arg picker shows the detached worktree"
  lacks "$menu" "$BARE"      "no-arg picker skips the bare repo"

  at "$P_ALPHA"; wt <<< "$(rownum_for "$menu" "$P_BETA")"
  eq "$PWD" "$P_BETA" "picking feature-beta's row from the no-arg picker jumps there"
}

test_picker_name_jumps() {
  # At the picker, a name matching exactly one worktree jumps there.
  at "$P_MAIN"; wt <<< "alpha"
  eq "$PWD" "$P_ALPHA" "picker: a name matching one worktree jumps there ('alpha')"
}

test_picker_name_refilters_then_number() {
  # A name matching several re-filters; a follow-up number picks. Two input
  # lines feed the two reads.
  menu=$(menu_from "$P_MAIN" feature)
  at "$P_MAIN"; wt <<< "$(printf 'feature\n%s\n' "$(rownum_for "$menu" "$P_BETA")")"
  eq "$PWD" "$P_BETA" "picker: a name matching several re-filters, then a number picks"
}

test_picker_out_of_range_number_matches_name() {
  # An out-of-range number is no row, so it falls through to name/path matching
  # rather than dead-ending — here reporting no match cleanly.
  at "$P_MAIN"; wt <<< "999" > "$ROOT/msg" 2>&1 || true
  msg=$(cat "$ROOT/msg")
  has "$msg" "no worktree matches: 999" "picker: an out-of-range number falls through to matching"
}

test_picker_empty_reply_cancels() {
  at "$P_MAIN"; before="$PWD"
  wt <<< "" > "$ROOT/msg" 2>&1 || true
  msg=$(cat "$ROOT/msg")
  eq  "$PWD" "$before"          "picker: empty reply does not move"
  has "$msg" "nothing selected" "picker: empty reply reports nothing selected"
}

# A query that matches nothing, but from inside a real repo, blames the query.
test_query_no_match_blames_query() {
  at "$P_MAIN"
  wt zzz-no-such > "$ROOT/msg" 2>&1 || true
  msg=$(cat "$ROOT/msg")
  has "$msg" "no worktree matches: zzz-no-such" "a non-matching query in a repo reports no match"
}

# The same query outside any repo blames the missing repo, not the query — an
# empty candidate set can't tell the two apart, so the repo is probed directly.
test_query_outside_repo_reports_no_repo() {
  mkdir -p "$ROOT/norepo"
  at "$ROOT/norepo"
  wt zzz-no-such > "$ROOT/msg" 2>&1 || true
  msg=$(cat "$ROOT/msg")
  has "$msg" "not in a git repository" "a query outside any repo reports 'not in a git repository'"
}

# One worktree lands you on its root: a no-op from the root, a cd-up from a
# subdir. Either way it says "no other worktrees", not the generic "already there".
test_one_worktree_from_root_says_only_worktree() {
  solo_root=$(git -C "$SOLO" rev-parse --show-toplevel)
  at "$solo_root"; before="$PWD"
  wt > "$ROOT/msg" 2>&1
  msg=$(cat "$ROOT/msg")
  eq    "$PWD" "$before"        "one worktree from root: does not move"
  has   "$msg" "no other worktrees"  "one worktree from root: reports 'no other worktrees'"
  lacks "$msg" "already there"  "one worktree from root: not the generic 'already there'"
}

test_one_worktree_from_subdir_cds_to_root() {
  solo_root=$(git -C "$SOLO" rev-parse --show-toplevel)
  mkdir -p "$solo_root/sub/deep"
  at "$solo_root/sub/deep"
  wt > "$ROOT/msg" 2>&1
  msg=$(cat "$ROOT/msg")
  eq    "$PWD" "$solo_root"    "one worktree from subdir: cds to its root"
  has   "$msg" "no other worktrees" "one worktree from subdir: reports 'no other worktrees'"
  lacks "$msg" "already there" "one worktree from subdir: does not say 'already there'"
}

# Picking the current worktree from a subdir cds up to its root — "already
# there" applies only when standing on the root itself.
test_picks_current_worktree_from_subdir() {
  mkdir -p "$P_MAIN/sub/deep"
  at "$P_MAIN/sub/deep"
  wt "$P_MAIN" > "$ROOT/msg" 2>&1
  msg=$(cat "$ROOT/msg")
  eq    "$PWD" "$P_MAIN"      "picking the current worktree from a subdir cds to its root"
  lacks "$msg" "already there" "picking from a subdir does not say 'already there'"
}

# Standing on the worktree root and picking it is a genuine no-op.
test_picks_current_worktree_from_root_is_noop() {
  at "$P_MAIN"; before="$PWD"
  wt "$P_MAIN" > "$ROOT/msg" 2>&1
  msg=$(cat "$ROOT/msg")
  eq  "$PWD" "$before"       "picking the current worktree from its root does not move"
  has "$msg" "already there" "picking from the root reports 'already there'"
}

test_dash_returns_to_previous() {
  at "$P_ALPHA"; wt feature-beta
  eq "$PWD" "$P_BETA" "jump to feature-beta (arming the toggle)"
  wt -
  eq "$PWD" "$P_ALPHA" "'wt -' returns to the previous worktree"
}

# With the current worktree removed, $PWD is gone and git can't run. `wt` should
# climb back to a survivor (here via WT_LAST) instead of erroring, then jump.
test_recovers_from_removed_cwd() {
  git -C "$BARE" worktree add -q "$ROOT/wt-doomed" -b doomed >/dev/null 2>&1
  at "$P_ALPHA"; wt feature-beta         # arm WT_LAST=P_ALPHA (a survivor)
  at "$ROOT/wt-doomed"                    # now standing in the doomed worktree
  rm -rf "$ROOT/wt-doomed"               # removed out from under us
  git -C "$BARE" worktree prune

  wt quxpath >/dev/null 2>&1              # from the dead cwd: recover, then jump
  eq "$PWD" "$P_QUX" "recovers from a removed cwd and still resolves the jump"
}

test_rename_via_wt_cmd() {
  got=$(jump_in_fresh_shell gwt gwt)
  eq "$got" "$P_BETA" "WT_CMD exported before sourcing renames the command ('gwt' jumps)"
}

test_default_command_name_is_wt() {
  got=$(jump_in_fresh_shell "" wt)
  eq "$got" "$P_BETA" "with WT_CMD unset the command defaults to 'wt'"
}

# Completion draws its labels from _wt_label, so it names the detached worktree
# and drops the bare repo. _wt must run in this shell (not a subshell) so the
# COMPREPLY it sets is ours to read; an empty current word offers everything.
test_completion_labels_come_from_wt_label() {
  at "$P_MAIN"
  COMP_WORDS=(wt ""); COMP_CWORD=1
  _wt
  menu=$(printf '%s\n' "${COMPREPLY[@]}")
  has   "$menu" "feature-alpha" "completion: offers branch Labels"
  has   "$menu" "(detached)"    "completion: offers the (detached) Label via _wt_label"
  lacks "$menu" "repo.git"      "completion: drops the bare repo (never a switch target)"
  unset COMP_WORDS COMP_CWORD COMPREPLY
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
# Braces (not a subshell) so build_fixture's globals persist; stdout/stderr go
# to /dev/null while ok/bad report on fd 3.
{
  build_fixture

  # pure filters
  test_label_uses_branch_when_present
  test_label_names_detached
  test_label_names_unknown
  test_label_drops_bare
  test_match_labels_before_paths
  test_match_falls_back_to_path
  test_match_is_case_insensitive
  test_match_reports_nothing_on_no_match
  test_match_empty_query_passes_all
  test_render_aligns_paths
  test_render_marks_the_current_row
  test_render_colour_is_off_by_default
  test_render_colour_wraps_current_row

  test_single_match_is_branch_first
  test_falls_back_to_path_match
  test_multi_match_shows_picker
  test_no_arg_picker_lists_everything
  test_picker_name_jumps
  test_picker_name_refilters_then_number
  test_picker_out_of_range_number_matches_name
  test_picker_empty_reply_cancels
  test_query_no_match_blames_query
  test_query_outside_repo_reports_no_repo
  test_one_worktree_from_root_says_only_worktree
  test_one_worktree_from_subdir_cds_to_root
  test_picks_current_worktree_from_subdir
  test_picks_current_worktree_from_root_is_noop
  test_dash_returns_to_previous
  test_recovers_from_removed_cwd
  test_rename_via_wt_cmd
  test_default_command_name_is_wt
  test_completion_labels_come_from_wt_label
} >/dev/null 2>&1

printf '\n%s under %s: %d passed, %d failed\n' \
  "$(basename "$0")" "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash}" "$PASS" "$FAIL" >&3
[ "$FAIL" -eq 0 ] || exit 1
exit 0
