// Byte-exact fixtures for the CIP Connection Manager
// (mobile/lib/protocols/enip/cip_connection.dart): Forward Open (0x54) and
// Forward Close (0x4E) service-data handling, deterministic Target-to-
// Originator connection id allocation, and lookup/teardown.
// Verified against public CIP specification material.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_connection.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

const List<int> _defaultConnectionPath = [0x20, 0x02, 0x24, 0x01]; // Message Router, class/instance.

/// Builds the Forward Open *service data* only (everything after the outer
/// CIP request's service byte + path, matching what `CipRequest.data`
/// already holds once `parseCipRequest` has stripped the outer envelope).
Uint8List _buildForwardOpenData({
  required int connIdOT,
  required int connectionSerial,
  required int vendorId,
  required int originatorSerial,
  int connIdTOProposed = 0,
  int otRpi = 10000,
  int toRpi = 20000,
  int otParams = 0x4302,
  int toParams = 0x4302,
  int transportTypeTrigger = 0xA3,
  List<int> connectionPath = _defaultConnectionPath,
}) {
  final bytes = <int>[
    0x0A, // priority/time tick
    0x0E, // timeout ticks
    ..._le32(connIdOT),
    ..._le32(connIdTOProposed),
    ..._le16(connectionSerial),
    ..._le16(vendorId),
    ..._le32(originatorSerial),
    0x03, // connection timeout multiplier
    0x00, 0x00, 0x00, // reserved
    ..._le32(otRpi),
    ..._le16(otParams),
    ..._le32(toRpi),
    ..._le16(toParams),
    transportTypeTrigger,
    connectionPath.length ~/ 2, // connection path size, in words
    ...connectionPath,
  ];
  return Uint8List.fromList(bytes);
}

Uint8List _buildForwardCloseData({
  required int connectionSerial,
  required int vendorId,
  required int originatorSerial,
  List<int> connectionPath = _defaultConnectionPath,
}) {
  final bytes = <int>[
    0x0A, // priority/time tick
    0x0E, // timeout ticks
    ..._le16(connectionSerial),
    ..._le16(vendorId),
    ..._le32(originatorSerial),
    connectionPath.length ~/ 2, // connection path size, in words
    0x00, // reserved
    ...connectionPath,
  ];
  return Uint8List.fromList(bytes);
}

CipRequest _forwardOpenRequest({
  required int connIdOT,
  required int connectionSerial,
  required int vendorId,
  required int originatorSerial,
}) {
  return CipRequest(
    service: 0x54,
    path: [CipPathSegment.classId(0x06), CipPathSegment.instanceId(1)],
    data: _buildForwardOpenData(
      connIdOT: connIdOT,
      connectionSerial: connectionSerial,
      vendorId: vendorId,
      originatorSerial: originatorSerial,
    ),
  );
}

CipRequest _forwardCloseRequest({required int connectionSerial, required int vendorId, required int originatorSerial}) {
  return CipRequest(
    service: 0x4E,
    path: [CipPathSegment.classId(0x06), CipPathSegment.instanceId(1)],
    data: _buildForwardCloseData(connectionSerial: connectionSerial, vendorId: vendorId, originatorSerial: originatorSerial),
  );
}

void main() {
  group('forwardOpen', () {
    test('well-formed request succeeds, echoes originator values, allocates a predictable T->O id', () {
      final manager = CipConnectionManager();
      final request = _forwardOpenRequest(connIdOT: 0x12345678, connectionSerial: 0xBEEF, vendorId: 0x1234, originatorSerial: 0xCAFEBABE);

      final response = manager.forwardOpen(request);

      expect(response.generalStatus, kCipStatusSuccess);
      expect(response.service, 0x54);
      expect(response.data.length, 26);

      final bd = ByteData.sublistView(response.data);
      expect(bd.getUint32(0, Endian.little), 0x12345678); // O->T id echoed.
      expect(bd.getUint32(4, Endian.little), kInitialTargetConnectionId); // T->O id allocated.
      expect(bd.getUint16(8, Endian.little), 0xBEEF); // connection serial echoed.
      expect(bd.getUint16(10, Endian.little), 0x1234); // vendor id echoed.
      expect(bd.getUint32(12, Endian.little), 0xCAFEBABE); // originator serial echoed.
    });

    test('a second Forward Open allocates the next sequential T->O id', () {
      final manager = CipConnectionManager();
      final first = manager.forwardOpen(
        _forwardOpenRequest(connIdOT: 0x1, connectionSerial: 0x0001, vendorId: 0x0001, originatorSerial: 0x00000001),
      );
      final second = manager.forwardOpen(
        _forwardOpenRequest(connIdOT: 0x2, connectionSerial: 0x0002, vendorId: 0x0001, originatorSerial: 0x00000002),
      );

      final firstToId = ByteData.sublistView(first.data).getUint32(4, Endian.little);
      final secondToId = ByteData.sublistView(second.data).getUint32(4, Endian.little);

      expect(firstToId, kInitialTargetConnectionId);
      expect(secondToId, kInitialTargetConnectionId + 1);
    });

    test('a truncated Forward Open request returns an error status, not a throw', () {
      final manager = CipConnectionManager();
      final request = CipRequest(service: 0x54, path: [CipPathSegment.classId(0x06)], data: _u8([0x0A, 0x0E, 0x01, 0x02]));

      final response = manager.forwardOpen(request);

      expect(response.generalStatus, isNot(kCipStatusSuccess));
      expect(response.generalStatus, kCipStatusNotEnoughData);
    });

    test('a Forward Open whose declared connection path overruns the buffer returns an error, not a throw', () {
      final manager = CipConnectionManager();
      final data = _buildForwardOpenData(connIdOT: 1, connectionSerial: 1, vendorId: 1, originatorSerial: 1);
      // Truncate away the connection path bytes the fixed header declares.
      final truncated = Uint8List.fromList(data.sublist(0, data.length - 2));
      final request = CipRequest(service: 0x54, path: const [], data: truncated);

      final response = manager.forwardOpen(request);

      expect(response.generalStatus, kCipStatusNotEnoughData);
    });

    test('an empty request returns an error status, not a throw', () {
      final manager = CipConnectionManager();
      final response = manager.forwardOpen(CipRequest(service: 0x54, path: const [], data: Uint8List(0)));
      expect(response.generalStatus, isNot(kCipStatusSuccess));
    });
  });

  group('byTargetId', () {
    test('resolves the connection allocated by forwardOpen', () {
      final manager = CipConnectionManager();
      manager.forwardOpen(_forwardOpenRequest(connIdOT: 0xAA, connectionSerial: 0x10, vendorId: 0x20, originatorSerial: 0x30));

      final conn = manager.byTargetId(kInitialTargetConnectionId);

      expect(conn, isNotNull);
      expect(conn!.connectionIdOT, 0xAA);
      expect(conn.connectionIdTO, kInitialTargetConnectionId);
      expect(conn.connectionSerial, 0x10);
      expect(conn.vendorId, 0x20);
      expect(conn.originatorSerial, 0x30);
      expect(conn.sequenceCount, 0);
    });

    test('returns null for an unknown id', () {
      final manager = CipConnectionManager();
      expect(manager.byTargetId(999), isNull);
    });
  });

  group('forwardClose', () {
    test('matching serial/vendor/originator releases the connection and returns success', () {
      final manager = CipConnectionManager();
      manager.forwardOpen(_forwardOpenRequest(connIdOT: 0x1, connectionSerial: 0x55, vendorId: 0x66, originatorSerial: 0x77));
      expect(manager.byTargetId(kInitialTargetConnectionId), isNotNull);

      final response = manager.forwardClose(
        _forwardCloseRequest(connectionSerial: 0x55, vendorId: 0x66, originatorSerial: 0x77),
      );

      expect(response.generalStatus, kCipStatusSuccess);
      expect(response.service, 0x4E);
      expect(response.data.length, 10);
      final bd = ByteData.sublistView(response.data);
      expect(bd.getUint16(0, Endian.little), 0x55);
      expect(bd.getUint16(2, Endian.little), 0x66);
      expect(bd.getUint32(4, Endian.little), 0x77);

      expect(manager.byTargetId(kInitialTargetConnectionId), isNull);
    });

    test('closing an unknown connection returns a non-zero status, not a throw', () {
      final manager = CipConnectionManager();
      final response = manager.forwardClose(
        _forwardCloseRequest(connectionSerial: 0xDEAD, vendorId: 0xBEEF, originatorSerial: 0x12345678),
      );

      expect(response.generalStatus, isNot(kCipStatusSuccess));
    });

    test('closing the same connection twice fails the second time, not a throw', () {
      final manager = CipConnectionManager();
      manager.forwardOpen(_forwardOpenRequest(connIdOT: 0x1, connectionSerial: 0x01, vendorId: 0x02, originatorSerial: 0x03));
      final firstClose = manager.forwardClose(_forwardCloseRequest(connectionSerial: 0x01, vendorId: 0x02, originatorSerial: 0x03));
      final secondClose = manager.forwardClose(_forwardCloseRequest(connectionSerial: 0x01, vendorId: 0x02, originatorSerial: 0x03));

      expect(firstClose.generalStatus, kCipStatusSuccess);
      expect(secondClose.generalStatus, isNot(kCipStatusSuccess));
    });

    test('a truncated Forward Close request returns an error status, not a throw', () {
      final manager = CipConnectionManager();
      final response = manager.forwardClose(CipRequest(service: 0x4E, path: const [], data: _u8([0x0A, 0x0E, 0x01])));
      expect(response.generalStatus, isNot(kCipStatusSuccess));
    });
  });

  group('releaseAll', () {
    test('clears every open connection', () {
      final manager = CipConnectionManager();
      manager.forwardOpen(_forwardOpenRequest(connIdOT: 0x1, connectionSerial: 0x01, vendorId: 0x01, originatorSerial: 0x01));
      manager.forwardOpen(_forwardOpenRequest(connIdOT: 0x2, connectionSerial: 0x02, vendorId: 0x01, originatorSerial: 0x02));
      expect(manager.byTargetId(kInitialTargetConnectionId), isNotNull);
      expect(manager.byTargetId(kInitialTargetConnectionId + 1), isNotNull);

      manager.releaseAll();

      expect(manager.byTargetId(kInitialTargetConnectionId), isNull);
      expect(manager.byTargetId(kInitialTargetConnectionId + 1), isNull);
    });
  });
}
