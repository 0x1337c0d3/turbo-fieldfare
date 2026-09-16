---
name: pr
description: Security review → confirm with user → push branch → open PR with structured body.
---

# /pr

Raise a pull request. Security review runs first, the user confirms the push, then `gh` opens the PR.

## Steps

### 1. Branch sanity

```bash
git rev-parse --abbrev-ref HEAD
```

If the current branch is `main` (or `master`): **halt.** PRs come from feature branches. Tell the user to switch.

### 2. Security review

Run `/security-review` against the branch diff (`git diff $(git merge-base HEAD main)...HEAD`).

Handle findings:

- **Critical / High:** halt. The user must address them before the PR opens. Do not auto-apply security fixes — surface them and let the user decide.
- **Medium:** surface, ask whether to address pre-PR or defer to a follow-up.
- **Low / Info:** include in the PR body's Security notes; do not block.

If anything was fixed: re-run `/test` to confirm no regressions.

### 3. Confirm push with the user

This confirmation is **per-push**. A previous approval does not carry over.

Ask, explicitly: *"Ready to push `<branch>` to origin and open a PR? (yes/no)"*

On `no`: stop and report nothing was pushed.

### 4. Push

```bash
git push -u origin <branch>
```

If the remote rejects the push (non-fast-forward, branch protection, etc.): do **not** force-push. Report the error and ask the user.

### 5. Open the PR

Compose the PR body with this structure:

```markdown
## Summary

- <bullet: what changed, in user-visible terms>
- <bullet: ...>

## Test plan

- [ ] <how to verify the change works>
- [ ] <edge case covered>
- [ ] CI tests pass (`cargo test`, clippy clean, coverage ≥ 80%)

## Security notes

<verbatim output from /security-review — keep the file:line refs>

## Notes

<anything else worth flagging to a reviewer — out-of-scope follow-ups, deferred work, etc. Omit if empty.>
```

Then:

```bash
gh pr create --title "<conventional commit subject>" --body "$(cat <<'EOF'
<body above>
EOF
)"
```

Title rules:

- Match the most representative commit's subject (or compose a new conventional-commit subject if the branch has many commits).
- ≤ 72 chars. No emoji. No `[WIP]` tags — if it's WIP, use `gh pr create --draft`.

### 6. Report

Return the PR URL on its own line so the user can click it. Nothing else needed.

## Don't

- Don't push before the user confirms in step 3, even if `/security-review` is clean.
- Don't open a PR with un-addressed Critical/High security findings.
- Don't force-push to shared branches without an explicit user request — and even then, never to `main`.
