# bugscan

static analysis wrapper — shellcheck (bash) + bandit (python)

```
~/projects/bugscan/
├── bugscan.sh     ← main script
├── install.sh     ← ติดตั้ง alias อัตโนมัติ
└── README.md
```

---

## install

```bash
cd ~/projects/bugscan
bash install.sh
source ~/.zshrc
```

---

## usage

```
bugscan <path>              summary + HIGH + MEDIUM (default)
bugscan <path> --high       HIGH only
bugscan <path> --all        ทุก level รวม LOW
bugscan <path> --detail     full output + fix hints
bugscan <path> --ai         export .txt ส่ง AI ได้เลย
bugscan <path> --skip <dir> ข้าม dir (ใช้ซ้ำได้)
```

### ตัวอย่าง

```bash
bugscan ~/projects/dexv2
bugscan . --detail
bugscan ~/USSDTH --high --skip node_modules --skip inbox
bugscan . --ai          # → ~/bugscan_ai_YYYYMMDD_HHMMSS.txt
```

---

## output

```
┌──────────────────────────────────────────┐
│  BUGSCAN v2.0                            │
│  /home/user/projects/dexv2               │
├──────────────────────────────────────────┤
│  .sh    3 files   (shellcheck)           │
│  .py   12 files   (bandit)               │
├──────────────────────────────────────────┤
│  HIGH    ██████░░░░░░░░░░░░░░  5         │
│  MEDIUM  ████████████░░░░░░░░  12        │
│  LOW     ░░░░░░░░░░░░░░░░░░░░  80        │
└──────────────────────────────────────────┘

── bash ─────────────────────────────────────
[HIGH]  [SC2086] scripts/run.sh:14  Double quote to prevent globbing
         → FIX: ใส่ "" รอบ variable  ex: echo "$var"

── python ───────────────────────────────────
[HIGH]  [B307]  app/utils.py:42  Use of eval detected
         → FIX: eval() อันตราย — หลีกเลี่ยงถ้าเป็นไปได้
```

---

## --ai export

สร้างไฟล์ `~/bugscan_ai_YYYYMMDD_HHMMSS.txt` — copy ส่ง AI แล้วบอกว่า:

> "ช่วย fix HIGH issues ใน app/utils.py หน่อย"

AI จะเห็น file + line + issue + fix hint ครบทันที

---

## dependencies

```
shellcheck   pkg install shellcheck
bandit       pip install bandit --break-system-packages
```

---

## changelog

| version | date       | changes                                      |
|---------|------------|----------------------------------------------|
| v2.0    | 2026-04-18 | rewrite: severity filter, summary box, --ai export, fix hints |
| v1.0    | 2026-04-18 | initial: raw shellcheck + bandit output      |
