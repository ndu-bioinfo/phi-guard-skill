#!/bin/bash
# PHI Safety — UserPromptSubmit scanner
# BLOCKS prompts containing high-confidence PHI patterns. The prompt is NOT
# forwarded to the LLM. User must confirm the data is non-PHI (e.g. synthetic
# test data) by including the bypass token [PHI-OK] in a re-submitted prompt.
#
# Output on match: JSON with decision=block → Claude Code suppresses prompt
# No output = no match = normal submission.

set -euo pipefail

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null) || prompt=""

# Skip short prompts (commands, quick questions — not pasted data)
if [ ${#prompt} -lt 20 ]; then
  exit 0
fi

# ── Bypass token ────────────────────────────────────────────────────
# User confirms the data is synthetic / non-PHI by including [PHI-OK]
# anywhere in the prompt. Hook becomes a no-op in that case.
if printf '%s\n' "$prompt" | grep -qF '[PHI-OK]'; then
  exit 0
fi

warnings=()

# ── SSN pattern: XXX-XX-XXXX (3-2-4 digits) ────────────────────────
if printf '%s\n' "$prompt" | grep -qiE '(ssn|social.security)[[:space:]:=#]*[0-9]{3}-[0-9]{2}-[0-9]{4}'; then
  warnings+=("Labeled Social Security Number (XXX-XX-XXXX)")
elif printf '%s\n' "$prompt" | grep -qE '(^|[^0-9A-Za-z._-])[0-9]{3}-[0-9]{2}-[0-9]{4}([^0-9A-Za-z._-]|$)'; then
  if printf '%s\n' "$prompt" | grep -qiE '(^|[^a-zA-Z0-9])(patient|clinical|medical|hipaa|phi|diagnosis|dob|mrn)([^a-zA-Z0-9]|$)'; then
    warnings+=("Possible Social Security Number pattern in clinical context (XXX-XX-XXXX)")
  fi
fi

# ── Explicitly labeled MRN / Patient ID ─────────────────────────────
if printf '%s\n' "$prompt" | grep -qiE '(MRN|medical.record.number|patient.id|patient.identifier)[[:space:]:=#]+[A-Z0-9-]+'; then
  warnings+=("Labeled Medical Record Number / Patient ID")
fi

# ── Explicitly labeled DOB (with or without :/=/# separator) ────────
# "DOB: 03/15/1985", "DOB 03/15/1985", "date_of_birth = 1985-03-15"
if printf '%s\n' "$prompt" | grep -qiE '(DOB|date.of.birth)[[:space:]:=#]+[0-9]{1,4}[/-][0-9]{1,2}[/-][0-9]{2,4}'; then
  warnings+=("Labeled Date of Birth")
fi

# ── Labeled accession number ────────────────────────────────────────
if printf '%s\n' "$prompt" | grep -qiE '(accession|specimen)[[:space:]:=#]*([A-Z]{2,5}-?)?[0-9]{4,}'; then
  warnings+=("Labeled accession/specimen number (HIPAA identifier #18)")
fi

# ── Labeled health plan / account numbers ──────────────────────────
if printf '%s\n' "$prompt" | grep -qiE '(health.plan|beneficiary|insurance.id|policy.number|member.id)[[:space:]:=#]+[A-Z0-9-]+'; then
  warnings+=("Labeled health plan / beneficiary number")
fi

# ── Name + Date proximity (e.g. "Jane Smith DOB 03/29/1988") ────────
# Two capitalized words (proper name) within 30 chars of a date pattern.
if printf '%s\n' "$prompt" | grep -qE '[A-Z][a-z]+[[:space:]]+[A-Z][a-z]+[[:space:]].{0,30}[0-9]{1,4}[/-][0-9]{1,2}[/-][0-9]{2,4}'; then
  warnings+=("Possible patient name adjacent to a date of birth")
fi

# ── Tabular data with PHI column headers ────────────────────────────
if printf '%s\n' "$prompt" | grep -qiE '(^|[^a-zA-Z0-9_])(patient_name|date_of_birth|ssn|social_security|medical_record_number|mrn|diagnosis|dob|accession_num|health_plan|beneficiary)([^a-zA-Z0-9_]|$)'; then
  if printf '%s\n' "$prompt" | grep -qE '(\|[[:space:]]*[^\|]+[[:space:]]*\||\t[^\t]+\t)'; then
    warnings+=("Tabular data with PHI-indicative column headers")
  fi
fi

# ── Multi-line pasted records with clinical markers ─────────────────
if printf '%s\n' "$prompt" | grep -qiE '(^|[^a-zA-Z0-9])(patient|clinical|specimen|sample|accession)([^a-zA-Z0-9]|$)'; then
  line_count=$(printf '%s\n' "$prompt" | wc -l | tr -d ' ')
  if [ "$line_count" -gt 4 ]; then
    date_lines=$(printf '%s\n' "$prompt" | grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    if [ "$date_lines" -gt 3 ]; then
      warnings+=("Multi-line data with clinical context and repeated date patterns")
    fi
  fi
fi

# ── BLOCK if any patterns matched ───────────────────────────────────
if [ ${#warnings[@]} -gt 0 ]; then
  detail=""
  for w in "${warnings[@]}"; do
    detail+="  - ${w}
"
  done

  reason=$(printf 'PHI Safety: Your prompt was BLOCKED and was NOT sent to the LLM.\n\nDetected patterns:\n%s\nData in this prompt would be transmitted to the external LLM API.\n\nIf this is synthetic / test data and you want to proceed, re-submit the prompt with the token [PHI-OK] included anywhere in the message.\nOtherwise, rephrase without PHI (remove names, dates of birth, MRNs, SSNs, accession numbers, etc.).' "$detail")

  jq -n --arg reason "$reason" '{
    "decision": "block",
    "reason": $reason,
    "hookSpecificOutput": {
      "hookEventName": "UserPromptSubmit",
      "additionalContext": "PHI scanner blocked the prior submission. Do not attempt to recall or reconstruct its contents."
    }
  }'
  exit 0
fi
