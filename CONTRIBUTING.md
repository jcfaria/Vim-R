# Contributing to Vim-R

Vim-R improves Vim's and Neovim's support for editing R code. This file
covers how to build, test and commit changes — for human contributors and
for AI coding agents working on this repository alike.

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
- `work` is where day-to-day development happens, including by an AI
  assistant: commit there freely.
- For a change risky enough that it shouldn't land on `work` unproven
  (e.g. touching threading, memory safety, or the network protocol in
  `R/vimcom/src/`), branch a temporary `work_xxx` off `work` and advance
  the work there. Once it succeeds, merge `work_xxx` into `work` — but
  keep `work_xxx` itself alive and mirrored to the remote as a precaution,
  rather than deleting it right away. Only once `work` has actually been
  consolidated into `main` (a `CP`/`CMPW` push, see below) is `work_xxx`
  pruned, local and remote.
- Never rewrite history that has already been pushed: no `--amend`,
  `rebase`, or `reset --hard` on a published commit, and no `--force`
  unless explicitly instructed. If two authors' commits are mixed in a
  range (e.g. cherry-picks from a fork), their authorship must survive
  untouched.
- Only one writer — human or agent — commits to a given branch at a time.
  Check `git status` before starting; unexpected local changes mean someone
  else is mid-flight.

## Pushing (for an AI assistant working here)

Never `git push` — to any remote, on any branch — unless the maintainer
writes one of these, in that same message:

- **`CP`** — commit whatever is staged on `work`, then push `work` only.
  `main` is not touched.
- **`CMPW`** — commit on `work`, merge `work` into `main`, push both
  branches, then switch back to `work` so day-to-day development continues
  from there. This is the token that moves `main`.
- **"podes enviar"** — plain-language equivalent of `CP`.

None of the three authorizes `--force`, tags, or pushing to a fork's own
remote. Absent one of these tokens in the message, prepare the commit and
say so, but do not push to see what happens.

## Building and testing

Before opening a pull request — and, for an AI assistant, before every
commit — run the end-to-end smoke test:

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

## Notes for whoever (or whatever) picks this up next

- Replies to the maintainer are expected in Brazilian Portuguese (pt-BR).
- Running tests, builds and local commits does not need per-action
  confirmation; only pushing does (see above). Repeated confirmation
  requests for those are unwelcome.
- Prefer many small local commits over one large one.
- Report what was *verified by running* separately from what is *inferred
  from reading the code*. If something can't be reproduced, say so rather
  than naming a cause that wasn't checked.
- The maintainer notices sloppy or inconsistent wording in the
  documentation and expects it fixed, not just the code.
