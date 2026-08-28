# 02 — Manifest guard rails: static test + doctor warning

Status: done

## Parent

ADR 0036 (proposed). Grill conclusions in `../NOTES.md`.

## What to build

Two guards for the invariant "nothing outside the manifest ever lands in the
shared config directory", covering the one new risk the directory mount adds
(a future file appearing in every Container automatically):

1. A static test in `tests/` that scans the codebase for references to files
   inside the shared config directory and fails when it finds a filename not
   listed in the manifest. Adding a third shared file must force a conscious,
   reviewable manifest bump to turn the test green. There is no CI; the test
   runs in the pre-commit review loop like the rest of `tests/`.
2. A `boxa doctor` check that compares the actual contents of the host shared
   directory against the manifest and warns about unexpected files (covers
   files placed by humans or editors rather than code).

## Acceptance criteria

- [x] Adding a codebase reference to a non-manifest filename in the shared
      directory makes the new test fail; adding the name to the manifest makes
      it pass (demonstrated in the test's own fixtures/self-check). Covered by
      `tests/shared-config.sh`: `scan_unlisted_shared_filenames` fixture cases
      ("static guard rejects an unlisted fixture filename" /
      "manifest addition admits the fixture filename"), plus a live scan of
      the whole repo ("codebase shared filenames match the manifest").
- [x] `boxa doctor` warns when an extra file exists in the host shared
      directory and stays quiet when only manifest files are present. Covered
      by `shared_config_unexpected_files()` (`docker-run.sh:884`), wired into
      the doctor summary (`docker-run.sh:5247`), and asserted by
      `tests/shared-config.sh` ("unexpected shared entries are reported" /
      "manifest-only shared directory is clean").
- [x] Existing test suites pass; shellcheck clean on touched scripts.

## Comments

Both guard rails were already implemented opportunistically in the issue-01
commit (`91027a2`), which added `shared_config_unexpected_files()` and the
static `scan_unlisted_shared_filenames` guard together with the manifest and
directory mount. No further code changes were needed for this issue; verified
by re-running the full proof (see below) rather than re-implementing.

## Blocked by

`01-directory-mount-manifest-transition.md` (needs the manifest and directory
to exist).

## Comments
