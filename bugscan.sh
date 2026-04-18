#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────┐
# │  bugscan v2.0                                   │
# │  shellcheck (bash) + bandit (python) wrapper    │
# │  Termux / aarch64 compatible                    │
# └─────────────────────────────────────────────────┘
# usage:
#   bugscan <path>              → summary + HIGH + MEDIUM
#   bugscan <path> --high       → HIGH only
#   bugscan <path> --all        → all levels
#   bugscan <path> --detail     → full output + fix hints
#   bugscan <path> --ai         → export .txt ส่ง AI ได้เลย
#   bugscan <path> --skip <dir> → ข้าม folder (ใช้ซ้ำได้)

VERSION="2.0"

# ── Colors ──────────────────────────────────────────
R='\033[0;31m'
Y='\033[1;33m'
G='\033[0;32m'
C='\033[0;36m'
B='\033[1;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── State ────────────────────────────────────────────
SCAN_PATH=""
MODE="default"
SKIP_DIRS=()
TMPDIR_SCAN=$(mktemp -d)
RESULTS_FILE="$TMPDIR_SCAN/results.txt"   # level|file|line|code|msg|tool
AI_FILE=""

# counters
SH_FILE_COUNT=0
PY_FILE_COUNT=0
COUNT_HIGH=0
COUNT_MED=0
COUNT_LOW=0

# ────────────────────────────────────────────────────
cleanup() { rm -rf "$TMPDIR_SCAN"; }
trap cleanup EXIT

# ── Usage ────────────────────────────────────────────
usage() {
  echo ""
  echo -e "${BOLD}bugscan v${VERSION}${NC} — shellcheck + bandit"
  echo ""
  echo "  bugscan <path>              summary + HIGH + MEDIUM (default)"
  echo "  bugscan <path> --high       HIGH only"
  echo "  bugscan <path> --all        all levels"
  echo "  bugscan <path> --detail     full detail + fix hints"
  echo "  bugscan <path> --ai         export .txt เพื่อส่ง AI"
  echo "  bugscan <path> --skip <dir> ข้าม dir นั้น (ใช้ซ้ำได้)"
  echo ""
  echo "  examples:"
  echo "    bugscan ~/projects/dexv2"
  echo "    bugscan . --ai"
  echo "    bugscan ~/USSDTH --high --skip node_modules"
  echo ""
}

# ── Parse Args ───────────────────────────────────────
parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  SCAN_PATH="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --high)    MODE="high"   ;;
      --all)     MODE="all"    ;;
      --detail)  MODE="detail" ;;
      --ai)      MODE="ai"     ;;
      --skip)    shift; SKIP_DIRS+=("$1") ;;
      -h|--help) usage; exit 0 ;;
      *) echo -e "${R}unknown option:${NC} $1"; usage; exit 1 ;;
    esac
    shift
  done

  [[ ! -e "$SCAN_PATH" ]] && {
    echo -e "${R}error:${NC} not found: $SCAN_PATH"; exit 1
  }
  SCAN_PATH=$(realpath "$SCAN_PATH")
}

# ── Check Tools ──────────────────────────────────────
HAS_SC=false
HAS_BD=false
check_tools() {
  command -v shellcheck &>/dev/null && HAS_SC=true
  command -v bandit     &>/dev/null && HAS_BD=true

  if ! $HAS_SC && ! $HAS_BD; then
    echo -e "${R}error:${NC} ไม่พบ tools"
    echo "  pkg install shellcheck"
    echo "  pip install bandit --break-system-packages"
    exit 1
  fi
  $HAS_SC || echo -e "${Y}warn:${NC} shellcheck ไม่พบ — ข้าม .sh"
  $HAS_BD || echo -e "${Y}warn:${NC} bandit ไม่พบ — ข้าม .py"
}

# ── Build find excludes ──────────────────────────────
find_files() {
  local ext="$1"
  local args=()
  args+=("$SCAN_PATH" -type f -name "*.$ext")
  for d in "${SKIP_DIRS[@]}"; do
    args+=(-not -path "*/${d}/*" -not -path "*/${d}")
  done
  find "${args[@]}" 2>/dev/null
}

# ── map severity word → level ────────────────────────
sc_level() {
  case "$1" in
    error)   echo "HIGH"   ;;
    warning) echo "MEDIUM" ;;
    *)       echo "LOW"    ;;   # note / style / info
  esac
}

bd_level() {
  case "$1" in
    HIGH)   echo "HIGH"   ;;
    MEDIUM) echo "MEDIUM" ;;
    *)      echo "LOW"    ;;
  esac
}

# ════════════════════════════════════════════════════
#  SHELLCHECK
# ════════════════════════════════════════════════════
run_shellcheck() {
  $HAS_SC || return
  local files=()
  mapfile -t files < <(find_files "sh"; find_files "bash")
  SH_FILE_COUNT=${#files[@]}
  [[ $SH_FILE_COUNT -eq 0 ]] && return

  for f in "${files[@]}"; do
    # --format=gcc  →  file:line:col: severity: (SCxxxx): message
    while IFS= read -r raw; do
      # match: path:line:col: sev: (SCnnnn): msg
      # format: /path/file.sh:LINE:COL: severity: message [SCxxxx]
      if [[ "$raw" =~ ^(.+):([0-9]+):[0-9]+:\ ([a-z]+):\ (.*)\ \[SC([0-9]+)\]$ ]]; then
        local file="${BASH_REMATCH[1]}"
        local lineno="${BASH_REMATCH[2]}"
        local sev="${BASH_REMATCH[3]}"
        local msg="${BASH_REMATCH[4]}"
        local code="SC${BASH_REMATCH[5]}"
        local level
        level=$(sc_level "$sev")
        echo "${level}|${file}|${lineno}|${code}|${msg}|bash" >> "$RESULTS_FILE"
      fi
    done < <(shellcheck --format=gcc "$f" 2>/dev/null)
  done
}

# ════════════════════════════════════════════════════
#  BANDIT — parse JSON (no jq needed)
# ════════════════════════════════════════════════════
run_bandit() {
  $HAS_BD || return
  local files=()
  mapfile -t files < <(find_files "py")
  PY_FILE_COUNT=${#files[@]}
  [[ $PY_FILE_COUNT -eq 0 ]] && return

  # build --exclude
  local excl=""
  for d in "${SKIP_DIRS[@]}"; do
    excl+="${SCAN_PATH}/${d},"
  done
  excl="${excl%,}"

  # ใช้ --format text — เสถียรกว่า JSON ไม่มีปัญหา comma ใน issue_text
  # bandit text format:
  #   >> Issue: [Bxxx:test_name] message
  #      Severity: HIGH   Confidence: HIGH
  #      Location: /path/file.py:lineno:col
  local bd_args=(-r "$SCAN_PATH" -f txt -q)
  [[ -n "$excl" ]] && bd_args+=(--exclude "$excl")

  local cur_code="" cur_msg="" cur_sev="" cur_file="" cur_line=""

  _flush_bd() {
    [[ -z "$cur_code" || -z "$cur_file" ]] && return
    local lv
    lv=$(bd_level "$cur_sev")
    echo "${lv}|${cur_file}|${cur_line}|${cur_code}|${cur_msg}|python" >> "$RESULTS_FILE"
    cur_code=""; cur_msg=""; cur_sev=""; cur_file=""; cur_line=""
  }

  while IFS= read -r ln; do
    case "$ln" in
      ">>"\ Issue:*)
        _flush_bd
        cur_code=$(echo "$ln" | grep -o 'B[0-9]\+')
        cur_msg=$(echo "$ln"  | sed 's/.*\] *//')
        ;;
      *"Severity:"*"Confidence:"*)
        cur_sev=$(echo "$ln" | sed 's/.*Severity: *\([A-Za-z]*\).*/\1/' | tr '[:lower:]' '[:upper:]')
        ;;
      *"Location:"*)
        local loc
        loc=$(echo "$ln" | awk '{print $2}')
        cur_file=$(echo "$loc" | rev | cut -d: -f3- | rev)
        cur_line=$(echo "$loc" | rev | cut -d: -f2  | rev)
        ;;
    esac
  done < <(bandit "${bd_args[@]}" 2>/dev/null)

  _flush_bd
}

# ════════════════════════════════════════════════════
#  COUNT results
# ════════════════════════════════════════════════════
count_results() {
  [[ ! -f "$RESULTS_FILE" ]] && return
  COUNT_HIGH=$(grep -c '^HIGH|'   "$RESULTS_FILE" 2>/dev/null); COUNT_HIGH=$(( ${COUNT_HIGH:-0} + 0 ))
  COUNT_MED=$(grep  -c '^MEDIUM|' "$RESULTS_FILE" 2>/dev/null); COUNT_MED=$(( ${COUNT_MED:-0} + 0 ))
  COUNT_LOW=$(grep  -c '^LOW|'    "$RESULTS_FILE" 2>/dev/null); COUNT_LOW=$(( ${COUNT_LOW:-0} + 0 ))
}

# ── Bar chart ────────────────────────────────────────
bar() {
  local n=$1 max=$2 color=$3
  local width=20
  local filled=0
  [[ $max -gt 0 ]] && filled=$(( n * width / max ))
  local bar=""
  for ((i=0; i<filled; i++));  do bar+="█"; done
  for ((i=filled; i<width; i++)); do bar+="░"; done
  echo -e "${color}${bar}${NC} ${BOLD}${n}${NC}"
}

# ════════════════════════════════════════════════════
#  PRINT SUMMARY BOX
# ════════════════════════════════════════════════════
print_summary() {
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
  local max=$(( COUNT_HIGH > COUNT_MED ? COUNT_HIGH : COUNT_MED ))
  max=$(( max > COUNT_LOW ? max : COUNT_LOW ))
  [[ $max -eq 0 ]] && max=1

  echo ""
  echo -e "${C}┌──────────────────────────────────────────┐${NC}"
  echo -e "${C}│  BUGSCAN v${VERSION}${NC}                              ${C}│${NC}"
  echo -e "${C}│  ${DIM}$(printf '%-42s' "$SCAN_PATH")${NC}${C}│${NC}"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  %-8s %-6s  %-6s %14s ${C}│${NC}\n" "type" "files" "issues" ""
  echo -e "${C}│${NC}  .sh      ${BOLD}${SH_FILE_COUNT}${NC}             (shellcheck)  ${C}│${NC}"
  echo -e "${C}│${NC}  .py      ${BOLD}${PY_FILE_COUNT}${NC}             (bandit)      ${C}│${NC}"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  ${R}HIGH  ${NC}  "; bar "$COUNT_HIGH" "$max" "$R"
  printf "${C}│${NC}  ${Y}MEDIUM${NC}  "; bar "$COUNT_MED"  "$max" "$Y"
  printf "${C}│${NC}  ${B}LOW   ${NC}  "; bar "$COUNT_LOW"  "$max" "$B"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  echo -e "${C}│${NC}  total issues: ${BOLD}${total}${NC}                          ${C}│${NC}"

  if [[ $total -eq 0 ]]; then
    echo -e "${C}│${NC}  ${G}✓ ไม่พบปัญหา — clean!${NC}                   ${C}│${NC}"
  fi

  echo -e "${C}└──────────────────────────────────────────┘${NC}"
  echo ""
}

# ════════════════════════════════════════════════════
#  FIX HINTS — shellcheck codes
# ════════════════════════════════════════════════════
sc_hint() {
  local code="$1" msg="$2"
  case "$code" in
    SC2086) echo "→ FIX: ใส่ \"\" รอบ variable  ex: echo \"\$var\"" ;;
    SC2046) echo "→ FIX: ใส่ \"\" รอบ command substitution  ex: \"\$(cmd)\"" ;;
    SC2006) echo "→ FIX: เปลี่ยน backtick เป็น \$(...)  ex: var=\$(cmd)" ;;
    SC2034) echo "→ FIX: variable ไม่ได้ใช้ — ลบออก หรือ export ถ้าตั้งใจ" ;;
    SC2164) echo "→ FIX: เพิ่ม || exit หลัง cd  ex: cd dir || exit 1" ;;
    SC2155) echo "→ FIX: แยก declare และ assign  ex: local v; v=\$(cmd)" ;;
    SC2181) echo "→ FIX: ใช้ if cmd; แทน if [ \$? -eq 0 ]" ;;
    SC2236) echo "→ FIX: ใช้ -n แทน ! -z  ex: if [[ -n \"\$var\" ]]" ;;
    SC2317) echo "→ NOTE: code unreachable — ตรวจ logic การ return/exit" ;;
    SC1091) echo "→ NOTE: source ไฟล์หาไม่เจอ — ใส่ # shellcheck source=<path> hint" ;;
    *)      echo "→ INFO: $msg" ;;
  esac
}

# ── bandit hints ─────────────────────────────────────
bd_hint() {
  local code="$1"
  case "$code" in
    B101) echo "→ FIX: assert ถูก optimize ออกได้ — ใช้ raise Exception แทน" ;;
    B105|B106|B107) echo "→ FIX: hardcoded password/secret — ย้ายไป env var หรือ config ภายนอก" ;;
    B108) echo "→ FIX: tmp file ไม่ปลอดภัย — ใช้ tempfile.mkstemp() แทน" ;;
    B110) echo "→ FIX: try/except/pass กลืน error — อย่างน้อย log ไว้" ;;
    B201|B202) echo "→ FIX: Flask debug=True — ปิดก่อน deploy" ;;
    B301|B302|B303|B304|B305|B306) echo "→ FIX: pickle/marshal ไม่ปลอดภัยกับ untrusted data" ;;
    B307) echo "→ FIX: eval() อันตราย — หลีกเลี่ยงถ้าเป็นไปได้" ;;
    B311) echo "→ NOTE: random ไม่ crypto-safe — ใช้ secrets module ถ้าต้องการ security" ;;
    B324) echo "→ FIX: MD5/SHA1 อ่อน — ใช้ SHA256+ แทน" ;;
    B501|B502|B503|B504|B505|B506) echo "→ FIX: SSL/TLS config ไม่ปลอดภัย — เปิด verify=True" ;;
    B601|B602|B603|B604|B605|B606|B607|B608) echo "→ FIX: shell injection risk — sanitize input หรือใช้ list args" ;;
    B701|B702) echo "→ FIX: Jinja2 autoescaping ปิดอยู่ — เปิด autoescape=True" ;;
    *) echo "→ ดู: https://bandit.readthedocs.io/en/latest/plugins/${code,,}.html" ;;
  esac
}

# ════════════════════════════════════════════════════
#  PRINT ISSUES (filtered by MODE)
# ════════════════════════════════════════════════════
should_show() {
  local level="$1"
  case "$MODE" in
    high)    [[ "$level" == "HIGH" ]] ;;
    all)     true ;;
    detail)  true ;;
    ai)      true ;;
    default) [[ "$level" == "HIGH" || "$level" == "MEDIUM" ]] ;;
  esac
}

color_level() {
  case "$1" in
    HIGH)   echo -e "${R}[HIGH]  ${NC}" ;;
    MEDIUM) echo -e "${Y}[MED]   ${NC}" ;;
    LOW)    echo -e "${B}[LOW]   ${NC}" ;;
  esac
}

tool_label() {
  case "$1" in
    bash)   echo "sh " ;;
    python) echo "py " ;;
  esac
}

print_issues() {
  [[ ! -f "$RESULTS_FILE" ]] && return

  local shown=0
  local prev_tool=""

  # sort: HIGH first, then MEDIUM, then LOW
  sort -t'|' -k1,1 "$RESULTS_FILE" | \
  while IFS='|' read -r level file lineno code msg tool; do
    should_show "$level" || continue

    # tool section header
    if [[ "$tool" != "$prev_tool" ]]; then
      echo -e "${C}── ${tool} ──────────────────────────────────────${NC}"
      prev_tool="$tool"
    fi

    local clevel ctool relfile
    clevel=$(color_level "$level")
    ctool=$(tool_label "$tool")
    relfile="${file#"$SCAN_PATH/"}"

    printf "%b[%s] %s:%s  %s\n" "$clevel" "$code" "$relfile" "$lineno" "$msg"

    # show hint in detail mode
    if [[ "$MODE" == "detail" ]]; then
      local hint
      if [[ "$tool" == "bash" ]]; then
        hint=$(sc_hint "$code" "$msg")
      else
        hint=$(bd_hint "$code")
      fi
      echo -e "         ${DIM}${hint}${NC}"
    fi

    shown=$((shown + 1))
  done

  echo ""
}

# ════════════════════════════════════════════════════
#  AI EXPORT MODE
#  สร้างไฟล์ .txt ที่ copy ส่ง AI ได้ทันที
# ════════════════════════════════════════════════════
export_ai() {
  [[ ! -f "$RESULTS_FILE" ]] && return

  local ts
  ts=$(date '+%Y%m%d_%H%M%S')
  AI_FILE="${HOME}/storage/downloads/bugscan_ai_${ts}.txt"

  {
    echo "# BUGSCAN REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# path: $SCAN_PATH"
    echo "# tool: shellcheck v$(shellcheck --version 2>/dev/null | grep version: | awk '{print $2}') + bandit v$(bandit --version 2>/dev/null | awk '{print $2}')"
    echo ""
    echo "## SUMMARY"
    echo "  .sh files : $SH_FILE_COUNT"
    echo "  .py files : $PY_FILE_COUNT"
    echo "  HIGH      : $COUNT_HIGH"
    echo "  MEDIUM    : $COUNT_MED"
    echo "  LOW       : $COUNT_LOW"
    echo "  TOTAL     : $(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))"
    echo ""
    echo "## ISSUES"
    echo ""

    sort -t'|' -k1,1 "$RESULTS_FILE" | \
    while IFS='|' read -r level file lineno code msg tool; do
      local relfile="${file#"$SCAN_PATH/"}"
      printf "[%s] [%s] %s:%s\n" "$level" "$code" "$relfile" "$lineno"
      printf "  issue : %s\n" "$msg"

      local hint
      if [[ "$tool" == "bash" ]]; then
        hint=$(sc_hint "$code" "$msg")
      else
        hint=$(bd_hint "$code")
      fi
      printf "  %s\n" "$hint"
      echo ""
    done

    echo "## HOW TO USE THIS REPORT"
    echo "  paste นี้ให้ AI แล้วบอกว่า:"
    echo "  'ช่วย fix issues เหล่านี้ใน <filename> หน่อย'"
    echo "  หรือ 'อธิบาย HIGH issues ทุกตัว'"

  } > "$AI_FILE"

  echo -e "${G}✓ exported:${NC} ${BOLD}$AI_FILE${NC}"
  echo -e "  ${DIM}copy ส่ง AI ได้เลย${NC}"
  echo ""
}

# ════════════════════════════════════════════════════
#  FOOTER TIPS
# ════════════════════════════════════════════════════
print_tips() {
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
  [[ $total -eq 0 ]] && return

  echo -e "${DIM}tips:"
  [[ "$MODE" == "default" ]] && \
    echo -e "  --detail  → ดู fix hint ทุกตัว"
  [[ "$MODE" != "ai" ]] && \
    echo -e "  --ai      → export .txt ส่ง AI แก้ได้เลย"
  [[ "$MODE" != "all" ]] && \
    echo -e "  --all     → ดู LOW issues ด้วย"
  echo -e "${NC}"
}

# ════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════
main() {
  parse_args "$@"
  check_tools

  echo ""
  echo -e "${C}  bugscan v${VERSION}${NC}  scanning..."
  echo -e "${DIM}  path: $SCAN_PATH${NC}"
  [[ ${#SKIP_DIRS[@]} -gt 0 ]] && \
    echo -e "${DIM}  skip: ${SKIP_DIRS[*]}${NC}"
  echo ""

  # run analysis
  run_shellcheck
  run_bandit
  count_results

  # output
  print_summary

  if [[ "$MODE" == "ai" ]]; then
    export_ai
  else
    print_issues
    print_tips
  fi
}

main "$@"
