import 'dart:async';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('JtagRemote', () {
    late JtagRemote server;
    late Logic tdo;
    late int ticks;

    setUp(() async {
      tdo = Logic()..put(1); // TDO high so 'R' answers '1'
      ticks = 0;
      server = JtagRemote(
        tck: Logic(),
        tms: Logic(),
        tdi: Logic(),
        tdo: tdo,
        port: 0, // OS-assigned
        onTick: () async => ticks++,
      );
      unawaited(server.start());
      for (var i = 0; i < 200 && server.boundPort == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(server.boundPort, isNotNull);
    });

    tearDown(() => server.stop());

    test('one onTick per pin-change byte; R answers with TDO', () async {
      final sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort!,
      );
      final resp = <int>[];
      sock.listen(resp.addAll);
      // '0' '4' '2' set TCK/TMS/TDI (3 pin-changes), 'R' reads TDO.
      sock.add([0x30, 0x34, 0x32, 0x52]);
      await sock.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(ticks, 3);
      expect(resp, [0x31]); // '1'
      await sock.close();
    });

    test('a reconnect supersedes and tears down the previous client', () async {
      final a = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort!,
      );
      final aClosed = Completer<void>();
      void markClosed() {
        if (!aClosed.isCompleted) aClosed.complete();
      }

      a.listen((_) {}, onDone: markClosed, onError: (_) => markClosed());
      a.add([0x30]); // one pin-change
      await a.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ticks, 1);

      // B connects: the server must supersede A (close its socket) and serve B.
      final b = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort!,
      );
      b.listen((_) {});
      // The old client is torn down rather than left lingering.
      await aClosed.future.timeout(const Duration(seconds: 2));

      // B drives the simulator. The stale A handler does not.
      b.add([0x30, 0x30]);
      await b.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ticks, 3); // 1 from A + 2 from B
      await b.close();
    });
  });
}
