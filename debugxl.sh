#!/usr/bin/env bash
# DeBug XL v1.0 - pattern-based code reviewer

VERSION="1.0"
DL="${DL:-/storage/emulated/0/Download}"

R=$'\033[0;31m'; Y=$'\033[1;33m'; G=$'\033[0;32m'
C=$'\033[0;36m'; B=$'\033[1;34m'; M=$'\033[0;35m'
DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'

DEFAULT_SKIP=(node_modules dist bundle.js .git __pycache__ .pytest_cache venv .venv)
SCAN_PATH=""; SINGLE_FILE=""; MODE="default"; SKIP_DIRS=(); JSON_MODE=false
TMPDIR=$(mktemp -d); PATTERNS="$TMPDIR/p.txt"; TERMUX="$TMPDIR/t.txt"

cleanup() { rm -rf "$TMPDIR"; }; trap cleanup EXIT

logo() {
  echo ""
  echo -e "${C}===============================================${NC}"
  echo -e "${C}  ${BOLD}DeBug XL${NC} v${VERSION}  pattern-based code reviewer"
  echo -e "${C}  no dependencies, pure bash"
  echo -e "${C}===============================================${NC}"
  echo ""
}

usage() { logo
  echo "  debugxl <path>         default scan"
  echo "  debugxl <path> -d      detail + snippet"
  echo "  debugxl <path> -o      export"
  echo "  debugxl --file <file>  scan single file"
  echo "  debugxl <path> -s <dir>  skip folder"
  echo ""
}

parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  if [[ "$1" == "--file" ]]; then
    shift; [[ -z "$1" ]] && { echo -e "${R}error: --file <file>${NC}"; exit 1; }
    [[ ! -f "$1" ]] && { echo -e "${R}error: not found: $1${NC}"; exit 1; }
    SINGLE_FILE=$(realpath "$1"); SCAN_PATH=$(dirname "$SINGLE_FILE"); shift
  else
    SCAN_PATH="$1"; shift
    [[ ! -e "$SCAN_PATH" ]] && { echo -e "${R}error: not found: $SCAN_PATH${NC}"; exit 1; }
    SCAN_PATH=$(realpath "$SCAN_PATH")
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in -d) MODE="detail" ;; -o) MODE="export" ;;
      -s) shift; SKIP_DIRS+=("$1") ;; -h|--help) usage; exit 0 ;;
      *) echo -e "${R}unknown: $1${NC}"; usage; exit 1 ;;
    esac; shift
  done
}

find_files() {
  local ext="$1"
  if [[ -n "$SINGLE_FILE" ]]; then
    [[ "$SINGLE_FILE" == *".$ext" ]] && echo "$SINGLE_FILE"; return
  fi
  local args=("$SCAN_PATH" -type f -name "*.$ext")
  for d in "${DEFAULT_SKIP[@]}" "${SKIP_DIRS[@]}"; do
    args+=(-not -path "*/${d}/*" -not -path "*/${d}" -not -name "$d")
  done
  find "${args[@]}" 2>/dev/null
}

snippet() {
  local f="$1" n="$2" c="${3:-2}"
  [[ ! -f "$f" || ! "$n" =~ ^[0-9]+$ ]] && return
  awk -v s="$((n-c))" -v e="$((n+c))" -v t="$n" '
    NR>=s&&NR<=e{printf "%s %4d | %s\n",(NR==t?">>>":"   "),NR,$0}
  ' "$f" 2>/dev/null
}

ap() { echo "$1|$2|$3|$4|$5" >> "$6"; }

# ============================================================
run_patterns() {
  local files=()
  mapfile -t files < <(find_files "js"; find_files "ts"; find_files "jsx"; find_files "tsx"; find_files "sh"; find_files "py")
  local fc=${#files[@]}; [[ $fc -eq 0 ]] && return

  for f in "${files[@]}"; do
    local ext="${f##*.}"; local fn=$(basename "$f")
    local ln="" ac="" sc="" tc="" rc="" vc="" hb="" hc="" srv="" cln="" anyc=""

    ln=$(grep -nE '(api_key|password|secret)\s*=' "$f" 2>/dev/null | grep -vE 'example|sample|dummy|process\.env' | head -1 | cut -d: -f1)
    [[ -n "$ln" ]] && ap "HIGH" "P001" "$f" "$ln" "hardcoded secret" "$PATTERNS"

    ln=$(grep -nE 'query\s*\+|execute\s*\+' "$f" 2>/dev/null | head -1 | cut -d: -f1)
    [[ -n "$ln" ]] && ap "HIGH" "P002" "$f" "$ln" "SQL string concat" "$PATTERNS"

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      ln=$(grep -n '\beval(' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "HIGH" "P003" "$f" "$ln" "eval() risk" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]] && grep -qn 'jwt\.sign\|jsonwebtoken' "$f" 2>/dev/null; then
      ln=$(grep -nE 'secret\s*(:| =)' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "HIGH" "P004" "$f" "$ln" "JWT secret hardcode" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "py" ]]; then
      ln=$(grep -nEin 'http[^ ]*token=|http[^ ]*api_key=' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "MED" "P005" "$f" "$ln" "token in URL" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      ln=$(grep -nEi "createHash.*md5|createHash.*sha1" "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "MED" "P006" "$f" "$ln" "weak crypto" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      ln=$(grep -n '__proto__' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "HIGH" "P007" "$f" "$ln" "prototype pollution" "$PATTERNS"
    fi

    if [[ "$f" == *".env" && "$f" != *".env.example"* && "$f" != *".env.sample"* ]]; then
      ap "HIGH" "P008" "$f" "1" ".env committed" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      ac=$(grep -c 'await ' "$f" 2>/dev/null)
      if grep -q 'for.*{' "$f" 2>/dev/null && [[ $ac -gt 0 ]]; then
        ln=$(grep -n 'await ' "$f" 2>/dev/null | head -1 | cut -d: -f1)
        ap "INFO" "P009" "$f" "$ln" "await in loop" "$PATTERNS"
      fi
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      sc=$(grep -c 'readFileSync\|writeFileSync\|existsSync' "$f" 2>/dev/null)
      ac=$(grep -c '\basync\b' "$f" 2>/dev/null)
      if [[ $sc -gt 0 && $ac -gt 0 ]]; then
        ln=$(grep -n 'readFileSync\|writeFileSync\|existsSync' "$f" 2>/dev/null | head -1 | cut -d: -f1)
        ap "INFO" "P010" "$f" "$ln" "sync fs in async" "$PATTERNS"
      fi
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      sc=$(grep -c 'addEventListener' "$f" 2>/dev/null)
      ac=$(grep -c 'removeEventListener' "$f" 2>/dev/null)
      [[ $sc -gt 2 && $ac -eq 0 ]] && ap "INFO" "P011" "$f" "1" "listener leak" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "jsx" || "$ext" == "tsx" ]]; then
      ln=$(grep -n 'console\.log' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "INFO" "P012" "$f" "$ln" "console.log" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      sc=$(grep -c 'async function\|async (' "$f" 2>/dev/null)
      ac=$(grep -c 'try {' "$f" 2>/dev/null)
      [[ $sc -gt 0 && $ac -eq 0 ]] && ap "MED" "P013" "$f" "1" "async no try/catch" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      srv=$(grep -c 'listen\|createServer\|express()' "$f" 2>/dev/null)
      cln=$(grep -c 'process.on.*SIGINT\|process.on.*SIGTERM' "$f" 2>/dev/null)
      [[ $srv -gt 0 && $cln -eq 0 ]] && ap "INFO" "P014" "$f" "1" "server no cleanup" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]] && grep -qE 'fs\.writeFile|fs\.appendFile' "$f" 2>/dev/null; then
      tc=$(grep -c 'catch\|\.catch(' "$f" 2>/dev/null)
      if [[ $tc -eq 0 ]]; then
        ln=$(grep -nE 'fs\.writeFile|fs\.appendFile' "$f" 2>/dev/null | head -1 | cut -d: -f1)
        ap "MED" "P015" "$f" "$ln" "fs.write no error" "$PATTERNS"
      fi
    fi

    if [[ "$ext" == "sh" ]] && ! grep -q 'set -e\|set -eu\|set -euo' "$f" 2>/dev/null; then
      ap "MED" "P016" "$f" "1" "no set -e" "$PATTERNS"
    fi

    tc=$(grep -c 'TODO\|FIXME\|HACK\|XXX' "$f" 2>/dev/null)
    [[ $tc -gt 3 ]] && ap "INFO" "P017" "$f" "1" "TODO/FIXME $tc" "$PATTERNS"

    tc=$(wc -l < "$f" 2>/dev/null)
    [[ $tc -gt 300 && "$ext" != "md" ]] && ap "INFO" "P018" "$f" "1" "$tc lines" "$PATTERNS"

    if [[ "$ext" == "ts" || "$ext" == "tsx" ]]; then
      anyc=$(grep -c ': any\b\|as any\b' "$f" 2>/dev/null)
      [[ $anyc -gt 2 ]] && ap "INFO" "P019" "$f" "1" "any $anyc" "$PATTERNS"
    fi

    if [[ "$fn" == "package.json" ]]; then
      ln=$(grep -n 'curl.*bash\|wget.*bash' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "HIGH" "P020" "$f" "$ln" "supply chain risk" "$PATTERNS"
    fi

    if [[ "$fn" == "Dockerfile" || "$fn" == "dockerfile" ]]; then
      ln=$(grep -ni 'FROM.*:latest' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "INFO" "P021" "$f" "$ln" "FROM :latest" "$PATTERNS"
      grep -qi '^USER ' "$f" 2>/dev/null || ap "INFO" "P022" "$f" "1" "no USER" "$PATTERNS"
      ln=$(grep -niE 'ENV.*PASSWORD|ENV.*SECRET|ENV.*API_KEY' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "HIGH" "P023" "$f" "$ln" "secret in Dockerfile" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" || "$ext" == "py" ]]; then
      ln=$(grep -nE 'http://localhost|http://127\.0\.0\.1' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "INFO" "P024" "$f" "$ln" "hardcoded localhost" "$PATTERNS"
    fi

    if [[ "$ext" == "js" || "$ext" == "ts" ]]; then
      rc=$(grep -c 'req\.body\|req\.params\|req\.query' "$f" 2>/dev/null)
      vc=$(grep -c 'validate\|sanitize\|joi\|zod\|yup\|express-validator' "$f" 2>/dev/null)
      [[ $rc -gt 2 && $vc -eq 0 ]] && ap "MED" "P025" "$f" "1" "no validation" "$PATTERNS"
    fi

    if [[ "$ext" == "jsx" || "$ext" == "tsx" ]]; then
      hb=$(grep -c 'ErrorBoundary\|componentDidCatch' "$f" 2>/dev/null)
      hc=$(grep -c 'export default\|export const' "$f" 2>/dev/null)
      [[ $hc -gt 0 && $hb -eq 0 ]] && ap "INFO" "P026" "$f" "1" "no ErrorBoundary" "$PATTERNS"
    fi

    if [[ "$ext" == "sh" ]]; then
      local shl=$(head -1 "$f" 2>/dev/null)
      if [[ "$shl" =~ ^#!/.*/(bash|sh)$ && ! "$shl" =~ ^#!/usr/bin/env ]]; then
        ap "INFO" "P027" "$f" "1" "shebang not portable" "$PATTERNS"
      fi
    fi
  done
}

# ============================================================
run_termux() {
  local files=()
  mapfile -t files < <(
    local args=("$SCAN_PATH" -type f)
    for d in "${DEFAULT_SKIP[@]}" "${SKIP_DIRS[@]}"; do
      args+=(-not -path "*/${d}/*" -not -path "*/${d}")
    done
    find "${args[@]}" 2>/dev/null
  )
  [[ ${#files[@]} -eq 0 ]] && return

  for f in "${files[@]}"; do
    local ext="${f##*.}"; local fn=$(basename "$f")
    [[ "$ext" == "node" ]] && ap "HIGH" "T001" "$f" "1" ".node addon" "$TERMUX"
    if grep -q '/tmp/' "$f" 2>/dev/null; then
      local ln=$(grep -n '/tmp/' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      ap "INFO" "T002" "$f" "$ln" "/tmp/ usage" "$TERMUX"
    fi
    if grep -q '/storage/emulated/0/Download' "$f" 2>/dev/null; then
      local ln=$(grep -n '/storage/emulated/0/Download' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      ap "INFO" "T003" "$f" "$ln" "hardcoded DL path" "$TERMUX"
    fi
    [[ "$fn" == ".DS_Store" ]] && ap "INFO" "T004" "$f" "1" "DS_Store" "$TERMUX"
    if [[ "$ext" == "sh" ]]; then
      local ln=$(grep -n '\blsof\b' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "INFO" "T005" "$f" "$ln" "lsof on Termux" "$TERMUX"
      ln=$(grep -n '\bss\b' "$f" 2>/dev/null | head -1 | cut -d: -f1)
      [[ -n "$ln" ]] && ap "INFO" "T006" "$f" "$ln" "ss on Termux" "$TERMUX"
    fi
  done
}

# ============================================================
hint() {
  case "$1" in
    P001) echo "use .env + process.env" ;; P002) echo "use parameterized query" ;;
    P003) echo "avoid eval()" ;; P004) echo "process.env.JWT_SECRET" ;;
    P005) echo "use Authorization header" ;; P006) echo "use SHA256" ;;
    P007) echo "Object.assign({}, defaults, input)" ;; P008) echo "add .env to .gitignore" ;;
    P009) echo "Promise.all(items.map(fn))" ;; P010) echo "fs.promises" ;;
    P011) echo "cleanup listener" ;; P012) echo "use DEBUG flag" ;;
    P013) echo "wrap with try/catch" ;; P014) echo "process.on(SIGINT, cleanup)" ;;
    P015) echo "add error callback" ;; P016) echo "set -euo pipefail" ;;
    P017) echo "create GitHub issue" ;; P018) echo "split module" ;;
    P019) echo "use unknown then narrow" ;; P020) echo "verify checksum" ;;
    P021) echo "pin version" ;; P022) echo "USER node" ;;
    P023) echo "use Docker secrets" ;; P024) echo "process.env.BASE_URL" ;;
    P025) echo "zod / express-validator" ;; P026) echo "ErrorBoundary" ;;
    P027) echo "#!/usr/bin/env bash" ;;
    T001) echo "find pure JS alt" ;; T002) echo "use \$HOME/tmp/" ;;
    T003) echo "use \$DL" ;; T004) echo "rm .DS_Store" ;;
    T005) echo "use ps aux" ;; T006) echo "use ps aux" ;;
  esac
}

csev() {
  case "$1" in HIGH) echo -e "${R}[HIGH]${NC}" ;; MED) echo -e "${Y}[MED] ${NC}" ;;
    INFO) echo -e "${B}[INFO]${NC}" ;; TX) echo -e "${M}[TX]  ${NC}" ;;
  esac
}

# ============================================================
print_results() {
  local ch=$(grep -c '^HIGH|' "$PATTERNS" 2>/dev/null); ch=$((ch+0))
  local cm=$(grep -c '^MED|' "$PATTERNS" 2>/dev/null); cm=$((cm+0))
  local ci=$(grep -c '^INFO|' "$PATTERNS" 2>/dev/null); ci=$((ci+0))
  local cth=$(grep -c '^HIGH|' "$TERMUX" 2>/dev/null); cth=$((cth+0))
  local cti=$(grep -c '^INFO|' "$TERMUX" 2>/dev/null); cti=$((cti+0))
  local t=$((ch+cm+ci+cth+cti))

  echo ""
  echo -e "${C}---------------------------------------------${NC}"
  echo -e "${C}  ${BOLD}DeBug XL${NC} v${VERSION}  review complete${NC}"
  echo -e "${C}  $(printf '%-42s' "$SCAN_PATH")${NC}"
  echo -e "${C}---------------------------------------------${NC}"
  [[ $ch -gt 0 ]]  && echo -e "  ${R}HIGH  ${ch}${NC}"
  [[ $cm -gt 0 ]]  && echo -e "  ${Y}MED   ${cm}${NC}"
  [[ $ci -gt 0 ]]  && echo -e "  ${B}INFO  ${ci}${NC}"
  [[ $cth -gt 0 ]] && echo -e "  ${R}TX-HI ${cth}${NC}"
  [[ $cti -gt 0 ]] && echo -e "  ${M}TX-IF ${cti}${NC}"
  [[ $t -eq 0 ]]   && echo -e "  ${G}clean${NC}"
  echo -e "${C}---------------------------------------------${NC}" ""

  print_file "$PATTERNS" "patterns"
  print_file "$TERMUX" "termux"

  if [[ "$MODE" == "default" ]]; then
    echo -e "${DIM}tips: -d detail  -o export${NC}" ""
  fi
}

print_file() {
  local file="$1" title="$2"
  [[ ! -f "$file" || ! -s "$file" ]] && return
  echo -e "${C}-- $title ---------------------------------------${NC}"
  while IFS='|' read -r sev code f lineno msg; do
    [[ -z "$code" ]] && continue
    local rel="${f#$SCAN_PATH/}"
    printf "%b [%s] %s:%s  %s\n" "$(csev "$sev")" "$code" "$rel" "$lineno" "$msg"
    if [[ "$MODE" == "detail" ]]; then
      local h=$(hint "$code")
      [[ -n "$h" ]] && echo -e "         ${DIM}$h${NC}"
      local sn=$(snippet "$f" "$lineno")
      if [[ -n "$sn" ]]; then
        echo -e "${DIM}         +- code ----------------+${NC}"
        while IFS= read -r sline; do echo -e "${DIM}         | ${sline}${NC}"; done <<< "$sn"
        echo -e "${DIM}         +------------------------+${NC}"
      fi
    fi
  done < "$file"
  echo ""
}

# ============================================================
export_output() {
  local ts=$(date '+%Y%m%d_%H%M%S')
  local dl_file="${DL}/debugxl_${ts}.txt"
  local pn=$(basename "$SCAN_PATH")
  local ch=$(grep -c '^HIGH|' "$PATTERNS" 2>/dev/null); ch=$((ch+0))

  {
    echo "DeBug XL v$VERSION - $pn"
    echo "scan: $(date)"
    echo "----------------------------------------"
    for src in "$PATTERNS" "$TERMUX"; do
      [[ ! -f "$src" ]] && continue
      while IFS='|' read -r sev code f lineno msg; do
        [[ -z "$code" ]] && continue
        echo "[${sev}] [${code}] ${f#$SCAN_PATH/}:${lineno}  $msg"
        snippet "$f" "$lineno" 3 2>/dev/null
        echo ""
      done < "$src"
    done
    echo "PROMPT: debugxl report of $pn"
    [[ $ch -gt 0 ]] && echo "HIGH $ch issues - fix all first"
  } > "$dl_file"
  echo -e "${G}export: Download/debugxl_${ts}.txt${NC}" ""
}

# ============================================================
main() {
  parse_args "$@"
  logo
  echo -e "${DIM}  scanning $SCAN_PATH ...${NC}" ""
  run_patterns
  run_termux
  print_results
  [[ "$MODE" == "export" ]] && export_output
}

main "$@"; exit 0
