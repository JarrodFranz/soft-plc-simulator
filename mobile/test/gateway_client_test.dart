import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:soft_plc_mobile/models/gateway_sync.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/services/gateway_client.dart';

/// A fake [WebSocketChannel] backed by a [StreamChannelController] so tests
/// can capture every frame the client sends (via [sentFrames]) and push
/// inbound frames into the client (via [controller.local.sink.add]) without
/// touching a real socket.
class FakeWebSocketChannel with StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeWebSocketChannel() : _controller = StreamChannelController<String>() {
    // Drain the "server-side" (local) stream with a no-op listener so that
    // closing the client-facing sink (`foreign.sink`, which the fake's
    // `sink` wraps) can actually complete: a single-subscription
    // StreamController's `close()` future only resolves once a listener has
    // drained it.
    _controller.local.stream.listen((_) {});
  }

  final StreamChannelController<String> _controller;
  final List<String> sentFrames = [];

  /// Push a frame from the "server" (gateway) down to the client under test.
  void pushFromServer(String frame) => _controller.local.sink.add(frame);

  /// Simulate the socket erroring out.
  void emitError(Object error) => _controller.local.sink.addError(error);

  /// Simulate the socket closing.
  void closeFromServer() => _controller.local.sink.close();

  @override
  Stream<dynamic> get stream => _controller.foreign.stream;

  @override
  WebSocketSink get sink => _FakeSink(_controller.foreign.sink, sentFrames);

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._inner, this._sentFrames);
  final StreamSink<String> _inner;
  final List<String> _sentFrames;

  @override
  void add(dynamic data) {
    _sentFrames.add(data as String);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream stream) => _inner.addStream(stream.cast<String>());

  @override
  Future close([int? closeCode, String? closeReason]) => _inner.close();

  @override
  Future get done => _inner.done;
}

PlcProject _projectWithTags() {
  final project = PlcProject(
    id: 'proj_gw_test',
    name: 'Gateway Test Project',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Start_PB',
        path: 'Inputs.Start_PB',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Motor_Run',
        path: 'Outputs.Motor_Run',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedOutput',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  return project;
}

/// A project with a single FLOAT64 tag, used to test inbound-write value
/// coercion in isolation (kept separate from [_projectWithTags] so it
/// doesn't change the exposed-tag counts asserted by other tests).
PlcProject _projectWithFloatTag() {
  return PlcProject(
    id: 'proj_gw_float_test',
    name: 'Gateway Float Test Project',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Setpoint_Temp',
        path: 'Internal.Setpoint_Temp',
        dataType: 'FLOAT64',
        value: 0.0,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
}

void main() {
  group('GatewayClient', () {
    late FakeWebSocketChannel fakeChannel;
    late GatewayClient client;

    setUp(() {
      fakeChannel = FakeWebSocketChannel();
      client = GatewayClient(connect: (uri) => fakeChannel);
    });

    tearDown(() {
      client.dispose();
    });

    test('connect sends hello then snapshot with exposed tags', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);

      expect(fakeChannel.sentFrames.length, greaterThanOrEqualTo(2));
      final first = decodeMessage(fakeChannel.sentFrames[0]);
      final second = decodeMessage(fakeChannel.sentFrames[1]);
      expect(first, isA<HelloMsg>());
      expect(second, isA<SnapshotMsg>());

      final snapshot = second as SnapshotMsg;
      expect(snapshot.tags.length, 2);
      final paths = snapshot.tags.map((t) => t.path).toSet();
      expect(paths, {'Start_PB', 'Motor_Run'});

      final motorTag = snapshot.tags.firstWhere((t) => t.path == 'Motor_Run');
      expect(motorTag.access, 'ReadOnly');
      final startTag = snapshot.tags.firstWhere((t) => t.path == 'Start_PB');
      expect(startTag.access, 'ReadWrite');

      expect(client.status, GatewayStatus.connected);
      expect(client.exposedTagCount, 2);
    });

    test('syncTags sends a delta containing only the changed exposed tag', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);
      fakeChannel.sentFrames.clear();

      // No change yet -> no delta.
      client.syncTags(project);
      expect(fakeChannel.sentFrames, isEmpty);

      // Change one exposed tag's value.
      writePath(project, 'Start_PB', true);
      client.syncTags(project);

      expect(fakeChannel.sentFrames.length, 1);
      final msg = decodeMessage(fakeChannel.sentFrames.first);
      expect(msg, isA<DeltaMsg>());
      final delta = msg as DeltaMsg;
      expect(delta.changes.length, 1);
      expect(delta.changes.first.path, 'Start_PB');
      expect(delta.changes.first.value, true);

      // Sync again with no further change -> nothing sent.
      fakeChannel.sentFrames.clear();
      client.syncTags(project);
      expect(fakeChannel.sentFrames, isEmpty);
    });

    test('inbound WriteMsg applies the value to the tag', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);

      fakeChannel.pushFromServer(encodeMessage(const WriteMsg(path: 'Start_PB', value: true)));
      await pumpEventQueue();

      expect(readPath(project, 'Start_PB'), true);
    });

    test('inbound WriteMsg coerces an integral JSON number to double for a FLOAT64 tag', () async {
      final project = _projectWithFloatTag();
      await client.connect('ws://localhost:4855', project);

      // Simulate a Rust/serde_json gateway sending an integral number (`5`,
      // a JSON/Dart int) for a FLOAT64 tag: the value must be coerced to a
      // double so the tag's runtime type stays consistent with its
      // declared dataType.
      fakeChannel.pushFromServer(encodeMessage(const WriteMsg(path: 'Setpoint_Temp', value: 5)));
      await pumpEventQueue();

      final result = readPath(project, 'Setpoint_Temp');
      expect(result, isA<double>());
      expect(result, 5.0);
    });

    test('inbound WriteMsg is force-aware: a forced root tag is not overwritten', () async {
      final project = _projectWithTags();
      final startTag = project.tags.firstWhere((t) => t.name == 'Start_PB');
      startTag.isForced = true;
      startTag.value = false;

      await client.connect('ws://localhost:4855', project);

      fakeChannel.pushFromServer(encodeMessage(const WriteMsg(path: 'Start_PB', value: true)));
      await pumpEventQueue();

      expect(readPath(project, 'Start_PB'), false);
    });

    test('inbound PingMsg triggers an outbound PongMsg', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);
      fakeChannel.sentFrames.clear();

      fakeChannel.pushFromServer(encodeMessage(const PingMsg()));
      await pumpEventQueue();

      expect(fakeChannel.sentFrames.length, 1);
      expect(decodeMessage(fakeChannel.sentFrames.first), isA<PongMsg>());
    });

    test('status transitions disconnected -> connecting -> connected', () async {
      final project = _projectWithTags();
      expect(client.status, GatewayStatus.disconnected);

      final future = client.connect('ws://localhost:4855', project);
      expect(client.status, GatewayStatus.connecting);

      await future;
      expect(client.status, GatewayStatus.connected);
    });

    test('a socket error moves status to error and never throws', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);

      fakeChannel.emitError(Exception('boom'));
      await pumpEventQueue();

      expect(client.status, GatewayStatus.error);
      expect(client.lastError, isNotNull);
    });

    test('disconnect closes the channel and sets status disconnected', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);

      await client.disconnect();
      expect(client.status, GatewayStatus.disconnected);
    });

    test('reconnect re-sends hello+snapshot', () async {
      final project = _projectWithTags();
      await client.connect('ws://localhost:4855', project);
      await client.disconnect();

      // Each reconnect opens a fresh channel (as a real socket reconnect
      // would) via the injected factory, since a WebSocketChannel's stream
      // is single-subscription and can't be relistened.
      final channels = <FakeWebSocketChannel>[];
      client = GatewayClient(connect: (uri) {
        final c = FakeWebSocketChannel();
        channels.add(c);
        return c;
      });
      await client.connect('ws://localhost:4855', project);
      await client.reconnect(project);

      expect(channels.length, 2);
      final firstDecoded = channels[0].sentFrames.map(decodeMessage).toList();
      final secondDecoded = channels[1].sentFrames.map(decodeMessage).toList();
      expect(firstDecoded.whereType<HelloMsg>().length, 1);
      expect(firstDecoded.whereType<SnapshotMsg>().length, 1);
      expect(secondDecoded.whereType<HelloMsg>().length, 1);
      expect(secondDecoded.whereType<SnapshotMsg>().length, 1);
    });

    test('falls back to OpcuaMap.autoGenerate when project.opcuaMap is null', () async {
      final project = _projectWithTags();
      expect(project.opcuaMap, isNull);
      await client.connect('ws://localhost:4855', project);

      final snapshot = decodeMessage(fakeChannel.sentFrames[1]) as SnapshotMsg;
      expect(snapshot.tags.length, 2);
    });

    test('uses project.opcuaMap when present instead of auto-generating', () async {
      final project = _projectWithTags();
      project.opcuaMap = OpcuaMap(namespaceUri: 'urn:test', nodes: [
        OpcuaNode(nodeId: 'ns=1;s=Start_PB', tag: 'Start_PB', access: 'ReadOnly'),
      ]);
      await client.connect('ws://localhost:4855', project);

      final snapshot = decodeMessage(fakeChannel.sentFrames[1]) as SnapshotMsg;
      expect(snapshot.tags.length, 1);
      expect(snapshot.tags.first.path, 'Start_PB');
      expect(snapshot.tags.first.access, 'ReadOnly');
    });
  });
}
