# Kickoff — agent-identity AFK batch

Run via /afk-feature-workflow. Spec: [PRD.md](PRD.md), architecture:
`docs/adr/0032-per-installation-agent-identity.md` (accepted), decision
trail: [MAP.md](MAP.md) + closed tickets 01–10 in `issues/`.

## Batch

Implementation issues `issues/11-*.md` … `issues/18-*.md`, all
`ready-for-agent`, all AFK. Dependency-respecting order:

1. 11 — agent key, dedicated agent, gate state `agent` (spine)
2. 13 — forge store + `boxa forge` CLI (independent of 11)
3. 15 — glab in image + per-project gh/glab volumes (independent)
4. 12 — SSH surface for three states (after 11)
5. 14 — container delivery: forge env + committer (after 13)
6. 16 — onboarding step `agent-identity` (after 11)
7. 17 — forge checklists + adopt-existing import (after 13, 16)
8. 18 — docs + glossary (last)

## Standing constraints

- Coding delegated to Codex via MCP `boxa-codex-delegate` inside a
  subagent (per afk-feature-workflow defaults); commit per issue right
  after tests, NO per-issue review; ONE review loop over the whole
  feature at the end.
- Work on `main` (repo convention), user pushes himself.
- shellcheck clean incl. info-level; interactive flows tested via real
  pty (no stubbed consent/prompt seams); conf parsers strict with
  byte-preserving writers (tests/ssh.sh patterns).
- UI strings/comments English.
- Issue 15 needs a docker image build to verify.
- Live host verification (wizard end-to-end, real machine user +
  service account, push/PR/MR round-trip, WSL2 reboot persistence) is
  the USER's, after the batch — list what to verify in the handoff.
