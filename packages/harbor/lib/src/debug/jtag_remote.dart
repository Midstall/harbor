import 'dart:async';
import 'dart:io';

import 'package:rohd/rohd.dart';

/// Remote bitbang JTAG server for simulation.
///
/// Opens a TCP socket that speaks the OpenOCD remote bitbang protocol.
/// Connect with OpenOCD using:
///
/// ```
/// adapter speed 10000
/// adapter driver remote_bitbang
/// remote_bitbang_host localhost
/// remote_bitbang_port 44853
/// ```
///
/// Protocol:
/// - '0'-'7': set {TCK, TMS, TDI} as 3-bit value
/// - 'R': read TDO, respond with '0' or '1'
/// - 'Q': quit
///
/// ```dart
/// final jtag = JtagRemote(
///   tck: tapModule.input('tck'),
///   tms: tapModule.input('tms'),
///   tdi: tapModule.input('tdi'),
///   tdo: tapModule.output('tdo'),
/// );
///
/// await jtag.start();
/// // ... run simulation ...
/// await jtag.stop();
/// ```
class JtagRemote {
  /// TCP port to listen on.
  final int port;

  /// JTAG signals to drive/read.
  final Logic tck;
  final Logic tms;
  final Logic tdi;
  final Logic tdo;

  /// Optional callback invoked after each JTAG signal change.
  /// Use this to advance the simulation clock.
  final Future<void> Function()? onTick;

  ServerSocket? _server;
  Socket? _client;
  bool _running = false;

  /// Default OpenOCD remote bitbang port.
  static const defaultPort = 44853;

  JtagRemote({
    required this.tck,
    required this.tms,
    required this.tdi,
    required this.tdo,
    this.port = defaultPort,
    this.onTick,
  });

  /// Starts the remote bitbang server.
  ///
  /// Listens for TCP connections and processes JTAG commands.
  /// Returns when [stop] is called.
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _running = true;

    print('JTAG remote bitbang server listening on port $port');
    print('Connect with: remote_bitbang_port $port');

    await for (final client in _server!) {
      if (!_running) break;

      _client = client;
      client.setOption(SocketOption.tcpNoDelay, true);
      print('JTAG remote bitbang: client connected');

      // A write to the socket (the 'R' TDO response) is buffered and flushed
      // asynchronously. If the peer (OpenOCD) closes the connection while a
      // write is in flight, the failure surfaces on the sink's `done` future
      // rather than at the `add` call site, so it escapes the try/catch below
      // and would otherwise crash the whole simulation. Swallow it here and
      // treat it as a normal disconnect.
      unawaited(client.done.catchError((Object _) => client));

      try {
        await _handleClient(client);
      } catch (e) {
        if (_running) print('JTAG remote bitbang error: $e');
      }

      _client = null;
      print('JTAG remote bitbang: client disconnected');
    }
  }

  /// Stops the server and closes connections.
  Future<void> stop() async {
    _running = false;
    await _client?.close();
    await _server?.close();
    _server = null;
    _client = null;
  }

  Future<void> _handleClient(Socket client) async {
    await for (final data in client) {
      if (!_running) break;

      for (final byte in data) {
        if (byte >= 0x30 && byte <= 0x37) {
          // '0'-'7': set TCK/TMS/TDI
          final val_ = byte - 0x30;
          tck.inject((val_ >> 2) & 1);
          tms.inject((val_ >> 1) & 1);
          tdi.inject(val_ & 1);

          if (onTick != null) await onTick!();
        } else if (byte == 0x52) {
          // 'R': read TDO
          final tdoVal = tdo.value.isValid ? tdo.value.toInt() : 0;
          client.add([tdoVal == 1 ? 0x31 : 0x30]); // '1' or '0'
        } else if (byte == 0x51) {
          // 'Q': quit
          await client.close();
          return;
        }
      }
    }
  }
}

/// Convenience function to create and start a JTAG remote server
/// attached to a module's JTAG pins.
///
/// ```dart
/// final server = await startJtagRemote(
///   tck: dut.input('tck'),
///   tms: dut.input('tms'),
///   tdi: dut.input('tdi'),
///   tdo: dut.output('tdo'),
/// );
/// // ... run simulation ...
/// await server.stop();
/// ```
Future<JtagRemote> startJtagRemote({
  required Logic tck,
  required Logic tms,
  required Logic tdi,
  required Logic tdo,
  int port = JtagRemote.defaultPort,
  Future<void> Function()? onTick,
}) async {
  final server = JtagRemote(
    tck: tck,
    tms: tms,
    tdi: tdi,
    tdo: tdo,
    port: port,
    onTick: onTick,
  );
  // Start in background - don't await, it runs until stop()
  unawaited(server.start());
  return server;
}
