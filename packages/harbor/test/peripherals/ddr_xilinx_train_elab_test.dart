import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  const artyTarget = HarborFpgaTarget.spartan7(
    device: 's50',
    package: 'csga324',
  );

  test('trainableRead Arty build emits VARIABLE IDELAY + XilinxReadTrainRegs '
      '+ a runtime (non-const) fabric bitslip', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      trainableRead: true, // now allowed on the Xilinx PHY
      target: artyTarget,
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    // The MMIO decode unit is instantiated.
    expect(sv, contains('XilinxReadTrainRegs'));
    // The per-DQ IDELAYE2s are VAR_LOAD (absolute-tap runtime-loadable), not the
    // FIXED static-tap baseline.
    expect(sv, contains('.IDELAY_TYPE("VAR_LOAD")'));
    expect(
      sv,
      isNot(contains('.IDELAY_TYPE("FIXED")')),
      reason: 'every read IDELAY must be VAR_LOAD on the trainable build',
    );
    // The fabric bitslip select is now a runtime rotate register driven by the
    // train BITSLIP pulse, not the compile-time env const.
    expect(
      sv,
      contains('bitslip_sel'),
      reason: 'the fabric bitslip select must be a runtime net',
    );
    // The read path is still the routeable IDDR capture (ISERDESE2 is not
    // routeable on openXC7 xc7s50), just now trainable.
    expect(sv, contains('dq_iddr'));
  });

  test(
    'non-trainable Arty build keeps the FIXED static IDELAY, no train unit',
    () async {
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.artyS7(),
        baseAddress: 0x80000000,
        target: artyTarget,
      );
      await ddr.build();
      final sv = ddr.generateSynth();
      expect(sv, contains('.IDELAY_TYPE("FIXED")'));
      expect(sv, isNot(contains('.IDELAY_TYPE("VAR_LOAD")')));
      expect(sv, isNot(contains('XilinxReadTrainRegs')));
      expect(sv, isNot(contains('bitslip_sel')));
    },
  );
}
