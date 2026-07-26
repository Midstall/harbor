import 'package:rohd/rohd.dart';

/// Two line buffers with a system-clock write port and a combinational read
/// port, the clock-domain-crossing element of framebuffer scanout.
///
/// The framebuffer DMA (system clock) bursts a scanline into the buffer
/// selected by [wrSel], the scanout (pixel clock) reads the buffer selected by
/// [rdSel] at column [rdCol]. Double-buffering guarantees the read buffer is
/// never the buffer being written, so the read crossing into the pixel domain
/// is a safe quasi-static (multi-cycle) path, only the small line-swap handshake
/// (built by the surrounding controller) crosses through synchronizers.
///
/// The read is asynchronous (LUT-RAM style) so a freshly filled buffer is
/// visible immediately on the read side.
class HarborDoubleLineBuffer extends Module {
  /// The selected buffer's word at [rdCol].
  Logic get rdData => output('rd_data');

  final int maxWords;

  HarborDoubleLineBuffer({
    required Logic wrClk,
    required Logic wrEn,
    required Logic wrSel,
    required Logic wrIdx,
    required Logic wrData,
    required Logic rdSel,
    required Logic rdCol,
    this.maxWords = 1024,
    super.name = 'double_line_buffer',
  }) : super(definitionName: 'HarborDoubleLineBuffer') {
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;

    wrClk = addInput('wr_clk', wrClk);
    wrEn = addInput('wr_en', wrEn);
    wrSel = addInput('wr_sel', wrSel);
    wrIdx = addInput('wr_idx', wrIdx, width: idxW);
    wrData = addInput('wr_data', wrData, width: 32);
    rdSel = addInput('rd_sel', rdSel);
    rdCol = addInput('rd_col', rdCol, width: rdCol.width);
    addOutput('rd_data', width: 32);

    final buf0 = List.generate(
      maxWords,
      (i) => Logic(name: 'b0_$i', width: 32),
    );
    final buf1 = List.generate(
      maxWords,
      (i) => Logic(name: 'b1_$i', width: 32),
    );

    // Write port: clocked by the system (write) clock.
    Sequential(wrClk, [
      If(
        wrEn,
        then: [
          for (var i = 0; i < maxWords; i++)
            If(
              wrIdx.eq(i),
              then: [
                If(wrSel, then: [buf1[i] < wrData], orElse: [buf0[i] < wrData]),
              ],
            ),
        ],
      ),
    ]);

    // Read port: combinational select of buffer and column.
    Logic p0 = Const(0, width: 32);
    Logic p1 = Const(0, width: 32);
    for (var i = 0; i < maxWords; i++) {
      p0 = mux(rdCol.eq(i), buf0[i], p0);
      p1 = mux(rdCol.eq(i), buf1[i], p1);
    }
    rdData <= mux(rdSel, p1, p0);
  }
}
