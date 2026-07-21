// Tests for the dart:io BACnet/IP UDP host (mobile/lib/services/bacnet_host.dart).
// Uses REAL datagram sockets bound to an ephemeral loopback port (port 0).
// Every test is bounded so a stalled server/socket can never hang the suite.
//
// SCOPE: Who-Is -> I-Am round trip (incl. instance-range filtering);
// ReadProperty/ReadPropertyMultiple served against the minimal
// `BacnetSimpleImage` fixture (the first group below, mirroring the host's
// Task-3 gate); a malformed/short datagram dropped WITHOUT wedging the bind;
// stop() closes the socket; and (the second group, Task 5) an END-TO-END
// mapped ReadProperty/WriteProperty against the REAL project-tag-backed
// `BacnetTagImage` the shipped host now serves (`BacnetHost._imageForProject`)
// — a mapped tag read, a write that updates it, and a refused write (a
// ReadOnly map entry) that leaves it unchanged, all over a real UDP socket.
// These tests prove the HOST'S datagram/socket handling — they cannot prove
// wire conformance against an independent implementation, which is why
// `tool/bacnet_e2e.sh` drives a real third-party client (bacpypes3) against
// the shared dispatch this host also calls.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/bacnet_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_bvll.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_services.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_tags.dart';
import 'package:soft_plc_mobile/services/bacnet_host.dart';

/// Builds a complete Unconfirmed-Request APDU (byte0 = PDU type nibble only,
/// no flags) with [serviceChoice] and [serviceData].
Uint8List _unconfirmedApdu(int serviceChoice, List<int> serviceData) {
  return Uint8List.fromList([
    kBacnetPduUnconfirmedRequest << 4,
    serviceChoice,
    ...serviceData,
  ]);
}

/// Builds a complete, unsegmented Confirmed-Request APDU: byte0 PDU type
/// nibble (no SEG/MOR/SA flags), byte1 max-segments/max-APDU (unused by this
/// device, arbitrary), byte2 invoke ID, byte3 service choice, then
/// [serviceData].
Uint8List _confirmedApdu(int invokeId, int serviceChoice, List<int> serviceData) {
  return Uint8List.fromList([
    kBacnetPduConfirmedRequest << 4,
    0x05,
    invokeId,
    serviceChoice,
    ...serviceData,
  ]);
}

/// A UDP client that binds an ephemeral loopback port, sends one datagram to
/// the host, and awaits (up to [timeout]) the single reply datagram (or
/// `null` if none arrives — used to prove a datagram was correctly dropped).
class _UdpClient {
  final RawDatagramSocket socket;
  _UdpClient(this.socket);

  static Future<_UdpClient> bind() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _UdpClient(s);
  }

  Future<Uint8List?> request(
    Uint8List data,
    int hostPort, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<Uint8List?>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final dg = socket.receive();
      if (dg != null && !completer.isCompleted) {
        completer.complete(dg.data);
      }
    });
    socket.send(data, InternetAddress.loopbackIPv4, hostPort);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  void sendOnly(Uint8List data, int hostPort) {
    socket.send(data, InternetAddress.loopbackIPv4, hostPort);
  }

  void close() => socket.close();
}

/// A minimal project; the host's Task-3 image does not read project tags at
/// all yet, but `start` still requires a readable [PlcProject].
PlcProject _buildHostProject() {
  return PlcProject(
    id: 'proj_bacnet_host_test',
    name: 'BACnet Host Test',
    controllerName: 'PLC_TEST',
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    tags: const [],
  );
}

void main() {
  late BacnetHost host;
  late PlcProject project;

  setUp(() async {
    project = _buildHostProject();
    host = BacnetHost(deviceInstance: 4321)..port = 0; // ephemeral loopback port
    await host.start(() => project);
    expect(host.status, BacnetHostStatus.running,
        reason: 'host should bind and run: ${host.lastError}');
    expect(host.boundPort, isNotNull);
    expect(host.endpointUrl, isNotNull);
  });

  tearDown(() async {
    await host.stop();
    expect(host.status, BacnetHostStatus.stopped);
  });

  test('Who-Is (no range) gets an I-Am naming this device\'s instance', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    final request = buildBvllUnicast(_unconfirmedApdu(kBacnetServiceWhoIs, const []));
    final reply = await client.request(request, host.boundPort!);

    expect(reply, isNotNull, reason: 'the host must answer a Who-Is with an I-Am');
    final apdu = parseBvllToApdu(reply!);
    expect(apdu, isNotNull);

    // I-Am is unconfirmed; parseApdu decodes it directly.
    final decoded = parseApdu(apdu!);
    expect(decoded, isNotNull);
    expect(decoded!.pduType, kBacnetPduUnconfirmedRequest);
    expect(decoded.serviceChoice, kBacnetServiceIAm);

    final reader = BacnetTagReader(decoded.serviceData);
    final objIdTag = reader.readTag();
    expect(objIdTag, isNotNull);
    final objId = objIdTag!.asObjectId();
    expect(objId, isNotNull);
    expect(objId!.$1, kBacnetObjectDevice);
    expect(objId.$2, 4321, reason: 'I-Am must name this host\'s own deviceInstance');
  });

  test('Who-Is with a range that excludes this device gets NO reply', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    // Range [9000, 9999] excludes deviceInstance 4321.
    final serviceData = <int>[
      ...encodeContextUnsigned(0, 9000),
      ...encodeContextUnsigned(1, 9999),
    ];
    final request = buildBvllUnicast(_unconfirmedApdu(kBacnetServiceWhoIs, serviceData));
    final reply = await client.request(request, host.boundPort!);

    expect(reply, isNull, reason: 'a Who-Is range excluding this device gets no I-Am');
  });

  test('ReadProperty of the device Object_Name is served with a ComplexAck', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    const invokeId = 0x11;
    final serviceData = <int>[
      ...encodeContextObjectId(0, kBacnetObjectDevice, 4321),
      ...encodeContextUnsigned(1, kBacnetPropObjectName),
    ];
    final request =
        buildBvllUnicast(_confirmedApdu(invokeId, kBacnetServiceReadProperty, serviceData));
    final reply = await client.request(request, host.boundPort!);

    expect(reply, isNotNull, reason: 'a valid ReadProperty must be answered');
    final apdu = parseBvllToApdu(reply!);
    expect(apdu, isNotNull);
    expect((apdu![0] >> 4) & 0x0F, kBacnetPduComplexAck);
    expect(apdu[1], invokeId, reason: 'invoke ID echoed');
    expect(apdu[2], kBacnetServiceReadProperty, reason: 'service echoed');

    // Walk past the echoed ctx0 objectId / ctx1 propertyId to the ctx3-open
    // value bracket, then decode the CharacterString value tag inside it.
    final reader = BacnetTagReader(apdu, 3);
    final echoedObjId = reader.readTag();
    expect(echoedObjId!.asObjectId(), (kBacnetObjectDevice, 4321));
    final echoedProp = reader.readTag();
    expect(echoedProp!.asUnsigned(), kBacnetPropObjectName);
    final openTag = reader.readTag();
    expect(openTag!.isOpening, isTrue);
    final valueTag = reader.readTag();
    expect(valueTag, isNotNull);
    expect(
      String.fromCharCodes(valueTag!.content.sublist(1)), // skip charset byte
      kBacnetDefaultDeviceName,
    );
  });

  test('ReadPropertyMultiple is served through the shared dispatch (RPM lands in a later task)',
      () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    const invokeId = 0x22;
    // One object spec (the Device object), two requested properties: one the
    // minimal BacnetSimpleImage DOES serve (Object_Name) and one it does NOT
    // (Present_Value is not a Device property at all) — proving one bad
    // property never fails the whole RPM batch.
    final serviceData = <int>[
      ...encodeContextObjectId(0, kBacnetObjectDevice, 4321),
      ...openingTag(1),
      ...encodeContextUnsigned(0, kBacnetPropObjectName),
      ...encodeContextUnsigned(0, kBacnetPropPresentValue),
      ...closingTag(1),
    ];
    final request = buildBvllUnicast(
      _confirmedApdu(invokeId, kBacnetServiceReadPropertyMultiple, serviceData),
    );
    final reply = await client.request(request, host.boundPort!);

    expect(reply, isNotNull, reason: 'RPM must still get an answer, not silence');
    final apdu = parseBvllToApdu(reply!);
    expect(apdu, isNotNull);
    expect((apdu![0] >> 4) & 0x0F, kBacnetPduComplexAck);
    expect(apdu[1], invokeId);
    expect(apdu[2], kBacnetServiceReadPropertyMultiple);

    // ctx0 objectId echoed, ctx1-open, then per property: ctx2 propId,
    // (ctx4-open value ctx4-close | ctx5-open errClass errCode ctx5-close).
    final reader = BacnetTagReader(apdu, 3);
    final objTag = reader.readTag();
    expect(objTag!.asObjectId(), (kBacnetObjectDevice, 4321));
    final openTag = reader.readTag();
    expect(openTag!.isOpening, isTrue);

    final firstPropId = reader.readTag();
    expect(firstPropId!.asUnsigned(), kBacnetPropObjectName);
    final firstBracket = reader.readTag();
    expect(firstBracket!.isOpening, isTrue, reason: 'Object_Name is served -> a value bracket (ctx4)');
    final firstValue = reader.readTag();
    expect(
      String.fromCharCodes(firstValue!.content.sublist(1)),
      kBacnetDefaultDeviceName,
    );
    final firstClose = reader.readTag();
    expect(firstClose!.isClosing, isTrue);

    final secondPropId = reader.readTag();
    expect(secondPropId!.asUnsigned(), kBacnetPropPresentValue);
    final secondBracket = reader.readTag();
    expect(secondBracket!.isOpening, isTrue,
        reason: 'Present_Value is unsupported on Device -> still an answer, an error bracket (ctx5)');
    final errClass = reader.readTag();
    expect(errClass!.asEnumerated(), kBacnetErrorClassProperty);
    final errCode = reader.readTag();
    expect(errCode!.asEnumerated(), kBacnetErrorCodeUnknownProperty);
  });

  test('a malformed/short datagram does NOT crash the bind — a following '
      'valid datagram is still answered', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    client.sendOnly(Uint8List.fromList([0x00, 0x01, 0x02]), host.boundPort!);
    client.sendOnly(Uint8List.fromList(List<int>.filled(40, 0xEE)), host.boundPort!);

    final request = buildBvllUnicast(_unconfirmedApdu(kBacnetServiceWhoIs, const []));
    final reply = await client.request(request, host.boundPort!);

    expect(reply, isNotNull,
        reason: 'the bind survived the malformed datagrams and still answers');
    expect(host.status, BacnetHostStatus.running);
  });

  test('stop() closes the socket: boundPort becomes null and status is stopped', () async {
    await host.stop();
    expect(host.status, BacnetHostStatus.stopped);
    expect(host.boundPort, isNull);
    expect(host.endpointUrl, isNull);
  });

  _mappedHostTests();
}

/// A project carrying real tags plus a persisted `BacnetProtocolConfig` +
/// `BacnetMap` — proves `BacnetHost._imageForProject` really does serve the
/// project's tags (a `BacnetTagImage`), not the Task-3 fixture image, over a
/// real UDP socket end to end.
PlcProject _buildMappedProject() {
  final project = PlcProject(
    id: 'proj_bacnet_host_mapped_test',
    name: 'BACnet Host Mapped Test',
    controllerName: 'PLC_TEST',
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    tags: [
      PlcTag(name: 'Level', path: 'Level', dataType: 'INT16', value: 55, ioType: 'Internal'),
      PlcTag(
        name: 'Locked',
        path: 'Locked',
        dataType: 'INT16',
        value: 250,
        ioType: 'Internal',
        access: 'ReadOnly',
      ),
    ],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.bacnet = BacnetProtocolConfig(
    enabled: true,
    deviceInstance: 5150,
    map: BacnetMap(entries: [
      BacnetMapEntry(tag: 'Level', objectType: kBacnetMapTypeAv, instance: 0),
      BacnetMapEntry(tag: 'Locked', objectType: kBacnetMapTypeAv, instance: 1, access: 'ReadOnly'),
    ]),
  );
  return project;
}

/// Builds a complete, unsegmented Confirmed-Request WriteProperty APDU
/// targeting `(objectType, instance)`'s Present_Value with an app-tagged Real
/// [value] — mirrors `bacnet_object_image_test.dart`'s dispatch-level
/// WriteProperty fixtures.
Uint8List _writePresentValueApdu(int invokeId, int objectType, int instance, double value) {
  final serviceData = <int>[
    ...encodeContextObjectId(0, objectType, instance),
    ...encodeContextUnsigned(1, kBacnetPropPresentValue),
    ...openingTag(3),
    ...encodeAppReal(value),
    ...closingTag(3),
  ];
  return Uint8List.fromList([
    kBacnetPduConfirmedRequest << 4,
    0x05,
    invokeId,
    kBacnetServiceWriteProperty,
    ...serviceData,
  ]);
}

void _mappedHostTests() {
  group('BacnetHost over the REAL project-tag-backed BacnetTagImage (end-to-end, real UDP)', () {
    late BacnetHost host;
    late PlcProject project;

    setUp(() async {
      project = _buildMappedProject();
      host = BacnetHost(deviceInstance: project.protocols!.bacnet!.deviceInstance)..port = 0;
      await host.start(() => project);
      expect(host.status, BacnetHostStatus.running, reason: 'host should bind and run: ${host.lastError}');
    });

    tearDown(() async {
      await host.stop();
    });

    test('ReadProperty of a mapped AV Present_Value reads the live tag value', () async {
      final client = await _UdpClient.bind();
      addTearDown(client.close);

      const invokeId = 0x60;
      final serviceData = <int>[
        ...encodeContextObjectId(0, kBacnetObjectAnalogValue, 0), // Level
        ...encodeContextUnsigned(1, kBacnetPropPresentValue),
      ];
      final request =
          buildBvllUnicast(_confirmedApdu(invokeId, kBacnetServiceReadProperty, serviceData));
      final reply = await client.request(request, host.boundPort!);

      expect(reply, isNotNull);
      final apdu = parseBvllToApdu(reply!)!;
      expect((apdu[0] >> 4) & 0x0F, kBacnetPduComplexAck);

      final reader = BacnetTagReader(apdu, 3);
      reader.readTag(); // echoed objectId
      reader.readTag(); // echoed propertyId
      final openTag = reader.readTag();
      expect(openTag!.isOpening, isTrue);
      final valueTag = reader.readTag();
      expect(valueTag!.asReal(), closeTo(55.0, 1e-6));
    });

    test('WriteProperty of a mapped AV updates the live tag; an independent ReadProperty observes it',
        () async {
      final client = await _UdpClient.bind();
      addTearDown(client.close);

      const writeInvokeId = 0x61;
      final writeRequest =
          buildBvllUnicast(_writePresentValueApdu(writeInvokeId, kBacnetObjectAnalogValue, 0, 77.0));
      final writeReply = await client.request(writeRequest, host.boundPort!);
      expect(writeReply, isNotNull);
      final writeApdu = parseBvllToApdu(writeReply!)!;
      expect((writeApdu[0] >> 4) & 0x0F, kBacnetPduSimpleAck, reason: 'the write must land');
      expect(readPath(project, 'Level'), 77, reason: 'the underlying tag must be updated in place');

      // Independent read-back over a SECOND client socket, proving the write
      // is observable through the host, not just through the model directly.
      final reader = await _UdpClient.bind();
      addTearDown(reader.close);
      const readInvokeId = 0x62;
      final readServiceData = <int>[
        ...encodeContextObjectId(0, kBacnetObjectAnalogValue, 0),
        ...encodeContextUnsigned(1, kBacnetPropPresentValue),
      ];
      final readRequest =
          buildBvllUnicast(_confirmedApdu(readInvokeId, kBacnetServiceReadProperty, readServiceData));
      final readReply = await reader.request(readRequest, host.boundPort!);
      expect(readReply, isNotNull);
      final readApdu = parseBvllToApdu(readReply!)!;
      final tagReader = BacnetTagReader(readApdu, 3);
      tagReader.readTag();
      tagReader.readTag();
      tagReader.readTag(); // opening bracket
      final valueTag = tagReader.readTag();
      expect(valueTag!.asReal(), closeTo(77.0, 1e-6));
    });

    test('WriteProperty of a ReadOnly-mapped AV is REFUSED (write-access-denied), value unchanged',
        () async {
      final client = await _UdpClient.bind();
      addTearDown(client.close);

      const invokeId = 0x63;
      final request =
          buildBvllUnicast(_writePresentValueApdu(invokeId, kBacnetObjectAnalogValue, 1, 999.0));
      final reply = await client.request(request, host.boundPort!);

      expect(reply, isNotNull, reason: 'a refused write must still be answered, not dropped');
      final apdu = parseBvllToApdu(reply!)!;
      expect((apdu[0] >> 4) & 0x0F, kBacnetPduError);
      final reader = BacnetTagReader(apdu, 3);
      final errClass = reader.readTag();
      final errCode = reader.readTag();
      expect(errClass!.asEnumerated(), kBacnetErrorClassProperty);
      expect(errCode!.asEnumerated(), kBacnetErrorCodeWriteAccessDenied);
      expect(readPath(project, 'Locked'), 250, reason: 'the ReadOnly-mapped tag must be unchanged');
    });
  });
}
