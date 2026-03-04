"""
Unit tests for lambda/api handlers.
Run with: pytest tests/test_lambdas.py
"""
import json
import os
import sys
import unittest
from datetime import datetime, timezone
from unittest.mock import MagicMock

# Set required env vars before importing handlers (they read os.environ at module load)
os.environ.update({
    "ECS_CLUSTER":         "test-cluster",
    "ECS_TASK_DEFINITION": "test-task",
    "ECS_CONTAINER_NAME":  "pi-agent",
    "ECS_SUBNETS":         "subnet-123",
    "ECS_SECURITY_GROUP":  "sg-456",
    "LOG_GROUP":           "/ecs/test",
})

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "api"))

import logs as logs_mod
import start as start_mod
import stop as stop_mod
import tasks as tasks_mod


def _body(resp):
    return json.loads(resp["body"])


# ---------------------------------------------------------------------------
# start.py
# ---------------------------------------------------------------------------

class TestStart(unittest.TestCase):

    def setUp(self):
        start_mod.ecs = MagicMock()

    def test_missing_prompt_returns_400(self):
        for body in ("{}", '{"prompt": ""}', '{"prompt": "  "}', "null", ""):
            with self.subTest(body=body):
                resp = start_mod.handler({"body": body}, None)
                self.assertEqual(resp["statusCode"], 400)
                self.assertIn("error", _body(resp))

    def test_success_extracts_task_id_and_log_stream(self):
        start_mod.ecs.run_task.return_value = {
            "tasks": [{"taskArn": "arn:aws:ecs:eu-central-1:123:task/cluster/abc123def456"}],
            "failures": [],
        }
        resp = start_mod.handler({"body": '{"prompt": "Fix the auth bug"}'}, None)
        self.assertEqual(resp["statusCode"], 200)
        body = _body(resp)
        self.assertEqual(body["taskId"], "abc123def456")
        self.assertEqual(body["logStream"], "pi/pi-agent/abc123def456")

    def test_ecs_failure_returns_500(self):
        start_mod.ecs.run_task.return_value = {
            "tasks": [],
            "failures": [{"reason": "No capacity available"}],
        }
        resp = start_mod.handler({"body": '{"prompt": "Fix bug"}'}, None)
        self.assertEqual(resp["statusCode"], 500)
        self.assertIn("No capacity", _body(resp)["error"])


# ---------------------------------------------------------------------------
# tasks.py
# ---------------------------------------------------------------------------

class TestTasks(unittest.TestCase):

    def setUp(self):
        tasks_mod.ecs = MagicMock()

    def test_no_tasks_returns_empty_list(self):
        tasks_mod.ecs.list_tasks.return_value = {"taskArns": []}
        resp = tasks_mod.handler({}, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(_body(resp)["tasks"], [])

    def test_prompt_extracted_from_overrides(self):
        tasks_mod.ecs.list_tasks.side_effect = [
            {"taskArns": ["arn:aws:ecs:eu-central-1:123:task/cluster/task1"]},  # RUNNING
            {"taskArns": []},  # STOPPED
        ]
        tasks_mod.ecs.describe_tasks.return_value = {"tasks": [{
            "taskArn": "arn:aws:ecs:eu-central-1:123:task/cluster/task1",
            "lastStatus": "RUNNING",
            "startedAt": datetime(2024, 1, 15, 10, 30, 0, tzinfo=timezone.utc),
            "overrides": {"containerOverrides": [{
                "name": "pi-agent",
                "environment": [{"name": "PROMPT", "value": "Fix the auth bug"}],
            }]},
        }]}
        resp = tasks_mod.handler({}, None)
        self.assertEqual(resp["statusCode"], 200)
        tasks = _body(resp)["tasks"]
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]["taskId"], "task1")
        self.assertEqual(tasks[0]["status"], "RUNNING")
        self.assertEqual(tasks[0]["prompt"], "Fix the auth bug")
        self.assertIsNotNone(tasks[0]["startedAt"])

    def test_running_tasks_sorted_first(self):
        tasks_mod.ecs.list_tasks.side_effect = [
            {"taskArns": ["arn:aws:ecs:eu-central-1:123:task/c/running1"]},   # RUNNING
            {"taskArns": ["arn:aws:ecs:eu-central-1:123:task/c/stopped1"]},   # STOPPED
        ]
        tasks_mod.ecs.describe_tasks.return_value = {"tasks": [
            {
                "taskArn": "arn:aws:ecs:eu-central-1:123:task/c/stopped1",
                "lastStatus": "STOPPED",
                "startedAt": datetime(2024, 1, 14, 9, 0, 0, tzinfo=timezone.utc),
                "overrides": {"containerOverrides": []},
            },
            {
                "taskArn": "arn:aws:ecs:eu-central-1:123:task/c/running1",
                "lastStatus": "RUNNING",
                "startedAt": datetime(2024, 1, 15, 10, 0, 0, tzinfo=timezone.utc),
                "overrides": {"containerOverrides": []},
            },
        ]}
        tasks = _body(tasks_mod.handler({}, None))["tasks"]
        self.assertEqual(tasks[0]["status"], "RUNNING")
        self.assertEqual(tasks[1]["status"], "STOPPED")


# ---------------------------------------------------------------------------
# logs.py
# ---------------------------------------------------------------------------

class TestLogs(unittest.TestCase):

    def setUp(self):
        logs_mod.ecs = MagicMock()
        logs_mod.logs = MagicMock()

    def _event(self, task_id, next_token=None):
        return {
            "pathParameters": {"taskId": task_id},
            "queryStringParameters": {"nextToken": next_token} if next_token else None,
        }

    def test_returns_lines_and_next_token(self):
        logs_mod.ecs.describe_tasks.return_value = {
            "tasks": [{"lastStatus": "RUNNING"}]
        }
        logs_mod.logs.get_log_events.return_value = {
            "events": [{"message": "line 1"}, {"message": "line 2"}],
            "nextForwardToken": "token-abc",
        }
        resp = logs_mod.handler(self._event("task1"), None)
        self.assertEqual(resp["statusCode"], 200)
        body = _body(resp)
        self.assertEqual(body["lines"], ["line 1", "line 2"])
        self.assertEqual(body["nextToken"], "token-abc")
        self.assertEqual(body["status"], "RUNNING")

    def test_missing_log_stream_returns_empty(self):
        from botocore.exceptions import ClientError
        logs_mod.ecs.describe_tasks.return_value = {"tasks": []}
        logs_mod.logs.get_log_events.side_effect = ClientError(
            {"Error": {"Code": "ResourceNotFoundException", "Message": "not found"}},
            "GetLogEvents",
        )
        resp = logs_mod.handler(self._event("nonexistent"), None)
        self.assertEqual(resp["statusCode"], 200)
        body = _body(resp)
        self.assertEqual(body["lines"], [])
        self.assertIsNone(body["nextToken"])
        self.assertEqual(body["status"], "STOPPED")

    def test_next_token_forwarded_in_request(self):
        logs_mod.ecs.describe_tasks.return_value = {"tasks": [{"lastStatus": "STOPPED"}]}
        logs_mod.logs.get_log_events.return_value = {
            "events": [],
            "nextForwardToken": "token-xyz",
        }
        logs_mod.handler(self._event("task1", next_token="token-xyz"), None)
        call_kwargs = logs_mod.logs.get_log_events.call_args[1]
        self.assertEqual(call_kwargs["nextToken"], "token-xyz")


# ---------------------------------------------------------------------------
# stop.py
# ---------------------------------------------------------------------------

class TestStop(unittest.TestCase):

    def setUp(self):
        stop_mod.ecs = MagicMock()

    def test_success(self):
        stop_mod.ecs.stop_task.return_value = {}
        resp = stop_mod.handler({"pathParameters": {"taskId": "task123"}}, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(_body(resp)["stopped"], "task123")
        stop_mod.ecs.stop_task.assert_called_once()

    def test_unknown_task_returns_404(self):
        from botocore.exceptions import ClientError
        stop_mod.ecs.stop_task.side_effect = ClientError(
            {"Error": {"Code": "InvalidParameterException", "Message": "not found"}},
            "StopTask",
        )
        resp = stop_mod.handler({"pathParameters": {"taskId": "bad-id"}}, None)
        self.assertEqual(resp["statusCode"], 404)


if __name__ == "__main__":
    unittest.main()
