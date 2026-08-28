# 16 — Multiple keys per persona

Status: done

## Parent

ADR 0034 decision 8.

## What to build

A persona can own several SSH keys. The flow offers: generate a new
key into the agent identity dir (`ssh-keygen`, passphrase-less for
agent-kind), take over an existing key (Key picker consent flow), or
detach one. Attached keys register in the Key registry and flow into
every project agent the persona is assigned to. The flow surfaces the
GitHub caveat that one auth key authenticates exactly one account
(offer per-key `ssh -T` verification showing who it authenticates as).

## Acceptance criteria

- [x] A persona with two keys forwards both into its project agents;
      detaching one removes it on next agent (re)population.
- [x] Generate-new and adopt-existing both work from the persona flow;
      private material is never read by boxa.
- [x] GitHub one-key-one-account caveat is shown at attach time.
- [x] shellcheck clean (incl. info); pty coverage.

## Blocked by

- 15-persona-registration-no-posture.md

## Comments
