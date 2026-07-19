// Pure Dart MQTT / Sparkplug B PUBLISHER SESSION logic — no dart:io /
// Flutter imports (only `dart:convert` + `dart:typed_data`). Turns a project
// + its `MqttProtocolConfig` into publish descriptors (topic + payload bytes
// + qos + retain) and decodes inbound command payloads back into tag writes.
// No sockets: the host (a later task) owns the TCP connection, wraps these
// descriptors into MQTT PUBLISH packets via `mqtt_codec.dart`, and feeds
// inbound PUBLISH payloads into [MqttPublisher.decodeCommand].
//
// Determinism: every method that stamps a timestamp takes an explicit
// `nowMs` parameter — this file never calls `DateTime.now()` itself, so
// tests are fully deterministic and the host supplies the real clock.
//
// Force-awareness: every tag value is read via `readPath` (tag_resolver.dart)
// exactly once per publish, which is already force-aware — a forced scalar
// tag resolves to its forced value there, so it propagates to every
// telemetry publish (JSON and Sparkplug alike) with no special-casing here.
//
// Report-by-exception + Sparkplug session state: an [MqttPublisher] holds
// state that only makes sense for the lifetime of ONE broker connection:
//   - `_aliasByTag`/`_tagByAlias`: the Sparkplug alias table, assigned in
//     the project's map order the moment [birthMessages] runs (a fresh
//     birth means a fresh session, so the table is rebuilt from scratch).
//   - `_seq`: Sparkplug's 0-255 message sequence counter, reset to 0 by
//     every [birthMessages] call (NBIRTH always carries seq 0) and advanced
//     by one on every subsequent NDATA (`changedPublishes`/
//     `heartbeatPublishes`).
//   - `_bdSeq`: Sparkplug's birth/death sequence counter. [willMessage]
//     advances it once per NEW connection attempt (the Will/NDEATH is
//     registered with the broker at CONNECT time, before the session's
//     NBIRTH can be sent) and [birthMessages] reads the CURRENT value
//     (no further increment) so the NBIRTH that follows a given NDEATH's
//     Will registration carries the SAME bdSeq — exactly the pairing
//     Sparkplug B subscribers rely on to detect a rebirth. Calling
//     [birthMessages] without ever calling [willMessage] is also supported
//     (bdSeq simply stays at its default, 0) for hosts/tests that don't use
//     an MQTT Will.
//   - `_lastPublished`: the report-by-exception baseline (tag path -> last
//     published value). Seeded to the CURRENT value of every mapped tag by
//     [birthMessages] (so a fresh session's first [changedPublishes] call
//     reports nothing until something actually changes since the birth
//     snapshot) and updated by both [changedPublishes] and
//     [heartbeatPublishes] as they publish.
library mqtt_publisher;

import 'dart:convert';
import 'dart:typed_data';

import '../../models/mqtt_map.dart';
import '../../models/project_model.dart';
import '../../models/protocol_settings.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';
import 'mqtt_sparkplug.dart';

/// The Sparkplug B topic namespace prefix (`spBv1.0/<group>/<msgType>/<node>`).
const String _sparkplugNamespace = 'spBv1.0';

/// The well-known Sparkplug B "Node Control" metric name a subscriber (e.g.
/// Ignition's MQTT Engine) publishes as a boolean-true NCMD metric to request
/// a rebirth (a fresh NBIRTH) — see [MqttPublisher.isRebirthRequest].
const String _rebirthMetricName = 'Node Control/Rebirth';

/// One publish the host must send: wrap into an MQTT PUBLISH packet (or, for
/// [willMessage]'s result, register as the CONNECT packet's Will) — this
/// pure unit never touches sockets itself.
class MqttPublishDescriptor {
  final String topic;
  final Uint8List payload;
  final int qos;
  final bool retain;

  const MqttPublishDescriptor({
    required this.topic,
    required this.payload,
    required this.qos,
    required this.retain,
  });
}

/// A decoded remote-write command, ready to apply via
/// `writePath(project, tagPath, value)`.
typedef MqttCommand = ({String tagPath, Object value});

/// Sanitizes a name for use as an MQTT topic segment: spaces become `_`, and
/// the three characters MQTT gives special meaning to in a topic path (`/`
/// the level separator, `#`/`+` the wildcards) are stripped outright so a
/// controller/project name can never accidentally fracture the topic tree
/// or collide with a wildcard subscription.
String _sanitizeForTopic(String name) {
  final spaced = name.replaceAll(' ', '_');
  final buf = StringBuffer();
  for (final rune in spaced.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '/' || ch == '#' || ch == '+') {
      continue;
    }
    buf.write(ch);
  }
  return buf.toString();
}

/// True for the flat-JSON payload format; false (Sparkplug B) for anything
/// else (`'sparkplug'` is `MqttProtocolConfig`'s persisted value, but any
/// non-`'json'` string is treated as Sparkplug so a differently-spelled
/// value never silently falls back to JSON).
bool _isJson(MqttProtocolConfig cfg) => cfg.format == 'json';

String _controllerTopicName(PlcProject project) => _sanitizeForTopic(project.controllerName);

/// The Sparkplug B Edge Node id: the configured `edgeNodeId`, or — when
/// that's empty — the sanitized project name (per the brief's fallback).
String _edgeNode(MqttProtocolConfig cfg, PlcProject project) {
  final raw = cfg.edgeNodeId.trim().isEmpty ? project.name : cfg.edgeNodeId;
  return _sanitizeForTopic(raw);
}

String _statusTopic(MqttProtocolConfig cfg, PlcProject project) =>
    '${cfg.baseTopic}/${_controllerTopicName(project)}/status';

String _tagTopic(MqttProtocolConfig cfg, PlcProject project, String metric) =>
    '${cfg.baseTopic}/${_controllerTopicName(project)}/tags/$metric';

String _tagSetFilter(MqttProtocolConfig cfg, PlcProject project) =>
    '${cfg.baseTopic}/${_controllerTopicName(project)}/tags/+/set';

String _nbirthTopic(MqttProtocolConfig cfg, PlcProject project) =>
    '$_sparkplugNamespace/${cfg.groupId}/NBIRTH/${_edgeNode(cfg, project)}';

String _ndeathTopic(MqttProtocolConfig cfg, PlcProject project) =>
    '$_sparkplugNamespace/${cfg.groupId}/NDEATH/${_edgeNode(cfg, project)}';

String _ndataTopic(MqttProtocolConfig cfg, PlcProject project) =>
    '$_sparkplugNamespace/${cfg.groupId}/NDATA/${_edgeNode(cfg, project)}';

String _ncmdTopic(MqttProtocolConfig cfg, PlcProject project) =>
    '$_sparkplugNamespace/${cfg.groupId}/NCMD/${_edgeNode(cfg, project)}';

/// The root tag name of a (possibly dotted/indexed) path — `'A.DN'` -> `'A'`,
/// `'A[0]'` -> `'A'`, `'A'` -> `'A'`. Forcing (`PlcTag.isForced`) only ever
/// applies to a root scalar tag (see tag_resolver.dart's `readPath` doc), so
/// this is all that's needed to look up whether a mapped tag's value is
/// currently forced.
String _rootSegment(String path) {
  final dot = path.indexOf('.');
  final bracket = path.indexOf('[');
  var end = path.length;
  if (dot != -1 && dot < end) {
    end = dot;
  }
  if (bracket != -1 && bracket < end) {
    end = bracket;
  }
  return path.substring(0, end);
}

bool _isForcedPath(PlcProject project, String path) {
  final rootName = _rootSegment(path);
  for (final tag in project.tags) {
    if (tag.name == rootName) {
      return tag.isForced;
    }
  }
  return false;
}

/// Turns a mapped tag's project-model `dataType` into the Sparkplug B
/// datatype constant used on the wire, or null if it's not one of the
/// scalar types `MqttMap` ever maps (`SparkplugDatatype.forTag` would throw
/// on anything else — this wrapper keeps the publisher's Sparkplug paths
/// exception-free by skipping such an entry instead).
int? _sparkplugDatatypeFor(PlcProject project, String tagPath) {
  final dataType = dataTypeOfPath(project, tagPath);
  if (dataType == null) {
    return null;
  }
  try {
    return SparkplugDatatype.forTag(dataType);
  } catch (_) {
    return null;
  }
}

/// Holds per-connection publisher state (Sparkplug alias table, seq/bdSeq,
/// the report-by-exception cache) and turns a project + its
/// `MqttProtocolConfig` into publish descriptors / topic-filter lists /
/// decoded inbound commands. Every method is pure — no sockets, no
/// `DateTime.now()` — see the file-level doc comment for the full session
/// state model.
class MqttPublisher {
  final Map<String, int> _aliasByTag = {};
  final Map<int, String> _tagByAlias = {};
  int _nextAlias = 1;
  final SparkplugSeq _seq = SparkplugSeq();
  final SparkplugBdSeq _bdSeq;
  final Map<String, Object?> _lastPublished = {};

  /// [initialBdSeq] seeds this session's `bdSeq` counter (default 0, so a
  /// bare `MqttPublisher()` behaves exactly as before). The host
  /// (`mqtt_host.dart`) constructs a brand-new [MqttPublisher] on every
  /// (re)connect attempt, so it passes the last `bdSeq` value observed from
  /// the PREVIOUS attempt's publisher here — that is what keeps `bdSeq`
  /// monotonically increasing across reconnects (Sparkplug B's requirement
  /// for distinguishing a stale NDEATH from the current session's) rather
  /// than resetting to 0/1 on every fresh connection.
  MqttPublisher({int initialBdSeq = 0}) : _bdSeq = SparkplugBdSeq(initial: initialBdSeq);

  /// The current `bdSeq` value (unchanged by reading it) — the host reads
  /// this after [willMessage] to remember where to seed the NEXT
  /// connection attempt's [MqttPublisher].
  int get bdSeq => _bdSeq.value;

  int _allocAlias(String tagPath) {
    final existing = _aliasByTag[tagPath];
    if (existing != null) {
      return existing;
    }
    final alias = _nextAlias++;
    _aliasByTag[tagPath] = alias;
    _tagByAlias[alias] = tagPath;
    return alias;
  }

  /// The retained "just connected" publish(es): JSON status "ONLINE", or a
  /// Sparkplug NBIRTH (seq reset to 0, one aliased metric per mapped tag
  /// plus a `bdSeq` metric). Also (re)builds the alias table in the
  /// project's current map order and reseeds the report-by-exception
  /// baseline to every mapped tag's CURRENT value, so the very next
  /// [changedPublishes] call reports nothing until something actually
  /// changes after this birth. Returns an empty list if MQTT isn't
  /// configured for this project.
  List<MqttPublishDescriptor> birthMessages(PlcProject project, int nowMs) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null) {
      return const [];
    }

    final entries = cfg.map.entries;
    _aliasByTag.clear();
    _tagByAlias.clear();
    _nextAlias = 1;
    for (final entry in entries) {
      _lastPublished[entry.tag] = readPath(project, entry.tag);
    }

    if (_isJson(cfg)) {
      return [
        MqttPublishDescriptor(
          topic: _statusTopic(cfg, project),
          payload: Uint8List.fromList(utf8.encode('ONLINE')),
          qos: cfg.qos,
          retain: true,
        ),
      ];
    }

    final metrics = <SparkplugMetric>[];
    for (final entry in entries) {
      final datatype = _sparkplugDatatypeFor(project, entry.tag);
      final value = readPath(project, entry.tag);
      if (datatype == null || value == null) {
        continue;
      }
      metrics.add(SparkplugMetric(
        name: entry.metric,
        alias: _allocAlias(entry.tag),
        datatype: datatype,
        value: value,
      ));
    }
    metrics.add(SparkplugMetric(
      name: 'bdSeq',
      datatype: SparkplugDatatype.uint64,
      value: _bdSeq.value,
    ));

    _seq.reset();
    final payload = SparkplugPayload(timestampMs: nowMs, seq: _seq.next(), metrics: metrics);
    return [
      MqttPublishDescriptor(
        topic: _nbirthTopic(cfg, project),
        payload: encodePayload(payload),
        qos: cfg.qos,
        retain: true,
      ),
    ];
  }

  /// The MQTT Will descriptor the host registers at CONNECT time: JSON
  /// status "OFFLINE" (retained), or a Sparkplug NDEATH carrying a freshly
  /// advanced `bdSeq` (this is the ONE place `_bdSeq` advances — the
  /// subsequent [birthMessages] call reads this same value into its NBIRTH,
  /// pairing the two per Sparkplug B's rebirth-detection convention). Null
  /// if MQTT isn't configured.
  MqttPublishDescriptor? willMessage(PlcProject project) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null) {
      return null;
    }

    if (_isJson(cfg)) {
      return MqttPublishDescriptor(
        topic: _statusTopic(cfg, project),
        payload: Uint8List.fromList(utf8.encode('OFFLINE')),
        qos: cfg.qos,
        retain: true,
      );
    }

    final bdSeq = _bdSeq.next();
    final payload = SparkplugPayload(
      timestampMs: 0, // no nowMs param on this method — see file-level doc.
      seq: 0,
      metrics: [
        SparkplugMetric(name: 'bdSeq', datatype: SparkplugDatatype.uint64, value: bdSeq),
      ],
    );
    return MqttPublishDescriptor(
      topic: _ndeathTopic(cfg, project),
      payload: encodePayload(payload),
      qos: cfg.qos,
      retain: false,
    );
  }

  /// The death certificate to publish on an INTENTIONAL disconnect, using the
  /// CURRENT session `bdSeq` (the one the active NBIRTH used) — it does NOT
  /// advance `_bdSeq` (that is [willMessage]'s job, once per new connection).
  /// A clean MQTT DISCONNECT suppresses the registered Will, so the host would
  /// otherwise never see the node die; the host publishes this explicitly
  /// before disconnecting. Returns null if MQTT isn't configured.
  MqttPublishDescriptor? deathMessage(PlcProject project, int nowMs) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null) {
      return null;
    }
    if (_isJson(cfg)) {
      return MqttPublishDescriptor(
        topic: _statusTopic(cfg, project),
        payload: Uint8List.fromList(utf8.encode('OFFLINE')),
        qos: cfg.qos,
        retain: true,
      );
    }
    final payload = SparkplugPayload(
      timestampMs: nowMs,
      seq: 0,
      metrics: [
        SparkplugMetric(name: 'bdSeq', datatype: SparkplugDatatype.uint64, value: _bdSeq.value),
      ],
    );
    return MqttPublishDescriptor(
      topic: _ndeathTopic(cfg, project),
      payload: encodePayload(payload),
      qos: cfg.qos,
      retain: false,
    );
  }

  /// Report-by-exception telemetry: only tags whose `readPath` value has
  /// changed since the last [birthMessages]/[changedPublishes]/
  /// [heartbeatPublishes] call. JSON emits one publish per changed tag;
  /// Sparkplug batches every changed tag into a single NDATA (alias-only
  /// metrics, seq advanced by one). Returns an empty list when nothing
  /// changed (including when MQTT isn't configured).
  List<MqttPublishDescriptor> changedPublishes(PlcProject project, int nowMs) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null) {
      return const [];
    }

    final changed = <MqttMapEntry>[];
    for (final entry in cfg.map.entries) {
      final value = readPath(project, entry.tag);
      final hadBaseline = _lastPublished.containsKey(entry.tag);
      final lastValue = _lastPublished[entry.tag];
      if (hadBaseline && lastValue == value) {
        continue;
      }
      // Analog deadband gate (event-loop-flood fix): a NUMERIC value that
      // moved by no more than `cfg.deadband` since the last published
      // baseline is suppressed WITHOUT touching the baseline, so a slow
      // drift across many small sub-deadband ticks is still measured from
      // the original baseline rather than resetting on every tick. BOOL/
      // STRING values and `deadband == 0.0` (the default) are never gated —
      // unchanged behavior.
      if (hadBaseline &&
          cfg.deadband > 0 &&
          value is num &&
          lastValue is num &&
          (value - lastValue).abs() <= cfg.deadband) {
        continue;
      }
      _lastPublished[entry.tag] = value;
      changed.add(entry);
    }
    if (changed.isEmpty) {
      return const [];
    }

    if (_isJson(cfg)) {
      return changed.map((e) => _jsonTagDescriptor(cfg, project, e, nowMs)).toList();
    }
    return [_sparkplugDataDescriptor(cfg, project, changed, nowMs)];
  }

  /// Every mapped tag, regardless of whether it changed — the periodic
  /// heartbeat publish. Also updates the report-by-exception baseline for
  /// every tag it publishes. Empty list when MQTT isn't configured or the
  /// map is empty.
  List<MqttPublishDescriptor> heartbeatPublishes(PlcProject project, int nowMs) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null) {
      return const [];
    }
    final entries = cfg.map.entries;
    if (entries.isEmpty) {
      return const [];
    }
    for (final entry in entries) {
      _lastPublished[entry.tag] = readPath(project, entry.tag);
    }

    if (_isJson(cfg)) {
      return entries.map((e) => _jsonTagDescriptor(cfg, project, e, nowMs)).toList();
    }
    return [_sparkplugDataDescriptor(cfg, project, entries, nowMs)];
  }

  MqttPublishDescriptor _jsonTagDescriptor(
    MqttProtocolConfig cfg,
    PlcProject project,
    MqttMapEntry entry,
    int nowMs,
  ) {
    final value = readPath(project, entry.tag);
    final body = jsonEncode({
      'value': value,
      'quality': 'Good',
      'timestamp': nowMs,
      'forced': _isForcedPath(project, entry.tag),
    });
    return MqttPublishDescriptor(
      topic: _tagTopic(cfg, project, entry.metric),
      payload: Uint8List.fromList(utf8.encode(body)),
      qos: cfg.qos,
      retain: false,
    );
  }

  MqttPublishDescriptor _sparkplugDataDescriptor(
    MqttProtocolConfig cfg,
    PlcProject project,
    List<MqttMapEntry> entries,
    int nowMs,
  ) {
    final metrics = <SparkplugMetric>[];
    for (final entry in entries) {
      // Only emit a data metric for a tag that already has an alias from the
      // last NBIRTH. A tag whose `readPath` was null at birth time (so it
      // was skipped there — see `birthMessages`) never got an alias
      // assigned; minting a fresh one here at data-time would send an alias
      // the subscriber never learned during NBIRTH, which Sparkplug B
      // decoders can't resolve back to a name. Such a tag is simply skipped
      // until the next NBIRTH re-establishes the alias table.
      final alias = _aliasByTag[entry.tag];
      if (alias == null) {
        continue;
      }
      final datatype = _sparkplugDatatypeFor(project, entry.tag);
      final value = readPath(project, entry.tag);
      if (datatype == null || value == null) {
        continue;
      }
      metrics.add(SparkplugMetric(
        alias: alias,
        datatype: datatype,
        value: value,
      ));
    }
    final payload = SparkplugPayload(timestampMs: nowMs, seq: _seq.next(), metrics: metrics);
    return MqttPublishDescriptor(
      topic: _ndataTopic(cfg, project),
      payload: encodePayload(payload),
      qos: cfg.qos,
      retain: false,
    );
  }

  /// The subscription(s) the host must make to receive remote-write
  /// commands: the JSON `/set` wildcard filter, or the Sparkplug NCMD topic.
  /// Empty when `allowRemoteWrites` is false or MQTT isn't configured — the
  /// host simply subscribes to nothing, so no command can ever be applied.
  List<String> commandTopicFilters(PlcProject project) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null || !cfg.allowRemoteWrites) {
      return const [];
    }
    return [_isJson(cfg) ? _tagSetFilter(cfg, project) : _ncmdTopic(cfg, project)];
  }

  /// The Sparkplug B NCMD topic the host must subscribe to in order to
  /// receive rebirth requests (see [isRebirthRequest]) — independent of
  /// `allowRemoteWrites` (unlike [commandTopicFilters], which gates ordinary
  /// tag-write commands on that setting). Null for the JSON format (which has
  /// no Sparkplug rebirth concept) or when MQTT isn't configured.
  String? ncmdSubscriptionTopic(PlcProject project) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null || _isJson(cfg)) {
      return null;
    }
    return _ncmdTopic(cfg, project);
  }

  /// True iff `topic`/`payload` is a Sparkplug B NCMD PUBLISH carrying a
  /// `Node Control/Rebirth` metric with a boolean value of `true` — the
  /// standard Sparkplug B convention a subscriber (e.g. Ignition's MQTT
  /// Engine) uses to request a fresh NBIRTH. Always false for the JSON
  /// format, the wrong topic, or a payload without that metric/value. Never
  /// throws (mirrors [decodeCommand]'s exception-free contract).
  bool isRebirthRequest(String topic, Uint8List payload, PlcProject project) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null || _isJson(cfg)) {
      return false;
    }
    if (topic != _ncmdTopic(cfg, project)) {
      return false;
    }
    try {
      final metrics = _decodeSparkplugPayload(payload);
      for (final metric in metrics) {
        if (metric.name == _rebirthMetricName && metric.value == true) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Decodes an inbound PUBLISH (`topic`/`payload`) into zero or more
  /// tag writes. Never throws: any malformed/unexpected input (wrong topic,
  /// garbage payload, unknown tag, non-writable tag, remote writes
  /// disabled) simply yields an empty list.
  List<MqttCommand> decodeCommand(String topic, Uint8List payload, PlcProject project) {
    final cfg = project.protocols?.mqtt;
    if (cfg == null || !cfg.allowRemoteWrites) {
      return const [];
    }
    try {
      return _isJson(cfg)
          ? _decodeJsonCommand(cfg, project, topic, payload)
          : _decodeSparkplugCommand(cfg, project, topic, payload);
    } catch (_) {
      return const [];
    }
  }

  /// Matches `topic` against `{base}/{ctrl}/tags/{metric}/set`, extracting
  /// `metric`; null if `topic` doesn't fit that shape (wrong prefix/suffix,
  /// or an embedded extra `/`).
  String? _jsonSetMetric(MqttProtocolConfig cfg, PlcProject project, String topic) {
    final prefix = '${cfg.baseTopic}/${_controllerTopicName(project)}/tags/';
    const suffix = '/set';
    if (!topic.startsWith(prefix) || !topic.endsWith(suffix)) {
      return null;
    }
    final middle = topic.substring(prefix.length, topic.length - suffix.length);
    if (middle.isEmpty || middle.contains('/')) {
      return null;
    }
    return middle;
  }

  List<MqttCommand> _decodeJsonCommand(
    MqttProtocolConfig cfg,
    PlcProject project,
    String topic,
    Uint8List payload,
  ) {
    final metric = _jsonSetMetric(cfg, project, topic);
    if (metric == null) {
      return const [];
    }
    MqttMapEntry? entry;
    for (final e in cfg.map.entries) {
      if (e.metric == metric) {
        entry = e;
        break;
      }
    }
    // Write-time hard backstop (protocol-hardening workstream, Task 2): the
    // MqttMap entry above is a MUTABLE map that a hand-edit could re-target
    // at the reserved System tag. `isExternallyWritable` re-checks the
    // underlying ROOT tag itself, independent of whatever this entry's own
    // `writable` claims — a hard, non-overridable rule, never a replacement
    // for the per-entry check above. Short-circuiting `||` means
    // `entry.tag` is never touched when `entry` is null.
    if (entry == null || !entry.writable || !isExternallyWritable(project, entry.tag)) {
      return const [];
    }

    // Strict UTF-8: a payload that isn't even valid text can't represent any
    // tag value (raw-scalar or JSON-object), so it's treated as garbage
    // (empty result) rather than smuggled through as a lossy String.
    String raw;
    try {
      raw = utf8.decode(payload).trim();
    } on FormatException {
      return const [];
    }
    if (raw.isEmpty) {
      return const [];
    }

    Object value;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded.containsKey('value') && decoded['value'] != null) {
        value = decoded['value'] as Object;
      } else if (decoded is bool || decoded is num || decoded is String) {
        value = decoded;
      } else {
        value = raw; // decoded to null/List/Map without a usable 'value' — fall back to raw text
      }
    } catch (_) {
      value = raw; // not valid JSON on its own — treat the whole body as a raw scalar string
    }
    return [(tagPath: entry.tag, value: value)];
  }

  List<MqttCommand> _decodeSparkplugCommand(
    MqttProtocolConfig cfg,
    PlcProject project,
    String topic,
    Uint8List payload,
  ) {
    if (topic != _ncmdTopic(cfg, project)) {
      return const [];
    }
    final metrics = _decodeSparkplugPayload(payload);
    final out = <MqttCommand>[];
    for (final metric in metrics) {
      final value = metric.value;
      if (value == null) {
        continue;
      }
      String? tagPath = metric.alias != null ? _tagByAlias[metric.alias] : null;
      if (tagPath == null && metric.name != null) {
        for (final e in cfg.map.entries) {
          if (e.metric == metric.name) {
            tagPath = e.tag;
            break;
          }
        }
      }
      if (tagPath == null) {
        continue;
      }
      MqttMapEntry? entry;
      for (final e in cfg.map.entries) {
        if (e.tag == tagPath) {
          entry = e;
          break;
        }
      }
      // Write-time hard backstop (protocol-hardening workstream, Task 2):
      // see the identical comment in `_decodeJsonCommand` above.
      if (entry == null || !entry.writable || !isExternallyWritable(project, entry.tag)) {
        continue;
      }
      out.add((tagPath: entry.tag, value: value));
    }
    return out;
  }
}

// --- Minimal, production-side Sparkplug B Payload decoder (NCMD only) -----
//
// `mqtt_sparkplug.dart` deliberately only ENCODES (its own decoder is
// test-only, per that file's doc comment) — but this publisher must decode
// INBOUND NCMD payloads to service remote writes, so a small decoder lives
// here instead. It mirrors the wire format documented at the top of
// mqtt_sparkplug.dart (Payload fields 1 timestamp/2 metrics/3 seq; Metric
// fields 1 name/2 alias/4 datatype/10 int_value/11 long_value/13
// double_value/14 boolean_value/15 string_value — the Tahu spec's real
// field numbers, fields 5-9 being reserved for metadata this app never
// emits) but is intentionally bounds-checked at every step and never
// throws — any malformed byte returns null/partial results instead, so
// [MqttPublisher.decodeCommand] can stay exception-free even against a
// garbage/hostile payload.

class _SparkplugMetricIn {
  final String? name;
  final int? alias;
  final Object? value;

  const _SparkplugMetricIn({this.name, this.alias, required this.value});
}

class _Varint {
  final int value;
  final int nextPos;

  const _Varint(this.value, this.nextPos);
}

/// Reads one base-128 varint starting at [pos]; null on truncated/malformed
/// input (missing terminator) rather than throwing or looping forever.
_Varint? _readVarint(Uint8List data, int pos) {
  var result = 0;
  var shift = 1;
  var p = pos;
  for (var i = 0; i < 10; i++) {
    if (p >= data.length) {
      return null;
    }
    final b = data[p];
    result += (b & 0x7F) * shift;
    p += 1;
    if ((b & 0x80) == 0) {
      return _Varint(result, p);
    }
    shift *= 128;
  }
  return null; // 10 continuation bytes without a terminator: malformed
}

/// Skips one protobuf field's value given its [wireType], returning the
/// position after it, or null if malformed/unsupported. This lets the inbound
/// decoder TOLERATE fields it doesn't model — `is_null`, `metadata`,
/// `properties`, quality, `uuid`, `body`, etc. that a full Sparkplug host
/// (e.g. Ignition's MQTT Engine) includes in NCMD metrics/payloads — by
/// stepping over them instead of dropping the metric/payload entirely.
int? _skipField(Uint8List data, int pos, int wireType) {
  switch (wireType) {
    case 0: // varint
      final v = _readVarint(data, pos);
      return v?.nextPos;
    case 1: // 64-bit fixed
      return pos + 8 <= data.length ? pos + 8 : null;
    case 2: // length-delimited
      final len = _readVarint(data, pos);
      if (len == null || len.nextPos + len.value > data.length) {
        return null;
      }
      return len.nextPos + len.value;
    case 5: // 32-bit fixed
      return pos + 4 <= data.length ? pos + 4 : null;
    default: // groups (3/4) — deprecated/unsupported
      return null;
  }
}

int _fromUnsignedWireInt(int datatype, int raw) {
  switch (datatype) {
    case SparkplugDatatype.int8:
      return raw >= 0x80 ? raw - 0x100 : raw;
    case SparkplugDatatype.int16:
      return raw >= 0x8000 ? raw - 0x10000 : raw;
    case SparkplugDatatype.int32:
      return raw >= 0x80000000 ? raw - 0x100000000 : raw;
    default:
      return raw;
  }
}

String? _utf8DecodeSafe(Uint8List bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// Decodes one Metric submessage's bytes; null on any malformed/unrecognized
/// field rather than throwing.
_SparkplugMetricIn? _decodeSparkplugMetric(Uint8List data) {
  String? name;
  int? alias;
  var datatype = -1;
  Object? value;
  var pos = 0;
  while (pos < data.length) {
    final tagV = _readVarint(data, pos);
    if (tagV == null) {
      return null;
    }
    final fieldNumber = tagV.value >> 3;
    pos = tagV.nextPos;
    switch (fieldNumber) {
      case 1: // name
        final len = _readVarint(data, pos);
        if (len == null || len.nextPos + len.value > data.length) {
          return null;
        }
        name = _utf8DecodeSafe(Uint8List.sublistView(data, len.nextPos, len.nextPos + len.value));
        pos = len.nextPos + len.value;
        break;
      case 2: // alias
        final v = _readVarint(data, pos);
        if (v == null) {
          return null;
        }
        alias = v.value;
        pos = v.nextPos;
        break;
      case 3: // per-metric timestamp — not used by this app; skip
        final v = _readVarint(data, pos);
        if (v == null) {
          return null;
        }
        pos = v.nextPos;
        break;
      case 4: // datatype
        final v = _readVarint(data, pos);
        if (v == null) {
          return null;
        }
        datatype = v.value;
        pos = v.nextPos;
        break;
      case 10: // int_value (unsigned-reinterpreted)
        final v = _readVarint(data, pos);
        if (v == null) {
          return null;
        }
        value = _fromUnsignedWireInt(datatype, v.value);
        pos = v.nextPos;
        break;
      case 11: // long_value
        final v = _readVarint(data, pos);
        if (v == null) {
          return null;
        }
        value = v.value;
        pos = v.nextPos;
        break;
      case 13: // double_value (64-bit little-endian)
        if (pos + 8 > data.length) {
          return null;
        }
        value = ByteData.sublistView(data, pos, pos + 8).getFloat64(0, Endian.little);
        pos += 8;
        break;
      case 14: // boolean_value
        final v = _readVarint(data, pos);
        if (v == null) {
          return null;
        }
        value = v.value != 0;
        pos = v.nextPos;
        break;
      case 15: // string_value
        final len = _readVarint(data, pos);
        if (len == null || len.nextPos + len.value > data.length) {
          return null;
        }
        value = _utf8DecodeSafe(Uint8List.sublistView(data, len.nextPos, len.nextPos + len.value));
        pos = len.nextPos + len.value;
        break;
      default:
        // A metric field this app doesn't model (is_null/metadata/properties/
        // quality/...). A real host like Ignition includes these — skip by
        // wire type rather than dropping the whole metric (which would make
        // an inbound NCMD write silently decode to nothing).
        final skipTo = _skipField(data, pos, tagV.value & 0x7);
        if (skipTo == null) {
          return null;
        }
        pos = skipTo;
    }
  }
  return _SparkplugMetricIn(name: name, alias: alias, value: value);
}

/// Decodes a Payload's top-level fields, collecting every metric it can
/// successfully parse. Stops (returning whatever was collected so far)
/// rather than throwing the moment anything doesn't parse.
List<_SparkplugMetricIn> _decodeSparkplugPayload(Uint8List data) {
  final metrics = <_SparkplugMetricIn>[];
  var pos = 0;
  while (pos < data.length) {
    final tagV = _readVarint(data, pos);
    if (tagV == null) {
      return metrics;
    }
    final fieldNumber = tagV.value >> 3;
    pos = tagV.nextPos;
    switch (fieldNumber) {
      case 1: // timestamp
        final v = _readVarint(data, pos);
        if (v == null) {
          return metrics;
        }
        pos = v.nextPos;
        break;
      case 2: // metrics (length-delimited submessage)
        final len = _readVarint(data, pos);
        if (len == null || len.nextPos + len.value > data.length) {
          return metrics;
        }
        final metric =
            _decodeSparkplugMetric(Uint8List.sublistView(data, len.nextPos, len.nextPos + len.value));
        if (metric != null) {
          metrics.add(metric);
        }
        pos = len.nextPos + len.value;
        break;
      case 3: // seq
        final v = _readVarint(data, pos);
        if (v == null) {
          return metrics;
        }
        pos = v.nextPos;
        break;
      default:
        // Unknown top-level Payload field (uuid/body/...) — skip by wire type
        // instead of stopping, so a metric that follows it is still decoded.
        final skipTo = _skipField(data, pos, tagV.value & 0x7);
        if (skipTo == null) {
          return metrics;
        }
        pos = skipTo;
    }
  }
  return metrics;
}
