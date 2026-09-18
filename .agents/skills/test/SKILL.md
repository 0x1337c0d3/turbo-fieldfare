---
name: test
description: Run TurboFieldfare's serial Swift package tests through Scripts/test.sh, with the required safeguards for any real-model test.
---

# /test

Run package tests through the repository wrapper; shared Metal state makes
parallel execution unreliable.

## Package tests

Use the whole suite unless the user asks for a focused filter:

```bash
Scripts/test.sh
Scripts/test.sh --filter <test-or-suite>
```

Pass supported `swift test` arguments through the wrapper. Never invoke
`swift test` directly and never add parallelism. Capture the exact command,
exit code, elapsed time, failures, and skips. This repository defines no local
coverage threshold, so do not invent or enforce one.

Before running, determine whether the selected suite can open an installed
model pack. Treat a full-suite run as model-using when the required real model
artifacts are present.

## Tests that load a real model

Before any run that can load the real model, apply every preflight in
`AGENTS.md`: macOS and Swift versions, disk, `memory_pressure -Q`, completed
model pack, and the full process check. If any check fails, report it and stop.
Do not terminate an app/process, reinstall or delete a model, or run more than
one app, CLI, or model-using test at once.

Ordinary model-free package tests may run without a model; model-dependent
cases are expected to skip when their packs are absent.

## Report

On failure, name each failing test and its useful diagnostic. On success,
report pass/skip totals when emitted, elapsed time, and `PASS`. If the run is a
performance measurement, additionally follow `docs/COMMUNITY_BENCHMARKS.md`
exactly and report every required environment field and protocol deviation.
