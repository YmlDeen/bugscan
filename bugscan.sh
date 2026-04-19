#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────┐
# │  bugscan v4.0                                   │
# │  shellcheck (bash) + bandit (python)            │
# │  + eslint (javascript) wrapper                  │
# │  Termux / aarch64 compatible                    │
# └─────────────────────────────────────────────────┘
# usage:
#   bugscan <path>            → summary + HIGH + MEDIUM
#   bugscan <path> -d         → full detail + fix hints + LOW
#   bugscan <path> -o         → export .txt + .md ส่ง AI ได้เลย
#   bugscan <path> -s <dir>   → ข้าม folder (ใช้ซ้ำได้)
#   bugscan --file <file>     → scan ไฟล์เดียว
#   bugscan <path> --json     → output JSON (ส่ง dex/axl ได้)
#   bugscan <path> --fix-dry  → preview ว่าจะ autofix อะไร
#   bugscan <path> --fix      → autofix safe issues อัตโนมัติ
#   bugscan --diff            → เทียบ 2 scan ล่าสุดใน exports/

VERSION="4.0"
EXPORT_DIR="${HOME}/projects/bugscan/exports"

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
SINGLE_FILE=""
MODE="default"
SKIP_DIRS=()
JSON_MODE=false
FIX_MODE=""        # "" | "dry" | "apply"
TMPDIR_SCAN=$(mktemp -d)
RESULTS_FILE="$TMPDIR_SCAN/results.txt"

SH_FILE_COUNT=0
PY_FILE_COUNT=0
JS_FILE_COUNT=0
COUNT_HIGH=0
COUNT_MED=0
COUNT_LOW=0
FIX_COUNT=0

cleanup() { rm -rf "$TMPDIR_SCAN"; }
trap cleanup EXIT

# ── Usage ─────────────────────────────────────────────
usage() {
  echo ""
  echo -e "${BOLD}bugscan v${VERSION}${NC} — shellcheck + bandit + eslint"
  echo ""
  echo "  bugscan <path>            summary + HIGH + MEDIUM"
  echo "  bugscan <path> -d         detail + fix hints + LOW"
  echo "  bugscan <path> -o         export .txt + .md → exports/"
  echo "  bugscan <path> -s <dir>   ข้าม dir (ใช้ซ้ำได้)"
  echo "  bugscan --file <file>     scan ไฟล์เดียว"
  echo "  bugscan <path> --json     output JSON"
  echo "  bugscan <path> --fix-dry  preview autofix"
  echo "  bugscan <path> --fix      autofix safe issues"
  echo "  bugscan --diff            เทียบ 2 scan ล่าสุด"
  echo ""
  echo "  examples:"
  echo "    bugscan ."
  echo "    bugscan --file myscript.sh"
  echo "    bugscan ~/projects/dex -o"
  echo "    bugscan . -d -s node_modules"
  echo "    bugscan . --fix-dry"
  echo "    bugscan . --fix"
  echo "    bugscan . --json"
  echo "    bugscan --diff"
  echo ""
}

# ── Parse Args ────────────────────────────────────────
parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }

  if [[ "$1" == "--diff" ]]; then
    MODE="diff"; return
  fi

  if [[ "$1" == "--file" ]]; then
    shift
    [[ -z "$1" ]] && { echo -e "${R}error:${NC} --file ต้องระบุชื่อไฟล์"; exit 1; }
    [[ ! -f "$1" ]] && { echo -e "${R}error:${NC} ไฟล์ไม่พบ: $1"; exit 1; }
    SINGLE_FILE=$(realpath "$1")
    SCAN_PATH=$(dirname "$SINGLE_FILE")
    shift
  else
    SCAN_PATH="$1"; shift
    [[ ! -e "$SCAN_PATH" ]] && {
      echo -e "${R}error:${NC} not found: $SCAN_PATH"; exit 1
    }
    SCAN_PATH=$(realpath "$SCAN_PATH")
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d)         MODE="detail" ;;
      -o)         MODE="export" ;;
      -s)         shift; SKIP_DIRS+=("$1") ;;
      --json)     JSON_MODE=true ;;
      --fix-dry)  FIX_MODE="dry" ;;
      --fix)      FIX_MODE="apply" ;;
      -h|--help)  usage; exit 0 ;;
      *) echo -e "${R}unknown option:${NC} $1"; usage; exit 1 ;;
    esac
    shift
  done
}

# ── Check Tools ───────────────────────────────────────
HAS_SC=false
HAS_BD=false
HAS_ES=false
check_tools() {
  command -v shellcheck &>/dev/null && HAS_SC=true
  command -v bandit     &>/dev/null && HAS_BD=true
  command -v eslint     &>/dev/null && HAS_ES=true

  if ! $HAS_SC && ! $HAS_BD && ! $HAS_ES; then
    echo -e "${R}error:${NC} ไม่พบ tools"
    echo "  pkg install shellcheck"
    echo "  pip install bandit --break-system-packages"
    echo "  npm install -g eslint"
    exit 1
  fi
  $HAS_SC || echo -e "${Y}warn:${NC} shellcheck ไม่พบ — ข้าม .sh"
  $HAS_BD || echo -e "${Y}warn:${NC} bandit ไม่พบ — ข้าม .py"
  $HAS_ES || echo -e "${Y}warn:${NC} eslint ไม่พบ — ข้าม .js"
}

# ── Find files ────────────────────────────────────────
find_files() {
  local ext="$1"

  # single file mode
  if [[ -n "$SINGLE_FILE" ]]; then
    [[ "$SINGLE_FILE" == *".$ext" ]] && echo "$SINGLE_FILE"
    return
  fi

  local args=()
  args+=("$SCAN_PATH" -type f -name "*.$ext")
  for d in "${SKIP_DIRS[@]}"; do
    args+=(-not -path "*/${d}/*" -not -path "*/${d}")
  done
  find "${args[@]}" 2>/dev/null
}

# ── Severity mapping ──────────────────────────────────
sc_level() {
  case "$1" in
    error)   echo "HIGH"   ;;
    warning) echo "MEDIUM" ;;
    *)       echo "LOW"    ;;
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
    while IFS= read -r raw; do
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
#  BANDIT
# ════════════════════════════════════════════════════
run_bandit() {
  $HAS_BD || return
  local files=()
  mapfile -t files < <(find_files "py")
  PY_FILE_COUNT=${#files[@]}
  [[ $PY_FILE_COUNT -eq 0 ]] && return

  local excl=""
  for d in "${SKIP_DIRS[@]}"; do
    excl+="${SCAN_PATH}/${d},"
  done
  excl="${excl%,}"

  local bd_args=(-r "$SCAN_PATH" -f txt -q)
  [[ -n "$SINGLE_FILE" ]] && bd_args=("$SINGLE_FILE" -f txt -q)
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
#  ESLINT
# ════════════════════════════════════════════════════
run_eslint() {
  $HAS_ES || return
  local files=()
  mapfile -t files < <(find_files "js")
  JS_FILE_COUNT=${#files[@]}
  [[ $JS_FILE_COUNT -eq 0 ]] && return

  local cfg_arg=""
  local check_dir="$SCAN_PATH"
  while [[ "$check_dir" != "/" ]]; do
    for cfg in eslint.config.js eslint.config.mjs eslint.config.cjs; do
      [[ -f "$check_dir/$cfg" ]] && { cfg_arg="--no-ignore"; break 2; }
    done
    check_dir=$(dirname "$check_dir")
  done

  for f in "${files[@]}"; do
    [[ "$f" == *"/node_modules/"* ]] && continue
    while IFS= read -r raw; do
      if [[ "$raw" =~ ^(.+):([0-9]+):[0-9]+:\ (error|warning):\ (.+)\ \[(.+)\]$ ]]; then
        local file="${BASH_REMATCH[1]}"
        local lineno="${BASH_REMATCH[2]}"
        local sev="${BASH_REMATCH[3]}"
        local msg="${BASH_REMATCH[4]}"
        local code="${BASH_REMATCH[5]}"
        local level
        [[ "$sev" == "error" ]] && level="HIGH" || level="MEDIUM"
        echo "${level}|${file}|${lineno}|${code}|${msg}|javascript" >> "$RESULTS_FILE"
      fi
    done < <(eslint --format compact $cfg_arg "$f" 2>/dev/null)
  done
}

# ── Count ─────────────────────────────────────────────
count_results() {
  [[ ! -f "$RESULTS_FILE" ]] && return
  COUNT_HIGH=$(grep -c '^HIGH|'   "$RESULTS_FILE" 2>/dev/null | head -1 || echo 0)
  COUNT_MED=$(grep  -c '^MEDIUM|' "$RESULTS_FILE" 2>/dev/null | head -1 || echo 0)
  COUNT_LOW=$(grep  -c '^LOW|'    "$RESULTS_FILE" 2>/dev/null | head -1 || echo 0)
  COUNT_HIGH=$(( COUNT_HIGH + 0 ))
  COUNT_MED=$(( COUNT_MED + 0 ))
  COUNT_LOW=$(( COUNT_LOW + 0 ))
}

# ── Bar chart ─────────────────────────────────────────
bar() {
  local n=$1 max=$2 color=$3
  local width=20 filled=0
  [[ $max -gt 0 ]] && filled=$(( n * width / max ))
  local b=""
  for ((i=0; i<filled; i++));      do b+="█"; done
  for ((i=filled; i<width; i++)); do b+="░"; done
  echo -e "${color}${b}${NC} ${BOLD}${n}${NC}"
}

# ════════════════════════════════════════════════════
#  SUMMARY BOX
# ════════════════════════════════════════════════════
print_summary() {
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
  local max=$(( COUNT_HIGH > COUNT_MED ? COUNT_HIGH : COUNT_MED ))
  max=$(( max > COUNT_LOW ? max : COUNT_LOW ))
  [[ $max -eq 0 ]] && max=1

  local label="$SCAN_PATH"
  [[ -n "$SINGLE_FILE" ]] && label="$SINGLE_FILE"

  echo ""
  echo -e "${C}┌──────────────────────────────────────────┐${NC}"
  echo -e "${C}│  bugscan v${VERSION}${NC}                              ${C}│${NC}"
  echo -e "${C}│  ${DIM}$(printf '%-42s' "$label")${NC}${C}│${NC}"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  echo -e "${C}│${NC}  .sh  ${BOLD}${SH_FILE_COUNT}${NC} files (shellcheck)                ${C}│${NC}"
  echo -e "${C}│${NC}  .py  ${BOLD}${PY_FILE_COUNT}${NC} files (bandit)                    ${C}│${NC}"
  echo -e "${C}│${NC}  .js  ${BOLD}${JS_FILE_COUNT}${NC} files (eslint)                    ${C}│${NC}"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  ${R}HIGH  ${NC}  "; bar "$COUNT_HIGH" "$max" "$R"
  printf "${C}│${NC}  ${Y}MEDIUM${NC}  "; bar "$COUNT_MED"  "$max" "$Y"
  printf "${C}│${NC}  ${B}LOW   ${NC}  "; bar "$COUNT_LOW"  "$max" "$B"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  echo -e "${C}│${NC}  total: ${BOLD}${total}${NC}                                  ${C}│${NC}"
  if [[ $total -eq 0 ]]; then
    echo -e "${C}│${NC}  ${G}✓ clean — ไม่พบปัญหา${NC}                    ${C}│${NC}"
  fi
  echo -e "${C}└──────────────────────────────────────────┘${NC}"
  echo ""
}

# ════════════════════════════════════════════════════
#  FIX HINTS
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

bd_hint() {
  local code="$1"
  case "$code" in
    B101)             echo "→ FIX: assert ถูก optimize ออกได้ — ใช้ raise Exception แทน" ;;
    B105|B106|B107)   echo "→ FIX: hardcoded password/secret — ย้ายไป env var หรือ config ภายนอก" ;;
    B108)             echo "→ FIX: tmp file ไม่ปลอดภัย — ใช้ tempfile.mkstemp() แทน" ;;
    B110)             echo "→ FIX: try/except/pass กลืน error — อย่างน้อย log ไว้" ;;
    B201|B202)        echo "→ FIX: Flask debug=True — ปิดก่อน deploy" ;;
    B301|B302|B303|B304|B305|B306) echo "→ FIX: pickle/marshal ไม่ปลอดภัยกับ untrusted data" ;;
    B307)             echo "→ FIX: eval() อันตราย — หลีกเลี่ยงถ้าเป็นไปได้" ;;
    B311)             echo "→ NOTE: random ไม่ crypto-safe — ใช้ secrets module ถ้าต้องการ security" ;;
    B324)             echo "→ FIX: MD5/SHA1 อ่อน — ใช้ SHA256+ แทน" ;;
    B501|B502|B503|B504|B505|B506) echo "→ FIX: SSL/TLS config ไม่ปลอดภัย — เปิด verify=True" ;;
    B601|B602|B603|B604|B605|B606|B607|B608) echo "→ FIX: shell injection risk — sanitize input หรือใช้ list args" ;;
    B701|B702)        echo "→ FIX: Jinja2 autoescaping ปิดอยู่ — เปิด autoescape=True" ;;
    *)                echo "→ ดู: https://bandit.readthedocs.io/en/latest/plugins/${code,,}.html" ;;
  esac
}

# ── is_fixable: เช็คว่า code นี้ autofix ได้ไหม ────────
is_fixable() {
  case "$1" in
    SC2006|SC2164) return 0 ;;  # safe to autofix
    *) return 1 ;;
  esac
}

# ════════════════════════════════════════════════════
#  AUTOFIX ENGINE
# ════════════════════════════════════════════════════
run_autofix() {
  local dry="$1"   # "dry" หรือ "apply"
  [[ ! -f "$RESULTS_FILE" ]] && return

  echo ""
  if [[ "$dry" == "dry" ]]; then
    echo -e "${C}── autofix preview (--fix-dry) ──────────────────${NC}"
    echo -e "${DIM}  ไม่มีการแก้ไฟล์จริง — แค่แสดงว่าจะทำอะไร${NC}"
  else
    echo -e "${C}── autofix (--fix) ───────────────────────────────${NC}"
    echo -e "${Y}  backup ไฟล์ที่แก้ไว้ที่ <file>.bak${NC}"
  fi
  echo ""

  # รวม fixes ตาม file
  local prev_file=""
  local fixed_files=()

  while IFS='|' read -r level file lineno code msg tool; do
    [[ "$tool" != "bash" ]] && continue
    is_fixable "$code" || continue

    if [[ "$file" != "$prev_file" ]]; then
      echo -e "  ${BOLD}${file#"$SCAN_PATH/"}${NC}"
      prev_file="$file"
    fi

    case "$code" in
      SC2006)
        echo -e "    ${Y}[${code}]${NC} line ${lineno}: backtick → \$()"
        if [[ "$dry" == "apply" ]]; then
          # backup ครั้งแรกที่เจอไฟล์นี้
          [[ ! -f "${file}.bak" ]] && cp "$file" "${file}.bak"
          # replace backtick `cmd` → $(cmd)  — simple single-line cases
          sed -i "s/\`\([^\`]*\)\`/\$(\1)/g" "$file"
          fixed_files+=("$file")
          FIX_COUNT=$(( FIX_COUNT + 1 ))
        fi
        ;;
      SC2164)
        echo -e "    ${Y}[${code}]${NC} line ${lineno}: cd ไม่มี || exit"
        if [[ "$dry" == "apply" ]]; then
          [[ ! -f "${file}.bak" ]] && cp "$file" "${file}.bak"
          # เพิ่ม || exit 1 หลัง cd ที่ยังไม่มี
          sed -i "/^[[:space:]]*cd [^|]*$/s/$/ || exit 1/" "$file"
          fixed_files+=("$file")
          FIX_COUNT=$(( FIX_COUNT + 1 ))
        fi
        ;;
    esac
  done < <(sort -t'|' -k3,3n "$RESULTS_FILE")

  echo ""
  if [[ "$dry" == "apply" && $FIX_COUNT -gt 0 ]]; then
    echo -e "${G}✓ autofix เสร็จ — แก้ ${FIX_COUNT} จุด${NC}"
    echo -e "${DIM}  backup ไว้ที่ <file>.bak — ลบได้ถ้าผลโอเค${NC}"
    echo -e "${DIM}  แนะนำ: bugscan . เพื่อตรวจผลหลัง fix${NC}"
  elif [[ "$dry" == "dry" && $FIX_COUNT -eq 0 ]]; then
    # นับจาก preview
    local fixable=0
    while IFS='|' read -r level file lineno code msg tool; do
      [[ "$tool" == "bash" ]] && is_fixable "$code" && fixable=$(( fixable + 1 ))
    done < "$RESULTS_FILE"
    [[ $fixable -eq 0 ]] && echo -e "${DIM}  ไม่มี issue ที่ autofix ได้ในตอนนี้${NC}"
  fi
  echo ""
}

# ════════════════════════════════════════════════════
#  PRINT ISSUES
# ════════════════════════════════════════════════════
color_level() {
  case "$1" in
    HIGH)   echo -e "${R}[HIGH]  ${NC}" ;;
    MEDIUM) echo -e "${Y}[MED]   ${NC}" ;;
    LOW)    echo -e "${B}[LOW]   ${NC}" ;;
  esac
}

should_show() {
  local level="$1"
  case "$MODE" in
    detail|export) true ;;
    default) [[ "$level" == "HIGH" || "$level" == "MEDIUM" ]] ;;
  esac
}

print_issues() {
  [[ ! -f "$RESULTS_FILE" ]] && return
  local prev_tool=""

  sort -t'|' -k1,1 "$RESULTS_FILE" | \
  while IFS='|' read -r level file lineno code msg tool; do
    should_show "$level" || continue

    if [[ "$tool" != "$prev_tool" ]]; then
      echo -e "${C}── ${tool} ──────────────────────────────────────${NC}"
      prev_tool="$tool"
    fi

    local clevel relfile
    clevel=$(color_level "$level")
    relfile="${file#"$SCAN_PATH/"}"

    printf "%b[%s] %s:%s  %s\n" "$clevel" "$code" "$relfile" "$lineno" "$msg"

    if [[ "$MODE" == "detail" ]]; then
      local hint
      [[ "$tool" == "bash" ]] && hint=$(sc_hint "$code" "$msg") || hint=$(bd_hint "$code")
      echo -e "         ${DIM}${hint}${NC}"
    fi
  done
  echo ""
}

# ════════════════════════════════════════════════════
#  JSON OUTPUT
# ════════════════════════════════════════════════════
print_json() {
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
  local label="$SCAN_PATH"
  [[ -n "$SINGLE_FILE" ]] && label="$SINGLE_FILE"

  echo "{"
  echo "  \"version\": \"${VERSION}\","
  echo "  \"path\": \"${label}\","
  echo "  \"summary\": {"
  echo "    \"high\": ${COUNT_HIGH},"
  echo "    \"medium\": ${COUNT_MED},"
  echo "    \"low\": ${COUNT_LOW},"
  echo "    \"total\": ${total}"
  echo "  },"
  echo "  \"issues\": ["

  local first=true
  if [[ -f "$RESULTS_FILE" ]]; then
    while IFS='|' read -r level file lineno code msg tool; do
      local relfile="${file#"$SCAN_PATH/"}"
      # escape quotes in msg
      msg="${msg//\"/\\\"}"
      if [[ "$first" == true ]]; then
        first=false
      else
        echo ","
      fi
      printf '    {"level":"%s","file":"%s","line":%s,"code":"%s","msg":"%s","tool":"%s"}' \
        "$level" "$relfile" "$lineno" "$code" "$msg" "$tool"
    done < <(sort -t'|' -k1,1 "$RESULTS_FILE")
  fi

  echo ""
  echo "  ]"
  echo "}"
}

# ════════════════════════════════════════════════════
#  EXPORT MODE — .txt + .md พร้อมกัน
# ════════════════════════════════════════════════════
export_files() {
  [[ ! -f "$RESULTS_FILE" ]] && return
  mkdir -p "$EXPORT_DIR"

  local ts
  ts=$(date '+%Y%m%d_%H%M%S')
  local txt_file="${EXPORT_DIR}/bugscan_${ts}.txt"
  local md_file="${EXPORT_DIR}/bugscan_${ts}.md"

  local sc_ver bd_ver
  sc_ver=$(shellcheck --version 2>/dev/null | grep 'version:' | awk '{print $2}')
  bd_ver=$(bandit --version 2>/dev/null | awk '{print $2}')
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
  local label="$SCAN_PATH"
  [[ -n "$SINGLE_FILE" ]] && label="$SINGLE_FILE"

  # ── .txt (AI-ready) ──────────────────────────────
  {
    echo "# BUGSCAN REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# path: $label"
    echo "# tool: shellcheck v${sc_ver} + bandit v${bd_ver} + eslint"
    echo "# version: bugscan v${VERSION}"
    echo ""
    echo "## SUMMARY"
    echo "  .sh files : $SH_FILE_COUNT"
    echo "  .py files : $PY_FILE_COUNT"
    echo "  .js files : $JS_FILE_COUNT"
    echo "  HIGH      : $COUNT_HIGH"
    echo "  MEDIUM    : $COUNT_MED"
    echo "  LOW       : $COUNT_LOW"
    echo "  TOTAL     : $total"
    echo ""
    echo "## ISSUES"
    echo ""
    sort -t'|' -k1,1 "$RESULTS_FILE" | \
    while IFS='|' read -r level file lineno code msg tool; do
      local relfile="${file#"$SCAN_PATH/"}"
      printf "[%s] [%s] %s:%s\n" "$level" "$code" "$relfile" "$lineno"
      printf "  issue : %s\n" "$msg"
      local hint
      [[ "$tool" == "bash" ]] && hint=$(sc_hint "$code" "$msg") || hint=$(bd_hint "$code")
      printf "  %s\n\n" "$hint"
    done
    echo "## HOW TO USE"
    echo "  paste ให้ Claude แล้วบอกว่า:"
    echo "  'ช่วย fix issues เหล่านี้ใน <filename>'"
    echo "  หรือ 'อธิบาย HIGH issues ทุกตัว'"
  } > "$txt_file"

  # ── .md (human-readable) ──────────────────────────
  {
    echo "# 🐛 Bugscan Report"
    echo ""
    echo "> **Date:** $(date '+%Y-%m-%d %H:%M:%S')  "
    echo "> **Path:** \`$label\`  "
    echo "> **Tools:** shellcheck v${sc_ver} · bandit v${bd_ver} · eslint"
    echo "> **bugscan:** v${VERSION}"
    echo ""
    echo "## Summary"
    echo ""
    echo "| | Count |"
    echo "|---|---|"
    echo "| 🔴 HIGH | $COUNT_HIGH |"
    echo "| 🟡 MEDIUM | $COUNT_MED |"
    echo "| 🔵 LOW | $COUNT_LOW |"
    echo "| **TOTAL** | **$total** |"
    echo ""

    for lvl in HIGH MEDIUM LOW; do
      local count icon
      case "$lvl" in
        HIGH)   count=$COUNT_HIGH; icon="🔴" ;;
        MEDIUM) count=$COUNT_MED;  icon="🟡" ;;
        LOW)    count=$COUNT_LOW;  icon="🔵" ;;
      esac
      [[ $count -eq 0 ]] && continue

      echo "## ${icon} ${lvl} (${count})"
      echo ""

      grep "^${lvl}|" "$RESULTS_FILE" | sort | \
      while IFS='|' read -r level file lineno code msg tool; do
        local relfile="${file#"$SCAN_PATH/"}"
        local hint
        [[ "$tool" == "bash" ]] && hint=$(sc_hint "$code" "$msg") || hint=$(bd_hint "$code")
        echo "### \`${code}\` — ${relfile}:${lineno}"
        echo ""
        echo "**issue:** ${msg}  "
        echo "**${hint}**"
        echo ""
      done
    done

    [[ $total -eq 0 ]] && echo "## ✅ Clean — ไม่พบปัญหา"
  } > "$md_file"

  echo -e "${G}✓ exported:${NC}"
  echo -e "  ${BOLD}$txt_file${NC}  ${DIM}← ส่ง AI${NC}"
  echo -e "  ${BOLD}$md_file${NC}   ${DIM}← อ่านเอง${NC}"
  echo ""
}

# ════════════════════════════════════════════════════
#  DIFF MODE
# ════════════════════════════════════════════════════
run_diff() {
  mkdir -p "$EXPORT_DIR"
  local files=()
  mapfile -t files < <(ls -t "${EXPORT_DIR}"/bugscan_*.txt 2>/dev/null)

  if [[ ${#files[@]} -lt 2 ]]; then
    echo -e "${Y}warn:${NC} ต้องมี export อย่างน้อย 2 ครั้ง (bugscan <path> -o)"
    exit 1
  fi

  local new="${files[0]}"
  local old="${files[1]}"

  _get() { grep "  $2" "$1" | awk '{print $NF}'; }

  local old_h old_m old_l new_h new_m new_l
  old_h=$(_get "$old" "HIGH");   old_h=${old_h:-0}
  old_m=$(_get "$old" "MEDIUM"); old_m=${old_m:-0}
  old_l=$(_get "$old" "LOW");    old_l=${old_l:-0}
  new_h=$(_get "$new" "HIGH");   new_h=${new_h:-0}
  new_m=$(_get "$new" "MEDIUM"); new_m=${new_m:-0}
  new_l=$(_get "$new" "LOW");    new_l=${new_l:-0}

  _delta() {
    local d=$(( $2 - $1 ))
    if   [[ $d -lt 0 ]]; then echo -e "${G}${d}${NC}"
    elif [[ $d -gt 0 ]]; then echo -e "${R}+${d}${NC}"
    else echo -e "${DIM}±0${NC}"
    fi
  }

  local old_ts new_ts
  old_ts=$(basename "$old" | sed 's/bugscan_//;s/.txt//')
  new_ts=$(basename "$new" | sed 's/bugscan_//;s/.txt//')

  echo ""
  echo -e "${C}┌──────────────────────────────────────────┐${NC}"
  echo -e "${C}│  bugscan --diff${NC}                              ${C}│${NC}"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  %-10s  %6s  %6s  %6s  %6s ${C}│${NC}\n" "" "HIGH" "MED" "LOW" "TOTAL"
  printf "${C}│${NC}  %-10s  %6s  %6s  %6s  %6s ${C}│${NC}\n" \
    "$old_ts" "$old_h" "$old_m" "$old_l" "$(( old_h+old_m+old_l ))"
  printf "${C}│${NC}  %-10s  %6s  %6s  %6s  %6s ${C}│${NC}\n" \
    "$new_ts" "$new_h" "$new_m" "$new_l" "$(( new_h+new_m+new_l ))"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  %-10s  " "delta"
  _delta "$old_h" "$new_h"; printf "  "
  _delta "$old_m" "$new_m"; printf "  "
  _delta "$old_l" "$new_l"; printf "  "
  _delta "$(( old_h+old_m+old_l ))" "$(( new_h+new_m+new_l ))"
  echo -e "  ${C}│${NC}"
  echo -e "${C}└──────────────────────────────────────────┘${NC}"
  echo ""
}

# ════════════════════════════════════════════════════
#  TIPS
# ════════════════════════════════════════════════════
print_tips() {
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
  [[ $total -eq 0 ]] && return
  echo -e "${DIM}tips:"
  [[ "$MODE" == "default" ]] && echo -e "  -d        → ดู fix hints + LOW"
  echo -e "  -o        → export .txt + .md"
  echo -e "  --fix-dry → preview autofix"
  echo -e "  --fix     → autofix safe issues"
  echo -e "${NC}"
}

# ════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════
main() {
  parse_args "$@"

  if [[ "$MODE" == "diff" ]]; then
    run_diff; exit 0
  fi

  check_tools

  echo ""
  echo -e "${C}  bugscan v${VERSION}${NC}  scanning..."
  local label="$SCAN_PATH"
  [[ -n "$SINGLE_FILE" ]] && label="$SINGLE_FILE"
  echo -e "${DIM}  path: $label${NC}"
  [[ ${#SKIP_DIRS[@]} -gt 0 ]] && echo -e "${DIM}  skip: ${SKIP_DIRS[*]}${NC}"
  echo ""

  run_shellcheck
  run_bandit
  run_eslint
  count_results

  # JSON mode — print และจบ
  if $JSON_MODE; then
    print_json
    exit 0
  fi

  print_summary

  # autofix mode
  if [[ -n "$FIX_MODE" ]]; then
    run_autofix "$FIX_MODE"
    [[ "$FIX_MODE" == "apply" ]] && exit 0
  fi

  if [[ "$MODE" == "export" ]]; then
    export_files
  else
    print_issues
    print_tips
  fi
}

main "$@"
