---
name: phi-safety
description: >
  PHI exposure prevention guardrails for Claude Code. Detects database client
  usage that could send Protected Health Information to the LLM API, scans
  prompts for PHI patterns, and provides HIPAA-aligned decision guidance.
triggers:
  - psql
  - mysql
  - mongo
  - database
  - patient
  - clinical
  - accession
  - phi
  - hipaa
  - pg_dump
  - mysqldump
  - mongodump
  - medical record
  - health plan
  - social security
---

# PHI Safety Guardrails

This skill prevents Protected Health Information (PHI) from entering the LLM
context, aligned with GeneDx's data classification and HIPAA compliance
requirements.

> **Scope:** PHI exposure prevention only. This plugin does NOT guard against
> destructive operations (DROP TABLE, rm -rf, terraform destroy, etc.) — those
> are separate operational safety concerns outside this plugin's responsibility.

> **BAA Status:** These rules assume **no Business Associate Agreement (BAA)**
> exists between GeneDx and the LLM provider (Anthropic). Any data entering the
> LLM context is transmitted to a third-party API outside GeneDx's control — a
> HIPAA compliance boundary. Once a BAA is executed with Anthropic, the database
> client detection rules should be revised to permit PHI in the LLM context
> under BAA terms.
>
> **Approved internal AI endpoints** (e.g., Azure OpenAI within GeneDx's
> firewall) are permitted for clinical data processing under existing policies.
> This skill governs only the boundary where data leaves the organization via
> external LLM APIs.

## Data Classification Alignment

| Classification | Description | LLM Policy |
|---------------|-------------|------------|
| **Restricted** | PHI, ePHI, PII — patient/customer data | **BLOCK** — must never enter external LLM context |
| **Confidential** | Employee data, financial data, internal operational data | **WARN** — confirm with user before processing |
| **Public** | Marketing materials, public disclosures, open-source code | **ALLOW** — safe to process |

### Zone Model

- **Zone A (Identifiable/Operational):** Patient/provider workflows, clinical
  databases with identifiable data. Data in this zone **must never be sent to
  external LLM APIs**.
- **Zone B (De-identified/Analytical):** Expert Determination de-identified data
  under HIPAA §164.514(b)(1). All 18 HIPAA identifiers removed or generalized.
  De-identified data may be processed after user confirmation.

### The 18 HIPAA Identifiers (must never enter LLM context)

1. Names
2. Geographic data (smaller than state)
3. Dates (except year) related to an individual
4. Phone numbers
5. Fax numbers
6. Email addresses
7. Social Security numbers
8. Medical record numbers (MRN)
9. Health plan beneficiary numbers
10. Account numbers
11. Certificate/license numbers
12. Vehicle identifiers and serial numbers
13. Device identifiers and serial numbers
14. Web URLs
15. IP addresses
16. Biometric identifiers
17. Full-face photographs
18. Any other unique identifying number or code (e.g., accession numbers)

## PHI Exposure Prevention

### Database Client Detection (Enforcement Layer)

Any database client or dump tool whose output would enter the LLM context
is flagged for user confirmation:

| Tool Category | Examples | Risk |
|---------------|----------|------|
| Interactive clients | `psql`, `pgcli`, `mysql`, `mongo`, `redis-cli`, `sqlite3`, `duckdb`, `snowsql`, `sqlcmd`, `bq`, `clickhouse-client`, `cqlsh` | Query results enter LLM context |
| Dump/restore tools | `pg_dump`, `mysqldump`, `mongodump`, `pg_restore`, `mongorestore` | Full table contents streamed to LLM |

**When detected:**
- If the database contains PHI → **DENY** and generate the query for the user
  to run in their own terminal
- If confirmed non-PHI (CI metrics, build stats, monitoring) → **ALLOW** after
  user confirmation

**What to do instead of executing PHI queries:**
```bash
# Generate the query, user runs in their own terminal:
psql service=<connection> -c "<GENERATED_SQL>"

# Or save as CSV:
psql service=<connection> --csv -o output.csv -c "<GENERATED_SQL>"
```

- If the user reports an error, they can paste the **error message** (not
  results) and you refine the query
- If the user asks you to interpret results, explain that you cannot see the
  data and guide them to inspect it themselves

### PHI in User Prompts (Detection Layer)

The prompt scanner detects high-confidence PHI patterns pasted into prompts:

| Pattern | Example |
|---------|---------|
| Labeled SSN | `SSN: 123-45-6789` |
| Labeled MRN / Patient ID | `MRN: ABC-12345` |
| Labeled Date of Birth | `DOB: 03/15/1985` |
| Accession/specimen numbers | `accession: LAB-20240001` |
| Health plan / beneficiary IDs | `member_id: H12345678` |
| Tabular data with PHI columns | `patient_name | dob | ssn` |
| Multi-line clinical data | Bulk-pasted records with dates and clinical keywords |

**When detected:** A warning is shown to the user, and a reminder is injected
into the agent context to not process, repeat, or summarize the PHI.

## Decision Flowchart

```
User prompt arrives
       |
       v
Does the prompt contain PHI patterns?
(SSN, MRN, DOB, accession numbers, patient data)
       |
   yes |                    no
       v                     |
  WARN user:                 v
  "PHI detected,        Does the action involve
  do not proceed"        a database client or dump tool?
                              |
                          yes |              no
                              v               |
                     Does the database         v
                     contain PHI?             ALLOW
                              |
                          yes |         no / confirmed non-PHI
                              v               |
                         BLOCK:               v
                         Generate query,     ALLOW
                         user runs it        (after confirmation)
                         themselves
```

## Non-PHI Database Access

Read-only queries against non-PHI data sources are **allowed after user
confirmation**:

- CI/CD metrics databases
- Build/deployment status stores
- Infrastructure monitoring (Prometheus, Grafana backends)
- Application configuration stores
- Schema-only queries (`\dt`, `SHOW TABLES`, `DESCRIBE`)

**Schema is safe, data is not.** Table structures, column names, and types are
fine. Row data may contain PHI.

## Environment Awareness

When the target environment is ambiguous, **default to the most restrictive
treatment** (assume PHI-containing production database).

Detection order:
1. Explicit environment variable (`$CLAUDE_ENV`, `$ENVIRONMENT`)
2. Database connection string or hostname clues (`prod`, `staging`, `dev`)
3. Command arguments (e.g., `--context production`)
4. If unknown → **assume production with PHI**

## Key Principles

1. **When in doubt, block.** It is always safer to ask than to leak PHI.
2. **Generate, don't execute.** For any PHI database, generate the command for
   the user to run in their own terminal.
3. **Warn, don't block non-PHI.** For confirmed non-PHI data, a warning and
   user confirmation is sufficient — do not prevent legitimate work.
4. **Error messages are safe.** Users can paste error messages — these don't
   contain PHI.
5. **Schema is safe, data is not.** Table structures are fine. Row data may
   contain PHI.
6. **The user is the gatekeeper.** You provide the tool; they decide when to
   use it.
7. **Assume production.** When the environment is unknown, assume the database
   contains PHI.
8. **Defense in depth.** The skill provides guidance; the PreToolUse hook
   provides enforcement. Neither alone is sufficient.

## Enforcement Layers

| Layer | Hook | Purpose |
|-------|------|---------|
| **Skill injection** | `UserPromptSubmit` | Detects PHI-related keywords in user prompt, injects this skill as context |
| **PHI scanner** | `UserPromptSubmit` | Warns when prompt contains PHI patterns (SSN, MRN, DOB, etc.) |
| **DB client guard** | `PreToolUse` on Bash | Flags database client/dump tool execution for PHI confirmation (`ask`) |

## BAA Revision Guide

When a BAA is executed with the LLM provider:

| Rule | Pre-BAA | Post-BAA |
|------|---------|----------|
| PHI in LLM context | BLOCK | ALLOW with audit logging |
| Non-PHI queries | WARN → confirm | ALLOW |

**Post-BAA changes required:**
1. Update `bash-guard.sh` — remove or relax the DB client `ask` gate
2. Update this skill — permit PHI queries with appropriate access controls
3. **Add audit logging** — all PHI access should be logged for compliance
