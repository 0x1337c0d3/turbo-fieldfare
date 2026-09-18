---
name: setup
description: Verify and bootstrap the TurboFieldfare Swift and Metal development environment on Apple Silicon without downloading or running the model.
---

# /setup

Verify the local development environment. This workflow is model-free: do not
download, repack, load, duplicate, or delete a `.gturbo` model.

## Checks

1. Read `AGENTS.md` and the `swift-tools-version` line in `Package.swift`.
2. Report the host and toolchain:

   ```bash
   uname -m
   sw_vers
   swift --version
   xcode-select -p
   xcodebuild -version
   xcrun --find metal
   ```

   TurboFieldfare requires Apple Silicon, macOS 26 or newer, and Swift 6.2 or
   newer. If one is missing or too old, stop and name the unmet requirement.
   Do not switch or install Xcode without the user's approval.

3. Verify that the bundled formatter is available:

   ```bash
   swift format --version
   ```

4. Build the same configuration used by CI:

   ```bash
   swift build -c release
   ```

   Dependency resolution performed by SwiftPM is expected. If it changes
   `Package.resolved`, report that change; do not silently stage it. Report
   compiler failures verbatim and do not turn `/setup` into an implementation
   task.

5. If the user intends to run inference later, report readiness without taking
   corrective action:

   ```bash
   test -f scratch/gemma4.gturbo
   memory_pressure -Q
   pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'
   ```

   A missing model is not a development-setup failure. Do not set or request
   `HF_TOKEN` unless the user asks to install/repack the model. Never terminate
   an existing model process.

## Report

Return a compact status for architecture, macOS, Swift, Xcode/Metal compiler,
release build, and optional model-run readiness. End with the exact next action
for any failed requirement.
