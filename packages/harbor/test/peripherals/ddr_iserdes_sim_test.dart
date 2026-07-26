import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'IserdesE2SimModel groups two DQ samples into Q1/Q2 at 1-cycle latency',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final ddly = Logic(name: 'ddly');
      final bitslip = Logic(name: 'bitslip');
      final reset = Logic(name: 'reset');
      final dut = IserdesE2SimModel(
        clk,
        ddly: ddly,
        bitslip: bitslip,
        reset: reset,
      );
      await dut.build();

      ddly.inject(0);
      bitslip.inject(0);
      reset.inject(1);
      Simulator.setMaxSimTime(2000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      reset.inject(0);
      // Drive the sample stream 1,0 (rise=1, fall=0).
      ddly.inject(1);
      await clk.nextPosedge; // shift in 1
      ddly.inject(0);
      await clk.nextPosedge; // shift in 0; pair {sr[1]=1, sr[0]=0}
      await clk.nextNegedge;
      // Real ISERDESE2 convention: Q1 = NEWER (0), Q2 = OLDER (1).
      expect(dut.q1.value.toInt(), 0);
      expect(dut.q2.value.toInt(), 1);

      // Pulse bitslip -> the pairing rotates (Q1/Q2 swap).
      bitslip.inject(1);
      await clk.nextPosedge;
      bitslip.inject(0);
      ddly.inject(1);
      await clk.nextPosedge;
      ddly.inject(0);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(dut.q1.value.toInt(), 1); // swapped
      expect(dut.q2.value.toInt(), 0);

      await Simulator.endSimulation();
    },
  );
}
