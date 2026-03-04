---
name: github-create-pull-request
description: Create a GitHub pull request from local changes. Covers the full workflow — branch, commit, push, then open a PR via the pi-agent-github-create-pull-request Lambda. Use this when you have made changes to a checked-out repository and want to submit them for review. The GitHub token is managed by AWS Secrets Manager.
---

# GitHub: Create Pull Request

Full workflow for turning local changes into a GitHub pull request.

## Step 1 — Determine owner and repo

`owner` and `repo` come from the git remote URL of the checked-out repository:

```bash
git remote get-url origin
```

Typical outputs:

| Remote URL | owner | repo |
|---|---|---|
| `https://github.com/myorg/myrepo.git` | `myorg` | `myrepo` |
| `git@github.com:myorg/myrepo.git` | `myorg` | `myrepo` |

Parse owner and repo from the URL by splitting on `/` (HTTPS) or `:` then `/` (SSH), and stripping a trailing `.git`.

## Step 2 — Review the changes

```bash
git diff HEAD
git status
```

Read the diff carefully. Use it to write:
- **Branch name** — short, lowercase, hyphen-separated, describing the change (e.g. `fix/login-timeout`, `feat/export-csv`)
- **Commit message** — imperative, one-line summary (e.g. `Fix login timeout for SSO users`)
- **PR title** — same as or a polished version of the commit message
- **PR body** — markdown description: what changed and why, with bullet points for notable details

## Step 3 — Create a branch and commit

```bash
git checkout -b <branch-name>
git add -A
git commit -m "<commit message>"
```

## Step 4 — Push to remote

```bash
git push -u origin <branch-name>
```

## Step 5 — Open the pull request

```bash
aws lambda invoke \
  --function-name pi-agent-github-create-pull-request \
  --payload '{"owner":"<owner>","repo":"<repo>","title":"<PR title>","head":"<branch-name>","base":"main","body":"<PR body>"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda-response.json && cat /tmp/lambda-response.json
```

The GitHub token is stored in AWS Secrets Manager and is **never visible to you** — the Lambda reads it directly.

### Lambda parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `owner` | yes | — | GitHub organisation or user (from Step 1) |
| `repo` | yes | — | Repository name (from Step 1) |
| `title` | yes | — | PR title (from Step 2) |
| `head` | yes | — | Branch you just pushed (from Step 3) |
| `base` | no | `main` | Target branch to merge into |
| `body` | no | `""` | PR description in markdown (from Step 2) |

### Successful response

```json
{"status": "success", "pr_url": "https://github.com/myorg/myrepo/pull/42", "pr_number": 42}
```

Report the `pr_url` to the user when done.
