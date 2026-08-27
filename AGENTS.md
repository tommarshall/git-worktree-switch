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

- **No external tools.** Pure bash/zsh only — no awk, sed, or fzf. Parse with
  shell built-ins.
- **Runs in bash 3.2 and zsh.** Every function opens with the `emulate -L zsh`
  guard. No `mapfile`, no bash-4-isms.
- **Sourced, not executed.** State (`WT_LAST`) lives in the user's shell. Don't
  wrap the switch in a subshell — a `$(...)` capture eats the picker prompt.
- **Dynamic-scope contract.** `_wt_collect` / `_wt_match` / `_wt_pick` write
  into arrays declared `local` in `_wt_main` only. Keep that shape; don't add
  globals and don't re-`local` those names in the callees.
- **Rename via `WT_CMD`.** One variable at the top drives the command name, its
  completion, and every message. Never hardcode `wt`.
- **Never name a variable `path`.** In zsh `path` is `$PATH` as an array;
  clobbering it makes git vanish. Use `wtpath`.
