---
name: review
description: Review a TurboFieldfare pull request or pending Swift and Metal changes for correctness, regressions, tests, and project-specific safety constraints.
---

# Code Review Skill

Conduct a focused review that surfaces actionable defects rather than a change
summary.

## Scope and context

Choose the diff in this order: a user-named PR (`gh pr view` and `gh pr diff`),
staged changes, then the current branch against its merge base with `main`.
State the scope. Read every changed file in full, `AGENTS.md`, relevant tests,
and directly relevant format/runtime/server documentation.

## Review focus

**Swift correctness and concurrency**

- Off-by-one errors, invalid shape/stride math, unchecked narrowing, overflow,
  and out-of-bounds collection or raw-buffer access.
- `try!`, force unwraps, force casts, and `precondition` on input-controlled
  paths without a proved invariant.
- Actor-isolation violations, non-`Sendable` state crossing tasks, continuations
  resumed incorrectly, cancellation races, and locks held across suspension.
- Escaping pointers from `withUnsafe*`, mismatched allocation/deallocation,
  use-after-free with `Data(bytesNoCopy:)` or Metal buffers, and FFI ownership
  errors.
- Resource lifetime mistakes involving mapped files, file descriptors, tasks,
  NIO channels, command buffers, or retained KV state.

**Metal and inference**

- Dispatch geometry that can access past a buffer, host/shader layout mismatch,
  missing synchronization, incorrect storage mode assumptions, and unsupported
  dtype/shape combinations.
- Silent changes to sampling defaults, prompt rendering, context accounting,
  expert cache behaviour, image/text separation, or `.gturbo` v1 compatibility.
- Image failures that fall back to text-only behaviour instead of failing
  closed.

**Tests and public behaviour**

- New behaviour without a focused Swift Testing/XCTest case, especially error,
  cancellation, empty input, boundary sizes, and malformed pack/server input.
- Accidental real-model dependence where a deterministic model-free fixture or
  reference implementation would suffice.
- Server behaviour that diverges from `docs/OPENAI_SERVER.md` or binds beyond
  `127.0.0.1`.

**Clarity and scope**

- Misleading names, stale comments, dead code, unjustified diagnostic
  suppressions, `fatalError`/`TODO` in reachable production paths, and
  speculative abstraction.
- Unrelated refactors or unintended changes to `Package.resolved`, generated
  files, model packs, `scratch/`, runtime defaults, or experimental controls.

Defer a deep vulnerability analysis to `/security-review`, but report concrete
security bugs found during ordinary review.

## Report

Use `file:line` references and only headings that have content:

```markdown
## Review: <scope>

### Blocking
- `path/File.swift:42` — <correctness or security defect and concise fix>

### Should fix
- `path/File.swift:88` — <material maintainability or test gap>

### Nits
- `path/File.swift:12` — <minor issue>
```

Do not block on style. If clean, say so plainly. When called by `/commit` or
`/implement`, distinguish mechanical fixes and tag judgment calls
`[needs-decision]`.
