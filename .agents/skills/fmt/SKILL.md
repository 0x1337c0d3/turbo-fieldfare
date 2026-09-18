---
name: fmt
description: Format changed Swift source files with the formatter bundled in the active Swift toolchain and report what changed.
---

# /fmt

Format only Swift files in the requested change unless the user explicitly
asks to format the whole repository. This avoids unrelated repository-wide
churn when no `.swift-format` configuration is present.

1. Read `AGENTS.md` and verify `swift format --version` succeeds.
2. Determine the target files from explicit user paths, otherwise from staged,
   unstaged, and untracked files. Include `Package.swift` and files ending in
   `.swift`; exclude `.build/` and dependency checkouts.
3. Run:

   ```bash
   swift format format --in-place --parallel <files...>
   ```

4. Inspect `git diff --check` and `git diff --name-only`. Report the files the
   formatter changed, or say that they were already formatted. If parsing
   fails, report the file and diagnostic; do not repair unrelated syntax as
   part of formatting.

`/fmt` applies formatting. Commit-time checking uses `swift format lint
--strict` against the intended Swift files.
