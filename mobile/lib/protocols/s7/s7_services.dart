// S7comm Read Var / Write Var request dispatch — pure Dart, no dart:io and no
// Flutter imports.
//
// *** WHY THIS FILE EXISTS SEPARATELY FROM services/s7_host.dart ***
// The S7comm E2E machine-proof (`tool/s7_e2e.sh`) drives a REAL third-party
// client (`python-snap7`) against the Dart FIXTURE host
// (`mobile/tool/s7_host_probe.dart`), not against `services/s7_host.dart` —
// the shipped host extends `ChangeNotifier` and therefore cannot run under a
// plain `dart run`. That only proves the shipped host if the two agree on
// every byte they put on the wire. Rather than keep two hand-written copies
// in sync and verify them by diff, ALL request->response byte production for
// Read Var and Write Var lives here, in one pure function both call. Fidelity
// is then true by construction. This mirrors `dispatchCipService` in
// `protocols/enip/cip_tags.dart`, which the EtherNet/IP host and its fixture
// share for exactly the same reason.
//
// *** ENDIANNESS WARNING ***
// S7comm is BIG-ENDIAN throughout. Everything encoded here goes through
// `s7_pdu.dart`/`s7_area_image.dart`, which are big-endian; the EtherNet/IP
// codec next door is little-endian everywhere — do not pattern-match it.
//
// *** THE TWO TRANSPORT-SIZE FAMILIES COLLIDE NUMERICALLY ***
// A parsed `S7Item.transportSize` is an ITEM-SPECIFICATION size
// (`kS7TransportSize*`: BIT=0x01, WORD=0x04, ...). A data item carries a
// DATA-ITEM size (`kS7DataTransport*`: BIT=0x03, BYTE/WORD=0x04, ...). The
// two schemes share numeric values by accident, so passing the request's
// transport size straight into `buildDataItem` is silently right for 0x04 and
// silently WRONG for BIT. Every crossing in this file goes through
// `dataTransportForItemTransport`.
//
// Safety contract: nothing here throws. A malformed parameter block yields
// `null` (the caller drops the message); a bad individual ITEM yields a
// per-item error return code so the other items in the same request still
// return their data.
library s7_services;

import 'dart:typed_data';

import '../../models/project_model.dart';
import '../../models/s7_map.dart';
import 's7_area_image.dart';
import 's7_pdu.dart';

/// Bytes of a response PDU that are not item data: the 12-byte Ack_Data
/// header plus the 2-byte Read Var response parameter. Used to bound the
/// total size of a Read Var response against the negotiated PDU length, so a
/// client asking for more than it agreed to receive gets a per-item error
/// instead of an oversized frame.
const int kS7ResponseOverheadBytes = kS7HeaderLenAckData + 2;

/// The greatest number of DATA bytes a single Read Var response may carry,
/// given the PDU length agreed during Setup Communication. Never negative.
int s7MaxResponseDataBytes(int negotiatedPduLength) {
  final budget = negotiatedPduLength - kS7ResponseOverheadBytes;
  return budget > 0 ? budget : 0;
}

/// The number of BYTES a Read/Write Var [item] addresses, or 0 if its
/// transport size is not one this device serves. A BIT item always addresses
/// exactly one byte (it reads or writes one bit inside it); every other
/// transport size addresses `count * elementWidth` bytes.
int s7ItemByteLength(S7Item item) {
  if (item.transportSize == kS7TransportSizeBit) {
    return 1;
  }
  final width = s7ItemElementBytes(item.transportSize);
  if (width == 0) {
    return 0;
  }
  final len = item.count * width;
  return len > 0 ? len : 0;
}

/// Builds the DATA-section item that answers one Read Var [item], reading
/// through [readAreaImage] so gap semantics (unmapped bytes read `0x00`) are
/// the byte image's single definition and are never re-implemented here.
///
/// [budgetBytes] is how many data bytes are still available in the response;
/// an item that cannot fit is answered with [kS7ReturnAddressOutOfRange] and
/// a NULL transport rather than a truncated payload.
///
/// *** THE BUDGET IS CHARGED THE ITEM'S FULL ON-WIRE COST, NOT ITS PAYLOAD ***
/// A data item is bigger than the bytes it carries: [buildDataItem] prepends a
/// [kS7DataItemHeaderLen]-byte header and appends a pad byte when the payload
/// length is odd. Comparing the PAYLOAD against the remaining budget — the
/// natural mistake, since that is the number this function goes on to read —
/// admits a read whose finished message overruns the PDU length the device
/// agreed to during Setup Communication, by up to 5 bytes per item. A strict
/// driver enforcing the negotiated size drops such a frame, so the read fails
/// silently on exactly the large-block-read pattern this protocol serves. See
/// `test/s7_services_test.dart`, which pins the boundary from both sides.
Uint8List _readItemData(
  PlcProject project,
  S7Map map,
  S7Item item,
  int budgetBytes,
) {
  Uint8List errorItem(int returnCode) {
    return buildDataItem(
      returnCode: returnCode,
      transportSize: kS7DataTransportNull,
      data: Uint8List(0),
    );
  }

  final areaName = s7AreaNameForCode(item.area);
  if (areaName == null) {
    // A memory area this version does not serve (timers/counters, or an area
    // code that is not an area at all).
    return errorItem(kS7ReturnObjectDoesNotExist);
  }
  final byteLength = s7ItemByteLength(item);
  if (byteLength <= 0) {
    return errorItem(kS7ReturnObjectDoesNotExist);
  }
  final itemCost = byteLength + kS7DataItemHeaderLen + (byteLength.isOdd ? 1 : 0);
  if (itemCost > budgetBytes) {
    return errorItem(kS7ReturnAddressOutOfRange);
  }

  final image = readAreaImage(
    project,
    map,
    areaName,
    item.dbNumber,
    item.byteOffset,
    byteLength,
  );
  if (image.length != byteLength) {
    // `readAreaImage` returns an empty list for a nonsensical window.
    return errorItem(kS7ReturnAddressOutOfRange);
  }

  if (item.transportSize == kS7TransportSizeBit) {
    // ONE bit, delivered as one byte holding 0x00 or 0x01 — NOT the raw
    // memory byte, whose other bits belong to other tags. The declared length
    // is `1 byte * 8` (see `buildDataItem`, and the real-client evidence in
    // its doc comment). The crossing below MUST go through
    // `dataTransportForItemTransport` (item BIT 0x01 -> data BIT 0x03) rather
    // than reuse the item-spec value 0x01.
    final bit = (image[0] & (1 << item.bitOffset)) != 0;
    return buildDataItem(
      returnCode: kS7ReturnSuccess,
      transportSize: dataTransportForItemTransport(item.transportSize),
      data: Uint8List.fromList([bit ? 0x01 : 0x00]),
    );
  }

  return buildDataItem(
    returnCode: kS7ReturnSuccess,
    transportSize: dataTransportForItemTransport(item.transportSize),
    data: image,
  );
}

/// Builds the complete Read Var Ack_Data reply for [request], or `null` if
/// its parameter block is malformed (the caller drops such a message rather
/// than answering it).
///
/// Every item is answered independently and in request order: a bad item
/// returns its own error code while the good items in the same request still
/// return their data.
Uint8List? buildReadVarResponse(
  PlcProject project,
  S7Map map,
  S7Message request, {
  required int negotiatedPduLength,
}) {
  final varParam = parseVarParameter(request.parameter);
  if (varParam == null) {
    return null;
  }
  final maxData = s7MaxResponseDataBytes(negotiatedPduLength);
  final items = varParam.items;
  final chunks = <Uint8List>[];
  var used = 0;
  for (var i = 0; i < items.length; i++) {
    // Every item still to be answered after this one occupies at least a
    // [kS7DataItemHeaderLen]-byte NULL error item — the reply's item count
    // must match the request's, so no item can simply be dropped. Reserving
    // that minimum here is what stops a big item early in the list from
    // eating the room its successors' headers need, which would push the
    // finished message past the negotiated PDU even though every individual
    // admission looked affordable.
    final reserved = (items.length - i - 1) * kS7DataItemHeaderLen;
    final budget = maxData - used - reserved;
    final chunk = _readItemData(project, map, items[i], budget > 0 ? budget : 0);
    used += chunk.length;
    chunks.add(chunk);
  }

  final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
  final data = Uint8List(total);
  var offset = 0;
  for (final chunk in chunks) {
    data.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }

  return buildS7(
    rosctr: kS7RosctrAckData,
    pduReference: request.header.pduReference,
    parameter: buildVarParameter(
      function: kS7FunctionReadVar,
      itemCount: varParam.items.length,
    ),
    data: data,
  );
}

/// Maps the outcomes [applyAreaWrite] reported for ONE Write Var item to that
/// item's single return code.
///
/// An EMPTY [results] list means the range covered no map entry at all — a
/// write into a gap, which is DISCARDED silently by design (see
/// `s7_area_image.dart`) and reported as success, exactly as a real
/// controller reports a write into an unused byte of a data block.
///
/// A refusal wins over everything else so a client is never told a write it
/// was denied succeeded: a `ReadOnly` entry, a FORCED root tag, or the
/// write-time hard backstop (a mismatched map entry against the reserved
/// System tag or a tag whose own `access` is `ReadOnly`) all yield
/// [kS7ReturnAccessDenied]. A partially covered multi-byte tag (writing a
/// fragment would corrupt it) yields [kS7ReturnAddressOutOfRange], and a tag
/// with no v1 S7 representation yields [kS7ReturnObjectDoesNotExist].
int s7WriteReturnCode(List<S7WriteResult> results) {
  var code = kS7ReturnSuccess;
  for (final r in results) {
    switch (r.status) {
      case S7WriteStatus.written:
        break;
      case S7WriteStatus.refusedReadOnly:
      case S7WriteStatus.refusedForced:
      case S7WriteStatus.refusedNotExternallyWritable:
        return kS7ReturnAccessDenied;
      case S7WriteStatus.partiallyCovered:
        code = kS7ReturnAddressOutOfRange;
        break;
      case S7WriteStatus.unsupported:
        if (code == kS7ReturnSuccess) {
          code = kS7ReturnObjectDoesNotExist;
        }
        break;
    }
  }
  return code;
}

/// True if [entry] is the map entry a BIT item addresses: same area, same
/// data block (where that discriminates), same byte AND same bit.
bool _entryIsAtBit(S7MapEntry entry, String area, int dbNumber, S7Item item) {
  if (entry.area != area) {
    return false;
  }
  if (area == kS7AreaNameDb && entry.dbNumber != dbNumber) {
    return false;
  }
  return entry.byteOffset == item.byteOffset && entry.bitOffset == item.bitOffset;
}

/// Applies one Write Var item and returns its return code.
int _writeItem(
  PlcProject project,
  S7Map map,
  S7Item item,
  Uint8List payload,
) {
  final areaName = s7AreaNameForCode(item.area);
  if (areaName == null) {
    return kS7ReturnObjectDoesNotExist;
  }
  final byteLength = s7ItemByteLength(item);
  if (byteLength <= 0) {
    return kS7ReturnObjectDoesNotExist;
  }
  if (payload.length < byteLength) {
    return kS7ReturnAddressOutOfRange;
  }

  if (item.transportSize == kS7TransportSizeBit) {
    // A BIT write must not disturb the other tags sharing the byte. Instead
    // of a read-modify-write of the whole byte — which would re-write up to
    // seven neighbouring BOOLs and make their refusals indistinguishable
    // from this item's own — the write is applied through a map narrowed to
    // the entries at exactly this bit. Neighbouring bits are then untouched
    // by construction, and the returned results describe ONLY the addressed
    // tag. A bit position with no entry yields an empty result list, i.e.
    // the gap-write-is-discarded rule, which is correct here too.
    final narrowed = S7Map(
      entries: map.entries.where((e) => _entryIsAtBit(e, areaName, item.dbNumber, item)).toList(),
    );
    // snap7 and real S7 clients carry a single bit as one byte valued 0x00 or
    // 0x01; the byte image decodes BOOLs by bit position, so the value is
    // re-seated into this item's own bit before being applied.
    final bitSet = payload[0] != 0;
    final memoryByte = Uint8List.fromList([bitSet ? (1 << item.bitOffset) : 0x00]);
    final results = applyAreaWrite(
      project,
      narrowed,
      areaName,
      item.dbNumber,
      item.byteOffset,
      memoryByte,
    );
    return s7WriteReturnCode(results);
  }

  final slice = Uint8List.fromList(payload.sublist(0, byteLength));
  final results = applyAreaWrite(
    project,
    map,
    areaName,
    item.dbNumber,
    item.byteOffset,
    slice,
  );
  return s7WriteReturnCode(results);
}

/// Builds the complete Write Var Ack_Data reply for [request], or `null` if
/// its parameter block or data section is malformed.
///
/// The reply's data section carries exactly one return-code byte per item, in
/// request order, so one refused item never fails the others.
Uint8List? buildWriteVarResponse(
  PlcProject project,
  S7Map map,
  S7Message request,
) {
  final varParam = parseVarParameter(request.parameter);
  if (varParam == null) {
    return null;
  }
  final payloads = parseWriteDataItems(request.data, varParam.items.length);
  if (payloads == null) {
    return null;
  }

  final codes = <int>[];
  for (var i = 0; i < varParam.items.length; i++) {
    codes.add(_writeItem(project, map, varParam.items[i], payloads[i]));
  }

  return buildS7(
    rosctr: kS7RosctrAckData,
    pduReference: request.header.pduReference,
    parameter: buildVarParameter(
      function: kS7FunctionWriteVar,
      itemCount: varParam.items.length,
    ),
    data: buildWriteResponseData(codes),
  );
}

/// Dispatches a Read Var or Write Var Job [request] against [project]'s tags
/// as exposed by [map], returning the complete S7 reply message bytes — or
/// `null` when the message is not one of those two functions, or is
/// malformed, in which case the caller drops it without replying.
///
/// This is the ONE definition of S7comm read/write behaviour: both
/// `services/s7_host.dart` and the E2E fixture host
/// `mobile/tool/s7_host_probe.dart` call it, so the bytes the real
/// third-party client validates are the same bytes the shipped app emits.
Uint8List? dispatchS7VarJob(
  PlcProject project,
  S7Map map,
  S7Message request, {
  required int negotiatedPduLength,
}) {
  if (request.header.rosctr != kS7RosctrJob) {
    return null;
  }
  if (request.parameter.isEmpty) {
    return null;
  }
  switch (request.parameter[0]) {
    case kS7FunctionReadVar:
      return buildReadVarResponse(
        project,
        map,
        request,
        negotiatedPduLength: negotiatedPduLength,
      );
    case kS7FunctionWriteVar:
      return buildWriteVarResponse(project, map, request);
    default:
      return null;
  }
}
