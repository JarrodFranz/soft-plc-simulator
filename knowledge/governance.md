---
id: knowledge:governance
title: Knowledge Base Governance
domain: root
version: "2026-08"
topics: [governance, process, maintenance, conventions]
summary: The authority on how knowledge/ is structured, placed into, versioned, and kept from drifting, including the learning-loop pipeline from a session finding to a cited canonical update.
related:
  - knowledge:index
  - knowledge:gaps
---

# Knowledge Base Governance

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** authored as the foundation governance document for `knowledge/`, defining the
> rules every subsequent author and future session must follow when adding to or revising it.
> **Read this before:** creating a new file under `knowledge/`, editing an existing one, or
> deciding where a piece of newly-learned information belongs.

---

## 1. Placement table

Every piece of knowledge belongs in exactly one place. Use this table to decide where.

| Type of knowledge | Goes in |
|---|---|
| A fact true of an industrial protocol regardless of this app (wire format, byte order, framing) | `knowledge/industry/protocols/<protocol>.md` |
| A fact about a vendor PLC project/exchange file format (L5X, PLCopen TC6) | `knowledge/industry/plc-formats/<format>.md` |
| A fact about IEC 61131-3 language semantics (ST/LD/FBD/SFC, tasks, custom FBs) | `knowledge/industry/iec61131/<topic>.md` |
| A fact about how *this app's engine* behaves (scan order, tag resolution, sim rules, protocol hosting, UI repaint, default-project catalog) | `knowledge/app/<topic>.md` |
| A fact about how *this project's team* verifies or develops (browser verification method, spec-to-PR process) | `knowledge/practices/<topic>.md` |
| A single-session or single-observation finding, not yet folded into a canonical file | `learning/registry.md` as a TL-N (tentative), or CL-N once confirmed |
| An open question, or coverage the knowledge base is known to lack | `knowledge/gaps.md` |
| A feature-scoped living doc still being actively maintained alongside code | `docs/<feature>.md` (not `knowledge/`; see [index.md](./index.md#7-relationship-to-other-folders)) |
| A pre-implementation design rationale (why a shape was chosen) | `docs/superpowers/specs/` and `docs/superpowers/plans/` (process artifact, cited but never authoritative) |
| An architecture decision record | `DECISIONS.md` (repo root; named and cited, not duplicated) |
| Deferred/not-yet-done implementation work | `docs/DEFERRED.md` |

---

## 2. Knowledge layering

`knowledge/` sits at the top of a four-layer stack, each layer with a different volatility and
authority:

1. **Canonical (`knowledge/`)** - durable, verified, cross-referenced. Changes only when the
   underlying fact changes or a CL/TL confirms something new. This is the layer other sessions
   should read first.
2. **Learning (`learning/`)** - append-only session log. Never edited to remove history; entries
   are marked superseded, not deleted. This is the *staging area* for canonical updates, not a
   substitute for them.
3. **Process artifacts (`docs/superpowers/specs/`, `docs/superpowers/plans/`)** - snapshot the
   intent and design at the time a feature was planned. They are evidence of *why*, never
   evidence of *current behavior* - the implementation may have diverged since.
4. **Code comments** - the most granular, most perishable layer, local to one file. Cited as
   evidence pointers from `knowledge/`, never duplicated at length.

A fact only belongs in `knowledge/` once it is durable and verified. A fact that is still
single-observation belongs in `learning/registry.md` as a TL-N until a second confirmation (or
an authoritative source) promotes it to CL-N and it gets folded into a canonical file.

---

## 3. Version policy

Every canonical file's frontmatter carries `version: "2026-08"` - a knowledge-current-as-of
marker, not a semantic version. When a file's content is re-verified against the implementation
and found still accurate, the marker may be left unchanged. When content is added, corrected, or
re-verified after a code change, bump the marker to the current year-month. The provenance
blockquote's "Current as of" line must always match the frontmatter `version`.

---

## 4. Single canonical file per topic

Each topic has exactly one canonical file. Before creating a new file, search
`knowledge/**/*.md` for the topic. If a close match exists, extend it rather than forking a
second file that will drift from the first. If a topic legitimately spans two domains (for
example, task scheduling is both an IEC 61131 concept and an app-engine concern), pick the
domain that owns the *authoritative* mechanism (here: `industry/iec61131/task-scheduling.md`
owns the IEC-level model; `app/scan-engine.md` cites it rather than re-explaining it) and cross
link both ways.

---

## 5. Mandatory indexing - "link, don't name"

Every canonical file **must** be linked from its domain `index.md`, and every domain
`index.md` **must** be linked from the top-level [index.md](./index.md). A file that exists but
isn't linked is invisible to the next session and will get re-created by accident.

When referring to another piece of knowledge, always use a relative Markdown link to the file,
never a bare filename in prose or inline code. "See `slmp.md`" is wrong; "see
[slmp.md](industry/protocols/slmp.md)" is correct. This keeps the knowledge base navigable by
following links rather than by guessing paths.

---

## 6. Learning-loop integration

The pipeline from a session finding to durable knowledge is fixed:

1. During or immediately after a session, log the finding in `learning/registry.md` as a new
   `### TL-N` (single observation) or `### CL-N` (already backed by 2+ observations, a test, an
   E2E probe, or an authoritative source).
2. Add a Sessions Index row pointing at the session's artifact (if one exists under
   `learning/sessions/`).
3. Once a TL-N is confirmed by a second observation, promote it to CL-N in place (renumbering is
   not required; the id is permanent once assigned).
4. Fold the CL-N's substance into the relevant canonical file under `knowledge/`, as a row,
   bullet, or Wrong/Correct pair, citing the CL-N id inline. Add the id to that file's
   frontmatter `learnings:` list.
5. If a later finding **corrects** an existing CL-N, do not delete the old entry. Mark it
   `[SUPERSEDED by CL-M]` in `learning/registry.md`, add the new CL-M with the corrected rule,
   and update the canonical file's citation to point at CL-M. The history of "we used to think
   X" stays visible - silent deletion hides a class of mistake from recurring.

A canonical file with no `learnings:` entries is not a problem; not every fact needs a session
behind it (some are read straight from a spec or the implementation). A `learnings:` entry with
no corresponding CL-N in the registry is a defect - fix on discovery (see section 9).

---

## 7. Source-verification rule

Before writing any empirical claim into `knowledge/`:

1. **Check the authoritative source first.** For protocol facts, that is the published standard
   (Modbus spec, IEC 61131-3, IEEE 1815, ASHRAE 135, the Sparkplug B spec) or, absent a
   standard, the implementation. For app-behavior facts, that is always the implementation
   (`mobile/lib/**`), never a doc that describes it secondhand.
2. **If a doc and the code disagree, the code wins.** Note the doc as stale (report it; do not
   silently "fix" someone else's living doc as part of writing knowledge).
3. **Conflicting evidence gets investigated, not recorded.** If two runs of the same probe give
   different results, that is a bug to chase down, not a "sometimes X, sometimes Y" line in the
   knowledge base. Knowledge files state settled facts.
4. **Negative claims ("this doesn't work") carry the highest evidence bar.** State exactly what
   was tested: the input shape, the client library, the exact error or absence of expected
   behavior. "OPC UA doesn't support X" is not admissible; "the Rust `opcua` crate's
   `write()` call against this server's read-only System tag returns `BadNotWritable`, verified
   via `mobile/test/...`" is.

---

## 8. Naming and layout

- Filenames: lowercase kebab-case, no numbering prefixes. Domain folders: lowercase nouns.
- Layout is fixed by [index.md](./index.md); do not invent new top-level folders under
  `knowledge/` without updating this governance file first.
- Frontmatter keys appear in the exact order specified in the authoring conventions; `id`
  mirrors the file's domain path (`knowledge:<domain-path>/<file-slug>`).
- Links are relative Markdown links only. No wiki-links, no bare filenames as references.

---

## 9. What does NOT belong in `knowledge/`

- **Active work** - anything describing a task in progress belongs in the session's own
  scratch space or `learning/sessions/`, not `knowledge/`.
- **Specs and plans** - `docs/superpowers/specs/` and `docs/superpowers/plans/` are process
  artifacts. They may be *cited* from a canonical file as design rationale, but their content
  must never be copied wholesale into `knowledge/` as if it were verified behavior.
- **Generated outputs** - build artifacts, screenshots, diffs, review reports. These live where
  they were generated (`.playwright-artifacts/`, `.git/sdd/`, etc.) and are referenced by path
  as evidence, never copied in.
- **Raw vendor manuals** - do not paste standard text or vendor documentation into `knowledge/`.
  Cite the standard by name and section, and describe the practically-relevant subset in this
  project's own words.

---

## 10. Anti-fragmentation - don't drift

`knowledge/` degrades the same way any reference doc set does: small near-duplicate files
accumulate, each slightly out of sync with the others. Two rules keep this from happening:

1. **Don't fragment.** Before adding a new file, check section 4 (single canonical file per
   topic). An "atomic gotcha" is not a new file - it is a CL-N folded into the file that already
   owns the topic.
2. **Fix drift on discovery.** If, while writing or reading unrelated knowledge, you notice an
   existing canonical file contradicts the implementation, fix it immediately as part of that
   session's work (with a CL-N backing the correction) rather than filing it as a gap for later.
   [gaps.md](./gaps.md) is for coverage that does not exist yet, not for known-wrong content
   that does.

---

## Quick self-check before adding knowledge

1. Does this fact already have a canonical home? Search before creating a new file
   (section 4).
2. Have I verified this against the authoritative source or the implementation, not a
   secondhand doc (section 7)?
3. If this is a negative claim, have I stated exactly what was tested?
4. Is this durable enough for `knowledge/`, or is it still single-observation and belongs in
   `learning/registry.md` as a TL-N first (section 2)?
5. Have I linked the file from its domain `index.md`, and is that domain linked from the top
   [index.md](./index.md) (section 5)?
6. If this corrects an earlier CL-N, did I mark the old one superseded instead of deleting it
   (section 6)?
7. Are all links relative Markdown links, filenames kebab-case, frontmatter keys in order
   (section 8)?
8. Does this belong in `knowledge/` at all, or is it active work, a spec, a generated output, or
   vendor manual text that belongs elsewhere (section 9)?

---

## Related

- [index.md](./index.md) - domain navigation hub and the relationship-to-other-folders table.
- [gaps.md](./gaps.md) - the open-question register this governance model feeds.
- [../learning/registry.md](../learning/registry.md) - the CL/TL log referenced throughout
  section 6.
- [../learning/HOW-TO-USE.md](../learning/HOW-TO-USE.md) - the practical, step-by-step version
  of the learning loop described here.
