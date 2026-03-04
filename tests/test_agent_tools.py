"""
Unit tests for lambda/agent tool handlers.
Run with: pytest tests/test_agent_tools.py
"""
import io
import json
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

os.environ.setdefault("GITHUB_TOKEN_SECRET_ARN", "arn:aws:secretsmanager:eu-central-1:123:secret:test")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "agent"))

import coin_toss
import github_create_pull_request as gh_mod


# ---------------------------------------------------------------------------
# coin_toss.py
# ---------------------------------------------------------------------------

class TestCoinToss(unittest.TestCase):

    def test_returns_heads_or_tails(self):
        resp = coin_toss.handler({}, None)
        self.assertIn(resp["result"], ("heads", "tails"))

    def test_returns_both_values_over_many_calls(self):
        results = {coin_toss.handler({}, None)["result"] for _ in range(100)}
        self.assertEqual(results, {"heads", "tails"})


# ---------------------------------------------------------------------------
# github_create_pull_request.py
# ---------------------------------------------------------------------------

class TestGitHubCreatePullRequest(unittest.TestCase):

    def setUp(self):
        gh_mod.sm = MagicMock()
        gh_mod.sm.get_secret_value.return_value = {"SecretString": "ghp_fake_token"}

    def _mock_urlopen(self, payload):
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(payload).encode()
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        return mock_resp

    def test_missing_required_fields_returns_error(self):
        for event in [{}, {"title": "My PR"}, {"owner": "org", "repo": "r", "title": "t"}]:
            with self.subTest(event=event):
                resp = gh_mod.handler(event, None)
                self.assertEqual(resp["status"], "error")
                self.assertIn("required", resp["message"])

    def test_success_returns_pr_url_and_number(self):
        mock_resp = self._mock_urlopen({"html_url": "https://github.com/org/repo/pull/42", "number": 42})
        with patch("urllib.request.urlopen", return_value=mock_resp):
            resp = gh_mod.handler(
                {"owner": "org", "repo": "repo", "title": "Fix bug", "head": "fix-branch"},
                None,
            )
        self.assertEqual(resp["status"], "success")
        self.assertEqual(resp["pr_url"], "https://github.com/org/repo/pull/42")
        self.assertEqual(resp["pr_number"], 42)

    def test_default_base_is_main(self):
        mock_resp = self._mock_urlopen({"html_url": "https://github.com/org/repo/pull/1", "number": 1})
        with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen:
            gh_mod.handler(
                {"owner": "org", "repo": "repo", "title": "t", "head": "branch"},
                None,
            )
        sent = json.loads(mock_urlopen.call_args[0][0].data)
        self.assertEqual(sent["base"], "main")

    def test_github_api_error_returns_error(self):
        import urllib.error
        error_body = json.dumps({"message": "Not Found"}).encode()
        with patch("urllib.request.urlopen", side_effect=urllib.error.HTTPError(
            url=None, code=404, msg="Not Found", hdrs=None, fp=io.BytesIO(error_body)
        )):
            resp = gh_mod.handler(
                {"owner": "org", "repo": "repo", "title": "t", "head": "branch"},
                None,
            )
        self.assertEqual(resp["status"], "error")
        self.assertIn("Not Found", resp["message"])

    def test_token_fetched_from_secrets_manager(self):
        mock_resp = self._mock_urlopen({"html_url": "https://github.com/org/repo/pull/1", "number": 1})
        with patch("urllib.request.urlopen", return_value=mock_resp):
            gh_mod.handler(
                {"owner": "org", "repo": "repo", "title": "t", "head": "branch"},
                None,
            )
        gh_mod.sm.get_secret_value.assert_called_once_with(
            SecretId="arn:aws:secretsmanager:eu-central-1:123:secret:test"
        )


if __name__ == "__main__":
    unittest.main()
