#!/usr/bin/env bash
#
# wt(1) - switch between git worktrees. One thing, well.
# Released under the MIT License.
#
# Version 0.1.0
#
# https://github.com/tommarshall/git-worktree-switch
#
# SOURCE this file from ~/.bashrc and ~/.zshrc (it is not executed):
#
#   source /path/to/wt.sh
#
# Usage:
#   wt            list worktrees, pick one by number (or type a name to match)
#   wt <query>    jump to the worktree matching <query> (branch, then path;
#                 case-insensitive substring). One match jumps; several filter.
#   wt -          jump back to the previous worktree (like `cd -`)

# --------------------------------------------------------------------------
# Globals (declared once, up top)
# --------------------------------------------------------------------------

# The command name, driving the function, its completion, and every message.
# Defaults to `wt`, but honours a WT_CMD exported before this file is sourced —
# so you can rename the command from your shell profile without editing here.
WT_CMD="${WT_CMD:-wt}"

# Remembers the worktree you last jumped from, so `wt -` can return. Lives in
# the interactive shell because this file is sourced, not run.
WT_LAST=""

#
# Change directory to a worktree, remembering where we came from.
# $1 = target path, $2 = path we're leaving (may be empty)
#
_wt_cd() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local target="$1" leaving="$2"

  if [ -n "$leaving" ] && [ "$leaving" != "$target" ]; then
    WT_LAST="$leaving"
  fi

  cd "$target" || return 1
  printf '%s\n' "$PWD"
}

#
# Recover when the current directory has vanished — typically this very
# worktree was removed out from under us. $PWD still holds the stale path but
# the directory is gone, so git can't run at all. Find a surviving worktree to
# stand on and cd there, so both git and the user are back on solid ground:
#   1. climb the stale $PWD to the nearest ancestor that still exists and lives
#      in a work tree (handles worktrees nested under the repo);
#   2. failing that, fall back to WT_LAST — where we last jumped from (handles
#      the classic bare-repo-with-sibling-worktrees layout).
# Returns 1 if neither yields a directory git can run in.
#
_wt_recover() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local p="$PWD"
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    p="${p%/*}"
    [ -z "$p" ] && break
    if [ -d "$p" ] && git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
      cd "$p" || return 1
      return 0
    fi
  done

  if [ -n "${WT_LAST:-}" ] && [ -d "$WT_LAST" ] && \
     git -C "$WT_LAST" rev-parse --git-dir >/dev/null 2>&1; then
    cd "$WT_LAST" || return 1
    return 0
  fi

  return 1
}

#
# The records pipeline
# --------------------------------------------------------------------------
# A *record* is one worktree as it moves down the pipe. `_wt_records` runs git
# once and prints raw records; `_wt_label` turns those into display records;
# `_wt_match` keeps the ones a query hits. All three are pure stdin→stdout
# filters — they touch no shell state, so they can be tested by feeding records
# in and asserting the records that come out, with no git and no fixture.
#
# Records are NUL-framed so a worktree path (which may contain a newline — the
# reason git offers `-z`) survives intact. Fixed arity, no record separator:
#   raw     record = head \0 branch \0 path \0   (`_wt_records` → `_wt_label`)
#   display record = label \0 path \0            (`_wt_label`  → `_wt_match`)
# `head` is one of `bare` / `detached` / `branch`, the only field that tells the
# three cases apart.
#
# Only the conductor's own glue (`_wt_fill`) and the picker (`_wt_pick`) still
# share state by dynamic scope: they read/write the arrays `wt_paths` /
# `wt_labels` and the scalars `tgt` / `requery`, declared `local` in `_wt_main`
# ONLY. Dynamic scope means a callee writes straight into the conductor's
# locals, so no globals leak into the interactive shell and nothing is
# serialised across a subshell (a `$(...)` capture would swallow the picker's
# prompt). This holds under the zsh `emulate -L` guard, which localises options,
# not variable scope.
#
# Print one raw record per worktree, bare repo included, straight from
# `git worktree list --porcelain -z`.
#
_wt_records() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  # Parse `list --porcelain -z` (double-NUL record boundaries) in pure shell
  # (no awk/sed) per the house style. Branch on which lines a record carries:
  # bare has neither HEAD nor branch; a detached HEAD emits `detached` and NO
  # branch line — never assume a branch.
  # NOTE: do NOT name a variable `path` here — in zsh `path` is the array form
  # of $PATH, so `local path=...` would blow away PATH inside the function and
  # git would vanish. Use `wtpath`.
  local token wtpath="" branch="" head="branch"
  while IFS= read -r -d '' token; do
    if [ -z "$token" ]; then
      # record boundary — emit the record we just read
      [ -n "$wtpath" ] && printf '%s\0%s\0%s\0' "$head" "$branch" "$wtpath"
      wtpath=""; branch=""; head="branch"
      continue
    fi
    case "$token" in
      "worktree "*) wtpath="${token#worktree }" ;;
      "branch "*)   branch="${token#branch }"; branch="${branch#refs/heads/}" ;;
      "detached")   head="detached" ;;
      "bare")       head="bare" ;;
      *) : ;;  # HEAD, locked, prunable — not needed for switching
    esac
  done < <(git worktree list --porcelain -z 2>/dev/null)
  # safety net if a git build omits the trailing empty record
  [ -n "$wtpath" ] && printf '%s\0%s\0%s\0' "$head" "$branch" "$wtpath"
}

#
# Read raw records, print display records: drop the bare repo, and give every
# survivor a label — its branch, else `(detached)`, else `(unknown)`.
#
_wt_label() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local head branch wtpath label
  while IFS= read -r -d '' head && IFS= read -r -d '' branch \
        && IFS= read -r -d '' wtpath; do
    [ "$head" = "bare" ] && continue
    if [ -n "$branch" ]; then
      label="$branch"
    elif [ "$head" = "detached" ]; then
      label="(detached)"
    else
      label="(unknown)"
    fi
    printf '%s\0%s\0' "$label" "$wtpath"
  done
}

#
# Read display records, print the ones matching $1: labels first, then paths
# only if no label matched (case-insensitive substring). An empty query matches
# every label, so it passes the whole set through unchanged. The fallback needs
# the full set before it can decide, so buffer into local arrays first — these
# are `_wt_match`'s OWN locals, not the conductor's.
#
_wt_match() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local query="$1" q_lc
  q_lc=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

  local labels=() paths=() label wtpath
  while IFS= read -r -d '' label && IFS= read -r -d '' wtpath; do
    labels+=("$label"); paths+=("$wtpath")
  done

  local count="${#labels[@]}" i=0 matched=0 lc
  while [ "$i" -lt "$count" ]; do
    lc=$(printf '%s' "${labels[$i]}" | tr '[:upper:]' '[:lower:]')
    case "$lc" in *"$q_lc"*)
      printf '%s\0%s\0' "${labels[$i]}" "${paths[$i]}"; matched=1 ;;
    esac
    i=$((i + 1))
  done
  [ "$matched" -eq 1 ] && return 0

  i=0
  while [ "$i" -lt "$count" ]; do
    lc=$(printf '%s' "${paths[$i]}" | tr '[:upper:]' '[:lower:]')
    case "$lc" in *"$q_lc"*)
      printf '%s\0%s\0' "${labels[$i]}" "${paths[$i]}" ;;
    esac
    i=$((i + 1))
  done
}

#
# Conductor glue: run the pipeline for query $1 ("" = every worktree) and load
# the resulting display records into `wt_paths` / `wt_labels` (the conductor's
# locals, reached by dynamic scope — see the pipeline note above).
#
_wt_fill() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local query="$1" label wtpath
  # shellcheck disable=SC2154  # wt_paths/wt_labels are the conductor's locals
  wt_paths=(); wt_labels=()
  while IFS= read -r -d '' label && IFS= read -r -d '' wtpath; do
    wt_labels+=("$label"); wt_paths+=("$wtpath")
  done < <(_wt_records | _wt_label | _wt_match "$query")
}

#
# Print the numbered candidate list (marker + colour) straight from the filled
# `wt_paths` / `wt_labels` (caller's locals), read a choice, and set `tgt`
# (caller's local) to the chosen row's index. $1 = current path (for the `*`
# marker). Returns 1 on an invalid reply, 2 on a re-query.
#
_wt_pick() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local here="$1"

  # --- colour: only on a tty, and only if git config doesn't forbid it ------
  local C_CUR="" C_RST=""
  if [ -t 1 ]; then
    local ui
    ui=$(git config --get color.ui 2>/dev/null)
    case "$ui" in
      never|false|off|no) : ;;
      *) C_CUR=$'\033[1;32m'; C_RST=$'\033[0m' ;;
    esac
  fi

  # shellcheck disable=SC2154  # wt_paths/wt_labels are the conductor's locals
  # widest branch label among the candidates, so every path lines up in a column
  local count="${#wt_paths[@]}" n=0 label_w=0 len
  while [ "$n" -lt "$count" ]; do
    len=${#wt_labels[$n]}
    [ "$len" -gt "$label_w" ] && label_w="$len"
    n=$((n + 1))
  done

  local marker reply
  n=0
  while [ "$n" -lt "$count" ]; do
    if [ -n "$here" ] && [ "${wt_paths[$n]}" = "$here" ]; then
      marker="*"
    else
      marker=" "
    fi
    if [ "$marker" = "*" ]; then
      printf '%s%3d) %s %-*s  %s%s\n' "$C_CUR" "$((n + 1))" "$marker" \
        "$label_w" "${wt_labels[$n]}" "${wt_paths[$n]}" "$C_RST"
    else
      printf '%3d) %s %-*s  %s\n' "$((n + 1))" "$marker" \
        "$label_w" "${wt_labels[$n]}" "${wt_paths[$n]}"
    fi
    n=$((n + 1))
  done

  printf 'pick › '
  IFS= read -r reply

  # An empty reply is a deliberate bail-out. A pure number in range picks that
  # row. ANYTHING else — a name, or a number that isn't a row — is handed back
  # to the conductor as a fresh query (requery) to re-match by name/path, so a
  # branch literally named `1234` still resolves.
  if [ -z "$reply" ]; then
    printf '%s: nothing selected\n' "$WT_CMD" >&2
    return 1
  fi
  case "$reply" in
    *[!0-9]*) : ;;  # not a pure number -> requery below
    *) if [ "$reply" -ge 1 ] && [ "$reply" -le "$count" ]; then
         tgt=$((reply - 1))
         return 0
       fi ;;
  esac
  requery="$reply"
  return 2
}

#
# The switcher itself. Wrapped as ${WT_CMD} at the bottom of the file.
# Thin conductor: guard, fill, route (`-` / no-arg / query), then jump.
#
_wt_main() {
  # --- portability guard (zsh only; local via emulate -L, does not leak) ---
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local query="${1:-}"

  # --- recover from a deleted cwd -------------------------------------------
  # If this worktree was removed while we were standing in it, $PWD no longer
  # exists and every git command below would fail with a misleading "not in a
  # git repository". Climb back to a surviving worktree first (see _wt_recover),
  # then carry on normally so the user lands in the picker instead of an error.
  if [ ! -d "$PWD" ]; then
    _wt_recover || {
      printf '%s: current directory no longer exists (worktree removed?)\n' \
        "$WT_CMD" >&2
      return 1
    }
    printf '%s: current worktree was removed; recovered to %s\n' \
      "$WT_CMD" "$PWD" >&2
  fi

  # --- where are we now (absolute worktree root) ----------------------------
  local here=""
  here=$(git rev-parse --show-toplevel 2>/dev/null)

  # --- `wt -` : jump back to the previous worktree --------------------------
  # Handled before we fill/count worktrees so it still works as an escape
  # hatch even when the current directory is gone or we're outside a repo.
  if [ "$query" = "-" ]; then
    if [ -z "${WT_LAST:-}" ]; then
      printf '%s: no previous worktree\n' "$WT_CMD" >&2
      return 1
    fi
    if [ ! -d "$WT_LAST" ]; then
      printf '%s: previous worktree is gone: %s\n' "$WT_CMD" "$WT_LAST" >&2
      return 1
    fi
    _wt_cd "$WT_LAST" "$here"
    return
  fi

  # --- decide the target, or the set of candidates to pick from -------------
  # shellcheck disable=SC2034  # wt_paths/wt_labels filled by _wt_fill (dynamic scope)
  local wt_paths=() wt_labels=() tgt=-1 requery="" rc=0

  _wt_fill "$query"
  local count="${#wt_paths[@]}"

  # Zero candidates: tell "not a repo" apart from "the query matched nothing".
  # `here` is set inside a worktree but empty when standing in a bare repo, so
  # fall back to a git-dir probe (true in a bare repo too) before blaming the
  # query. Only ever runs on the empty path, never in the common case.
  if [ "$count" -eq 0 ]; then
    if [ -n "$query" ] && { [ -n "$here" ] || \
         git rev-parse --git-dir >/dev/null 2>&1; }; then
      printf '%s: no worktree matches: %s\n' "$WT_CMD" "$query" >&2
    else
      printf '%s: not in a git repository (or no worktrees)\n' "$WT_CMD" >&2
    fi
    return 1
  fi

  if [ -z "$query" ]; then
    # no arg: candidates are every worktree
    if [ "$count" -le 1 ]; then
      printf '%s: only one worktree\n' "$WT_CMD"
      return 0
    fi
  else
    # exactly one match jumps; several fall through to the picker
    [ "$count" -eq 1 ] && tgt=0
  fi

  # --- picker: numbered list of candidates, read a choice -------------------
  # Loop so a typed name (or an out-of-range number) re-matches against ALL
  # worktrees, reusing the same pipeline the CLI does. A pick (rc 0) sets `tgt`
  # and ends the loop; a re-query (rc 2) refills the candidates; an empty reply
  # (rc 1) bails.
  while [ "$tgt" -lt 0 ]; do
    _wt_pick "$here"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      _wt_fill "$requery"
      case "${#wt_paths[@]}" in
        0) printf '%s: no worktree matches: %s\n' "$WT_CMD" "$requery" >&2
           return 1 ;;
        1) tgt=0 ;;
        *) : ;;  # several matches -> loop, picker reshows the filtered set
      esac
    elif [ "$rc" -ne 0 ]; then
      return 1
    fi
  done

  # --- go ---------------------------------------------------------------------
  # "already there" means standing on the worktree root itself, not merely
  # inside that worktree — compare against $PWD, not `here` (the root). Picking
  # the current worktree from a subdirectory should still cd up to its root.
  if [ "${wt_paths[$tgt]}" = "$PWD" ]; then
    printf '%s: already there\n' "$WT_CMD"
    return 0
  fi
  _wt_cd "${wt_paths[$tgt]}" "$here"
}

#
# Completion: one bash-style function, reused in zsh via bashcompinit.
# Completes branch names and worktree path basenames for the first argument.
#
_wt() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local cur candidates="" head branch wtpath
  cur="${COMP_WORDS[COMP_CWORD]}"

  # only complete the first word after the command
  if [ "$COMP_CWORD" -ne 1 ]; then
    COMPREPLY=()
    return 0
  fi

  # Same record source the switcher uses. Offer every branch name and every
  # worktree folder basename — bare repo included, as before.
  while IFS= read -r -d '' head && IFS= read -r -d '' branch \
        && IFS= read -r -d '' wtpath; do
    [ -n "$branch" ] && candidates="$candidates $branch"
    [ -n "$wtpath" ] && candidates="$candidates ${wtpath##*/}"
  done < <(_wt_records)

  # SC2207: word-splitting is the intended completion idiom; mapfile is absent in bash 3.2.
  # shellcheck disable=SC2207
  COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}

# --------------------------------------------------------------------------
# Register the command and its completion (name driven by $WT_CMD).
# --------------------------------------------------------------------------

eval "${WT_CMD}() { _wt_main \"\$@\"; }"

if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -Uz bashcompinit 2>/dev/null && bashcompinit 2>/dev/null
  complete -F _wt "$WT_CMD" 2>/dev/null
elif [ -n "${BASH_VERSION:-}" ]; then
  complete -F _wt "$WT_CMD"
fi
