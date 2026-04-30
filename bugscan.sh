#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────┐
# │  bugscan v7.0                                   │
# │  shellcheck (bash) + bandit (python)            │
# │  + eslint (javascript/typescript)               │
# │  + pattern check                                │
# │  + code snippets + AI-ready prompts             │
# │  Termux / aarch64 compatible                    │
# └─────────────────────────────────────────────────┘
# usage:
#   bugscan <path>            → summary + HIGH + MEDIUM
#   bugscan <path> -d         → full detail + fix hints + LOW + snippets
#   bugscan <path> -o         → export .txt พร้อม prompt สำเร็จรูป → $DL
#   bugscan <path> -s <dir>   → ข้าม folder (ใช้ซ้ำได้)
#   bugscan --file <file>     → scan ไฟล์เดียว
#   bugscan <path> --json     → output JSON
#   bugscan <path> --fix-dry  → preview autofix
#   bugscan <path> --fix      → autofix safe issues
#   bugscan --diff            → เทียบ 2 scan ล่าสุด
#   bugscan <path> --pattern  → pattern check อย่างเดียว
#   bugscan <path> --ask      → export + เปิด prompt พร้อม paste ใน Claude

VERSION="7.0"
DL="/storage/emulated/0/Download"
SNIPPET_CONTEXT=3  # บรรทัดรอบข้าง issue

# ── Colors ──────────────────────────────────────────
R='\033[0;31m'
Y='\033[1;33m'
G='\033[0;32m'
C='\033[0;36m'
B='\033[1;34m'
M='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Default skip ─────────────────────────────────────
DEFAULT_SKIP=(node_modules dist bundle.js .git __pycache__ .pytest_cache venv)

# ── State ────────────────────────────────────────────
SCAN_PATH=""
SINGLE_FILE=""
MODE="default"
SKIP_DIRS=()
JSON_MODE=false
FIX_MODE=""
PATTERN_ONLY=false
ASK_MODE=false
TMPDIR_SCAN=$(mktemp -d)
RESULTS_FILE="$TMPDIR_SCAN/results.txt"
PATTERN_FILE="$TMPDIR_SCAN/patterns.txt"

SH_FILE_COUNT=0
PY_FILE_COUNT=0
JS_FILE_COUNT=0
TS_FILE_COUNT=0
COUNT_HIGH=0
COUNT_MED=0
COUNT_LOW=0
COUNT_PATTERN=0
FIX_COUNT=0

cleanup() { rm -rf "$TMPDIR_SCAN"; }
trap cleanup EXIT

# ── Usage ─────────────────────────────────────────────
usage() {
  echo ""
  echo -e "${BOLD}bugscan v${VERSION}${NC} — shellcheck + bandit + eslint + pattern + AI-ready"
  echo ""
  echo "  bugscan <path>            summary + HIGH + MEDIUM"
  echo "  bugscan <path> -d         detail + fix hints + LOW + snippets"
  echo "  bugscan <path> -o         export .txt พร้อม prompt สำเร็จรูป → \$DL"
  echo "  bugscan <path> --ask      export + แสดง prompt พร้อม paste ให้ Claude"
  echo "  bugscan <path> -s <dir>   ข้าม dir (ใช้ซ้ำได้)"
  echo "  bugscan --file <file>     scan ไฟล์เดียว"
  echo "  bugscan <path> --json     output JSON"
  echo "  bugscan <path> --fix-dry  preview autofix"
  echo "  bugscan <path> --fix      autofix safe issues"
  echo "  bugscan <path> --pattern  pattern check เท่านั้น"
  echo "  bugscan --diff            เทียบ 2 scan ล่าสุด"
  echo ""
  echo "  examples:"
  echo "    bugscan ."
  echo "    bugscan --file myscript.sh"
  echo "    bugscan ~/projects/linkbox -o"
  echo "    bugscan . -d -s node_modules"
  echo "    bugscan . --ask"
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
      -d)          MODE="detail" ;;
      -o)          MODE="export" ;;
      -s)          shift; SKIP_DIRS+=("$1") ;;
      --json)      JSON_MODE=true ;;
      --fix-dry)   FIX_MODE="dry" ;;
      --fix)       FIX_MODE="apply" ;;
      --pattern)   PATTERN_ONLY=true ;;
      --ask)       ASK_MODE=true; MODE="export" ;;
      -h|--help)   usage; exit 0 ;;
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

  if ! $HAS_SC && ! $HAS_BD && ! $HAS_ES && ! $PATTERN_ONLY; then
    echo -e "${R}error:${NC} ไม่พบ tools"
    echo "  pkg install shellcheck"
    echo "  pip install bandit --break-system-packages"
    echo "  npm install -g eslint"
    exit 1
  fi
  $HAS_SC || echo -e "${Y}warn:${NC} shellcheck ไม่พบ — ข้าม .sh"
  $HAS_BD || echo -e "${Y}warn:${NC} bandit ไม่พบ — ข้าม .py"
  $HAS_ES || echo -e "${Y}warn:${NC} eslint ไม่พบ — ข้าม .js/.ts"
}

# ── Find files ────────────────────────────────────────
find_files() {
  local ext="$1"

  if [[ -n "$SINGLE_FILE" ]]; then
    [[ "$SINGLE_FILE" == *".$ext" ]] && echo "$SINGLE_FILE"
    return
  fi

  local args=()
  args+=("$SCAN_PATH" -type f -name "*.$ext")

  local all_skip=("${DEFAULT_SKIP[@]}" "${SKIP_DIRS[@]}")
  for d in "${all_skip[@]}"; do
    args+=(-not -path "*/${d}/*" -not -path "*/${d}" -not -name "$d")
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
#  GET CODE SNIPPET — ดึง code จริงรอบบรรทัด issue
# ════════════════════════════════════════════════════
get_snippet() {
  local file="$1"
  local lineno="$2"
  local context="${3:-$SNIPPET_CONTEXT}"

  [[ ! -f "$file" ]] && return
  [[ ! "$lineno" =~ ^[0-9]+$ ]] && return

  local total_lines
  total_lines=$(wc -l < "$file" 2>/dev/null)
  [[ -z "$total_lines" || "$total_lines" -eq 0 ]] && return

  local start=$(( lineno - context ))
  local end=$(( lineno + context ))
  [[ $start -lt 1 ]] && start=1
  [[ $end -gt $total_lines ]] && end=$total_lines

  awk -v s="$start" -v e="$end" -v target="$lineno" '
    NR >= s && NR <= e {
      marker = (NR == target) ? ">>>" : "   "
      printf "%s %4d | %s\n", marker, NR, $0
    }
  ' "$file"
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
#  ESLINT (js + ts)
# ════════════════════════════════════════════════════
run_eslint() {
  $HAS_ES || return
  local files=()
  mapfile -t files < <(find_files "js"; find_files "ts"; find_files "tsx"; find_files "jsx")
  JS_FILE_COUNT=${#files[@]}
  [[ $JS_FILE_COUNT -eq 0 ]] && return

  local cfg_arg=""
  local check_dir="$SCAN_PATH"
  while [[ "$check_dir" != "/" ]]; do
    for cfg in eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc.js .eslintrc.json; do
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
        local lang="javascript"
        [[ "$f" == *.ts || "$f" == *.tsx ]] && lang="typescript"
        echo "${level}|${file}|${lineno}|${code}|${msg}|${lang}" >> "$RESULTS_FILE"
      fi
    done < <(eslint --format compact $cfg_arg "$f" 2>/dev/null)
  done
}

# ════════════════════════════════════════════════════
#  PATTERN CHECK
# ════════════════════════════════════════════════════
run_pattern_check() {
  local files=()
  mapfile -t files < <(
    find_files "js"
    find_files "ts"
    find_files "jsx"
    find_files "tsx"
    find_files "sh"

  )

  [[ ${#files[@]} -eq 0 ]] && return

  for f in "${files[@]}"; do
    local ext="${f##*.}"

    # P1: console.log หลุด production
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "jsx" || "$ext" == "tsx" ]]; then
      if grep -qn 'console\.log' "$f" 2>/dev/null; then
        local lineno
        lineno=$(grep -n 'console\.log' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${lineno}|P001|console.log หลุด production — ควรใช้ debug filter หรือ logger|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P2: async ไม่มี try/catch
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "jsx" || "$ext" == "tsx" ]]; then
      local async_lines trycatch_lines
      async_lines=$(grep -c 'async function\|async (' "$f" 2>/dev/null); async_lines=$(( async_lines + 0 ))
      trycatch_lines=$(grep -c 'try {' "$f" 2>/dev/null); trycatch_lines=$(( trycatch_lines + 0 ))
      if [[ $async_lines -gt 0 && $trycatch_lines -eq 0 ]]; then
        echo "PATTERN|${f}|1|P002|มี async ${async_lines} จุด แต่ไม่มี try/catch เลย — เสี่ยง unhandled rejection|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P3: server ไม่มี cleanup
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      local has_server has_cleanup
      has_server=$(grep -c 'listen\|createServer\|express()' "$f" 2>/dev/null); has_server=$(( has_server + 0 ))
      has_cleanup=$(grep -c 'process\.on.*exit\|process\.on.*SIGINT\|process\.on.*SIGTERM' "$f" 2>/dev/null); has_cleanup=$(( has_cleanup + 0 ))
      if [[ $has_server -gt 0 && $has_cleanup -eq 0 ]]; then
        echo "PATTERN|${f}|1|P003|มี server แต่ไม่มี process exit handler — ควรเพิ่ม SIGINT/SIGTERM cleanup|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P4: fs.write ไม่มี error handling
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      if grep -qn 'fs\.writeFile\|fs\.appendFile\|fs\.writeFileSync' "$f" 2>/dev/null; then
        local write_lines
        write_lines=$(grep -n 'fs\.writeFile\|fs\.appendFile\|fs\.writeFileSync' "$f" | head -1 | cut -d: -f1)
        local near_catch
        near_catch=$(grep -c 'catch\|\.catch(' "$f" 2>/dev/null); near_catch=$(( near_catch + 0 ))
        if [[ $near_catch -eq 0 ]]; then
          echo "PATTERN|${f}|${write_lines}|P004|fs.write ไม่มี error handling — ไฟล์เขียนล้มเหลวจะ silent fail|pattern" >> "$PATTERN_FILE"
        fi
      fi
    fi

    # P5: hardcoded secret
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "sh" || "$ext" == "py" ]]; then
      local secret_line
      secret_line=$(grep -in 'api_key\s*=\s*["'"'"'][^$"'"'"']\|password\s*=\s*["'"'"'][^$"'"'"']\|secret\s*=\s*["'"'"'][^$"'"'"']' "$f" 2>/dev/null | head -1)
      if [[ -n "$secret_line" ]]; then
        local lineno
        lineno=$(echo "$secret_line" | cut -d: -f1)
        echo "PATTERN|${f}|${lineno}|P005|hardcoded secret/password — ย้ายไป .env หรือ process.env|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P6: shell script ไม่มี set -e
    if [[ "$ext" == "sh" ]]; then
      if ! grep -q 'set -e\|set -euo\|set -eu' "$f" 2>/dev/null; then
        echo "PATTERN|${f}|1|P006|script ไม่มี set -euo pipefail — error จะถูกกลืนโดยไม่รู้ตัว|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P7: .env ถูก commit
    if [[ "$f" == *".env" && "$f" != *".env.example"* && "$f" != *".env.sample"* ]]; then
      echo "PATTERN|${f}|1|P007|ไฟล์ .env อยู่ใน project — ตรวจว่าอยู่ใน .gitignore แล้วหรือยัง|pattern" >> "$PATTERN_FILE"
    fi

    # P8: input validation หายไป (JS/TS)
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      local has_req has_validate
      has_req=$(grep -c 'req\.body\|req\.params\|req\.query' "$f" 2>/dev/null); has_req=$(( has_req + 0 ))
      has_validate=$(grep -c 'validate\|sanitize\|joi\|zod\|yup\|express-validator' "$f" 2>/dev/null); has_validate=$(( has_validate + 0 ))
      if [[ $has_req -gt 2 && $has_validate -eq 0 ]]; then
        local lineno
        lineno=$(grep -n 'req\.body\|req\.params\|req\.query' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${lineno}|P008|ใช้ req.body/params ${has_req} จุด แต่ไม่มี input validation — SQL injection / XSS risk|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P9: SQL query แบบ string concat
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "py" ]]; then
      if grep -qn 'query.*+.*req\.\|execute.*+.*req\.\|query.*\${' "$f" 2>/dev/null; then
        local lineno
        lineno=$(grep -n 'query.*+.*req\.\|execute.*+.*req\.\|query.*\${' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${lineno}|P009|SQL string concatenation — SQL injection risk สูงมาก ใช้ parameterized query แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

  done


    # ── SECURITY ────────────────────────────────────────────

    # P010: JWT secret hardcode
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      if grep -qn 'jwt\.sign\|jsonwebtoken' "$f" 2>/dev/null; then
        if grep -qn 'secret.*['"'"'"][a-zA-Z0-9]\{8,\}['"'"'"]' "$f" 2>/dev/null; then
          local ln; ln=$(grep -n 'secret.*['"'"'"][a-zA-Z0-9]\{8,\}['"'"'"]' "$f" | head -1 | cut -d: -f1)
          echo "PATTERN|${f}|${ln}|P010|JWT secret hardcode — ย้ายไป process.env.JWT_SECRET|pattern" >> "$PATTERN_FILE"
        fi
      fi
    fi

    # P011: weak crypto MD5/SHA1
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      if grep -qin "createHash.*'md5'\|createHash.*'sha1'\|createHash.*\"md5\"\|createHash.*\"sha1\"" "$f" 2>/dev/null; then
        local ln; ln=$(grep -in "createHash.*md5\|createHash.*sha1" "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P011|weak crypto MD5/SHA1 — ใช้ SHA256 หรือ bcrypt แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P012: token ใน URL
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "py" ]]; then
      if grep -qin 'http.*token=\|http.*api_key=\|http.*apikey=' "$f" 2>/dev/null; then
        local ln; ln=$(grep -in 'http.*token=\|http.*api_key=' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P012|token/key ใน URL — ใช้ Authorization header แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P013: eval() ใน JS/TS
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      if grep -qn '\beval(' "$f" 2>/dev/null; then
        local ln; ln=$(grep -n '\beval(' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P013|eval() อันตราย — code injection risk สูง|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P014: prototype pollution
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      if grep -qn '__proto__' "$f" 2>/dev/null; then
        local ln; ln=$(grep -n '__proto__' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P014|prototype pollution risk — ตรวจ input ก่อน merge object|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # ── PERFORMANCE ──────────────────────────────────────────

    # P015: await ใน loop
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      if grep -qn 'for.*{' "$f" 2>/dev/null && grep -qn 'await ' "$f" 2>/dev/null; then
        local ln; ln=$(grep -n 'await ' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P015|await อาจอยู่ใน loop — ใช้ Promise.all() แทนเพื่อ parallel|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P016: sync fs ใน async context
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      local sync_count; sync_count=$(grep -c 'readFileSync\|writeFileSync\|existsSync' "$f" 2>/dev/null); sync_count=$(( sync_count + 0 ))
      local async_count; async_count=$(grep -c '\basync\b' "$f" 2>/dev/null); async_count=$(( async_count + 0 ))
      if [[ $sync_count -gt 0 && $async_count -gt 0 ]]; then
        local ln; ln=$(grep -n 'readFileSync\|writeFileSync\|existsSync' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P016|sync fs ใน async context — บล็อก event loop ใช้ fs.promises แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P017: event listener ไม่มี remove
    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      local add_count; add_count=$(grep -c 'addEventListener\|\.on(' "$f" 2>/dev/null); add_count=$(( add_count + 0 ))
      local rm_count; rm_count=$(grep -c 'removeEventListener\|\.off(\|\.removeListener(' "$f" 2>/dev/null); rm_count=$(( rm_count + 0 ))
      if [[ $add_count -gt 2 && $rm_count -eq 0 ]]; then
        echo "PATTERN|${f}|1|P017|event listener ${add_count} จุด ไม่มี removeListener — memory leak risk|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # ── CODE QUALITY ─────────────────────────────────────────

    # P018: TODO/FIXME มากเกิน
    local todo_count; todo_count=$(grep -c 'TODO\|FIXME\|HACK\|XXX' "$f" 2>/dev/null); todo_count=$(( todo_count + 0 ))
    if [[ $todo_count -gt 3 ]]; then
      echo "PATTERN|${f}|1|P018|มี TODO/FIXME ${todo_count} จุด — ค้างอยู่นาน ควร track ใน issue|pattern" >> "$PATTERN_FILE"
    fi

    # P019: TypeScript any type
    if [[ "$ext" == "ts" || "$ext" == "tsx" ]]; then
      local any_count; any_count=$(grep -c ': any\b\|as any\b' "$f" 2>/dev/null); any_count=$(( any_count + 0 ))
      if [[ $any_count -gt 2 ]]; then
        local ln; ln=$(grep -n ': any\b\|as any\b' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P019|TypeScript any ${any_count} จุด — ใส่ type จริงหรือ unknown แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P020: non-null assertion TS
    if [[ "$ext" == "ts" || "$ext" == "tsx" ]]; then
      local bang_count; bang_count=$(grep -c '[a-zA-Z0-9]!' "$f" 2>/dev/null); bang_count=$(( bang_count + 0 ))
      if [[ $bang_count -gt 3 ]]; then
        local ln; ln=$(grep -n '[a-zA-Z0-9]!' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P020|non-null assertion (!) ${bang_count} จุด — เสี่ยง runtime null crash|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P021: ไฟล์ใหญ่ > 300 บรรทัด
    local line_count; line_count=$(wc -l < "$f" 2>/dev/null); line_count=$(( line_count + 0 ))
    if [[ $line_count -gt 300 && "$ext" != "md" ]]; then
      echo "PATTERN|${f}|1|P021|ไฟล์ใหญ่ ${line_count} บรรทัด — ควร split module ให้เล็กลง|pattern" >> "$PATTERN_FILE"
    fi

    # ── DOCKER / CONFIG ──────────────────────────────────────

    # P022: Dockerfile FROM :latest
    local fname; fname=$(basename "$f")
    if [[ "$fname" == "Dockerfile" || "$fname" == "dockerfile" ]]; then
      if grep -qin 'FROM.*:latest' "$f" 2>/dev/null; then
        local ln; ln=$(grep -in 'FROM.*:latest' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P022|Dockerfile FROM :latest — pin version เช่น node:20-alpine|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P023: Dockerfile ไม่มี USER
    if [[ "$fname" == "Dockerfile" || "$fname" == "dockerfile" ]]; then
      if ! grep -qi '^USER ' "$f" 2>/dev/null; then
        echo "PATTERN|${f}|1|P023|Dockerfile ไม่มี USER — container รันเป็น root|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P024: secret ใน Dockerfile ENV
    if [[ "$fname" == "Dockerfile" || "$fname" == "dockerfile" ]]; then
      if grep -qin 'ENV.*PASSWORD\|ENV.*SECRET\|ENV.*API_KEY' "$f" 2>/dev/null; then
        local ln; ln=$(grep -in 'ENV.*PASSWORD\|ENV.*SECRET\|ENV.*API_KEY' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P024|secret ใน Dockerfile ENV — ใช้ runtime secret แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P025: hardcoded localhost URL
    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "py" ]]; then
      if grep -qn 'http://localhost\|http://127\.0\.0\.1' "$f" 2>/dev/null; then
        local ln; ln=$(grep -n 'http://localhost\|http://127\.0\.0\.1' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P025|hardcoded localhost URL — ใช้ process.env.BASE_URL แทน|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P026: curl|bash ใน package.json
    if [[ "$fname" == "package.json" ]]; then
      if grep -qn 'curl.*bash\|wget.*bash' "$f" 2>/dev/null; then
        local ln; ln=$(grep -n 'curl.*bash\|wget.*bash' "$f" | head -1 | cut -d: -f1)
        echo "PATTERN|${f}|${ln}|P026|curl|bash ใน package.json scripts — supply chain risk|pattern" >> "$PATTERN_FILE"
      fi
    fi

    # P027: React ไม่มี ErrorBoundary
    if [[ "$ext" == "jsx" || "$ext" == "tsx" ]]; then
      local has_boundary; has_boundary=$(grep -c 'ErrorBoundary\|componentDidCatch' "$f" 2>/dev/null); has_boundary=$(( has_boundary + 0 ))
      local has_comp; has_comp=$(grep -c 'export default\|export const' "$f" 2>/dev/null); has_comp=$(( has_comp + 0 ))
      if [[ $has_comp -gt 0 && $has_boundary -eq 0 ]]; then
        echo "PATTERN|${f}|1|P027|React component ไม่มี ErrorBoundary — crash พัง UI ทั้งหน้า|pattern" >> "$PATTERN_FILE"
      fi
    fi

  COUNT_PATTERN=0
  if [[ -f "$PATTERN_FILE" ]]; then
    COUNT_PATTERN=$(wc -l < "$PATTERN_FILE" | tr -d ' ')
  fi
}

# ── Count ─────────────────────────────────────────────
count_results() {
  [[ ! -f "$RESULTS_FILE" ]] && return
  COUNT_HIGH=$(grep -c '^HIGH|'   "$RESULTS_FILE" 2>/dev/null); COUNT_HIGH=$(( COUNT_HIGH + 0 ))
  COUNT_MED=$(grep  -c '^MEDIUM|' "$RESULTS_FILE" 2>/dev/null); COUNT_MED=$(( COUNT_MED + 0 ))
  COUNT_LOW=$(grep  -c '^LOW|'    "$RESULTS_FILE" 2>/dev/null); COUNT_LOW=$(( COUNT_LOW + 0 ))
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
  max=$(( max > COUNT_PATTERN ? max : COUNT_PATTERN ))
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
  printf "${C}│${NC}  ${R}HIGH   ${NC} "; bar "$COUNT_HIGH"    "$max" "$R"
  printf "${C}│${NC}  ${Y}MEDIUM ${NC} "; bar "$COUNT_MED"     "$max" "$Y"
  printf "${C}│${NC}  ${B}LOW    ${NC} "; bar "$COUNT_LOW"     "$max" "$B"
  printf "${C}│${NC}  ${M}PATTERN${NC} "; bar "$COUNT_PATTERN" "$max" "$M"
  echo -e "${C}├──────────────────────────────────────────┤${NC}"
  echo -e "${C}│${NC}  bugs: ${BOLD}${total}${NC}  patterns: ${BOLD}${COUNT_PATTERN}${NC}                ${C}│${NC}"
  if [[ $total -eq 0 && $COUNT_PATTERN -eq 0 ]]; then
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

pattern_hint() {
  local code="$1"
  case "$code" in
    P001) echo "→ FIX: ใช้ DEBUG=* หรือ logger แทน console.log  ex: if (process.env.DEBUG) console.log(...)" ;;
    P002) echo "→ FIX: ครอบ async ด้วย try/catch  ex: try { await fn() } catch(e) { console.error(e) }" ;;
    P003) echo "→ FIX: เพิ่ม process.on('SIGINT', () => { server.close(); process.exit(0) })" ;;
    P004) echo "→ FIX: ใช้ fs.writeFile(path, data, (err) => { if(err) console.error(err) })" ;;
    P005) echo "→ FIX: ย้ายไป .env  ex: const key = process.env.API_KEY" ;;
    P006) echo "→ FIX: เพิ่ม set -euo pipefail บรรทัดแรกหลัง shebang" ;;
    P007) echo "→ CHECK: เพิ่ม .env ใน .gitignore ถ้ายังไม่มี" ;;
    P008) echo "→ FIX: ใช้ express-validator หรือ zod validate req.body ก่อน process" ;;
    P009) echo "→ FIX: ใช้ parameterized query  ex: db.query('SELECT * WHERE id=?', [id])" ;;
    P010) echo "→ FIX: ใช้ process.env.JWT_SECRET แทน hardcode" ;;
    P011) echo "→ FIX: ใช้ crypto.createHash('sha256') หรือ bcrypt สำหรับ password" ;;
    P012) echo "→ FIX: ส่ง token ผ่าน Authorization: Bearer <token> header" ;;
    P013) echo "→ FIX: หลีกเลี่ยง eval() ใช้ JSON.parse() แทน" ;;
    P014) echo "→ FIX: ใช้ Object.assign({}, defaults, input) แทน merge direct" ;;
    P015) echo "→ FIX: const results = await Promise.all(items.map(fn))" ;;
    P016) echo "→ FIX: ใช้ await fs.promises.readFile() แทน readFileSync" ;;
    P017) echo "→ FIX: เก็บ ref แล้ว removeEventListener ใน cleanup" ;;
    P018) echo "→ NOTE: สร้าง GitHub Issues track แทน TODO ใน code" ;;
    P019) echo "→ FIX: ใส่ type จริงๆ หรือ unknown แล้วค่อย narrow" ;;
    P020) echo "→ FIX: ใช้ optional chaining (?.) แทน non-null assertion (!)" ;;
    P021) echo "→ NOTE: แยก module ย่อย — 1 ไฟล์ 1 responsibility" ;;
    P022) echo "→ FIX: FROM node:20-alpine  (pin version เสมอ)" ;;
    P023) echo "→ FIX: เพิ่ม USER node ก่อน CMD ใน Dockerfile" ;;
    P024) echo "→ FIX: ใช้ Docker secrets หรือ runtime env แทน ENV" ;;
    P025) echo "→ FIX: BASE_URL=process.env.BASE_URL || 'http://localhost:3000'" ;;
    P026) echo "→ FIX: download script แยก verify checksum ก่อนรัน" ;;
    P027) echo "→ FIX: ครอบด้วย <ErrorBoundary fallback={<Err/>}>" ;;
    *)    echo "→ INFO: ตรวจสอบด้วยตนเอง" ;;
  esac
}

# ── is_fixable ────────────────────────────────────────
is_fixable() {
  case "$1" in
    SC2006|SC2164) return 0 ;;
    *) return 1 ;;
  esac
}

# ════════════════════════════════════════════════════
#  AUTOFIX ENGINE
# ════════════════════════════════════════════════════
run_autofix() {
  local dry="$1"
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

  local prev_file=""

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
          [[ ! -f "${file}.bak" ]] && cp "$file" "${file}.bak"
          sed -i "s/\`\([^\`]*\)\`/\$(\1)/g" "$file"
          FIX_COUNT=$(( FIX_COUNT + 1 ))
        fi
        ;;
      SC2164)
        echo -e "    ${Y}[${code}]${NC} line ${lineno}: cd ไม่มี || exit"
        if [[ "$dry" == "apply" ]]; then
          [[ ! -f "${file}.bak" ]] && cp "$file" "${file}.bak"
          sed -i "/^[[:space:]]*cd [^|]*$/s/$/ || exit 1/" "$file"
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
  fi
  echo ""
}

# ════════════════════════════════════════════════════
#  PRINT ISSUES (terminal)
# ════════════════════════════════════════════════════
color_level() {
  case "$1" in
    HIGH)    echo -e "${R}[HIGH]   ${NC}" ;;
    MEDIUM)  echo -e "${Y}[MED]    ${NC}" ;;
    LOW)     echo -e "${B}[LOW]    ${NC}" ;;
    PATTERN) echo -e "${M}[PATTERN]${NC}" ;;
  esac
}

should_show() {
  local level="$1"
  case "$MODE" in
    detail|export) true ;;
    default) [[ "$level" == "HIGH" || "$level" == "MEDIUM" || "$level" == "PATTERN" ]] ;;
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
      local hint=""
      [[ "$tool" == "bash" ]]    && hint=$(sc_hint "$code" "$msg")
      [[ "$tool" == "python" ]]  && hint=$(bd_hint "$code")
      [[ "$tool" == "javascript" || "$tool" == "typescript" ]] && hint="→ ดู eslint docs: ${code}"
      echo -e "         ${DIM}${hint}${NC}"

      # แสดง snippet ใน terminal mode -d
      local snippet
      snippet=$(get_snippet "$file" "$lineno")
      if [[ -n "$snippet" ]]; then
        echo -e "${DIM}         ┌─ code ─────────────────────────${NC}"
        while IFS= read -r sline; do
          echo -e "${DIM}         │ ${sline}${NC}"
        done <<< "$snippet"
        echo -e "${DIM}         └────────────────────────────────${NC}"
      fi
    fi
  done
}

print_patterns() {
  [[ ! -f "$PATTERN_FILE" ]] && return
  [[ $COUNT_PATTERN -eq 0 ]] && return

  echo -e "${C}── pattern check ────────────────────────────────${NC}"

  while IFS='|' read -r _ file lineno code msg _; do
    local relfile="${file#"$SCAN_PATH/"}"
    printf "%b[%s] %s:%s  %s\n" "$(color_level PATTERN)" "$code" "$relfile" "$lineno" "$msg"
    if [[ "$MODE" == "detail" || "$PATTERN_ONLY" == true ]]; then
      local hint
      hint=$(pattern_hint "$code")
      echo -e "         ${DIM}${hint}${NC}"

      local snippet
      snippet=$(get_snippet "$file" "$lineno")
      if [[ -n "$snippet" ]]; then
        echo -e "${DIM}         ┌─ code ─────────────────────────${NC}"
        while IFS= read -r sline; do
          echo -e "${DIM}         │ ${sline}${NC}"
        done <<< "$snippet"
        echo -e "${DIM}         └────────────────────────────────${NC}"
      fi
    fi
  done < "$PATTERN_FILE"
  echo ""
}

# ════════════════════════════════════════════════════
#  BUILD AI PROMPT — สร้าง prompt สำเร็จรูปสำหรับ Claude
# ════════════════════════════════════════════════════
build_ai_prompt() {
  local label="$SCAN_PATH"
  [[ -n "$SINGLE_FILE" ]] && label="$SINGLE_FILE"
  local project_name
  project_name=$(basename "$label")

  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))

  # นับ HIGH + PATTERN เพื่อ priority
  local critical=$(( COUNT_HIGH + COUNT_PATTERN ))

  echo "================================================================"
  echo "BUGSCAN REPORT — ${project_name}"
  echo "สแกนเมื่อ: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "bugscan v${VERSION}"
  echo "================================================================"
  echo ""
  echo "SUMMARY"
  echo "  HIGH      : $COUNT_HIGH"
  echo "  MEDIUM    : $COUNT_MED"
  echo "  LOW       : $COUNT_LOW"
  echo "  PATTERN   : $COUNT_PATTERN"
  echo "  TOTAL     : $total"
  echo ""

  # ── ISSUES พร้อม snippet ────────────────────────
  if [[ -f "$RESULTS_FILE" && $(wc -l < "$RESULTS_FILE") -gt 0 ]]; then
    echo "================================================================"
    echo "ISSUES (พร้อม code snippet)"
    echo "================================================================"
    echo ""

    sort -t'|' -k1,1 "$RESULTS_FILE" | \
    while IFS='|' read -r level file lineno code msg tool; do
      local relfile="${file#"$SCAN_PATH/"}"
      echo "────────────────────────────────────────"
      echo "[$level] [$code] $relfile:$lineno"
      echo "issue  : $msg"

      local hint=""
      [[ "$tool" == "bash" ]]    && hint=$(sc_hint "$code" "$msg")
      [[ "$tool" == "python" ]]  && hint=$(bd_hint "$code")
      [[ -n "$hint" ]] && echo "hint   : $hint"

      echo ""
      echo "code snippet:"
      echo '```'
      get_snippet "$file" "$lineno" 4
      echo '```'
      echo ""
    done
  fi

  # ── PATTERNS พร้อม snippet ───────────────────────
  if [[ -f "$PATTERN_FILE" && $COUNT_PATTERN -gt 0 ]]; then
    echo "================================================================"
    echo "PATTERNS"
    echo "================================================================"
    echo ""

    while IFS='|' read -r _ file lineno code msg _; do
      local relfile="${file#"$SCAN_PATH/"}"
      echo "────────────────────────────────────────"
      echo "[PATTERN] [$code] $relfile:$lineno"
      echo "issue  : $msg"
      echo "hint   : $(pattern_hint "$code")"
      echo ""
      echo "code snippet:"
      echo '```'
      get_snippet "$file" "$lineno" 4
      echo '```'
      echo ""
    done < "$PATTERN_FILE"
  fi

  # ── AI PROMPT สำเร็จรูป ─────────────────────────
  echo "================================================================"
  echo "PROMPT สำเร็จรูป — copy ข้อความด้านล่างนี้ paste ให้ Claude"
  echo "================================================================"
  echo ""

  if [[ $total -eq 0 && $COUNT_PATTERN -eq 0 ]]; then
    echo "โปรเจกต์ $project_name สะอาด ไม่พบปัญหา"
  elif [[ $COUNT_HIGH -gt 0 ]]; then
    echo "นี่คือ bugscan report ของ ${project_name}"
    echo "มี HIGH ${COUNT_HIGH} จุด และ PATTERN ${COUNT_PATTERN} จุด"
    echo "ช่วย fix HIGH ทุกตัวก่อน โดยแสดง code ที่แก้แล้วพร้อม before/after"
    echo "แต่ละ issue มี snippet แนบมาแล้ว ไม่ต้องเดา context"
  elif [[ $COUNT_PATTERN -gt 0 ]]; then
    echo "นี่คือ bugscan report ของ ${project_name}"
    echo "ไม่มี HIGH แต่มี PATTERN ${COUNT_PATTERN} จุดที่ควรแก้"
    echo "ช่วยอธิบาย PATTERN แต่ละตัว และแสดง code ที่แก้แล้ว"
  else
    echo "นี่คือ bugscan report ของ ${project_name}"
    echo "มี MEDIUM ${COUNT_MED} จุด ช่วย fix และอธิบายเหตุผลที่แก้"
  fi
  echo ""
  echo "================================================================"
}

# ════════════════════════════════════════════════════
#  EXPORT MODE — save ตรงไป $DL พร้อม AI prompt
# ════════════════════════════════════════════════════
export_files() {
  local ts
  ts=$(date '+%Y%m%d_%H%M%S')
  local dl_file="${DL}/bugscan_${ts}.txt"

  build_ai_prompt > "$dl_file"

  echo -e "${G}✓ Export: Download/bugscan_${ts}.txt${NC}"
  echo -e "${DIM}  share bugscan_${ts}.txt → แนบใน Claude ได้เลย${NC}"
  echo ""

  # ถ้า --ask ให้แสดง prompt สำเร็จรูปใน terminal ด้วย
  if $ASK_MODE; then
    local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW ))
    local project_name
    project_name=$(basename "${SCAN_PATH}")
    [[ -n "$SINGLE_FILE" ]] && project_name=$(basename "$SINGLE_FILE")

    echo ""
    echo -e "${M}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${M}│  PROMPT สำเร็จรูป — copy ไป paste ให้ Claude   │${NC}"
    echo -e "${M}└─────────────────────────────────────────────────┘${NC}"
    echo ""

    if [[ $COUNT_HIGH -gt 0 ]]; then
      echo -e "${BOLD}นี่คือ bugscan report ของ ${project_name}"
      echo -e "มี HIGH ${COUNT_HIGH} จุด และ PATTERN ${COUNT_PATTERN} จุด"
      echo -e "ช่วย fix HIGH ทุกตัวก่อน โดยแสดง code ที่แก้แล้วพร้อม before/after${NC}"
    elif [[ $COUNT_PATTERN -gt 0 ]]; then
      echo -e "${BOLD}นี่คือ bugscan report ของ ${project_name}"
      echo -e "ไม่มี HIGH แต่มี PATTERN ${COUNT_PATTERN} จุดที่ควรแก้"
      echo -e "ช่วยอธิบาย PATTERN แต่ละตัว และแสดง code ที่แก้แล้ว${NC}"
    else
      echo -e "${BOLD}นี่คือ bugscan report ของ ${project_name}"
      echo -e "ช่วย fix และอธิบายเหตุผลที่แก้${NC}"
    fi
    echo ""
    echo -e "${DIM}(แนบไฟล์ bugscan_${ts}.txt ไปด้วย)${NC}"
    echo ""
  fi
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
  echo "    \"pattern\": ${COUNT_PATTERN},"
  echo "    \"total\": ${total}"
  echo "  },"
  echo "  \"issues\": ["

  local first=true
  if [[ -f "$RESULTS_FILE" ]]; then
    while IFS='|' read -r level file lineno code msg tool; do
      local relfile="${file#"$SCAN_PATH/"}"
      msg="${msg//\"/\\\"}"
      local snippet_raw
      snippet_raw=$(get_snippet "$file" "$lineno" 2 | sed 's/"/\\"/g' | tr '\n' '↵')
      [[ "$first" == true ]] && first=false || echo ","
      printf '    {"level":"%s","file":"%s","line":%s,"code":"%s","msg":"%s","tool":"%s","snippet":"%s"}' \
        "$level" "$relfile" "$lineno" "$code" "$msg" "$tool" "$snippet_raw"
    done < <(sort -t'|' -k1,1 "$RESULTS_FILE")
  fi

  echo ""
  echo "  ],"
  echo "  \"patterns\": ["

  first=true
  if [[ -f "$PATTERN_FILE" ]]; then
    while IFS='|' read -r _ file lineno code msg _; do
      local relfile="${file#"$SCAN_PATH/"}"
      msg="${msg//\"/\\\"}"
      [[ "$first" == true ]] && first=false || echo ","
      printf '    {"level":"PATTERN","file":"%s","line":%s,"code":"%s","msg":"%s"}' \
        "$relfile" "$lineno" "$code" "$msg"
    done < "$PATTERN_FILE"
  fi

  echo ""
  echo "  ]"
  echo "}"
}

# ════════════════════════════════════════════════════
#  DIFF MODE
# ════════════════════════════════════════════════════
run_diff() {
  local files=()
  mapfile -t files < <(ls -t "${DL}"/bugscan_*.txt 2>/dev/null)

  if [[ ${#files[@]} -lt 2 ]]; then
    echo -e "${Y}warn:${NC} ต้องมี export อย่างน้อย 2 ครั้ง (bso)"
    exit 1
  fi

  local new="${files[0]}"
  local old="${files[1]}"

  _get() { grep "  $2" "$1" | awk '{print $NF}'; }

  local old_h old_m old_l old_p new_h new_m new_l new_p
  old_h=$(_get "$old" "HIGH");    old_h=${old_h:-0}
  old_m=$(_get "$old" "MEDIUM");  old_m=${old_m:-0}
  old_l=$(_get "$old" "LOW");     old_l=${old_l:-0}
  old_p=$(_get "$old" "PATTERN"); old_p=${old_p:-0}
  new_h=$(_get "$new" "HIGH");    new_h=${new_h:-0}
  new_m=$(_get "$new" "MEDIUM");  new_m=${new_m:-0}
  new_l=$(_get "$new" "LOW");     new_l=${new_l:-0}
  new_p=$(_get "$new" "PATTERN"); new_p=${new_p:-0}

  _delta() {
    local d=$(( $2 - $1 ))
    if   [[ $d -lt 0 ]]; then echo -e "${G}${d}${NC}"
    elif [[ $d -gt 0 ]]; then echo -e "${R}+${d}${NC}"
    else echo -e "${DIM}+-0${NC}"
    fi
  }

  local old_ts new_ts
  old_ts=$(basename "$old" | sed 's/bugscan_//;s/.txt//')
  new_ts=$(basename "$new" | sed 's/bugscan_//;s/.txt//')

  echo ""
  echo -e "${C}┌────────────────────────────────────────────────┐${NC}"
  echo -e "${C}│  bugscan --diff${NC}                                    ${C}│${NC}"
  echo -e "${C}├────────────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  %-12s  %5s  %5s  %5s  %7s  %5s ${C}│${NC}\n" "" "HIGH" "MED" "LOW" "PATTERN" "TOTAL"
  printf "${C}│${NC}  %-12s  %5s  %5s  %5s  %7s  %5s ${C}│${NC}\n" \
    "$old_ts" "$old_h" "$old_m" "$old_l" "$old_p" "$(( old_h+old_m+old_l ))"
  printf "${C}│${NC}  %-12s  %5s  %5s  %5s  %7s  %5s ${C}│${NC}\n" \
    "$new_ts" "$new_h" "$new_m" "$new_l" "$new_p" "$(( new_h+new_m+new_l ))"
  echo -e "${C}├────────────────────────────────────────────────┤${NC}"
  printf "${C}│${NC}  %-12s  " "delta"
  _delta "$old_h" "$new_h"; printf "  "
  _delta "$old_m" "$new_m"; printf "  "
  _delta "$old_l" "$new_l"; printf "       "
  _delta "$old_p" "$new_p"; printf "  "
  _delta "$(( old_h+old_m+old_l ))" "$(( new_h+new_m+new_l ))"
  echo -e "  ${C}│${NC}"
  echo -e "${C}└────────────────────────────────────────────────┘${NC}"
  echo ""
}

# ════════════════════════════════════════════════════
#  TIPS
# ════════════════════════════════════════════════════
print_tips() {
  local total=$(( COUNT_HIGH + COUNT_MED + COUNT_LOW + COUNT_PATTERN ))
  [[ $total -eq 0 ]] && return
  echo -e "${DIM}tips:"
  [[ "$MODE" == "default" ]] && echo -e "  -d        → ดู fix hints + snippets + LOW"
  echo -e "  -o        → export พร้อม AI prompt → \$DL"
  echo -e "  --ask     → export + แสดง prompt พร้อม paste ให้ Claude"
  echo -e "  --fix-dry → preview autofix"
  echo -e "  --fix     → autofix safe issues"
  echo -e "  --pattern → pattern check อย่างเดียว"
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

  if ! $PATTERN_ONLY; then
    run_shellcheck
    run_bandit
    run_eslint
    count_results
  fi

  run_pattern_check

  if $JSON_MODE; then
    print_json
    exit 0
  fi

  print_summary

  if [[ -n "$FIX_MODE" ]]; then
    run_autofix "$FIX_MODE"
    [[ "$FIX_MODE" == "apply" ]] && exit 0
  fi

  if [[ "$MODE" == "export" ]]; then
    export_files
  else
    if ! $PATTERN_ONLY; then
      print_issues
    fi
    print_patterns
    print_tips
  fi
}

main "$@"
