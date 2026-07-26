import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborBoard registry', () {
    test('get resolves the ulx3s-85f preset', () {
      final board = HarborBoard.get('ulx3s-85f');
      expect(board.name, equals('ulx3s-85f'));
      expect(board.vendor, equals(HarborFpgaVendor.ecp5));
      expect(board.device, equals('lfe5u-85f'));
      expect(board.package, equals('CABGA381'));
      expect(board.oscillatorHz, equals(25000000));
    });

    test('get throws on an unknown board', () {
      expect(() => HarborBoard.get('nope-1'), throwsArgumentError);
    });

    test('the ulx3s preset has a programming command', () {
      expect(HarborBoard.get('ulx3s-85f').progCommand, isNotNull);
    });

    test('the ulx3s preset exposes the GPDI pins (LVCMOS33D)', () {
      final pins = HarborBoard.get('ulx3s-85f').pins;
      expect(pins['gpdi_dp[0]'], startsWith('A16'));
      expect(pins['gpdi_dp[1]'], startsWith('A14'));
      expect(pins['gpdi_dp[2]'], startsWith('A12'));
      expect(pins['gpdi_dp[3]'], startsWith('A17')); // clock pair
      expect(pins['gpdi_dp[0]'], contains('LVCMOS33D'));
    });
  });

  group('HarborBoard.fpgaTarget', () {
    late HarborBoard board;

    setUp(() {
      board = HarborBoard.get('ulx3s-85f');
    });

    test('carries the board device, package, and vendor', () {
      final target = board.fpgaTarget();
      expect(target.vendor, equals(HarborFpgaVendor.ecp5));
      expect(target.device, equals('lfe5u-85f'));
      expect(target.package, equals('CABGA381'));
    });

    test('frequency defaults to the board oscillator', () {
      expect(board.fpgaTarget().frequency, equals(25000000));
    });

    test('frequency can be overridden', () {
      expect(board.fpgaTarget(frequency: 50000000).frequency, equals(50000000));
    });

    test('selects only the requested pins from the catalog', () {
      final target = board.fpgaTarget(pins: ['clk', 'uart_tx']);
      expect(target.pinMap.keys, containsAll(['clk', 'uart_tx']));
      expect(target.pinMap.containsKey('uart_rx'), isFalse);
      // Sites come from the board catalog.
      expect(target.pinMap['clk'], startsWith('G2'));
    });

    test('all catalog pins are used when none are requested', () {
      final target = board.fpgaTarget();
      expect(target.pinMap.keys, containsAll(['clk', 'uart_tx', 'uart_rx']));
    });

    test('extra pins merge in alongside catalog pins', () {
      final target = board.fpgaTarget(pins: ['clk'], extraPins: {'led0': 'B2'});
      expect(target.pinMap['led0'], equals('B2'));
      expect(target.pinMap.containsKey('clk'), isTrue);
    });

    test('throws when a requested pin is not in the catalog', () {
      expect(
        () => board.fpgaTarget(pins: ['nonexistent']),
        throwsArgumentError,
      );
    });

    test('threads the programming command into the target', () {
      final target = board.fpgaTarget();
      final makefile = target.generateMakefile('my_soc');
      expect(makefile, contains('prog:'));
      expect(makefile, contains('openFPGALoader'));
    });
  });

  group('HarborFpgaTarget programming and clock', () {
    test('no prog target without a progCommand', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-85f',
        package: 'CABGA381',
        pinMap: {'clk': 'G2'},
      );
      expect(target.generateMakefile('soc'), isNot(contains('prog:')));
    });

    test('clockPortName drives the LPF frequency constraint', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-85f',
        package: 'CABGA381',
        frequency: 25000000,
        pinMap: {'clk_in': 'G2'},
        clockPortName: 'clk_in',
      );
      expect(target.generateConstraints(), contains('FREQUENCY PORT "clk_in"'));
    });
  });
}
