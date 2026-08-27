# AGENTS.md

`wt` is one sourced shell function that lists git worktrees and `cd`s into one.
All the code is in [`wt.sh`](wt.sh). Behaviour is in [`README.md`](README.md).
Each function carries its own comment — read the one you're editing.

## Before you're done

```bash
make lint && make test
```

Both must be green. `lint` is shellcheck; `test` is `test.sh`.

## Invariants (easy to break, span the whole file)

- **No deps beyond git and coreutils.** Lean on shell built-ins first; a
  ubiquitous POSIX tool like `tr` is fine where it's clearly simpler. No awk,
  sed, or fzf — parse with built-ins. Nothing a user would have to install.
- **Runs in bash 3.2 and zsh.** Every function opens with the `emulate -L zsh`
  guard. No `mapfile`, no bash-4-isms.
- **Sourced, not executed.** State (`WT_LAST`) lives in the user's shell. Don't
  wrap the switch in a subshell — a `$(...)` capture eats the picker prompt.
- **Records are pure filters.** `_wt_records` / `_wt_label` / `_wt_match` /
  `_wt_render` are stdin→stdout filters that touch no shell state — that's what
  makes them testable without git. Keep them that way: no writing into the
  conductor's variables, and NUL-frame every field (a worktree path may contain
  a newline).
- **Dynamic-scope contract.** Only the conductor's glue `_wt_fill` and the
  picker's shell half `_wt_pick` share state by dynamic scope — they read/write the arrays
  `wt_paths` / `wt_labels` and the scalars `tgt` / `requery`, declared `local`
  in `_wt_main` only. Keep that shape; don't add globals and don't re-`local`
  those names in the callees. It survives because the picker must prompt and
  `cd` in the user's shell, so its output can't be captured through `$(...)`.
- **Rename via `WT_CMD`.** One variable at the top drives the command name, its
  completion, and every message. Never hardcode `wt`. Its default is set with
  `${WT_CMD:-wt}` so a value exported before sourcing wins — keep that form so
  users can rename from their profile without editing the script.
- **Never name a variable `path`.** In zsh `path` is `$PATH` as an array;
  clobbering it makes git vanish. Use `wtpath`.
