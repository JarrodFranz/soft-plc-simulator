# In-App Log / Diagnostics Window

This document covers the app-wide, in-memory diagnostic log: what it
records, how to read and filter it in the **Logs** screen, how per-source
verbosity works, and a worked example of the failure that motivated the
whole feature.

Implementation: `mobile/lib/models/app_log.dart` (the pure `LogEntry` /
`LogRingBuffer` / `filterLogEntries` core), `mobile/lib/services/
app_logger.dart` (the `AppLogger` service — level gating, the lazy-message
contract), `mobile/lib/screens/logs_screen.dart` (the **Logs** screen), and
`mobile/lib/screens/workspace_shell.dart` (owns the one `AppLogger` instance
and threads it into the six protocol hosts and the shell's own subsystems).

## Why this exists

Before this feature, a protocol host that PARSED a request it didn't know
how to serve just... dropped it. Nothing recorded why. A concrete example:
an Ignition Siemens driver connects to the in-app S7comm server, the
Outbound Protocols card reads **"Running, Clients: 1"** — everything *looks*
healthy — and yet no data ever arrives, because the driver sent a ROSCTR or
function code the host's `switch` didn't have a case for, and the old code
silently `return`ed. There was no log, no error, nothing to grep. The Logs
window exists so that failure mode is diagnosable from the app alone, with
no companion tooling and no rebuild.

## What the Logs window shows

Open **Logs** from the left dock. The screen has three parts:

- **Filter bar** (always visible): a free-text search box (matches against
  both the message and the expanded detail, case-insensitive), a **Min
  level** dropdown (TRACE/DEBUG/INFO/WARN/ERROR — hides anything below the
  selected severity), a **Live tail** switch, and **Clear** (empties the
  buffer).
- **Sources** and **Per-source verbosity (DEBUG)** — two collapsed-by-
  default disclosure panels. Sources lets you narrow the view to one or more
  sources (a multi-select — none selected means "show all"). Verbosity is
  covered below.
- **The entry list** — virtualized (`ListView.builder`; the ring buffer can
  hold up to 2000 entries and they are not all built at once), newest
  towards the tail. Each row shows time, level (colour-coded), source, and
  message. A row with additional detail (a hex frame dump, a raw
  request/response summary) shows a disclosure chevron — tap the row to
  expand or collapse it.

**Live tail.** ON (the default) follows the tail of whatever is currently
visible — including the filtered view, if a filter is active — as new
entries arrive. Turn it OFF to freeze the view exactly where it is so you
can read without rows moving underneath you; new entries keep being
recorded in the background and reappear the moment you turn live tail back
on.

## The source list

Every subsystem logs under one of a fixed set of source tags (defined once
in `app_log.dart` so every part of the app names itself identically):

`OPC UA`, `Modbus`, `MQTT`, `DNP3`, `EtherNet/IP`, `S7`, `Scan`, `Project`,
`Sim`, `Historian`, `Scheduler`.

The six protocol names are the six in-app servers/clients. `Scan` is the
scan-engine loop (start/stop, watchdog trips, task overruns). `Project` is
project load/save/switch/import/export/backfill. `Sim`, `Historian`, and
`Scheduler` cover the simulated-I/O engine, the tag historian, and the
task-type scheduler — each logs only notable state changes, not per-tick
noise.

## Per-source verbosity — DEBUG/TRACE is off by default

Each source has its own minimum log level, independent of every other
source's. **The default minimum is INFO.** That means, out of the box:

- Lifecycle events are always visible at their natural level: bind
  success/failure (including a privileged-port bind error), client
  connect/disconnect, protocol-level errors, and write refusals (a forced
  tag or a read-only entry) all log at INFO/WARN and need no configuration.
- Per-request detail — function/service codes, byte counts, raw frame
  dumps — logs at DEBUG and is **silent until you ask for it**, specifically
  so normal operation doesn't flood the buffer with per-scan chatter.

To see that detail for one source, open **Per-source verbosity
(DEBUG/TRACE)** in the Logs screen and flip that source's switch on. This
sets only that source's minimum level to DEBUG — every other source's
verbosity is untouched. Flip it back off to return to INFO. There is
nothing to restart; the change takes effect on the very next log call.

## Memory-only — never written to disk

The log buffer lives entirely in memory (a bounded ring buffer, default
capacity 2000 entries — the oldest entry is evicted once the buffer is
full). It is **never serialized to a file, and never part of any project's
saved JSON.** That means:

- **It does not survive an app restart.** Closing and reopening the app (or
  a hot process kill) loses everything logged so far. If you need to
  capture a diagnosis, do it in the same session as the failure — there is
  no persisted history to go back and read later.
- Nothing here can ever show up in a project export/import, a backup, or a
  diff of saved project files. The log is purely a live, in-session
  diagnostic aid.

## Not cleared on project switch — and why

This is a deliberate difference from the tag historian
(`mobile/lib/services/tag_historian.dart`), whose recorded trend samples
*are* cleared on every project switch. The historian's samples belong to a
project's tags — they're meaningless once that project is gone. Log
entries are app-level: they record what the app and its hosts *did*,
including in the moments right around a project switch. If the log were
also wiped on switch, the exact class of bug this feature exists to catch —
"it broke right after I switched projects" — would erase its own evidence
the instant it happened. So the log keeps accumulating across every project
switch for the lifetime of the app process; only **Clear** in the Logs
screen (or an app restart) empties it.

## The no-credentials rule

**No credential ever reaches a log call.** MQTT passwords and OPC UA user
tokens pass through code that is log-adjacent (the authentication paths),
and every one of those call sites logs an *outcome* only — e.g. "username
auth rejected" — never the secret itself, and never a whole request/response
object that might be carrying one. This is enforced by a test
(`mobile/test/host_logging_test.dart`) that drives a real authentication
attempt with a known password string and scans every recorded entry's
message *and* detail for that string, asserting it never appears. If you are
extending logging anywhere near an authentication path, follow the same
rule: log what happened, never what was used to authenticate.

## Worked example: a client connects but nothing we serve

This is the exact scenario that motivated the feature. Suppose a SCADA
driver (say, Ignition's Siemens driver, talking S7comm) connects to the
in-app S7 server. The Outbound Protocols card shows:

```
S7comm: Running · Clients: 1
```

Everything about the card says the server is healthy — a TCP client is
connected — and yet no tag data ever updates on the SCADA side. Before this
feature, there was nothing more to look at. Now:

1. Open **Logs**. At the default verbosity you will already see an INFO
   entry recording the client connecting (`S7` source). If the driver is
   sending a request the host doesn't support, you will also see a **WARN**
   entry the first time it happens — something like *"Unsupported ROSCTR
   0x07 — request dropped"* or *"Unsupported function code 0x05 —
   request dropped"* — naming the exact offending code. That first-occurrence
   WARN fires at default verbosity precisely so this failure is visible
   without touching any configuration.
2. If the same unsupported request repeats (a driver that retries the same
   unsupported operation on a poll cycle, for example), the *repeat*
   occurrences log at **DEBUG**, not WARN again — so a driver hammering the
   same unsupported request doesn't spam the buffer with duplicate WARNs,
   but you can still see every occurrence, with its byte-level detail, by
   raising `S7` to DEBUG in the verbosity panel.
3. Filter the list: type the source name or a keyword like `ROSCTR` or
   `unsupported` in the text filter, or select just `S7` in the Sources
   panel, to isolate exactly this conversation from everything else the app
   is logging.
4. Expand the entry (tap it) if it carries a `detail` payload — for a
   dropped request this is typically the raw frame bytes — to see precisely
   what the client sent.

The result: instead of an unexplained "Running, Clients: 1" with no data
flowing, you have the exact code the client sent and confirmation the host
doesn't implement it — enough to know whether the fix is on the driver side
(wrong function/service selection) or the app side (a gap in protocol
coverage).
