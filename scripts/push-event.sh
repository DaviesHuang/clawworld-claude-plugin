#!/bin/bash
# ClawWorld — forward Claude Code hook event to backend
# Triggered by: SessionStart, SessionEnd, UserPromptSubmit, Stop, StopFailure

set -euo pipefail

LOG_FILE="$(dirname "$0")/push-event.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

EVENT_NAME="${CLAUDE_HOOK_EVENT_NAME:-}"
log "--- push-event started (event: ${EVENT_NAME:-unknown}) ---"

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then
  log "No python found — exiting"
  exit 0
fi

INPUT=$(cat)
log "Raw input: $INPUT"

CONFIG_VALUES=$($PYTHON -c "
import json, os
p = os.path.expanduser('~/.clawworld/config.json')
try:
    c = json.load(open(p))
except Exception:
    c = {}
print(c.get('endpoint') or os.environ.get('CLAWWORLD_ENDPOINT') or 'https://api.claw-world.app')
print(c.get('deviceToken') or os.environ.get('CLAWWORLD_TOKEN') or '')
print(c.get('lobsterId') or os.environ.get('CLAWWORLD_LOBSTER_ID') or '')
print(c.get('instanceId') or os.environ.get('CLAWWORLD_INSTANCE_ID') or '')
" 2>/dev/null || true)
ENDPOINT=$(echo "$CONFIG_VALUES" | sed -n '1p')
TOKEN=$(echo "$CONFIG_VALUES" | sed -n '2p')
LOBSTER_ID=$(echo "$CONFIG_VALUES" | sed -n '3p')
INSTANCE_ID=$(echo "$CONFIG_VALUES" | sed -n '4p')

if [ -z "$TOKEN" ] || [ -z "$LOBSTER_ID" ]; then
  log "Missing credentials (TOKEN=${TOKEN:+set}, LOBSTER_ID=${LOBSTER_ID:+set}) — exiting"
  exit 0
fi

PAYLOAD=$(printf '%s' "$INPUT" | "$PYTHON" -c "
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
event_name = os.environ.get('CLAUDE_HOOK_EVENT_NAME') or d.get('hook_event_name') or d.get('event_name') or ''
if event_name:
    d['hook_event_name'] = event_name
instance_id = sys.argv[1]
if instance_id:
    d['instance_id'] = instance_id
print(json.dumps(d))
" "$INSTANCE_ID" 2>/dev/null || echo "{}")
log "Payload: $PAYLOAD"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${ENDPOINT:-https://api.claw-world.app}/api/claude-code/event" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Lobster-Id: $LOBSTER_ID" \
  -H "Content-Type: application/json" \
  --max-time 5 \
  -d "$PAYLOAD" 2>/dev/null || true)
log "HTTP response: $HTTP_CODE"

exit 0
