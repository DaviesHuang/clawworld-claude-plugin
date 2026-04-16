#!/bin/bash
# ClawWorld — push an activity summary to backend
# Called by Claude directly (not a hook): push-activity.sh "<summary>"

set -euo pipefail

LOG_FILE="$(dirname "$0")/push-activity.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log "--- push-activity started ---"

SUMMARY="${1:-}"
if [ -z "$SUMMARY" ]; then
  log "No summary provided — exiting"
  exit 0
fi
log "Summary: $SUMMARY"

# Resolve python — prefer python3, fall back to python
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then
  log "No python found — exiting"
  exit 0
fi
log "Python: $PYTHON"

# Auth credentials from env (injected by Claude Code via settings.json env)
TOKEN="${CLAWWORLD_TOKEN:-}"
LOBSTER_ID="${CLAWWORLD_LOBSTER_ID:-}"
INSTANCE_ID="${CLAWWORLD_INSTANCE_ID:-}"

if [ -z "$TOKEN" ] || [ -z "$LOBSTER_ID" ]; then
  log "Missing credentials (TOKEN=${TOKEN:+set}, LOBSTER_ID=${LOBSTER_ID:+set}) — exiting"
  exit 0
fi
log "Credentials present"

# Read session_key_hash written by push-skills.sh at SessionStart
SESSION_HASH_FILE="$HOME/.claude/tmp/clawworld-session-id"
SESSION_KEY_HASH=""
if [ -f "$SESSION_HASH_FILE" ]; then
  SESSION_KEY_HASH=$(cat "$SESSION_HASH_FILE" 2>/dev/null || echo "")
fi

# Fallback: derive from lobster_id + today's date
if [ -z "$SESSION_KEY_HASH" ]; then
  DATE=$(date '+%Y%m%d')
  if command -v sha256sum &>/dev/null; then
    SESSION_KEY_HASH=$(echo -n "${LOBSTER_ID}${DATE}" | sha256sum | cut -c1-16)
  else
    SESSION_KEY_HASH=$(echo -n "${LOBSTER_ID}${DATE}" | shasum -a 256 | cut -c1-16)
  fi
  log "Using fallback session_key_hash (date-based): $SESSION_KEY_HASH"
else
  log "session_key_hash: $SESSION_KEY_HASH"
fi

KIND="other"
ACTIVITY_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
log "activity_at: $ACTIVITY_AT"

# Build activity_id: sha256(lobster_id|activity_at|session_key_hash|kind|summary).slice(0, 32)
ACTIVITY_ID=$("$PYTHON" -c "
import hashlib, sys
raw = '|'.join([sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]])
print(hashlib.sha256(raw.encode()).hexdigest()[:32])
" "$LOBSTER_ID" "$ACTIVITY_AT" "$SESSION_KEY_HASH" "$KIND" "$SUMMARY" 2>/dev/null || echo "")

if [ -z "$ACTIVITY_ID" ]; then
  log "Failed to compute activity_id — exiting"
  exit 0
fi
log "activity_id: $ACTIVITY_ID"

# Build JSON payload
PAYLOAD=$("$PYTHON" -c "
import json, sys
d = {
    'lobster_id': sys.argv[1],
    'activity_at': sys.argv[2],
    'activity_id': sys.argv[3],
    'session_key_hash': sys.argv[4],
    'kind': sys.argv[5],
    'summary': sys.argv[6],
}
instance_id = sys.argv[7]
if instance_id:
    d['instance_id'] = instance_id
print(json.dumps(d))
" "$LOBSTER_ID" "$ACTIVITY_AT" "$ACTIVITY_ID" "$SESSION_KEY_HASH" "$KIND" "$SUMMARY" "$INSTANCE_ID" 2>/dev/null)
log "Payload: $PAYLOAD"

# Push to backend
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${CLAWWORLD_ENDPOINT:-https://api.claw-world.app}/api/claw/activity" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --max-time 5 \
  -d "$PAYLOAD" 2>/dev/null || true)
log "HTTP response: $HTTP_CODE"

exit 0  # Always exit 0 — never block Claude Code
