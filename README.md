# git-worktree-switch

Switch between git worktrees.

`wt` is a tiny shell function that lists your git worktrees, matches one by
name with autocompletion, and `cd`s you into it.

## Requirements

- git 2.36+
- bash or zsh

No other dependencies. No awk, no sed, no fzf.

## Install

Clone the repo somewhere permanent:

```bash
git clone https://github.com/tommarshall/git-worktree-switch.git ~/.git-worktree-switch
```

Then `source` `wt.sh` from your shell. `wt` must be **sourced**, not run — it
has to change the directory of your current shell, and a script run in a
subshell can't do that.

Add one line to your shell startup file so it loads in every new shell:

```bash
echo 'source ~/.git-worktree-switch/wt.sh' >> ~/.bashrc
```

For zsh, use `~/.zshrc` instead:

```bash
echo 'source ~/.git-worktree-switch/wt.sh' >> ~/.zshrc
```

**macOS note:** macOS Terminal starts login shells, which read `~/.bash_profile`
rather than `~/.bashrc`. If you use bash on macOS, add the line to
`~/.bash_profile` (or `source ~/.bashrc` from it).

Open a new shell, or `source` the file once to use it right away:

```bash
source ~/.git-worktree-switch/wt.sh
```

## Usage

```
wt            list worktrees, pick one by number
wt <query>    jump to the worktree matching <query>
wt -          jump back to the previous worktree (like cd -)
```

Matching is a case-insensitive substring. It checks branch names first,
then paths. One match jumps straight there. Several matches drop you into the
numbered picker, filtered to just those matches.

The current worktree is marked with `*`. A detached HEAD shows as `(detached)`;
the bare repo, if any, is skipped.

Tab completion completes branch names and worktree folder names.

```
$ wt
  1) * main        ~/projects/app
  2)   feature-x   ~/projects/app-feature-x
  3)   bugfix-42   ~/projects/app-bugfix-42
worktree #? 2
~/projects/app-feature-x

$ wt bug
~/projects/app-bugfix-42

$ wt -
~/projects/app-feature-x
```

## Update

```bash
cd ~/.git-worktree-switch && git pull
```

Then open a new shell (or `source ~/.git-worktree-switch/wt.sh` again).

## Rename the command

If `wt` clashes with something else, change the command name. Edit `wt.sh` and
set the variable at the top:

```bash
WT_CMD="wtree"
```

That one line renames the command, its tab completion, and every message. Open
a new shell after changing it.
