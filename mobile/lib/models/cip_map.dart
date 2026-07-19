// Pure Dart CIP (symbolic tag) exposure map model.
//
// Mirrors models/opcua_map.dart's node<->tag map shape but for CIP explicit
// messaging (EtherNet/IP + CIP workstream, Task 4): each entry binds a
// project tag — or one scalar leaf of a composite/array tag, keyed by its
// dotted/indexed resolver path, exactly like OpcuaMap's leaf keying — to
// symbolic/named tag addressing, with an `access` mode deciding whether an
// external client's Write Tag (0x4D) is honored.
//
// **v1 SKIPS `STRING` tags during auto-population.** A symbolic (named)
// string tag of the kind this addressing style implies is not a scalar wire
// value: it is a structured type (a length field plus a character array)
// that requires the CIP Template Object to describe its layout to a client
// before the client can decode it. Implementing the Template Object is
// explicitly out of scope for this version and deferred to v2 — omitting
// STRING leaves here is a deliberate scope boundary documented at the
// source, not an oversight. See `protocols/enip/cip.dart`'s
// `cipTypeForTagType`, which likewise returns `null` for `STRING`.
//
// No Flutter dependency — pure Dart, no dart:io — so this file can be used
// from services and widgets alike without pulling Flutter into model code.

import 'project_model.dart';
import 'system_tags.dart';
import 'tag_resolver.dart';

/// One CIP tag-map entry: a project tag's (possibly dotted/indexed) resolver
/// path, exposed under that same name for symbolic/named tag addressing,
/// plus whether external Write Tag requests against it are honored.
///
/// `access` is either `'ReadOnly'` or `'ReadWrite'`.
class CipMapEntry {
  String tagName;
  String access;

  CipMapEntry({
    required this.tagName,
    this.access = 'ReadWrite',
  });

  factory CipMapEntry.fromJson(Map<String, dynamic> json) => CipMapEntry(
        tagName: json['tag_name']?.toString() ?? '',
        access: json['access']?.toString() ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'tag_name': tagName,
        'access': access,
      };
}

/// The editable CIP tag-exposure map for a project: which tags are visible
/// to symbolic/named-tag explicit messaging, and whether each accepts
/// writes.
class CipMap {
  List<CipMapEntry> entries;

  CipMap({List<CipMapEntry>? entries}) : entries = entries ?? [];

  /// Additive persistence: a project JSON with no `cip` protocol key at all
  /// never reaches this constructor (see `CipProtocolConfig` in a later
  /// task); a `map` key that's present but malformed/empty still loads
  /// cleanly here as an empty map rather than throwing.
  factory CipMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return CipMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => CipMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <CipMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Builds a default map from a project's scalar leaf tags (`scalarLeaves`):
  /// composite/array tags are expanded into one entry per scalar leaf, keyed
  /// by its dotted/indexed path (e.g. `System.Fault`, `Tank.Level`,
  /// `Arr[0]`) — a bare scalar tag yields itself, unchanged. **`STRING`
  /// leaves are SKIPPED** (see file header) — this is the one place this
  /// auto-population differs from `OpcuaMap.autoGenerate`.
  ///
  /// Access is inherited from the ROOT tag (the tag whose name is the
  /// leaf path's first segment): `SimulatedOutput`, an explicit `ReadOnly`
  /// tag `access`, or the reserved `System` tag (checked by name, not just
  /// its `access` field, so this holds even if `System`'s own `access`
  /// were ever left at its default) all yield `ReadOnly`; everything else
  /// (`SimulatedInput`, `Internal`) is `ReadWrite`.
  static CipMap autoPopulate(PlcProject p) {
    final entries = <CipMapEntry>[];
    for (final leaf in scalarLeaves(p)) {
      if (leaf.dataType == 'STRING') {
        continue;
      }
      final root = rootTagOf(p, leaf.path);
      final readOnly = root?.ioType == 'SimulatedOutput' ||
          root?.access == 'ReadOnly' ||
          root?.name == kSystemTagName;
      entries.add(CipMapEntry(
        tagName: leaf.path,
        access: readOnly ? 'ReadOnly' : 'ReadWrite',
      ));
    }
    return CipMap(entries: entries);
  }
}
