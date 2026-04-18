#!/bin/bash
# PHI Safety — UserPromptSubmit scanner
# Warns (does NOT block) when user prompt contains high-confidence PHI patterns.
# Designed to minimize false positives — only fires on patterns that are
# very unlikely to appear in normal development work.
#
# Output: systemMessage (user-visible warning) + additionalContext (agent reminder)
# No output = no match = no interruption.

set -euo pipefail

prompt=$(jq -r '.prompt // ""' 2>/dev/null) || prompt=""

# Skip short prompts (commands, quick questions — not pasted data)
if [ ${#prompt} -lt 20 ]; then
  exit 0
fi

warnings=()

# ── SSN pattern: XXX-XX-XXXX (3-2-4 digits) ────────────────────────
# Requires either an explicit label (SSN, social security) nearby, OR
# the 3-2-4 pattern appearing alongside other clinical context.
# Bare 3-2-4 digits alone are too ambiguous (version tags, IDs).
if printf '%s\n' "$prompt" | grep -qiE '(ssn|social.security)[[:space:]]*[:=]?[[:space:]]*[0-9]{3}-[0-9]{2}-[0-9]{4}'; then
  warnings+=("Labeled Social Security Number (XXX-XX-XXXX)")
elif printf '%s\n' "$prompt" | grep -qE '(^|[^0-9A-Za-z._-])[0-9]{3}-[0-9]{2}-[0-9]{4}([^0-9A-Za-z._-]|$)'; then
  if printf '%s\n' "$prompt" | grep -qiE '(^|[^a-zA-Z0-9])(patient|clinical|medical|hipaa|phi|diagnosis|dob|mrn)([^a-zA-Z0-9]|$)'; then
    warnings+=("Possible Social Security Number pattern in clinical context (XXX-XX-XXXX)")
  fi
fi

# ── Explicitly labeled MRN / Patient ID ─────────────────────────────
# Only triggers when prefixed with a clinical label — won't match random IDs.
if printf '%s\n' "$prompt" | grep -qiE '(MRN|medical.record.number|patient.id|patient.identifier)[[:space:]]*[:=#][[:space:]]*[A-Z0-9-]+'; then
  warnings+=("Labeled Medical Record Number / Patient ID")
fi

# ── Explicitly labeled DOB ──────────────────────────────────────────
# "DOB: 03/15/1985" or "date_of_birth = 1985-03-15" — not bare dates.
if printf '%s\n' "$prompt" | grep -qiE '(DOB|date.of.birth)[[:space:]]*[:=#][[:space:]]*[0-9]{1,4}[/-][0-9]{1,2}[/-][0-9]{2,4}'; then
  warnings+=("Labeled Date of Birth")
fi

# ── Labeled accession number ────────────────────────────────────────
# Accession numbers are HIPAA identifier #18 ("any other unique identifying
# number or code"). Only trigger when explicitly labeled.
if printf '%s\n' "$prompt" | grep -qiE '(accession|specimen)[[:space:]]*[:=#]?[[:space:]]*([A-Z]{2,5}-?)?[0-9]{4,}'; then
  warnings+=("Labeled accession/specimen number (HIPAA identifier #18)")
fi

# ── Labeled health plan / account numbers ──────────────────────────
if printf '%s\n' "$prompt" | grep -qiE '(health.plan|beneficiary|insurance.id|policy.number|member.id)[[:space:]]*[:=#][[:space:]]*[A-Z0-9-]+'; then
  warnings+=("Labeled health plan / beneficiary number")
fi

# ── Tabular data with PHI column headers ────────────────────────────
# Catches pasted query results: requires BOTH clinical column names
# AND tabular formatting (pipes or tabs). Double signal = low false positive.
if printf '%s\n' "$prompt" | grep -qiE '(^|[^a-zA-Z0-9_])(patient_name|date_of_birth|ssn|social_security|medical_record_number|mrn|diagnosis|dob|accession_num|health_plan|beneficiary)([^a-zA-Z0-9_]|$)'; then
  if printf '%s\n' "$prompt" | grep -qE '(\|[[:space:]]*[^\|]+[[:space:]]*\||\t[^\t]+\t)'; then
    warnings+=("Tabular data with PHI-indicative column headers")
  fi
fi

# ── Multi-line pasted records with clinical markers ─────────────────
# Detects bulk-pasted rows: 4+ lines containing a mix of names and dates,
# suggesting patient record output. Requires clinical keyword nearby.
if printf '%s\n' "$prompt" | grep -qiE '(^|[^a-zA-Z0-9])(patient|clinical|specimen|sample|accession)([^a-zA-Z0-9]|$)'; then
  line_count=$(printf '%s\n' "$prompt" | wc -l | tr -d ' ')
  if [ "$line_count" -gt 4 ]; then
    # Check for repeating structured data (dates + IDs on multiple lines)
    date_lines=$(printf '%s\n' "$prompt" | grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    if [ "$date_lines" -gt 3 ]; then
      warnings+=("Multi-line data with clinical context and repeated date patterns")
    fi
  fi
fi

# ── Emit warning if any patterns matched ────────────────────────────
if [ ${#warnings[@]} -gt 0 ]; then
  detail=""
  for w in "${warnings[@]}"; do
    detail+="  - ${w}
"
  done

  user_msg=$(printf 'PHI Safety: Your prompt may contain Protected Health Information:\n%sData in this prompt is transmitted to Anthropic'\''s API (no BAA in place). Please verify no PHI is included before proceeding.' "$detail")

  agent_ctx="PHI SAFETY WARNING: The user's prompt triggered PHI pattern detection. Patterns found: $(printf '%s, ' "${warnings[@]}" | sed 's/, $//') Reminder: you must NOT process, repeat, summarize, or store any PHI data that may have been pasted. If the prompt contains actual patient data, inform the user and ask them to rephrase without PHI."

  jq -n --arg msg "$user_msg" --arg ctx "$agent_ctx" '{
    "systemMessage": $msg,
    "hookSpecificOutput": {
      "hookEventName": "UserPromptSubmit",
      "additionalContext": $ctx
    }
  }'
fi
