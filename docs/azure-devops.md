# Running the BC PR Review engine on Azure DevOps

This repository was built for GitHub (Actions + GitHub REST API). The engine
itself — fetch/filter BCQuality, run the Copilot CLI over the diff, render
findings — is host-agnostic PowerShell. Only two layers are GitHub-specific:
the **CI orchestration** and the **PR comment API**. Both now have an Azure
DevOps path.

## What was added

| Piece | File | Notes |
| --- | --- | --- |
| Review-host abstraction | `agents/ALReviewAgent/scripts/providers/` | `GitHubProvider.ps1` (verbatim extraction of the old inline helpers) and `AzureDevOpsProvider.ps1` (PR threads API). Selected by `REVIEW_PROVIDER` (`github` default \| `azuredevops`). |
| Orchestrator hooks | `Invoke-CopilotPRReview.ps1` | Dot-sources the provider; `REVIEW_GIT_HOST` + provider-aware token for the PR-head fetch; Azure DevOps logging commands (`##vso[...]`); provider-aware `Assert-Config`. |
| Review pipeline | `azure-pipelines/bc-pr-review.yml` | Two stages = the GitHub review/publish job split. |
| Merge gate | `azure-pipelines/ci.yml` | PSScriptAnalyzer, 1:1 port of `.github/workflows/ci.yml`. |
| Version on merge | `azure-pipelines/version.yml` | Git-tag `X.Y.Z` port of `.github/workflows/version.yml`. |

The GitHub workflows under `.github/workflows/` are left in place and unchanged —
`REVIEW_PROVIDER` defaults to `github`, so existing behaviour is untouched.

## Provider contract

Every provider defines the same surface; nothing else in the orchestrator talks
to the review host:

| Function | GitHub | Azure DevOps |
| --- | --- | --- |
| `Get-ReviewComments` | `GET /pulls/{n}/comments` | threads **with** `threadContext.filePath` |
| `Get-IssueComments` | `GET /issues/{n}/comments` | threads **without** file context |
| `New-ReviewComment` | `POST /pulls/{n}/comments` | `POST /pullRequests/{id}/threads` with `threadContext` |
| `New-IssueComment` | `POST /issues/{n}/comments` | `POST /pullRequests/{id}/threads` |
| `Update-IssueComment` | `PATCH /issues/comments/{id}` | `PATCH /threads/{tid}/comments/{cid}` |
| `Get-PrFiles` | `GET /pulls/{n}/files` | `@()` — the diff is taken from the local checkout |

The Azure DevOps provider normalises threads into the same comment shape
(`.body .path .line .original_line .side .id`) the downstream dedup, iteration
and summary-upsert logic already expects. `.id` there is a composite
`"<threadId>.<commentId>"` string.

## Setup

1. **Variable group `bc-pr-review`:**
   - `COPILOT_GH_TOKEN` (secret) — a GitHub token with Copilot entitlement.
     GitHub Copilot Enterprise seats work; the token only authenticates the
     `@github/copilot` CLI and bills inference to your GitHub org. Moving CI to
     Azure DevOps does **not** remove this GitHub dependency.
   - `AZURE_DEVOPS_READ_TOKEN` (secret, optional) — see isolation note below.

2. **Permissions:** grant *"<Project> Build Service"* the **Contribute to pull
   requests** permission (Project Settings → Repositories → Security). For
   `version.yml` also grant **Create tag**.

3. **Branch policies:** add `bc-pr-review.yml` and `ci.yml` as **Build
   Validation** policies on your default branch. The `pr:` trigger key is
   ignored by Azure Repos — PR runs come from the policy.

4. **Enable `System.AccessToken`:** the Publish stage maps it explicitly
   (`env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)`); no project setting
   needed beyond the Build Service permission above.

## Security note — the read-only isolation is weaker on Azure DevOps

On GitHub the review job runs the model with a `contents:read` token and
literally cannot post. On Azure DevOps, `System.AccessToken` cannot be scoped
to read-only, so the review stage simply never maps it. For a private repo the
PR-head fetch still needs *a* credential:

- **Recommended:** create a dedicated **read-only PAT** (Code: Read) and put it
  in `AZURE_DEVOPS_READ_TOKEN`. The Review stage uses it; a successful
  prompt-injection then holds only read access.
- **Fallback:** if that variable is unset, the Review stage's fetch falls back
  to `System.AccessToken` — which *is* write-capable. Acceptable for a private
  trusted repo, not for forked/untrusted contributions.

## Environment variable mapping

| Engine env | GitHub Actions | Azure Pipelines |
| --- | --- | --- |
| `GITHUB_REPOSITORY` | `github.repository` | `$(Build.Repository.Name)` |
| `PR_NUMBER` | resolved from event | `$(System.PullRequest.PullRequestId)` |
| `PR_HEAD_SHA` | PR head | `$(System.PullRequest.SourceCommitId)` |
| `BASE_BRANCH` | PR base | `$(System.PullRequest.TargetBranchName)` |
| post token | `GITHUB_TOKEN` | `SYSTEM_ACCESSTOKEN` |
| Copilot CLI auth | `GH_TOKEN` | `GH_TOKEN` (= `COPILOT_GH_TOKEN`) |

## Not yet ported

- `.github/workflows/bcquality-uptake.yml` — opens a PR via `gh`. The Azure
  equivalent is `az repos pr create`; the BCQuality tag-resolution logic is
  host-agnostic and can be reused as-is.
- `Online Evals/` — GitHub-specific scoring pipeline, out of scope for review.
- Suggestion `commit_id` pinning: the Azure provider anchors threads by line
  only, not by iteration/commit. Re-anchoring across pushes relies on Azure
  DevOps' own line tracking.
