// OPC UA Browse/Read/Write services over the live tag DB — pure Dart, no
// dart:io / Flutter imports. Implements the Task 2 `OpcUaServiceHandler`
// contract (see opcua_session.dart:104-136). See
// docs/superpowers/plans/2026-07-06-in-app-opcua-server.md, Task 3.
//
// Every encoding id / struct layout / StatusCode / AttributeId used here is
// cross-checked against the Rust `opcua` crate (v0.12.0), vendored locally
// at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// Specific files cited inline next to each constant/decision.
library opcua_services;

import 'dart:typed_data';

import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'opcua_address_space.dart';
import 'opcua_binary.dart';
import 'opcua_session.dart';

/// Service DefaultBinary encoding ids (types/node_ids.rs) — verified exact.
class _Ids {
  static const browseRequest = 527; // node_ids.rs:1697
  static const browseResponse = 530; // node_ids.rs:1698
  static const readRequest = 631; // node_ids.rs:1731
  static const readResponse = 634; // node_ids.rs:1732
  static const writeRequest = 673; // node_ids.rs:1745
  static const writeResponse = 676; // node_ids.rs:1746
}

/// StatusCodes used by this file. Verified one-by-one against
/// types/status_codes.rs.
class OpcUaServiceStatusCodes {
  static const good = 0;
  static const badNothingToDo = 0x800F0000; // status_codes.rs:100
  static const badUserAccessDenied = 0x801F0000; // status_codes.rs:116
  static const badNodeIdUnknown = 0x80340000; // status_codes.rs:132
  static const badAttributeIdInvalid = 0x80350000; // status_codes.rs:133
  static const badIndexRangeInvalid = 0x80360000; // status_codes.rs:134
  static const badNotWritable = 0x803B0000; // status_codes.rs:139
  static const badTypeMismatch = 0x80740000; // status_codes.rs:195
}

/// The Task 3 `OpcUaServiceHandler` implementation: decodes Browse/Read/
/// Write requests, answers them against an `OpcUaAddressSpace` built from
/// the CURRENT project (obtained via [projectProvider] on every call, so
/// hosts can swap the active project — e.g. a project reload — without
/// re-wiring the handler), and always reads/writes tag VALUES live at call
/// time (never a cached snapshot).
///
/// The address space's STRUCTURE (which nodes exist) is rebuilt from
/// `projectProvider()` on every call. This is deliberately simple (no
/// staleness bugs from a cached structure surviving a project swap) and
/// cheap in practice (v1 address spaces are small, flat, exposed-tag-only).
class OpcUaProjectServices implements OpcUaServiceHandler {
  final PlcProject Function() projectProvider;

  OpcUaProjectServices({required this.projectProvider});

  /// Samples the live Value attribute of [nodeId] RIGHT NOW: builds a fresh
  /// `OpcUaAddressSpace` from the CURRENT `projectProvider()` project (same
  /// "always live, never cached" contract as Read/Write) and returns exactly
  /// what a Read of that node's Value attribute (attributeId 13, no
  /// indexRange) would — shares the one `_readAttribute` code path with
  /// `_handleRead` so there is no risk of the two ever drifting apart. Used
  /// by [SubscriptionManager] (Task 3's `sampler` callback) to sample
  /// monitored items on every clock tick.
  OpcDataValue sample(OpcNodeId nodeId) {
    final project = projectProvider();
    final space = OpcUaAddressSpace.build(project);
    return _readAttribute(project, space, nodeId, OpcUaAttributeIds.value, null);
  }

  @override
  Uint8List? handle(
    int requestTypeId,
    OpcUaReader body,
    RequestHeader header,
    ResponseBuilder respond,
  ) {
    try {
      switch (requestTypeId) {
        case _Ids.browseRequest:
          return _handleBrowse(body, respond);
        case _Ids.readRequest:
          return _handleRead(body, respond);
        case _Ids.writeRequest:
          return _handleWrite(body, respond);
        default:
          return null; // unsupported — session emits Bad_ServiceUnsupported.
      }
    } catch (_) {
      // Never throw: any decode failure here is unsupported from the
      // session's point of view (its own catch-all is the true last resort,
      // not the plan — see opcua_session.dart's handler contract doc).
      return null;
    }
  }

  // --- Browse -------------------------------------------------------------

  /// BrowseRequest (browse_request.rs): requestHeader(already consumed by
  /// the session), view ViewDescription{viewId NodeId, timestamp DateTime,
  /// viewVersion UInt32}, requestedMaxReferencesPerNode UInt32,
  /// nodesToBrowse[] BrowseDescription{nodeId, browseDirection Int32 enum,
  /// referenceTypeId NodeId, includeSubtypes bool, nodeClassMask UInt32,
  /// resultMask UInt32}.
  Uint8List _handleBrowse(OpcUaReader body, ResponseBuilder respond) {
    body.nodeId(); // view.viewId — unused (v1 has no Views).
    body.dateTime(); // view.timestamp
    body.uint32(); // view.viewVersion
    body.uint32(); // requestedMaxReferencesPerNode — v1 never truncates.
    final count = body.int32();
    final nodesToBrowse = <({OpcNodeId nodeId, int resultMask})>[];
    if (count > 0) {
      for (var i = 0; i < count; i++) {
        final nodeId = body.nodeId();
        body.int32(); // browseDirection — v1 only ever answers Forward refs.
        body.nodeId(); // referenceTypeId — v1 doesn't filter by it.
        body.boolean(); // includeSubtypes
        body.uint32(); // nodeClassMask
        final resultMask = body.uint32();
        nodesToBrowse.add((nodeId: nodeId, resultMask: resultMask));
      }
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.browseResponse));
    if (nodesToBrowse.isEmpty) {
      w.responseHeader(respond(serviceResult: OpcUaServiceStatusCodes.badNothingToDo));
      w.int32(-1); // results: null array
      w.int32(-1); // diagnosticInfos: null array
      return w.take();
    }

    final project = projectProvider();
    final space = OpcUaAddressSpace.build(project);

    w.responseHeader(respond());
    w.int32(nodesToBrowse.length);
    for (final req in nodesToBrowse) {
      _writeBrowseResult(w, space, req.nodeId);
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  /// BrowseResult (browse_result.rs): statusCode, continuationPoint
  /// ByteString, references[] ReferenceDescription. ReferenceDescription
  /// (reference_description.rs): referenceTypeId NodeId, isForward bool,
  /// nodeId ExpandedNodeId, browseName QualifiedName, displayName
  /// LocalizedText, nodeClass Int32 enum, typeDefinition ExpandedNodeId.
  ///
  /// Task 2 (discovery): a top-down client starts at Root (i=84) and expects
  /// exactly one Organizes reference down to Objects (i=85); Browsing
  /// Objects now ALSO surfaces the standard Server object (i=2253) ahead of
  /// the flat tag list, so the address space looks like a real OPC UA server
  /// rather than "Objects > tags only". Browsing the Server node itself (or
  /// any mapped variable) is Good with zero references — v1 doesn't model
  /// the Server object's own children.
  void _writeBrowseResult(OpcUaWriter w, OpcUaAddressSpace space, OpcNodeId nodeId) {
    final isRoot = space.isRootFolder(nodeId);
    final isObjects = space.isObjectsFolder(nodeId);
    final isServer = space.isServerNode(nodeId);
    final entry = space.byNodeId(nodeId);
    if (!isRoot && !isObjects && !isServer && entry == null) {
      w.statusCode(OpcUaServiceStatusCodes.badNodeIdUnknown);
      w.byteString(null); // continuationPoint
      w.int32(-1); // references: null array
      return;
    }

    w.statusCode(OpcUaServiceStatusCodes.good);
    w.byteString(null); // continuationPoint — v1 never paginates.

    if (isRoot) {
      // Root organizes exactly the Objects folder — the top-down client's
      // entry point into the rest of the address space.
      w.int32(1);
      w.nodeId(OpcUaStandardNodeIds.organizesReferenceType);
      w.boolean(true); // isForward
      w.expandedNodeId(OpcUaStandardNodeIds.objectsFolder);
      w.qualifiedName(const OpcQualifiedName(ns: 0, name: 'Objects'));
      w.localizedText(const OpcLocalizedText(text: 'Objects'));
      w.int32(OpcUaNodeClass.object);
      w.expandedNodeId(OpcUaStandardNodeIds.folderType);
      return;
    }

    if (isObjects) {
      // Browsing Objects lists the standard Server object first, then every
      // exposed variable (v1's flat tag layout).
      final children = space.children(OpcUaStandardNodeIds.objectsFolder);
      w.int32(children.length + 1);
      w.nodeId(OpcUaStandardNodeIds.organizesReferenceType);
      w.boolean(true); // isForward
      w.expandedNodeId(OpcUaStandardNodeIds.serverNode);
      w.qualifiedName(const OpcQualifiedName(ns: 0, name: 'Server'));
      w.localizedText(const OpcLocalizedText(text: 'Server'));
      w.int32(OpcUaNodeClass.object);
      w.expandedNodeId(OpcUaStandardNodeIds.serverType);
      for (final child in children) {
        w.nodeId(OpcUaStandardNodeIds.organizesReferenceType);
        w.boolean(true); // isForward
        w.expandedNodeId(child.nodeId);
        w.qualifiedName(OpcQualifiedName(ns: child.nodeId.namespace, name: child.browseName));
        w.localizedText(OpcLocalizedText(text: child.browseName));
        w.int32(OpcUaNodeClass.variable);
        w.expandedNodeId(OpcUaStandardNodeIds.baseDataVariableType);
      }
      return;
    }

    // Browsing the Server node or a variable node: no further children.
    w.int32(0);
  }

  // --- Read -----------------------------------------------------------------

  /// ReadRequest (read_request.rs): maxAge Double, timestampsToReturn Int32
  /// enum, nodesToRead[] ReadValueId{nodeId, attributeId UInt32, indexRange
  /// String, dataEncoding QualifiedName}.
  Uint8List _handleRead(OpcUaReader body, ResponseBuilder respond) {
    body.float64(); // maxAge — v1 always answers live, ignores staleness hints.
    body.int32(); // timestampsToReturn — v1 always includes serverTimestamp.
    final count = body.int32();
    final toRead = <({OpcNodeId nodeId, int attributeId, String? indexRange})>[];
    if (count > 0) {
      for (var i = 0; i < count; i++) {
        final nodeId = body.nodeId();
        final attributeId = body.uint32();
        final indexRange = body.string();
        body.qualifiedName(); // dataEncoding — v1 only supports the default encoding.
        toRead.add((nodeId: nodeId, attributeId: attributeId, indexRange: indexRange));
      }
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.readResponse));
    if (toRead.isEmpty) {
      w.responseHeader(respond(serviceResult: OpcUaServiceStatusCodes.badNothingToDo));
      w.int32(-1);
      w.int32(-1);
      return w.take();
    }

    final project = projectProvider();
    final space = OpcUaAddressSpace.build(project);

    w.responseHeader(respond());
    w.int32(toRead.length);
    for (final req in toRead) {
      w.dataValue(_readAttribute(project, space, req.nodeId, req.attributeId, req.indexRange));
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  OpcDataValue _readAttribute(
    PlcProject project,
    OpcUaAddressSpace space,
    OpcNodeId nodeId,
    int attributeId,
    String? indexRange,
  ) {
    // Task 2 (discovery): the standard NamespaceArray/Server nodes are
    // special-cased BEFORE the `space.byNodeId` lookup — neither is a mapped
    // tag, so both would otherwise fall through to Bad_NodeIdUnknown.
    if (space.isNamespaceArrayNode(nodeId)) {
      return _readNamespaceArrayAttribute(space, attributeId, indexRange);
    }
    if (space.isServerNode(nodeId)) {
      return _readServerNodeAttribute(attributeId, indexRange);
    }

    final entry = space.byNodeId(nodeId);
    if (entry == null) {
      return const OpcDataValue(status: OpcUaServiceStatusCodes.badNodeIdUnknown);
    }
    if (indexRange != null) {
      // v1 supports no sub-value indexing on any attribute.
      return const OpcDataValue(status: OpcUaServiceStatusCodes.badIndexRangeInvalid);
    }

    final now = DateTime.now().toUtc();
    switch (attributeId) {
      case OpcUaAttributeIds.value:
        final variant = entry.readVariant(project);
        if (variant == null) {
          return const OpcDataValue(status: OpcUaServiceStatusCodes.badAttributeIdInvalid);
        }
        return OpcDataValue(variant: variant, status: OpcUaServiceStatusCodes.good, serverTs: now);
      case OpcUaAttributeIds.nodeClass:
        return OpcDataValue(
          variant: const OpcVariant(typeId: 6, value: OpcUaNodeClass.variable), // Int32
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.browseName:
        return OpcDataValue(
          variant: OpcVariant(
            typeId: 20, // QualifiedName
            value: OpcQualifiedName(ns: entry.nodeId.namespace, name: entry.browseName),
          ),
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.displayName:
        return OpcDataValue(
          variant: OpcVariant(
            typeId: 21, // LocalizedText
            value: OpcLocalizedText(text: entry.browseName),
          ),
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.dataType:
        final mapping = entry.typeMapping;
        if (mapping == null) {
          return const OpcDataValue(status: OpcUaServiceStatusCodes.badAttributeIdInvalid);
        }
        return OpcDataValue(
          variant: OpcVariant(typeId: 17, value: mapping.dataTypeNodeId), // NodeId
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.accessLevel:
      case OpcUaAttributeIds.userAccessLevel:
        return OpcDataValue(
          variant: OpcVariant(typeId: 3, value: entry.accessLevelByte), // Byte
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      default:
        return const OpcDataValue(status: OpcUaServiceStatusCodes.badAttributeIdInvalid);
    }
  }

  /// Answers a Read of `Server_NamespaceArray` (ns=0;i=2255): the ONE
  /// attribute a strict client actually needs from it is `Value` (to resolve
  /// what namespace index 1 means), but the identity attributes
  /// (NodeClass/BrowseName/DisplayName/DataType/AccessLevel) are answered too
  /// so a client that reads them before Value (e.g. to render a browse tree)
  /// doesn't see a bare Bad_NodeIdUnknown gap.
  OpcDataValue _readNamespaceArrayAttribute(
    OpcUaAddressSpace space,
    int attributeId,
    String? indexRange,
  ) {
    if (indexRange != null) {
      return const OpcDataValue(status: OpcUaServiceStatusCodes.badIndexRangeInvalid);
    }
    final now = DateTime.now().toUtc();
    switch (attributeId) {
      case OpcUaAttributeIds.value:
        return OpcDataValue(
          variant: OpcVariant(typeId: 12, isArray: true, value: space.namespaceArray), // String[]
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.nodeClass:
        return OpcDataValue(
          variant: const OpcVariant(typeId: 6, value: OpcUaNodeClass.variable), // Int32
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.browseName:
        return OpcDataValue(
          variant: const OpcVariant(
            typeId: 20, // QualifiedName
            value: OpcQualifiedName(ns: 0, name: 'NamespaceArray'),
          ),
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.displayName:
        return OpcDataValue(
          variant: const OpcVariant(
            typeId: 21, // LocalizedText
            value: OpcLocalizedText(text: 'NamespaceArray'),
          ),
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.dataType:
        return OpcDataValue(
          variant: const OpcVariant(typeId: 17, value: OpcNodeId.numeric(0, 12)), // NodeId -> String
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.accessLevel:
      case OpcUaAttributeIds.userAccessLevel:
        return OpcDataValue(
          variant: const OpcVariant(typeId: 3, value: kAccessLevelCurrentRead), // Byte, read-only
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      default:
        return const OpcDataValue(status: OpcUaServiceStatusCodes.badAttributeIdInvalid);
    }
  }

  /// Answers a Read of the standard `Server` object (ns=0;i=2253): only the
  /// identity attributes are meaningful for an Object node — `Value` is not
  /// applicable (matching the existing default-case behavior for any
  /// non-Value attribute on a Variable), so it falls through to
  /// Bad_AttributeIdInvalid same as everything else this method doesn't
  /// explicitly answer.
  OpcDataValue _readServerNodeAttribute(int attributeId, String? indexRange) {
    if (indexRange != null) {
      return const OpcDataValue(status: OpcUaServiceStatusCodes.badIndexRangeInvalid);
    }
    final now = DateTime.now().toUtc();
    switch (attributeId) {
      case OpcUaAttributeIds.nodeClass:
        return OpcDataValue(
          variant: const OpcVariant(typeId: 6, value: OpcUaNodeClass.object), // Int32
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.browseName:
        return OpcDataValue(
          variant: const OpcVariant(
            typeId: 20, // QualifiedName
            value: OpcQualifiedName(ns: 0, name: 'Server'),
          ),
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      case OpcUaAttributeIds.displayName:
        return OpcDataValue(
          variant: const OpcVariant(
            typeId: 21, // LocalizedText
            value: OpcLocalizedText(text: 'Server'),
          ),
          status: OpcUaServiceStatusCodes.good,
          serverTs: now,
        );
      default:
        return const OpcDataValue(status: OpcUaServiceStatusCodes.badAttributeIdInvalid);
    }
  }

  // --- Write ------------------------------------------------------------

  /// WriteRequest (write_request.rs): nodesToWrite[] WriteValue{nodeId,
  /// attributeId UInt32, indexRange String, value DataValue}.
  Uint8List _handleWrite(OpcUaReader body, ResponseBuilder respond) {
    final count = body.int32();
    final toWrite = <({OpcNodeId nodeId, int attributeId, String? indexRange, OpcDataValue value})>[];
    if (count > 0) {
      for (var i = 0; i < count; i++) {
        final nodeId = body.nodeId();
        final attributeId = body.uint32();
        final indexRange = body.string();
        final value = body.dataValue();
        toWrite.add((nodeId: nodeId, attributeId: attributeId, indexRange: indexRange, value: value));
      }
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.writeResponse));
    if (toWrite.isEmpty) {
      w.responseHeader(respond(serviceResult: OpcUaServiceStatusCodes.badNothingToDo));
      w.int32(-1);
      w.int32(-1);
      return w.take();
    }

    final project = projectProvider();
    final space = OpcUaAddressSpace.build(project);

    w.responseHeader(respond());
    w.int32(toWrite.length);
    for (final req in toWrite) {
      w.statusCode(_writeAttribute(project, space, req.nodeId, req.attributeId, req.indexRange, req.value));
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  int _writeAttribute(
    PlcProject project,
    OpcUaAddressSpace space,
    OpcNodeId nodeId,
    int attributeId,
    String? indexRange,
    OpcDataValue value,
  ) {
    final entry = space.byNodeId(nodeId);
    if (entry == null) {
      return OpcUaServiceStatusCodes.badNodeIdUnknown;
    }
    if (attributeId != OpcUaAttributeIds.value) {
      return OpcUaServiceStatusCodes.badAttributeIdInvalid;
    }
    if (indexRange != null) {
      return OpcUaServiceStatusCodes.badIndexRangeInvalid;
    }
    if (!entry.isWritable) {
      return OpcUaServiceStatusCodes.badNotWritable;
    }
    final variant = value.variant;
    if (variant == null) {
      return OpcUaServiceStatusCodes.badTypeMismatch;
    }
    final coerced = entry.coerceForWrite(variant);
    if (coerced == null) {
      return OpcUaServiceStatusCodes.badTypeMismatch;
    }

    // Force-aware write: if the root tag backing this entry is forced, an
    // external OPC UA client's write is REFUSED with a visible status code
    // (Bad_UserAccessDenied) — this intentionally differs from the engines'
    // silent-skip (`_forceAwareWrite` in fbd_exec.dart/ld_exec.dart/
    // sfc_exec.dart/st_exec.dart/gateway_client.dart), because an external
    // client needs to SEE that its write had no effect rather than get a
    // deceptive Good with a silently-discarded value. Per the brief: "the
    // client must SEE the refusal."
    final rootTag = _findRootTag(project, entry.tagName);
    if (rootTag != null && rootTag.isForced && rootTag.name == entry.tagName) {
      return OpcUaServiceStatusCodes.badUserAccessDenied;
    }

    writePath(project, entry.tagName, coerced);
    return OpcUaServiceStatusCodes.good;
  }

  PlcTag? _findRootTag(PlcProject project, String tagName) {
    for (final t in project.tags) {
      if (t.name == tagName) return t;
    }
    return null;
  }
}
