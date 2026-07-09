// DNP3 Transport Function codec (WS26 DNP3 outstation, Task 3) — pure Dart,
// no dart:io / Flutter imports. Implements the 1-byte transport-segment
// header and a streaming reassembler that turns a sequence of transport
// segments (each carried inside one link-layer user-data frame) back into a
// complete application-layer fragment.
//
// Wire reference (IEEE 1815 Transport Function): each transport segment is a
// single header byte prepended to up to 249 bytes of application-layer data
// (250 minus the header byte, to fit a single 0x0564 link frame's 250-byte
// user-data budget): `FIN (bit 7, 0x80) | FIR (bit 6, 0x40) | SEQUENCE (bits
// 0-5, 6 bits, 0x3F mask)`. Note this bit layout is specific to the
// TRANSPORT header and differs from the APPLICATION layer's control byte
// (see `dnp3_app.dart`), which uses FIR=bit7/FIN=bit6/CON=bit5/UNS=bit4 and
// only a 4-bit sequence number — the two layers are independent framing
// mechanisms that happen to both carry a "FIR/FIN/sequence" idea.
//
// CORRECTNESS NOTE: an earlier draft of this file (following a paraphrase
// that turned out to invert two bit positions) placed FIR at 0x40 and FIN at
// 0x20, which collides with the top bit of a 6-bit (0x3F-masked) sequence
// number — a segment with FIN set and seq >= 32 would be indistinguishable
// from a lower sequence number. The bit positions above (FIN=0x80, FIR=0x40,
// SEQ=0x3F over bits 0-5, no overlap) match the real IEEE 1815 layout and
// are what every real DNP3 stack (and Task 6's master) expects.
//
// A single-segment application fragment (the common case for the payload
// sizes this v1 outstation deals with) simply has `fir = fin = true` and
// `sequence = 0`; multi-segment reassembly (fir on the first segment, fin on
// the last, sequence incrementing by one modulo 64 in between) is supported
// by [DnpTransportReassembler] for completeness and future-proofing, even
// though it is not expected to be exercised by v1's small object payloads.
//
// dart2js-safety note: the header byte and the 6-bit sequence number are
// both well within 8 bits, handled with plain byte masks/shifts (`&`, `<<`),
// which is safe on dart2js per the same reasoning as `dnp3_link.dart`.
library dnp3_transport;

import 'dart:typed_data';

/// Transport-header bit masks.
const int _finMask = 0x80;
const int _firMask = 0x40;
const int _seqMask = 0x3F;

/// Builds one transport segment: the 1-byte header (`FIN(0x80) | FIR(0x40) |
/// (seq & 0x3F)`) followed by [appData] verbatim.
///
/// This codec does not itself split [appData] across multiple segments —
/// callers that need multi-segment framing (application fragments longer
/// than a single link frame's user-data budget can carry) should chunk
/// [appData] themselves and call this once per chunk with the appropriate
/// [fir]/[fin]/[seq] for that chunk.
Uint8List buildTransport(
  int seq, {
  required bool fir,
  required bool fin,
  required Uint8List appData,
}) {
  final header = (fir ? _firMask : 0) | (fin ? _finMask : 0) | (seq & _seqMask);
  final out = Uint8List(1 + appData.length);
  out[0] = header;
  out.setRange(1, out.length, appData);
  return out;
}

/// Reassembles a sequence of transport segments (as produced by
/// [buildTransport]) back into complete application-layer fragments.
///
/// Feed each segment via [addSegment] in the order it was received (after
/// link-layer de-framing). A segment with `FIR` set starts a new fragment
/// (discarding any partially-collected previous one — a fresh FIR always
/// wins, matching real master/outstation behavior when a peer restarts a
/// transfer). [addSegment] returns the complete reassembled fragment once a
/// segment with `FIN` set is processed, or `null` while more segments are
/// still expected.
///
/// Sequence numbers are checked to increment by one (mod 64) between
/// segments of the same fragment; a gap or duplicate resets the in-progress
/// fragment and returns `null` for that segment (never throws). Malformed
/// input (an empty segment) is likewise ignored, never thrown on.
class DnpTransportReassembler {
  final BytesBuilder _buf = BytesBuilder();
  bool _active = false;
  int _expectedSeq = 0;

  /// Feeds one transport segment. Returns the reassembled application
  /// fragment once its final (FIN) segment has been processed, else `null`.
  Uint8List? addSegment(Uint8List segment) {
    if (segment.isEmpty) {
      return null; // Malformed: no header byte. Ignored, not thrown.
    }
    final header = segment[0];
    final fir = (header & _firMask) != 0;
    final fin = (header & _finMask) != 0;
    final seq = header & _seqMask;
    final payload = segment.sublist(1);

    if (fir) {
      _buf.clear();
      _active = true;
      _expectedSeq = seq;
    }
    if (!_active) {
      return null; // A non-FIR segment arrived with no fragment in progress.
    }
    if (seq != _expectedSeq) {
      // Out-of-sequence segment: abandon the in-progress fragment rather
      // than reassemble corrupt/misordered data.
      _active = false;
      _buf.clear();
      return null;
    }

    _buf.add(payload);
    _expectedSeq = (_expectedSeq + 1) & _seqMask;

    if (fin) {
      final result = _buf.toBytes();
      _buf.clear();
      _active = false;
      return result;
    }
    return null;
  }

  /// Discards any partially-collected fragment, e.g. after a link-layer
  /// reset or timeout.
  void reset() {
    _buf.clear();
    _active = false;
    _expectedSeq = 0;
  }
}
