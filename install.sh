#!/usr/bin/env bash
# install.sh — ติดตั้ง bugscan ให้ใช้งานได้ทั่วระบบ
# usage: bash install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$SCRIPT_DIR/bugscan.sh"
ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"

echo ""
echo "  bugscan installer"
echo "  project: $SCRIPT_DIR"
echo ""

# 1. chmod
chmod +x "$MAIN"
echo "  ✓ chmod +x bugscan.sh"

# 2. เพิ่ม alias ถ้ายังไม่มี
add_alias() {
  local rcfile="$1"
  [[ ! -f "$rcfile" ]] && return
  if grep -q 'alias bugscan=' "$rcfile" 2>/dev/null; then
    # อัปเดต path ถ้าเปลี่ยน
    sed -i "s|alias bugscan=.*|alias bugscan='bash $MAIN'|" "$rcfile"
    echo "  ✓ updated alias in $rcfile"
  else
    echo "" >> "$rcfile"
    echo "# bugscan — static analysis (projects/bugscan/)" >> "$rcfile"
    echo "alias bugscan='bash $MAIN'" >> "$rcfile"
    echo "  ✓ added alias to $rcfile"
  fi
}

add_alias "$ZSHRC"
add_alias "$BASHRC"

echo ""
echo "  done — reload shell:"
echo "    source ~/.zshrc"
echo ""
