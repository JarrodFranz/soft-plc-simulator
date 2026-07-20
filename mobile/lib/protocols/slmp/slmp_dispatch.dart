// Mitsubishi SLMP (MELSEC Communication) request -> response dispatch — pure
// Dart, no dart:io / Flutter imports. This is the SINGLE definition of SLMP
// command handling that BOTH the shipped TCP host (`services/slmp_host.dart`)
// and the E2E fixture host (`mobile/tool/slmp_host_probe.dart`) call, exactly
// as the S7comm stack shares `dispatchS7VarJob` and the FINS stack shares
// `dispatchFinsDatagram`. Because the fixture host cannot import the shipped
// host (it extends `ChangeNotifier`, which pulls in `dart:ui`, unavailable
// under a plain `dart run`), sharing ONE dispatch is what makes the real
// third-party `pymcprotocol` client's proof against the fixture also a proof
// of the shipped host — the bytes the client validates are, by construction
// rather than by diff, the bytes the app puts on the wire.
//
// *** ENDIANNESS ***
// SLMP 3E binary word data is LITTLE-ENDIAN (see slmp_frame.dart /
// slmp_commands.dart; the one big-endian field is the frame subheader, handled
// in slmp_frame.dart). This file builds the read-response word data
// little-endian via [SlmpWordImage].
//
// *** SCOPE (Task 3) ***
// Serves a Batch Read (word units, command 0x0401 / subcommand 0x0000) and a
// Batch Write (word units, command 0x1401 / subcommand 0x0000) against a
// [SlmpDeviceImage]. At this task the only concrete image is [SlmpWordImage],
// a simple seeded per-device word bank used by BOTH the shipped host's fixture
// and the E2E fixture host; Task 4 slots a tag-backed [SlmpDeviceImage] (a
// `SlmpMap` over the project's tags) into the SAME seam, so the real client's
// round-trip then exercises the actual tag encode/decode. A command this file
// does not serve (or a bit-units subcommand, deferred to a later task) returns
// `null`, and the host drops the frame without replying.
//
// Safety contract: [dispatchSlmpFrame] returns `null` — and never throws — on
// malformed, truncated, unsupported, or otherwise hostile input, since the TCP
// host feeds it arbitrary reassembled frame bytes read straight off the wire
// and must never wedge its bind on one bad frame.
library slmp_dispatch;

import 'dart:typed_data';

import 'slmp_commands.dart';
import 'slmp_frame.dart';

/// The outcome of one [SlmpDeviceImage.readWords] call: an SLMP end code plus,
/// on [kSlmpEndNormal], the requested words as LITTLE-ENDIAN bytes
/// (`count * 2` long). On any error end code [words] is empty — the response
/// then carries the end code and no data, per the SLMP wire format.
class SlmpReadOutcome {
  final int endCode;
  final Uint8List words;

  const SlmpReadOutcome(this.endCode, this.words);

  /// A successful read carrying [words] (LITTLE-ENDIAN, `count * 2` bytes).
  factory SlmpReadOutcome.ok(Uint8List words) =>
      SlmpReadOutcome(kSlmpEndNormal, words);

  /// A failed read carrying only [endCode] (e.g. [kSlmpEndAddressRange] or
  /// [kSlmpEndCommandError]) and no data.
  factory SlmpReadOutcome.error(int endCode) =>
      SlmpReadOutcome(endCode, Uint8List(0));
}

/// The outcome of one [SlmpDeviceImage.writeWords] call: an SLMP end code.
/// [kSlmpEndNormal] means the write landed (or fell entirely into an unmapped
/// gap, which a later task's tag-backed image discards-as-success); any other
/// code means the write was refused or out of range and device state was left
/// unchanged.
class SlmpWriteOutcome {
  final int endCode;

  const SlmpWriteOutcome(this.endCode);

  /// A successful (or discarded-gap) write.
  factory SlmpWriteOutcome.ok() => const SlmpWriteOutcome(kSlmpEndNormal);

  /// A failed write carrying only [endCode].
  factory SlmpWriteOutcome.error(int endCode) => SlmpWriteOutcome(endCode);
}

/// The device memory an incoming Batch Read/Write is served against.
/// Deliberately abstract so Task 4's tag-backed image (a `SlmpMap` over the
/// project's tags) drops into the same seam the Task-3 fixture [SlmpWordImage]
/// occupies, both served through the one [dispatchSlmpFrame] — mirroring FINS's
/// `FinsMemoryImage`.
abstract class SlmpDeviceImage {
  /// Reads [count] words starting at [deviceNumber] from the device identified
  /// by the wire [deviceCode] (e.g. [kSlmpDevD]). Must NEVER throw: an
  /// unsupported device or an out-of-range address is reported as an error
  /// [SlmpReadOutcome], not an exception.
  SlmpReadOutcome readWords(int deviceCode, int deviceNumber, int count);

  /// Writes the LITTLE-ENDIAN word bytes [data] (`2 * words` long) starting at
  /// [deviceNumber] into the device identified by the wire [deviceCode]. Must
  /// NEVER throw: an unsupported device, an out-of-range address, or a refused
  /// write is reported as an error [SlmpWriteOutcome], not an exception.
  SlmpWriteOutcome writeWords(int deviceCode, int deviceNumber, Uint8List data);
}

/// A simple, pure, zero-filled per-device word image: a fixed-size word bank
/// per wire device code, with gap-reads-error and range-checked semantics.
/// Used to seed both the shipped host's Task-3 fixture and the E2E fixture
/// host; Task 4 replaces it (in the shipped host) with a tag-backed
/// [SlmpDeviceImage] over the real `SlmpMap`.
class SlmpWordImage implements SlmpDeviceImage {
  /// Wire device code (e.g. [kSlmpDevD]) -> that device's word bank. Words are
  /// stored host-native in the [Uint16List]; [readWords] emits them
  /// LITTLE-ENDIAN.
  final Map<int, Uint16List> _devices;

  SlmpWordImage(Map<int, Uint16List> devices) : _devices = devices;

  @override
  SlmpReadOutcome readWords(int deviceCode, int deviceNumber, int count) {
    final bank = _devices[deviceCode];
    if (bank == null) {
      return SlmpReadOutcome.error(kSlmpEndCommandError);
    }
    if (count <= 0) {
      return SlmpReadOutcome.error(kSlmpEndPointCount);
    }
    if (deviceNumber < 0 || deviceNumber + count > bank.length) {
      return SlmpReadOutcome.error(kSlmpEndAddressRange);
    }
    final out = Uint8List(count * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < count; i++) {
      bd.setUint16(i * 2, bank[deviceNumber + i] & 0xFFFF, Endian.little);
    }
    return SlmpReadOutcome.ok(out);
  }

  @override
  SlmpWriteOutcome writeWords(int deviceCode, int deviceNumber, Uint8List data) {
    final bank = _devices[deviceCode];
    if (bank == null) {
      return SlmpWriteOutcome.error(kSlmpEndCommandError);
    }
    if (deviceNumber < 0 || data.length.isOdd) {
      return SlmpWriteOutcome.error(kSlmpEndAddressRange);
    }
    final count = data.length ~/ 2;
    if (count <= 0) {
      return SlmpWriteOutcome.error(kSlmpEndPointCount);
    }
    if (deviceNumber + count > bank.length) {
      return SlmpWriteOutcome.error(kSlmpEndAddressRange);
    }
    final bd = ByteData.sublistView(data);
    for (var i = 0; i < count; i++) {
      bank[deviceNumber + i] = bd.getUint16(i * 2, Endian.little);
    }
    return SlmpWriteOutcome.ok();
  }
}

/// Dispatches one complete, reassembled SLMP request [frame] against [image],
/// returning the complete SLMP response frame bytes — or `null` when the frame
/// is not a served request (malformed/short frame, unparseable command data,
/// a bit-units subcommand, or a command code this task does not serve), in
/// which case the caller drops it without replying.
///
/// This never throws: [parseSlmpRequest], [parseBatchReadRequest], and
/// [parseBatchWriteRequest] all return `null` rather than throwing on hostile
/// input, and [SlmpDeviceImage.readWords]/[SlmpDeviceImage.writeWords] report
/// every failure as an end code.
Uint8List? dispatchSlmpFrame(Uint8List frame, SlmpDeviceImage image) {
  final request = parseSlmpRequest(frame);
  if (request == null) {
    return null;
  }
  // Only the word-units subcommand is served in v1; a bit-units subcommand
  // (0x0001) needs the per-bit addressing deferred to a later task, so it is
  // dropped here rather than answered incorrectly.
  if (request.subcommand != kSlmpSubcmdWord) {
    return null;
  }
  switch (request.command) {
    case kSlmpCmdBatchReadWord:
      final spec = parseBatchReadRequest(request.data);
      if (spec == null) {
        return null;
      }
      final outcome =
          image.readWords(spec.deviceCode, spec.deviceNumber, spec.pointCount);
      return buildSlmpResponse(
        requestHeader: request.header,
        endCode: outcome.endCode,
        data: buildBatchReadResponseData(outcome.words),
      );
    case kSlmpCmdBatchWriteWord:
      final parsed = parseBatchWriteRequest(request.data);
      if (parsed == null) {
        return null;
      }
      final outcome = image.writeWords(
        parsed.spec.deviceCode,
        parsed.spec.deviceNumber,
        parsed.writeData,
      );
      // A Batch Write response carries only the end code (no data).
      return buildSlmpResponse(
        requestHeader: request.header,
        endCode: outcome.endCode,
      );
    default:
      // Any other command is not served; drop it here (no reply).
      return null;
  }
}
