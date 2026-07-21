// A tiny `dart run` CLI that hosts BACnet/IP over a real `RawDatagramSocket`
// (UDP), prints `READY` once bound, then serves until killed. Used by
// `tool/bacnet_e2e.sh` as the Dart half of the v1 BACnet/IP workstream's
// EARLY E2E machine-proof: a REAL third-party client — BAC0/bacpypes (or the
// `bacpypes3` fallback), driven by `tool/py/bacnet_probe.py` — discovers this
// fixture device via Who-Is/I-Am and reads one Analog Value's Present_Value,
// BEFORE the tag-backed object model exists.
//
// WHY A REAL CLIENT RUNS THIS EARLY: BACnet's APDU payloads are ASN.1-style
// TAGGED values (see `bacnet_tags.dart`'s "TAG-STRUCTURE TRAP" note) — a
// build-then-parse round trip through our OWN codec proves self-consistency,
// not conformance. This fixture is where a client written independently of us
// reads our wire bytes, and — crucially — reads a Present_Value (12.5) this
// fixture SEEDED into an Analog Value independently of the client, settling
// every open tag-encoding question before the real object model (a later
// task) is built on top of the same assumptions.
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
// (`protocols/bacnet/bacnet_dispatch.dart`) against a `BacnetObjectImage`. So
// the bytes the BAC0/bacpypes client validates here are, by construction
// rather than by diff, the same bytes the shipped app puts on the wire. Only
// the small `RawDatagramSocket` receive loop is re-implemented here.
//
// *** THE FIXTURE OBJECT MODEL ***
// A `BacnetSimpleImage` (`bacnet_dispatch.dart`) — a MINIMAL, hand-rolled
// image, NOT the tag-backed `BacnetTagImage` a later task builds: device
// instance 3056, Object_Name "BACNET-E2E-FIXTURE", one Analog Value instance
// 0 with a fixed Present_Value of 12.5. Every constant below is pinned in
// `tool/py/bacnet_probe.py`; keep the two files in step.
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

import 'package:soft_plc_mobile/protocols/bacnet/bacnet_dispatch.dart';

/// The fixture's Device_Object_Instance. Pinned in `tool/py/bacnet_probe.py`.
const int _kFixtureDeviceInstance = 3056;

/// The fixture's Object_Name. Pinned in `tool/py/bacnet_probe.py`.
const String _kFixtureDeviceName = 'BACNET-E2E-FIXTURE';

/// The fixture's single Analog Value instance number.
const int _kFixtureAvInstance = 0;

/// The fixture's Analog Value Present_Value — independently seeded so a real
/// client reading it back through its OWN parser is a true conformance check,
/// not a round trip. 12.5 is exactly representable in IEEE-754 single
/// precision, so no float32 narrowing blurs the assertion.
const double _kFixtureAvPresentValue = 12.5;

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

  final image = BacnetSimpleImage(
    deviceInstance: _kFixtureDeviceInstance,
    deviceName: _kFixtureDeviceName,
    analogValues: {_kFixtureAvInstance: _kFixtureAvPresentValue},
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
