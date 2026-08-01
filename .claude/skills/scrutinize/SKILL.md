---
name: scrutinize
description: Self-review pass to run after finishing a development task. With no argument it scrutinizes the current working changes.
argument-hint: "GH PR <number> | commit-id | git-ref-or-range | empty for working changes"
---

You are a senior software development expert with years of experience.

First, resolve `$ARGUMENTS` to the exact set of changes to scrutinize. Pick the
single case that matches and ignore the rest:

- A GitHub PR reference like `GH PR 12` -> take the number `N` and resolve it
  with `gh pr diff N` for the diff and
  `gh pr view N --json number,title,body,state,headRefName,baseRefName,url,author,files,commits`
  for the metadata. Do NOT use a bare `gh pr view N`: its default view fetches
  classic project cards and fails with a "Projects (classic) is being
  deprecated" GraphQL error.
- A commit hash -> `git show <hash>`.
- A range or ref (e.g. `main..HEAD`, `HEAD~3`) -> `git diff <range-or-ref>`.
- Empty -> the current uncommitted changes (`git diff` for unstaged,
  `git diff --cached` for staged).

Before resolving a committed target, sync the remote with `git fetch origin` so
you scrutinize current state, not a stale local checkout. If the target branch
or PR is behind `origin/main`, flag it - the scrutiny may be reviewing outdated
code.

When the target is a GitHub PR, you must edit the PR's actual code, not the tip
of whatever branch happens to be checked out. Get the PR code into the CURRENT
worktree before reading or editing:

- NEVER `cd` into another worktree, even if `git worktree list` shows the PR
  branch checked out elsewhere. Those are separate paseo workspaces - stay in
  the current one and do all work here.
- Record the current branch first (`git rev-parse --abbrev-ref HEAD`) so you
  can return to it afterward.
- Check out the PR head as a DETACHED HEAD in the current worktree:
  `gh pr checkout N --detach`. Detaching is what lets this work even when the
  PR's branch is already checked out in another worktree. If `gh` is
  unavailable, use `git fetch origin pull/N/head` followed by
  `git checkout --detach FETCH_HEAD`.
- Spot-check that one changed file already contains the PR's changes before you
  edit it. If a file still shows the old code, you are not on the PR code - fix
  that before editing.

Read the resolved diff in full before changing anything, together with all
supporting material: any linked GitHub issue, existing PR or commit comments,
and related discussion. Address every unresolved review comment - reply to and
resolve each thread per [`../github-pr/SKILL.md`](../github-pr/SKILL.md), do not
merely read them. Then read the surrounding code so a "simpler" rewrite
stays correct and so you understand the project's conventions and structure,
and honor `AGENTS.md` / `CLAUDE.md`.

This is a BG3 Script Extender Lua mod. You cannot run the game, so correctness
is a reasoning exercise, not a test run. Pay special attention to:

- **BG3SE API assumptions.** A field read or Osiris call that "should work" may
  have drifted between patches. Cross-check any non-obvious API shape against
  the IDE helpers (`ExtIdeHelpers.lua`) or the API docs rather than trusting the
  diff. If an assumption cannot be confirmed from source, say so - do not
  present it as verified.
- **pcall coverage.** Every SE call that can fail on a dead entity or absent
  component must be guarded; an unguarded error tears down the Lua state.
- **Server vs client replication.** Only the server replicates a rename; a
  client applies locally. A rewrite that moves a write across that boundary is a
  correctness bug even if it reads cleanly.
- **Empirical timing.** The delays exist because summons are not assembled on
  the tick they enter the level. Do not "simplify" them away.

Then research online for current best practices for exactly what the change is
trying to do, so every decision that follows is well founded.

Now critically challenge each and every single character added by the change:

- If it is not absolutely needed, remove it.
- If it can be done more simply, make it simpler.
- If it can be done more elegantly, make it more elegant.

While doing so, keep the result readable:

- No abbreviations.
- Variables have speaking, descriptive names.
- The additions stay readable.

Hold comments and docstrings to a strict standard:

- Good code needs no inline comments. Add one only to explain something
  non-obvious that the code cannot convey - almost always a BG3SE quirk, a
  timing reason, or a replication invariant.
- A good inline comment is at most one line - a line, not a sentence.
- Honor the project's documentation standards while trimming: keep the EmmyLua
  `---@param` / `---@return` annotations that make dynamically-typed SE objects
  navigable, but make each entry as short and precise as possible.

Challenge every existing comment and docstring against these limits and cut or
shorten anything that fails them. Enforce ASCII punctuation (see `AGENTS.md`) -
flag any em-dash, arrow, or smart quote introduced by the change.

Scrutinize the commit message itself against
[`../commit/SKILL.md`](../commit/SKILL.md):

- Subject in the imperative, first word capitalized, no trailing period, under
  ~72 characters.
- Body wrapped at ~72-76 characters, explaining why the change is made and what
  it achieves - not how, which the code already shows. Keep it short and
  precise; do not drift into technical detail.
- ASCII punctuation only, and the mandatory `Co-authored-by:` trailer present
  exactly once in the footer.

If the message fails any of these, correct it as part of the same amend you make
when publishing the result below - unless the commit is already merged into the
remote's main branch, in which case flag the problem rather than rewriting
published history.

If the change adds tests, challenge each one: is it necessary, does it add value
beyond existing coverage, can it fold into another test or use parametrization?
Drop anything redundant. (This repo has no test suite today, so this applies
only once one exists.)

Apply the changes directly. For every edit, state what you challenged and why
the change is justified (removed as unneeded / simpler / more elegant /
tightened prose). If a change is genuinely needed as-is, say so rather than
inventing a change.

Once the edits are applied, verify what you can without the game: re-read the
result for the four correctness points above and confirm the pre-commit
typography check passes. Call out explicitly anything that still needs in-game
verification, naming the console command (`!nys_diag`, `!nys_rename`, ...) the
user should run.

Finally, publish the result so the scrutiny is not stranded locally:

- For a GitHub PR: commit the edits following [`../commit/SKILL.md`](../commit/SKILL.md)
  (including the mandatory `Co-authored-by` trailer). Because you are on a
  detached HEAD, push the new commit to the PR's branch explicitly:
  `git push origin HEAD:<headRefName>`, using the `headRefName` from the
  `gh pr view --json` metadata. Do this without being asked. Then return to the
  branch you recorded earlier (`git checkout <original-branch>`), report the new
  commit hash, and confirm the PR now reflects the scrutiny.
- For a commit on a branch: amend the scrutinized commit (`git commit --amend`,
  keeping the message unless you corrected it above) rather than adding a
  follow-up commit, then `git push` (force-push if already pushed, confirming
  with the user first). Exception: if the commit is already merged into
  `origin/main` (`git merge-base --is-ancestor <hash> origin/main` after
  `git fetch origin`), do NOT amend - tell the user and ask how to proceed,
  offering a force-push that rewrites history or a dedicated follow-up commit.
- For working changes (empty argument): leave them staged/unstaged as you found
  them and do not commit unless asked.
