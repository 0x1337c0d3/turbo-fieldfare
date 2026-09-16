---
name: kanban
description: View the story board grouped by status, with optional filters
---

# /kanban

Display all stories in `stories/` grouped by status column. Read-only — use `/story update` to change status.

### 1. Load stories

Glob `stories/*.md`. For each file, parse the YAML front matter to extract: `id`, `title`, `status`, `priority`, `components`, `epic`, `branch`.

If `stories/` is empty or absent, output:

```
No stories yet. Run /story <title> to create one.
```

### 2. Group and sort

Group stories into columns in this order:

```
idea  →  backlog  →  in-progress  →  review  →  done
```

Within each column, sort by priority ascending (1=high first), then by id ascending.

### 3. Render the board

```
IDEA             (N)
  S-NNN [P?] <title>                    <components>

BACKLOG          (N)
  S-NNN [P?] <title>                    <components>

IN-PROGRESS      (N)
  S-NNN [P?] <title>  [branch]          <components>

REVIEW           (N)
  S-NNN [P?] <title>                    <components>

DONE             (N)
  S-NNN [P?] <title>                    <components>
```

- `[P?]` is the priority: `[P1]`, `[P2]`, `[P3]`
- `[branch]` shows the `branch:` field for in-progress stories (omit for other statuses)
- Skip empty columns

---

## Filters

**By column:** `/kanban backlog` — show only that status column.

**By epic:** `/kanban epic=Auth` — show only stories whose `epic` field matches (case-insensitive, partial match).

**Story detail:** `/kanban S-004` — pretty-print the full content of that story file (same as `/story show S-004`).

---

**Don't:**
- Modify any story files
- Omit stories — if a file fails to parse, note the filename and skip it rather than silently dropping it
