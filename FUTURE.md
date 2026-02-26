# Future Improvements

## Persistence (EFS)

Currently the Fargate container is fully ephemeral — conversations, cloned repos, and agent state in `/root/.pi` are lost when the task stops.

This can be solved by mounting an EFS (Elastic File System) volume at `/root/.pi`, so conversation history and agent config persist across task runs. EFS costs ~$0.30/GB/month and is natively supported by Fargate.

## Git Proxy Sidecar (Token Isolation)

Currently the agent would need direct access to GitLab/GitHub tokens to clone and push. To avoid exposing tokens to the agent, a sidecar proxy container can be added to the Fargate task:

- A lightweight HTTP proxy (nginx or a small app) runs as a second container in the same task
- The proxy fetches the GitLab/GitHub token from AWS Secrets Manager on startup
- Pi clones via `http://localhost:3000/org/repo.git` — no auth needed from its perspective
- The proxy forwards requests to `https://gitlab.com/org/repo.git` and injects the `Authorization` header
- The token never enters Pi's environment — it only exists in the sidecar

Fargate supports multiple containers per task natively, and sidecar containers share `localhost`.

The token used by the sidecar should be **scoped to only `read_repository` + `write_repository`** — enough to clone and push code, nothing else. All privileged API operations (creating MRs, posting comments, managing issues, triggering pipelines, Jira integration) go through the **Lambda**, which holds a broader token and controls the logic. This way, even if the agent is compromised, it can only push code — it can't merge, delete branches, change project settings, or touch Jira.
