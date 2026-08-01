---
name: commit
description: Write a git commit message that follows Name Your Summons' subject/body/trailer conventions, including the mandatory Co-authored-by trailer for AI-generated commits.
---

# Commit Messages

Commit messages follow the standard three-block layout: a single-line
**subject**, an optional wrapped prose **body**, and a **footer** block of Git
trailers - each block separated from the next by a blank line.

## Subject line

- Imperative mood, first word capitalized (`Add`, `Fix`, `Migrate`, `Rename`,
  `Update`, `Support`, `Remove`, `Refactor`). Mirror the style already in
  `git log`.
- Optional lowercase scope prefix followed by `: ` when the change is confined
  to a single area (e.g. `server:`, `client:`, `NameWriter:`, `prompt:`). Do
  not invent scopes that do not match the code layout.
- No trailing period. Keep under ~72 characters.
- Do not pre-append a PR number in parentheses - GitHub's squash-merge adds
  that automatically when the PR lands.

## Body

- Separate the subject from the body with a blank line.
- Wrap lines at ~72-76 characters.
- Explain **why** the change is being made, and the observable in-game
  behaviour before/after when relevant (names not sticking, a summon reverting
  to its default name, a crash). This project cannot be unit-tested, so the
  body is where the reasoning lives.
- Use `-` for bullet lists.
- ASCII punctuation only (see `AGENTS.md`) - no em-dashes, arrows, or smart
  quotes in the message.

## Footer (trailers)

Trailers go in a final block separated from the body by a blank line. Order:
issue/PR references first, then co-author trailers.

- **GitHub references**: use `GitHub: #<number>` - one per line, in the footer,
  never in the subject or body prose.
- **AI co-authorship (MANDATORY for AI-generated commits)**: include a
  `Co-authored-by:` trailer naming the model. For example:

  ```
  Co-authored-by: Claude Opus 4.7 <noreply@anthropic.com>
  ```

  - Use the exact model name in use (e.g. `Claude Opus 4.7`,
    `Claude Sonnet 4.6`, `Claude Haiku 4.5`).
  - Email must be `<noreply@anthropic.com>`.
  - Use the Git-canonical casing `Co-authored-by:` (lowercase `authored`/`by`).
    GitHub recognizes other casings too, but lowercase matches Git's own
    trailer convention and avoids duplicate trailers when tooling re-adds one.
  - Emit the trailer **exactly once**.

## Example

```
server: re-register loca handles before reapplying names

Loading a save dropped every custom summon name: runtime localisation
entries do not survive a restart, so the reapply pass pointed each
summon at a handle that no longer resolved and the name rendered as
nothing. Re-register every saved name's handle on SessionLoaded, before
the reapply pass runs.

GitHub: #12
Co-authored-by: Claude Opus 4.7 <noreply@anthropic.com>
```

## How to actually commit

Use a single-quoted heredoc (`<<'EOF'`) so backticks and `$` in the body are
not expanded by the shell:

```sh
git add <paths>        # prefer explicit paths over `git add -A`
git commit -m "$(cat <<'EOF'
<subject line>

<wrapped body>

GitHub: #<N>
Co-authored-by: <Model Name> <noreply@anthropic.com>
EOF
)"
```

Never pass `--no-verify` unless the user has explicitly asked for it. If the
pre-commit hook fails, fix the offending characters and create a new commit -
do not `--amend` to "retry" a commit that never happened.
