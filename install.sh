#!/usr/bin/env bash
# phi-safety installer — installs PHI safety hooks into Claude Code
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ndu-bioinfo/phi-safety/main/install.sh | bash
#   # or, from a clone:
#   bash install.sh
#
# Installs files to:  ~/.claude/phi-safety
# Registers hooks in: ~/.claude/settings.json
set -euo pipefail

REPO="${PHI_SAFETY_REPO:-ndu-bioinfo/phi-safety}"
REF="${PHI_SAFETY_REF:-main}"
INSTALL_DIR="${PHI_SAFETY_DIR:-$HOME/.claude/phi-safety}"
SETTINGS="$HOME/.claude/settings.json"

log() { printf '[phi-safety] %s\n' "$*"; }
die() { printf '[phi-safety] error: %s\n' "$*" >&2; exit 1; }

command -v bash >/dev/null || die "bash required"

# 1. Fetch source: prefer local copy if run from a clone; otherwise download tarball.
mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "${SCRIPT_DIR}" && -d "${SCRIPT_DIR}/hooks" && -f "${SCRIPT_DIR}/plugin.json" ]]; then
  log "installing from local checkout: $SCRIPT_DIR"
  cp -R "$SCRIPT_DIR/hooks" "$SCRIPT_DIR/skills" "$SCRIPT_DIR/plugin.json" "$INSTALL_DIR/"
else
  command -v curl >/dev/null || die "curl required"
  command -v tar  >/dev/null || die "tar required"
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT
  TARBALL_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"
  log "downloading ${REPO}@${REF}"
  # Private repo support: pass GITHUB_TOKEN via env if set.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" "$TARBALL_URL" | tar -xz -C "$TMPDIR"
  else
    curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMPDIR" || die "download failed (private repo? set GITHUB_TOKEN)"
  fi
  SRC="$(find "$TMPDIR" -maxdepth 1 -type d -name 'phi-safety-*' | head -n1)"
  [[ -d "$SRC" ]] || die "could not locate extracted source"
  cp -R "$SRC/hooks" "$SRC/skills" "$SRC/plugin.json" "$INSTALL_DIR/"
fi

chmod +x "$INSTALL_DIR"/hooks/*.sh || true
log "installed files to $INSTALL_DIR"

# 2. Merge hooks into ~/.claude/settings.json.
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || printf '{}\n' > "$SETTINGS"

python3 - "$SETTINGS" "$INSTALL_DIR" <<'PY'
import json, sys, pathlib, datetime

settings_path = pathlib.Path(sys.argv[1])
root = sys.argv[2]

try:
    data = json.loads(settings_path.read_text() or "{}")
except json.JSONDecodeError as e:
    sys.exit(f"[phi-safety] error: {settings_path} is not valid JSON: {e}")

hooks = data.setdefault("hooks", {})

def replace_block(event, matcher, new_hooks):
    entries = hooks.setdefault(event, [])
    # Drop any prior phi-safety entries (tagged with _phi_safety).
    entries[:] = [e for e in entries if not e.get("_phi_safety")]
    block = {"_phi_safety": True, "hooks": new_hooks}
    if matcher is not None:
        block["matcher"] = matcher
    entries.append(block)

replace_block("UserPromptSubmit", None, [
    {"type": "command", "command": f'bash "{root}/hooks/skill-inject.sh"', "timeout": 5},
    {"type": "command", "command": f'bash "{root}/hooks/prompt-phi-scan.sh"', "timeout": 5,
     "statusMessage": "Scanning for PHI patterns..."},
])
replace_block("PreToolUse", "Bash", [
    {"type": "command", "command": f'bash "{root}/hooks/bash-guard.sh"', "timeout": 5},
])

# Backup previous settings once per install.
backup = settings_path.with_suffix(f".json.bak.{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}")
backup.write_text(settings_path.read_text())
settings_path.write_text(json.dumps(data, indent=2) + "\n")
print(f"[phi-safety] updated {settings_path} (backup: {backup.name})")
PY

log "done. restart Claude Code to pick up the new hooks."
