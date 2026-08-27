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
# Globals
# --------------------------------------------------------------------------

# Command name. Honour a value exported before sourcing, so users can rename
# without editing this file.
WT_CMD="${WT_CMD:-wt}"

# Worktree we last jumped from, for `wt -`. Persists because this file is sourced.
WT_LAST=""

#
# cd to a worktree, remembering where we left ($2, may be empty) for `wt -`.
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
# Recover when $PWD has vanished (this worktree was removed under us): git can't
# run from a gone directory. Climb to the nearest surviving ancestor worktree,
# else fall back to WT_LAST. Returns 1 if neither is a directory git can run in.
#
_wt_recover() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    dir="${dir%/*}"
    [ -z "$dir" ] && break
    if [ -d "$dir" ] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      cd "$dir" || return 1
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
# A record is one worktree: _wt_records → _wt_label → _wt_match → _wt_render.
# All four are pure stdin→stdout filters (no shell state), so each is testable
# by piping records in — no git, no fixtures.
#
# Records are NUL-framed, fixed arity, so a path with a newline survives:
#   raw     = head \0 branch \0 path \0      (_wt_records)
#   display = label \0 path \0               (_wt_label onward)
# head is `bare` / `detached` / `branch`.
#
# _wt_fill and _wt_pick are the exception: they share the conductor's locals by
# dynamic scope (wt_paths / wt_labels / pick), never through a subshell — a
# `$(...)` capture would swallow the picker's prompt.
#
# Print one raw record per worktree, bare repo included, from
# `git worktree list --porcelain -z`.
#
_wt_records() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  # Records are double-NUL separated; branch on which lines each carries. A bare
  # repo has neither HEAD nor branch; a detached HEAD emits `detached` and no
  # branch line.
  # `wtpath` not `path`: in zsh `path` aliases $PATH, so `local path=` hides git.
  local token wtpath="" branch="" head="branch"
  while IFS= read -r -d '' token; do
    if [ -z "$token" ]; then
      # record boundary
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
# Print records matching $1 (case-insensitive substring): labels first, paths
# only if no label matched. An empty query matches everything. Buffers the full
# set first, since the path fallback can't decide until every label has failed.
#
_wt_match() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local query="$1" needle
  needle=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

  local labels=() paths=() label wtpath
  while IFS= read -r -d '' label && IFS= read -r -d '' wtpath; do
    labels+=("$label"); paths+=("$wtpath")
  done

  local count="${#labels[@]}" i=0 matched=0 hay
  while [ "$i" -lt "$count" ]; do
    hay=$(printf '%s' "${labels[$i]}" | tr '[:upper:]' '[:lower:]')
    case "$hay" in *"$needle"*)
      printf '%s\0%s\0' "${labels[$i]}" "${paths[$i]}"; matched=1 ;;
    esac
    i=$((i + 1))
  done
  [ "$matched" -eq 1 ] && return 0

  i=0
  while [ "$i" -lt "$count" ]; do
    hay=$(printf '%s' "${paths[$i]}" | tr '[:upper:]' '[:lower:]')
    case "$hay" in *"$needle"*)
      printf '%s\0%s\0' "${labels[$i]}" "${paths[$i]}" ;;
    esac
    i=$((i + 1))
  done
}

#
# Run the pipeline for query $1 ("" = all) into the conductor's wt_paths /
# wt_labels (dynamic scope — see the pipeline note above).
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
# Render the numbered, aligned menu from records on stdin.
# $1 = current path (its row gets a `*`); $2 = `1` to colour that row.
#
_wt_render() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local here="$1" color="${2:-0}"
  local C_CUR="" C_RST=""
  [ "$color" = "1" ] && { C_CUR=$'\033[1;32m'; C_RST=$'\033[0m'; }

  local labels=() paths=() label wtpath
  while IFS= read -r -d '' label && IFS= read -r -d '' wtpath; do
    labels+=("$label"); paths+=("$wtpath")
  done

  # widest label, so paths line up in a column
  local count="${#labels[@]}" n=0 label_w=0 len
  while [ "$n" -lt "$count" ]; do
    len=${#labels[$n]}
    [ "$len" -gt "$label_w" ] && label_w="$len"
    n=$((n + 1))
  done

  local marker
  n=0
  while [ "$n" -lt "$count" ]; do
    if [ -n "$here" ] && [ "${paths[$n]}" = "$here" ]; then
      marker="*"
    else
      marker=" "
    fi
    if [ "$marker" = "*" ]; then
      printf '%s%3d) %s %-*s  %s%s\n' "$C_CUR" "$((n + 1))" "$marker" \
        "$label_w" "${labels[$n]}" "${paths[$n]}" "$C_RST"
    else
      printf '%3d) %s %-*s  %s\n' "$((n + 1))" "$marker" \
        "$label_w" "${labels[$n]}" "${paths[$n]}"
    fi
    n=$((n + 1))
  done
}

#
# Show the menu and read a choice into `pick`: "" = nothing, `row:<index>` =
# that row (0-based), `query:<text>` = re-match by name/path. Runs in the user's
# shell (not a subshell) so a later `cd` lands there. $1 = current path.
#
_wt_pick() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local here="$1"

  # colour: only on a tty, and only if git config allows
  local color=0
  if [ -t 1 ]; then
    local ui
    ui=$(git config --get color.ui 2>/dev/null)
    case "$ui" in
      never|false|off|no) : ;;
      *) color=1 ;;
    esac
  fi

  # shellcheck disable=SC2154  # wt_paths/wt_labels are the conductor's locals
  local count="${#wt_paths[@]}" n=0 reply
  # serialise the filled arrays back into records for the pure renderer
  {
    while [ "$n" -lt "$count" ]; do
      printf '%s\0%s\0' "${wt_labels[$n]}" "${wt_paths[$n]}"
      n=$((n + 1))
    done
  } | _wt_render "$here" "$color"

  printf 'pick › '
  IFS= read -r reply

  # Classify: empty bails; a number in range is `row:`; anything else is
  # `query:`, so a branch named `1234` out of range still resolves as a search.
  # shellcheck disable=SC2034  # pick is the conductor's local (dynamic scope)
  if [ -z "$reply" ]; then
    printf '%s: nothing selected\n' "$WT_CMD" >&2
    pick=""
    return 0
  fi
  case "$reply" in
    *[!0-9]*) : ;;  # not a pure number -> a query below
    *) if [ "$reply" -ge 1 ] && [ "$reply" -le "$count" ]; then
         pick="row:$((reply - 1))"
         return 0
       fi ;;
  esac
  pick="query:$reply"
  return 0
}

#
# The switcher itself. Wrapped as ${WT_CMD} at the bottom of the file.
# Thin conductor: guard, fill, route (`-` / no-arg / query), then jump.
#
_wt_main() {
  # portability guard: zsh only, localised by emulate -L
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local query="${1:-}"

  # Recover a deleted cwd before any git runs, else git fails with a misleading
  # "not in a git repository" (see _wt_recover).
  if [ ! -d "$PWD" ]; then
    _wt_recover || {
      printf '%s: current directory no longer exists (worktree removed?)\n' \
        "$WT_CMD" >&2
      return 1
    }
    printf '%s: current worktree was removed; recovered to %s\n' \
      "$WT_CMD" "$PWD" >&2
  fi

  # current worktree root
  local here=""
  here=$(git rev-parse --show-toplevel 2>/dev/null)

  # `wt -`: back to the previous worktree. Before fill/count so it works even
  # when the cwd is gone or we're outside a repo.
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

  # decide the target, or the candidate set to pick from
  # shellcheck disable=SC2034  # wt_paths/wt_labels filled by _wt_fill; pick set by _wt_pick (dynamic scope)
  local wt_paths=() wt_labels=() chosen=-1 pick=""

  _wt_fill "$query"
  local count="${#wt_paths[@]}"

  # Zero candidates: distinguish "not a repo" from "query matched nothing".
  # `here` is empty in a bare repo, so probe the git-dir before blaming the query.
  if [ "$count" -eq 0 ]; then
    if [ -n "$query" ] && { [ -n "$here" ] || \
         git rev-parse --git-dir >/dev/null 2>&1; }; then
      printf '%s: no worktree matches: %s\n' "$WT_CMD" "$query" >&2
    else
      printf '%s: not in a git repository (or no worktrees)\n' "$WT_CMD" >&2
    fi
    return 1
  fi

  # A lone candidate (the only worktree, or the only query match) skips the
  # picker; the jump below cd's to its root. `sole` is the narrower case of one
  # worktree and no query — it only changes the wording below.
  local sole=0
  [ "$count" -eq 1 ] && chosen=0
  [ -z "$query" ] && [ "$count" -eq 1 ] && sole=1

  # Picker loop. A typed name (or out-of-range number) re-matches via the same
  # pipeline: `row:` picks and ends, `query:` refills, "" bails.
  while [ "$chosen" -lt 0 ]; do
    _wt_pick "$here"
    case "$pick" in
      "")    return 1 ;;
      row:*) chosen="${pick#row:}" ;;
      query:*)
        _wt_fill "${pick#query:}"
        case "${#wt_paths[@]}" in
          0) printf '%s: no worktree matches: %s\n' "$WT_CMD" "${pick#query:}" >&2
             return 1 ;;
          1) chosen=0 ;;
          *) : ;;  # several matches -> loop, picker reshows the filtered set
        esac ;;
    esac
  done

  # "already there" means $PWD is the root itself; from a subdir we still cd up.
  if [ "${wt_paths[$chosen]}" = "$PWD" ]; then
    if [ "$sole" -eq 1 ]; then
      printf '%s: no other worktrees\n' "$WT_CMD"
    else
      printf '%s: already there\n' "$WT_CMD"
    fi
    return 0
  fi
  _wt_cd "${wt_paths[$chosen]}" "$here" || return 1
  # A move prints its destination (see _wt_cd); for the sole worktree, add why
  # it moved on its own — you didn't pick, there was just nowhere else to go.
  [ "$sole" -eq 1 ] && printf '%s: no other worktrees\n' "$WT_CMD"
}

#
# Completion: one bash-style function, reused in zsh via bashcompinit.
# Completes branch names and worktree path basenames for the first argument.
#
_wt() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local cur candidates="" label wtpath
  cur="${COMP_WORDS[COMP_CWORD]}"

  # only complete the first word after the command
  if [ "$COMP_CWORD" -ne 1 ]; then
    COMPREPLY=()
    return 0
  fi

  # Reuse `_wt_label` so labels form in one place; offer each label and the
  # worktree folder basename. Limit: `compgen -W` splits on IFS, so a label or
  # path with whitespace won't survive (NUL-safe needs bash 4, we target 3.2).
  while IFS= read -r -d '' label && IFS= read -r -d '' wtpath; do
    [ -n "$label" ]  && candidates="$candidates $label"
    [ -n "$wtpath" ] && candidates="$candidates ${wtpath##*/}"
  done < <(_wt_records | _wt_label)

  # SC2207: word-splitting is the completion idiom here.
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
