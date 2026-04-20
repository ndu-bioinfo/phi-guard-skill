# phi-guard-skill

> A Claude Code skill + hook bundle that keeps Protected Health Information (PHI)
> out of your LLM prompts — before it leaves your machine.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/ndu-bioinfo/phi-guard-skill/main/install.sh | bash
```

Private repo? Pass a token:

```bash
GITHUB_TOKEN=ghp_xxx bash -c "$(curl -fsSL -H \"Authorization: token $GITHUB_TOKEN\" \
  https://raw.githubusercontent.com/ndu-bioinfo/phi-guard-skill/main/install.sh)"
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

## Design philosophy: two gates, no hard stops

This skill enforces **two gates** that sit between you and the Anthropic API:

```
  your prompt ──► [Gate 1: prompt scan]  ──► [Gate 2: tool-use guard] ──► LLM
                         warn                     ask-to-confirm
```

### Gate 1 — Prompt scanner (`UserPromptSubmit`)

Scans every prompt *before* it leaves your machine for high-confidence PHI
signals: labeled SSNs, MRNs, DOBs, accession numbers, or tabular clinical
data with clinical column headers. If it finds something, it **warns** and
lets you decide.

### Gate 2 — Database-client guard (`PreToolUse` on Bash)

Intercepts invocations of database clients (`psql`, `pgcli`, `mysql`,
`duckdb`, `snowsql`, `pg_dump`, …) and asks you to confirm the target
contains no PHI before running. Non-PHI databases (CI metrics, monitoring,
config stores) remain fully usable — you just acknowledge once per session.

### Why no hard block?

The most important design choice here is what this skill **doesn't** do:
it never silently blocks your prompt or tool call.

False positives are the single biggest risk to any guardrail. A scanner that
cries wolf on legitimate work — flagging "patient-id" in a schema migration,
or refusing to let you run `psql` against a config DB — trains users to
disable it, bypass it, or move the work outside the tool entirely. That is
strictly worse than no guardrail at all, because now you've lost the easy
catches *and* created a false sense of security.

So the contract is:

1. **High-precision signals only.** Patterns require labels
   (`SSN: 123-45-6789`) or double signals (clinical column headers + tabular
   formatting). No speculative matching.
2. **Warn and inform, don't block.** The user stays in control. The skill's
   job is to make sure the decision is *conscious*, not to make it for them.
3. **Inject guidance on demand.** When PHI-adjacent keywords appear (HIPAA,
   patient, clinical, etc.), a HIPAA decision-flow skill is loaded into
   context so Claude itself can help reason about what's safe to share.

The goal is to convert silent data exfiltration — the actual threat in the
AI era — into a visible, deliberate moment. One where you get to say "yes,
I know, this database has no PHI" or "oh, that *is* an MRN, let me redact."

---

## What you'll see

| Scenario | Behavior |
|---|---|
| `psql -h localhost metrics_db` | Claude asks: "Confirm this database contains no PHI." |
| Prompt contains `SSN: 123-45-6789` | Warning surfaces before send; you can edit and retry. |
| Prompt mentions "how should I handle patient data?" | HIPAA decision-guidance skill auto-loads into context. |
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
