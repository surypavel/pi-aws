import json
import os
import urllib.error
import urllib.request

import boto3

GITHUB_TOKEN_SECRET_ARN = os.environ["GITHUB_TOKEN_SECRET_ARN"]

sm = boto3.client("secretsmanager")


def _get_token():
    return sm.get_secret_value(SecretId=GITHUB_TOKEN_SECRET_ARN)["SecretString"]


def handler(event, context):
    owner = event.get("owner")
    repo = event.get("repo")
    title = event.get("title")
    head = event.get("head")
    base = event.get("base", "main")
    body = event.get("body", "")

    if not all([owner, repo, title, head]):
        return {"status": "error", "message": "owner, repo, title, and head are required"}

    token = _get_token()

    payload = json.dumps({"title": title, "body": body, "head": head, "base": base}).encode()
    req = urllib.request.Request(
        f"https://api.github.com/repos/{owner}/{repo}/pulls",
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read())
            return {
                "status": "success",
                "pr_url": result["html_url"],
                "pr_number": result["number"],
            }
    except urllib.error.HTTPError as e:
        error_body = json.loads(e.read())
        return {"status": "error", "message": error_body.get("message", str(e))}
