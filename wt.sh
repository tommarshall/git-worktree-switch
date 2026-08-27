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
# A *record* is one worktree moving down the pipe:
#   _wt_records → _wt_label → _wt_match → _wt_render
# runs git once, labels, filters by query, then draws the menu. All four are
# pure stdin→stdout filters — no shell state — so each is testable by piping
# records in and checking what comes out, with no git and no fixture.
#
# Records are NUL-framed, fixed arity, no separator, so a worktree path (which
# may contain a newline — why git offers `-z`) survives intact:
#   raw     = head \0 branch \0 path \0   from `_wt_records`
#   display = label \0 path \0            from `_wt_label` onward
# `head` is `bare` / `detached` / `branch` — the one field telling them apart.
#
# Only `_wt_fill` and `_wt_pick` share state by dynamic scope: `_wt_fill` fills
# the arrays `wt_paths` / `wt_labels`, `_wt_pick` reads them and writes the one
# scalar `pick` (its verdict). All three are `local` in `_wt_main` alone, so a
# callee writes straight into the conductor's locals — no globals leak, and
# nothing crosses a subshell (a `$(...)` capture would swallow the picker's
# prompt). Holds under the zsh `emulate -L` guard, which localises options.
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
# Render the numbered, aligned candidate menu from display records on stdin —
# the same `label \0 path \0` records the pipeline produces. A pure filter like
# the rest: records in, menu text out, no shell state and no tty, so the column
# alignment and current-row marker can be asserted without driving `wt`.
# $1 = current path (its row gets the `*` marker); $2 = `1` to colour that row.
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

  # widest branch label among the candidates, so every path lines up in a column
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
# Show the candidate menu, read a choice, and set `pick` (the conductor's local)
# to one verdict: "" = nothing selected, `row:<index>` = that row (0-based),
# `query:<text>` = re-match by name/path. The effectful half of the picker:
# decides colour from the tty, feeds `wt_paths` / `wt_labels` to `_wt_render`,
# then reads and classifies the reply — it runs in the user's shell so the `cd`
# lands there. $1 = current path. Always returns 0; the verdict is in `pick`.
#
_wt_pick() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local here="$1"

  # --- colour: only on a tty, and only if git config doesn't forbid it ------
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

  # Classify the reply into `pick`: empty = bail; a pure number in range =
  # `row:<index>`; anything else = `query:<text>`, so a branch named `1234` still
  # resolves. The conductor strips the tag once, so a query with a `:` survives.
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
  # shellcheck disable=SC2034  # wt_paths/wt_labels filled by _wt_fill; pick set by _wt_pick (dynamic scope)
  local wt_paths=() wt_labels=() chosen=-1 pick=""

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
    [ "$count" -eq 1 ] && chosen=0
  fi

  # --- picker: numbered list of candidates, read a choice -------------------
  # Loop so a typed name (or out-of-range number) re-matches against ALL
  # worktrees via the same pipeline the CLI uses. Dispatch the picker's `pick`
  # verdict: `row:` picks and ends the loop; `query:` refills the candidates; ""
  # bails (the picker already said why).
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

  # --- go ---------------------------------------------------------------------
  # "already there" means standing on the worktree root itself, not merely
  # inside that worktree — compare against $PWD, not `here` (the root). Picking
  # the current worktree from a subdirectory should still cd up to its root.
  if [ "${wt_paths[$chosen]}" = "$PWD" ]; then
    printf '%s: already there\n' "$WT_CMD"
    return 0
  fi
  _wt_cd "${wt_paths[$chosen]}" "$here"
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

  # Label through `_wt_label` so how a Label is formed lives in ONE place
  # (branch, else `(detached)` / `(unknown)`), with the bare repo already
  # dropped. Offer each Label and its worktree folder basename.
  # ACCEPTED LIMIT: `compgen -W` word-splits on IFS, so a Label or path with
  # whitespace won't survive. NUL-safe completion needs bash 4's `readarray -d`,
  # but this runs in bash 3.2 — keep the space-join.
  while IFS= read -r -d '' label && IFS= read -r -d '' wtpath; do
    [ -n "$label" ]  && candidates="$candidates $label"
    [ -n "$wtpath" ] && candidates="$candidates ${wtpath##*/}"
  done < <(_wt_records | _wt_label)

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
