# Contributing to Vim-R

Vim-R improves Vim's and Neovim's support for editing R code. This file
covers the project's build, test and commit conventions. If you are an AI
agent maintaining this repository, also read `CODE_OF_CONDUCT_AI.md` — it
governs how you operate here; this file governs the project's technical
conventions, for any contributor.

## Getting started

After cloning the repository, run the following commands from a terminal:

```bash
# Create a local git hooks directory
mkdir -p .git/hooks

# Create a symlink for the pre-commit hook
cd .git/hooks
ln -sf ../../hooks/pre-commit
```

Currently, the pre-commit hook checks whether all staged C files in the
repository are formatted correctly. Make sure `clang-format` is installed
on your system.

## Branches

- `main` only moves when the maintainer has reviewed and blessed the
  change. It is never pushed to directly.
- `work` is where day-to-day development happens: commit there freely.
- For a change risky enough that it shouldn't land on `work` unproven
  (e.g. touching threading, memory safety, or the network protocol in
  `R/vimcom/src/`), branch a temporary `work_xxx` off `work` and advance
  the work there. Once it succeeds, merge `work_xxx` into `work` — but
  keep `work_xxx` itself alive and mirrored to the remote as a precaution,
  rather than deleting it right away. Only once `work` has actually been
  consolidated into `main` is `work_xxx` pruned, local and remote.
- History on `main` and `work` is not rewritten once pushed — no
  `--amend`, `rebase`, `reset --hard`, or `--force` on a published commit
  — without the maintainer's explicit sign-off on that specific rewrite.
  If two authors' commits are mixed in a range (e.g. cherry-picks from a
  fork), their authorship must survive untouched.
- Only one writer commits to a given branch at a time. Check `git status`
  before starting; unexpected local changes mean someone else is
  mid-flight.

## Building and testing

Before opening a pull request, run the end-to-end smoke test:

```sh
./test/smoke_test.sh          # no arguments, ~60 s
```

It needs `tmux`, `R` with a C compiler, `vim` and `nvim`. It drives both
editors through real sessions in an isolated tmux socket and scratch
`HOME`/`R_LIBS_USER` — checking, among other things, that the plugin can
send code to R and update the Object Browser — so it never touches your
real R library or editor configuration, and exits non-zero if it leaves
any leftover state behind (editor swap files, tmux sessions, changes to
the real R library path). Toolchain-dependent assertions (LaTeX, Quarto,
PyBTeX, …) skip rather than fail when the tool is missing.

If you touch `R/vimcom/src/` or `R/vimcom/R/`, bump the `Version:` field in
`R/vimcom/DESCRIPTION` — `CheckVimcomVersion()` only rebuilds the package
when that string differs from what a user already has installed, so a
change that lands without a bump is invisible to existing installs. One
bump covers everything changed in a given batch of commits; it does not
need to be per-commit.

## Commit and documentation conventions

- Commit subject: concise, imperative. Body: prose wrapped at 72 columns,
  stating the concrete harm the change removes and, where relevant,
  whether the test suite can actually exercise it.
- `doc/Vim-R.txt`'s News section, under the current unreleased version's
  heading: bullets start with one space then `* `, continuation lines
  indented three spaces, wrapped at 78 columns. Write what the *user*
  gains or loses; a test-only or comment-only change gets no entry. Once a
  version has been merged into `main`, its News entries are final — a
  later fix gets its *own* new version heading rather than rewriting one
  that shipped.
- Avoid pinning the version of external, independently-versioned software
  (an R version bound tighter than the code actually enforces, a
  toolchain path). Point at the authoritative source instead, so it can't
  go stale silently. A real minimum the code enforces (Vim `8.2.84`,
  Neovim `0.6.0`, R `4.0.0`, Tmux `3.0`) is the exception — keep those
  pinned, and change the code and the docs together if one changes.
