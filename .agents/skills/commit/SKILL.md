---
name: commit
description: Pre-commit gate (fmt + clippy + test) then create a conventional commit with explicit file staging.
---

# /commit

The enforcer. Nothing reaches the index without passing the gate.

## Steps

### 1. Format check

```bash
cargo fmt -- --check
```

If dirty: run `/fmt` to apply formatting, then re-stage any files that were already staged.

### 2. Clippy

```bash
cargo clippy --all-features --all-targets -- -D warnings
```

If any warnings/errors are reported: fix them. **Do not add `#[allow(clippy::...)]` suppression** unless the lint is a confirmed false positive — and even then, add a comment explaining why. Re-run clippy until it exits 0.

### 3. Full test run

Run `/test`. **Must pass, including the coverage gate.** If it fails: halt. Surface the failure and let the user decide.

### 4. Review

Run `/review` against staged changes (`git diff --cached`).

> The `/review` skill is diff-aware — it picks up staged changes automatically when invoked here.

Handle findings:

- Mechanical fixes (Blocking / Should fix without `[needs-decision]`): apply, re-stage the file, then re-run `/test`.
- `[needs-decision]` findings: surface to the user. Do not silently apply.
- Nits: mention in the report, do not block on them.

If any fix was applied: loop back to step 1. Max 2 loops, then escalate.

### 5. Stage files explicitly

```bash
git add <file1> <file2> ...
```

**Never `git add -A` or `git add .`.** These are denied at the settings level — if Claude tries them, the call will be rejected.

Use `git status --short` to enumerate what's intended for the commit. If something unintended shows up (e.g. `Cargo.lock` changes you didn't intend), ask the user.

### 6. Compose the commit message

Format: conventional commits.

```
<type>(<scope>): <short imperative description>

<optional body — wrap at 72 cols, explain the WHY, not the WHAT>
```

Types: `feat`, `fix`, `chore`, `test`, `docs`, `refactor`, `perf`, `style`, `build`, `ci`.

Rules:

- **Imperative mood** ("add parser", not "adds parser" or "added parser").
- **Short subject** (≤ 72 chars). Detail goes in the body.
- **No emoji.**
- **No hardcoded `Co-Authored-By` line.**

### 7. Commit

```bash
git commit -m "$(cat <<'EOF'
<message>
EOF
)"
```

Use a heredoc so multi-line bodies format correctly.

### 8. Confirm

```bash
git log -1 --oneline
git status --short
```

Report: commit hash, subject line, working-tree state. One line each, no padding.

## Pre-commit hook failure

If a pre-commit hook fails: the commit did **not** happen. Fix the underlying issue, re-stage, and create a **new** commit. Never `--amend` after a hook failure — there's nothing to amend.
