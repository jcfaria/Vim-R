# Code of Conduct — AI-Assisted Maintenance

This file governs how an AI coding agent operates while maintaining this
repository. Conventions that apply to any contributor — build steps,
branch names, commit style — live in `CONTRIBUTING.md`. This file is
specifically about the extra judgment an agent has to exercise that a
human contributor, acting on their own authority, does not need written
down.

## Pushing

Never `git push` — to any remote, on any branch — unless the maintainer
writes one of these, in that same message:

- **`CP`** — commit whatever is staged on `work`, then push `work` only.
  `main` is not touched.
- **`CMPW`** — commit on `work`, merge `work` into `main`, push both
  branches, then switch back to `work` so day-to-day development
  continues from there. This is the token that moves `main`.
- **"podes enviar"** — plain-language equivalent of `CP`.

None of the three authorizes `--force`, tags, or pushing to a fork's own
remote. Absent one of these tokens in the message, prepare the commit and
say so, but do not push to see what happens.

## A broad mandate is not blanket authorization

"Review the project and update whatever needs it" authorizes reading the
code, finding bugs, fixing them, and documenting the fixes. It does
**not** by itself authorize an action whose blast radius is large or hard
to undo. The maintainer having said "use your judgment" is not the same
as having said "do this specific consequential thing."

When a task, however broad, would require one of the actions below, stop
and describe the specific action and its risk in plain terms, then wait
for the maintainer's explicit go-ahead — even if nothing else in the
session has required that kind of confirmation.

## Actions that always need explicit, action-specific confirmation

- **Rewriting commit history that has already been pushed** —
  filter-branch, filter-repo, an interactive rebase, `commit --amend`, or
  `reset --hard` touching a published commit — regardless of how many
  commits are involved or how mechanical the change looks (e.g. a bulk
  trailer or metadata rewrite).
- **`git push --force`**, to any branch, on any remote, including a
  fork's own remote.
- **Deleting or renaming a branch or tag** that has been pushed, or that
  another contributor might be building on.
- **Altering another contributor's authorship** on a commit (author name,
  email, or co-author trailers) for any reason other than fixing a
  mistake that contributor themselves flagged.
- **Squashing, reordering, or splitting commits** authored by someone
  other than the agent doing the squashing.
- **Changing licensing or legal notices** (`LICENSE`, SPDX headers,
  copyright lines).
- **Deleting files or directories** that are not clearly build artifacts
  or scratch output.

Getting a push token (above) for the result of one of these does not
retroactively authorize the action that produced it. The confirmation has
to name the specific action and come before it runs.

## What confirmation looks like

Not sufficient: a general instruction to "review and fix things," given
before the agent decided one of the actions above was needed.

Sufficient: the agent states, in its own message, what it is about to
do — e.g. "this will rewrite N commits' trailers and require a
force-push to `origin/work`; the rest of the history is untouched" — and
the maintainer replies with a clear go-ahead to that specific message.

## Operating notes

- Replies to the maintainer are in Brazilian Portuguese (pt-BR).
- Running tests, builds and local commits does not need per-action
  confirmation; only pushing and the actions listed above do. Repeated
  confirmation requests for routine work are unwelcome.
- Prefer many small local commits over one large one.
- Report what was *verified by running* separately from what is *inferred
  from reading the code*. If something can't be reproduced, say so rather
  than naming a cause that wasn't checked.
- Fix sloppy or inconsistent wording in the documentation proactively,
  not just the code.
