#!/usr/bin/env bash
# Symlinks all skills from this repository (.agents/skills/*) into the user-scope
# skill directories on Linux/macOS (e.g. SSH host devs7 where herdr-core runs).
#
# Targets:
#   - ~/.agents/skills             (Universal Agent Skills / Herdr remote spaces)
#   - ~/.kimi-code/skills          (Kimi Code CLI inside Herdr panes)
#   - ~/.claude/skills             (Claude Code CLI inside Herdr panes)
#   - ~/.gemini/config/skills.json (Antigravity global skill registry)
#
# Usage:
#   ./link-skills.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SOURCE="${REPO_ROOT}/.agents/skills"

if [ ! -d "$SKILLS_SOURCE" ]; then
    echo "Error: Skills source directory not found: $SKILLS_SOURCE" >&2
    exit 1
fi

chmod +x "${SKILLS_SOURCE}"/*/scripts/*.sh 2>/dev/null || true

KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
TARGET_DIRS=(
    "$HOME/.agents/skills"
    "$KIMI_HOME/skills"
    "$HOME/.claude/skills"
)

for target_root in "${TARGET_DIRS[@]}"; do
    mkdir -p "$target_root"
    for skill_dir in "$SKILLS_SOURCE"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name="$(basename "$skill_dir")"
        link_path="${target_root}/${skill_name}"
        rm -rf "$link_path"
        ln -sfn "${skill_dir%/}" "$link_path"
        echo "[$(hostname)] Linked ${skill_name} -> ${link_path}"
    done
done

# Register in Antigravity global skills.json (~/.gemini/config/skills.json)
GEMINI_CONFIG_DIR="$HOME/.gemini/config"
mkdir -p "$GEMINI_CONFIG_DIR"
cat > "${GEMINI_CONFIG_DIR}/skills.json" <<EOF
{
  "entries": [
    {
      "path": "${SKILLS_SOURCE}"
    }
  ]
}
EOF
echo "[$(hostname)] Registered ${SKILLS_SOURCE} in ${GEMINI_CONFIG_DIR}/skills.json"
