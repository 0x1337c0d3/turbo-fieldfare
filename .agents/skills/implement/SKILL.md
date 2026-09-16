---
name: implement
description: Full TDD loop — plan, branch, write code + tests, fmt, clippy, test, review, commit.
---

# /implement

The core SDLC loop. Use this whenever the user asks for a new feature, bug fix, or non-trivial change.

---

## Story mode

If invoked as `/implement S-NNN`, run these steps **before** Step 1:

### 0a. Load the story

Find `stories/S-NNN-*.md` and read it in full. The story's acceptance criteria become the spec for Step 1.

### 0b. Verify branch

```bash
git rev-parse --abbrev-ref HEAD
```

The current branch must be `feature/S-NNN-<slug>`. If it is not:

```
Story S-NNN has not been started. Run: /story update S-NNN status=in-progress
```

Stop. Do not create a branch here — `/story update` owns that transition.

### 0c. Use story as spec

In Step 1 (Plan), use the story's acceptance criteria as the requirements. The plan must address each criterion. The branch already exists (from Step 0b), so skip the branch creation in Step 2 — just confirm you're on it.

After `/pr` opens, remind the user: `/story update S-NNN status=review`

---

## Steps

### 1. Plan first

Enter plan mode. Before touching any file:

- Read `AGENTS.md` to confirm conventions and architecture.
- Read the relevant existing modules so the plan respects the current layout.
- Propose a design that names: the files you'll add/modify, the tests you'll write, the public API surface, and any risks (including `unsafe` implications if relevant).

Wait for explicit user approval before exiting plan mode. The plan also produces the **work slug** (used for the branch name).

### 1a. Persist plan to story (if active)

If a story is active (you loaded one in Step 0a), append the approved plan to the story file. This captures the implementation approach for future reference.

```bash
story_file=$(ls stories/S-*.md 2>/dev/null | head -1)
if [[ -n "$story_file" ]]; then
  cat >> "$story_file" << 'PLANEOF'

## Implementation plan

<the approved plan text — files, API surface, test strategy, risks>
PLANEOF
fi
```

Then `git add` the story file so the plan is version-controlled alongside the code.

### 2. Branch check

```bash
git rev-parse --abbrev-ref HEAD
```

If on `main`:

```bash
git checkout -b feature/<slug>     # or fix/<slug> for bug fixes
```

Slug rules: lowercase, kebab-case, derived from the plan title, max ~40 chars. Don't create the branch until step 1 is approved.

### 3. Write code + tests *together*

Follow `AGENTS.md` for where files go. For each unit of behaviour:

- Add or modify the test first (mark `#[ignore]` initially if needed).
- Implement until the test passes.
- Repeat.

Don't batch a wall of production code and write tests at the end — interleave.

Rust-specific reminders:
- Prefer `?` over `.unwrap()` in production paths.
- Every `unsafe` block needs a `// SAFETY:` comment.
- If adding a new dependency, add it with `cargo add <crate>` and commit `Cargo.lock`.

### 4. Run `/fmt`

Format inline. The PostToolUse hook will have surfaced violations during step 3 already; this is the belt-and-braces pass.

### 5. Run `/test`

Loop control:

- If tests fail: fix, re-run.
- If coverage gate fails: add the missing tests named by `/test`'s output, re-run.
- **Max 3 loops.** After 3 failed iterations, stop and surface the situation to the user — don't keep grinding.

### 6. Run `/review`

The `/review` skill produces findings tagged Blocking / Should fix / Nits, with `[needs-decision]` on judgement calls.

- Auto-apply mechanical fixes (formatter quirks, dead code, obvious renames).
- For each `[needs-decision]` finding: surface to the user, get a call, then apply or dismiss.
- Skip Nits unless the user has time.

### 7. Re-run `/test`

Confirm review-driven changes didn't break anything. If they did, fix and re-run.

### 8. Run `/commit`

Hand off to the commit gate. Do not commit directly from this command — `/commit` enforces the pre-commit gate independently.

## Don't

- Don't combine unrelated changes in one `/implement` run. Two features = two runs = two branches.
- Don't skip the plan step "because the change is small". A 3-line fix still benefits from a 30-second plan.
- Don't loop indefinitely on failing tests. After loop 3, the user needs to weigh in.
- Don't add `#[allow(clippy::...)]` to silence clippy — fix the underlying issue.
