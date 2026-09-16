---
name: review
description: Review a pull request or pending changes. Performs a focused code review against the current branch's diff (or staged diff if invoked pre-commit), surfacing correctness bugs, missing tests, style violations, and unclear naming. Use when the user asks to "review this", "review the PR", "code review", or before commits/PRs.
---

# Code Review Skill

You are conducting a focused code review. Your goal is to surface real issues a reviewer should catch — not produce a generic summary.

## Step 1 — Determine review scope

Pick the diff source in this order:

1. If the user names a PR (e.g. "review PR 42"), fetch it with `gh pr view <n> --json ...` + `gh pr diff <n>`.
2. If staged changes exist (`git diff --cached --name-only` is non-empty), review the staged diff. Announce: "Reviewing staged changes."
3. Otherwise, review the current branch vs `main`:
   ```bash
   base=$(git merge-base HEAD main)
   git diff "$base"...HEAD
   ```

State the scope in one sentence before going deeper.

## Step 2 — Gather context

- List changed files (`git diff --name-only <range>`).
- Read each changed file (the **whole file**, not just the hunks) so you understand the context surrounding each change.
- Read any `AGENTS.md` files in the repo to learn project conventions.
- If tests exist for changed modules, scan them so you know what's already covered.

## Step 3 — Review

For each changed file, look for:

**Correctness**
- Off-by-one errors, wrong operator, swapped arguments
- Unhandled `Result`/`Option` — `.unwrap()` or `.expect()` in production paths (non-main)
- Resource leaks (file handles, sockets, locks not released — check `Drop` impls)
- Race conditions: `Arc<Mutex<_>>` held across `.await`, shared mutable state
- Integer overflow in release mode (unchecked arithmetic on user-supplied values)
- Wrong return type or shape vs. what callers expect
- `unsafe` blocks without a `// SAFETY:` comment, or with a comment that doesn't hold

**Tests**
- New behaviour without a corresponding test
- Tests that assert on incidental output rather than behaviour
- Tests that call `.unwrap()` without explanation — they'll panic silently on CI
- Missing edge cases: empty input, overflow boundaries, error paths

**Security (lightweight — defer deep work to `/security-review`)**
- `std::process::Command` built from user input without sanitisation
- `unsafe` that dereferences raw pointers from untrusted sources
- Secrets in code or logs
- Missing input validation at trust boundaries (CLI args, env vars, network input)

**Style & clarity**
- Names that don't match what the thing does
- Comments that say WHAT (delete) vs WHY (keep if non-obvious)
- Dead code, unused imports, `#[allow(...)]` without justification
- Over-engineering: speculative abstractions, premature generics, error handling for impossible cases
- Violations of project conventions (check `AGENTS.md`)
- `todo!()` / `unimplemented!()` left in production paths

**Scope**
- Changes outside the stated purpose of the PR (unrelated refactors mixed in)
- Half-finished work, `// TODO` added without tickets
- `Cargo.lock` changes that weren't intentional

## Step 4 — Report

Output format — **be terse**:

```
## Review: <one-line scope>

### Blocking
- `path/to/file.rs:42` — <issue>. <one-line fix suggestion>

### Should fix
- `path/to/file.rs:88` — <issue>.

### Nits
- `path/to/file.rs:12` — <issue>.

### Looks good
<1-2 sentences on what's solid — only if there's something genuinely worth calling out>
```

Rules:
- Use `file:line` references so the user can jump to the source.
- "Blocking" = correctness or security bug; do not block on style.
- If there's nothing in a category, omit the heading entirely.
- If the diff is clean, say so in one sentence. Don't pad.
- Do NOT summarise what the PR does — the user wrote it and can read the diff.

## Step 5 — If invoked from `/commit` or `/implement`

When the caller is another slash command (not the user directly), it may auto-apply your suggestions. In that case:

- Be explicit about which findings are mechanical fixes (formatter, rename, delete dead code) vs. judgement calls that need user input.
- Tag judgement calls with `[needs-decision]` so the caller knows to surface them rather than silently auto-apply.
