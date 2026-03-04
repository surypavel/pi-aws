#!/bin/sh
if [ -n "$PROMPT" ]; then
  exec pi --print "$PROMPT" --no-session   # headless: exits when done
else
  exec /watchdog.sh                        # fallback: interactive via scripts/start-pi.sh
fi
