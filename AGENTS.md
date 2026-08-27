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
  picker's shell half `_wt_pick` share state by dynamic scope: `_wt_fill` fills
  the arrays `wt_paths` / `wt_labels`, `_wt_pick` reads them and writes the one
  scalar `pick` (its verdict `""` / `row:<index>` / `query:<text>`), all
  declared `local` in `_wt_main` only. Keep that shape; don't add globals and
  don't re-`local` those names in the callees. It survives because the picker
  must prompt and `cd` in the user's shell, so its output can't be captured
  through `$(...)`.
- **Rename via `WT_CMD`.** One variable at the top drives the command name, its
  completion, and every message. Never hardcode `wt`. Its default is set with
  `${WT_CMD:-wt}` so a value exported before sourcing wins — keep that form so
  users can rename from their profile without editing the script.
- **Never name a variable `path`.** In zsh `path` is `$PATH` as an array;
  clobbering it makes git vanish. Use `wtpath`.
- **Name variables so they read.** Prefer a word to an abbreviation: `chosen`
  not `tgt`, `dir` not `p`, `needle`/`hay` for a match. Loop counters (`i`, `n`)
  and the glossary's own terms (`head`, `label`, `query`) are the exceptions.

## Comments

Comment sparingly, and make each one earn its place. Prefer code clear enough to
need none; shell buys more comment than most languages, but stay lean.

- **Say why, not what.** The gotcha, the reason a line exists, the constraint
  that isn't visible — never a restatement of what the code plainly does.
- **One line where one line does.** Cut anything the code already carries.
- **Write for a new reader six months out.** A comment stands on its own, with
  no history: no "used to", no previous implementation, no ticket or plan.
