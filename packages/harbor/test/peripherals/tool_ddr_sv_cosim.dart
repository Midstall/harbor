import 'dart:io';

import 'package:harbor/harbor.dart';

/// Emit the DDR3 controller SV for the iverilog pin-level cosim.
///
/// This targets the reverted clk90 ECP5 DDR PHY (single-clock DLL-off
/// bring-up controller). Two write-path variants are emitted:
///   ddr_controller_mpr.sv    - mprDebug=true:  reads return the MPR pattern
///   ddr_controller_array.sv  - mprDebug=false: reads return the array
///
/// Usage: dart run test/peripherals/tool_ddr_sv_cosim.dart <outdir>
Future<void> main(List<String> args) async {
  final outDir = Directory(args.isNotEmpty ? args[0] : '/tmp/ddrcosim')
    ..createSync(recursive: true);

  Future<void> emit(String name, {required bool mprDebug}) async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
      // clkMhz is derived from clockHz, 24MHz matches the OrangeCrab DLL-off
      // bring-up clock the 3 in-tree PHY fixes were calibrated against.
      clockHz: 24000000,
      busAddressWidth: 28,
      mprDebug: mprDebug,
    );
    await ddr.build();
    File('${outDir.path}/$name').writeAsStringSync(ddr.generateSynth());
    stdout.writeln('wrote ${outDir.path}/$name (mprDebug=$mprDebug)');
  }

  await emit('ddr_controller_mpr.sv', mprDebug: true);
  await emit('ddr_controller_array.sv', mprDebug: false);
}
