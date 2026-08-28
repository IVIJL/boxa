# 09 — Forge pickers: missing question/context in fzf (use --header)

Status: done

## Parent

Live-verification feedback (2026-08-25); ADR 0006 (picker conventions),
ADR 0032/0033 setup flows.

## Problem

Every `picker::one` call in the forge setup/checklist/migration flows
passes only `--prompt`; the step title and context are printf'd to
stdout beforehand, which full-screen fzf hides. The user sees answer
options (Done/Skip, posture lines, token choices) with NO visible
question. `lib/picker.sh` provides `--header` exactly for this
("fzf otherwise hides everything that was on the terminal before
launch") and the checklist code does not use it.

Additional narrative gaps observed live:

- "Expected account username (optional; verification is authoritative):"
  appears with zero context about what it is for.
- No legend of where you are in the checklist (which step, of how many,
  for which forge/account).
- No explanation of WHY a token is minted (SSH key covers only git
  transport; the token feeds gh/glab CLI + API + PR/MR + committer
  identity) and no end-of-flow summary of what got configured.

## What to build

- Every forge-flow picker passes `--header` carrying the question and
  the step context (e.g. "GitHub machine-user checklist — step 5/5:
  mint a PAT (the SSH key only covers git push/pull; gh CLI and PRs
  need a token)"). Free-text prompts (`read`) print one context line
  immediately above.
- Intro line per checklist: what will be configured and why (SSH =
  git transport, token = API/CLI).
- Outro summary: identity ID, kind, auth posture, what works now
  (push/pull, gh/glab, PR/MR) and what was skipped.

## Acceptance criteria

- [x] No forge-flow fzf screen shows options without the question in
      the fzf header (pty test asserts header text is rendered).
- [x] Expected-username prompt explains its purpose inline.
- [x] Checklist intro + outro summary exist and are tested.
