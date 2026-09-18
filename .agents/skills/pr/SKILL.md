---
name: pr
description: Security-review, validate, confirm the push, and open a TurboFieldfare pull request with a structured test and safety record.
---

# /pr

Raise a pull request from a feature branch. Never push before receiving the
user's explicit confirmation for that push.

1. Confirm the current branch is not `main` or `master` and identify its merge
   base with `main`.
2. Run `/security-review` on the branch diff. Critical/High findings block the
   PR; ask how to handle Medium findings; carry Low/Info notes into the body.
   If code changes, re-run `/test` and any affected build/check gate.
3. Ask: `Ready to push <branch> to origin and open a PR?` Stop on refusal.
4. Push with `git push -u origin <branch>`. Do not force-push after a rejection.
5. Open the PR with a conventional, at-most-72-character title and this body:

   ```markdown
   ## Summary

   - <user-visible change>

   ## Test plan

   - [ ] `swift build -c release`
   - [ ] `Scripts/test.sh`
   - [ ] Relevant repository checks pass
   - [ ] Any model run followed the AGENTS.md preflight (or: no model run)

   ## Security notes

   <self-contained /security-review result with file:line references>

   ## Notes

   <protocol deviations, skipped checks, or follow-ups; omit if empty>
   ```

   Use `gh pr create`; use `--draft` when the work is not ready rather than a
   title tag.
6. Return the PR URL.

Never claim performance from ordinary tests. For benchmark changes/results,
use `docs/COMMUNITY_BENCHMARKS.md` and include the required commit, hardware,
RAM, macOS, Swift, exact command, timing footer/error, and deviations.
