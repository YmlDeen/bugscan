# debugxl — pattern-based code reviewer

zero-dependency static analysis for Termux projects. pure bash.

## Features

- 27 patterns (P001-P027) — security, performance, code quality
- 6 Termux-specific checks (T001-T006)
- no external tools needed (no shellcheck/bandit/eslint)
- snippet view in detail mode
- export with AI prompt

## Install

```bash
cd ~/projects/bugscan
bash install.sh
source ~/.zshrc
```

No dependencies. Just bash + grep + awk.

## Usage

```
debugxl <path>            default scan
debugxl <path> -d         detail + code snippet
debugxl <path> -o         export → $DL
debugxl --file <file>     scan single file
debugxl <path> -s <dir>   skip folder
```

## Change from bugscan

- Removed shellcheck/bandit/eslint wrappers (unused on Termux)
- Pure pattern-based — runs anywhere with bash
- Termux-specific checks (native addons, /tmp/, lsof, etc)
- Added DeBug XL logo and simpler output

## Patterns

| Code | Severity | Check |
|------|----------|-------|
| P001 | HIGH | hardcoded secret/password |
| P002 | HIGH | SQL string concat |
| P003 | HIGH | eval() |
| P004 | HIGH | JWT secret hardcode |
| P005 | MED | token/key in URL |
| P006 | MED | weak crypto MD5/SHA1 |
| P007 | HIGH | prototype pollution |
| P008 | HIGH | .env committed |
| P009 | INFO | await in loop |
| P010 | INFO | sync fs in async |
| P011 | INFO | event listener leak |
| P012 | INFO | console.log |
| P013 | MED | async no try/catch |
| P014 | INFO | server no cleanup |
| P015 | MED | fs.write no error handling |
| P016 | MED | no set -e (shell) |
| P017 | INFO | TODO/FIXME |
| P018 | INFO | file too large |
| P019 | INFO | TypeScript any |
| P020 | HIGH | curl|bash in package.json |
| P021 | INFO | Dockerfile :latest |
| P022 | INFO | Dockerfile no USER |
| P023 | HIGH | secret in Dockerfile |
| P024 | INFO | hardcoded localhost |
| P025 | MED | input validation missing |
| P026 | INFO | React no ErrorBoundary |
| P027 | INFO | shebang not portable |
| T001 | HIGH | native .node addon |
| T002 | INFO | /tmp/ usage |
| T003 | INFO | hardcoded DL path |
| T004 | INFO | .DS_Store |
| T005 | INFO | lsof on Termux |
| T006 | INFO | ss on Termux |
