import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the double line buffer: a system-clock write port fills one of two
/// buffers word-by-word. A (combinational) read port serves any buffer by
/// column. Because scanout double-buffers, the buffer being read is never the
/// one being written, so the read can cross into the pixel domain safely. Here
/// the read clock differs from the write clock to exercise that crossing.
void main() {
  test('writes one buffer and reads it back across clocks', () async {
    final wrClk = SimpleClockGenerator(10).clk;
    final rdClk = SimpleClockGenerator(14).clk; // different domain

    final wrEn = Logic(name: 'wr_en');
    final wrSel = Logic(name: 'wr_sel');
    final wrIdx = Logic(name: 'wr_idx', width: 2);
    final wrData = Logic(name: 'wr_data', width: 32);
    final rdSel = Logic(name: 'rd_sel');
    final rdCol = Logic(name: 'rd_col', width: 2);

    final lb = HarborDoubleLineBuffer(
      wrClk: wrClk,
      wrEn: wrEn,
      wrSel: wrSel,
      wrIdx: wrIdx,
      wrData: wrData,
      rdSel: rdSel,
      rdCol: rdCol,
      maxWords: 4,
    );
    await lb.build();

    wrEn.inject(0);
    wrSel.inject(0);
    wrIdx.inject(0);
    wrData.inject(0);
    rdSel.inject(0);
    rdCol.inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await rdClk.nextPosedge;

    // Fill buffer 0 with 0xA0, 0xA1, 0xA2, 0xA3 on the write clock.
    for (var i = 0; i < 4; i++) {
      wrSel.inject(0);
      wrIdx.inject(i);
      wrData.inject(0xA0 + i);
      wrEn.inject(1);
      await wrClk.nextPosedge;
    }
    wrEn.inject(0);
    // Fill buffer 1 with different data to prove the buffers are independent.
    for (var i = 0; i < 4; i++) {
      wrSel.inject(1);
      wrIdx.inject(i);
      wrData.inject(0xB0 + i);
      wrEn.inject(1);
      await wrClk.nextPosedge;
    }
    wrEn.inject(0);
    await wrClk.nextNegedge;

    // Read buffer 0 from the read-clock domain.
    rdSel.inject(0);
    for (var i = 0; i < 4; i++) {
      rdCol.inject(i);
      await rdClk.nextPosedge;
      await rdClk.nextNegedge;
      expect(lb.rdData.value.toInt(), equals(0xA0 + i), reason: 'buf0[$i]');
    }
    // Read buffer 1.
    rdSel.inject(1);
    for (var i = 0; i < 4; i++) {
      rdCol.inject(i);
      await rdClk.nextPosedge;
      await rdClk.nextNegedge;
      expect(lb.rdData.value.toInt(), equals(0xB0 + i), reason: 'buf1[$i]');
    }

    await Simulator.endSimulation();
    Simulator.reset();
  });
}
