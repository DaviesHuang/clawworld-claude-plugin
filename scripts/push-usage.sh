#!/bin/bash
# ClawWorld — push Claude Code token usage to backend
# Triggered by: Stop
# Reads token usage from the session transcript JSONL (Stop events don't include usage in payload)

set -euo pipefail

LOG_FILE="$(dirname "$0")/push-usage.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log "--- push-usage started ---"

# Resolve python — prefer python3, fall back to python
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then
  log "No python found — exiting"
  exit 0
fi
log "Python: $PYTHON"

INPUT=$(cat)
log "Raw input: $INPUT"

SESSION_ID=$(echo "$INPUT" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(echo "$INPUT" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || echo "")
log "session_id: $SESSION_ID"
log "transcript_path: $TRANSCRIPT_PATH"

if [ -z "$TRANSCRIPT_PATH" ]; then
  log "No transcript_path — exiting"
  exit 0
fi

# Auth credentials: prefer v2 ~/.clawworld/config.json, fallback to legacy env
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
log "Credentials present (config/env source, instance_id=${INSTANCE_ID:-unset})"

# Sentinel: tracks last processed line count per session to compute deltas
SENTINEL_DIR="$HOME/.claude/tmp"
mkdir -p "$SENTINEL_DIR"
if [ -n "$SESSION_ID" ]; then
  if command -v sha256sum &>/dev/null; then
    SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
  else
    SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
  fi
  LINES_FILE="$SENTINEL_DIR/${SESSION_HASH}.usage_lines"
else
  LINES_FILE=""
fi
log "Lines sentinel: ${LINES_FILE:-none}"

# --- Parse transcript and compute token delta since last Stop ---
USAGE=$("$PYTHON" -c "
import json, os, sys

transcript_path = sys.argv[1]
lines_file = sys.argv[2] if len(sys.argv) > 2 else ''

# Read last processed line count
last_line = 0
if lines_file and os.path.exists(lines_file):
    try:
        last_line = int(open(lines_file).read().strip())
    except: pass

# Read transcript file
if not os.path.exists(transcript_path):
    print(json.dumps({'total_lines': 0, 'usage': None}))
    sys.exit(0)

with open(transcript_path, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

new_lines = lines[last_line:]
total_lines = len(lines)

# Parse assistant entries with usage where stop_reason is not null
# Deduplicate by message.id (streaming produces two entries per turn: partial + complete)
seen_ids = set()
usage_sum = {
    'input_tokens': 0,
    'output_tokens': 0,
    'cache_read_input_tokens': 0,
    'cache_creation_input_tokens': 0,
}
found_any = False
# Track the most recent model and provider seen in the new range, so we can
# report the model that's actually answering the user's prompts right now
# (covers mid-session model switches).
last_model = None
last_provider = None

for line in new_lines:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except:
        continue
    if entry.get('type') != 'assistant':
        continue
    msg = entry.get('message', {})
    usage = msg.get('usage')
    if not usage:
        continue
    # Skip partial streaming entries (stop_reason is null, output_tokens is 0)
    if msg.get('stop_reason') is None:
        continue
    msg_id = msg.get('id', '')
    if msg_id:
        if msg_id in seen_ids:
            continue
        seen_ids.add(msg_id)
    usage_sum['input_tokens']               += usage.get('input_tokens', 0)
    usage_sum['output_tokens']              += usage.get('output_tokens', 0)
    usage_sum['cache_read_input_tokens']    += usage.get('cache_read_input_tokens', 0)
    usage_sum['cache_creation_input_tokens'] += usage.get('cache_creation_input_tokens', 0)
    mdl = msg.get('model')
    if isinstance(mdl, str) and mdl:
        last_model = mdl
    prov = msg.get('provider')
    if isinstance(prov, str) and prov:
        last_provider = prov
    found_any = True

print(json.dumps({
    'total_lines': total_lines,
    'usage': usage_sum if found_any else None,
    'model': last_model,
    'provider': last_provider,
}))
" "$TRANSCRIPT_PATH" "${LINES_FILE:-}" 2>/dev/null || echo '{"total_lines":0,"usage":null}')

log "Usage result: $USAGE"

TOTAL_LINES=$(echo "$USAGE" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin).get('total_lines', 0))" 2>/dev/null || echo "0")
HAS_USAGE=$(echo "$USAGE" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('usage') else 'no')" 2>/dev/null || echo "no")

if [ "$HAS_USAGE" = "no" ]; then
  log "No new token usage found — updating line count and exiting"
  if [ -n "$LINES_FILE" ] && [ "$TOTAL_LINES" -gt 0 ]; then
    echo "$TOTAL_LINES" > "$LINES_FILE"
  fi
  exit 0
fi

# --- Build payload ---
# Pass model + provider through unchanged from the transcript so the backend
# can store the full model identifier (e.g. "claude-sonnet-4-5-20250929").
PAYLOAD=$(echo "$USAGE" | "$PYTHON" -c "
import json, sys
d = json.load(sys.stdin)
session_id = sys.argv[1]
payload = {
    'hook_event_name': 'Stop',
    'session_id': session_id,
    'usage': d['usage'],
}
if isinstance(d.get('model'), str) and d['model']:
    payload['model'] = d['model']
if isinstance(d.get('provider'), str) and d['provider']:
    payload['provider'] = d['provider']
print(json.dumps(payload))
" "$SESSION_ID" 2>/dev/null)
log "Payload: $PAYLOAD"

# --- Push to backend ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${ENDPOINT:-https://api.claw-world.app}/api/claude-code/event" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Lobster-Id: $LOBSTER_ID" \
  -H "Content-Type: application/json" \
  --max-time 5 \
  -d "$PAYLOAD" 2>/dev/null || true)
log "HTTP response: $HTTP_CODE"

# Update line count sentinel after successful push; clean up old sentinels
if [[ "$HTTP_CODE" =~ ^2 ]]; then
  if [ -n "$LINES_FILE" ]; then
    echo "$TOTAL_LINES" > "$LINES_FILE"
    find "$SENTINEL_DIR" -name "*.usage_lines" -mtime +1 -delete 2>/dev/null || true
    log "Line count updated to $TOTAL_LINES — done"
  fi
else
  log "Push failed (HTTP_CODE=$HTTP_CODE) — not updating line count"
fi

exit 0  # Always exit 0 — never block Claude Code
