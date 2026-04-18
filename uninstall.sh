#!/usr/bin/env bash
# Remove phi-safety hooks from ~/.claude/settings.json and delete install dir.
set -euo pipefail
INSTALL_DIR="${PHI_SAFETY_DIR:-$HOME/.claude/phi-safety}"
SETTINGS="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS" ]]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text() or "{}")
hooks = data.get("hooks", {})
for event, entries in list(hooks.items()):
    hooks[event] = [e for e in entries if not e.get("_phi_safety")]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    data.pop("hooks", None)
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"[phi-safety] cleaned {p}")
PY
fi

rm -rf "$INSTALL_DIR"
echo "[phi-safety] removed $INSTALL_DIR"
