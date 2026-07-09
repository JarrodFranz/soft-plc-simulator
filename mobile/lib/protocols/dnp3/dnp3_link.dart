// DNP3 Data Link Layer codec (WS26 DNP3 outstation, Task 2) — pure Dart, no
// dart:io / Flutter imports. Implements CRC-16/DNP, the `0x0564` link frame
// (10-byte header block + 16-byte user-data blocks, each block CRC-guarded),
// and a streaming `DnpLinkBuffer` reassembler for TCP-chunked input.
//
// Wire reference (IEEE 1815 Data Link Layer): a link frame starts with the
// two sync bytes `0x05 0x64`, followed by a 10-byte header BLOCK: LENGTH (1
// byte — counts CONTROL + 2 address bytes + user-data length, i.e.
// `5 + userDataLen`, max 255), CONTROL (1 byte), DESTINATION (u16 LE),
// SOURCE (u16 LE), then a 2-byte CRC (LE) over the preceding 8 header bytes.
// User data follows in blocks of up to 16 bytes, each immediately followed
// by its own 2-byte CRC (LE) over just that block's data bytes. All DNP3
// multi-byte integers are little-endian.
//
// dart2js-safety note: every multi-byte field here is 16 bits or narrower and
// is assembled/read with byte-wise `int` shifts/masks (`<<`, `>>`, `&0xFF`) —
// never `ByteData.getInt64`/`setInt64` (unsupported on dart2js) and never any
// operation on values wider than 16 bits, so there is no risk of exceeding
// the 32-bit-safe-integer range dart2js guarantees for bitwise ops.
//
// CRC-16/DNP validation: `dnpCrc` implements the reflected CRC-16/DNP
// algorithm (poly 0x3D65, reflected shift constant 0xA6BC, init 0, final
// one's-complement == xorout 0xFFFF). It has been cross-checked against TWO
// independently-computed references outside this codebase (see
// `test/dnp3_link_test.dart` and `.git/sdd/task-2-report.md` for the exact
// values and how they were derived): Python's third-party `crcmod` library's
// predefined `crc-16-dnp` function, and a from-scratch MSB-first
// bit-by-bit polynomial-division implementation with explicit input/output
// bit reflection. Both agree exactly with this implementation on every test
// vector. Task 6's real Rust `dnp3` master remains the final wire-level
// authority for CRC correctness.
library dnp3_link;

import 'dart:typed_data';

/// Link-layer sync bytes that begin every DNP3 frame.
const int _startByte1 = 0x05;
const int _startByte2 = 0x64;

/// Header block size: 2 sync + LENGTH + CONTROL + 2 dest + 2 src + 2 CRC.
const int _headerBlockLen = 10;

/// Number of header bytes covered by the header CRC (everything before it).
const int _headerCrcSpan = 8;

/// Max bytes of user data per data block, each followed by its own CRC.
const int _maxBlockDataLen = 16;

/// Computes the CRC-16/DNP (IEEE 1815 Data Link Layer) checksum of [bytes].
///
/// Reflected algorithm: init 0, XOR each byte in, shift 8 times using the
/// reflected polynomial constant `0xA6BC` (bit-reversal of poly `0x3D65`),
/// then return the one's-complement of the final register (equivalent to
/// `xorout = 0xFFFF`). See the library doc comment above for how this was
/// independently cross-validated.
int dnpCrc(List<int> bytes) {
  int crc = 0x0000;
  for (final b in bytes) {
    crc ^= (b & 0xFF);
    for (int i = 0; i < 8; i++) {
      if ((crc & 0x0001) != 0) {
        crc = (crc >> 1) ^ 0xA6BC;
      } else {
        crc >>= 1;
      }
    }
  }
  return (~crc) & 0xFFFF;
}

/// A decoded DNP3 link-layer frame: CONTROL byte, DESTINATION/SOURCE link
/// addresses, and the reassembled (block-CRC-stripped) user-data payload.
class DnpLinkFrame {
  final int control;
  final int dest;
  final int src;
  final Uint8List userData;

  DnpLinkFrame({
    required this.control,
    required this.dest,
    required this.src,
    required this.userData,
  });
}

/// Builds a complete `0x0564` link frame: the 10-byte header block (with its
/// CRC) followed by [userData] split into up to-16-byte blocks, each with its
/// own trailing 2-byte CRC.
///
/// [control], [dest], and [src] are masked to their wire widths (control to 8
/// bits, dest/src to 16 bits) so out-of-range callers can never corrupt
/// adjacent fields. If [userData] is longer than 250 bytes (the max a single
/// LENGTH byte can express, `255 - 5`), it is silently truncated to 250 bytes
/// — this codec never throws, even when misused by a caller.
Uint8List buildLinkFrame({
  required int control,
  required int dest,
  required int src,
  required Uint8List userData,
}) {
  const maxUserDataLen = 255 - 5;
  final data = userData.length > maxUserDataLen ? userData.sublist(0, maxUserDataLen) : userData;

  final out = BytesBuilder();
  final header = Uint8List(_headerCrcSpan);
  header[0] = _startByte1;
  header[1] = _startByte2;
  header[2] = (5 + data.length) & 0xFF; // LENGTH
  header[3] = control & 0xFF; // CONTROL
  header[4] = dest & 0xFF; // DESTINATION lo
  header[5] = (dest >> 8) & 0xFF; // DESTINATION hi
  header[6] = src & 0xFF; // SOURCE lo
  header[7] = (src >> 8) & 0xFF; // SOURCE hi
  out.add(header);
  out.add(_u16LeBytes(dnpCrc(header)));

  var offset = 0;
  while (offset < data.length) {
    final blockLen = data.length - offset < _maxBlockDataLen ? data.length - offset : _maxBlockDataLen;
    final block = data.sublist(offset, offset + blockLen);
    out.add(block);
    out.add(_u16LeBytes(dnpCrc(block)));
    offset += blockLen;
  }
  return out.toBytes();
}

/// Parses a complete `0x0564` link frame. Returns null on anything
/// malformed or short: wrong sync bytes, an implausible LENGTH, a truncated
/// buffer, or any header/block CRC mismatch. Never throws, even on empty or
/// garbage input.
DnpLinkFrame? parseLinkFrame(Uint8List frame) {
  if (frame.length < _headerBlockLen) {
    return null;
  }
  if (frame[0] != _startByte1 || frame[1] != _startByte2) {
    return null;
  }
  final length = frame[2];
  if (length < 5) {
    return null;
  }
  final headerCrc = _u16Le(frame, _headerCrcSpan);
  if (dnpCrc(frame.sublist(0, _headerCrcSpan)) != headerCrc) {
    return null;
  }
  final control = frame[3];
  final dest = _u16Le(frame, 4);
  final src = _u16Le(frame, 6);

  final userDataLen = length - 5;
  final userData = Uint8List(userDataLen);
  var offset = _headerBlockLen;
  var written = 0;
  var remaining = userDataLen;
  while (remaining > 0) {
    final blockLen = remaining < _maxBlockDataLen ? remaining : _maxBlockDataLen;
    if (frame.length < offset + blockLen + 2) {
      return null; // Truncated: promised more data than is present.
    }
    final block = frame.sublist(offset, offset + blockLen);
    final blockCrc = _u16Le(frame, offset + blockLen);
    if (dnpCrc(block) != blockCrc) {
      return null;
    }
    userData.setRange(written, written + blockLen, block);
    written += blockLen;
    offset += blockLen + 2;
    remaining -= blockLen;
  }

  return DnpLinkFrame(control: control, dest: dest, src: src, userData: userData);
}

int _u16Le(Uint8List data, int offset) => data[offset] | (data[offset + 1] << 8);

Uint8List _u16LeBytes(int value) => Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);

/// Streaming reassembler that turns a sequence of raw TCP-chunked byte
/// arrays into complete [DnpLinkFrame]s. Tolerant of arbitrary chunking (a
/// frame split across many `add()` calls, several frames coalesced into one
/// `add()` call) and of leading/embedded garbage: bytes that can't be the
/// start of a valid frame are dropped one at a time while resynchronizing on
/// the next `0x05 0x64` sync sequence. Never throws.
class DnpLinkBuffer {
  final List<int> _buf = <int>[];

  /// Appends [chunk] to the internal buffer and returns every complete,
  /// CRC-valid link frame that can now be extracted (possibly empty, possibly
  /// more than one).
  List<DnpLinkFrame> add(List<int> chunk) {
    _buf.addAll(chunk);
    final frames = <DnpLinkFrame>[];

    while (true) {
      // Drop leading bytes until the buffer starts with a plausible sync
      // sequence (or runs out of data to check).
      while (_buf.isNotEmpty && _buf[0] != _startByte1) {
        _buf.removeAt(0);
      }
      if (_buf.length < 2) {
        break; // Need more data to confirm/reject the second sync byte.
      }
      if (_buf[1] != _startByte2) {
        _buf.removeAt(0); // False start byte; resync from the next byte.
        continue;
      }
      if (_buf.length < 3) {
        break; // Need the LENGTH byte.
      }
      final length = _buf[2];
      if (length < 5) {
        _buf.removeAt(0); // Implausible LENGTH; resync.
        continue;
      }
      final userDataLen = length - 5;
      final numBlocks = userDataLen == 0 ? 0 : (userDataLen + _maxBlockDataLen - 1) ~/ _maxBlockDataLen;
      final totalFrameLen = _headerBlockLen + userDataLen + 2 * numBlocks;
      if (_buf.length < totalFrameLen) {
        break; // Frame not fully buffered yet.
      }

      final frameBytes = Uint8List.fromList(_buf.sublist(0, totalFrameLen));
      final parsed = parseLinkFrame(frameBytes);
      if (parsed == null) {
        // Matched sync + a plausible LENGTH, but a CRC failed: this was a
        // false-positive sync (or genuine corruption). Drop just the sync
        // byte and keep scanning rather than discarding the whole span, so a
        // real frame embedded further in isn't lost.
        _buf.removeAt(0);
        continue;
      }
      frames.add(parsed);
      _buf.removeRange(0, totalFrameLen);
    }
    return frames;
  }
}
