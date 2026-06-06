import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration smoke tests for the DDR3 controller: the full
/// bus -> sequencer -> PHY -> pads chain must build and emit SystemVerilog
/// for the board configs. Functional verification runs in the pin-level
/// iverilog bench against a behavioral DDR3 model (not in this suite).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('DDR3 controller elaborates for the OrangeCrab config', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('DdrSequencer'));
    expect(sv, contains('DdrPhyEcp5'));
    expect(sv, contains('EHXPLLL'));
    expect(sv, contains('ODDRX1F'));
  });

  test('DDR3L controller elaborates for the Arty S7 config', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
    );
    await ddr.build();
    expect(ddr.generateSynth(), contains('DdrSequencer'));
  });
}
