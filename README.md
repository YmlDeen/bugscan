# bugscan v4.0

Static analysis wrapper สำหรับ Termux (aarch64)
รวม shellcheck + bandit + eslint ไว้ในคำสั่งเดียว

## Structure

```
bugscan/
├── bugscan.sh     ← main script
├── install.sh     ← ติดตั้ง alias
├── exports/       ← ไฟล์ export จาก -o
└── README.md
```

## Install

```bash
cd ~/projects/bugscan
bash install.sh
source ~/.zshrc
```

## Dependencies

```bash
pkg install shellcheck
pip install bandit --break-system-packages
npm install -g eslint
```

## Usage

```
bugscan <path>            summary + HIGH + MEDIUM
bugscan <path> -d         detail + fix hints + LOW
bugscan <path> -o         export .txt + .md → exports/
bugscan <path> -s <dir>   ข้าม dir (ใช้ซ้ำได้)
bugscan --file <file>     scan ไฟล์เดียว
bugscan <path> --json     output JSON
bugscan <path> --fix-dry  preview autofix
bugscan <path> --fix      autofix safe issues
bugscan --diff            เทียบ 2 scan ล่าสุด
```

## Aliases

```bash
bs       → bugscan . -s node_modules
bsd      → bs -d
bso      → bs -o
bsdiff   → bugscan --diff
```

## Workflow

```bash
bso                        # scan + export
share exports/bugscan_*.txt  # ส่งไป Download/
# แนบ .txt ให้ Claude → แก้ HIGH ก่อนเสมอ
bsdiff                     # เทียบก่อน/หลัง
```

## Output

```
exports/
├── bugscan_YYYYMMDD_HHMMSS.txt   ← ส่ง Claude
└── bugscan_YYYYMMDD_HHMMSS.md    ← อ่านเอง
```

## Note

- HIGH > 5 → แก้ทีละไฟล์ ไม่ batch
- gsave มี bugscan check — HIGH หยุด push

## Changelog

| version | date       | changes |
|---------|------------|---------|
| v4.0    | 2026-04-19 | เพิ่ม eslint, --json, --fix-dry, --fix, --diff, export .txt+.md |
| v2.0    | 2026-04-18 | severity filter, summary box, --ai export, fix hints |
| v1.0    | 2026-04-18 | initial: shellcheck + bandit |
