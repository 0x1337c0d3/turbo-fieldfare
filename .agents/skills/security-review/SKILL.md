---
name: security-review
description: Security-review pending TurboFieldfare Swift, Metal, server, installer, and package changes for concrete exploitable flaws and supply-chain risk.
---

# Security Review Skill

Find concrete, exploitable issues in the change; do not emit a generic
checklist.

## Scope and context

Use a user-named PR when supplied. Otherwise review the current branch against
its merge base with `main`, falling back to staged changes when there is no
branch diff. State the scope, read each changed file in full, and read
`AGENTS.md` plus relevant server, format, installer, and runtime documentation.
Note changes to `Package.swift`, `Package.resolved`, build plugins, binary
targets, scripts, and GitHub Actions.

## Threat focus

For a finding, cite a specific line and describe a plausible attacker action
and impact.

**Memory, Metal, and FFI safety**

- Raw pointers or buffer bindings derived from untrusted sizes without checked
  range/alignment validation.
- Pointers escaping `withUnsafeBytes`/`withUnsafeMutableBytes`, incorrect
  `Data(bytesNoCopy:)` deallocators, use-after-unmap, or C/Objective-C ownership
  mistakes.
- Metal buffer length, offset, thread-grid, or shader struct assumptions that
  let malformed model/image data produce out-of-bounds GPU access.

**Parsing, files, and installer transactions**

- Unbounded reads/decodes, allocation before validating lengths, decompression
  bombs, integer conversion/overflow, overlapping ranges, and acceptance of
  non-canonical or partially verified `.gturbo` state.
- User-controlled paths joined or opened without containment checks, symlink
  races, archive traversal, unsafe temporary-file permissions, and
  check-then-use transaction gaps.
- Resume/checkpoint logic that trusts unverified bytes or can publish a partial
  pack as complete.

**Server and command injection**

- Binding anywhere other than `127.0.0.1`, permissive CORS, proxy/tunnel
  assumptions, request bodies without size limits, unsafe connection/resource
  accounting, or endpoints that expose local files or internal errors.
- `Process` calls that pass untrusted input through a shell (`sh -c`, `bash -c`)
  or allow executable/path selection. Passing a value as a distinct argument is
  not shell injection by itself.
- Tool-call handling that weakens or bypasses the client's normal permission
  policy.

**Concurrency and state isolation**

- Races in conversation admission, cancellation, model/KV lineage ownership,
  installer publication, or decode-service IPC.
- Actor isolation escapes, unchecked continuations, locks across suspension,
  and TOCTOU between validation and use.
- Cross-request leakage of prompts, images, cached tokens, model paths, or
  retained conversation state.

**Images and fail-closed behaviour**

- Missing/invalid vision companion packs being ignored after accepting an
  image, or an image request continuing as text-only.
- Image dimensions, pixel counts, decoded bytes, or multipart/base64 payloads
  accepted without limits before allocation.

**Secrets, crypto, and supply chain**

- Tokens or credentials in source, fixtures, logs, diagnostics, crash output,
  or overly descriptive values; TLS verification disabled for downloads.
- Weak randomness or hashes used for authentication/integrity, unsigned or
  insufficiently verified remote content, and checksums compared
  non-atomically or against the wrong bytes.
- New SwiftPM packages that are unnecessary, unexpectedly unpinned, sourced
  from an untrusted URL/revision, add executable build plugins, or alter
  `Package.resolved` unexpectedly. Use an appropriate current advisory source
  when dependency risk is material; use a source that actually covers SwiftPM.

**Insecure defaults**

- Runtime protections present only in assertions/debug builds.
- Changes that loosen safe defaults, enable experimental controls, expose the
  loopback service, or convert a validation failure into fallback behaviour.

## Report

Rank by exploitability in this codebase using Critical / High / Medium / Low /
Info. Use this form, omitting empty severity headings:

```markdown
## Security Review: <scope>

### High
- **`path/File.swift:42` — <class>**
  Attack: <concrete attacker action and impact>
  Fix: <concise remediation>

### Out of scope / accepted
<only non-obvious exclusions>

### Verdict
<safe to ship, fix blockers first, or needs broader threat modelling>
```

A finding requires a location and plausible attack; otherwise make it an Info
note or omit it. When called from `/pr`, keep the result self-contained for the
PR body.
