#!/bin/bash
# ClawWorld — push installed skills/MCPs to backend
# Triggered by: SessionStart, UserPromptSubmit

set -euo pipefail

LOG_FILE="$(dirname "$0")/push-skills.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log "--- push-skills started (event: ${CLAUDE_HOOK_EVENT_NAME:-unknown}) ---"

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
CWD=$(echo "$INPUT" | "$PYTHON" -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
log "session_id: $SESSION_ID"
log "cwd: $CWD"

# Deduplication: skip if already pushed for this session
SENTINEL_DIR="$HOME/.claude/tmp"
mkdir -p "$SENTINEL_DIR"
if [ -n "$SESSION_ID" ]; then
  if command -v sha256sum &>/dev/null; then
    SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
  else
    SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
  fi
  SENTINEL_FILE="$SENTINEL_DIR/${SESSION_HASH}.skills_pushed"

  # Save session hash so push-activity.sh can use it throughout the session
  echo "$SESSION_HASH" > "$SENTINEL_DIR/clawworld-session-id"
  log "Session hash saved: $SESSION_HASH"

  if [ -f "$SENTINEL_FILE" ]; then
    log "Already pushed for this session — exiting"
    exit 0
  fi
else
  SENTINEL_FILE=""
fi
log "Sentinel file: ${SENTINEL_FILE:-none}"

# Auth credentials from env (injected by Claude Code via allowedEnvVars)
TOKEN="${CLAWWORLD_TOKEN:-}"
LOBSTER_ID="${CLAWWORLD_LOBSTER_ID:-}"

if [ -z "$TOKEN" ] || [ -z "$LOBSTER_ID" ]; then
  log "Missing credentials (TOKEN=${TOKEN:+set}, LOBSTER_ID=${LOBSTER_ID:+set}) — exiting"
  exit 0
fi
log "Credentials present"

# --- Extract MCP servers ---
MCP_SERVERS=$("$PYTHON" -c "
import json, os, sys

servers = set()

# User scope: ~/.claude.json
claude_json = os.path.expanduser('~/.claude.json')
if os.path.exists(claude_json):
    try:
        d = json.load(open(claude_json))
        servers.update(d.get('mcpServers', {}).keys())
    except: pass

# Project scope: .mcp.json in cwd
cwd = sys.argv[1] if len(sys.argv) > 1 else ''
if cwd:
    mcp_json = os.path.join(cwd, '.mcp.json')
    if os.path.exists(mcp_json):
        try:
            d = json.load(open(mcp_json))
            servers.update(d.get('mcpServers', {}).keys())
        except: pass

print(json.dumps(sorted(servers)))
" "$CWD" 2>/dev/null || echo "[]")
log "MCP servers: $MCP_SERVERS"

# --- Extract installed skills ---
SKILLS=$("$PYTHON" -c "
import os, json, sys

skills = set()
home = os.path.expanduser('~')

# User skills: ~/.claude/skills/<skill-name>/
user_skills = os.path.join(home, '.claude', 'skills')
if os.path.isdir(user_skills):
    for name in os.listdir(user_skills):
        if os.path.isdir(os.path.join(user_skills, name)):
            skills.add(name)

# Project skills: .claude/skills/<skill-name>/
cwd = sys.argv[1] if len(sys.argv) > 1 else ''
if cwd:
    proj_skills = os.path.join(cwd, '.claude', 'skills')
    if os.path.isdir(proj_skills):
        for name in os.listdir(proj_skills):
            if os.path.isdir(os.path.join(proj_skills, name)):
                skills.add(name)

# Plugin-provided skills: ~/.claude/plugins/marketplaces/<m>/plugins/<p>/skills/
plugins_root = os.path.join(home, '.claude', 'plugins', 'marketplaces')
if os.path.isdir(plugins_root):
    for marketplace in os.listdir(plugins_root):
        for plugin_type in ['plugins', 'external_plugins']:
            plugins_dir = os.path.join(plugins_root, marketplace, plugin_type)
            if os.path.isdir(plugins_dir):
                for plugin_name in os.listdir(plugins_dir):
                    skills_dir = os.path.join(plugins_dir, plugin_name, 'skills')
                    if os.path.isdir(skills_dir):
                        skills.add(plugin_name)

print(json.dumps(sorted(skills)))
" "$CWD" 2>/dev/null || echo "[]")
log "Skills: $SKILLS"

# --- Build payload ---
PAYLOAD=$("$PYTHON" -c "
import json, sys
print(json.dumps({
    'hook_event_name': 'SkillsUpdate',
    'session_id': sys.argv[1],
    'mcp_servers': json.loads(sys.argv[2]),
    'skills': json.loads(sys.argv[3]),
}))
" "$SESSION_ID" "$MCP_SERVERS" "$SKILLS" 2>/dev/null)
log "Payload: $PAYLOAD"

# --- Push to backend ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${CLAWWORLD_ENDPOINT:-https://api.claw-world.app}/api/claude-code/event" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Lobster-Id: $LOBSTER_ID" \
  -H "Content-Type: application/json" \
  --max-time 5 \
  -d "$PAYLOAD" 2>/dev/null || true)
log "HTTP response: $HTTP_CODE"

# Mark sentinel on success (2xx) and clean up old sentinels
if [[ "$HTTP_CODE" =~ ^2 ]] && [ -n "$SENTINEL_FILE" ]; then
  touch "$SENTINEL_FILE"
  find "$SENTINEL_DIR" -name "*.skills_pushed" -mtime +1 -delete 2>/dev/null || true
  log "Sentinel written — done"
else
  log "Not marking sentinel (HTTP_CODE=$HTTP_CODE, SENTINEL_FILE=${SENTINEL_FILE:-none})"
fi

exit 0  # Always exit 0 — never block Claude Code
