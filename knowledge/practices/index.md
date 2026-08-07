---
id: knowledge:practices/index
title: Practices
domain: practices
version: "2026-08"
topics: [verification, testing, development-process, code-review, playwright, e2e]
summary: Domain hub for the development and verification practices proven on this project - how work gets specified, implemented, reviewed and verified end to end, and how a canvas-rendered Flutter app and eight in-app protocol hosts get proven correct with real clients.
related:
  - knowledge:index
  - knowledge:app/index
learnings: [CL-9, CL-10, CL-11, CL-16]
---

# Practices

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `CLAUDE.md`, `scripts/serve-web.sh`, `scripts/browser-check.mjs`,
> the `tool/*_e2e.sh` lane pattern, `docs/DEFERRED.md`, `mobile/test/defaults/`, and
> `.playwright-artifacts/defaults-redo-verify.md`.
> **Read this before:** verifying any UI change, standing up a new protocol's E2E lane,
> writing a widget test that touches real sockets, or running the spec -> plan -> review ->
> PR pipeline on a new workstream.

---

## What this domain covers

This app is a Flutter canvas app (CanvasKit web + native desktop) that hosts eight
industrial protocols in-process in pure Dart. Neither fact is verifiable the "normal" way:
the UI has no DOM to query, and a protocol host is only proven correct against a real
third-party client, not another Dart test. This domain captures the two verification
methods that actually work here, plus the process discipline (spec -> plan -> two-tier
review -> PR) that keeps a long-running, single-branch-at-a-time project coherent across
dozens of shipped workstreams.

## Where to look first

- Changed a screen, dashboard, or editor? Start at [verification.md](./verification.md) §2
  (the headless Playwright loop).
- Added or touched a protocol host? Start at [verification.md](./verification.md) §5
  (the `tool/*_e2e.sh` lane pattern).
- Writing a widget test that opens a real socket? [verification.md](./verification.md) §3
  (CL-10).
- Planning a new workstream or wondering why reviews happen twice?
  [development-process.md](./development-process.md).
- Deferring something on purpose? [development-process.md](./development-process.md) §3
  (`docs/DEFERRED.md`).

## Lookup table

| Topic | File | What it covers |
|---|---|---|
| Headless Playwright against Flutter-web CanvasKit | [verification.md](./verification.md) | No-DOM app, screenshot+console+network method, viewports, single-listener-on-port check |
| Widget-test fake-async vs real sockets | [verification.md](./verification.md) | `tester.runAsync`, why `dart:io` futures never complete in fake-async |
| Privileged-port classification | [verification.md](./verification.md) | EACCES/WSAEACCES vs EADDRINUSE, why port 502 needs special handling |
| Per-protocol E2E lanes | [verification.md](./verification.md) | `tool/*_e2e.sh`, real third-party clients per protocol, Windows PID-of-listener teardown |
| Desktop computer-use harness | [verification.md](./verification.md) | Build -> run -> interact -> verify loop for the Windows desktop build, real saved projects |
| Spec -> plan -> review -> PR pipeline | [development-process.md](./development-process.md) | Two-tier review (per-task vs whole-branch), why both are needed |
| Deferred-work registry | [development-process.md](./development-process.md) | `docs/DEFERRED.md` convention: record, strike through, never silently drop |
| Byte-identical snapshot technique | [development-process.md](./development-process.md) | Proving a refactor/move is data-neutral |

## Confirmed learnings

| CL | Rule |
|---|---|
| CL-9 | Flutter-web CanvasKit apps expose no DOM; Playwright drives them with screenshots + coordinate clicks, and screenshots work despite the continuous repaint loop. |
| CL-10 | `dart:io` futures never complete inside a widget-test's fake-async zone - wrap real socket work in `tester.runAsync` and assert the result `isNotNull`. |
| CL-11 | Binding port 502 requires privilege on POSIX (EACCES 13) and Windows (WSAEACCES 10013) - port-probe tests must classify permission-denied separately from address-in-use. |
| CL-16 | An in-app screenshot pane can time out on a continuously-repainting canvas app while headless Playwright captures fine - verify canvas apps with Playwright, not embedded preview screenshotters. |

## Related

- [verification.md](./verification.md) - the verification methods in full.
- [development-process.md](./development-process.md) - the pipeline that produces each change.
