---
name: github-pr
description: Create a GitHub pull request, or work on an existing one - address review comments, push updates, reply to and resolve each unresolved thread.
---

# GitHub Pull Requests

Use this skill to **create** a new PR or to **respond to review feedback** on
an existing one.

## Creating a PR

Create PRs from the commit message - do not re-author the prose in the PR
form:

```sh
gh pr create --fill
```

`--fill` uses the most recent commit's subject as the PR title and its body as
the PR description, so a well-formed commit (see
[`../commit/SKILL.md`](../commit/SKILL.md)) produces a well-formed PR
automatically.

### PR description format (the mandated layout)

Because `--fill` derives them from the commit, a PR's title and description are
held to the SAME bar as the commit message. A well-formed PR has:

- **Title** = the commit subject rules from
  [`../commit/SKILL.md`](../commit/SKILL.md): imperative mood, first word
  capitalized, optional lowercase scope prefix, no trailing period, no PR number
  appended (squash-merge adds that), under ~72 chars.
- **Description** = the commit body: wrapped prose explaining WHY the change is
  made and, when relevant, the observable in-game effect and how it was verified
  in game (or the console command a reviewer should run) - not how, which the
  diff shows. A docs/CI/internal change has no in-game effect to note (see
  `CONTRIBUTING.md`). ASCII punctuation only. It should match the commit body it
  was filled from; note any drift.
- **News fragment**: the PR must add a `news/<id>.<type>.md` fragment (type one
  of `feature`, `bugfix`, `security`, `deprecation`, `removal`) OR carry the
  `no-news-fragment-needed` label, or the `news-fragment-check` workflow fails
  it. This is part of a well-formed PR's contents.

When a PR has drifted from this - edited on GitHub, stale after later commits,
missing the verification note or the news fragment - bring it back into line:

```sh
gh pr edit <N> --title '<subject>' --body '<body>'
gh pr edit <N> --add-label no-news-fragment-needed   # when the label is right
```

## Addressing review feedback on an existing PR

Use this whenever you are asked to address feedback, update a PR, or "handle
the review comments".

### Core rules

- **Reply to every unresolved review comment** - even when the fix is "done in
  commit abc123". Never leave a thread silently addressed.
- **Resolve each thread only after** (a) the fix is pushed and (b) a reply has
  been posted.
- **Push to update the PR.** Local commits alone do not count.
- No force-push to `main`. No `--no-verify`. No `git commit --amend` to rewrite
  commits that have already been pushed for review.
- Exception - the sanctioned rebase patchset: rebasing the PR's OWN branch onto
  its base branch (`origin/<baseRefName>`, not a hardcoded `origin/main`) and
  `--force-with-lease` pushing it (the Gerrit "new patchset" flow the
  [`../scrutinize/SKILL.md`](../scrutinize/SKILL.md) skill performs) IS allowed,
  because GitHub records it as a visible force-push event with a compare link.
  Still never force-push `main`, never plain `--force`, and never force-push to
  hide review history.
- Commit changes per [`../commit/SKILL.md`](../commit/SKILL.md) - including the
  mandatory `Co-authored-by:` trailer.

### Workflow (run these commands; substitute the placeholders in `<>`)

#### 1. Discover PR context

```sh
gh repo view --json owner --jq .owner.login   # <OWNER>
gh repo view --json name --jq .name           # <REPO>
gh pr view --json number --jq .number         # <N> for the current branch

# Or, if the PR number N was given explicitly, check it out:
gh pr checkout <N>
```

#### 2. List every unresolved review thread

The REST endpoint `/pulls/:n/comments` does **not** expose thread resolution
state. Always use GraphQL:

```sh
gh api graphql -f query='
  query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$number){
        reviewThreads(first:100){
          nodes{
            id isResolved isOutdated
            comments(first:50){
              nodes{ id databaseId author{login} path line body }
            }
          }
        }
      }
    }
  }' -F owner=<OWNER> -F name=<REPO> -F number=<N>
```

Filter client-side to `isResolved == false`. From each unresolved thread you
need:

- the thread `id` (GraphQL node id) -> used to **resolve** the thread in step 5.
- the `databaseId` of the **first** comment in the thread -> used to **reply**
  to the thread in step 4.

#### 3. Make the code changes, commit, push

Commit per [`../commit/SKILL.md`](../commit/SKILL.md). Then push:

```sh
git push                                           # already-tracked branch
git push -u origin "$(git branch --show-current)"  # first push of a new branch
```

Capture the commit SHA (`git rev-parse HEAD`) to reference in your replies.

#### 4. Reply to each unresolved thread

Reply to the **first** comment in the thread (its `databaseId` from step 2).
GitHub threads your reply underneath automatically:

```sh
gh api --method POST \
  repos/<OWNER>/<REPO>/pulls/<N>/comments/<COMMENT_DATABASE_ID>/replies \
  -f body='Fixed in <SHA>. <optional short explanation>.'
```

Do **not** use `gh pr comment` - that posts a top-level PR comment, which does
not count as answering the review thread.

#### 5. Resolve each thread

Use the thread node `id` from step 2 (the GraphQL `id`, **not** `databaseId`):

```sh
gh api graphql -f query='
  mutation($threadId:ID!){
    resolveReviewThread(input:{threadId:$threadId}){
      thread{ id isResolved }
    }
  }' -F threadId=<THREAD_NODE_ID>
```

The mutation returns `isResolved: true` on success.

#### 6. Verify

Re-run the step-2 query. Every thread you addressed should now have
`isResolved: true`. Any that remain unresolved either still need a fix or were
intentionally deferred - never silently skip one.

### Anti-patterns

- Posting a top-level PR comment (`gh pr comment`) instead of threading the
  reply on the review comment.
- Resolving without replying, or replying without resolving.
- Pushing before committing per [`../commit/SKILL.md`](../commit/SKILL.md)
  (skips the mandatory `Co-authored-by:` trailer).
- Force-pushing to "clean up history" mid-review (distinct from the sanctioned
  rebase patchset above), or force-pushing `main`.
- Using `--amend` on commits that have already been pushed.
