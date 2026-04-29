# CHANGELOG

## v1.0.0 — 2026-04-29

### Major rewrite: bugscan → DeBug XL

- Removed shellcheck/bandit/eslint wrappers (unused on Termux)
- Pure pattern-based scanning — zero dependencies
- 27 patterns (P001-P027): security, performance, code quality
- 6 Termux-specific checks (T001-T006)
- New DeBug XL logo and cleaner output
- Termux-aware: detects native addons, /tmp/ misuse, lsof/ss
- detail mode (-d) with code snippets and fix hints
- export mode (-o) with AI prompt
