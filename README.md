# phi-guard-skill

> A Claude Code skill + hook bundle that keeps Protected Health Information (PHI)
> out of your LLM prompts — before it leaves your machine.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/ndu-bioinfo/phi-guard-skill/main/install.sh | bash
```

Or from a clone:

```bash
git clone git@github.com:ndu-bioinfo/phi-guard-skill.git
bash phi-guard-skill/install.sh
```

The installer copies files to `~/.claude/phi-safety/` and merges hooks into
`~/.claude/settings.json` (with a timestamped backup). Restart Claude Code
after install.

Uninstall: `bash ~/.claude/phi-safety/uninstall.sh`

---

## Why this exists

Every regulated industry — healthcare, finance, defense — has spent decades
building compliance around two things: **people** (training, attestations,
annual HIPAA/SOC2/GLBA modules) and **warehouses** (access controls, audit
logs, data classification, egress monitoring). Those controls assume humans
move data deliberately: you query a database, you export a file, you email a
spreadsheet. Each step is a conscious act with a paper trail.

AI assistants break that model.

When an engineer pastes a debugging stack trace, a SQL result set, or a
"just take a look at this CSV" into an LLM chat, the data exits the regulated
perimeter **silently**. There is no download dialog, no VPN prompt, no DLP
scanner, no Slack thread for a reviewer to notice. The prompt goes straight
to a third-party inference API — which, absent a Business Associate Agreement
(BAA), is itself a HIPAA violation the moment PHI crosses the wire. Worse,
the data may be cached, logged, or used for model evaluation depending on
the vendor's terms.

The gap is widest for people who are *trying* to do the right thing. They've
taken the annual training. They would never email a patient record. But they
might copy a sample row into Claude to ask "why is this parse failing?" —
not realizing they just exfiltrated PHI. The old controls don't fire because
the old controls were built for a pre-LLM world.

**phi-guard-skill is a seatbelt for that moment.** It doesn't replace
training, policy, or BAAs. It catches the easy mistakes at the last possible
second — on your machine, before the prompt is sent.

---

## Design philosophy: block on high-confidence PHI, attest for synthetic

This skill enforces **two hook gates plus a model-side backstop** between
you and the Anthropic API:

```
  your prompt ──► [Gate 1: prompt scan] ──► [Model + SKILL.md] ──► [Gate 2: tool-use guard] ──► LLM
                  block or pass-through     second-line catch       ask-to-confirm
```

### Gate 1 — Prompt scanner (`UserPromptSubmit`)

Scans every prompt *before* it reaches the LLM for high-confidence PHI
signals: labeled SSNs, MRNs, DOBs, accession numbers, patient-name +
date-of-birth proximity, or tabular clinical data with clinical column
headers. If it matches, the prompt is **blocked** — it is not sent to the
model — and the user is told why.

### The `[PHI-OK]` attestation

False positives are the single biggest risk to any guardrail. A blocker
that cries wolf on legitimate test data (`DOB: 03/15/1985` in a fixture,
`SSN: 000-00-0000` in a regex unit test) trains users to disable it,
bypass it, or move the work outside the tool entirely — strictly worse
than no guardrail at all.

To resolve this, the scanner honors a user attestation: include the
literal token `[PHI-OK]` anywhere in your prompt, and the scanner
passes through. The token is a **deliberate, auditable statement** that
the identifier-looking values are synthetic / test / non-PHI. The skill
itself is also bypassed in that case, so you don't get lectured about
values you already declared fake.

The token is not a magic word — it's an attestation. Misuse is a policy
violation on the user's side. The goal is to preserve an escape hatch
for legitimate work *without* giving silent exfiltration a silent path.

### Gate 2 — Database-client guard (`PreToolUse` on Bash)

Intercepts invocations of database clients (`psql`, `pgcli`, `mysql`,
`duckdb`, `snowsql`, `pg_dump`, …) and asks you to confirm the target
contains no PHI before running. Non-PHI databases (CI metrics, monitoring,
config stores) remain fully usable — you just acknowledge once per session.

### Model-side backstop (`SKILL.md`)

When PHI-related keywords appear, the skill is injected into context. It
instructs the model to catch what the regex missed (obfuscated dates,
names spelled across turns, indirect identifiers) and to refuse actions
that would pull PHI into context (reading a clinical CSV, executing a
query against a PHI database). No single layer is sufficient — defense
in depth.

---

## Decision flowchart

```
User prompt arrives
        │
        ▼
┌─ Gate 1: prompt-phi-scan.sh (UserPromptSubmit) ──────────┐
│  PHI pattern detected?                                   │
│    no  → pass to LLM                                     │
│    yes → [PHI-OK] token present in prompt?               │
│          yes → pass to LLM (treated as synthetic)        │
│          no  → BLOCK (prompt never sent; user informed)  │
└──────────────────────────────────────────────────────────┘
        │ (pass)
        ▼
┌─ Model + SKILL.md (second line of defense) ──────────────┐
│  Does the prompt contain PHI the regex missed?           │
│    yes → refuse, ask user to redact or attest [PHI-OK]   │
│    no  → continue                                        │
│                                                          │
│  Will a requested action pull PHI into context?          │
│  (psql/mysql query, pg_dump, reading a clinical file)    │
│    yes → generate the command for the user to run in     │
│          their own terminal; do not execute              │
│    no  → proceed                                         │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌─ Gate 2: bash-guard.sh (PreToolUse on Bash) ─────────────┐
│  DB client or dump tool invoked?                         │
│    no  → allow                                           │
│    yes → ask user to confirm target has no PHI           │
│          confirmed → allow                               │
│          denied    → block, generate query instead       │
└──────────────────────────────────────────────────────────┘
        │
        ▼
     LLM response
```

---

## What you'll see

| Scenario | Behavior |
|---|---|
| `psql -h localhost metrics_db` | Gate 2 asks: "Confirm this database contains no PHI." |
| Prompt contains `SSN: 123-45-6789` | Gate 1 **blocks** the prompt. Re-submit redacted, or add `[PHI-OK]` if synthetic. |
| Prompt contains `DOB: 03/15/1985 [PHI-OK] — it's a test fixture` | Passes through; model treats values as synthetic. |
| Prompt mentions "how should I handle patient data?" | Skill auto-loads as second-line PHI guidance. |
| Model asked to `cat patients.csv` | Skill refuses; asks user to confirm file is de-identified or to redact. |
| `ls -la`, normal coding, non-clinical prompts | Silent pass-through. No friction. |

---

## Files

```
~/.claude/phi-safety/
├── plugin.json
├── hooks/
│   ├── bash-guard.sh         # DB client detector (Gate 2)
│   ├── prompt-phi-scan.sh    # PHI pattern scanner (Gate 1)
│   └── skill-inject.sh       # On-demand skill loader
└── skills/phi-safety/
    └── SKILL.md              # HIPAA decision guidance for Claude
```

---

## Compatibility

- macOS / Linux, bash 3.2+ (BSD/GNU grep both supported via POSIX ERE)
- Claude Code with hook support
- Requires `python3` for the settings merge step

---

## Scope (what this is not)

This skill covers **PHI exposure prevention only**. It is intentionally not
a general-purpose safety harness. Destructive operations (`DROP TABLE`,
`rm -rf`, `terraform destroy`) are out of scope — use a dedicated tool for
those concerns.

It is also not a substitute for:

- A signed BAA with your LLM vendor
- Your organization's HIPAA training program
- Database-level access controls or audit logging
- Data loss prevention (DLP) at the network layer

Treat it as the last-mile seatbelt, not the whole safety system.

---

## License

MIT.
