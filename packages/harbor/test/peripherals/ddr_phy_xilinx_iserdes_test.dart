import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('Arty S7 DDR controller read path uses IDDR, not ISERDESE2', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      target: const HarborFpgaTarget.spartan7(
        device: 's50',
        package: 'csga324',
      ),
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('DdrPhyXilinx'));
    expect(sv, contains('dq_iddr'));
    expect(sv, contains('DdrReadWordAssembler'));
    // ISERDESE2 is no longer instantiated in the read capture path.
    expect(
      sv,
      isNot(contains('dq_iserdes')),
      reason: 'the DQ ISERDESE2 capture must be replaced by IDDR',
    );
  });
}
