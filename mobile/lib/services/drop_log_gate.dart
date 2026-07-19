// First-occurrence severity gate for dropped-request log entries.
//
// *** WHY THIS EXISTS ***
// A host that PARSES a request but does not SERVE it used to log nothing at
// all; Task 3 closed those sites at DEBUG. But DEBUG is off by default, so the
// motivating failure (an Ignition Siemens driver whose every request was
// discarded while the Outbound Protocols card read "Running, Clients: 1") was
// diagnosable only by an operator who ALREADY suspected S7 and knew to raise
// that source's level. That does not announce itself, which was the point.
//
// The approved product rule is that FRAME DETAIL is off by default while
// ERRORS are always logged. A host discarding every request it receives is an
// error condition; the second and subsequent identical discards are frame
// detail. This class is exactly that split: the FIRST drop of a given reason
// on a given connection is a WARN (visible at the default `info` level), every
// repeat is a DEBUG.
//
// *** THE RECONNECT-LOOP BOUND ***
// Per-connection dedup alone is not enough. A client in a reconnect loop opens
// a FRESH connection every cycle, so a purely per-connection set would re-arm
// the WARN on every reconnect and reintroduce the flood by another route. So a
// WARN also has to claim a slot from a HOST-WIDE, per-reason budget of
// [kMaxDropWarnsPerReason]; once that budget is spent, every further drop of
// that reason logs at DEBUG no matter how many new sockets appear.
//
// The budget is reset only by [reset] (which each host calls from `start()`),
// never by traffic. The rejected alternative was to reset the dedup state on a
// successfully SERVED request: with two concurrent clients — one healthy, one
// broken — the healthy client's successful requests would continuously re-arm
// the broken client's WARN, producing the very flood the bound exists to
// prevent. A fixed budget has no such coupling and needs no clock, so it is
// also exactly reproducible in a test.
//
// *** THIS CHANGES NO PROTOCOL BEHAVIOUR ***
// It only chooses a LEVEL. A dropped frame stays dropped, no reply is added or
// removed, and with a null logger every method here is a no-op that touches no
// state at all.

import '../models/app_log.dart';
import 'app_logger.dart';

/// How many WARN-level drop entries one host will emit for any single reason
/// before falling back to DEBUG for that reason. Small on purpose: the WARN's
/// whole job is to ANNOUNCE that the host is discarding requests. Once said,
/// the per-frame DEBUG stream is the diagnostic tool, not the announcement.
const int kMaxDropWarnsPerReason = 3;

/// Host-scoped drop-logging policy. One per host instance; hand each accepted
/// connection its own [ConnectionDropLog] via [forConnection].
class DropLogGate {
  /// The `kLogSource*` constant every entry from this gate is filed under.
  final String source;

  /// Optional diagnostics sink. Null makes every call a no-op — a host built
  /// without a logger behaves byte-for-byte as it did before.
  final AppLogger? logger;

  /// How many WARNs this host has already spent on each reason.
  final Map<String, int> _warnsByReason = <String, int>{};

  DropLogGate(this.source, this.logger);

  /// Clears the host-wide WARN budget. Hosts call this from `start()` so a
  /// restart re-announces a still-broken configuration.
  void reset() {
    _warnsByReason.clear();
  }

  /// A fresh per-connection view of this gate.
  ConnectionDropLog forConnection() => ConnectionDropLog._(this);

  /// True if a WARN slot was successfully claimed for [reason] on a
  /// connection whose already-warned set is [connectionSeen]. Mutates both
  /// [connectionSeen] and the host-wide budget, so it is called ONLY when an
  /// entry is actually going to be recorded.
  bool _claimWarn(Set<String> connectionSeen, String reason) {
    if (!connectionSeen.add(reason)) {
      return false; // this connection already warned about this reason
    }
    final spent = _warnsByReason[reason] ?? 0;
    if (spent >= kMaxDropWarnsPerReason) {
      return false; // host-wide budget exhausted — bounds a reconnect loop
    }
    _warnsByReason[reason] = spent + 1;
    return true;
  }
}

/// One connection's view of its host's [DropLogGate].
class ConnectionDropLog {
  final DropLogGate _gate;

  /// Reasons this connection has already emitted a WARN for.
  final Set<String> _warned = <String>{};

  ConnectionDropLog._(this._gate);

  /// Records a request that was parsed but not served.
  ///
  /// [reason] is a short, STABLE key identifying the kind of drop (not the
  /// formatted message, which carries variable wire values) — it is what the
  /// dedup is keyed on and it never reaches the log itself.
  ///
  /// [build] is invoked lazily, INSIDE the logger, and only when the chosen
  /// level is actually enabled — so a suppressed repeat at the default level
  /// costs no string interpolation at all.
  void drop(String reason, String Function() build) {
    final logger = _gate.logger;
    if (logger == null) {
      // Claim nothing and touch no state: a bare host must be indistinguishable
      // from one built before this class existed.
      return;
    }
    final level = _gate._claimWarn(_warned, reason) ? LogLevel.warn : LogLevel.debug;
    logger.logLazy(_gate.source, level, build);
  }

  /// Records a silence the PROTOCOL ITSELF requires — an EtherNet/IP NOP, a
  /// DNP3 CONFIRM, a Modbus RTU broadcast. These reach the same "no reply was
  /// sent" code paths as a real drop, but nothing is wrong: the request was
  /// understood and handled correctly, and staying silent IS the correct
  /// answer.
  ///
  /// So they are never promoted to WARN. Announcing correct behaviour as a
  /// warning would train an operator to ignore the warnings that matter,
  /// which would undo the very thing the first-occurrence WARN exists to
  /// achieve. They stay pure frame detail: DEBUG, off by default, lazy.
  void specSilence(String Function() build) {
    _gate.logger?.logLazy(_gate.source, LogLevel.debug, build);
  }
}
