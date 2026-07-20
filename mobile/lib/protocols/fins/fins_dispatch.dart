// Omron FINS request -> response dispatch — pure Dart, no dart:io / Flutter
// imports. This is the SINGLE definition of FINS command handling that BOTH
// the shipped UDP host (`services/fins_host.dart`) and the E2E fixture host
// (`mobile/tool/fins_host_probe.dart`) call, exactly as the S7comm stack
// shares `dispatchS7VarJob` (`protocols/s7/s7_services.dart`). Because the
// fixture host cannot import the shipped host (it extends `ChangeNotifier`,
// which pulls in `dart:ui`, unavailable under a plain `dart run`), sharing
// ONE dispatch is what makes the real third-party `fins` client's proof
// against the fixture also a proof of the shipped host — the bytes the client
// validates are, by construction rather than by diff, the bytes the app puts
// on the wire.
//
// *** ENDIANNESS ***
// FINS multi-byte fields are BIG-ENDIAN (see fins_frame.dart / fins_memory.dart).
// This file builds the read-response word data big-endian via [FinsWordImage].
//
// *** SCOPE (this task) ***
// Serves a Memory Area Read (0x0101) against a [FinsMemoryImage]. Memory Area
// Write (0x0102) and wiring against the real tag map (`FinsMap`) are a later
// task, which will implement [FinsMemoryImage] over the project's tags and add
// the write branch to [dispatchFinsDatagram] — the [FinsMemoryImage] seam is
// kept deliberately general so that map can slot straight in. A command this
// task does not serve returns `null`, and the host drops the datagram.
//
// Safety contract: [dispatchFinsDatagram] returns `null` — and never throws —
// on malformed, truncated, unsupported, or otherwise hostile input, since the
// UDP host feeds it arbitrary datagram bytes read straight off the wire and
// must never wedge its bind on one bad datagram.
library fins_dispatch;

import 'dart:typed_data';

import 'fins_frame.dart';
import 'fins_memory.dart';

/// The outcome of one [FinsMemoryImage.readWords] call: a FINS end code plus,
/// on [kFinsEndNormal], the requested words as BIG-ENDIAN bytes
/// (`count * 2` long). On any error end code [words] is empty — the response
/// then carries the end code and no data, per the FINS wire format.
class FinsReadOutcome {
  final int endCode;
  final Uint8List words;

  const FinsReadOutcome(this.endCode, this.words);

  /// A successful read carrying [words] (BIG-ENDIAN, `count * 2` bytes).
  factory FinsReadOutcome.ok(Uint8List words) =>
      FinsReadOutcome(kFinsEndNormal, words);

  /// A failed read carrying only [endCode] (e.g. [kFinsEndNoArea] or
  /// [kFinsEndAddressRange]) and no data.
  factory FinsReadOutcome.error(int endCode) =>
      FinsReadOutcome(endCode, Uint8List(0));
}

/// The memory an incoming Memory Area Read is served from. Deliberately
/// abstract so the shipped host and the fixture host can each supply their own
/// backing (a seeded [FinsWordImage] at this task), and so a later task can
/// supply an implementation backed by the project's tags via `FinsMap` without
/// touching [dispatchFinsDatagram].
abstract class FinsMemoryImage {
  /// Reads [count] words starting at [wordAddress] from the area identified by
  /// the wire [areaCode] (e.g. [kFinsAreaDM]). Must NEVER throw: an
  /// unsupported area or an out-of-range address is reported as an error
  /// [FinsReadOutcome], not an exception.
  FinsReadOutcome readWords(int areaCode, int wordAddress, int count);
}

/// A simple, pure, zero-filled per-area word image: a fixed-size word bank per
/// wire area code, with gap-reads-zero and range-checked semantics. Used to
/// seed both the shipped host's Task-3 fixture and the E2E fixture host; a
/// later task may reuse it (seeded from the real map) or replace it with a
/// tag-backed [FinsMemoryImage].
class FinsWordImage implements FinsMemoryImage {
  /// Wire area code (e.g. [kFinsAreaDM]) -> that area's word bank. Words are
  /// stored host-native in the [Uint16List]; [readWords] emits them BIG-ENDIAN.
  final Map<int, Uint16List> _areas;

  FinsWordImage(Map<int, Uint16List> areas) : _areas = areas;

  @override
  FinsReadOutcome readWords(int areaCode, int wordAddress, int count) {
    final bank = _areas[areaCode];
    if (bank == null) {
      return FinsReadOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 ||
        count < 0 ||
        wordAddress + count > bank.length) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    final out = Uint8List(count * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < count; i++) {
      bd.setUint16(i * 2, bank[wordAddress + i] & 0xFFFF, Endian.big);
    }
    return FinsReadOutcome.ok(out);
  }
}

/// Dispatches one raw FINS command [datagram] against [image], returning the
/// complete FINS response datagram bytes — or `null` when the datagram is not
/// a served command (malformed/short frame, unparseable item, or a command
/// code this task does not serve), in which case the caller drops it without
/// replying.
///
/// This never throws: [parseFinsCommand] and [parseMemAreaReadItem] both
/// return `null` rather than throwing on hostile input, and
/// [FinsMemoryImage.readWords] reports every failure as an end code.
Uint8List? dispatchFinsDatagram(Uint8List datagram, FinsMemoryImage image) {
  final frame = parseFinsCommand(datagram);
  if (frame == null) {
    return null;
  }
  switch (frame.commandCode) {
    case kFinsCmdMemAreaRead:
      final item = parseMemAreaReadItem(frame.text);
      if (item == null) {
        return null;
      }
      final outcome = image.readWords(item.areaCode, item.wordAddress, item.count);
      return buildFinsResponse(
        requestHeader: frame.header,
        commandCode: frame.commandCode,
        endCode: outcome.endCode,
        data: buildMemReadResponseData(outcome.words),
      );
    default:
      // Memory Area Write (0x0102) and any other command are added in a later
      // task; drop unserved commands here (no reply).
      return null;
  }
}
