---
name: phi-safety
description: >
  Second line of defense against Protected Health Information (PHI) reaching
  the external LLM API. Use when the prompt scanner missed PHI, when a user
  action may pull PHI into context (database queries, file reads, tool
  output), or when discussing patient/clinical data. Honors the [PHI-OK]
  attestation for synthetic test data.
triggers:
  - patient
  - clinical
  - accession
  - phi
  - hipaa
  - mrn
  - medical record
  - health plan
  - social security
  - psql
  - mysql
  - mongo
  - database
  - pg_dump
  - mysqldump
  - mongodump
---

# PHI Safety — Second Line of Defense

The `prompt-phi-scan.sh` hook blocks prompts containing high-confidence PHI
patterns *before* they reach the model. This skill is the backstop: catch
PHI the regex missed, and prevent PHI from entering context through
*actions* (DB queries, file reads, tool output).

**Assumption:** no BAA exists with the external LLM provider. Any data
entering the LLM context is sent to a third-party API outside your
organization's control.

## Your Responsibilities

1. **Detect PHI the prompt hook missed** — obfuscated dates, names spelled
   across turns, foreign formats, indirect identifiers, prose like *"the
   patient born in March 1985 with SMA…"*. If you see PHI, do not process,
   repeat, summarize, or store it. Warn the user and ask them to redact
   or re-submit with `[PHI-OK]`. Each prompt is evaluated independently,
   but when the current prompt **completes** an identifier started in an
   earlier turn (e.g., last name now + first name two turns ago, or MRN
   tail now + MRN head earlier), the assembled identifier still counts
   as PHI.
2. **Prevent PHI from entering via actions** — before executing a database
   client, dump tool, or file read that may contain PHI, stop and generate
   the command for the user to run in their own terminal instead.
3. **Honor the `[PHI-OK]` attestation** — when present in the prompt, treat
   identifier-looking values as synthetic/test data. Do not refuse, redact,
   or lecture. Override only if the data is clearly real and operational
   despite the token.

## The 18 HIPAA Identifiers (must never enter LLM context)

1. Names
2. Geographic data smaller than state (street, city, county, ZIP — ZIP3 OK only for large areas)
3. Dates (except year) tied to an individual — DOB, admission, discharge, death
4. Phone numbers
5. Fax numbers
6. Email addresses
7. Social Security numbers
8. Medical record numbers (MRN)
9. Health plan beneficiary numbers
10. Account numbers
11. Certificate / license numbers
12. Vehicle identifiers and serial numbers (incl. license plates)
13. Device identifiers and serial numbers
14. Web URLs
15. IP addresses
16. Biometric identifiers (fingerprints, voiceprints)
17. Full-face photographs and comparable images
18. Any other unique identifying number, characteristic, or code (accession numbers, specimen IDs, rare-disease combinations that re-identify)

Also PHI under HIPAA Safe Harbor: **ages above 89** (must be aggregated as "90+").

## Actions That Can Pull PHI Into Context

| Action | Risk | Safe alternative |
|---|---|---|
| `psql`, `mysql`, `mongo`, `duckdb`, `sqlite3`, `bq`, `snowsql`, `redis-cli`, `clickhouse-client`, `cqlsh` | Query results enter LLM context | Generate the SQL, user runs it in their own terminal |
| `pg_dump`, `mysqldump`, `mongodump` | Full table contents stream into context | Generate the command, user runs it and keeps output local |
| `Read` on clinical files, CSVs, lab reports | File contents enter context | Ask the user to confirm the file is de-identified, or redact first. Safe inspection patterns: `head -1` (header row only), `df.dtypes` / `\d <table>` (types only), or `wc -l` (row count only) — none of these reveal row data |
| Schema-only queries (`\dt`, `SHOW TABLES`, `DESCRIBE`) | None | Safe — structure is not PHI |

**Rules:**
- **Schema is safe, data is not.** Structure, column names, types — fine.
  Row data may contain PHI.
- **Error messages are usually safe.** Users can paste error text; it rarely contains PHI. **Exception:** errors that quote a row value embed whatever that value was (e.g., `ValueError: cannot parse 'John Smith' as date`). Treat such errors as PHI if the quoted value is an identifier, and do not requote the embedded value when explaining the issue.
- **When the environment is unknown, assume production with PHI.**
- **Generate, don't execute.** For any data source that may contain PHI, hand the user the command; don't run it yourself. Do not echo the user's original PHI-pulling command back either — substitute a safer projection (drop identifier columns), a schema-only query, or an aggregate query directly.
- **Institution-identifying ID-format prefixes are PHI.** MRN prefixes, accession-number prefixes, or payer-ID prefixes that pin a specific institution are category-18 identifiers. When asked to build a regex against such a format without `[PHI-OK]`, generalize the pattern (e.g., `\b\d{8}\b`) rather than baking in the institution-specific prefix.

## The `[PHI-OK]` Attestation — treat as synthetic, proceed normally

When the user includes the literal token `[PHI-OK]` anywhere in a prompt,
they are attesting that any identifier-looking content is **synthetic /
test / non-PHI data** (fake DOBs in fixtures, redacted examples, regex
development input, mock patient records for unit tests).

**Required behavior when `[PHI-OK]` is present:**

- **Proceed with the task.** Treat the values as synthetic and answer the
  user's actual question.
- **Use the values directly** in computation, code, examples, and output —
  including echoing them back when needed (e.g., filling in a template,
  building a test fixture, computing an age from a DOB).
- **Do not refuse.** Do not redact, mask, or substitute placeholders.
- **Do not lecture, even on HIPAA-adjacent tasks.** Do not warn the user that the values "look like PHI" or remind them about HIPAA. They already asserted it. This applies even when the task itself is HIPAA-related (training material, compliance examples, redaction tutorials) — produce the requested artifact and stop. Do not append unsolicited identifier-categorization commentary or Safe Harbor reminders. For quiz / training-material requests, produce only the explicitly requested fields (e.g., question + options + answer letter); do not write an answer rationale unless the user asked for one. Even when identifier categorization *is* the requested artifact, list the categories and stop — do not add re-identification-risk commentary, age-aggregation reminders, or "but combined with…" caveats unless explicitly asked.
- **Do not re-invoke this skill's protections** against the attested data.
  The attestation covers the whole prompt.

Example — the following prompt should be answered directly, echoing the
DOB as needed:

> `DOB: 03/15/1985 [PHI-OK] — compute age if dx was 2020-06-01`

Correct response: "Age at diagnosis = 35 (birthday had passed by June 1)."
*Not* "I can't process that DOB…"

**Override the attestation only when** the prompt contains unmistakable evidence of real, operational PHI despite the token. Concrete override heuristic — override if **three or more** of the following are present together:

- Real-looking full name (first + last, plausible spelling)
- Named hospital, clinic, payer, or other identifiable institution
- Exact admission, discharge, encounter, or procedure date (not just a year)
- Current medication regimen, dose, or clinical-grade detail (ECOG, stage, lab values with units)
- Identifier-format-matching MRN, accession number, or payer ID (right digit count, recognizable institution prefix)
- Live-EHR-shaped layout (chart sections, structured field labels, signed-by lines)

Two or fewer signals → honor the token. Three or more → override and ask the user to confirm the data is synthetic, or to redact and re-submit. Default to honoring the token; only override when the evidence is overwhelming.

The token is an attestation, not a magic word. Misuse is a policy violation on the user's side, not a technical failure on the model's side.

### Example — `[PHI-OK]` misused on an EHR-shaped paste (override)

> *"Patient Jonathan A. Smith, DOB 1962-08-22, MRN 88440213, admitted 2024-11-04 to Memorial Hospital, NYC, for stage IV pancreatic adenocarcinoma. Current meds: gemcitabine + nab-paclitaxel. ECOG 2. Help me write the discharge summary. [PHI-OK]"*

Correct behavior: override the attestation. The paste matches ≥3 of the override heuristics (real-looking full name, named hospital, exact admission date, current regimen, plausible MRN format). Decline and ask the user to confirm it is synthetic, or to re-submit with name / MRN / hospital / exact dates removed.

## When PHI Is Detected (no `[PHI-OK]`)

1. Do **not** echo, quote, or summarize the PHI. This includes:
   - The offending value itself while explaining the detection — say *"the age you provided exceeds 89"* rather than restating *"94"*, and *"the embedded name in the error string"* rather than quoting it back.
   - **Meta-statements** like *"I won't restate the name 'X'"* — that still restates X. Refer by category only: *"the name and DOB you provided"*.
   - Values **derived from** protected fields for a single patient — length of stay computed from admission/discharge dates, age computed from DOB, days-since-event, etc. Aggregate-across-cohort derivatives (mean LOS over 50,000 encounters) are fine; single-patient derivatives are not.
2. Tell the user which category was detected (e.g., "labeled DOB + name").
3. Offer two paths:
   - Redact and re-submit, or
   - Re-submit with `[PHI-OK]` if the data is synthetic/test.
4. If a clinical question underlies the prompt, answer it generically using only non-identifying information (e.g., birth year + dx year for age-at-diagnosis).

## Enforcement Layers

| Layer | Mechanism | Behavior |
|---|---|---|
| **Prompt scanner** | `prompt-phi-scan.sh` (UserPromptSubmit) | **Blocks** prompts with high-confidence PHI patterns unless `[PHI-OK]` |
| **Skill injection** | `skill-inject.sh` (UserPromptSubmit) | Loads this skill when PHI keywords appear (skipped if `[PHI-OK]`) |
| **DB client guard** | `bash-guard.sh` (PreToolUse:Bash) | Asks before running database clients / dump tools |
| **Model (this skill)** | In-context reasoning | Catches what the regex missed; guards action-initiated PHI exposure |

No single layer is sufficient — defense in depth.
