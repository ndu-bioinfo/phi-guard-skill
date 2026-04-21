#!/bin/bash
# PHI Safety — UserPromptSubmit skill injector
# Checks if user prompt contains PHI/safety-related keywords and injects
# the SKILL.md content as additional context for the agent.
#
# Uses CLAUDE_PLUGIN_ROOT (set by Claude Code plugin loader) to find
# SKILL.md. Falls back to BASH_SOURCE for local development.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SKILL_PATH="${PLUGIN_ROOT}/skills/phi-safety/SKILL.md"

prompt=$(jq -r '.prompt // ""' 2>/dev/null) || prompt=""

# Bypass: user asserts prompt is synthetic/non-PHI with [PHI-OK] token.
# Skip skill injection entirely to reduce context noise.
if printf '%s\n' "$prompt" | grep -qF '[PHI-OK]'; then
  exit 0
fi

# Trigger on PHI-related keywords only. This is a context-injection trigger
# (loads SKILL.md into the agent), not an enforcement gate — false positives
# just add safety context, which is harmless.
# Scope: database tools (whose output may contain PHI), clinical/medical
# terminology, and HIPAA-related terms. Destructive ops (DROP, DELETE,
# terraform, rm -rf, etc.) are intentionally excluded — not PHI concerns.
if printf '%s\n' "$prompt" | grep -qiE 'psql|pgcli|mysql|mongo|redis-cli|sqlite3|duckdb|snowsql|database|query.*db|db.*query|pg_dump|mysqldump|mongodump|patient|clinical|accession|specimen|diagnosis|medical.record|mrn|hipaa|phi([^a-zA-Z0-9]|$)|protected.health|health.plan|beneficiary|date.of.birth|dob([^a-zA-Z0-9]|$)|ssn([^a-zA-Z0-9]|$)|social.security'; then
  if [ -f "$SKILL_PATH" ]; then
    jq -n --rawfile ctx "$SKILL_PATH" '{
      "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": $ctx
      }
    }'
  fi
fi
