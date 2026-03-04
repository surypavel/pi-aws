---
name: coin-toss
description: Verify the Lambda connection is working. Invokes the pi-agent-coin-toss Lambda and returns heads or tails. No side effects, no secrets required.
---

# Coin Toss

Use this to verify your Lambda connection is working. No side effects, no secrets required.

```bash
aws lambda invoke \
  --function-name pi-agent-coin-toss \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda-response.json && cat /tmp/lambda-response.json
```

Returns either `{"result": "heads"}` or `{"result": "tails"}`.
