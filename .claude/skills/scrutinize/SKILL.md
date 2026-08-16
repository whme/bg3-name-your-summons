---
name: scrutinize
description: Self-review pass to run after finishing a development task. With no argument it scrutinizes the current working changes.
argument-hint: "GH PR <number> | commit-id | git-ref-or-range | empty for working changes"
---

You are a senior software development expert with years of experience.

## How to run this skill (read first)

This skill has a fuzzy half (judging the code) and a mechanical half
(rebasing, trimming, resolving threads, committing, pushing). The mechanical
half is what gets skipped: once the review reads well, the tempting next move is
to declare success and stop. Do not. The run is complete only when every
applicable item in **Definition of done** at the bottom is checked off WITH the
evidence named there.

- **Your first action** is to open **Definition of done**, drop the items that
  do not apply to this target (e.g. no PR-thread step for a plain commit), and
  turn the rest into a `TodoWrite` list. Keep it current as you go and never
  mark an item done without the evidence it names.
- When a step says to commit, create a PR, or answer review threads, **invoke
  the sibling skill** (`commit`, `github-pr`) with the Skill tool. Do not hand-
  roll a commit message or a thread reply from memory - the linked
  `SKILL.md` files are the source of truth, not a suggestion.

## 1. Resolve the target

Resolve `$ARGUMENTS` to the exact set of changes. Pick the single matching case:

- A GitHub PR reference like `GH PR 12` -> take the number `N`, get the diff
  with `gh pr diff N` and the metadata with
  `gh pr view N --json number,title,body,state,headRefName,baseRefName,url,author,files,commits`.
  Do NOT use a bare `gh pr view N`: its default view fetches classic project
  cards and fails with a "Projects (classic) is being deprecated" GraphQL error.
- A commit hash -> `git show <hash>`.
- A range or ref (e.g. `main..HEAD`, `HEAD~3`) -> `git diff <range-or-ref>`.
- Empty -> the current uncommitted changes (`git diff` unstaged,
  `git diff --cached` staged).

Run `git fetch origin` before resolving any committed target so you scrutinize
current state, not a stale checkout.

## 2. Put the PR code current in THIS worktree (PR / branch targets)

Skip this section for a plain commit hash, a range, or empty working changes.

Edit the PR's actual code, not the tip of whatever branch is checked out:

- NEVER `cd` into another worktree, even if `git worktree list` shows the PR
  branch checked out elsewhere - those are separate paseo workspaces. Stay here.
- Record the current branch (`git rev-parse --abbrev-ref HEAD`) so you can
  return to it at the end.
- Check out the PR head as a DETACHED HEAD here: `gh pr checkout N --detach`
  (detaching is what lets this work when the branch is checked out elsewhere).
  Without `gh`: `git fetch origin pull/N/head` then
  `git checkout --detach FETCH_HEAD`.
- Spot-check that one changed file already contains the PR's changes before you
  edit. If a file still shows old code, you are not on the PR code - fix that.

**Rebase onto the PR's base branch (the Gerrit "new patchset" flow).**
The GitHub equivalent of pushing a rebased patchset is a `--force-with-lease`
push to the PR's OWN branch: GitHub records it as a force-push event on the PR
timeline with a "compare" link, so the previous tip and the patchset-to-patchset
diff stay visible to the reviewer, exactly like Gerrit patchsets.

- Rebase onto `origin/<baseRefName>` from the `gh pr view --json` metadata - NOT
  a hardcoded `origin/main`. A patch-release PR targets a `X.Y-maintenance`
  branch (see `AGENTS.md`), and rebasing it onto `main` would be wrong.
- `git rebase origin/<baseRefName>`. Resolve any conflicts properly - do not
  `--abort` or `--skip` to make the work vanish (see `AGENTS.md`, "resolve,
  don't discard").
- Rebasing also lets you scrutinize the code as it will look merged, catching
  conflicts and semantic drift against the current base.
- The rebase and your scrutiny edits go up together as one new patchset in the
  publish step. Do not force-push here; that happens once, at the end.

## 3. Read and understand before touching anything

Read the resolved diff in full, plus all supporting material: any linked GitHub
issue, existing PR/commit comments, and related discussion. Then read the
surrounding code so a "simpler" rewrite stays correct, and honor `AGENTS.md` /
`CLAUDE.md`. Research current best practices online for what the change is
actually trying to do, so each decision below is well founded.

## 4. Answer every unresolved review thread (PR targets)

For a PR, invoke the `github-pr` skill and follow it to REPLY to and RESOLVE
each unresolved thread - not merely read them. A thread is handled only after
both the reply and the resolve. Record how many threads you closed; that count
is the evidence for this step.

## 5. Judge correctness (reason it through - you cannot run the game)

This is a BG3 Script Extender Lua mod, so correctness is reasoning, not a test
run. Weigh each of these:

- **BG3SE API assumptions.** A field read or Osiris call that "should work" may
  have drifted between patches. Cross-check any non-obvious shape against the
  IDE helpers (`ExtIdeHelpers.lua`) or the API docs. If an assumption cannot be
  confirmed from source, say so - never present it as verified.
- **pcall coverage.** Every SE call that can fail on a dead entity or absent
  component must be guarded; an unguarded error tears down the Lua state.
- **Server vs client replication.** Only the server replicates a rename; a
  client applies locally. A rewrite that moves a write across that boundary is a
  correctness bug even if it reads cleanly.
- **Empirical timing.** The delays exist because summons are not assembled on
  the tick they enter the level. Do not "simplify" them away.

## 6. Challenge every character the change adds

For each addition, ask - and then act:

- If it is not absolutely needed, remove it.
- If it can be done more simply, make it simpler.
- If it can be done more elegantly, make it more elegant.

Keep the result readable: no abbreviations, descriptive variable names, and
additions that stay legible.

**Comments and docstrings, to a strict standard - this is where narration gets
cut, so do it deliberately:**

Start from zero, not from "is this comment nice to have". Good code needs no
comment and no explanatory prose in a docstring; the default for every comment
and every line of docstring prose is DELETE. A comment earns its place ONLY by
explaining something the code genuinely cannot tell the reader - almost always a
BG3SE quirk, an empirical timing reason, or a replication invariant. That is the
sole exception. Everything else goes.

- **Narration is never a valid reason to keep a comment or docstring prose.** A
  comment that restates, paraphrases, summarizes, or narrates what the code
  does - even accurately, even readably - is not "documentation", it is noise,
  and it gets removed. "It describes the function" is not a justification; the
  code already describes the function. Do not talk yourself into keeping it
  because it reads well or seems harmless.
- Delete every comment that paraphrases the next line, narrates a step, restates
  a name, or banners a section. Delete docstring sentences that describe what the
  function/module does when the signature and name already convey it.
- A kept comment is at most one line - a line, not a sentence - and states the
  WHY the code cannot, never the WHAT it already shows.
- Keep the EmmyLua `---@param` / `---@return` annotations that make SE objects
  navigable (these are type hints, not prose), but make each as short and
  precise as possible. A one-line `---` summary is fine only when the name does
  not already say it; cut any longer narrative description.
- Challenge EXISTING comments and docstrings touched by the change against the
  same bar and cut anything that fails - do not grandfather them in.

Enforce ASCII punctuation (see `AGENTS.md`): flag and fix any em-dash, arrow, or
smart quote in the change.

Apply the edits directly. For each, state in one line what you challenged and
the verdict (removed as unneeded / simpler / more elegant / tightened prose). If
something is genuinely needed as-is, say so rather than inventing a change.

## 7. Scrutinize the commit message

Judge the message against the `commit` skill:

- Subject imperative, first word capitalized, no trailing period, under ~72
  chars.
- Body wrapped at ~72-76 chars, explaining WHY and the observable in-game
  effect - not how, which the code shows. Short and precise.
- ASCII punctuation only, and exactly one `Co-authored-by:` trailer in the
  footer.

Fix any failure as part of the publish step below - UNLESS the commit is already
merged into `origin/main`, in which case flag it rather than rewriting published
history.

If the change adds tests, challenge each: is it necessary, does it add value
beyond existing coverage, can it fold into another test or parametrize? Drop
anything redundant. Add or extend a spec when the change touches testable logic
(see `AGENTS.md` for what the LuaUnit suite under `spec/` covers).

## 8. Verify what you can without the game

Re-check the four correctness points in section 5 against the final code, and
confirm the pre-commit typography check passes. Run `./make.ps1 all` if you can;
if you cannot, reason through each gate and say so. Call out explicitly anything
that still needs in-game verification, naming the console command (`!nys_diag`,
`!nys_rename`, ...) the user should run.

## 9. Publish - do not strand the scrutiny locally

- **PR target:** if you made code or message changes, commit them by invoking
  the `commit` skill (mandatory `Co-authored-by` trailer). Push a new patchset
  only when there is something to push - you committed edits, or the rebase
  advanced the branch past its old remote tip
  (`git rev-parse HEAD` differs from `origin/<headRefName>`). If the code was
  already clean AND already current, do NOT push a no-op patchset; report the
  code clean instead. To push, use the PR's own branch:
  `git push --force-with-lease origin HEAD:<headRefName>` (the `headRefName`
  from the `gh pr view --json` metadata). Use `--force-with-lease`, never plain
  `--force`, so a concurrent push by someone else aborts instead of being
  clobbered; never force-push `main`. Do this without being asked. Then
  `git checkout <original-branch>`, report the new patchset's commit hash and
  the force-push compare link, and confirm the PR reflects the scrutiny.
- **Commit on a branch:** amend the scrutinized commit (`git commit --amend`,
  keeping the message unless you corrected it) rather than stacking a follow-up,
  then `git push` (force-push, confirming with the user first, only if already
  pushed). Exception: if the commit is already merged into `origin/main`
  (`git merge-base --is-ancestor <hash> origin/main` after `git fetch origin`),
  do NOT amend - tell the user and offer either a history-rewriting force-push or
  a dedicated follow-up commit.
- **Working changes (empty argument):** leave them staged/unstaged as you found
  them; do not commit unless asked.

## Definition of done

Turn the applicable items into your `TodoWrite` list at the start; each must
carry the stated evidence before you check it. Do not report success with any
applicable box unchecked.

- [ ] Target resolved and `git fetch origin` run. Evidence: which of the four
      cases, and the diff obtained.
- [ ] (PR/branch) PR head checked out DETACHED here and rebased onto
      `origin/<baseRefName>`. Evidence: rebase clean or conflicts resolved.
- [ ] Full diff, linked issue, and existing discussion read; best practices
      researched.
- [ ] (PR) Every unresolved thread replied to AND resolved via the `github-pr`
      skill. Evidence: count of threads closed (state 0 if there were none).
- [ ] Correctness judged on all four points in section 5. Evidence: one line
      each, or "n/a - change does not touch it".
- [ ] Every added character challenged; unneeded code removed, rest simplified.
      Evidence: the per-edit verdicts.
- [ ] Comments and docstring prose cut to the strict standard - every narrating
      or paraphrasing comment removed, only code-cannot-tell explanations kept;
      ASCII punctuation enforced. Evidence: what was cut, or "none to cut".
- [ ] Commit message checked against the `commit` skill and fixed if needed.
- [ ] Verification done: `./make.ps1 all` run or each gate reasoned through;
      in-game checks named.
- [ ] Published: committed via the `commit` skill and, for a PR with something
      to push, force-with-lease pushed to `<headRefName>`, then returned to the
      original branch. Evidence: the new commit hash and PR compare link, or a
      stated "clean and current, nothing to push".
