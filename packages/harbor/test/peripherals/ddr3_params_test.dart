import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:test/test.dart';

void main() {
  group('DdrParams derived geometry', () {
    test('Arty S7 x16 @ 333 MHz derives a 128-bit wishbone over 256 MB', () {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      expect(p.serdesRatio, 4);
      expect(p.wbAddrBits, 24);
      expect(p.wbDataBits, 128); // 8 DQ * 2 lanes * 4:1 SERDES * DDR(2)
      expect(p.wbSelBits, 16);
      expect(p.sizeBytes, 256 * 1024 * 1024);
      expect(p.lanes, 2);
      expect(p.odelaySupported, isFalse); // Arty S7 HR bank
    });

    test('controller clock is 4x the CK for any CK period', () {
      for (final ck in [3000, 3333, 2500]) {
        final p = DdrParams.artyS7(ckPeriodPs: ck);
        expect(p.controllerClkPeriodPs, ck * 4);
        expect(p.serdesRatio, 4);
      }
    });

    test('x8 (lanes=1) halves the data width and capacity', () {
      const p = DdrParams(
        controllerClkPeriodPs: 12000,
        ddr3ClkPeriodPs: 3000,
        lanes: 1,
      );
      expect(p.wbDataBits, 64);
      expect(p.wbSelBits, 8);
      expect(p.sizeBytes, 128 * 1024 * 1024);
    });

    test('rejects non-DDR3 geometry', () {
      expect(
        () => DdrParams(
          controllerClkPeriodPs: 12000,
          ddr3ClkPeriodPs: 3000,
          dqBits: 4,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DdrParams(
          controllerClkPeriodPs: 12000,
          ddr3ClkPeriodPs: 3000,
          lanes: 4,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
