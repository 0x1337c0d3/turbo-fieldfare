---
name: fmt
description: Format Rust code with rustfmt and report what changed.
---

# /fmt

Format the codebase. Single source of formatting truth.

## Steps

### 1. Verify rustfmt is installed

```bash
rustup component list --installed | grep rustfmt
```

If missing: `rustup component add rustfmt`. If that fails, halt with "Run /setup first."

### 2. Run rustfmt

```bash
cargo fmt
```

Capture the output. `cargo fmt` reformats all `.rs` files in the workspace in place.

### 3. Report what changed

```bash
git diff --name-only
```

Parse the list to find `.rs` files that were modified by the formatter.

Report one of:

- **Reformatted:** list the files that were rewritten (`file:` per line).
- **Already formatted:** print "Nothing to do — all files already formatted."
- **Error:** print the offending file and the error verbatim. Do **not** attempt to fix syntax errors — they must be resolved by the user.

Do not run in `--check` mode here — `/fmt` is the *apply* step. The PostToolUse hook is the *check* step. The `/commit` gate runs `--check` separately.
