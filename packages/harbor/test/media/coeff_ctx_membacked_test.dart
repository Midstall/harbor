import 'dart:async';
import 'dart:math';
import 'package:rohd/rohd.dart';
import 'package:harbor/src/media/coeff_context.dart';
import 'package:test/test.dart';

/// Proves the memBacked (addressed-memory) HarborCoeffContext produces
/// byte-identical context outputs to the original whole-buffer-mux version,
/// and that it is tractable to build/simulate at TX_32X32 (N=1024).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // (txSize, n, bhl, width)
  const cases = [
    (0, 16, 2, 4),
    (1, 64, 3, 8),
    (2, 256, 4, 16),
    (3, 1024, 5, 32),
  ];

  for (final (txSize, n, bhl, width) in cases) {
    test(
      'memBacked == mux for txSize=$txSize (N=$n)',
      () async {
        Simulator.setMaxSimTime(1000 * 1000 * 1000);
        final stride = (1 << bhl) + 4;
        final bufLen = ((1 << bhl) + 4) * (width + 4) + 16;
        int padded(int pos) => (pos & ((1 << bhl) - 1)) + (pos >> bhl) * stride;

        final ref = HarborCoeffContext(txSize: txSize, name: 'ref');
        final refLevels = Logic(width: bufLen * 8);
        final refCi = Logic(width: ref.input('coeff_idx').width);
        final refSi = Logic(width: ref.input('scan_idx').width);
        final refTc = Logic(width: 2);
        ref.input('levels').srcConnection! <= refLevels;
        ref.input('coeff_idx').srcConnection! <= refCi;
        ref.input('scan_idx').srcConnection! <= refSi;
        ref.input('tx_class').srcConnection! <= refTc;
        await ref.build();

        final clk = SimpleClockGenerator(10).clk;
        final dut = HarborCoeffContext(
          txSize: txSize,
          memBacked: true,
          name: 'dut',
        );
        final rst = Logic();
        final clr = Logic();
        final wrEn = Logic();
        final wrIdx = Logic(width: dut.input('wr_idx').width);
        final wrVal = Logic(width: 8);
        final dCi = Logic(width: dut.input('coeff_idx').width);
        final dSi = Logic(width: dut.input('scan_idx').width);
        final dTc = Logic(width: 2);
        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= rst;
        dut.input('clear').srcConnection! <= clr;
        dut.input('wr_en').srcConnection! <= wrEn;
        dut.input('wr_idx').srcConnection! <= wrIdx;
        dut.input('wr_val').srcConnection! <= wrVal;
        dut.input('coeff_idx').srcConnection! <= dCi;
        dut.input('scan_idx').srcConnection! <= dSi;
        dut.input('tx_class').srcConnection! <= dTc;
        await dut.build();

        final rng = Random(0x1234 + txSize);
        final gold = List<int>.filled(bufLen, 0);

        rst.inject(1);
        clr.inject(0);
        wrEn.inject(0);
        wrIdx.inject(0);
        wrVal.inject(0);
        dCi.inject(0);
        dSi.inject(0);
        dTc.inject(0);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        rst.inject(0);
        await clk.nextPosedge;

        const outs = [
          'base_ctx_2d',
          'base_ctx_gen',
          'base_eob_ctx',
          'br_ctx_2d',
          'br_ctx_gen',
          'br_ctx_eob',
        ];

        // Write a spread of random levels into the buffer, one cell per cycle,
        // and after each write check a batch of query positions/classes agree.
        // Fewer iterations for large N (the mux reference settle is O(N), slow).
        // A handful of random buffer states is plenty to prove equivalence.
        final nWrites = n <= 64 ? min(n, 120) : (n <= 256 ? 40 : 16);
        for (var w = 0; w < nWrites; w++) {
          final pos = rng.nextInt(n);
          final val = rng.nextInt(64); // magnitudes 0..63
          gold[padded(pos)] = val;
          // drive DUT write
          wrEn.inject(1);
          wrIdx.inject(pos);
          wrVal.inject(val);
          await clk.nextPosedge;
          wrEn.inject(0);
          // settle a delta
          await clk.nextPosedge;

          // update ref levels bus to the golden state
          var bus = BigInt.zero;
          for (var i = 0; i < bufLen; i++) {
            bus |= BigInt.from(gold[i]) << (i * 8);
          }
          refLevels.inject(bus);

          // check a few queries
          for (var q = 0; q < 4; q++) {
            final ci = rng.nextInt(n);
            final si = rng.nextInt(n);
            final tc = rng.nextInt(3);
            refCi.inject(ci);
            refSi.inject(si);
            refTc.inject(tc);
            dCi.inject(ci);
            dSi.inject(si);
            dTc.inject(tc);
            await clk.nextPosedge; // let both settle
            for (final o in outs) {
              final r = ref.output(o).value;
              final d = dut.output(o).value;
              expect(
                d,
                equals(r),
                reason:
                    'txSize=$txSize w=$w q=$q ci=$ci si=$si tc=$tc out=$o '
                    'ref=$r dut=$d',
              );
            }
          }
        }
        await Simulator.endSimulation();
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
