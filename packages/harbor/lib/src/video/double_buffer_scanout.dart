import 'package:rohd/rohd.dart';

/// Double-buffered line scanout: a Wishbone-style master plus two line buffers
/// that ping-pong so the beam always reads a fully-fetched line.
///
/// Runs in a single clock domain (the pixel domain). The system-bus clock
/// crossing is handled outside by a Wishbone CDC bridge. A [frameStart] pulse
/// primes both buffers (row 0 into buffer 0, row 1 into buffer 1). Each
/// [lineStart] pulse swaps to the prefetched buffer and kicks the DMA to fill
/// the freed buffer with the next row, staying one line ahead. [pixel] serves
/// `buffer[readSel][col]`. [underrun] latches if a line was not ready in time.
///
/// Addresses advance by [stride] bytes per row, each row is [wordsPerLine]
/// 32-bit words. [maxWords] sizes the line buffers.
class HarborDoubleBufferScanout extends Module {
  /// Current pixel word for [col] in the active line buffer.
  Logic get pixel => output('pixel');

  /// Latches high if the DMA failed to have a line ready at [lineStart].
  Logic get underrun => output('underrun');

  /// Wishbone master outputs.
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final int maxWords;

  HarborDoubleBufferScanout({
    required Logic clk,
    required Logic reset,
    required Logic frameStart,
    required Logic lineStart,
    required Logic col,
    required Logic fbBase,
    required Logic stride,
    required Logic wordsPerLine,
    required Logic mDataIn,
    required Logic mAck,
    this.maxWords = 1024,
    super.name = 'double_buffer_scanout',
  }) : super(definitionName: 'HarborDoubleBufferScanout') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    frameStart = addInput('frame_start', frameStart);
    lineStart = addInput('line_start', lineStart);
    col = addInput('col', col, width: col.width);
    fbBase = addInput('fb_base', fbBase, width: 32);
    stride = addInput('stride', stride, width: 32);
    wordsPerLine = addInput('words_per_line', wordsPerLine, width: 16);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    addOutput('pixel', width: 32);
    addOutput('underrun');
    addOutput('m_stb');
    addOutput('m_cyc');
    addOutput('m_we');
    addOutput('m_adr', width: 32);
    addOutput('m_sel', width: 4);
    addOutput('m_dat_o', width: 32);

    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;

    // Phases: 0 idle, 1 prime-A (row0 fetching), 2 prime-B (row1 fetching),
    // 3 run.
    final phase = Logic(name: 'phase', width: 2);
    final dmaBusy = Logic(name: 'dma_busy');
    final dmaAddr = Logic(name: 'dma_addr', width: 32);
    final dmaCnt = Logic(name: 'dma_cnt', width: 16);
    final dmaIdx = Logic(name: 'dma_idx', width: idxW);
    final dmaFill = Logic(name: 'dma_fill'); // target buffer for the DMA
    final readSel = Logic(name: 'read_sel'); // buffer the beam reads
    final fetchAddr = Logic(name: 'fetch_addr', width: 32);
    final underrunReg = Logic(name: 'underrun_reg');

    final buf0 = List.generate(
      maxWords,
      (i) => Logic(name: 'b0_$i', width: 32),
    );
    final buf1 = List.generate(
      maxWords,
      (i) => Logic(name: 'b1_$i', width: 32),
    );

    // Master port: read burst while the DMA is busy.
    mStb <= dmaBusy;
    mCyc <= dmaBusy;
    mWe <= Const(0);
    mAddr <= dmaAddr;
    mSel <= Const(0xF, width: 4);
    mDataOut <= Const(0, width: 32);
    underrun <= underrunReg;

    // Column readback from the active buffer.
    Logic p0 = Const(0, width: 32);
    Logic p1 = Const(0, width: 32);
    for (var i = 0; i < maxWords; i++) {
      p0 = mux(col.eq(i), buf0[i], p0);
      p1 = mux(col.eq(i), buf1[i], p1);
    }
    pixel <= mux(readSel, p1, p0);

    // A fetch kick: start the DMA on (addr -> buffer fill).
    List<Conditional> kick(Logic addr, Logic fill) => [
      dmaBusy < Const(1),
      dmaAddr < addr,
      dmaCnt < wordsPerLine,
      dmaIdx < Const(0, width: idxW),
      dmaFill < fill,
    ];

    Sequential(clk, reset: reset, [
      If(
        frameStart,
        then: [
          // (Re)start the frame: prime row 0 into buffer 0.
          readSel < Const(0),
          underrunReg < Const(0),
          ...kick(fbBase, Const(0)),
          fetchAddr < (fbBase + stride),
          phase < Const(1, width: 2),
        ],
        orElse: [
          // DMA read engine: capture one word per ack into the fill buffer.
          If(
            dmaBusy & mAck,
            then: [
              for (var i = 0; i < maxWords; i++)
                If(
                  dmaIdx.eq(i),
                  then: [
                    If(
                      dmaFill,
                      then: [buf1[i] < mDataIn],
                      orElse: [buf0[i] < mDataIn],
                    ),
                  ],
                ),
              dmaAddr < (dmaAddr + Const(4, width: 32)),
              dmaIdx < (dmaIdx + Const(1, width: idxW)),
              If(
                dmaCnt.eq(1),
                then: [dmaBusy < Const(0)],
                orElse: [dmaCnt < (dmaCnt - Const(1, width: 16))],
              ),
            ],
          ),
          // Line sequencer.
          Case(phase, [
            CaseItem(Const(1, width: 2), [
              // Prime A done -> fetch row 1 into buffer 1.
              If(
                ~dmaBusy,
                then: [
                  ...kick(fetchAddr, Const(1)),
                  fetchAddr < (fetchAddr + stride),
                  phase < Const(2, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 2), [
              If(~dmaBusy, then: [phase < Const(3, width: 2)]),
            ]),
            CaseItem(Const(3, width: 2), [
              If(
                lineStart,
                then: [
                  readSel < ~readSel,
                  If(
                    dmaBusy,
                    then: [underrunReg < Const(1)],
                    orElse: [
                      // Fill the just-freed buffer (the old readSel) with the next
                      // row.
                      ...kick(fetchAddr, readSel),
                      fetchAddr < (fetchAddr + stride),
                    ],
                  ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
