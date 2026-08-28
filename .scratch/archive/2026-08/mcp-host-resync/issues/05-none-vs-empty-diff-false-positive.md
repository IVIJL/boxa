# 05 — Changed-detection false positive: absent key vs empty value

Status: done

## Parent

Live-test finding against issue 01's no-op change detection
(#mcp-host-resync, beca814). Seen on host as
`diff: headers: catalog=None candidate={}` for dozzle.

## Root cause (confirmed)

`_safe_diff` compares raw `.get(field)` values with no normalization
(`scripts/mcp/catalog_import.py:191-195`) and the in-sync verdict is
plain dict equality (`catalog_import.py:302-303`). `_entry()` always
emits `"headers": {}` for http candidates (`catalog_import.py:140`),
so a stored catalog entry that simply OMITS the key (written by an
older build or by hand) compares `None != {}` and reports "changed" +
a phantom diff line although nothing differs.

## What to build

- Normalize BOTH sides through one canonical form before the no-op
  comparison and before `_safe_diff`: absent key, `None`, and empty
  container (`{}`/`[]`) are equal for container-valued fields
  (headers, env, secretHeaderKeys, and any other field `_entry()`
  emits as a container). Prefer running the stored entry through the
  same `_entry()`-style canonicalization rather than ad-hoc per-field
  `or {}` sprinkling, so detection and apply keep sharing one mapping
  (ADR 0031 invariant).
- The diff output must not show `catalog=None candidate={}` style
  no-op lines anymore; a genuinely changed field still shows both
  values.
- Reimporting such an entry (selected explicitly) reports "in sync"
  and changes nothing — unless another field (e.g. secretValues)
  genuinely differs, in which case only that field appears in the
  diff.

## Acceptance criteria

- [x] Catalog entry with `headers` key absent + host candidate with no
      headers → detection says in-sync, no diff line (test).
- [x] Same entry with a genuine secretValues difference → detection
      says changed with ONLY the secretValues diff line (mirrors the
      user's dozzle case).
- [x] Symmetric coverage for env/secretHeaderKeys absent-vs-empty.
- [x] Genuine changes on each field still flip detection (existing
      issue-01 field-matrix tests stay green).
- [x] Tests green (`python3 -m unittest discover -s tests -q`).

## Blocked by

None. Independent of 03/04.

## Comments

- 2026-08-21: The user's dozzle entry predates beca814's write paths
  (current `add_remote_entry`/`updated_catalog_entry` always persist
  `headers`), so old entries without the key exist in the wild.
