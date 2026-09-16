---
name: story
description: Create a user story in stories/ linked to architecture components, or update an existing story's status
---

# /story

Manage user stories in the `stories/` directory. Stories are version-controlled markdown files, one per feature or use case.

---

## Creating a story

Invoke as `/story <title or description>`.

### 1. Read context

- Read `ARCHITECTURE.md` to get the list of valid component slugs
- Glob `stories/*.md` and parse front matter to determine the next ID (S-001, S-002, …)

### 2. Draft the story

Using the title/description, produce:

- **Use case** — "As a [user type], I want [action], so that [benefit]."
- **Acceptance criteria** — 3–5 concrete, testable conditions
- **Technical notes** — which components are involved and why
- **Tasks** — 2–5 implementation steps

### 3. Write the file

Create `stories/S-NNN-<slug>.md` where slug is a kebab-case version of the title.

```markdown
---
id: S-NNN
title: <title>
epic: <epic name or "Uncategorized">
status: backlog
priority: 2
components: [<comma-separated component slugs>]
created: <YYYY-MM-DD>
branch: ~
---

## Use Case
As a [user type], I want [action], so that [benefit].

## Acceptance Criteria
- [ ] ...
- [ ] ...

## Technical Notes
See ARCHITECTURE.md#<component-slug>.

## Tasks
- [ ] ...
- [ ] ...
```

Status values: `idea | backlog | in-progress | review | done`
Priority: 1=high, 2=medium, 3=low

### 4. Report

Output:
- File path created
- Component slugs linked
- Number of acceptance criteria
- Suggested next command: `/kanban` or `/story update S-NNN status=in-progress`

---

## Updating a story

Invoke as `/story update S-NNN <field>=<value>`.

Examples:
- `/story update S-001 status=in-progress`
- `/story update S-001 priority=1`
- `/story update S-003 status=done`

### Status transition: backlog → in-progress

When status moves to `in-progress`:

1. Derive branch name: `feature/S-NNN-<slug>` (slug from the story filename)
2. Check if branch exists: `git branch --list feature/S-NNN-<slug>`
3. If absent: `git checkout -b feature/S-NNN-<slug>`
4. If present: `git checkout feature/S-NNN-<slug>`
5. Update story front matter: `status: in-progress`, `branch: feature/S-NNN-<slug>`
6. Report the branch name

### Status transition: any → review

Update story front matter: `status: review`

Remind the user: push the branch and run `/pr` to open the pull request.

### Status transition: any → done

Update story front matter: `status: done`, `completed: <YYYY-MM-DD>`

### Other field updates

Edit the front matter value in place. Do not change other fields.

---

## Showing a story

Invoke as `/story show S-NNN`.

Pretty-print the full story content including rendered acceptance criteria and task list.

---

**Don't:**
- Create branches for any status other than `in-progress`
- Rename or move story files (the filename is the stable ID)
- Use `git add -A` or `git add .` when committing story file changes — stage the specific file
