// A tiny `dart run` CLI that hosts BACnet/IP over a real `RawDatagramSocket`
// (UDP), prints `READY` once bound, then serves until killed. Used by
// `tool/bacnet_e2e.sh` as the Dart half of the v1 BACnet/IP workstream's
// EXTENDED (Task 5) E2E machine-proof: a REAL third-party client —
// `bacpypes3`, driven by `tool/py/bacnet_probe.py` — discovers this fixture
// device, then reads and writes through the REAL tag-backed object model
// (`BacnetTagImage`), proving the full RPM/WriteProperty/force-gate path a
// project actually ships, not just the minimal Task-3 fixture image.
//
// WHY A REAL CLIENT RUNS THIS: BACnet's APDU payloads are ASN.1-style TAGGED
// values (see `bacnet_tags.dart`'s "TAG-STRUCTURE TRAP" note) — a
// build-then-parse round trip through our OWN codec proves self-consistency,
// not conformance. This fixture is where a client written independently of us
// reads AND writes our wire bytes, and — crucially — reads values this
// fixture SEEDED into tags independently of the client, settling every open
// tag-encoding question against the REAL object model this task ships.
//
// IMPORTANT: this does NOT import `services/bacnet_host.dart`. `BacnetHost
// extends ChangeNotifier` (`package:flutter/foundation.dart`), which
// transitively pulls in Flutter/`dart:ui` machinery unavailable under a plain
// `dart run` (only `flutter test`'s harness provides a `dart:ui` shim, and
// this must run as a standalone process) — see `mobile/tool/fins_host_probe.dart`,
// whose identical note this mirrors.
//
// *** HOW THIS STAYS FAITHFUL TO THE SHIPPED HOST ***
// The dispatch path below is NOT mirrored — it is SHARED: both this fixture
// and `BacnetHost` call the single pure `dispatchBacnetDatagram`
// (`protocols/bacnet/bacnet_dispatch.dart`) against a `BacnetObjectImage`, and
// — as of this task — that image is the REAL `BacnetTagImage`
// (`protocols/bacnet/bacnet_object_image.dart`) built from a fixture
// `PlcProject` + `BacnetMap`, exactly mirroring `tool/slmp_host_probe.dart`'s
// fixture-project pattern (see that file's header). So the bytes the
// bacpypes3 client validates here are, by construction rather than by diff,
// the same bytes the shipped app puts on the wire, through the SAME force-gate
// chain a real project's tags go through.
//
// *** THE FIXTURE OBJECT MODEL ***
// Device instance 3056, Object_Name "BACNET-E2E-FIXTURE" (both pinned in
// `tool/py/bacnet_probe.py` since Task 3 — kept unchanged so the probe's
// EARLY steps 1-4 still pass unmodified against the REAL tag-backed image).
// Plus, new at this task:
//   - AV 0 ("Av0Seed", FLOAT64 12.5, ReadOnly) — the Task-3 seeded-read value,
//     now served off a REAL tag rather than `BacnetSimpleImage`'s hand-rolled
//     Present_Value.
//   - BV 0 ("Bv0Seed", BOOL true, ReadOnly) — a seeded Binary Value state
//     read.
//   - AV 1 ("AvWrite", FLOAT64, ReadWrite) — the write + independent
//     read-back target.
//   - BV 1 ("BvWrite", BOOL, ReadWrite) — the write-with-priority + read-back
//     target.
//   - AV 2 ("AvLocked", FLOAT64, ReadOnly-MAPPED) — the refused-write target
//     (map access is ReadOnly; the underlying tag itself is an ordinary
//     ReadWrite tag, so the refusal proves the MAP gate, exactly like
//     `bacnet_object_image_test.dart`'s `RoTag` fixture).
// Every constant below is pinned in `tool/py/bacnet_probe.py`; keep the two
// files in step.
//
// *** THE UDP SHAPE ***
// One datagram = one complete BVLL/NPDU/APDU frame. There is no reassembly,
// no per-connection state; a reply goes back to the datagram's own source
// address/port.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/bacnet_host_probe.dart <port>
import 'dart:async';
import 'dart:io';

import 'package:soft_plc_mobile/models/bacnet_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_dispatch.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_object_image.dart';

/// The fixture's Device_Object_Instance. Pinned in `tool/py/bacnet_probe.py`.
const int _kFixtureDeviceInstance = 3056;

/// The fixture's Object_Name. Pinned in `tool/py/bacnet_probe.py`.
const String _kFixtureDeviceName = 'BACNET-E2E-FIXTURE';

/// AV 0 — the Task-3-era seeded-read value, now served off a real tag.
/// Independently seeded so a real client reading it back through its OWN
/// parser is a true conformance check, not a round trip. 12.5 is exactly
/// representable in IEEE-754 single precision, so no float32 narrowing blurs
/// the assertion.
const int _kAv0Instance = 0;
const double _kAv0SeedValue = 12.5;

/// BV 0 — a seeded Binary Value state read.
const int _kBv0Instance = 0;
const bool _kBv0SeedValue = true;

/// AV 1 — the write + independent read-back target.
const int _kAv1Instance = 1;
const double _kAv1InitialValue = 5.0;

/// BV 1 — the write-with-priority + read-back target.
const int _kBv1Instance = 1;

/// AV 2 — the ReadOnly-MAPPED refused-write target.
const int _kAv2Instance = 2;
const double _kAv2Value = 42.0;

/// Builds the fixture project + BacnetMap the E2E probe reads and writes,
/// mirroring `slmp_host_probe.dart`'s `_fixtureProject`. Tag name == path
/// (single top-level names) so a map entry's `tag` resolves directly.
PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_bacnet_e2e_fixture',
    name: 'BACnet E2E Fixture',
    controllerName: 'PLC_E2E',
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    tags: [
      PlcTag(name: 'Av0Seed', path: 'Av0Seed', dataType: 'FLOAT64', value: _kAv0SeedValue, ioType: 'Internal'),
      PlcTag(name: 'Bv0Seed', path: 'Bv0Seed', dataType: 'BOOL', value: _kBv0SeedValue, ioType: 'Internal'),
      PlcTag(name: 'AvWrite', path: 'AvWrite', dataType: 'FLOAT64', value: _kAv1InitialValue, ioType: 'Internal'),
      PlcTag(name: 'BvWrite', path: 'BvWrite', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'AvLocked', path: 'AvLocked', dataType: 'FLOAT64', value: _kAv2Value, ioType: 'Internal'),
    ],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.bacnet = BacnetProtocolConfig(
    enabled: true,
    deviceInstance: _kFixtureDeviceInstance,
    map: BacnetMap(entries: [
      BacnetMapEntry(tag: 'Av0Seed', objectType: kBacnetMapTypeAv, instance: _kAv0Instance, access: 'ReadOnly'),
      BacnetMapEntry(tag: 'Bv0Seed', objectType: kBacnetMapTypeBv, instance: _kBv0Instance, access: 'ReadOnly'),
      BacnetMapEntry(tag: 'AvWrite', objectType: kBacnetMapTypeAv, instance: _kAv1Instance),
      BacnetMapEntry(tag: 'BvWrite', objectType: kBacnetMapTypeBv, instance: _kBv1Instance),
      BacnetMapEntry(tag: 'AvLocked', objectType: kBacnetMapTypeAv, instance: _kAv2Instance, access: 'ReadOnly'),
    ]),
  );
  return project;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/bacnet_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final project = _fixtureProject();
  // The image is backed by the project's tags via the persisted BACnet map —
  // the same `BacnetTagImage` the shipped host serves, so a write mutates the
  // project in place and a following read observes it.
  final BacnetObjectImage image = BacnetTagImage(
    project,
    project.protocols!.bacnet!.map,
    deviceInstance: _kFixtureDeviceInstance,
    deviceName: _kFixtureDeviceName,
  );

  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  socket.listen((event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    // Drain every queued datagram: one `read` event can cover several, and
    // `receive()` returns null once the queue is empty.
    while (true) {
      Datagram? dg;
      try {
        dg = socket.receive();
      } catch (_) {
        return;
      }
      if (dg == null) {
        return;
      }
      try {
        final reply = dispatchBacnetDatagram(dg.data, image);
        if (reply == null) {
          // Malformed / unserved datagram: drop it, keep the bind alive.
          continue;
        }
        socket.send(reply, dg.address, dg.port);
      } catch (_) {
        // One bad datagram must never wedge the bind.
      }
    }
  });

  // ignore: avoid_print
  print('READY bacnet-udp://127.0.0.1:${socket.port}');

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit; SIGTERM
  // is intentionally NOT watched (unsupported on Windows and throws
  // asynchronously if attempted) — the E2E harness (`tool/bacnet_e2e.sh`)
  // simply kills this process outright when done, which is fine for a
  // short-lived fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  socket.close();
}
