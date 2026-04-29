#!/usr/bin/env bash
# install.sh — ติดตั้ง debugxl ให้ใช้งานได้ทั่วระบบ
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$SCRIPT_DIR/debugxl.sh"

chmod +x "$MAIN"
echo "  ✓ chmod +x debugxl.sh"

for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [[ ! -f "$rc" ]] && continue
  if grep -q 'alias debugxl=' "$rc" 2>/dev/null; then
    sed -i "s|alias debugxl=.*|alias debugxl='bash $MAIN'|" "$rc"
    echo "  ✓ updated alias in $(basename $rc)"
  else
    echo "" >> "$rc"
    echo "# debugxl — pattern code reviewer (projects/bugscan/)" >> "$rc"
    echo "alias debugxl='bash $MAIN'" >> "$rc"
    echo "  ✓ added alias to $(basename $rc)"
  fi
done

echo ""
echo "  done — reload: source ~/.zshrc"
echo "  usage: debugxl .   (no dependencies needed)"
echo ""
