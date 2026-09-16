---
name: setup
description: Bootstrap the Rust dev environment — verify rustup, toolchain, rust-analyzer, cargo tools, codex-nav, and env vars.
---

# /setup

Bootstrap (or re-verify) the development environment. Idempotent — safe to re-run.

## Steps

### 1. Verify `rustup` is installed

```bash
rustup --version
```

If missing: stop and tell the user to install `rustup` from https://rustup.rs/. Do not attempt to install it without asking.

### 2. Verify the active toolchain

```bash
rustup show active-toolchain
```

If a `rust-toolchain.toml` file exists in the project root, verify the pinned toolchain is installed:

```bash
rustup toolchain list
```

If the pinned toolchain is missing, install it:

```bash
rustup toolchain install "$(grep 'channel' rust-toolchain.toml | cut -d'"' -f2)"
```

### 3. Verify the `rust-analyzer` editor LSP is available

```bash
rustup component list --installed | grep rust-analyzer
```

If not installed, add it:

```bash
rustup component add rust-analyzer
```

Also check that the binary is reachable:

```bash
rust-analyzer --version
```

If `rust-analyzer` is not found even after `rustup component add`, warn the user — it may need to be installed as a standalone binary or via their editor's extension.

### 4. Verify required cargo components

Check for and install if missing:

```bash
# rustfmt
rustup component list --installed | grep rustfmt || rustup component add rustfmt

# clippy
rustup component list --installed | grep clippy || rustup component add clippy

# llvm-cov (coverage)
cargo llvm-cov --version 2>/dev/null || cargo install cargo-llvm-cov
rustup component list --installed | grep llvm-tools || rustup component add llvm-tools-preview
```

### 5. Verify the `codex-nav` MCP is available

Use the `codex-nav` MCP supplied by the agent environment and initialize its
local index:

```text
code_nav_init()
```

If the tool is unavailable or initialization fails, report `codex-nav` as
missing and tell the user to configure it in their agent environment. Do not
install `rust-analyzer-mcp` and do not create a repository-local `.mcp.json`.
The `.codex-nav/` index is local tooling state and must remain Gitignored.

### 6. Run `cargo check`

```bash
cargo check
```

This verifies the project compiles without producing a linked executable. If it
fails, report the compiler error verbatim — do not attempt to fix compilation
errors during setup.

### 7. Ensure `.env` exists (if `.env-template` is present)

```bash
test -f .env || (test -f .env-template && cp .env-template .env)
```

If `.env` was just created, enumerate the keys the user needs to fill in (read `.env-template`).

### 8. Report

Print a short status block:

```
Setup status
  rustup              : <version>
  toolchain           : <active toolchain>
  rust-analyzer       : <version | missing>
  rustfmt             : <installed | missing>
  clippy              : <installed | missing>
  cargo-llvm-cov      : <version | missing>
  codex-nav           : <ready | missing>
  cargo check         : <ok | FAILED>
  .env                : <present | created from template | not applicable>
  RUST_LOG            : <set | unset>
```

Keep it tight — one line per item. If everything is green, end with "Ready." If anything is yellow/red, list the next action explicitly.
