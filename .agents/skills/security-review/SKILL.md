---
name: security-review
description: Complete a security review of pending changes on the current branch. Focuses on unsafe code, injection, secrets, memory safety at FFI boundaries, insecure deserialization, path traversal, and supply-chain risk. Use when the user asks to "security review", "security audit", "check for vulns", or before raising a PR.
---

# Security Review Skill

You are conducting a security review of the changes on this branch. The goal is to find real, exploitable issues — not produce a generic checklist.

## Step 1 — Determine review scope

1. If the user names a PR, fetch via `gh pr diff <n>`.
2. Otherwise review branch vs `main`:
   ```bash
   base=$(git merge-base HEAD main)
   git diff "$base"...HEAD --name-only
   git diff "$base"...HEAD
   ```
3. If neither produces a diff, fall back to staged changes (`git diff --cached`).

State the scope in one sentence.

## Step 2 — Gather context

- Read each changed file **in full** — security bugs hide in surrounding context (where input enters, how output is used, what privileges the process holds).
- Read any `AGENTS.md` and `.env-template` files to understand secrets handling
  and trust boundaries.
- Note any new dependencies added to `Cargo.toml` / `Cargo.lock`.

## Step 3 — Threat focus

Review for the following classes. For each finding, point to a **specific line** and describe a **plausible attacker action**. Vague concerns are not findings.

**Unsafe code**
- `unsafe` blocks without a `// SAFETY:` comment that justifies all invariants.
- Raw pointer dereference from untrusted sources (network, file, env).
- `transmute` between non-trivially-related types.
- FFI boundaries that accept user-controlled sizes or pointers without validation.
- Use-after-free patterns in manual lifetime management.

**Injection — command execution**
- `std::process::Command` where any argument is built from user input without allowlisting.
- Shell expansion via `sh -c` with unsanitised input.

**Injection — query/template**
- SQL: string concatenation into queries instead of parameterised statements (sqlx, diesel).
- Format strings built from user-controlled data passed to log macros (log injection / log forging).

**Deserialisation**
- `serde` deserialising untrusted input into types that execute logic in `Deserialize` impls.
- `bincode` / `rmp-serde` / `postcard` decoding of untrusted bytes without length limits.
- `serde_yaml::from_str` with untrusted YAML (YAML merge keys can cause unexpected behaviour).
- `std::io::Read` without a size cap on untrusted streams (memory exhaustion).

**Path traversal & file handling**
- `std::fs::File::open(user_input)` or `std::path::Path::join(user_input)` without canonicalisation and prefix check.
- Zip/tar extraction using paths from the archive without strip/containment (`zip_extract`, `tar` crate).

**AuthN / AuthZ**
- New endpoints or handlers lacking auth checks present on siblings.
- Authorisation decisions made on client-supplied IDs without ownership verification (IDOR).
- Hardcoded credentials, API keys, or default passwords in source or config.
- Token/session handling: weak generation (`rand::random` instead of `rand::rngs::OsRng`), missing expiry.

**Secrets & data exposure**
- Secrets committed to the repo (high-entropy strings, `AKIA*`, `ghp_*`, `xoxb-*`, PEM blocks).
- Secrets written to logs, error messages, or `Display` / `Debug` impls on types that hold credentials.
- Sensitive fields in structs that derive `Debug` without a custom redacting impl.

**Crypto**
- MD5 / SHA1 for security purposes (`md5` crate, `sha1` crate).
- Static IVs, hardcoded keys, ECB mode.
- `rand::thread_rng()` for security-sensitive tokens — use `OsRng`.
- TLS verification disabled (`danger_accept_invalid_certs`, `danger_accept_invalid_hostnames`).

**Integer safety**
- Unchecked arithmetic on attacker-controlled values in release mode (overflow wraps silently).
- Casting user-supplied `usize` to `i32` or vice versa without range check.
- Buffer indexing with user-supplied offsets without bounds validation before the index.

**Supply chain**
- New `Cargo.toml` dependencies: are they pinned in `Cargo.lock`? Are they from trusted sources?
- Typosquat-prone names (`serdé`, `actx-web`).
- Build scripts (`build.rs`) — do new deps introduce one? Build scripts run at compile time with full system access.
- `cargo audit` output: check if any added crate has known CVEs.

**Insecure defaults**
- Binding to `0.0.0.0` without justification.
- Permissive CORS (`*`), disabled CSRF.
- `debug_assertions`-gated checks that should also run in release.

**Race conditions & TOCTOU**
- File existence check followed by open in separate syscalls.
- `Mutex` lock dropped early (temporary borrow) before a dependent operation completes.
- `Arc<Mutex<_>>` held across `.await` (deadlock risk in async context).

## Step 4 — Report

Use **CVSS-flavoured severity** (Critical / High / Medium / Low / Info), ranked by *exploitability in this codebase*, not the abstract worst case.

```
## Security Review: <one-line scope>

### Critical
- **`file.rs:42` — <vuln class>**
  Attack: <what an attacker does, concretely>
  Fix: <one-line remediation>

### High
- ...

### Medium
- ...

### Low / Info
- ...

### Out of scope / accepted
<things you considered but ruled out — terse, only if non-obvious>

### Verdict
<one sentence: safe to ship / fix blockers first / needs broader threat modelling>
```

Rules:
- Always cite `file:line`. No findings without a concrete location.
- A "finding" needs a plausible attacker and a plausible impact. If you can't write the Attack line, it's at most an Info note.
- Do NOT pad with generic advice the reader already knows.
- If the diff is security-clean, say so in one line and end with the Verdict.

## Step 5 — If invoked from `/pr`

When the caller is `/pr`, your output is embedded in the PR body's **Security notes** section. Keep the report self-contained — anyone reading the PR should understand each finding without running the skill themselves.
