---
name: design
description: Create or update ARCHITECTURE.md with system components, data flows, and ADRs
---

# /design

Maintain the living architecture document for this project. Creates `ARCHITECTURE.md` if absent; updates it in place if it exists.

### 1. Read current state

If `ARCHITECTURE.md` exists, read it in full. If absent, start from a blank structure.

Also read `AGENTS.md` for project name, technology context, and conventions.

### 2. Collect input

If invoked with an argument, treat it as a description of the system or a specific change to make.

If invoked with no argument, display the current architecture and ask:

```
What would you like to change? (add/update component, record a decision, describe a data flow, etc.)
```

### 3. Update the document

Apply the changes to produce an updated `ARCHITECTURE.md` with all five sections present:

**System Overview** — 2–3 sentences describing what the system does and its outer boundaries.

**Components** — One subsection per component, keyed by a stable slug (e.g. `auth-service`). Each subsection:

```markdown
### auth-service
- **Responsibility:** Handles user authentication and session management
- **Interface:** REST `/auth/*` endpoints; emits `user.login` events
- **Depends on:** user-db, email-service
```

**Data Flows** — Key scenarios as numbered steps, one subsection per flow:

```markdown
### User login
1. Client POSTs credentials to `auth-service /auth/login`
2. `auth-service` validates against `user-db`
3. On success, issues JWT and publishes `user.login` to event bus
```

**External Dependencies** — Table of third-party services, libraries, or infrastructure:

```markdown
| Dependency | Purpose | Version constraint |
|---|---|---|
| PostgreSQL | Primary datastore | >= 15 |
```

**ADR Log** — Append-only. Never remove or edit existing rows. New decisions go at the bottom:

```markdown
| # | Decision | Date | Status |
|---|---|---|---|
| ADR-001 | Use PostgreSQL over SQLite for multi-user writes | 2026-05-15 | Accepted |
```

ADR statuses: `Proposed | Accepted | Superseded | Rejected`

### 4. Write the file

Write the updated content to `ARCHITECTURE.md`. Preserve all existing ADRs verbatim.

### 5. Report

Output:
- What changed (new components, updated flows, new ADRs)
- Full list of current component slugs (for use with `/story`)

---

**Don't:**
- Shrink or reorder the ADR log
- Remove components that still appear in stories unless the user explicitly says so
- Invent component names that conflict with slugs already referenced in `stories/*.md`
