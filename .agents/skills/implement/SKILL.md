---
name: implement
description: Implement a TurboFieldfare Swift or Metal feature or fix with tests, formatting, serial validation, review, and commit preparation.
---

# /implement

Use this workflow for a requested feature, bug fix, or other non-trivial source
change. The repository is otherwise for running and reporting existing
behaviour, so do not begin implementation unless the user asked for it.

## Story mode

When invoked with `S-NNN`, read the matching `stories/S-NNN-*.md` in full and
use its acceptance criteria as the specification. Confirm the current branch
is `feature/S-NNN-<slug>`; if not, stop and direct the user to `/story update
S-NNN status=in-progress`. Do not create a second story branch.

## Workflow

1. Read `AGENTS.md`, the relevant source and tests, and any directly relevant
   design/runtime document. State the files, public API changes, tests, and
   risks before editing. Pay particular attention to wire-format compatibility,
   actor/concurrency boundaries, raw-buffer lifetimes, integer overflow, Metal
   buffer bounds, and whether a test would load the real model.
2. Check the branch. If the workflow calls for a branch and the current branch
   is `main`, create `feature/<slug>` or `fix/<slug>`. In story mode the branch
   is already owned by `/story`.
3. Add or update a focused Swift Testing (`@Test`) or XCTest case alongside
   each behaviour change, then implement until it passes. Prefer deterministic,
   model-free coverage. Keep `.gturbo` v1 changes compatible unless the user
   explicitly requested a contract change.
4. Follow Swift-specific constraints:
   - Preserve actor isolation and `Sendable` correctness; do not silence
     concurrency diagnostics casually.
   - Validate sizes and offsets before integer conversion, allocation, pointer
     arithmetic, or Metal dispatch.
   - Keep `withUnsafe*` pointers within their documented lifetime and explain
     genuinely non-obvious unsafe invariants.
   - Add SwiftPM dependencies in `Package.swift`, keep `Package.resolved`
     intentional, and avoid dependencies when platform APIs suffice.
   - Keep the loopback server on `127.0.0.1`; do not add remote exposure,
     authentication assumptions, or TLS claims.
5. Run `/fmt`, then `/test`. Fix failures and retry, with at most three repair
   loops before surfacing the blocker. Apply the `AGENTS.md` preflight before
   any real-model test or inference run.
6. Run `/review`, address mechanical Blocking/Should-fix findings, and ask the
   user about findings tagged `[needs-decision]`. Re-run `/test` after fixes.
7. Hand off to `/commit`; do not bypass its independent gates.

Do not mix unrelated changes, enable experimental runtime controls, start a
second model process, download/duplicate a model merely for validation, or
turn correctness work into unrequested performance optimization.
