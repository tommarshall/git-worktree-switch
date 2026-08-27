# git-worktree-switch

`wt` lists the git worktrees under a repository and changes the shell into the
one you choose. This glossary fixes the words the code and its docs use for the
things it switches between and the steps it takes to switch.

## Worktrees & records

**Worktree**:
One checked-out working tree of a repository — a directory with its own branch
or detached HEAD. The thing `wt` switches between. The bare repository is not a
worktree and never a switch target.

**Record**:
One worktree reduced to what switching needs: its `head`, its branch (may be
empty), and its path.
_Avoid_: entry, row, item.

**Head**:
Which of three states a worktree's HEAD is in — `bare`, `detached`, or
`branch`.
_Avoid_: type, kind, state.

**Label**:
The display name for a worktree: its branch, or `(detached)` / `(unknown)` when
there is no branch. What the picker shows and what a query matches first.
_Avoid_: title, name, caption.

## Switching

**Query**:
The text the user gives to pick a worktree — on the command line or typed at
the picker. Matched case-insensitively as a substring, label first, then path.
_Avoid_: search, term, pattern, filter.

**Candidate**:
A worktree that matched the current query — the set the picker offers. One
candidate jumps straight there; several are shown to choose from.
_Avoid_: result, option, hit.

**Picker**:
The numbered, aligned menu of candidates and the prompt that reads a choice.
Accepts a row number or a fresh query.
_Avoid_: menu, chooser, prompt, selector.

**Recover**:
Getting back onto a worktree git can run in after the current one is removed out
from under the shell, so a switch can still proceed instead of erroring.
_Avoid_: fallback, restore, repair.
