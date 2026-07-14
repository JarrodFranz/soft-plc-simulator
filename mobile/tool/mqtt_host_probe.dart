// A tiny `dart run` CLI that builds a small fixture project in code (a
// forced BOOL, and two writable INT16s) and drives it as a real MQTT
// PUBLISHER client — dialing OUT to a broker (rather than listening, like
// the Modbus/OPC UA fixture hosts) — over a real `Socket`, using ONLY the
// pure protocol modules (`mqtt_codec.dart`/`mqtt_publisher.dart`/
// `mqtt_sparkplug.dart`), then prints `READY` once connected/birthed. Used
// by `gateway/examples/mqtt_probe.rs` (which embeds the broker itself and
// spawns this as a child process — see that file's doc comment for why the
// orchestration direction is inverted vs. `modbus_probe.rs`/`opcua_probe.rs`)
// as the Dart half of the WS-mqtt Task 6 E2E machine-proof, and by that
// workstream's earlier tasks as the fixture backing the forced-tag/
// report-by-exception/remote-write proofs below.
//
// IMPORTANT: this does NOT import `services/mqtt_host.dart`. `MqttHost
// extends ChangeNotifier` (`package:flutter/foundation.dart`), which
// transitively imports `dart:ui` (via `change_notifier.dart`,
// `diagnostics.dart`, `binding.dart`, ...) — unavailable under a plain
// `dart run` (confirmed empirically: attempting it fails to compile with
// "Dart library 'dart:ui' is not available on this platform"). This mirrors
// `mobile/tool/modbus_host_probe.dart`'s/`opcua_host_probe.dart`'s identical
// note for their own `dart:io` host classes — see those files. The wire
// codec (`mqtt_codec.dart`) and the publisher session logic
// (`mqtt_publisher.dart`) are pure Dart with zero Flutter dependency, so
// this tool reimplements the small connect/birth/tick/command loop
// `MqttHost` itself uses directly against those pure modules — see that
// file (`mobile/lib/services/mqtt_host.dart`) for the authoritative version
// this mirrors (bdSeq ordering, frame reassembly, etc.).
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Fixture project (must match the constants `gateway/examples/mqtt_probe.rs`
// hardcodes: controller name `PLC_E2E`, Sparkplug group id `SoftPLC`, edge
// node id `E2ENode`, base topic `softplc`):
//   - `Forced_Bool` : BOOL,  Internal, isForced=true/forcedValue=true,
//     map order 1 (alias 1 in Sparkplug) — NOT writable (read-only in the
//     map), the forced-value-reaches-telemetry proof.
//   - `Counter`     : INT16, Internal, initial 100, map order 2 (alias 2) —
//     mutated to 4242 at T+3s by this fixture's OWN timer, independently of
//     any client, the report-by-exception/NDATA "server-side change" proof.
//   - `Speed`       : INT16, Internal, initial 10, map order 3 (alias 3) —
//     writable, the remote-write round-trip target (JSON `/set` and
//     Sparkplug NCMD).
//
// Usage: dart run tool/mqtt_host_probe.dart <broker_port> <json|sparkplug> [clean_disconnect_after_ms]
//
// The optional third argument (`clean_disconnect_after_ms`) is the
// WS-mqtt-ndeath-on-disconnect E2E machine-proof: when present, this fixture
// self-initiates a CLEAN stop that many milliseconds after CONNACK, mirroring
// `MqttHost.disconnect()` (`mobile/lib/services/mqtt_host.dart`) step for
// step -- publish the Sparkplug B NDEATH death certificate (current session
// bdSeq, via `MqttPublisher.deathMessage`), flush, THEN send the MQTT
// DISCONNECT packet, flush, close the socket, and exit(0) on its own. This is
// deliberately NOT the same shutdown path as the bottom of `main` (SIGINT /
// being killed by `gateway/examples/mqtt_probe.rs`'s `kill_dart_fixture`,
// which sends no NDEATH at all) -- the whole point of this argument is to
// prove the fixture reaches a genuine clean stop under its own steam, so
// `mqtt_probe.rs` can assert a real subscriber sees the NDEATH arrive BEFORE
// the DISCONNECT, with the same bdSeq the NBIRTH carried.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart' show writePath;
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_codec.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_publisher.dart';

/// Value `Counter` is mutated to at T+3s after CONNACK, entirely
/// independently of any client write — what the Rust probe waits for on
/// telemetry/NDATA to prove a live server-side change (not a frozen
/// snapshot) reaches MQTT.
const int _mutatedCounterValue = 4242;

PlcProject _fixtureProject(int brokerPort, String format) {
  final project = PlcProject(
    id: 'proj_mqtt_e2e_fixture',
    name: 'MQTT E2E Fixture',
    controllerName: 'PLC_E2E',
    tags: [
      PlcTag(
        name: 'Forced_Bool',
        path: 'Internal.Forced_Bool',
        dataType: 'BOOL',
        value: false,
        ioType: 'Internal',
        isForced: true,
        forcedValue: true,
      ),
      PlcTag(
        name: 'Counter',
        path: 'Internal.Counter',
        dataType: 'INT16',
        value: 100,
        ioType: 'Internal',
      ),
      PlcTag(
        name: 'Speed',
        path: 'Internal.Speed',
        dataType: 'INT16',
        value: 10,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.mqtt = MqttProtocolConfig(
    enabled: true,
    host: '127.0.0.1',
    port: brokerPort,
    tls: false,
    format: format,
    baseTopic: 'softplc',
    groupId: 'SoftPLC',
    edgeNodeId: 'E2ENode',
    qos: 0,
    heartbeatSeconds: 1,
    allowRemoteWrites: true,
    map: MqttMap(entries: [
      MqttMapEntry(tag: 'Forced_Bool', metric: 'Forced_Bool', writable: false),
      MqttMapEntry(tag: 'Counter', metric: 'Counter', writable: true),
      MqttMapEntry(tag: 'Speed', metric: 'Speed', writable: true),
    ]),
  );
  return project;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/mqtt_host_probe.dart <broker_port> <json|sparkplug> [clean_disconnect_after_ms]');
    exit(64);
  }
  final brokerPort = int.tryParse(args[0]);
  final format = args[1];
  final cleanDisconnectAfterMs = args.length >= 3 ? int.tryParse(args[2]) : null;
  if (brokerPort == null ||
      brokerPort <= 0 ||
      brokerPort > 65535 ||
      (format != 'json' && format != 'sparkplug') ||
      (args.length >= 3 && cleanDisconnectAfterMs == null)) {
    stderr.writeln('invalid arguments: ${args.join(' ')}');
    exit(64);
  }

  final project = _fixtureProject(brokerPort, format);
  final cfg = project.protocols!.mqtt!;
  final publisher = MqttPublisher();
  final clock = Stopwatch()..start();
  final frameBuffer = MqttFrameBuffer();
  final done = Completer<void>();
  var connacked = false;

  // MUST run before a single CONNECT byte is sent — this both computes the
  // Will (unused by this probe's assertions, but included so bdSeq advances
  // exactly like the real host: `mqtt_host.dart`'s "bdSeq ordering") AND
  // advances `_bdSeq` to 1, which the following birth reads unchanged — see
  // `mqtt_publisher.dart`'s doc comment.
  final will = publisher.willMessage(project);

  Socket socket;
  try {
    socket = await Socket.connect('127.0.0.1', brokerPort, timeout: const Duration(seconds: 10));
  } catch (e) {
    stderr.writeln('FAILED TO CONNECT: $e');
    exit(1);
  }

  void sendAll(List<MqttPublishDescriptor> ds) {
    for (final d in ds) {
      try {
        socket.add(encodePublish(topic: d.topic, payload: d.payload, qos: d.qos, retain: d.retain));
      } catch (_) {
        // Best-effort: a broker connection dropping mid-send shouldn't crash
        // this short-lived fixture.
      }
    }
  }

  final connectPacket = encodeConnect(
    clientId: 'softplc-e2e-fixture',
    keepAliveSecs: 60,
    cleanSession: true,
    willTopic: will?.topic,
    willPayload: will?.payload,
    willRetain: will?.retain ?? false,
    willQos: will?.qos ?? 0,
  );
  socket.add(connectPacket);

  socket.listen(
    (data) {
      try {
        final packets = frameBuffer.add(data);
        for (final packet in packets) {
          if (packet.isEmpty) continue;
          final type = (packet[0] >> 4) & 0x0F;
          if (type == MqttPacketType.connack) {
            if (connacked) continue;
            final connack = parseConnack(packet);
            if (connack == null || connack.returnCode != 0) {
              stderr.writeln('CONNACK rejected/malformed: $connack');
              exit(1);
            }
            connacked = true;
            final nowMs = clock.elapsedMilliseconds;
            sendAll(publisher.birthMessages(project, nowMs));
            // Immediate post-birth telemetry snapshot: for JSON, birth only
            // carries retained status — this is what puts Forced_Bool's
            // (and every other mapped tag's) value on the wire right away,
            // for the "forced value reaches telemetry" proof. For
            // Sparkplug, NBIRTH already carries every metric, so this is a
            // harmless extra NDATA the probe's alias/value-specific waits
            // simply don't match against until the later, real change.
            sendAll(publisher.heartbeatPublishes(project, nowMs));
            final filters = publisher.commandTopicFilters(project);
            if (filters.isNotEmpty) {
              socket.add(encodeSubscribe(
                packetId: 1,
                topicFilters: filters.map((f) => MqttTopicFilter(f, qos: cfg.qos)).toList(),
              ));
            }
            // ignore: avoid_print
            print('READY MQTT_E2E_FIXTURE $format');

            if (cleanDisconnectAfterMs != null) {
              Timer(Duration(milliseconds: cleanDisconnectAfterMs), () async {
                // Mirrors `MqttHost.disconnect()` exactly: NDEATH (current
                // session bdSeq, via `deathMessage` -- does NOT re-advance
                // bdSeq) published and flushed BEFORE the MQTT DISCONNECT,
                // because a clean DISCONNECT tells the broker to suppress
                // the registered Will. Best-effort, like the real host.
                try {
                  final death = publisher.deathMessage(project, clock.elapsedMilliseconds);
                  if (death != null) {
                    socket.add(encodePublish(
                      topic: death.topic,
                      payload: death.payload,
                      qos: death.qos,
                      retain: death.retain,
                    ));
                    await socket.flush();
                  }
                } catch (_) {
                  // Ignore -- best-effort death notice only.
                }
                try {
                  socket.add(encodeDisconnect());
                  await socket.flush();
                } catch (_) {
                  // Ignore -- best-effort graceful notice only.
                }
                // ignore: avoid_print
                print('CLEAN_DISCONNECT_DONE');
                await socket.close();
                exit(0);
              });
            }
          } else if (type == MqttPacketType.publish) {
            final pub = parsePublish(packet);
            if (pub == null) continue;
            final commands = publisher.decodeCommand(pub.topic, pub.payload, project);
            for (final cmd in commands) {
              writePath(project, cmd.tagPath, cmd.value);
            }
          }
          // SUBACK/PINGRESP/others: nothing this fixture needs to react to.
        }
      } catch (e) {
        stderr.writeln('(non-fatal) error handling inbound data: $e');
      }
    },
    onError: (Object e, StackTrace _) => stderr.writeln('socket error: $e'),
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: false,
  );

  // WS-mqtt Task 6 E2E: mutate `Counter` server-side, entirely independently
  // of any client connection, on a fixed schedule after CONNACK. This is
  // what `gateway/examples/mqtt_probe.rs` waits for on telemetry/NDATA.
  Timer(const Duration(seconds: 3), () {
    writePath(project, 'Counter', _mutatedCounterValue);
    // ignore: avoid_print
    print('[fixture host] mutated Counter -> $_mutatedCounterValue at T+3s');
  });

  // Periodic report-by-exception tick — the same mechanism `mqtt_host.dart`
  // uses (there on a 50ms timer; 250ms is plenty for this short-lived,
  // low-traffic fixture) — picks up both the T+3s mutation above and any
  // inbound remote-write command applied via `decodeCommand` above.
  Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (!connacked) return;
    try {
      sendAll(publisher.changedPublishes(project, clock.elapsedMilliseconds));
    } catch (e) {
      stderr.writeln('(non-fatal) tick error: $e');
    }
  });

  // Serve until killed — SIGINT watched for a graceful Ctrl+C exit;
  // otherwise `gateway/examples/mqtt_probe.rs` kills this process outright
  // when its assertions are done, fine for a short-lived fixture with no
  // state to flush (mirrors `modbus_host_probe.dart`'s identical note).
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  try {
    socket.add(encodeDisconnect());
  } catch (_) {
    // Ignore.
  }
  await socket.close();
}
