// Pure Dart tag-sync wire protocol: message types + JSON codec.
//
// This is the sole contract for the app <-> gateway WebSocket connection
// (see docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md,
// "The tag-sync layer"). No Flutter, no sockets — just encode/decode.
//
// The codec is total: decodeMessage never throws. Any malformed or
// unrecognized input decodes to an UnknownMsg carrying the raw string.

import 'dart:convert';

/// Base class for every sync message. A tagged (discriminated) hierarchy —
/// each subtype knows its own `"type"` wire discriminator.
abstract class SyncMessage {
  const SyncMessage();

  /// The wire discriminator written to the `"type"` field.
  String get wireType;

  /// Fields beyond `"type"` to merge into the encoded JSON object.
  Map<String, dynamic> encodeFields();
}

class HelloMsg extends SyncMessage {
  final String project;
  final String controller;
  final int scanMs;

  const HelloMsg({required this.project, required this.controller, required this.scanMs});

  @override
  String get wireType => 'hello';

  @override
  Map<String, dynamic> encodeFields() => {
        'project': project,
        'controller': controller,
        'scanMs': scanMs,
      };

  @override
  bool operator ==(Object other) =>
      other is HelloMsg &&
      other.project == project &&
      other.controller == controller &&
      other.scanMs == scanMs;

  @override
  int get hashCode => Object.hash(project, controller, scanMs);
}

class ExposedTag {
  final String path;
  final String dataType;
  final dynamic value;
  final String access;

  const ExposedTag({
    required this.path,
    required this.dataType,
    required this.value,
    required this.access,
  });

  factory ExposedTag.fromJson(Map<String, dynamic> json) => ExposedTag(
        path: json['path']?.toString() ?? '',
        dataType: json['dataType']?.toString() ?? 'BOOL',
        value: json['value'],
        access: json['access']?.toString() ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'dataType': dataType,
        'value': value,
        'access': access,
      };

  @override
  bool operator ==(Object other) =>
      other is ExposedTag &&
      other.path == path &&
      other.dataType == dataType &&
      other.value == value &&
      other.access == access;

  @override
  int get hashCode => Object.hash(path, dataType, value, access);
}

class SnapshotMsg extends SyncMessage {
  final List<ExposedTag> tags;

  const SnapshotMsg({required this.tags});

  @override
  String get wireType => 'snapshot';

  @override
  Map<String, dynamic> encodeFields() => {
        'tags': tags.map((t) => t.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) {
    if (other is! SnapshotMsg || other.tags.length != tags.length) {
      return false;
    }
    for (var i = 0; i < tags.length; i++) {
      if (other.tags[i] != tags[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(tags);
}

class TagChange {
  final String path;
  final dynamic value;

  const TagChange({required this.path, required this.value});

  factory TagChange.fromJson(Map<String, dynamic> json) => TagChange(
        path: json['path']?.toString() ?? '',
        value: json['value'],
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'value': value,
      };

  @override
  bool operator ==(Object other) =>
      other is TagChange && other.path == path && other.value == value;

  @override
  int get hashCode => Object.hash(path, value);
}

class DeltaMsg extends SyncMessage {
  final List<TagChange> changes;

  const DeltaMsg({required this.changes});

  @override
  String get wireType => 'delta';

  @override
  Map<String, dynamic> encodeFields() => {
        'changes': changes.map((c) => c.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) {
    if (other is! DeltaMsg || other.changes.length != changes.length) {
      return false;
    }
    for (var i = 0; i < changes.length; i++) {
      if (other.changes[i] != changes[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(changes);
}

class WriteMsg extends SyncMessage {
  final String path;
  final dynamic value;

  const WriteMsg({required this.path, required this.value});

  @override
  String get wireType => 'write';

  @override
  Map<String, dynamic> encodeFields() => {
        'path': path,
        'value': value,
      };

  @override
  bool operator ==(Object other) =>
      other is WriteMsg && other.path == path && other.value == value;

  @override
  int get hashCode => Object.hash(path, value);
}

class ReadyMsg extends SyncMessage {
  const ReadyMsg();

  @override
  String get wireType => 'ready';

  @override
  Map<String, dynamic> encodeFields() => const {};

  @override
  bool operator ==(Object other) => other is ReadyMsg;

  @override
  int get hashCode => wireType.hashCode;
}

class PingMsg extends SyncMessage {
  const PingMsg();

  @override
  String get wireType => 'ping';

  @override
  Map<String, dynamic> encodeFields() => const {};

  @override
  bool operator ==(Object other) => other is PingMsg;

  @override
  int get hashCode => wireType.hashCode;
}

class PongMsg extends SyncMessage {
  const PongMsg();

  @override
  String get wireType => 'pong';

  @override
  Map<String, dynamic> encodeFields() => const {};

  @override
  bool operator ==(Object other) => other is PongMsg;

  @override
  int get hashCode => wireType.hashCode;
}

/// Returned by [decodeMessage] whenever the input cannot be parsed into a
/// known message: not valid JSON, not a JSON object, missing/unknown
/// `"type"`. Carries the original raw string for logging/debugging.
class UnknownMsg extends SyncMessage {
  final String raw;

  const UnknownMsg(this.raw);

  @override
  String get wireType => 'unknown';

  @override
  Map<String, dynamic> encodeFields() => {'raw': raw};

  @override
  bool operator ==(Object other) => other is UnknownMsg && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

/// Encodes a [SyncMessage] as a JSON object string with a `"type"`
/// discriminator plus that message's own fields.
String encodeMessage(SyncMessage m) {
  final map = <String, dynamic>{'type': m.wireType, ...m.encodeFields()};
  return jsonEncode(map);
}

/// Decodes a wire string into a [SyncMessage]. Never throws: any parse
/// failure or unrecognized `"type"` yields an [UnknownMsg] wrapping [s].
SyncMessage decodeMessage(String s) {
  try {
    final decoded = jsonDecode(s);
    if (decoded is! Map<String, dynamic>) {
      return UnknownMsg(s);
    }
    final type = decoded['type'];
    switch (type) {
      case 'hello':
        return HelloMsg(
          project: decoded['project']?.toString() ?? '',
          controller: decoded['controller']?.toString() ?? '',
          scanMs: (decoded['scanMs'] as num?)?.toInt() ?? 0,
        );
      case 'snapshot':
        final rawTags = decoded['tags'];
        final tags = (rawTags is List)
            ? rawTags
                .whereType<Map>()
                .map((t) => ExposedTag.fromJson(Map<String, dynamic>.from(t)))
                .toList()
            : <ExposedTag>[];
        return SnapshotMsg(tags: tags);
      case 'delta':
        final rawChanges = decoded['changes'];
        final changes = (rawChanges is List)
            ? rawChanges
                .whereType<Map>()
                .map((c) => TagChange.fromJson(Map<String, dynamic>.from(c)))
                .toList()
            : <TagChange>[];
        return DeltaMsg(changes: changes);
      case 'write':
        return WriteMsg(
          path: decoded['path']?.toString() ?? '',
          value: decoded['value'],
        );
      case 'ready':
        return const ReadyMsg();
      case 'ping':
        return const PingMsg();
      case 'pong':
        return const PongMsg();
      default:
        return UnknownMsg(s);
    }
  } catch (_) {
    return UnknownMsg(s);
  }
}

/// Converts a tag's runtime [value] to a JSON-safe scalar per IEC [dataType].
/// Total: never throws, falls back to a sensible default on mismatch.
dynamic tagValueToJson(dynamic value, String dataType) {
  switch (dataType) {
    case 'BOOL':
      if (value is bool) {
        return value;
      }
      return value == true;
    case 'INT16':
    case 'INT32':
    case 'INT64':
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      return 0;
    case 'FLOAT32':
    case 'FLOAT64':
      if (value is double) {
        return value;
      }
      if (value is num) {
        return value.toDouble();
      }
      return 0.0;
    case 'STRING':
      if (value is String) {
        return value;
      }
      return value?.toString() ?? '';
    default:
      // Unknown/struct/array dataType: pass the value through as-is.
      return value;
  }
}

/// Converts a decoded JSON scalar back to a tag runtime value per IEC
/// [dataType]. Total: never throws, falls back to a sensible default on
/// mismatch.
dynamic jsonToTagValue(dynamic json, String dataType) {
  switch (dataType) {
    case 'BOOL':
      if (json is bool) {
        return json;
      }
      return json == true;
    case 'INT16':
    case 'INT32':
    case 'INT64':
      if (json is int) {
        return json;
      }
      if (json is num) {
        return json.toInt();
      }
      return 0;
    case 'FLOAT32':
    case 'FLOAT64':
      if (json is double) {
        return json;
      }
      if (json is num) {
        return json.toDouble();
      }
      return 0.0;
    case 'STRING':
      if (json is String) {
        return json;
      }
      return json?.toString() ?? '';
    default:
      return json;
  }
}
