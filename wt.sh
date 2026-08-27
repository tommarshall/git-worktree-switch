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
# How the internal functions share state
# --------------------------------------------------------------------------
# _wt_collect / _wt_match / _wt_pick fill or read the arrays `wt_paths`,
# `wt_labels`, `match_idx` and the scalars `tgt` and `requery`. Those names are declared
# `local` in the conductor (`_wt_main`) ONLY; the callees assign to them
# without re-declaring. Both bash and zsh use dynamic scope, so a callee
# writes straight into the conductor's locals — no globals leak into the
# interactive shell, and nothing is serialised across a subshell (a `$(...)`
# capture would swallow the picker's prompt). This holds under the zsh
# `emulate -L` guard, which localises options, not variable scope.
#
# Append one parsed record to `wt_paths` / `wt_labels` (caller's locals),
# skipping the bare repo. Fields come in as args (explicit); the arrays are
# reached by dynamic scope. $1 = path, $2 = branch, $3 = detached?, $4 = bare?
#
_wt_add_record() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local wtpath="$1" branch="$2" is_detached="$3" is_bare="$4"

  [ -z "$wtpath" ] && return 0
  [ "$is_bare" -eq 1 ] && return 0

  # shellcheck disable=SC2154  # wt_paths/wt_labels are the conductor's locals
  wt_paths+=("$wtpath")
  if [ -n "$branch" ]; then
    wt_labels+=("$branch")
  elif [ "$is_detached" -eq 1 ]; then
    wt_labels+=("(detached)")
  else
    wt_labels+=("(unknown)")
  fi
}

# Collect the worktrees into `wt_paths` / `wt_labels` (caller's locals).
#
_wt_collect() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  # Parse `list --porcelain -z` (double-NUL record boundaries) in pure shell
  # (no awk/sed) per the house style. Branch on which lines a record carries:
  # bare has neither HEAD nor branch (skip it); detached HEAD emits `detached`
  # and NO branch line — never assume a branch.
  # NOTE: do NOT name a variable `path` here — in zsh `path` is the array form
  # of $PATH, so `local path=...` would blow away PATH inside the function and
  # git would vanish. Use `wtpath`.
  local token wtpath="" branch="" is_detached=0 is_bare=0
  while IFS= read -r -d '' token; do
    if [ -z "$token" ]; then
      # record boundary — commit the record we just read
      _wt_add_record "$wtpath" "$branch" "$is_detached" "$is_bare"
      wtpath=""; branch=""; is_detached=0; is_bare=0
      continue
    fi
    case "$token" in
      "worktree "*) wtpath="${token#worktree }" ;;
      "branch "*)   branch="${token#branch }"; branch="${branch#refs/heads/}" ;;
      "detached")   is_detached=1 ;;
      "bare")       is_bare=1 ;;
      *) : ;;  # HEAD, locked, prunable — not needed for switching
    esac
  done < <(git worktree list --porcelain -z 2>/dev/null)
  # safety net if a git build omits the trailing empty record
  _wt_add_record "$wtpath" "$branch" "$is_detached" "$is_bare"
}

#
# Fill `match_idx` (caller's local) with the worktrees matching $1: branch
# labels first, then paths only if no label matched. Case-insensitive substring.
#
_wt_match() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  # shellcheck disable=SC2154  # wt_paths/wt_labels are the conductor's locals
  local query="$1" count="${#wt_paths[@]}" i=0
  local q_lc lbl_lc path_lc
  q_lc=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

  while [ "$i" -lt "$count" ]; do
    lbl_lc=$(printf '%s' "${wt_labels[$i]}" | tr '[:upper:]' '[:lower:]')
    case "$lbl_lc" in *"$q_lc"*) match_idx+=("$i") ;; esac
    i=$((i + 1))
  done

  if [ "${#match_idx[@]}" -eq 0 ]; then
    i=0
    while [ "$i" -lt "$count" ]; do
      path_lc=$(printf '%s' "${wt_paths[$i]}" | tr '[:upper:]' '[:lower:]')
      case "$path_lc" in *"$q_lc"*) match_idx+=("$i") ;; esac
      i=$((i + 1))
    done
  fi
}

#
# Print the numbered candidate list (marker + colour), read a choice, and set
# `tgt` (caller's local) to the chosen worktree index. $1 = current path (for
# the `*` marker). Returns 1 on an invalid or out-of-range reply.
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

  # shellcheck disable=SC2154  # match_idx/wt_paths/wt_labels are the conductor's locals
  # widest branch label among the candidates, so every path lines up in a column
  local n=0 idx label_w=0 len
  while [ "$n" -lt "${#match_idx[@]}" ]; do
    idx="${match_idx[$n]}"
    len=${#wt_labels[$idx]}
    [ "$len" -gt "$label_w" ] && label_w="$len"
    n=$((n + 1))
  done

  local marker reply
  n=0
  while [ "$n" -lt "${#match_idx[@]}" ]; do
    idx="${match_idx[$n]}"
    if [ -n "$here" ] && [ "${wt_paths[$idx]}" = "$here" ]; then
      marker="*"
    else
      marker=" "
    fi
    if [ "$marker" = "*" ]; then
      printf '%s%3d) %s %-*s  %s%s\n' "$C_CUR" "$((n + 1))" "$marker" \
        "$label_w" "${wt_labels[$idx]}" "${wt_paths[$idx]}" "$C_RST"
    else
      printf '%3d) %s %-*s  %s\n' "$((n + 1))" "$marker" \
        "$label_w" "${wt_labels[$idx]}" "${wt_paths[$idx]}"
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
    printf '%s: invalid selection\n' "$WT_CMD" >&2
    return 1
  fi
  case "$reply" in
    *[!0-9]*) : ;;  # not a pure number -> requery below
    *) if [ "$reply" -ge 1 ] && [ "$reply" -le "${#match_idx[@]}" ]; then
         tgt="${match_idx[$((reply - 1))]}"
         return 0
       fi ;;
  esac
  requery="$reply"
  return 2
}

#
# The switcher itself. Wrapped as ${WT_CMD} at the bottom of the file.
# Thin conductor: guard, collect, route (`-` / no-arg / query), then jump.
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
  # Handled before we collect/count worktrees so it still works as an escape
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

  # --- gather worktrees (fills wt_paths / wt_labels; see the note above) ----
  # shellcheck disable=SC2034  # filled by _wt_collect via dynamic scope
  local wt_paths=() wt_labels=()
  _wt_collect

  local count="${#wt_paths[@]}"
  if [ "$count" -eq 0 ]; then
    printf '%s: not in a git repository (or no worktrees)\n' "$WT_CMD" >&2
    return 1
  fi

  # --- decide the target, or the set of candidates to pick from -------------
  local match_idx=() tgt=-1 i=0 requery="" rc=0

  if [ -z "$query" ]; then
    # no arg: candidates are every worktree
    if [ "$count" -le 1 ]; then
      printf '%s: only one worktree\n' "$WT_CMD"
      return 0
    fi
    i=0
    while [ "$i" -lt "$count" ]; do match_idx+=("$i"); i=$((i + 1)); done
  else
    _wt_match "$query"
    case "${#match_idx[@]}" in
      0) printf '%s: no worktree matches: %s\n' "$WT_CMD" "$query" >&2
         return 1 ;;
      1) tgt="${match_idx[0]}" ;;
      *) : ;;  # several matches -> fall through to the picker
    esac
  fi

  # --- picker: numbered list of candidates, read a choice -------------------
  # Loop so a typed name (or an out-of-range number) re-matches against ALL
  # worktrees, reusing `_wt_match` — the same matching the CLI does. A pick
  # (rc 0) sets `tgt` and ends the loop; a re-query (rc 2) refills the
  # candidates; an empty reply (rc 1) bails.
  while [ "$tgt" -lt 0 ]; do
    _wt_pick "$here"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      match_idx=()
      _wt_match "$requery"
      case "${#match_idx[@]}" in
        0) printf '%s: no worktree matches: %s\n' "$WT_CMD" "$requery" >&2
           return 1 ;;
        1) tgt="${match_idx[0]}" ;;
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

  local cur candidates="" token
  cur="${COMP_WORDS[COMP_CWORD]}"

  # only complete the first word after the command
  if [ "$COMP_CWORD" -ne 1 ]; then
    COMPREPLY=()
    return 0
  fi

  while IFS= read -r -d '' token; do
    case "$token" in
      "branch "*)
        token="${token#branch }"; candidates="$candidates ${token#refs/heads/}" ;;
      "worktree "*)
        token="${token#worktree }"; candidates="$candidates ${token##*/}" ;;
    esac
  done < <(git worktree list --porcelain -z 2>/dev/null)

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
