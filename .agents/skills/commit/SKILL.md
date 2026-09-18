---
name: commit
description: Run TurboFieldfare's Swift formatting, release-build, serial-test, and repository checks, then create a conventional commit with explicit staging.
---

# /commit

Create a commit only after the intended change passes the repository's local
gates. Preserve unrelated user changes in a dirty worktree.

## Gates

1. Enumerate staged, unstaged, and untracked files with `git status --short`.
   Establish exactly which files belong to this commit.
2. For intended `*.swift` files and `Package.swift`, run:

   ```bash
   swift format lint --strict <files...>
   git diff --check
   ```

   If formatting fails, run `/fmt`, then re-stage only intended files.
3. Match the compile and package-test gates used by the project:

   ```bash
   swift build -c release
   Scripts/test.sh
   ruby Scripts/check_tracked_symlinks.rb
   ruby Scripts/check_markdown_links.rb
   ruby Scripts/check_app_version.rb
   ```

   The app-version check may report that GitHub is unavailable and skip its
   comparison; disclose that as a CI-parity gap. Do not substitute a direct or
   parallel `swift test`, and do not invent a coverage gate. Apply the full
   `AGENTS.md` preflight whenever the selected suite can use an installed real
   model.
4. Run `/review` against the staged changes. Apply mechanical fixes, re-stage,
   and repeat the gates. Surface `[needs-decision]` findings. Stop after two
   repair loops and ask the user how to proceed.

## Stage and commit

Stage each intended path explicitly with `git add <path>...`; never use
`git add .` or `git add -A`. Treat unexpected `Package.resolved`, model files,
`scratch/`, generated build output, or unrelated changes as blockers until the
user confirms their intent.

Use a conventional commit subject (`feat`, `fix`, `chore`, `test`, `docs`,
`refactor`, `perf`, `style`, `build`, or `ci`) in imperative mood, at most 72
characters. Explain why in an optional wrapped body. Do not add emoji or a
hard-coded co-author trailer.

After `git commit`, report `git log -1 --oneline` and `git status --short`. If a
hook fails, fix and retry as a new commit attempt; there is no commit to amend.
