import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('ECP5', () {
    test('Ecp5Ehxplll creates', () {
      final pll = Ecp5Ehxplll(
        clkiDiv: 1,
        clkfbDiv: 4,
        clkopDiv: 12,
        clk: Logic(),
        clkfb: Logic(),
      );
      expect(pll, isNotNull);
      expect(pll.definitionName, equals('EHXPLLL'));
    });

    test('Ecp5Dcca creates', () {
      final dcca = Ecp5Dcca();
      expect(dcca, isNotNull);
      expect(dcca.definitionName, equals('DCCA'));
    });

    test('Ecp5Bb creates', () {
      final bb = Ecp5Bb(i: Logic(), t: Logic(), b: LogicNet());
      expect(bb, isNotNull);
      expect(bb.definitionName, equals('BB'));
    });

    test('Ecp5Dtr creates (has DTROUT8 output width=8)', () {
      final dtr = Ecp5Dtr();
      expect(dtr, isNotNull);
      expect(dtr.output('DTROUT8').width, equals(8));
    });
  });

  group('Xilinx', () {
    test('XilinxMmcme2Adv creates', () {
      final mmcm = XilinxMmcme2Adv(
        clkfboutMult: 10.0,
        clkout0Divide: 5.0,
        divclkDivide: 1.0,
        clkinPeriod: 10.0,
      );
      expect(mmcm, isNotNull);
      expect(mmcm.definitionName, equals('MMCME2_ADV'));
    });

    test('XilinxBufg creates', () {
      final bufg = XilinxBufg();
      expect(bufg, isNotNull);
      expect(bufg.definitionName, equals('BUFG'));
    });

    test('XilinxXadc creates (has DO output width=16, DRDY output)', () {
      final xadc = XilinxXadc();
      expect(xadc, isNotNull);
      expect(xadc.output('DO').width, equals(16));
      expect(xadc.output('DRDY').width, equals(1));
    });

    test('XilinxDsp48e1 creates', () {
      final dsp = XilinxDsp48e1();
      expect(dsp, isNotNull);
      expect(dsp.definitionName, equals('DSP48E1'));
    });
  });

  group('iCE40', () {
    test('Ice40SbPll40Core creates', () {
      final pll = Ice40SbPll40Core(divr: 0, divf: 47, divq: 4, filterRange: 1);
      expect(pll, isNotNull);
      expect(pll.definitionName, equals('SB_PLL40_CORE'));
    });

    test('Ice40SbGb creates', () {
      final gb = Ice40SbGb();
      expect(gb, isNotNull);
      expect(gb.definitionName, equals('SB_GB'));
    });

    test('Ice40SbIo creates', () {
      final io = Ice40SbIo(pinType: '010000');
      expect(io, isNotNull);
      expect(io.definitionName, equals('SB_IO'));
    });

    test('Ice40SbRam40_4k creates', () {
      final ram = Ice40SbRam40_4k();
      expect(ram, isNotNull);
      expect(ram.definitionName, equals('SB_RAM40_4K'));
    });

    test('Ice40SbSpram256ka creates', () {
      final spram = Ice40SbSpram256ka();
      expect(spram, isNotNull);
      expect(spram.definitionName, equals('SB_SPRAM256KA'));
    });
  });
}
