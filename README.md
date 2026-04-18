# phi-safety

Claude Code guardrails that prevent Protected Health Information (PHI) from
entering the LLM context.

## What it does

| Layer | Hook | Behavior |
|-------|------|----------|
| DB client guard | `PreToolUse` on Bash | Detects `psql`, `pgcli`, `mysql`, `duckdb`, `snowsql`, `pg_dump`, etc. → asks user to confirm no PHI |
| PHI pattern scanner | `UserPromptSubmit` | Warns on labeled SSN, MRN, DOB, accession numbers, or tabular clinical data |
| Skill injection | `UserPromptSubmit` | Injects HIPAA decision guidance when PHI-related keywords appear |

Scope is intentionally narrow: **PHI exposure prevention only**. Destructive
operations (DROP TABLE, `rm -rf`, `terraform destroy`) are out of scope.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ndu-bioinfo/phi-guard-skill/main/install.sh | bash
```

Private repo? Export a token first:

```bash
GITHUB_TOKEN=ghp_xxx curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/ndu-bioinfo/phi-guard-skill/main/install.sh | bash
```

Or from a local clone:

```bash
git clone git@github.com:ndu-bioinfo/phi-guard-skill.git
bash phi-safety/install.sh
```

The installer:
1. Copies files to `~/.claude/phi-safety/`
2. Merges hooks into `~/.claude/settings.json` (backs up the prior version)

Restart Claude Code after installing.

## Uninstall

```bash
bash ~/.claude/phi-safety/uninstall.sh
```

## Files

- `hooks/bash-guard.sh` — DB client detector
- `hooks/prompt-phi-scan.sh` — PHI pattern scanner
- `hooks/skill-inject.sh` — skill loader
- `skills/phi-safety/SKILL.md` — HIPAA decision guidance

## Design notes

- **`ask`, not `deny`** — DB client hook prompts rather than blocks; non-PHI
  databases (CI metrics, monitoring, config) stay usable after confirmation.
- **High-confidence patterns only** — PHI scanner requires labels
  (e.g. `SSN: 123-45-6789`) or double signals (clinical column headers +
  tabular formatting) to minimize false positives.
- **POSIX ERE compliant** — uses `[[:space:]]` and
  `([^a-zA-Z0-9]|$)` boundaries for macOS BSD grep compatibility.

---

Extracted from the GeneDx `code-assist-tools` marketplace.
