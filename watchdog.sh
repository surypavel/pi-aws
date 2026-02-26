#!/bin/bash
# Watchdog: shuts down the container after IDLE_TIMEOUT minutes of no pi/node activity.
# A grace period allows time to connect and start the agent.

IDLE_TIMEOUT=${IDLE_TIMEOUT:-10}
GRACE_PERIOD=${GRACE_PERIOD:-30}

idle_minutes=0

sleep "$((GRACE_PERIOD * 60))" &
GRACE_PID=$!

# Wait for grace period before starting checks
wait $GRACE_PID

while true; do
  if pgrep -x "pi|node" > /dev/null; then
    idle_minutes=0
  else
    idle_minutes=$((idle_minutes + 1))
    if [ "$idle_minutes" -ge "$IDLE_TIMEOUT" ]; then
      echo "No activity for $IDLE_TIMEOUT minutes. Shutting down."
      exit 0
    fi
  fi
  sleep 60
done
