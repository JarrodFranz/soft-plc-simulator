---
id: learning:how-to-use
title: How To Use The Learning Registry
domain: learning
version: "2026-08"
topics: [learning-loop, registry, sessions, process]
summary: Practical, step-by-step instructions for reading learning/registry.md before a task and writing to it after one, including when a finding is a TL vs a CL and how it gets folded into knowledge/.
related:
  - knowledge:governance
  - knowledge:index
---

# How To Use The Learning Registry

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** authored alongside the foundation seed of `learning/registry.md`, as the practical
> companion to the learning-loop rule defined in `knowledge/governance.md` section 6.
> **Read this before:** starting any investigation that might rediscover something already
> known, and before ending a session that surfaced a new, verified fact.

---

## 1. Before you start a task

Read [registry.md](./registry.md) - specifically:

1. The **Sessions Index** table, to see whether a session already covered this area. If one did,
   its `Key Learnings` column names the CL-N ids to read directly.
2. Search the **Confirmed Learnings** section for keywords related to your task (protocol name,
   language name, engine subsystem). Every CL entry names `**Applies to:**` a specific file or
   subsystem - match on that.
3. Check [../knowledge/gaps.md](../knowledge/gaps.md) - if your task is about to investigate
   something already logged as an open gap, read the gap's "what would close it" line first; it
   may already tell you the exact next step instead of starting from scratch.

If a CL or TL already answers your question, cite it and move on. Do not re-derive a fact that
is already registered - if you get a different result, that is itself worth a registry entry
(see step 4 below on corrections).

---

## 2. During the task

If you observe something true and not yet documented - a wire-format quirk, an execution-order
subtlety, a test-infrastructure gotcha, a rule about how a subsystem behaves - note it as you go.
You do not need to write the registry entry immediately; a scratch note during the session is
fine, as long as it gets promoted before the session ends.

---

## 3. After the task: writing a new entry

1. Decide **CL or TL**:
   - **CL-N (confirmed):** the finding is backed by a test, an E2E probe against a real client
     library, 2+ independent observations, or it matches an authoritative standard/spec.
   - **TL-N (tentative):** a single observation, not yet independently confirmed. Still worth
     recording - apply with caution, and look for a second confirming observation later.
2. Append a new `### CL-N - <short rule name>` (or `### TL-N - ...`) section under **Confirmed
   Learnings** (or a **Tentative Learnings** section if the file doesn't have one yet - add it
   above Confirmed Learnings). Use the next unused number; numbers are never reused, even for
   superseded entries.
3. Fill in the required fields, in this order:
   - `**Confirmed in:**` the session id (see section 4 for the id format)
   - `**Applies to:**` the specific file(s)/subsystem the rule governs
   - `**Rule:**` the rule itself, stated as an absolute claim with exact evidence
   - optional `**Wrong:**` / `**Correct:**` fenced code pairs, for gotchas that are best shown
     as a code example
   - `**Knowledge base updated:**` a bullet list of the canonical `knowledge/` file(s) this
     entry was folded into
4. Add or update a **Sessions Index** row for the session, with its `Key Learnings` column
   listing the CL-N/TL-N ids it produced, and `Status` set to `closed` once the entry is written
   (use `open` while a session is still in progress, `compared` if the finding is still being
   cross-checked against a second source).
5. Fold the rule into the **canonical file(s)** listed under `Knowledge base updated`: add a row,
   bullet, or Wrong/Correct pair there, citing the CL-N id inline (e.g. "(CL-7)"), and add the id
   to that file's frontmatter `learnings:` list.
6. Bump the `> Last updated:` line at the top of [registry.md](./registry.md).

A registry entry that never gets folded into a canonical file is incomplete - the registry is a
staging area, not a final destination (see
[../knowledge/governance.md](../knowledge/governance.md) section 2).

---

## 4. Session IDs

Format: `YYYY-MM-DD-kebab-slug`, e.g. `2026-08-06-default-projects-redo`. The date is when the
session ran; the slug is a short description of the task. If a session artifact exists (a report,
a transcript, a diff), place it under [sessions/](./sessions/) named after the session id, and
reference it from the Sessions Index row - though a Sessions Index row does not require an
artifact file to exist; many sessions are logged from the registry entry alone.

---

## 5. Correcting an existing entry

Findings are sometimes wrong or incomplete, and get corrected by later work. Never delete or
silently rewrite an existing CL-N/TL-N:

1. Add a new entry (`CL-M`) with the corrected rule and its own evidence.
2. Edit the old entry's heading to `### CL-N - <original name> [SUPERSEDED by CL-M]`, leaving its
   body intact.
3. Update every canonical file that cited `CL-N` to cite `CL-M` instead (and update its
   `learnings:` frontmatter list).

This preserves the history of "we used to believe X, then learned Y" instead of erasing it -
useful both for auditing and for catching a class of mistake that might recur.

---

## 6. Quick reference

| I want to... | Do this |
|---|---|
| Check if something is already known | Search `registry.md` Confirmed/Tentative Learnings by `**Applies to:**` keyword, or the Sessions Index by task area |
| Record a single-observation finding | Add a `### TL-N` entry |
| Record a well-evidenced finding | Add a `### CL-N` entry, then fold it into the cited canonical file(s) |
| Fix a wrong earlier finding | Add a new CL-M, mark the old entry `[SUPERSEDED by CL-M]`, update citations |
| Find out what a session actually did | Look up its row in the Sessions Index, then its listed CL-N/TL-N ids |

---

## Related

- [registry.md](./registry.md) - the registry itself.
- [../knowledge/governance.md](../knowledge/governance.md) - section 6, the authoritative
  learning-loop rule this file operationalizes.
- [../knowledge/gaps.md](../knowledge/gaps.md) - open gaps to check before starting new
  investigation.
- [sessions/](./sessions/) - per-session artifacts, referenced by session id from the registry's
  Sessions Index.
