#!/bin/bash
# PHI Safety — PreToolUse guard for Bash commands.
# Detects database client and dump/restore tool invocations whose output
# would enter the LLM context (transmitted to Anthropic's API). If the
# target database contains PHI, this data must not be sent.
#
# Scope: PHI exposure prevention only. Destructive operations (DROP, DELETE,
# rm -rf, terraform destroy, etc.) are intentionally out of scope — this
# plugin focuses on preventing Protected Health Information from entering
# the AI context, not on general operational safety.
#
# Returns hookSpecificOutput with permissionDecision for Claude Code.

set -euo pipefail

input=$(cat)
command=$(printf '%s\n' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || command=""

# ── Database client / dump tool detection ──────────────────────────
# Any of these tools can stream query results or full table dumps into
# the LLM context. If the database contains PHI (patient names, SSNs,
# MRNs, DOBs, etc.), this would violate HIPAA — no BAA is in place
# with Anthropic.
#
# Includes:
#   - Interactive clients: psql, pgcli, mysql, mariadb, mongo, mongosh,
#     redis-cli, sqlite3, duckdb, snowsql, sqlcmd, bq,
#     clickhouse-client, cqlsh
#   - Dump/restore utilities: pg_dump, pg_restore, mysqldump,
#     mysqlpump, mongodump, mongorestore
#
# The pattern matches any DB client appearing as a standalone word
# (preceded by a non-identifier character or start-of-string, followed
# by whitespace or end-of-string). This covers all invocation styles:
# bare, env-prefixed, sudo-prefixed, subshell captures, full-path,
# after shell keywords (do/then), and after any shell operator.
#
# All patterns are POSIX ERE compliant (no \b or \s) for macOS
# BSD grep compatibility.
DB_CLIENTS='psql|pgcli|mysql|mariadb|mongo|mongosh|redis-cli|sqlite3|duckdb|snowsql|sqlcmd|bq|clickhouse-client|cqlsh|pg_dump|pg_restore|mysqldump|mysqlpump|mongodump|mongorestore'
if printf '%s\n' "$command" | grep -qiE "(^|[^a-zA-Z0-9_])(${DB_CLIENTS})([[:space:]]|$)"; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": "PHI Safety: Database client or dump tool detected. Query results will enter the LLM context (transmitted to Anthropic API, no BAA in place). If this database contains PHI or patient data, DENY this action and generate the query for the user to run in their own terminal instead. If this is confirmed non-PHI data, you may proceed."
    }
  }'
  exit 0
fi

exit 0
