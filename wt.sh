#!/usr/bin/env bash
#
# wt(1) - switch between git worktrees. One thing, well.
# Released under the MIT License.
#
# Version 0.1.0
#
# https://github.com/tommarshall/wt
#
# SOURCE this file from ~/.bashrc and ~/.zshrc (it is not executed):
#
#   source /path/to/wt.sh
#
# Usage:
#   wt            list worktrees, pick one by number
#   wt <query>    jump to the worktree matching <query> (branch, then path;
#                 case-insensitive substring). One match jumps; several filter.
#   wt -          jump back to the previous worktree (like `cd -`)

# --------------------------------------------------------------------------
# Globals (declared once, up top)
# --------------------------------------------------------------------------

# The command name. To rename the command, change this ONE line — the function,
# its completion, and every message follow it.
WT_CMD="wt"

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
# The switcher itself. Wrapped as ${WT_CMD} at the bottom of the file.
#
_wt_main() {
  # --- portability guard (zsh only; local via emulate -L, does not leak) ---
  [ -n "${ZSH_VERSION:-}" ] && emulate -L zsh 2>/dev/null && \
    setopt ksh_arrays sh_word_split no_nomatch

  local query="${1:-}"

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

  # --- where are we now (absolute worktree root) ----------------------------
  local here=""
  here=$(git rev-parse --show-toplevel 2>/dev/null)

  # --- gather worktrees from porcelain -z (double-NUL record boundaries) -----
  # Parse in pure shell (no awk/sed) per the house style. Branch on which
  # lines a record carries: bare has neither HEAD nor branch (skip it);
  # detached HEAD emits `detached` and NO branch line — never assume a branch.
  # NOTE: do NOT name a variable `path` here — in zsh `path` is the array form
  # of $PATH, so `local path=...` would blow away PATH inside the function and
  # git would vanish. Use `wtpath`.
  local wt_paths=() wt_labels=()
  local token wtpath="" branch="" is_detached=0 is_bare=0
  while IFS= read -r -d '' token; do
    if [ -z "$token" ]; then
      # record boundary — commit the record we just read
      if [ -n "$wtpath" ] && [ "$is_bare" -eq 0 ]; then
        wt_paths+=("$wtpath")
        if [ -n "$branch" ]; then
          wt_labels+=("$branch")
        elif [ "$is_detached" -eq 1 ]; then
          wt_labels+=("(detached)")
        else
          wt_labels+=("(unknown)")
        fi
      fi
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
  if [ -n "$wtpath" ] && [ "$is_bare" -eq 0 ]; then
    wt_paths+=("$wtpath")
    if [ -n "$branch" ]; then wt_labels+=("$branch")
    elif [ "$is_detached" -eq 1 ]; then wt_labels+=("(detached)")
    else wt_labels+=("(unknown)"); fi
  fi

  local count="${#wt_paths[@]}"
  if [ "$count" -eq 0 ]; then
    printf '%s: not in a git repository (or no worktrees)\n' "$WT_CMD" >&2
    return 1
  fi

  # --- `wt -` : jump back to the previous worktree --------------------------
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
  local match_idx=() tgt=-1 i=0

  if [ -z "$query" ]; then
    # no arg: candidates are every worktree
    if [ "$count" -le 1 ]; then
      printf '%s: only one worktree\n' "$WT_CMD"
      return 0
    fi
    i=0
    while [ "$i" -lt "$count" ]; do match_idx+=("$i"); i=$((i + 1)); done
  else
    # a query: match branch labels first, then fall back to paths
    local q_lc lbl_lc path_lc
    q_lc=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

    i=0
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

    case "${#match_idx[@]}" in
      0) printf '%s: no worktree matches: %s\n' "$WT_CMD" "$query" >&2
         return 1 ;;
      1) tgt="${match_idx[0]}" ;;
      *) : ;;  # several matches -> fall through to the picker
    esac
  fi

  # --- picker: numbered list of candidates, read a choice -------------------
  if [ "$tgt" -lt 0 ]; then
    local n=0 idx marker reply
    while [ "$n" -lt "${#match_idx[@]}" ]; do
      idx="${match_idx[$n]}"
      if [ -n "$here" ] && [ "${wt_paths[$idx]}" = "$here" ]; then
        marker="*"
      else
        marker=" "
      fi
      if [ "$marker" = "*" ]; then
        printf '%s%3d) %s %s  %s%s\n' "$C_CUR" "$((n + 1))" "$marker" \
          "${wt_labels[$idx]}" "${wt_paths[$idx]}" "$C_RST"
      else
        printf '%3d) %s %s  %s\n' "$((n + 1))" "$marker" \
          "${wt_labels[$idx]}" "${wt_paths[$idx]}"
      fi
      n=$((n + 1))
    done

    printf 'worktree #? '
    IFS= read -r reply

    case "$reply" in
      ''|*[!0-9]*)
        printf '%s: invalid selection\n' "$WT_CMD" >&2
        return 1 ;;
    esac
    if [ "$reply" -lt 1 ] || [ "$reply" -gt "${#match_idx[@]}" ]; then
      printf '%s: selection out of range\n' "$WT_CMD" >&2
      return 1
    fi
    tgt="${match_idx[$((reply - 1))]}"
  fi

  # --- go ---------------------------------------------------------------------
  if [ -n "$here" ] && [ "${wt_paths[$tgt]}" = "$here" ]; then
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
