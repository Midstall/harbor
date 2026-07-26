import 'package:rohd/rohd.dart';

/// Scanline fetch DMA: the streaming core of framebuffer scanout.
///
/// On a [start] pulse it reads [words] sequential 32-bit words from memory
/// starting at byte address [base], over a simple Wishbone-style master port
/// (assert `cyc`/`stb`, advance on each `ack`), into an internal line buffer of
/// up to [maxWords] words. [ready] latches high when the line is buffered.
/// [pixel] then serves `buffer[col]` combinationally.
///
/// This is the single-buffer fetch core. The double-buffer ping-pong and the
/// system->pixel clock-domain crossing are layered on top of this in the
/// display controller integration.
class HarborScanlineDma extends Module {
  /// High while a fetch is in progress.
  Logic get busy => output('busy');

  /// Latches high when a full line is buffered and available.
  Logic get ready => output('ready');

  /// The buffered word at column [col] (combinational).
  Logic get pixel => output('pixel');

  /// Wishbone master outputs.
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final int maxWords;

  HarborScanlineDma({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic base,
    required Logic words,
    required Logic col,
    required Logic mDataIn,
    required Logic mAck,
    this.maxWords = 1024,
    super.name = 'scanline_dma',
  }) : super(definitionName: 'HarborScanlineDma') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    base = addInput('base', base, width: 32);
    words = addInput('words', words, width: 16);
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;
    col = addInput('col', col, width: col.width);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    addOutput('busy');
    addOutput('ready');
    addOutput('pixel', width: 32);
    addOutput('m_stb');
    addOutput('m_cyc');
    addOutput('m_we');
    addOutput('m_adr', width: 32);
    addOutput('m_sel', width: 4);
    addOutput('m_dat_o', width: 32);

    // state: 0 = idle, 1 = reading.
    final state = Logic(name: 'state');
    final addr = Logic(name: 'addr', width: 32);
    final cnt = Logic(name: 'cnt', width: 16);
    final idx = Logic(name: 'idx', width: idxW);
    final readyReg = Logic(name: 'ready_reg');
    final buffer = List.generate(
      maxWords,
      (i) => Logic(name: 'line_$i', width: 32),
    );

    final reading = state; // 1-bit state doubles as "in read"

    // Master port: read burst while in the read state.
    mStb <= reading;
    mCyc <= reading;
    mWe <= Const(0);
    mAddr <= addr;
    mSel <= Const(0xF, width: 4);
    mDataOut <= Const(0, width: 32);

    busy <= reading;
    ready <= readyReg;

    // Column readback mux.
    Logic p = Const(0, width: 32);
    for (var i = 0; i < maxWords; i++) {
      p = mux(col.eq(i), buffer[i], p);
    }
    pixel <= p;

    Sequential(clk, reset: reset, [
      If(
        state.eq(0),
        then: [
          // Idle: wait for a start pulse.
          If(
            start,
            then: [
              addr < base,
              cnt < words,
              idx < Const(0, width: idxW),
              readyReg < Const(0),
              state < Const(1),
            ],
          ),
        ],
        orElse: [
          // Reading: capture one word per ack, advance, finish on the last.
          If(
            mAck,
            then: [
              for (var i = 0; i < maxWords; i++)
                If(idx.eq(i), then: [buffer[i] < mDataIn]),
              addr < (addr + Const(4, width: 32)),
              idx < (idx + Const(1, width: idxW)),
              If(
                cnt.eq(1),
                then: [state < Const(0), readyReg < Const(1)],
                orElse: [cnt < (cnt - Const(1, width: 16))],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
