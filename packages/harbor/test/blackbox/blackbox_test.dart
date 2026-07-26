import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('iCE40 blackbox', () {
    test('SB_PLL40_CORE creates correctly', () {
      final pll = Ice40SbPll40Core(divr: 0, divf: 47, divq: 4, filterRange: 1);
      expect(pll.definitionName, equals('SB_PLL40_CORE'));
    });

    test('SB_PLL40_PAD creates correctly', () {
      final pll = Ice40SbPll40Pad(divr: 0, divf: 47, divq: 4, filterRange: 1);
      expect(pll.definitionName, equals('SB_PLL40_PAD'));
    });

    test('SB_GB creates correctly', () {
      final gb = Ice40SbGb();
      expect(gb.definitionName, equals('SB_GB'));
    });

    test('SB_IO creates correctly', () {
      final io = Ice40SbIo(pinType: '010000');
      expect(io.definitionName, equals('SB_IO'));
    });

    test('SB_RAM40_4K creates correctly', () {
      final ram = Ice40SbRam40_4k();
      expect(ram.definitionName, equals('SB_RAM40_4K'));
    });

    test('SB_SPRAM256KA creates correctly', () {
      final spram = Ice40SbSpram256ka();
      expect(spram.definitionName, equals('SB_SPRAM256KA'));
    });
  });

  group('ECP5 blackbox', () {
    test('EHXPLLL creates correctly', () {
      final pll = Ecp5Ehxplll(
        clkiDiv: 1,
        clkfbDiv: 4,
        clkopDiv: 12,
        clk: Logic(),
        clkfb: Logic(),
      );
      expect(pll.definitionName, equals('EHXPLLL'));
    });

    test('DCCA creates correctly', () {
      final dcca = Ecp5Dcca();
      expect(dcca.definitionName, equals('DCCA'));
    });

    test('DP16KD creates correctly', () {
      final bram = Ecp5Dp16kd(
        clkA: Logic(),
        ceA: Logic(),
        weA: Logic(),
        oceA: Logic(),
        rstA: Logic(),
        adA: Logic(width: 14),
        diA: Logic(width: 18),
        clkB: Logic(),
        ceB: Logic(),
        weB: Logic(),
        oceB: Logic(),
        rstB: Logic(),
        adB: Logic(width: 14),
        diB: Logic(width: 18),
      );
      expect(bram.definitionName, equals('DP16KD'));
    });

    test('JTAGG creates correctly', () {
      final jtag = Ecp5Jtagg();
      expect(jtag.definitionName, equals('JTAGG'));
    });

    test('IO buffers create correctly', () {
      expect(
        Ecp5Bb(i: Logic(), t: Logic(), b: LogicNet()).definitionName,
        equals('BB'),
      );
      expect(Ecp5Ib().definitionName, equals('IB'));
      expect(Ecp5Ob().definitionName, equals('OB'));
    });
  });

  group('Xilinx 7-series blackbox', () {
    test('MMCME2_ADV creates correctly', () {
      final mmcm = XilinxMmcme2Adv(
        clkfboutMult: 10.0,
        clkout0Divide: 5.0,
        divclkDivide: 1.0,
        clkinPeriod: 10.0,
      );
      expect(mmcm.definitionName, equals('MMCME2_ADV'));
    });

    test('BUFG creates correctly', () {
      final bufg = XilinxBufg();
      expect(bufg.definitionName, equals('BUFG'));
    });

    test('IO buffers create correctly', () {
      expect(XilinxIbuf().definitionName, equals('IBUF'));
      expect(XilinxObuf().definitionName, equals('OBUF'));
      expect(XilinxIobuf().definitionName, equals('IOBUF'));
    });

    test('RAMB36E1 creates correctly', () {
      final bram = XilinxRamb36e1();
      expect(bram.definitionName, equals('RAMB36E1'));
    });

    test('BSCANE2 creates correctly', () {
      final bscan = XilinxBscane2(jtagChain: 2);
      expect(bscan.definitionName, equals('BSCANE2'));
    });

    test('DSP48E1 creates correctly', () {
      final dsp = XilinxDsp48e1();
      expect(dsp.definitionName, equals('DSP48E1'));
    });
  });
}
