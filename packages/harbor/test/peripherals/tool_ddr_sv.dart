import 'dart:io';

import 'package:harbor/harbor.dart';

/// Emit the DDR3 controller's SystemVerilog for the pin-level iverilog
/// bench: `dart run test/peripherals/tool_ddr_sv.dart <outdir>`.
Future<void> main(List<String> args) async {
  final outDir = Directory(args.isNotEmpty ? args[0] : '/tmp/ddr_sim')
    ..createSync(recursive: true);
  final ddr = HarborDdrController(
    config: const HarborDdrConfig.orangeCrab(),
    baseAddress: 0x80000000,
  );
  await ddr.build();
  File(
    '${outDir.path}/ddr_controller.sv',
  ).writeAsStringSync(ddr.generateSynth());
  stdout.writeln('wrote ${outDir.path}/ddr_controller.sv');
}
