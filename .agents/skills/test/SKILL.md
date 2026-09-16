---
name: test
description: Run cargo test with llvm-cov coverage, enforce gates, name uncovered lines on modified files.
---

# /test

Run the test suite with coverage. Coverage threshold is 80% — this command surfaces *why* and *where* when it fails.

## Steps

### 1. Run tests with coverage

```bash
cargo llvm-cov --all-features --workspace --summary-only 2>&1
```

Capture exit code and stdout. If `cargo llvm-cov` is not installed, halt: "Run /setup first — cargo-llvm-cov is not installed."

For more detail when diagnosing uncovered lines, use:

```bash
cargo llvm-cov --all-features --workspace 2>&1
```

### 2. Parse results

Extract from stdout:

- Pass / fail / ignore counts (from the `test result:` line, e.g. `test result: ok. 5 passed; 0 failed; 0 ignored`).
- Overall line coverage % from the `TOTAL` row in the coverage summary.
- Coverage threshold: **80%** (hardcoded gate — customize in `AGENTS.md` if the
  project differs).

### 3. Gate: test failures

If any test failed:

- **Stop.** Do not proceed to commit-related work.
- List each failing test: `<test_name> — <one-line failure reason>`.
- If there's an obvious cause (assertion, panic, fixture error), name it. Don't paste the full output unless the user asks.

### 4. Gate: coverage failure

If coverage is below threshold:

- Identify recently modified source files: `git diff --name-only HEAD~1 HEAD -- '**/*.rs'` and `git diff --name-only -- '**/*.rs'`.
- Run full coverage report for those files:
  ```bash
  cargo llvm-cov --all-features --workspace 2>&1
  ```
- For each modified file, list the uncovered line ranges.
- Suggest concrete test cases (one bullet per uncovered branch). Be specific — `test_parse_returns_err_on_empty_input`, not "add more tests".

### 5. Pass case

If everything is green, report:

```
PASS  <N> passed, <M> ignored
COVER <X>% line coverage (threshold: 80%)
TIME  <Z>s
```
