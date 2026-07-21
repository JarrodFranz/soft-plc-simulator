// BACnet/IP BVLL (BACnet Virtual Link Layer) + minimal NPDU framing codec —
// pure Dart, no dart:io / Flutter imports. This is the bottom layer of the
// BACnet/IP stack: the 4-byte BVLL header that rides directly inside a UDP
// datagram, wrapping the NPDU (network layer) header around the APDU
// (application layer) payload that later tasks (bacnet_services.dart, a
// later task) parse and build. The primitive TAG codec used INSIDE the APDU
// lives in `bacnet_tags.dart` — this file only frames/unframes the APDU, it
// never looks inside it.
//
// *** WIRE LAYOUT (all multi-byte fields BIG-ENDIAN) ***
// BVLL header (4 bytes): `type`(0, always 0x81), `function`(1, 0x0A
// Original-Unicast-NPDU or 0x0B Original-Broadcast-NPDU — other function
// codes are not served by this device and are dropped), `length`(2-3, u16
// BE) = the length of the WHOLE datagram INCLUDING this 4-byte BVLL header
// (not just what follows it).
//
// NPDU header (starts immediately after the BVLL header): `version`(1 byte,
// must be 0x01), `control`(1 byte) — bit `0x20` (destination-present) means
// this is router-bound traffic addressed to a network other than the local
// one (DNET/DLEN/DADR + a hop-count byte would follow); this device is not a
// router and drops such datagrams outright without parsing those fields.
// Bit `0x08` (source-present) means SNET(2 bytes BE) + SLEN(1 byte) +
// SADR(SLEN bytes) follow and must be skipped to reach the APDU — the reply
// always goes to the UDP datagram's actual source address/port regardless
// of what these fields say, so this codec never inspects their content, it
// only skips over them correctly. A minimal NPDU (no destination, no
// source) is exactly 2 bytes: `01 00`. This device always REPLIES with that
// minimal 2-byte NPDU ([buildBvllUnicast]/[buildBvllBroadcast]), never
// setting the destination- or source-present bits on outgoing traffic.
//
// Safety contract: [parseBvllToApdu] returns `null` — and NEVER throws — on
// malformed, truncated, or otherwise hostile input, since the UDP host (a
// later task) feeds this function arbitrary datagram bytes read straight
// off the wire and must not crash or wedge its bind on one bad datagram.
library bacnet_bvll;

import 'dart:typed_data';

// --- BVLL wire constants -----------------------------------------------------

/// The single BVLC type byte this device recognizes — BACnet/IP (Annex J).
const int kBvllTypeBacnetIp = 0x81;

/// BVLL function code: Original-Unicast-NPDU.
const int kBvllFunctionUnicast = 0x0A;

/// BVLL function code: Original-Broadcast-NPDU.
const int kBvllFunctionBroadcast = 0x0B;

/// Length, in bytes, of the fixed BVLL header (`type` + `function` +
/// `length` u16).
const int kBvllHeaderLen = 4;

// --- NPDU wire constants -----------------------------------------------------

/// The only NPDU version this device understands.
const int kNpduVersion = 1;

/// NPDU `control` bit: destination-present (router-bound traffic). This
/// device is not a router and drops such datagrams.
const int kNpduControlDestinationPresent = 0x20;

/// NPDU `control` bit: source-present (SNET/SLEN/SADR fields follow the
/// version/control bytes and must be skipped to reach the APDU).
const int kNpduControlSourcePresent = 0x08;

/// Minimal outgoing NPDU this device always sends: version 1, control 0 (no
/// destination, no source, no network-layer message).
const List<int> kNpduMinimal = [kNpduVersion, 0x00];

// --- Parse ------------------------------------------------------------------

/// Parses [datagram] as a BACnet/IP BVLL frame and returns the APDU slice
/// carried inside it, or `null` if [datagram] is not a servable BVLL/NPDU
/// frame. Never throws.
///
/// Validates, in order: BVLC type is [kBvllTypeBacnetIp]; function is
/// [kBvllFunctionUnicast] or [kBvllFunctionBroadcast] (any other function —
/// e.g. BBMD/foreign-device registration — is not served by this device and
/// is dropped); the BE `length` field equals `datagram.length` exactly;
/// there is room for an NPDU version+control byte pair; NPDU `version` is
/// [kNpduVersion]. If the destination-present control bit
/// ([kNpduControlDestinationPresent]) is set the datagram is router-bound
/// traffic and is dropped (this device is not a router) WITHOUT inspecting
/// the DNET/DLEN/DADR/hop-count fields that would otherwise follow. If the
/// source-present control bit ([kNpduControlSourcePresent]) is set, the
/// SNET(2)/SLEN(1)/SADR(SLEN) fields are skipped (never inspected — a reply
/// always targets the UDP datagram's actual source) to reach the APDU.
///
/// Returns a fresh [Uint8List] containing exactly the APDU bytes (everything
/// after the NPDU header), or `null` on any malformed/truncated input.
Uint8List? parseBvllToApdu(Uint8List datagram) {
  try {
    if (datagram.length < kBvllHeaderLen) {
      return null;
    }
    if (datagram[0] != kBvllTypeBacnetIp) {
      return null;
    }
    final function = datagram[1];
    if (function != kBvllFunctionUnicast && function != kBvllFunctionBroadcast) {
      return null;
    }
    final declaredLength = ByteData.sublistView(datagram, 2, 4).getUint16(0, Endian.big);
    if (declaredLength != datagram.length) {
      return null;
    }

    const npduStart = kBvllHeaderLen;
    if (datagram.length < npduStart + 2) {
      return null; // no room for NPDU version + control
    }
    final version = datagram[npduStart];
    if (version != kNpduVersion) {
      return null;
    }
    final control = datagram[npduStart + 1];
    if ((control & kNpduControlDestinationPresent) != 0) {
      // Router-bound traffic; this device is not a router. Drop without
      // parsing DNET/DLEN/DADR/hop-count.
      return null;
    }

    var apduStart = npduStart + 2;
    if ((control & kNpduControlSourcePresent) != 0) {
      // SNET(2) + SLEN(1) must be present before we know how much SADR to skip.
      if (datagram.length < apduStart + 3) {
        return null;
      }
      final slen = datagram[apduStart + 2];
      final sourceFieldsLen = 3 + slen; // SNET(2) + SLEN(1) + SADR(slen)
      if (datagram.length < apduStart + sourceFieldsLen) {
        return null;
      }
      apduStart += sourceFieldsLen;
    }

    if (apduStart > datagram.length) {
      return null;
    }
    return Uint8List.fromList(datagram.sublist(apduStart));
  } catch (_) {
    return null;
  }
}

// --- Build --------------------------------------------------------------

/// Builds a complete BVLL+NPDU+APDU datagram wrapping [apdu] with the given
/// [function] code and a minimal outgoing NPDU ([kNpduMinimal]: version 1,
/// control 0 — no destination, no source). The BVLL `length` field is set
/// to the exact total length of the resulting datagram, BIG-ENDIAN.
Uint8List _buildBvll(int function, Uint8List apdu) {
  final totalLength = kBvllHeaderLen + kNpduMinimal.length + apdu.length;
  final out = Uint8List(totalLength);
  out[0] = kBvllTypeBacnetIp;
  out[1] = function & 0xFF;
  ByteData.sublistView(out, 2, 4).setUint16(0, totalLength, Endian.big);
  out.setRange(kBvllHeaderLen, kBvllHeaderLen + kNpduMinimal.length, kNpduMinimal);
  out.setRange(kBvllHeaderLen + kNpduMinimal.length, totalLength, apdu);
  return out;
}

/// Builds an Original-Unicast-NPDU BVLL datagram carrying [apdu], prepending
/// the minimal NPDU (`01 00`) and a BVLL header with the correct BE length.
Uint8List buildBvllUnicast(Uint8List apdu) => _buildBvll(kBvllFunctionUnicast, apdu);

/// Builds an Original-Broadcast-NPDU BVLL datagram carrying [apdu],
/// prepending the minimal NPDU (`01 00`) and a BVLL header with the correct
/// BE length.
Uint8List buildBvllBroadcast(Uint8List apdu) => _buildBvll(kBvllFunctionBroadcast, apdu);
