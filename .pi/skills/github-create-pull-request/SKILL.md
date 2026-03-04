---
name: github-create-pull-request
description: Create a GitHub pull request via the pi-agent-github-create-pull-request Lambda. Use this when you need to open a PR between two branches in a GitHub repository. The GitHub token is managed by AWS Secrets Manager.
---

# GitHub: Create Pull Request

Creates a GitHub pull request via the `pi-agent-github-create-pull-request` Lambda.
The GitHub token is stored in AWS Secrets Manager and is **never visible to you** — the Lambda reads it directly.

## Input parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `owner` | yes | — | GitHub organisation or user (e.g. `myorg`) |
| `repo` | yes | — | Repository name (e.g. `myrepo`) |
| `title` | yes | — | PR title |
| `head` | yes | — | Source branch to merge from |
| `base` | no | `main` | Target branch to merge into |
| `body` | no | `""` | PR description (markdown supported) |

## Example

```bash
aws lambda invoke \
  --function-name pi-agent-github-create-pull-request \
  --payload '{"owner":"myorg","repo":"myrepo","title":"Fix auth bug","head":"fix/auth","base":"main","body":"Fixes the login flow."}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda-response.json && cat /tmp/lambda-response.json
```

A successful response looks like:
```json
{"status": "success", "pr_url": "https://github.com/myorg/myrepo/pull/42", "pr_number": 42}
```
